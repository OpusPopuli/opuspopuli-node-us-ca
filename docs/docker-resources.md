# Docker Desktop resource configuration (Mac Studio)

Sizing guide for Docker Desktop on the Studio. **Get this right once;
re-sizing later (especially shrinking the disk image) destroys volumes.**

> ⚠ **NEVER reduce the Docker Desktop disk image size.** A 256 → 200 GB
> resize on `2026-06-06` wiped all named volumes including
> `opuspopuli-db` (CAL-ACCESS + all civic data, only one pg_dump
> survived). The setting is one-way: grow yes, shrink no. Set it large
> up front.

## Reference hardware

This guide targets the Studio config the platform was sized against:

| Component | Value |
|---|---|
| Chip | Apple M4 Max, 16-core CPU (12P + 4E) |
| Unified memory | 128 GB |
| Internal SSD | 1 TB |
| LLM runtime | Ollama on host (not in Docker) |

Adjust the tables below if your config is smaller.

## Pre-step: APFS volume for data isolation

Done once on first setup:

```bash
diskutil list                                   # find your container, usually disk3
diskutil apfs addVolume disk3 APFS OpusPopuli   # creates /Volumes/OpusPopuli
```

This gives a logically separate mount point (`/Volumes/OpusPopuli`)
for the region repo + Docker data + region-specific artifacts. The new
volume shares the container's free space pool — no real partition, no
reboot, no risk to existing volumes. Inherits FileVault state.

## Memory allocation

Ollama and Docker compete for the same unified-memory pool. The right
split depends on which LLM tier you're running on the host.

| LLM tier         | Example models                                | Ollama RAM | macOS + buffer | Docker Desktop RAM |
|---|---|---|---|---|
| 9B class         | `qwen3.5:9b`, `llama3.1:8b`, `mistral:7b`     | ~8 GB      | ~16 GB         | **96 GB**          |
| 70B class        | `llama3.3:70b-q4`, `qwen2.5:72b-q4`           | ~50 GB     | ~22 GB         | **56 GB**          |
| Frontier / MoE   | `mixtral:8x22b-q4`, `llama3.1:405b-q4`        | ~80 GB     | ~24 GB         | **24 GB**          |

**Recommended for the current platform**: 70B tier — `Docker = 56 GB`.
The full data stack (postgres + redis + 7 microservices + observability
quintet) settles at ~12 GB resident; the rest is headroom for parallel
bill-ingestion + LLM-rerank workers + image pulls.

Set it under **Docker Desktop → Settings → Resources → Memory limit**.

## CPU allocation

| Setting | Value | Why |
|---|---|---|
| **CPU limit**          | **12 cores** | Leaves 4 of the 16-core M4 Max for the host + Ollama inference. Ollama on Apple Silicon uses CPU for small models, GPU/Neural Engine for larger ones; 4 host cores cover both cases. |
| **Memory swap**        | **4 GB**     | Inside-VM swap. Rarely touched with 56+ GB of RAM allocated, but cheap insurance. |

## Disk image size

This is the **most consequential setting** — see the warning at the top.

| Setting | Value | Why |
|---|---|---|
| **Disk image size** | **300 GB** | Allocate-once-and-forget. The Docker image is sparse (only uses what it actually stores), so 300 GB isn't actually consumed up front. Holds: ghcr image cache (~10 GB), postgres data (~50 GB + projected growth), buildx layers (~10 GB), all named volumes, and unforeseen growth — without ever needing a destructive resize. |

Set under **Docker Desktop → Settings → Resources → Disk → Virtual disk limit**.

## Disk image location

Move it off the boot volume to keep the logical split clean:

| Setting | Value |
|---|---|
| **Disk image location** | `/Volumes/OpusPopuli/.docker-data` |

Set under **Docker Desktop → Settings → Resources → Advanced → Disk image location** (or "Advanced" tab depending on Docker Desktop version).

> Docker Desktop handles the move atomically — it stops the VM, copies
> the existing disk image to the new path, and restarts. No data loss.
> Takes 1–5 minutes depending on existing volume size.

## Other Docker Desktop settings

These rarely need to change after first setup. Configure them once.

### General tab

| Setting | Value | Why |
|---|---|---|
| **Start Docker Desktop when you sign in** | ON  | The LaunchAgent + the data stack assume Docker is running at login. |
| **Open Docker Desktop dashboard at startup** | OFF | Dashboard isn't needed; runs in the background. |
| **Use Resource Saver** | **OFF** | Resource Saver pauses containers when idle; we need the stack running 24/7. |
| **Send usage statistics** | Operator's choice | Anonymous telemetry to Docker Inc. |
| **Show CLI hints** | OFF | Cosmetic. |
| **Choose theme for Docker Desktop** | Operator's choice | Cosmetic. |
| **Enable Docker terminal** | OFF | We use the host terminal. |

### Resources → Advanced

| Setting | Value | Why |
|---|---|---|
| **Virtualization framework** | **Apple Virtualization framework** | Faster than QEMU on Apple Silicon. Required for VirtioFS. |
| **VirtioFS for file sharing** | **ON** | Significantly faster bind-mount I/O than gRPC FUSE. |
| **Use Rosetta for x86_64/amd64 emulation on Apple Silicon** | ON | Falls back gracefully if a third-party image only ships amd64. Our images ship arm64 so this rarely fires. |

### Resources → File sharing

Add these paths so bind mounts work:

| Path | Why |
|---|---|
| `/Volumes/OpusPopuli` | Region repo clone + region-specific volumes. |
| `/Users/$USER` | Default; usually pre-populated. |

Remove any paths you don't actually share — file sharing is mTLS-pinned
between Docker and host, and unnecessary entries add startup time.

### Resources → Network

| Setting | Value | Why |
|---|---|---|
| **Enable host networking** | ON | Some compose-stack patterns rely on `network_mode: host`; harmless if unused. |

### Docker Engine

Leave the JSON config at defaults unless you have a specific reason. The
template's compose file doesn't depend on engine-level config changes.

### Software updates

| Setting | Value | Why |
|---|---|---|
| **Automatically check for updates** | ON | Notify-only. |
| **Always download updates automatically** | **OFF** | Apply updates manually after testing the stack on a non-prod machine first. Docker Desktop releases occasionally break compose behavior. |

### Beta features

All OFF — production node. Enable selectively on a dev machine.

## Verification

After applying the settings, restart Docker Desktop, then from a shell:

```bash
docker system info | grep -E 'CPUs|Memory|Total Memory'
# Expected with 70B-tier sizing:
#  CPUs: 12
#  Total Memory: 55.83GiB

docker system df
# Reports usage against the disk image limit; "Reclaimable" should be small
# on a fresh setup.

df -h /Volumes/OpusPopuli
# Shows the shared free-space pool (~900 GB on a fresh 1 TB SSD with the
# default macOS install + the OpusPopuli APFS volume).
```

## When to revisit

These settings hold for the lifetime of the Studio unless:

- You upgrade the LLM to a larger tier → recompute memory allocation
  from the table above.
- You add a second region's stack on the same Studio → roughly double
  the postgres footprint; consider larger disk image.
- Docker Desktop ships a behavior change in a major version → check the
  release notes against this doc.

## Related

- [`mac-studio-bootstrap.md`](./mac-studio-bootstrap.md) — full Studio
  setup runbook (the create-op-node CLI automates most of this).
- `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` —
  default disk image location. Don't touch directly; use Docker Desktop's
  "Disk image location" setting to move it.
