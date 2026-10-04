#!/usr/bin/env bash
#
# regraft-discord-extension.sh — restore Discord channel support after
# OpenClaw 2026.5.x npm installs / upgrades wipe the grafted extension.
#
# Background: OpenClaw 2026.5.0+ npm package no longer ships
# dist/extensions/discord/ (cutover happened between 2026.4.29 and
# 2026.5.0; closed-as-not-planned upstream). The 2026.4.29 tarball
# still has the working extension — we copy it onto the current
# install, install the 3 missing npm deps with --no-save (preserves
# openclaw's own package.json so future upgrades stay clean), and
# re-apply the Slack ping-timeout patch which gets wiped on every
# npm install -g openclaw@<newer>.
#
# WHEN TO RUN:
#   1. After every `npm install -g openclaw@<newer>` upgrade.
#   2. After any gateway shutdown that triggered an "Invalid config"
#      cleanup (which empties dist/extensions/discord/ even though
#      node_modules/ deps survive).
#   3. As a one-shot recovery if `openclaw channels list` shows only
#      Signal + Slack (no Discord).
#
# IDEMPOTENT: re-running when the extension is already grafted is a
# no-op for the extension copy step but always re-checks deps + Slack
# patch. Safe to run repeatedly.
#
# REFERENCES:
#   ~/.claude/projects/-home-openclaw--openclaw/memory/feedback_openclaw_5x_dropped_discord.md
#   ~/.openclaw/CLAUDE.md (search for "graft" / "Discord")
#   github.com/openclaw/openclaw — the upstream regression (no issue
#   number bound; tracked in our local memory).
#
# USAGE:
#   bash ~/.openclaw/scripts/regraft-discord-extension.sh             # graft only
#   bash ~/.openclaw/scripts/regraft-discord-extension.sh --restart   # also restart gateway
#   bash ~/.openclaw/scripts/regraft-discord-extension.sh --verbose   # show every step

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
OPENCLAW_PKG="/home/openclaw/.npm-global/lib/node_modules/openclaw"
TARBALL_VERSION="2026.4.29"
TARBALL_PATH="/tmp/openclaw-${TARBALL_VERSION}.tgz"
EXTRACT_DIR="/tmp/oc-extract-${TARBALL_VERSION}"
DISCORD_DEPS=(
  "@discordjs/voice@^0.19.2"
  "discord-api-types@^0.38.47"
  "opusscript@^0.1.1"
)
SLACK_PATCH_FILE="${OPENCLAW_PKG}/node_modules/@slack/socket-mode/dist/src/SocketModeClient.js"

# ── Flags ─────────────────────────────────────────────────────────────
RESTART=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2 ; exit 2 ;;
  esac
done

log() { echo "[regraft-discord] $*" ; }
vlog() { [[ $VERBOSE -eq 1 ]] && echo "[regraft-discord]   $*" || true ; }

# ── 1. Sanity: openclaw package present ──────────────────────────────
if [[ ! -d "$OPENCLAW_PKG" ]]; then
  log "ERROR: openclaw package not found at $OPENCLAW_PKG"
  log "       (is OpenClaw installed via npm-global? `which openclaw` to debug)"
  exit 1
fi
INSTALLED_VERSION=$(node -e "console.log(require('${OPENCLAW_PKG}/package.json').version)" 2>/dev/null || echo "unknown")
log "OpenClaw installed: ${INSTALLED_VERSION}"

# ── 2. Source tarball: cache or download ─────────────────────────────
if [[ -s "$TARBALL_PATH" ]]; then
  log "Using cached tarball: $TARBALL_PATH ($(du -h "$TARBALL_PATH" | cut -f1))"
else
  log "Downloading openclaw@${TARBALL_VERSION} tarball..."
  cd /tmp && npm pack "openclaw@${TARBALL_VERSION}" --pack-destination=/tmp >/dev/null 2>&1
  if [[ ! -s "$TARBALL_PATH" ]]; then
    log "ERROR: npm pack failed (no $TARBALL_PATH on disk)"
    exit 1
  fi
  log "Downloaded $(du -h "$TARBALL_PATH" | cut -f1)"
fi

# ── 3. Extract discord/ extension dir ────────────────────────────────
EXTRACTED_DIR="${EXTRACT_DIR}/package/dist/extensions/discord"
if [[ ! -f "${EXTRACTED_DIR}/index.js" ]]; then
  log "Extracting dist/extensions/discord/ from tarball..."
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  cd "$EXTRACT_DIR"
  tar -xzf "$TARBALL_PATH" package/dist/extensions/discord/
  vlog "extracted to $EXTRACT_DIR"
else
  vlog "extracted source already present at $EXTRACT_DIR"
