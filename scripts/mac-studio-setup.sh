#!/usr/bin/env bash
# =============================================================================
# Mac Studio production bootstrap — idempotent, safe to re-run.
#
# Automates Phases 3, 4, 5, 7, and 8-prep from
# docs/guides/mac-studio-bootstrap.md.
#
# Manual steps it CAN'T automate (it'll prompt you when you hit them):
#   - Phase 2: macOS Setup Assistant + System Settings (GUI)
#   - Phase 3.4: Docker Desktop GUI config (memory, disk image size)
#   - Phase 3.5: `gh auth login` (browser flow)
#   - Phase 3.6: Tailscale sign-in (menu bar)
#   - Phase 4.1: paste the pgsodium key + tunnel token (read -s)
#   - Phase 6: backup-restore drill (operational rehearsal)
#   - Phase 9: off-LAN verification + Pages re-point + browser sign-up
#
# Usage:
#   chmod +x scripts/mac-studio-setup.sh
#   ./scripts/mac-studio-setup.sh
# =============================================================================

set -euo pipefail

# ---------- helpers ----------
log()     { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail()    { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n%s\n  %s\n%s\n' "============================================" "$*" "============================================"; }
prompt()  { read -rp "→ $* [press Enter when done] " _; }

# ---------- preflight ----------
# Operator account name varies per region. We don't enforce a specific
# username — `$HOME` resolution + the LaunchAgent path are user-relative.
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
  || fail "this script targets Apple Silicon macOS"

OPUS_HOME="$HOME"
CONFIG_DIR="$OPUS_HOME/.config/opuspopuli"
KEY_FILE="$CONFIG_DIR/pgsodium_root_key"
LAUNCH_AGENT="$OPUS_HOME/Library/LaunchAgents/org.opuspopuli.envloader.plist"

# ============================================================================
# Phase 3 — Dev tooling
# ============================================================================
section "Phase 3 — Dev tooling"

if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
log "Homebrew: $(brew --version | head -1)"

log "Installing CLI tools (idempotent)..."
brew install git gh pnpm jq cloudflared rclone ollama

log "Installing Docker Desktop + Tailscale..."
brew install --cask docker tailscale

cat <<'MANUAL'

MANUAL STEPS — Docker Desktop:
  1. Open Docker Desktop from /Applications, accept EULA.
  2. Settings → General → "Start Docker Desktop when you sign in" ON.
  3. Settings → Resources → Memory: 40 GB.
  4. Settings → Resources → Disk image size: 200 GB.
     ⚠️  NEVER resize this later — resizing wipes all volumes.

MANUAL
prompt "Docker Desktop config done"

command -v docker >/dev/null 2>&1 || fail "docker not on PATH — restart shell"
log "Docker: $(docker --version)"

if ! gh auth status >/dev/null 2>&1; then
  echo
  echo "MANUAL — GitHub auth (browser flow opens):"
  gh auth login
fi
log "gh: signed in as $(gh api user --jq .login 2>/dev/null || echo unknown)"

cat <<'MANUAL'

MANUAL — Tailscale:
  1. Open Tailscale from the menu bar.
  2. Sign in to your tailnet.
  3. Accept this Studio as a node.
  4. Admin → Machines → enable SSH for this node.

MANUAL
prompt "Tailscale signed in"

# ============================================================================
# Phase 4 — pgsodium key + LaunchAgent
# ============================================================================
section "Phase 4 — pgsodium key + LaunchAgent"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ -s "$KEY_FILE" ]] && [[ "$(wc -c < "$KEY_FILE")" == "64" ]]; then
  log "key file already present ($KEY_FILE, 64 bytes)"
