# `backup/` — opuspopuli backup service

Container image, scripts, and supercronic schedule for the daily
PostgreSQL backup that runs alongside every opuspopuli environment.

**Operator-facing guide**: see [`docs/guides/backup-recovery.md`](../docs/guides/backup-recovery.md)
for setup, ad-hoc commands, and restore procedures.

**Compose**: see [`docker-compose-backup.yml`](../docker-compose-backup.yml)
for the overlay that pulls this image into a running stack.

**Env vars**: see [`.env.backup.example`](../.env.backup.example) for
the contract between this service and the host environment.

This README documents the contents of the directory for anyone
adding or modifying the backup service itself.

---

## Contents

| Path | Role |
|------|------|
| `Dockerfile` | Builds the backup container. Inherits from `supabase/postgres:17.6.1.138` so `pg_dump` / `pg_restore` versions exactly match the production server. Installs supercronic as the in-container scheduler (arch selected via `TARGETARCH`). |
| `entrypoint.sh` | Container entrypoint. Dispatches between **scheduler mode** (no args → supercronic + crontab) and **one-shot mode** (args → exec args). Ad-hoc invocations use one-shot. |
| `crontab` | supercronic-format schedule. Currently a single line: daily 03:00 backup. Edit here to change the schedule for all environments at once. |
| `scripts/backup-db.sh` | The daily backup of the main `opuspopuli-db`. `pg_dump --format=custom` piped through `gzip -9` into a host bind-mounted directory. Atomic rename via `.partial`, cross-mode `flock`, JSON-structured log lines, configurable retention. |
| `scripts/backup-prompts-db.sh` | Daily backup of the colocated prompt-service DB (`opuspopuli-prompts-db`). Same shape as `backup-db.sh`; skips cleanly (logs `skipped`) on nodes not running the prompt-service overlay. Snapshots named `opuspopuli-prompts-db-<sha>-<ts>.dump.gz`. |
| `scripts/restore-db.sh` | Operator-triggered restore of `opuspopuli-db`. Two modes (`--quick` and `--full`) for schema-match vs schema-drift cases. Takes the same lock as the backup scripts so a scheduled backup can't race a restore. |

## How the pieces fit together

```
┌──────────────────────────────────────────────────────────────────┐
│  Host filesystem                                                 │
│                                                                  │
│    ${BACKUPS_DIR_HOST}/                                          │
│    ├── opuspopuli-db-<sha>-<ts>.dump.gz         ← main DB        │
│    ├── opuspopuli-prompts-db-<sha>-<ts>.dump.gz ← prompts DB     │
│    ├── backup.log                          ← JSON lines, append  │
│    └── .backup.lock                        ← flock file          │
└──────────────────────────────────────────────────────────────────┘
                        ▲
                        │ bind-mount → /backups
                        │
┌─────────────────── opuspopuli-backup container ──────────────────┐
│                                                                  │
│   entrypoint.sh                                                  │
│      │                                                           │
│      ├── no args ─→  supercronic /crontab                        │
│      │                  │                                        │
│      │                  └── fires `/scripts/backup-db.sh` daily  │
│      │                                                           │
│      └── argv  ─→  exec argv                                     │
│                       └── `/scripts/backup-db.sh` (ad-hoc)       │
│                       └── `/scripts/restore-db.sh ...` (restore) │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                        │
                        │ docker network: opuspopuli-network
                        ▼
                 opuspopuli-db (postgres)
```

## Design decisions worth knowing before you change anything

### Base image is pinned to the production DB image

`FROM supabase/postgres:17.6.1.138` (not generic `postgres:17-alpine`).
This guarantees `pg_dump` and `pg_restore` versions exactly match the
server. PostgreSQL custom-format dumps are not forward-compatible
across major-version mismatches; downgrade-side bugs are silent and
costly. This tag MUST equal the `opuspopuli-db` image in
`docker-compose-prod.yml`. If you bump the DB image version anywhere
else in the stack, bump it here too (and in
`docker-compose-prompt-service.yml`).

### Backups land on a host bind mount, never a docker named volume

