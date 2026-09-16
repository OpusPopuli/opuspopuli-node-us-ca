#!/usr/bin/env bash
# Prometheus textfile-collector output for the backup jobs — opuspopuli#1217.
#
# Why this exists: production backups stopped on 2026-07-23 and nobody
# noticed for 49 days. Nothing in the deploy path restarts the backup
# container (op-deploy excludes docker-compose-backup.yml by design), so a
# node that is never redeployed can go quiet indefinitely. These gauges are
# what make that loud — see the opuspopuli-backups alert group in
# observability/prometheus-alerts.yml.
#
# node_exporter's textfile collector serves every .prom file in
# METRICS_DIR. Writes are atomic (tmp + mv) so a scrape can never observe a
# half-written file.
#
# Sourced by backup-db.sh and backup-prompts-db.sh. Never executed directly.

# metrics_init <database-label>
metrics_init() {
  METRICS_DB_LABEL="$1"
  METRICS_DIR="${METRICS_DIR:-${BACKUPS_DIR}/metrics}"
  METRICS_FILE="${METRICS_DIR}/backup_${METRICS_DB_LABEL}.prom"
}

# Last known success timestamp, so a FAILED run does not reset the clock.
# Keeping the old value is what lets `time() - last_success` keep growing
# and escalate BackupFailing (warning) into BackupStale (critical).
metrics_prev_success() {
  if [[ -r "${METRICS_FILE}" ]]; then
    awk '/^backup_last_success_timestamp_seconds/ {v=$2} END {print (v==""?0:v)}' \
      "${METRICS_FILE}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# metrics_write <status 1|0> <last_success_epoch> <bytes> <duration_seconds>
# Never fatal: a metrics failure must not fail an otherwise good backup.
metrics_write() {
  # NB: not named `status` — that is a read-only special variable in zsh,
  # which makes this file unsourceable there for no benefit.
  local ok_flag="$1" last_success="$2" bytes="$3" duration="$4"
  local tmp

  mkdir -p "${METRICS_DIR}" 2>/dev/null || return 0
  tmp="${METRICS_FILE}.$$"

  {
    echo "# HELP backup_last_status Whether the last backup attempt succeeded (1) or failed (0)."
    echo "# TYPE backup_last_status gauge"
    echo "backup_last_status{database=\"${METRICS_DB_LABEL}\"} ${ok_flag}"
    echo "# HELP backup_last_success_timestamp_seconds Unix time of the last SUCCESSFUL backup."
    echo "# TYPE backup_last_success_timestamp_seconds gauge"
    echo "backup_last_success_timestamp_seconds{database=\"${METRICS_DB_LABEL}\"} ${last_success}"
    echo "# HELP backup_last_size_bytes Size of the last successful backup artifact, in bytes."
    echo "# TYPE backup_last_size_bytes gauge"
    echo "backup_last_size_bytes{database=\"${METRICS_DB_LABEL}\"} ${bytes}"
    echo "# HELP backup_last_duration_seconds Wall-clock seconds the last successful backup took."
    echo "# TYPE backup_last_duration_seconds gauge"
    echo "backup_last_duration_seconds{database=\"${METRICS_DB_LABEL}\"} ${duration}"
  } > "${tmp}" 2>/dev/null || return 0

  mv -f "${tmp}" "${METRICS_FILE}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null
  return 0
}
