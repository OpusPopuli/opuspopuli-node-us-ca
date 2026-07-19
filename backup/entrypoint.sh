#!/usr/bin/env bash
# Container entrypoint. Two roles, picked by argv:
#
#   No args     → scheduler mode: supercronic reads /crontab and fires
#                  jobs at the scheduled times.
#
#   Any args    → one-shot mode: exec the args. This is how operators
#                  trigger ad-hoc runs:
#                    docker compose run --rm opuspopuli-backup \
#                        /scripts/backup-db.sh
#                    docker compose run --rm opuspopuli-backup \
#                        /scripts/restore-db.sh --quick /backups/...
set -euo pipefail

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

# Render the live crontab from the schedule env vars. Defaults preserve the
# historical 03:00 / 03:10 daily behavior, so a node that sets neither var
# behaves exactly as before. Rendered to a writable path because the container
# runs as the non-root `postgres` user and can't overwrite the baked /crontab.tmpl.
: "${BACKUP_SCHEDULE:=0 3 * * *}"
: "${BACKUP_PROMPTS_SCHEDULE:=10 3 * * *}"
CRONTAB_RENDERED="${CRONTAB_RENDERED:-/tmp/opuspopuli-crontab}"
# `|` delimiter avoids clashing with `/scripts/...`; cron values contain no `|`.
sed -e "s|@BACKUP_SCHEDULE@|${BACKUP_SCHEDULE}|" \
    -e "s|@BACKUP_PROMPTS_SCHEDULE@|${BACKUP_PROMPTS_SCHEDULE}|" \
    /crontab.tmpl > "${CRONTAB_RENDERED}"

echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"scheduler_start\",\"backup_schedule\":\"${BACKUP_SCHEDULE}\",\"prompts_schedule\":\"${BACKUP_PROMPTS_SCHEDULE}\",\"crontab\":\"$(tr '\n' ';' < "${CRONTAB_RENDERED}" | sed 's/"/\\"/g')\"}"

# -passthrough-logs streams scheduled job stdout/stderr through
# supercronic to container stdout, so backup-db.sh's JSON log lines
# surface in `docker logs opuspopuli-backup`.
exec /usr/local/bin/supercronic -passthrough-logs "${CRONTAB_RENDERED}"
