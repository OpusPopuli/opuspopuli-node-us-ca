#!/usr/bin/env bash
# Daily PostgreSQL backup for the colocated prompt-service DB.
#
# The prompt-service runs its OWN postgres cluster (`opuspopuli-prompts-db`,
# volume `prompts-db-data`) — see docker-compose-prompt-service.yml. It is a
# separate bounded context from the main `opuspopuli-db`, so it needs its own
# snapshot. This script mirrors backup-db.sh but targets the prompts cluster.
#
# Only meaningful on nodes running the prompt-service overlay. On nodes
# WITHOUT it, opuspopuli-prompts-db is unreachable and this exits non-fatally
# with a `skipped` log line (so the daily cron entry is harmless there).
#
# Modes:
#   - Scheduled: invoked by supercronic per /crontab (daily, 03:10 in TZ)
#   - Ad-hoc:    docker compose run --rm opuspopuli-backup \
#                    /scripts/backup-prompts-db.sh
#
# Output:    opuspopuli-prompts-db-<git_sha>-<UTC_timestamp>.dump.gz
# Retention: deletes matching files older than $RETENTION_DAYS (default 7)
#
# Concurrency: shares the same flock as backup-db.sh / restore-db.sh so runs
# never overlap.
#
# Exit codes:
#   0  ok (or skipped because the prompts DB is unreachable)
#   1  pg_dump or gzip failed
#   3  $BACKUPS_DIR not writable

set -euo pipefail

BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
LOCK_FILE="${BACKUPS_DIR}/.backup.lock"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOCK_WAIT="${BACKUP_LOCK_WAIT:-true}"
GIT_SHA="${GIT_SHA:-unknown}"

# Prompts-DB connection. Defaults match docker-compose-prompt-service.yml:
# host opuspopuli-prompts-db, superuser role supabase_admin, DB prompt_service.
# Password reuses PROMPTS_DB_PASSWORD (the prompts cluster's superuser pw).
PROMPTS_PGHOST="${PROMPTS_PGHOST:-opuspopuli-prompts-db}"
PROMPTS_PGUSER="${PROMPTS_PGUSER:-supabase_admin}"
PROMPTS_PGDATABASE="${PROMPTS_PGDATABASE:-prompt_service}"
PROMPTS_PGPASSWORD="${PROMPTS_DB_PASSWORD:-${PROMPTS_PGPASSWORD:-}}"

log_json() {
  local line
  line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"backup_prompts\",$1}"
  echo "${line}"
  echo "${line}" >> "${BACKUPS_DIR}/backup.log" 2>/dev/null || true
}

# 1. Validate destination is writable before touching the DB.
if [[ ! -w "${BACKUPS_DIR}" ]]; then
  log_json "\"status\":\"error\",\"reason\":\"dest_not_writable\",\"dir\":\"${BACKUPS_DIR}\""
  exit 3
fi

# 2. Skip cleanly if the prompts DB isn't reachable (overlay not active on
#    this node). Non-fatal — keeps the shared cron entry harmless.
export PGHOST="${PROMPTS_PGHOST}"
export PGUSER="${PROMPTS_PGUSER}"
export PGDATABASE="${PROMPTS_PGDATABASE}"
export PGPASSWORD="${PROMPTS_PGPASSWORD}"
if ! pg_isready -q -h "${PROMPTS_PGHOST}" -U "${PROMPTS_PGUSER}" -d "${PROMPTS_PGDATABASE}"; then
  log_json "\"status\":\"skipped\",\"reason\":\"prompts_db_unreachable\",\"host\":\"${PROMPTS_PGHOST}\""
  exit 0
fi

# 3. Acquire the cross-mode lock shared with backup-db.sh / restore-db.sh.
flock_opts="-x"
[[ "${LOCK_WAIT}" == "false" ]] && flock_opts="-xn"
exec 9>"${LOCK_FILE}"
if ! flock ${flock_opts} 9; then
  log_json "\"status\":\"skipped\",\"reason\":\"lock_held\""
  exit 0
fi

# 4. Compute snapshot filename. Atomic rename pattern via .partial.
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILENAME="opuspopuli-prompts-db-${GIT_SHA}-${TIMESTAMP}.dump.gz"
TMP_DUMP="${BACKUPS_DIR}/.${FILENAME}.partial"
FINAL_PATH="${BACKUPS_DIR}/${FILENAME}"
ERR_FILE="${BACKUPS_DIR}/.backup-prompts.lasterr"
START_MS="$(date +%s%3N)"

cleanup() {
  rm -f "${TMP_DUMP}"
}
trap cleanup EXIT

# 5. pg_dump (custom format) → gzip → partial file.
if ! pg_dump --format=custom --no-owner --no-acl --compress=0 2> "${ERR_FILE}" \
     | gzip -9 > "${TMP_DUMP}"; then
  STDERR_TRUNCATED="$(tr '\n' ' ' < "${ERR_FILE}" 2>/dev/null | head -c 500 | sed 's/"/\\"/g')"
  log_json "\"status\":\"error\",\"reason\":\"pg_dump_or_gzip_failed\",\"stderr\":\"${STDERR_TRUNCATED}\""
  exit 1
fi

mv "${TMP_DUMP}" "${FINAL_PATH}"
BYTES="$(stat -c%s "${FINAL_PATH}" 2>/dev/null || stat -f%z "${FINAL_PATH}")"
DURATION_MS=$(( $(date +%s%3N) - START_MS ))

# 6. Prune prompts snapshots older than retention window. Failures non-fatal.
PURGED=0
PURGE_LIST="$(mktemp)"
if find "${BACKUPS_DIR}" -maxdepth 1 -name 'opuspopuli-prompts-db-*.dump.gz' \
   -type f -mtime "+${RETENTION_DAYS}" -print -delete > "${PURGE_LIST}" 2>/dev/null; then
  PURGED=$(wc -l < "${PURGE_LIST}" | tr -d ' ')
else
  log_json "\"status\":\"warn\",\"reason\":\"retention_prune_failed\""
fi
rm -f "${PURGE_LIST}"

# 7. Success log.
log_json "\"status\":\"ok\",\"file\":\"${FILENAME}\",\"bytes\":${BYTES},\"duration_ms\":${DURATION_MS},\"git_sha\":\"${GIT_SHA}\",\"retention_days\":${RETENTION_DAYS},\"retention_purged\":${PURGED}"
