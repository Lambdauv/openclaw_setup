#!/usr/bin/env bash
# regraft-cron-ontimer.sh — post-upgrade patch 8: let the gateway's cron scheduler start a job that falls due while an
# earlier batch is still running. Re-apply after every `npm install -g openclaw@<newer>` (the upgrade re-extracts the
# bundle and clobbers the patch). 2026.10.x rewrote the scheduler with run-slot admission and no longer needs this:
# when the bundle changes shape, both anchors go missing and the check reports MISSING (the auto-heal then pings).
#
# Why this patch exists (root-caused 2026-10-13 from the code; memory project_2026-10-13_cron_scheduler_blocks_behind_long_turns):
#   dist/server-cron-*.js onTimer() sets state.running, collects the jobs due at that instant, runs them, and clears the
#   flag and re-arms the timer only in `finally`, after the whole batch settles. A tick that fires meanwhile sees
#   state.running and returns. So cron.maxConcurrentRuns only parallelises jobs due in the SAME tick, and every cron that
#   falls due behind an hour-long agent turn (a job-resume dispatch, a 2-h wiki scan) waits for it. Measured 09-23..10-13:
#   the 15-min email monitor had 136 gaps over 45 min (max 290); 2026-10-14 08:20-10:2x one batch held it dark ~2 h.
#
# The patch (two edits; the upstream 2026.10.x design does the same thing with reservations):
#   A. server-cron-*.js onTimer: right after the due jobs are reserved (runningAtMs set and persisted under the lock),
#      clear state.running and re-arm the timer, so the next tick can start jobs that fall due while this batch runs.
#      isRunnableJob() already skips a job whose runningAtMs is set, so no job can run twice; store writes stay under
#      locked(); outcomes are applied by job id after a forceReload. Agent turns still pass through the "cron" command
#      lane, so cron.maxConcurrentRuns still caps how many run at once.
#   B. jobs-*.js nextWakeAtMs: skip jobs that are running. Their nextRunAtMs stays in the past until their outcome is
#      applied, so without B the timer armed by A would re-fire every 2 s for as long as a long job runs.
#
# Usage: regraft-cron-ontimer.sh [--check] [--restart] [--revert]
#   --check    exit 0 if both edits are present, 1 otherwise (prints which); changes nothing
#   --restart  systemctl --user restart openclaw-gateway after patching (only between agent turns)
#   --revert   restore both files from their .openclaw-orig.* backups
# Pattern: anchor by content (exact pre-patch fragment, count==1 guard), idempotent marker, node --check, dated
# .openclaw-orig backup, --revert. OPENCLAW_DIST overrides the bundle directory (tests run on a copy).

set -euo pipefail

DIST="${OPENCLAW_DIST:-/home/openclaw/.npm-global/lib/node_modules/openclaw/dist}"
MARKER='openclaw-cron-ontimer'
TAG="/* PATCHED $MARKER: see scripts/regraft-cron-ontimer.sh (2026-10-14) */"

PRE_A=$'\t\t\treturn due.map((j) => ({\n\t\t\t\tid: j.id,\n\t\t\t\tjob: j\n\t\t\t}));\n\t\t});\n\t\tconst runDueJob = async (params) => {'
POST_A=$'\t\t\treturn due.map((j) => ({\n\t\t\t\tid: j.id,\n\t\t\t\tjob: j\n\t\t\t}));\n\t\t});\n\t\tstate.running = false; armTimer(state); '"$TAG"$'\n\t\tconst runDueJob = async (params) => {'
PRE_B='const enabled = (state.store?.jobs ?? []).filter((j) => j.enabled && hasScheduledNextRunAtMs(j.state.nextRunAtMs));'
POST_B='const enabled = (state.store?.jobs ?? []).filter((j) => j.enabled && typeof j.state.runningAtMs !== "number" && hasScheduledNextRunAtMs(j.state.nextRunAtMs)); '"$TAG"

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

# Resolve the two bundle files by content (their hashes change every release): patched (marker) or pre-patch (anchor).
find_target() {  # $1 glob, $2 fixed-string anchor
  local f
  for f in $(ls -t $1 2>/dev/null); do
    case "$f" in *.openclaw-orig.*) continue ;; esac
    if grep -qF "$MARKER" "$f" || grep -qF "$2" "$f"; then echo "$f"; return 0; fi
  done
  return 1
}
TA="$(find_target "$DIST/server-cron-*.js" 'const runDueJob = async (params) => {' || true)"
TB="$(find_target "$DIST/jobs-*.js" "$PRE_B" || true)"

if [[ $CHECK -eq 1 ]]; then
  ok=0
  if [[ -n "$TA" ]] && grep -qF "$MARKER" "$TA"; then echo "A onTimer re-arm: PATCHED ($TA)"; else echo "A onTimer re-arm: MISSING"; ok=1; fi
  if [[ -n "$TB" ]] && grep -qF "$MARKER" "$TB"; then echo "B nextWakeAtMs skips running: PATCHED ($TB)"; else echo "B nextWakeAtMs skips running: MISSING"; ok=1; fi
  exit $ok
fi

if [[ -z "$TA" || -z "$TB" ]]; then
  echo "ERR: bundle shape changed; anchors not found (A=${TA:-none} B=${TB:-none})." >&2
  echo "     2026.10.x rewrote the scheduler (run-slot admission) and does not need this patch; check the installed version." >&2
  exit 1
fi

if [[ $REVERT -eq 1 ]]; then
  for t in "$TA" "$TB"; do
    b=$(ls -t "$t".openclaw-orig.* 2>/dev/null | head -1 || true)
    [[ -n "$b" ]] || { echo "ERR: no .openclaw-orig.* backup next to $t" >&2; exit 1; }
    cp "$b" "$t"; node --check "$t"; echo "Reverted $t from $b"
  done
  echo "Reverted; the gateway picks up the originals at its next restart."
else
  for t in "$TA" "$TB"; do
    if ! grep -qF "$MARKER" "$t"; then
      b="$t.openclaw-orig.$(date +%Y-%m-%d)"
      [[ -f "$b" ]] || { cp "$t" "$b"; echo "Backup: $b"; }
    fi
  done
  TA="$TA" TB="$TB" PRE_A="$PRE_A" POST_A="$POST_A" PRE_B="$PRE_B" POST_B="$POST_B" MARKER="$MARKER" python3 - <<'PY'
import os
for tgt, pre, post, name in ((os.environ["TA"], os.environ["PRE_A"], os.environ["POST_A"], "A onTimer re-arm"),
                             (os.environ["TB"], os.environ["PRE_B"], os.environ["POST_B"], "B nextWakeAtMs skips running")):
    s = open(tgt, encoding="utf-8").read()
    if os.environ["MARKER"] in s:
        print(f"{name}: already patched")
        continue
    n = s.count(pre)
    if n != 1:
        raise SystemExit(f"ERR: {name}: expected exactly 1 anchor in {tgt}, found {n}; refusing to patch")
    open(tgt, "w", encoding="utf-8").write(s.replace(pre, post))
    print(f"{name}: patched ({tgt})")
PY
  node --check "$TA"; node --check "$TB"
fi

if [[ $RESTART -eq 1 ]]; then
  echo "Restarting openclaw-gateway..."
  systemctl --user restart openclaw-gateway
  sleep 3
  systemctl --user is-active openclaw-gateway
fi