The 2026-06-06 incident: a Docker Desktop disk image resize wiped
every docker named volume, including the prod database. If backups
had lived in a named volume the same operation would have wiped
them too. Bind-mounting to a host filesystem path (or external
drive) means backups survive any docker volume operation.

The `${BACKUPS_DIR_HOST:?...}` compose syntax fails the `up` command
loudly if the var isn't set — this is intentional, to surface
operator misconfiguration immediately.

### Scripts are baked into the image AND bind-mounted

The Dockerfile `COPY scripts /scripts` (image has its own copy) AND
the compose file binds `./backup/scripts:/scripts:ro` (overrides
with the on-disk version at runtime). This means:

- **Production**: image is self-contained, can run without the repo present
- **Development**: edits to scripts take effect on container restart
  without a rebuild

The compose-side bind mount wins at runtime, so dev iteration is
fast and prod is hermetic.

### supercronic chosen over stock cron

- Logs job output to stdout — `docker logs opuspopuli-backup` shows
  the scheduler activity directly, no syslog forwarding gymnastics
- Single static binary, no PAM/syslog dependencies
- Built-in `--lock` flag (we use `flock` in the script for the same
  effect, but the option exists)
- Sane PID 1 signal handling — `docker compose stop` is clean

### Cross-mode flock between backup-db.sh and restore-db.sh

Both scripts `flock -x` on `${BACKUPS_DIR}/.backup.lock`. This means:
- Two concurrent backup runs serialize (or fail fast with
  `BACKUP_LOCK_WAIT=false`)
- A restore blocks scheduled backups while it's in progress
- A scheduled backup at 03:00 won't fire mid-restore

### `--full` restore doesn't auto-migrate

After a `--full` restore, the schema is at the snapshot's git_sha,
not necessarily current head. If they differ, the script prints
the follow-up `db-migrate` command for the operator to run rather
than trying to do it itself.

The reason: invoking docker exec from inside this container to run
the migrate container requires mounting the docker socket, which is
a privilege escalation surface we don't want for a backup service.
Better to keep the operator in the loop for the schema-bump step.

### `--full` runs as the superuser and re-applies the JWT GUCs

Two non-obvious failure modes on the supabase/postgres image made a
naive drop/create + pg_restore leave the cluster subtly broken:

1. **CREATE EXTENSION needs SUPERUSER.** The dump contains
   `CREATE EXTENSION` for postgis / vector / pg_trgm, but the image's
   demote-postgres migration strips SUPERUSER from the everyday
   `postgres` role. So `--full` connects as `supabase_admin`
   (`BACKUP_SUPERUSER`) for the drop/create and the pg_restore.

2. **JWT GUCs are not in the dump.** `supabase/init/sql/01-jwt.sql`
   sets `ALTER DATABASE postgres SET "app.settings.jwt_secret"` and
   `app.settings.jwt_exp` on first boot. A single-DB `pg_dump` does
   NOT capture `ALTER DATABASE ... SET` (those live in globals), and
   the init scripts don't re-run on an existing cluster. After a
   `DROP DATABASE`, nothing restores them — postgrest then signs/
   verifies tokens against an empty secret and auth silently breaks.
   `--full` re-applies both GUCs from `JWT_SECRET` / `JWT_EXP` (env)
   immediately after `CREATE DATABASE`. It fails fast if `JWT_SECRET`
   is unset rather than restoring a DB whose auth is broken.

**Post-`--full` drill checklist** — a successful restore is NOT just
"rows came back". You MUST also verify auth works end-to-end:

- Confirm the GUCs are present:
  `SELECT current_setting('app.settings.jwt_secret')` against the
  restored DB (as supabase_admin) returns your secret, not empty.
- Hit a postgrest-authenticated endpoint (log in, load an
  authed GraphQL query) and confirm you are NOT rejected with a JWT
  error. If auth 401s, the JWT GUCs didn't take — re-check
  `JWT_SECRET` matched the running stack's secret.

## Adding a new scheduled job

If you ever want to add a second scheduled task (e.g. a separate
audit-log dump):

1. Add a new script to `scripts/`
2. Add a line to `crontab` referencing it
3. Rebuild the image; deploy via `docker compose up -d --build`

The image is small enough that rebuilds are quick. Don't try to
reuse the same script for multiple schedules — keep one
script-per-purpose for clarity.

