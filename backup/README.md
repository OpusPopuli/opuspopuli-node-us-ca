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
| `Dockerfile` | Builds the backup container. Inherits from `supabase/postgres:17.6.1.091` so `pg_dump` / `pg_restore` versions exactly match the production server. Installs supercronic as the in-container scheduler. |
| `entrypoint.sh` | Container entrypoint. Dispatches between **scheduler mode** (no args → supercronic + crontab) and **one-shot mode** (args → exec args). Ad-hoc invocations use one-shot. |
| `crontab` | supercronic-format schedule. Currently a single line: daily 03:00 backup. Edit here to change the schedule for all environments at once. |
| `scripts/backup-db.sh` | The daily backup. `pg_dump --format=custom` piped through `gzip -9` into a host bind-mounted directory. Atomic rename via `.partial`, cross-mode `flock`, JSON-structured log lines, configurable retention. |
| `scripts/restore-db.sh` | Operator-triggered restore. Two modes (`--quick` and `--full`) for schema-match vs schema-drift cases. Takes the same lock as backup-db.sh so a scheduled backup can't race a restore. |

## How the pieces fit together

```
┌──────────────────────────────────────────────────────────────────┐
│  Host filesystem                                                 │
│                                                                  │
│    ${BACKUPS_DIR_HOST}/                                          │
│    ├── opuspopuli-db-<sha>-<ts>.dump.gz   ← scheduled or ad-hoc  │
│    ├── opuspopuli-db-<sha>-<ts>.dump.gz                          │
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

`FROM supabase/postgres:17.6.1.091` (not generic `postgres:17-alpine`).
This guarantees `pg_dump` and `pg_restore` versions exactly match the
server. PostgreSQL custom-format dumps are not forward-compatible
across major-version mismatches; downgrade-side bugs are silent and
costly. If you bump the DB image version anywhere else in the stack,
bump it here too.

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

## Adding a new scheduled job

If you ever want to add a second scheduled task (e.g. a separate
audit-log dump):

1. Add a new script to `scripts/`
2. Add a line to `crontab` referencing it
3. Rebuild the image; deploy via `docker compose up -d --build`

The image is small enough that rebuilds are quick. Don't try to
reuse the same script for multiple schedules — keep one
script-per-purpose for clarity.

## Bumping supercronic

The version + SHA1 are build args in the Dockerfile. To bump:

```bash
# Fetch the new SHA1
curl -sL https://github.com/aptible/supercronic/releases/download/<NEW_VERSION>/supercronic-linux-amd64 | sha1sum

# Update SUPERCRONIC_VERSION and SUPERCRONIC_SHA1 in Dockerfile,
# then rebuild and verify
docker compose -f docker-compose-uat.yml \
               -f docker-compose-backup.yml \
               build --no-cache opuspopuli-backup
```

The SHA1 pin is a supply-chain safeguard — if upstream is ever
compromised, the build will fail loud at install time.

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
