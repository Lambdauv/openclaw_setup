#!/usr/bin/env bash
# regraft-narrative-timeout.sh — re-apply the NARRATIVE_TIMEOUT_MS 60s→600s
# patch to memory-core's narrative-generation path after every
# `npm install -g openclaw@<newer>` (the upgrade re-extracts the bundled
# plugin and clobbers the patch).
#
# Why this patch exists:
#   memory-core fires light/rem/deep narrative-generation subagent calls
#   during the 3am dream cycle. The plugin hardcodes a 60s timeout
#   (NARRATIVE_TIMEOUT_MS = 6e4) which is too short for either DeepSeek
#   (router injects max-thinking; >2 min latencies) or Qwen3.6 (~30-60s
#   subagent boot overhead). All 3 phases timed out reproducibly.
#   600s is enough headroom for either model.
#
# Companion to:
#   - scripts/regraft-discord-extension.sh
#   - the Slack ping-timeout sed (documented in CLAUDE.md)
#
# Pattern: anchor by content (the exact pre-patch line), idempotent
# (--check before write), node --check for syntax, .openclaw-orig backup,
# --revert support.

set -euo pipefail

# Bundle filename hash changes every release (e.g. dxWrCDfd@5.7 -> Cyv7G2PG@5.20),
# so resolve dreaming-phases-*.js by glob instead of hardcoding the hash.
PLUGIN_DIR="/home/openclaw/.npm-global/lib/node_modules/openclaw/dist"
PLUGIN_JS="$(ls -t "$PLUGIN_DIR"/dreaming-phases-*.js 2>/dev/null | head -1 || true)"
PRE_PATCH='const NARRATIVE_TIMEOUT_MS = 6e4;'
POST_PATCH='const NARRATIVE_TIMEOUT_MS = 6e5; /* PATCHED openclaw-narrative-timeout: 60s→600s; reapply via scripts/regraft-narrative-timeout.sh after npm upgrade */'
PATCH_MARKER='openclaw-narrative-timeout'   # matches both manual-applied and script-applied variants

RESTART=0
REVERT=0
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=1 ;;
    --revert)  REVERT=1 ;;
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [--restart] [--revert]

  --restart    systemctl --user restart openclaw-gateway after patching
  --revert     restore the pre-patch line from .openclaw-orig.* backup
               (does not restart unless --restart also given)
  --help       show this message

Idempotent: re-running on a patched file is a no-op. Re-running after a
clobbering npm upgrade re-applies the patch.
USAGE
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$PLUGIN_JS" ]]; then
  echo "ERR: plugin file not found at $PLUGIN_JS" >&2
  echo "     Has openclaw been installed via npm? Check:" >&2
  echo "       ls -la $(dirname "$PLUGIN_JS")" >&2
  exit 1
fi

if [[ $REVERT -eq 1 ]]; then
  BACKUP=$(ls -t "$PLUGIN_JS".openclaw-orig.* 2>/dev/null | head -1 || true)
  if [[ -z "$BACKUP" ]]; then
    echo "ERR: no .openclaw-orig.* backup found next to $PLUGIN_JS" >&2
    exit 1
  fi
  echo "Reverting from $BACKUP"
  cp "$BACKUP" "$PLUGIN_JS"
  node --check "$PLUGIN_JS"
  echo "Reverted; gateway will pick up the original on next restart."
else
  if grep -qF "$PATCH_MARKER" "$PLUGIN_JS"; then
    echo "Already patched (marker '$PATCH_MARKER' present); nothing to do."
  elif grep -qF "$PRE_PATCH" "$PLUGIN_JS"; then
    BACKUP="$PLUGIN_JS.openclaw-orig.$(date +%Y-%m-%d)"
    if [[ ! -f "$BACKUP" ]]; then
      cp "$PLUGIN_JS" "$BACKUP"
      echo "Backup: $BACKUP"
    fi
    # Use | as sed delimiter since the post-patch text contains /
    sed -i "s|$PRE_PATCH|$POST_PATCH|" "$PLUGIN_JS"
    node --check "$PLUGIN_JS"
    echo "Patched: NARRATIVE_TIMEOUT_MS 6e4 → 6e5 (60s → 600s)"
  else
    echo "ERR: pre-patch line not found and patch marker not present." >&2
    echo "     The plugin source may have changed shape — inspect line 148:" >&2
    sed -n '148p' "$PLUGIN_JS" >&2
    exit 1
  fi
fi

if [[ $RESTART -eq 1 ]]; then
  echo "Restarting openclaw-gateway..."
  systemctl --user restart openclaw-gateway
  sleep 3
  systemctl --user is-active openclaw-gateway
fi
