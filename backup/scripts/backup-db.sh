#!/usr/bin/env bash
# Daily PostgreSQL backup for the opuspopuli stack.
#
# Modes:
#   - Scheduled: invoked by supercronic per /crontab (daily, 03:00 in TZ)
#   - Ad-hoc:    docker compose run --rm opuspopuli-backup /scripts/backup-db.sh
#
# Output:    opuspopuli-db-<git_sha>-<UTC_timestamp>.dump.gz in $BACKUPS_DIR
# Retention: deletes files older than $RETENTION_DAYS (default 7)
#
# Concurrency: takes a flock on $BACKUPS_DIR/.backup.lock so scheduled +
# ad-hoc runs never overlap. Ad-hoc blocks until the scheduled run
# finishes (set BACKUP_LOCK_WAIT=false to fail fast instead).
#
# Exit codes:
#   0  ok
#   1  pg_dump or gzip failed
#   3  $BACKUPS_DIR not writable
#   (retention-prune failures are non-fatal — logged, not propagated)

set -euo pipefail

BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
LOCK_FILE="${BACKUPS_DIR}/.backup.lock"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOCK_WAIT="${BACKUP_LOCK_WAIT:-true}"
GIT_SHA="${GIT_SHA:-unknown}"

log_json() {
  local line
  line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"backup\",$1}"
  echo "${line}"
  echo "${line}" >> "${BACKUPS_DIR}/backup.log" 2>/dev/null || true
}

# 1. Validate destination is writable before touching the DB.
if [[ ! -w "${BACKUPS_DIR}" ]]; then
  log_json "\"status\":\"error\",\"reason\":\"dest_not_writable\",\"dir\":\"${BACKUPS_DIR}\""
  exit 3
fi

# 2. Acquire the cross-mode lock. Scheduled + ad-hoc share it.
flock_opts="-x"
[[ "${LOCK_WAIT}" == "false" ]] && flock_opts="-xn"
exec 9>"${LOCK_FILE}"
if ! flock ${flock_opts} 9; then
  log_json "\"status\":\"skipped\",\"reason\":\"lock_held\""
  exit 0
fi

# 3. Compute snapshot filename. Atomic rename pattern via .partial.
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILENAME="opuspopuli-db-${GIT_SHA}-${TIMESTAMP}.dump.gz"
TMP_DUMP="${BACKUPS_DIR}/.${FILENAME}.partial"
FINAL_PATH="${BACKUPS_DIR}/${FILENAME}"
ERR_FILE="${BACKUPS_DIR}/.backup.lasterr"
START_MS="$(date +%s%3N)"

cleanup() {
  rm -f "${TMP_DUMP}"
}
trap cleanup EXIT

# 4. pg_dump (custom format) → gzip → partial file. PG* vars in env.
#    --compress=0 hands raw bytes to gzip -9 instead of pg_dump's
#    internal compressor — gzip -9 produces ~5% smaller archives.
if ! pg_dump --format=custom --no-owner --no-acl --compress=0 2> "${ERR_FILE}" \
     | gzip -9 > "${TMP_DUMP}"; then
  STDERR_TRUNCATED="$(tr '\n' ' ' < "${ERR_FILE}" 2>/dev/null | head -c 500 | sed 's/"/\\"/g')"
  log_json "\"status\":\"error\",\"reason\":\"pg_dump_or_gzip_failed\",\"stderr\":\"${STDERR_TRUNCATED}\""
  exit 1
fi

mv "${TMP_DUMP}" "${FINAL_PATH}"
BYTES="$(stat -c%s "${FINAL_PATH}" 2>/dev/null || stat -f%z "${FINAL_PATH}")"
DURATION_MS=$(( $(date +%s%3N) - START_MS ))

# 5. Prune snapshots older than retention window. Failures non-fatal.
PURGED=0
PURGE_LIST="$(mktemp)"
if find "${BACKUPS_DIR}" -maxdepth 1 -name 'opuspopuli-db-*.dump.gz' \
   -type f -mtime "+${RETENTION_DAYS}" -print -delete > "${PURGE_LIST}" 2>/dev/null; then
  PURGED=$(wc -l < "${PURGE_LIST}" | tr -d ' ')
else
  log_json "\"status\":\"warn\",\"reason\":\"retention_prune_failed\""
fi
rm -f "${PURGE_LIST}"

# 6. Success log. Both stdout (docker logs) and appended to backup.log.
log_json "\"status\":\"ok\",\"file\":\"${FILENAME}\",\"bytes\":${BYTES},\"duration_ms\":${DURATION_MS},\"git_sha\":\"${GIT_SHA}\",\"retention_days\":${RETENTION_DAYS},\"retention_purged\":${PURGED}"
