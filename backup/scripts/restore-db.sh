#!/usr/bin/env bash
# Restore the postgres database from an opuspopuli pg_dump snapshot.
#
# Two modes, picked by the operator based on whether the snapshot's
# schema git_sha matches the current code's schema:
#
#   --quick  (fast path)
#     Assumes the snapshot's schema is identical to the current head.
#     Runs `pg_restore --clean --if-exists` in place. Fast.
#     Use when restoring from a snapshot taken against the same git SHA
#     as the currently-deployed code.
#
#   --full   (drift-safe path)
#     Drops + recreates the target DB, then pg_restores schema + data
#     from the dump. If the snapshot's git_sha is older than current,
#     the script prints the follow-up `db-migrate` command to bring the
#     schema forward to current head.
#
# Usage:
#   docker compose run --rm opuspopuli-backup /scripts/restore-db.sh \
#       --quick /backups/opuspopuli-db-<sha>-<ts>.dump.gz [--yes]
#   docker compose run --rm opuspopuli-backup /scripts/restore-db.sh \
#       --full  /backups/opuspopuli-db-<sha>-<ts>.dump.gz [--yes]
#
# Concurrency: takes the same flock as backup-db.sh so a scheduled
# backup can't land on a half-restored DB.

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: restore-db.sh (--quick | --full) <snapshot.dump.gz> [--yes]

  --quick   pg_restore --clean --if-exists; assumes schemas match
  --full    drop + recreate target DB, then pg_restore schema + data
  --yes     skip the destructive-action confirmation prompt

Snapshot filename shape: opuspopuli-db-<git_sha>-<timestamp>.dump.gz
EOF
  exit 64
}

MODE=""
SNAPSHOT=""
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) MODE="quick"; shift ;;
    --full)  MODE="full";  shift ;;
    --yes)   ASSUME_YES=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)  [[ -n "${SNAPSHOT}" ]] && { echo "Multiple snapshot files passed" >&2; usage; }
        SNAPSHOT="$1"; shift ;;
  esac
done

[[ -z "${MODE}" || -z "${SNAPSHOT}" ]] && usage
[[ ! -f "${SNAPSHOT}" ]] && { echo "Snapshot not found: ${SNAPSHOT}" >&2; exit 1; }

BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
LOCK_FILE="${BACKUPS_DIR}/.backup.lock"
TARGET_DB="${PGDATABASE:-postgres}"
TARGET_HOST="${PGHOST:-opuspopuli-db}"
CURRENT_SHA="${GIT_SHA:-unknown}"

# Pull the snapshot's git_sha out of the filename for drift detection.
SNAPSHOT_BASENAME="$(basename "${SNAPSHOT}")"
SNAPSHOT_SHA="$(echo "${SNAPSHOT_BASENAME}" | sed -nE 's/^opuspopuli-db-([^-]+)-[0-9TZ]+\.dump\.gz$/\1/p')"
[[ -z "${SNAPSHOT_SHA}" ]] && SNAPSHOT_SHA="unknown"

cat >&2 <<EOF
Restore plan:
  Snapshot file   : ${SNAPSHOT_BASENAME}
  Snapshot git_sha: ${SNAPSHOT_SHA}
  Current git_sha : ${CURRENT_SHA}
  Mode            : ${MODE}
  Target DB       : ${TARGET_DB}@${TARGET_HOST}

  This will DESTROY all data currently in ${TARGET_DB}.

EOF

# Quick-mode + sha mismatch is operator-error-prone. Warn loudly.
if [[ "${MODE}" == "quick" && "${SNAPSHOT_SHA}" != "${CURRENT_SHA}" && \
      "${SNAPSHOT_SHA}" != "unknown" && "${CURRENT_SHA}" != "unknown" ]]; then
  cat >&2 <<EOF
WARNING: snapshot git_sha (${SNAPSHOT_SHA}) does not match current (${CURRENT_SHA}).
         --quick assumes the schemas are identical. If they're not, the
         restore will leave the DB in an inconsistent state. Consider
         --full instead.

EOF
fi

if [[ "${ASSUME_YES}" != "true" ]]; then
  read -r -p "Proceed? (yes/no): " REPLY
  [[ "${REPLY}" != "yes" ]] && { echo "Aborted." >&2; exit 0; }
fi

# Cross-mode lock — blocks backups while we restore.
exec 9>"${LOCK_FILE}"
if ! flock -x 9; then
  echo "Failed to acquire restore lock" >&2
  exit 1
fi

START_MS="$(date +%s%3N)"

log_json() {
  local line
  line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"restore\",$1}"
  echo "${line}"
  echo "${line}" >> "${BACKUPS_DIR}/backup.log" 2>/dev/null || true
}

case "${MODE}" in
  quick)
    if ! gunzip -c "${SNAPSHOT}" | pg_restore --clean --if-exists \
         --no-owner --no-acl --dbname="${TARGET_DB}" --exit-on-error; then
      log_json "\"status\":\"error\",\"mode\":\"quick\",\"snapshot\":\"${SNAPSHOT_BASENAME}\""
      exit 1
    fi
    ;;

  full)
    # Postgres can't drop a database you're connected to, so issue the
    # DDL against `template1`. Terminate any other connections first so
    # the DROP DATABASE doesn't block on stragglers.
    if ! PGDATABASE="template1" psql -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${TARGET_DB}";
CREATE DATABASE "${TARGET_DB}";
SQL
    then
      log_json "\"status\":\"error\",\"mode\":\"full\",\"phase\":\"drop_create\",\"snapshot\":\"${SNAPSHOT_BASENAME}\""
      exit 1
    fi

    if ! gunzip -c "${SNAPSHOT}" | pg_restore \
         --no-owner --no-acl --dbname="${TARGET_DB}" --exit-on-error; then
      log_json "\"status\":\"error\",\"mode\":\"full\",\"phase\":\"pg_restore\",\"snapshot\":\"${SNAPSHOT_BASENAME}\""
      exit 1
    fi

    # Schema-drift advisory — operator follow-up.
    if [[ "${SNAPSHOT_SHA}" != "${CURRENT_SHA}" && \
          "${SNAPSHOT_SHA}" != "unknown" && "${CURRENT_SHA}" != "unknown" ]]; then
      cat >&2 <<EOF

Restore complete. NOTE: snapshot git_sha (${SNAPSHOT_SHA}) is older
than current (${CURRENT_SHA}). Apply Prisma migrations to bring the
schema forward to current head:

    docker compose -f docker-compose-uat.yml run --rm db-migrate

EOF
    fi
    ;;
esac

DURATION_MS=$(( $(date +%s%3N) - START_MS ))
log_json "\"status\":\"ok\",\"mode\":\"${MODE}\",\"snapshot\":\"${SNAPSHOT_BASENAME}\",\"snapshot_sha\":\"${SNAPSHOT_SHA}\",\"current_sha\":\"${CURRENT_SHA}\",\"duration_ms\":${DURATION_MS}"
