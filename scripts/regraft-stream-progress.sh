#!/usr/bin/env bash
# regraft-stream-progress.sh — make streamed model deltas count as liveness
# progress so long reasoning calls don't trip OpenClaw's stall-warning /
# stuck-session-recovery watchdogs. Reapply after every `npm install -g
# openclaw@<newer>` (the upgrade re-extracts the bundle and clobbers it).
#
# Background (root-caused + validated 2026-05-24):
#   DeepSeek-V4-Flash on vLLM DOES stream its thinking (delta.reasoning, TTFB
#   ~2s, continuous, max gap <4s — verified by direct probe), and OpenClaw's
#   transport surfaces it as `thinking_delta` events to the assistant-event
#   handler (handleMessageUpdate) in dist/selection-*.js. BUT OpenClaw liveness
#   (touchSessionActivity) only fires at model_call:started/ended — it never
#   counts the streaming. So long reasoning calls look "stuck".
#   This patch: on a real streamed delta (throttled 30s), emit a `run.progress`
#   diagnostic event (reused run.progress -> recordRunProgress ->
#   touchSessionActivity plumbing) keyed by the run's ids.
#   CRITICAL: the ids come from `ctx.params.{runId,sessionId,sessionKey}` —
#   the handler's own ctx.runId/sessionId are UNDEFINED (that was the bug in
#   the first attempt; ctx.params carries the run params, matching what the
#   watchdog keys the activity by via baseModelCallEvent).
#   Gated on a non-empty delta (a genuinely-hung call emits nothing -> still
#   flagged); try/catch so it can never break the stream; ctx-local throttle.
#   VALIDATED: a 143s reasoning call fired this 5x and logged ZERO stall warnings.
#
# Companion to regraft-subagent-timeout.sh / regraft-narrative-timeout.sh.
# Pattern: content anchor, idempotent (marker), node --check, dated
# .openclaw-orig backup, --revert, literal python replace + count==1 guard.

set -euo pipefail
DIST="/home/openclaw/.npm-global/lib/node_modules/openclaw/dist"
# target the selection bundle that actually contains the assistant-event handler
TARGET="$(grep -l 'const evtType = typeof assistantRecord' "$DIST"/selection-*.js 2>/dev/null | head -1 || true)"
MARKER='openclaw-stream-progress'
PRE='const evtType = typeof assistantRecord?.type === "string" ? assistantRecord.type : "";'
POST='const evtType = typeof assistantRecord?.type === "string" ? assistantRecord.type : ""; /* openclaw-stream-progress: streamed deltas count as liveness progress (throttled 30s, gated on real delta) so long reasoning calls do not trip the stall/stuck-recovery watchdogs; ids from ctx.params (handler ctx.runId is undefined). reapply/revert via scripts/regraft-stream-progress.sh after npm upgrade */ if (typeof assistantRecord?.delta === "string" && assistantRecord.delta.length > 0) { const __spNow = Date.now(); if (!ctx.__lastStreamProgressAt || __spNow - ctx.__lastStreamProgressAt >= 30000) { ctx.__lastStreamProgressAt = __spNow; const __p = ctx.params || {}; try { emitTrustedDiagnosticEvent({ type: "run.progress", reason: "model_call:streaming", runId: __p.runId, sessionId: __p.sessionId, sessionKey: __p.sessionKey }); } catch (e) {} } }'

RESTART=0; REVERT=0
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=1 ;;
    --revert)  REVERT=1 ;;
    -h|--help) cat <<USAGE
Usage: $(basename "$0") [--restart] [--revert]
  --restart    systemctl --user restart openclaw-gateway after patching
  --revert     restore the pre-patch file from the .openclaw-orig.* backup
  --help       show this message
Idempotent: re-running on a patched file is a no-op; re-run after an npm upgrade.
USAGE
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ -z "$TARGET" || ! -f "$TARGET" ]] && { echo "ERR: selection bundle with handler not found in $DIST" >&2; exit 1; }

if [[ $REVERT -eq 1 ]]; then
  BACKUP=$(ls -t "$TARGET".openclaw-orig.* 2>/dev/null | head -1 || true)
  [[ -z "$BACKUP" ]] && { echo "ERR: no .openclaw-orig.* backup next to $TARGET" >&2; exit 1; }
  echo "Reverting from $BACKUP"; cp "$BACKUP" "$TARGET"; node --check "$TARGET"; echo "Reverted."
elif grep -qF "$MARKER" "$TARGET"; then
  echo "Already patched (marker '$MARKER' present); nothing to do."
elif grep -qF "$PRE" "$TARGET"; then
  BACKUP="$TARGET.openclaw-orig.$(date +%Y-%m-%d)"
  [[ -f "$BACKUP" ]] || { cp "$TARGET" "$BACKUP"; echo "Backup: $BACKUP"; }
  PRE="$PRE" POST="$POST" TARGET="$TARGET" python3 - <<'PY'
import os
t=os.environ['TARGET']; pre=os.environ['PRE']; post=os.environ['POST']
s=open(t,encoding='utf-8').read()
n=s.count(pre)
if n!=1: raise SystemExit(f"ERR: expected exactly 1 occurrence of anchor, found {n} — refusing to patch")
open(t,'w',encoding='utf-8').write(s.replace(pre,post,1))
print("Patched: streamed deltas now emit throttled run.progress (liveness)")
PY
  node --check "$TARGET"
else
  echo "ERR: pre-patch anchor not found and marker absent — bundle shape changed." >&2; exit 1
fi

if [[ $RESTART -eq 1 ]]; then
  echo "Restarting openclaw-gateway..."; systemctl --user restart openclaw-gateway; sleep 3
  systemctl --user is-active openclaw-gateway
fi