else
  echo
  echo "Paste the 64-hex pgsodium key from 1Password"
  echo "(opuspopuli-prod-pgsodium-root-key). Input is hidden."
  read -rs -p "  key: " PGSODIUM_KEY
  echo
  [[ ${#PGSODIUM_KEY} -eq 64 ]] || fail "expected 64 hex chars, got ${#PGSODIUM_KEY}"
  printf '%s' "$PGSODIUM_KEY" > "$KEY_FILE"
  unset PGSODIUM_KEY
  log "wrote $KEY_FILE"
fi
chmod 400 "$KEY_FILE"

echo
echo "Paste the Cloudflare Tunnel token from 1Password"
echo "(opuspopuli-prod-tunnel-token). Input is hidden."
echo "Press Enter alone to keep the existing token in the LaunchAgent."
read -rs -p "  token: " TUNNEL_TOKEN
echo

mkdir -p "$(dirname "$LAUNCH_AGENT")"
if [[ -n "$TUNNEL_TOKEN" ]]; then
  cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.opuspopuli.envloader</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>launchctl setenv PGSODIUM_ROOT_KEY "\$(cat $KEY_FILE)"; launchctl setenv TUNNEL_TOKEN "$TUNNEL_TOKEN"</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  unset TUNNEL_TOKEN
  chmod 600 "$LAUNCH_AGENT"
  log "wrote $LAUNCH_AGENT"
fi

launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
launchctl load "$LAUNCH_AGENT"
launchctl setenv PGSODIUM_ROOT_KEY "$(cat "$KEY_FILE")"
log "LaunchAgent loaded; env injected into current launchd session"
log "verify in a NEW shell after relogin: echo \${PGSODIUM_ROOT_KEY:0:8}"

cat <<'NEXT'

MANUAL — operator-secret seed SQL (used at Phase 8.3):
  Write /Users/opuspopuli/.config/opuspopuli/seed-operator-vault.sql (mode 0400)
  containing vault_create_secret() calls for RESEND_API_KEY, FEC_API_KEY,
  R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY.
  See docs/guides/mac-studio-bootstrap.md Phase 4 step 3 for the SQL template.

NEXT
prompt "seed-operator-vault.sql in place (or skip if seeding later)"

# ============================================================================
# Phase 5 — Sanity-check: we're inside the region deployment repo
# ============================================================================
section "Phase 5 — Sanity-check deployment repo layout"

# This script runs from the region's own deployment repo (e.g.
# <your-org>/opuspopuli-node-ca), which the operator already cloned before
# invoking it. There's nothing to clone here — the compose YAML, bind-mount
# sources, and Terraform code all live in this same working tree.
#
# Images for backend services + prompt-service come from ghcr.io (built in CI
# in the central OpusPopuli/opuspopuli + OpusPopuli/prompt-service repos and
# pulled to the Studio at Phase 8).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for required in docker-compose-prod.yml supabase/init/pgsodium_getkey_env.sh backup/scripts/backup-db.sh observability/prometheus.yml; do
  if [[ ! -e "$REPO_ROOT/$required" ]]; then
    fail "missing $required — is this script being run from the region deployment repo's working tree?"
  fi
done
log "deployment repo layout OK ($REPO_ROOT)"

# ============================================================================
# Phase 7 — Ollama
# ============================================================================
section "Phase 7 — Ollama"

brew services start ollama >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  if curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://localhost:11434/api/tags >/dev/null \
  || fail "Ollama not responding on :11434"

for model in qwen3.5:9b nomic-embed-text; do
  if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$model"; then
    log "$model already pulled"
  else
    log "pulling $model (may take several minutes)..."
    ollama pull "$model"
  fi
done

log "warming qwen3.5:9b..."
curl -s -X POST http://localhost:11434/api/generate \
     -d '{"model":"qwen3.5:9b","prompt":"hi","stream":false}' >/dev/null
log "Ollama ready"

# verify host.docker.internal from inside a container
docker run --rm alpine sh -c 'apk add --no-cache curl >/dev/null 2>&1 && curl -fsS http://host.docker.internal:11434/api/tags' >/dev/null \
  && log "container → host.docker.internal:11434 OK" \
  || log "WARN: containers can't reach Ollama via host.docker.internal — check Docker network settings"

# ============================================================================
# Phase 8 prep — docker login to ghcr.io
# ============================================================================
section "Phase 8 prep — ghcr.io login"

# Backend + prompt-service images are pulled from ghcr.io, not built locally.
# `gh auth token` gives us a PAT with packages:read scope (since gh signed in
# above), which Docker can use to authenticate to ghcr.io.
if gh auth token >/dev/null 2>&1; then
  gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
  log "logged in to ghcr.io"
else
  log "WARN: gh not authenticated — run 'gh auth login' then re-run this script"
fi

# ============================================================================
# Summary + next manual steps
# ============================================================================
cat <<DONE

============================================
  Bootstrap script complete.
============================================

✅ Automated:
   - Homebrew + CLI tools + casks (Docker Desktop, Tailscale)
   - pgsodium key file (mode 0400) + LaunchAgent (PGSODIUM_ROOT_KEY,
     TUNNEL_TOKEN injected into launchd env on every login/boot)
   - Ollama running, models pulled + warmed
   - Docker logged in to ghcr.io

⏭  Next (manual, from docs/mac-studio-bootstrap.md):

   1. Verify env in a NEW shell after re-login:
        echo \${PGSODIUM_ROOT_KEY:0:8}   # 8 hex chars
        echo \${TUNNEL_TOKEN:0:8}        # 8 chars

   2. Phase 6 — backup-restore drill (60 min rehearsal).

   3. Phase 8 — pull + start the stack from this repo:
        docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml \\
          pull
        docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml \\
          up -d

   5. Phase 8.3 — seed operator vault:
        docker compose exec opuspopuli-db psql -U postgres -d postgres \\
          < $CONFIG_DIR/seed-operator-vault.sql

   6. Phase 9 — Tunnel cutover + Pages re-point + off-LAN verify.

DONE
