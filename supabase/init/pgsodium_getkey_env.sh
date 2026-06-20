#!/bin/bash
#
# pgsodium getkey script — env-driven replacement for the supabase/postgres
# image's default (which generates a random key inside the container
# filesystem on first start and re-generates on every container recreation).
#
# Why this matters: the default behavior means every `docker compose up -d
# --force-recreate --build opuspopuli-db` wipes the pgsodium master key,
# rendering every prior `vault.secrets` ciphertext permanently un-decryptable
# (pgsodium_crypto_aead_det_decrypt_by_id: invalid ciphertext). See issue
# #791 — discovered during PR #793 testing.
#
# This script reads `PGSODIUM_ROOT_KEY` (64 hex chars = 32 bytes) from the
# container environment and outputs it without a trailing newline, matching
# the format the original script produced (head -c 32 /dev/urandom | od -t x1
# | tr -d ' \n').
#
# Local UAT: PGSODIUM_ROOT_KEY defaults to a well-known dev value in
# docker-compose.yml. Prod (Supabase Cloud) doesn't use this script — Supabase
# manages key durability on the managed instance.
#
# Bind-mounted by docker-compose.yml over the image's
# /usr/lib/postgresql/bin/pgsodium_getkey.sh — the postgres GUC
# pgsodium.getkey_script (set in /etc/postgresql/postgresql.conf) already
# points at that path, so no postgresql.conf changes are needed.

set -euo pipefail

if [[ -z "${PGSODIUM_ROOT_KEY:-}" ]]; then
    echo "pgsodium_getkey_env: PGSODIUM_ROOT_KEY env var is not set." >&2
    echo "pgsodium_getkey_env: This will cause pgsodium to fail to load." >&2
    echo "pgsodium_getkey_env: Set PGSODIUM_ROOT_KEY (64 hex chars / 32 bytes) in docker-compose env." >&2
    exit 1
fi

# Validate format: pgsodium expects exactly 32 bytes encoded as 64 hex
# chars. A wrong length or non-hex value would fail later inside pgsodium
# with a less actionable error.
if ! [[ "$PGSODIUM_ROOT_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "pgsodium_getkey_env: PGSODIUM_ROOT_KEY must be exactly 64 hex chars (32 bytes)." >&2
    echo "pgsodium_getkey_env: Got length=${#PGSODIUM_ROOT_KEY}. Generate one with:" >&2
    echo "pgsodium_getkey_env:   head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \\n'" >&2
    exit 1
fi

printf -- '%s' "$PGSODIUM_ROOT_KEY"
