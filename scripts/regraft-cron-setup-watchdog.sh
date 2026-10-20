#!/usr/bin/env bash
# regraft-cron-setup-watchdog.sh — post-upgrade patch 9: let a cron agent run survive a long wait in the gateway's
# `cron-nested` command lane. Re-apply after every `npm install -g openclaw@<newer>` (the upgrade re-extracts the
# bundle and clobbers the patch).
#
# Why this patch exists (root-caused 2026-10-20 from the code and the gateway log):
#   dist/server-cron-*.js (src/cron/service/timer.ts) arms CRON_AGENT_SETUP_WATCHDOG_MS = 6e4 when a run starts with
#   deferUntilRunner and fires "cron: isolated agent setup timed out before runner start" if the runner has not started
#   60 s later. The runner starts only once the run is ADMITTED to the `cron-nested` lane, whose concurrency is
#   cron.maxConcurrentRuns, so the 60 s also counts the time spent queued behind long agent turns (1-h job-resume
#   dispatches, 2-h verifier runs, 1-h wiki/Dream/Knowledge turns). When a holder finishes, the whole queue is admitted
#   at once and every run whose wait exceeded 60 s dies in the same second (the "lane wait exceeded ... AbortError"
#   bursts: 12 in 10-17..10-19). Census 10-13..10-20: 70 Task Monitor + 36 email monitor + 11 other runs died this way,
#   plus design-agent dispatches and verifier runs. A run that waited 28 min and then ran would have been late, not dead.
#
# The patch (one edit): CRON_AGENT_SETUP_WATCHDOG_MS 6e4 -> 36e5 (60 min). The pre-execution watchdog (runner started,
# no model call) and the job timeout (payload.timeoutSeconds) are untouched, so a run that is admitted still has its
# own ceilings; only the queue wait is allowed to be long. A job whose previous run is still running is not re-fired
# (runningAtMs guards it), so a late monitor run does not stack with the next one.
#
# Usage: regraft-cron-setup-watchdog.sh [--check] [--restart] [--revert]
#   --check    exit 0 if the edit is present, 1 otherwise; changes nothing
#   --restart  systemctl --user restart openclaw-gateway after patching (only between agent turns; the running gateway
#              keeps the old constant until it restarts)
#   --revert   restore the file from its .openclaw-orig.* backup
# Pattern (as patches 7 and 8): anchor by content (exact pre-patch fragment, count==1 guard), idempotent marker,
# node --check, dated .openclaw-orig backup, --revert. OPENCLAW_DIST overrides the bundle directory (tests run on a copy).

set -euo pipefail

DIST="${OPENCLAW_DIST:-/home/openclaw/.npm-global/lib/node_modules/openclaw/dist}"
MARKER='openclaw-cron-setup-watchdog'
TAG="/* PATCHED $MARKER: see scripts/regraft-cron-setup-watchdog.sh (2026-10-20) */"

PRE='const CRON_AGENT_SETUP_WATCHDOG_MS = 6e4;'
POST='const CRON_AGENT_SETUP_WATCHDOG_MS = 36e5; '"$TAG"

CHECK=0; RESTART=0; REVERT=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --restart) RESTART=1 ;;
    --revert) REVERT=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Resolve the bundle file by content (its hash changes every release): patched (marker) or pre-patch (anchor).
find_target() {
  local f
  for f in $(ls -t "$DIST"/server-cron-*.js 2>/dev/null); do
    case "$f" in *.openclaw-orig.*) continue ;; esac
    if grep -qF "$MARKER" "$f" || grep -qF "$PRE" "$f"; then echo "$f"; return 0; fi
  done
  return 1
}
T="$(find_target || true)"

if [[ $CHECK -eq 1 ]]; then
  if [[ -n "$T" ]] && grep -qF "$MARKER" "$T"; then echo "setup watchdog 60 min: PATCHED ($T)"; exit 0; fi
  echo "setup watchdog 60 min: MISSING"; exit 1
fi

if [[ -z "$T" ]]; then
  echo "ERR: bundle shape changed; anchor not found in $DIST/server-cron-*.js (neither '$PRE' nor the marker)." >&2
  echo "     Check the installed version: a scheduler that arms the setup watchdog at lane admission does not need this." >&2
  exit 1
fi

if [[ $REVERT -eq 1 ]]; then
  b=$(ls -t "$T".openclaw-orig.* 2>/dev/null | head -1 || true)
  [[ -n "$b" ]] || { echo "ERR: no .openclaw-orig.* backup next to $T" >&2; exit 1; }
  cp -p "$b" "$T" && echo "reverted $T from $(basename "$b")"
  [[ $RESTART -eq 1 ]] && systemctl --user restart openclaw-gateway && echo "gateway restarted"
  exit 0
fi

if grep -qF "$MARKER" "$T"; then
  echo "already patched: $T"
else
  n=$(grep -cF "$PRE" "$T" || true)
  [[ "$n" == "1" ]] || { echo "ERR: anchor count $n != 1 in $T; refusing to patch." >&2; exit 1; }
  cp -p "$T" "$T.openclaw-orig.$(date +%Y%m%dT%H%M%S)"
  python3 - "$T" "$PRE" "$POST" <<'EOF'
import sys
p, pre, post = sys.argv[1:4]
s = open(p).read()
assert s.count(pre) == 1
open(p, 'w').write(s.replace(pre, post, 1))
EOF
  node --check "$T" || { echo "ERR: node --check failed; restoring backup" >&2; cp -p "$(ls -t "$T".openclaw-orig.* | head -1)" "$T"; exit 1; }
  echo "patched $T: CRON_AGENT_SETUP_WATCHDOG_MS 6e4 -> 36e5"
fi
grep -oF "$POST" "$T" >/dev/null && echo "verify: $(grep -oE 'const CRON_AGENT_SETUP_WATCHDOG_MS = [0-9e]+' "$T")"

if [[ $RESTART -eq 1 ]]; then
  systemctl --user restart openclaw-gateway && echo "gateway restarted (the new constant is live)"
else
  echo "note: the running gateway keeps 6e4 until it restarts (use scripts/gateway-restart-when-idle.py between turns)"
fi
