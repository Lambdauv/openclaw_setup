#!/usr/bin/env bash
# post-upgrade.sh — reapply ALL OpenClaw post-upgrade patches.
#
# Every `npm install -g openclaw@<newer>` (manual OR auto-upgrade) re-extracts
# the npm package and CLOBBERS the bundled-JS patches + drops the Discord
# extension + uninstalls the Slack plugin. Run this after every upgrade.
#
# Authoritative checklist: POST-UPGRADE.md
#
# Modes:
#   (default)  apply every patch idempotently, restart the gateway once if
#              anything changed, then verify.
#   --check    verify only; print a table; exit 0 if all present, non-zero
#              (= number missing) otherwise. No changes, no restart.
#   --alert    run --check; if anything is missing, Signal-alert Roger + log.
#              No changes, no restart. (Used by the openclaw-patch-check timer.)
#
# Each underlying regraft script is idempotent (marker-guarded, node --check,
# dated backup, --revert). See POST-UPGRADE.md for per-patch detail.

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

OC="$HOME/.openclaw"
SCRIPTS="$OC/scripts"
DIST="$HOME/.npm-global/lib/node_modules/openclaw/dist"
SLACK_PLUGIN="$OC/npm/node_modules/@openclaw/slack"
QMD_STORE="$HOME/.npm-global/lib/node_modules/@tobilu/qmd/dist/store.js"
# Operator Signal target: from the environment, or ~/.config/openclaw/operator.env (untracked, chmod 600). Never a literal here:
# this script is mirrored to the fixes export repo. Empty = log the ping instead of sending it.
[[ -f "$HOME/.config/openclaw/operator.env" ]] && set -a && source "$HOME/.config/openclaw/operator.env" && set +a
ROGER_SIGNAL="${ROGER_SIGNAL:-}"
LOG="$OC/logs/post-upgrade.log"

log(){ echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "$LOG"; }
send_ping(){ # $1=message. Set POST_UPGRADE_PING_DRYRUN=1 to log instead of send (for testing).
  if [[ "${POST_UPGRADE_PING_DRYRUN:-}" == "1" ]]; then log "[DRYRUN ping] $1"; return 0; fi
  if [[ -z "$ROGER_SIGNAL" ]]; then log "[ping skipped: ROGER_SIGNAL unset] $1"; return 0; fi
  openclaw message send --channel signal --target "$ROGER_SIGNAL" --message "$1" 2>&1 | tee -a "$LOG" || log "ping send failed"
}

# --- presence checks: 0 = patch present, 1 = missing ---
check_discord(){   [ -d "$DIST/extensions/discord" ]; }
check_narrative(){ grep -q "openclaw-narrative-timeout" "$DIST"/dreaming-phases-*.js 2>/dev/null; }
check_slack(){     [ -d "$SLACK_PLUGIN" ]; }
check_subagent(){  grep -q "openclaw-subagent-timeout" "$DIST"/agent-via-gateway-*.js 2>/dev/null; }
check_stream(){    grep -q "openclaw-stream-progress" "$DIST"/selection-*.js 2>/dev/null; }
check_qmdfts(){    grep -qF "split(/[.\/:-]+/)" "$QMD_STORE" 2>/dev/null; }   # qmd FTS dotted-identifier fix (clobbered on QMD upgrade)
check_execabort(){ grep -qF "openclaw-exec-abort-listener" "$DIST"/bash-tools-*.js 2>/dev/null; }   # exec-tool abort-listener leak fix (gateway heap, 2026-10-01)

PATCHES="discord narrative slack subagent stream qmdfts execabort"

# --- advisory presence (NOT a reapply patch): node-llama-cpp + embeddinggemma power
#     the LOCAL memorySearch embeddings provider. Installed as an upgrade-DURABLE global
#     sibling (npm i -g node-llama-cpp) + a model in $HOME — neither is clobbered by an
#     openclaw upgrade, so there is nothing to reapply. This only surfaces operator-error
#     deletion (npm prune -g / uninstall). LOG-ONLY: deliberately kept out of PATCHES /
#     verify_all so it never affects the patch-missing count or the auto-heal/ping state
#     machine. No-op (silent) when present. See POST-UPGRADE.md "Global siblings".
NLC_MODULE="$HOME/.npm-global/lib/node_modules/node-llama-cpp"
NLC_MODEL="$HOME/.node-llama-cpp/models/hf_ggml-org_embeddinggemma-300m-qat-Q8_0.gguf"
advisory_checks(){
  [ -d "$NLC_MODULE" ] || log "NOTE: node-llama-cpp global sibling missing — local memorySearch embeddings unavailable. Reinstall: NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm install -g node-llama-cpp@3.18.1"
  [ -f "$NLC_MODEL" ]  || log "NOTE: embeddinggemma GGUF missing — re-pull: npx --no node-llama-cpp pull --dir ~/.node-llama-cpp/models hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf"
}

verify_all(){ # prints a table; returns number missing
  local missing=0
  for p in $PATCHES; do
    if check_$p; then printf '  [ OK ]  %s\n' "$p"
    else printf '  [MISSING] %s\n' "$p"; missing=$((missing+1)); fi
  done
  return $missing
}

