# Backup service for the opuspopuli stack.
#
# Pinned to the SAME image tag as the production DB so that pg_dump /
# pg_restore versions are guaranteed to match the server. The 17.x
# series introduced format-version changes in custom dumps; using a
# different pg_dump major than the server would silently produce
# files the server can't restore.
#
# Must match docker-compose-prod.yml's opuspopuli-db image tag exactly.
FROM supabase/postgres:17.6.1.138

# supercronic — minimal-deps cron replacement we use as the in-container
# scheduler. Single static Go binary, logs jobs to stdout (so
# `docker logs opuspopuli-backup` shows scheduler activity directly,
# no syslog forwarding gymnastics).
#
# TARGETARCH is set automatically by BuildKit to the build platform's
# arch (`amd64` on x86 CI, `arm64` on the Mac Studio prod host). We map
# it to supercronic's `linux-<arch>` asset name and select the matching
# SHA256 from the per-arch checksum table below. This is what prevents
# the historical bug where a hardcoded `linux-amd64` binary landed in an
# arm64 image and died with "exec format error" on the Studio.
#
# SHA256 pins are a supply-chain safeguard — a tampered upstream binary
# fails the build loudly at install time. Both were verified against the
# v0.2.31 release assets; the amd64 SHA256 corresponds to the same binary
# as the previously-pinned amd64 SHA1 fb4242e9…ba7d2.
ARG SUPERCRONIC_VERSION=v0.2.31
ARG TARGETARCH
ARG SUPERCRONIC_SHA256_amd64=b3274a37a983a108345cbf2b86feb49f730e7cf4e9ba13ad364b7e5fad6fd573
ARG SUPERCRONIC_SHA256_arm64=099315b022d02031fb904aae2e6969d56268ee03015ab65c03075dc2b87f6bb2

# Fetch with ADD (native BuildKit download — no dependency on `curl` being
# present in the base image, which the previous `curl -fsSL` approach assumed).
# supercronic's asset is `supercronic-linux-<arch>` and TARGETARCH is exactly
# `amd64`/`arm64`, so the URL templates directly. A follow-up RUN selects the
# per-arch SHA256 and verifies with sha256sum (coreutils — always present).
ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH} /usr/local/bin/supercronic
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) SUPERCRONIC_SHA256="${SUPERCRONIC_SHA256_amd64}" ;; \
      arm64) SUPERCRONIC_SHA256="${SUPERCRONIC_SHA256_arm64}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic

# Bake the scripts into the image so it works standalone. The compose
# bind-mount over /scripts lets us iterate on script content without
# rebuilds during local development.
COPY scripts /scripts
COPY crontab.tmpl /crontab.tmpl
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /scripts/*.sh /entrypoint.sh

# flock, gzip, find, date are already in the base image.

# Default UID is the postgres image's `postgres` user; we keep that
# rather than rooting so file ownership on the bind-mounted /backups
# matches expected non-privileged ownership on the host.

ENTRYPOINT ["/entrypoint.sh"]
