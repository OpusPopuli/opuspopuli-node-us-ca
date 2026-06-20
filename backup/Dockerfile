# Backup service for the opuspopuli stack.
#
# Pinned to the SAME image tag as the production DB so that pg_dump /
# pg_restore versions are guaranteed to match the server. The 17.x
# series introduced format-version changes in custom dumps; using a
# different pg_dump major than the server would silently produce
# files the server can't restore.
FROM supabase/postgres:17.6.1.091

# supercronic — minimal-deps cron replacement we use as the in-container
# scheduler. Single static Go binary, logs jobs to stdout (so
# `docker logs opuspopuli-backup` shows scheduler activity directly,
# no syslog forwarding gymnastics).
#
# Build args isolate version + checksum so they can be bumped via
# compose --build-arg without editing this file. Pin to a known SHA
# to detect tampering of the upstream binary.
ARG SUPERCRONIC_VERSION=v0.2.31
ARG SUPERCRONIC_ARCH=linux-amd64
ARG SUPERCRONIC_SHA1=fb4242e9d28528a76b70d878dbf69fe8d94ba7d2

ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-${SUPERCRONIC_ARCH} /usr/local/bin/supercronic
RUN echo "${SUPERCRONIC_SHA1}  /usr/local/bin/supercronic" | sha1sum -c - \
    && chmod +x /usr/local/bin/supercronic

# Bake the scripts into the image so it works standalone. The compose
# bind-mount over /scripts lets us iterate on script content without
# rebuilds during local development.
COPY scripts /scripts
COPY crontab /crontab
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /scripts/*.sh /entrypoint.sh

# flock, gzip, find, date are already in the base image.

# Default UID is the postgres image's `postgres` user; we keep that
# rather than rooting so file ownership on the bind-mounted /backups
# matches expected non-privileged ownership on the host.

ENTRYPOINT ["/entrypoint.sh"]