## Backup coverage boundary

What this service does and does NOT snapshot, and why. Review this
before assuming any given data survives a `docker volume` disaster.

| Target | Volume | Covered? | How / why |
|--------|--------|----------|-----------|
| Main app DB | `opuspopuli-db-data` | **Yes** | `backup-db.sh`, daily 03:00. The primary asset. |
| Prompt-service DB | `prompts-db-data` | **Yes (when overlay active)** | `backup-prompts-db.sh`, daily 03:10. Skips cleanly on nodes without the prompt-service overlay. Separate bounded context → its own snapshot. |
| `_supabase` DB | `opuspopuli-db-data` (same cluster) | **No** | Internal supabase metadata DB (analytics, logflare) on the same cluster. Contains no civic/user data we can't rebuild; it is re-initialized by the image on a fresh boot. Accepted loss — a `--full` restore of the main DB does not touch it and that's fine. |
| Storage uploads | `supabase-storage-data` | **No — documented accepted loss** | File-backend uploads live in a named volume, NOT in Postgres, so `pg_dump` cannot capture them. Currently the DB holds only public civic data and storage holds derived/scanned artifacts that can be regenerated from source. **Boundary:** once real user PII / irreplaceable uploads land here, this MUST move to an `rclone`-to-R2 sync (tracked with the R2 follow-up below). Until then, off-site coverage is manual host-side copies. |
| Grafana | `grafana-data` | **No** | Dashboards + Grafana's internal SQLite. Dashboards are provisioned from `observability/` in-repo (source of truth), so the volume is reconstructable from a redeploy. Accepted loss — losing it costs only ad-hoc saved queries and alert-silence state. |

If you add a new stateful service, add a row here with an explicit
covered/accepted-loss decision — don't leave the coverage of a new
volume ambiguous.

## Bumping supercronic

The version + per-arch SHA256 checksums are build args in the
Dockerfile. supercronic ships one binary per arch and the prod host
(Mac Studio) is **arm64** while CI is **amd64**, so the Dockerfile
selects the arch via BuildKit's `TARGETARCH` and pins BOTH
checksums (`SUPERCRONIC_SHA256_amd64` and `SUPERCRONIC_SHA256_arm64`).
To bump you must refresh **both**:

```bash
# Fetch both new SHA256 checksums
for arch in amd64 arm64; do
  echo -n "$arch: "
  curl -sL "https://github.com/aptible/supercronic/releases/download/<NEW_VERSION>/supercronic-linux-${arch}" \
    | sha256sum
done

# Update SUPERCRONIC_VERSION, SUPERCRONIC_SHA256_amd64, and
# SUPERCRONIC_SHA256_arm64 in Dockerfile, then rebuild and verify.
# On a prod (arm64) node:
docker compose -f docker-compose-prod.yml \
               -f docker-compose-backup.yml \
               build --no-cache opuspopuli-backup
```

The SHA256 pins are a supply-chain safeguard — if upstream is ever
compromised, the build will fail loud at install time. Never ship a
guessed checksum: a wrong pin fails every build on that arch.

## Why no R2 sync yet

Deferred to a follow-up issue. Two reasons:

1. Vault-first secrets refactor (#811) isn't done; R2 creds would
   need to be available cleanly to the container, and threading
   them through env vars before #811 is finished introduces tech
   debt that we'd have to unwind later.
2. R2 sync turns this from a single-service into a two-step pipeline
   (snapshot → upload), which adds failure modes (network, R2 quota,
   credential expiry) worth thinking about in their own design pass.

Until then, manual off-site copies (Time Machine, `rclone` cron from
the host, or a one-off `aws s3 cp`) cover the geographic-redundancy
gap.

## Why no encryption yet

The DB currently contains civic public data only. Once we onboard
real users with PII, the snapshot file contains personal data
that the unencrypted-at-rest snapshot doesn't protect adequately.
Adding pg_dump encryption (or wrapping with `age` / `gpg`) at that
point is straightforward — it's a single pipe step in `backup-db.sh`
and a matching pipe in `restore-db.sh`.

For MVP launch, encryption is documented as a known gap in the
operator guide and tracked for v1.1.
