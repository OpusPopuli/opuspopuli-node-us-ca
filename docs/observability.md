# Observability

Every node runs Prometheus (metrics), Loki (logs), Tempo (traces) and Grafana
(the view over all three). Datasources and dashboards are provisioned from this
repo, so a fresh node has a working set-up on first boot rather than an empty
Grafana that each operator wires up differently.

## Reaching Grafana

Grafana binds to `${GRAFANA_BIND_ADDR:-127.0.0.1}:3101`.

**Loopback is the default and stays the default.** A dashboard over your metrics
and logs should not become reachable from other machines by accident.

| Access | How |
|---|---|
| From the node | `http://localhost:3101` |
| From your laptop, no config change | `ssh -N -L 3101:localhost:3101 <user>@<node>` then `http://localhost:3101` |
| From your tailnet | `create-op-node bootstrap --grafana-tailnet`, or set `GRAFANA_BIND_ADDR` to the node's Tailscale IP |

If you use the tailnet option, also set `GRAFANA_ROOT_URL` to the same address —
otherwise Grafana advertises `http://localhost:3101` in share links and alert
notifications, which is wrong for everyone but you.

```bash
# .env
GRAFANA_BIND_ADDR=100.x.y.z
GRAFANA_ROOT_URL=http://<node-hostname>:3101
```

Login is `admin`; the password was generated into your Keychain at bootstrap:

```bash
security find-generic-password -s org.opuspopuli.<region> -a grafana-admin-password -w
```

## What ships

Three dashboards, in the **Opus Populi** folder.

### Node Health

Is the node alive, and is anything trending toward not being alive.

- Services up, and per-service availability
- Restarts in the window — a crash-loop and a redeploy look identical here, so
  correlate with errors before concluding
- Resident memory and V8 heap. A steady climb that never falls back is the shape
  of a leak; the region worker legitimately spikes during a bulk sync
- Event-loop lag (p99). Sustained lag above ~100ms means the process is CPU-bound
  and health checks may start failing while nothing has actually crashed
- GC time, which rises with heap under memory pressure

### Sync Pipeline

What the region worker is doing right now.

**This one is built on Loki, not Prometheus**, because the sync exposes no
metrics — progress, failures and linker results exist only as log lines. That is
a gap worth closing; until it is, this dashboard is the answer to "is the sync
alive and how far along is it".

The panel that matters most is **Ingest rate**. During a re-sync the database
row counts sit completely still for hours, because rows already present are
upserted as updates rather than inserts. A table count that has not moved since
you last looked tells you nothing. The ingest rate is the liveness signal: flat
there means genuinely stalled.

**Linker results** shows post-sync attribution — `linked` versus `noCoverPage`
and `noCommittee`. That split is diagnostic: the first means the join source
never arrived, the second that it arrived but referenced a committee the node
does not know about.

### API Performance

Request throughput, latency and database pressure. The first place to look when
the site feels slow but nothing is down.

- HTTP request and 5xx rates
- Latency p95/p99 — the median can look fine while the tail is seconds
- GraphQL operation rate
- DB pool busy vs idle. Busy pinned at the ceiling means requests are queueing
  for a connection, usually a slow query rather than genuine load
- DB query duration p95, which moves before request latency does
- Circuit breaker state (0 closed, 1 half-open, 2 open)

## Changing a dashboard

Dashboards are files. `allowUiUpdates: false` is set deliberately, so edits made
in the browser are for exploring and Grafana restores the file version on
restart.

To keep a change: **Dashboard → Export → Save to file**, then commit the JSON to
`grafana/dashboards/` in `opuspopuli-node` and sync it down to your node repo.
That way every operator gets the improvement instead of one node drifting.

Grafana rescans the directory every 30 seconds, so a file change appears without
a restart.

## Adding a datasource

Edit `grafana/provisioning/datasources/datasources.yml`.

URLs are **container names** on `opuspopuli-network` — `localhost` there points
at the Grafana container itself, not at the service you meant.

If a datasource with the same name already exists from a hand-created UI entry,
delete it in the UI first. The database entry wins, which leaves you editing YAML
that appears to do nothing.

## Useful LogQL

Grafana's Explore, with the Loki datasource:

```logql
# everything from one service
{container="opuspopuli-region-worker"}

# sync progress
{container="opuspopuli-region-worker"} |= "Flushed batch"

# errors across the whole stack
{compose_project=~".+"} |~ "(?i)\\berror\\b"

# strip ANSI colour codes from Nest's output
{container="opuspopuli-api"} | decolorize
```

Labels available: `container`, `service`, `compose_service`, `compose_project`.

## When `docker logs` disagrees with Loki

Promtail collects through the Docker API rather than by tailing log files. After
a host reboot, `docker logs` has been observed going permanently silent for a
container that is running perfectly well — the log driver loses its handle and
does not recover.

Loki keeps working in that situation. **If a container looks silent but healthy,
check Loki before concluding it is wedged.** Recreating the container restores
`docker logs`, but there is rarely a reason to: Loki is the better source anyway,
and recreating mid-job loses the job.