apply_all(){
  log "applying post-upgrade patches..."
  bash "$SCRIPTS/regraft-discord-extension.sh"  2>&1 | sed 's/^/  discord:   /' | tee -a "$LOG" || true
  bash "$SCRIPTS/regraft-narrative-timeout.sh"  2>&1 | sed 's/^/  narrative: /' | tee -a "$LOG" || true
  if ! check_slack; then
    log "installing Slack plugin..."; openclaw plugins install @openclaw/slack 2>&1 | sed 's/^/  slack:     /' | tee -a "$LOG" || true
  else log "Slack plugin already installed"; fi
  bash "$SCRIPTS/regraft-subagent-timeout.sh"   2>&1 | sed 's/^/  subagent:  /' | tee -a "$LOG" || true
  bash "$SCRIPTS/regraft-stream-progress.sh"    2>&1 | sed 's/^/  stream:    /' | tee -a "$LOG" || true
  bash "$SCRIPTS/regraft-qmd-fts-tokenizer.sh"  2>&1 | sed 's/^/  qmdfts:    /' | tee -a "$LOG" || true
  bash "$SCRIPTS/regraft-exec-abort-listener.sh" 2>&1 | sed 's/^/  execabort: /' | tee -a "$LOG" || true
}

MODE="apply"
case "${1:-}" in
  --check) MODE="check" ;;
  --alert) MODE="alert" ;;
  --autoheal) MODE="autoheal" ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  "") MODE="apply" ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

advisory_checks   # log-only; runs for every mode; never affects exit codes / ping state

if [[ "$MODE" == "check" ]]; then
  echo "OpenClaw post-upgrade patch status:"; verify_all; exit $?
fi

STATEF="$OC/.post-upgrade-patch-state"   # records the missing-set already handled (anti-spam / anti-loop)

if [[ "$MODE" == "alert" ]]; then        # detect + notify only (no changes)
  out="$(verify_all)"; missing=$?
  cur="$(echo "$out" | grep MISSING | awk '{print $2}' | sort | paste -sd,)"
  prev="$(cat "$STATEF" 2>/dev/null || true)"
  if [[ $missing -gt 0 ]]; then
    if [[ "$cur" != "$prev" ]]; then
      log "PATCH DRIFT ($missing missing: $cur) — alerting"
      send_ping "⚠️ OpenClaw post-upgrade patches missing: $cur. An upgrade likely clobbered them — run: bash ~/.openclaw/scripts/post-upgrade.sh"
      echo "$cur" > "$STATEF"
    else log "PATCH DRIFT ($cur) — already alerted; skipping"; fi
    exit "$missing"
  else
    [[ -n "$prev" ]] && { log "patches restored; clearing state"; rm -f "$STATEF"; }
    exit 0
  fi
fi

if [[ "$MODE" == "autoheal" ]]; then     # detect + reapply + restart + ONE ping (detection→completion)
  out="$(verify_all)"; missing=$?
  cur="$(echo "$out" | grep MISSING | awk '{print $2}' | sort | paste -sd,)"
  prev="$(cat "$STATEF" 2>/dev/null || true)"
  if [[ $missing -eq 0 ]]; then
    [[ -n "$prev" ]] && { log "patches healthy; clearing state"; rm -f "$STATEF"; }
    exit 0                                 # silent when healthy — no ping
  fi
  if [[ "$cur" == "$prev" ]]; then
    log "drift persists ($cur) — already healed+pinged this set; skipping to avoid a heal/ping loop"; exit "$missing"
  fi
  log "DRIFT detected ($cur) — auto-healing: reapply + restart"
  apply_all
  log "restarting gateway to load patches/plugin..."
  systemctl --user restart openclaw-gateway; sleep 4
  systemctl --user is-active openclaw-gateway | sed 's/^/  gateway: /' | tee -a "$LOG"
  after="$(verify_all)"; missing_after=$?
  if [[ $missing_after -eq 0 ]]; then
    log "auto-heal SUCCESS — all patches present"
    send_ping "🔧 OpenClaw auto-heal: an upgrade had clobbered patches ($cur) — reapplied + restarted the gateway; all 5 present now ✓"
    rm -f "$STATEF"
  else
    still="$(echo "$after" | grep MISSING | awk '{print $2}' | sort | paste -sd,)"
    log "auto-heal INCOMPLETE — still missing: $still"
    send_ping "⚠️ OpenClaw auto-heal: patches were missing ($cur); reapplied + restarted but $missing_after STILL missing ($still) — bundle shape likely changed, needs manual fix (POST-UPGRADE.md)."
    echo "$cur" > "$STATEF"                 # record so we don't re-heal/re-ping the same broken set every run
  fi
  exit "$missing_after"
fi

# default: apply
log "=== post-upgrade run (openclaw $(openclaw --version 2>/dev/null | head -1)) ==="
before="$(verify_all)"; missing_before=$?
echo "$before"
if [[ $missing_before -eq 0 ]]; then
  log "all patches already present; nothing to apply."
else
  apply_all
  log "restarting gateway to load patches/plugin..."
  systemctl --user restart openclaw-gateway; sleep 4
  systemctl --user is-active openclaw-gateway | sed 's/^/  gateway: /' | tee -a "$LOG"
fi
echo "=== final verification ==="; after="$(verify_all)"; missing_after=$?; echo "$after"
if [[ $missing_after -eq 0 ]]; then log "ALL PATCHES PRESENT ✓"; else log "STILL MISSING $missing_after — inspect POST-UPGRADE.md"; fi
exit "$missing_after"