fi
EXPECTED_FILE_COUNT=$(find "$EXTRACTED_DIR" -type f | wc -l)
log "Source has $EXPECTED_FILE_COUNT files in extensions/discord/"

# ── 4. Copy onto current install ─────────────────────────────────────
TARGET_DIR="${OPENCLAW_PKG}/dist/extensions/discord"
if [[ -f "${TARGET_DIR}/index.js" ]]; then
  CURRENT_FILE_COUNT=$(find "$TARGET_DIR" -type f | wc -l)
  log "Discord extension already grafted ($CURRENT_FILE_COUNT files); refreshing copy"
else
  log "Discord extension MISSING from current install; grafting"
fi
mkdir -p "$TARGET_DIR"
cp -R "${EXTRACTED_DIR}/." "$TARGET_DIR/"
GRAFT_FILE_COUNT=$(find "$TARGET_DIR" -type f | wc -l)
log "Graft complete: $GRAFT_FILE_COUNT files in $TARGET_DIR/"

# ── 5. npm deps (--no-save preserves openclaw's package.json) ────────
log "Checking Discord npm deps in node_modules/..."
MISSING_DEPS=()
for dep_spec in "${DISCORD_DEPS[@]}"; do
  # strip the shortest @suffix so "@scope/pkg@^x.y.z" → "@scope/pkg" and "pkg@^x.y.z" → "pkg"
  dep_name="${dep_spec%@*}"
  dep_dir="${OPENCLAW_PKG}/node_modules/${dep_name}"
  if [[ -d "$dep_dir" ]]; then
    installed_v=$(node -e "console.log(require('${dep_dir}/package.json').version)" 2>/dev/null || echo "?")
    vlog "✓ ${dep_name} ${installed_v}"
  else
    log "  ✗ MISSING: ${dep_name}"
    MISSING_DEPS+=("$dep_spec")
  fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  log "Installing ${#MISSING_DEPS[@]} missing dep(s) with --no-save..."
  # --legacy-peer-deps: arborist's #loadPeerSet crashes ("Cannot read properties of
  # null (reading 'edgesOut')") resolving peers against openclaw's lockless global
  # tree (hit 2026-07-21 on both the 6.11 upgrade and the 5.20 rollback); legacy
  # mode skips the peer graph and installs cleanly.
  cd "$OPENCLAW_PKG" && npm install --no-save --legacy-peer-deps --no-audit --no-fund "${MISSING_DEPS[@]}" 2>&1 | tail -3
else
  log "All 3 Discord deps already present"
fi

# ── 6. Slack ping-timeout patch ──────────────────────────────────────
if [[ -f "$SLACK_PATCH_FILE" ]]; then
  if grep -q "clientPingTimeout = 30000" "$SLACK_PATCH_FILE" 2>/dev/null; then
    log "Slack ping-timeout patch already in place (clientPingTimeout=30000)"
  else
    log "Applying Slack ping-timeout patch (clientPingTimeout 5000→30000, serverPingTimeout 30000→60000)"
    sed -i.bak 's/clientPingTimeout = 5000/clientPingTimeout = 30000/; s/serverPingTimeout = 30000/serverPingTimeout = 60000/' "$SLACK_PATCH_FILE"
    if ! grep -q "clientPingTimeout = 30000" "$SLACK_PATCH_FILE" 2>/dev/null; then
      log "WARNING: patch may not have applied — verify manually:"
      log "  grep clientPingTimeout '$SLACK_PATCH_FILE'"
    fi
  fi
else
  log "WARNING: Slack SDK file not found at $SLACK_PATCH_FILE"
  log "         (skipping ping-timeout patch — may indicate a different package layout)"
fi

# ── 7. Optional restart ──────────────────────────────────────────────
if [[ $RESTART -eq 1 ]]; then
  log "Restarting openclaw-gateway service..."
  systemctl --user restart openclaw-gateway
  sleep 2
  STATE=$(systemctl --user is-active openclaw-gateway || echo "inactive")
  log "Gateway state: $STATE"
  if [[ "$STATE" != "active" ]]; then
    log "WARNING: gateway not active after restart — check journal:"
    log "  journalctl --user -u openclaw-gateway -n 20"
  fi
else
  log "Not restarting (use --restart to also restart the gateway)"
fi

# ── 8. Verify ────────────────────────────────────────────────────────
log "Verification:"
if [[ -f "${TARGET_DIR}/index.js" ]]; then
  log "  ✓ ${TARGET_DIR}/index.js present"
else
  log "  ✗ ${TARGET_DIR}/index.js MISSING — graft failed"
  exit 1
fi
log "  Now run: openclaw channels list  → should show Discord + Signal + Slack"
log "  And:    openclaw channels status discord  → should show bot:@SmallClaw connected"

log "Done."
