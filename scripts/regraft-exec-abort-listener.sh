#!/usr/bin/env bash
# regraft-exec-abort-listener.sh — re-apply the exec-tool abort-listener leak fix after every
# `npm install -g openclaw@<newer>` (the upgrade re-extracts the bundle and clobbers the patch).
#
# Why this patch exists (root-caused 2026-10-01 from two gateway heap snapshots):
#   The exec tool (dist/bash-tools-*.js) does
#       signal.addEventListener("abort", onAbortSignal, { once: true });
#   and never removes the listener when the command finishes. `once` only removes it if the signal FIRES.
#   The tool-call signal is a long-lived composite that Node keeps in gcPersistentSignals while it has
#   listeners, so every exec call left a listener whose closure pins the whole agent run context
#   (yieldTimer -> async-local store -> withSessionWriteLock -> params -> prepared -> cronSession.store,
#   i.e. a full parsed session store with every entry's ~23 KB skills prompt). Measured 03:09 -> 08:42:
#   onAbortSignal closures 56 -> 283 for 270 exec calls; live heap 522 -> 1090 MB; gateway V8 heap hit the
#   4 GB limit and aborted every 1.5-3 days (ABRT 09-21/24/26/27).
#   Fix: detach the listener when the command settles (after that, abort was already a no-op:
#   run.kill() on a finished process). Behaviour while the command runs is unchanged.
#
# Companion to the other regraft-*.sh scripts; wired into scripts/post-upgrade.sh (check_execabort).
#
# Pattern: anchor by content (exact pre-patch fragment, count==1 guard), idempotent marker, node --check,
# dated .openclaw-orig backup, --revert.

set -euo pipefail

DIST="${OPENCLAW_DIST:-/home/openclaw/.npm-global/lib/node_modules/openclaw/dist}"
# Bundle filename hash changes every release — resolve by glob, newest first.
TARGET="$(grep -lF 'signal.addEventListener("abort", onAbortSignal, { once: true });' "$DIST"/bash-tools-*.js 2>/dev/null | head -1 || true)"
PRE='signal.addEventListener("abort", onAbortSignal, { once: true });'
POST='signal.addEventListener("abort", onAbortSignal, { once: true }); if (signal) run.promise.then(() => signal.removeEventListener("abort", onAbortSignal), () => signal.removeEventListener("abort", onAbortSignal)); /* PATCHED openclaw-exec-abort-listener: detach on settle; the listener otherwise pins the whole run context forever (gateway heap leak, 2026-10-01). Reapply via scripts/regraft-exec-abort-listener.sh after npm upgrade */'
MARKER='openclaw-exec-abort-listener'

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
  echo "ERR: no bash-tools-*.js with the exec abort-listener anchor (already patched? check the marker; or the bundle changed)" >&2
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
print("Patched: exec tool now detaches its abort listener when the command settles")
PY
  node --check "$TARGET"
else
  echo "ERR: pre-patch fragment not found and marker absent." >&2
  echo "     Bundle shape may have changed — inspect the exec tool's onAbortSignal in:" >&2
  echo "       $TARGET" >&2
  exit 1
fi

if [[ $RESTART -eq 1 ]]; then
  echo "Restarting openclaw-gateway..."
  systemctl --user restart openclaw-gateway
  sleep 3
  systemctl --user is-active openclaw-gateway
fi
