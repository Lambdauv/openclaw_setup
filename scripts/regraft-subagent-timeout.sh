#!/usr/bin/env bash
# regraft-subagent-timeout.sh — re-apply the subagent per-run agent-timeout
# patch (600s → 3600s) after every `npm install -g openclaw@<newer>`
# (the upgrade re-extracts the bundle and clobbers the patch).
#
# Why this patch exists:
#   Spawned subagents (e.g. agent:research:subagent:*) resolve their agent-run
#   timeout in dist/agent-via-gateway-*.js via parseTimeoutSeconds():
#       opts.timeout ?? opts.cfg.agents?.defaults?.timeoutSeconds ?? 600
#   The subagent dispatch does NOT thread agents.defaults.timeoutSeconds
#   (=3600) into opts.cfg, so it falls through to the hardcoded 600s default.
#   Heavy chip-design subagents (large context + DeepSeek max-reasoning) run
#   >600s and get aborted mid-generation (timedOut:true, idleTimedOut:false,
#   while still emitting tokens), then HARD-fail because the OpenClaw fallback
#   chain is the same router endpoint (next=none / chain_exhausted).
#   Raising the fallback to 3600 matches agents.defaults.timeoutSeconds, the
#   provider timeoutSeconds, subagents.runTimeoutSeconds, and the router
#   sock_read — every other layer is already 3600s.
#   Root-caused 2026-05-24; upstream propagation bug filed (see HANDOVER §7).
#
# Companion to:
#   - scripts/regraft-narrative-timeout.sh
#   - scripts/regraft-discord-extension.sh
#
# Pattern: anchor by content (the exact pre-patch fragment), idempotent
# (marker check before write), node --check for syntax, dated .openclaw-orig
# backup, --revert support. Literal (non-regex) replace via python + a
# count==1 guard so it refuses to fire if the bundle shape changed.

set -euo pipefail

DIST="/home/openclaw/.npm-global/lib/node_modules/openclaw/dist"
# Bundle filename hash changes every release — resolve by glob, newest first.
TARGET="$(ls -t "$DIST"/agent-via-gateway-*.js 2>/dev/null | head -1 || true)"
PRE='opts.cfg.agents?.defaults?.timeoutSeconds ?? 600'
POST='opts.cfg.agents?.defaults?.timeoutSeconds ?? 3600 /* PATCHED openclaw-subagent-timeout: 600->3600; subagent dispatch does not thread agents.defaults.timeoutSeconds, so this fallback governs subagent run timeouts. Reapply via scripts/regraft-subagent-timeout.sh after npm upgrade */'
MARKER='openclaw-subagent-timeout'

RESTART=0; REVERT=0
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=1 ;;
    --revert)  REVERT=1 ;;
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [--restart] [--revert]

  --restart    systemctl --user restart openclaw-gateway after patching
  --revert     restore the pre-patch fragment from the .openclaw-orig.* backup
               (does not restart unless --restart also given)
  --help       show this message

Idempotent: re-running on a patched file is a no-op. Re-running after a
clobbering npm upgrade re-applies the patch.
USAGE
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$TARGET" ]]; then
  echo "ERR: target not found: $DIST/agent-via-gateway-*.js" >&2
  echo "     Has openclaw been installed via npm? Check: ls -la $DIST" >&2
  exit 1
fi

if [[ $REVERT -eq 1 ]]; then
  BACKUP=$(ls -t "$TARGET".openclaw-orig.* 2>/dev/null | head -1 || true)
  if [[ -z "$BACKUP" ]]; then
    echo "ERR: no .openclaw-orig.* backup found next to $TARGET" >&2
    exit 1
  fi
  echo "Reverting from $BACKUP"
  cp "$BACKUP" "$TARGET"
  node --check "$TARGET"
  echo "Reverted; gateway will pick up the original on next restart."
elif grep -qF "$MARKER" "$TARGET"; then
  echo "Already patched (marker '$MARKER' present); nothing to do."
elif grep -qF "$PRE" "$TARGET"; then
  BACKUP="$TARGET.openclaw-orig.$(date +%Y-%m-%d)"
  if [[ ! -f "$BACKUP" ]]; then
    cp "$TARGET" "$BACKUP"
    echo "Backup: $BACKUP"
  fi
  PRE="$PRE" POST="$POST" TARGET="$TARGET" python3 - <<'PY'
import os
t = os.environ['TARGET']; pre = os.environ['PRE']; post = os.environ['POST']
s = open(t, encoding='utf-8').read()
n = s.count(pre)
if n != 1:
    raise SystemExit(f"ERR: expected exactly 1 occurrence of anchor, found {n} — refusing to patch")
open(t, 'w', encoding='utf-8').write(s.replace(pre, post))
print("Patched: subagent agent-run timeout fallback 600 -> 3600")
PY
  node --check "$TARGET"
else
  echo "ERR: pre-patch fragment not found and marker absent." >&2
  echo "     Bundle shape may have changed — inspect parseTimeoutSeconds() in:" >&2
  echo "       $TARGET" >&2
  exit 1
fi

if [[ $RESTART -eq 1 ]]; then
  echo "Restarting openclaw-gateway..."
  systemctl --user restart openclaw-gateway
  sleep 3
  systemctl --user is-active openclaw-gateway
fi
