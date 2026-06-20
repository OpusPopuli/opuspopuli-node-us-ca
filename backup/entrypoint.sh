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

echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"scheduler_start\",\"crontab\":\"$(cat /crontab | tr '\n' ';' | sed 's/"/\\"/g')\"}"

# -passthrough-logs streams scheduled job stdout/stderr through
# supercronic to container stdout, so backup-db.sh's JSON log lines
# surface in `docker logs opuspopuli-backup`.
exec /usr/local/bin/supercronic -passthrough-logs /crontab
