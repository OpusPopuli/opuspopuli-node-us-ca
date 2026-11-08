#!/usr/bin/env bash
# Install (or remove) the host memory probe as a per-user launchd agent (#1434).
#
#   scripts/host-memory-probe/install.sh            # install or update, then start
#   scripts/host-memory-probe/install.sh --uninstall
#
#   HOST_MEMORY_PROBE_NODE=/path/to/node   the node to run it with (default:
#                                          the first on PATH). create-op-node
#                                          passes the one it runs on.
#   HOST_MEMORY_PROBE_PORT=11500
#
# Exit 0 once the probe answers; non-zero, with the reason on stderr, if not.
#
# It runs as you, binds 127.0.0.1:${HOST_MEMORY_PROBE_PORT:-11500}, and starts at
# login. The node binary is resolved now and written into the plist, because
# launchd does not read your shell's PATH or nvm. The probe is COPIED into
# ~/Library/Application Support: macOS privacy controls stop a background agent
# from reading an external volume (where this repo lives on the dev Mac), and
# the agent would otherwise hang silently on its first read. Re-run this after
# changing Node versions or editing probe.ts.
set -euo pipefail

LABEL="org.opuspopuli.host-memory-probe"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
PORT="${HOST_MEMORY_PROBE_PORT:-11500}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "HOST_MEMORY_PROBE_PORT must be a number" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/opuspopuli/host-memory-probe"

unload() { launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; }
# Paths go into XML: a & or < in $HOME or the node path would break the plist.
# sed, not ${var//}: from bash 5.2 (Homebrew's) a bare & in a replacement
# means "the matched text", and a backslash before it survives on 3.2.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [[ "${1:-}" == "--uninstall" ]]; then
  unload
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  echo "Removed $LABEL"
  exit 0
fi

NODE="${HOST_MEMORY_PROBE_NODE:-$(command -v node || true)}"
[[ -n "$NODE" && -x "$NODE" ]] || { echo "node not found (set HOST_MEMORY_PROBE_NODE or put node on PATH)" >&2; exit 1; }
NODE="$(cd "$(dirname "$NODE")" && pwd -P)/$(basename "$NODE")"
# 22.6 is the first release that runs a .ts file with --experimental-strip-types.
"$NODE" -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 6) ? 0 : 1)' ||
  { echo "need Node 22.6 or later, found $("$NODE" -v)" >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")" "$INSTALL_DIR"
cp "$HERE/probe.ts" "$HERE/package.json" "$INSTALL_DIR/"
X_NODE="$(xml "$NODE")"; X_PROBE="$(xml "$INSTALL_DIR/probe.ts")"; X_LOG="$(xml "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$X_NODE</string>
    <string>--experimental-strip-types</string>
    <string>--no-warnings</string>
    <string>$X_PROBE</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>HOST_MEMORY_PROBE_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- A probe that keeps failing (e.g. the nvm Node it names was removed)
       restarts at most once a minute, not every 10 s into the log. -->
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$X_LOG</string>
  <key>StandardErrorPath</key><string>$X_LOG</string>
</dict>
</plist>
PLIST

unload
# bootstrap straight after bootout can fail with error 5 while launchd is
# still tearing the old job down; once more after a moment is enough.
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null ||
  { sleep 1; launchctl bootstrap "gui/$(id -u)" "$PLIST"; }

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:$PORT/memory" >/dev/null 2>&1; then
    echo "$LABEL running: http://127.0.0.1:$PORT/memory"
    exit 0
  fi
  sleep 0.5
done
echo "$LABEL did not answer on port $PORT; see $LOG" >&2
exit 1
