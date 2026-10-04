#!/usr/bin/env bash
# sync-fixes-export.sh — mirror the OpenClaw deployment fixes (post-upgrade patch set, gateway heap-leak fix, memory
# hygiene, upstream issue draft) into a SECRETS-FREE export repo with its own history, and push it.
#
# WHY. ~/.openclaw itself can never be pushed: its history holds live credentials and >50 MB blobs (see
# scripts/pre-push-refuse.sh). Roger (2026-10-04): "make sure the memory-leak fix is always fixed and synced into our
# local and remote repo." The fix lives in ~/.openclaw (local repo) and is applied by openclaw-patch-check.timer; this
# script keeps a clean copy of the fix set on GitHub.
#
# WHAT IT DOES. Copies the file set below into $EXPORT (default ~/openclaw-setup-export, a separate git repo), refuses
# if any file matches a secret or personal-data pattern, commits when something changed, and pushes to $REMOTE.
#   --no-push   commit only
#   --check     scan + show what would change; no commit, no push
set -euo pipefail
SRC="$HOME/.openclaw"
EXPORT="${FIXES_EXPORT_DIR:-$HOME/openclaw-setup-export}"
REMOTE="${FIXES_EXPORT_REMOTE:-git@github.com:Lambdauv/openclaw_setup.git}"
BRANCH="${FIXES_EXPORT_BRANCH:-main}"
MODE="push"
for a in "$@"; do case "$a" in --no-push) MODE="commit" ;; --check) MODE="check" ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done

# published path -> source path (relative to ~/.openclaw unless absolute)
declare -A FILES=(
  ["POST-UPGRADE.md"]="POST-UPGRADE.md"
  ["scripts/post-upgrade.sh"]="scripts/post-upgrade.sh"
  ["scripts/regraft-discord-extension.sh"]="scripts/regraft-discord-extension.sh"
  ["scripts/regraft-exec-abort-listener.sh"]="scripts/regraft-exec-abort-listener.sh"
  ["scripts/regraft-narrative-timeout.sh"]="scripts/regraft-narrative-timeout.sh"
  ["scripts/regraft-qmd-fts-tokenizer.sh"]="scripts/regraft-qmd-fts-tokenizer.sh"
  ["scripts/regraft-stream-progress.sh"]="scripts/regraft-stream-progress.sh"
  ["scripts/regraft-subagent-timeout.sh"]="scripts/regraft-subagent-timeout.sh"
  ["scripts/gateway-memory-hygiene.py"]="scripts/gateway-memory-hygiene.py"
  ["scripts/test-gateway-memory-hygiene.py"]="scripts/test-gateway-memory-hygiene.py"
  ["scripts/sync-fixes-export.sh"]="scripts/sync-fixes-export.sh"
  ["docs/upstream/openclaw-exec-abort-listener-leak.md"]="docs/upstream/openclaw-exec-abort-listener-leak.md"
  ["systemd/openclaw-patch-check.service"]="$HOME/.config/systemd/user/openclaw-patch-check.service"
  ["systemd/openclaw-patch-check.timer"]="$HOME/.config/systemd/user/openclaw-patch-check.timer"
  ["systemd/openclaw-gateway-hygiene.service"]="$HOME/.config/systemd/user/openclaw-gateway-hygiene.service"
  ["systemd/openclaw-gateway-hygiene.timer"]="$HOME/.config/systemd/user/openclaw-gateway-hygiene.timer"
)
# Secrets AND personal data: a hit refuses the whole sync. Values are never printed, only file:line.
SECRET_RE='(xox[abp]-[0-9A-Za-z-]{10,}|AIza[0-9A-Za-z_-]{20,}|gh[pousr]_[0-9A-Za-z]{20,}|sk-[0-9A-Za-z]{20,}|Bearer [0-9A-Za-z._-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY|password[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']{6,}|token[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']{12,})'
PII_RE='(\+1[0-9]{10}|[A-Za-z0-9._%+-]+@(gmail|anyoncomputing)\.com)'

mkdir -p "$EXPORT"
if [[ ! -d "$EXPORT/.git" ]]; then git -C "$EXPORT" init -q -b "$BRANCH"; fi
bad=0
for pub in "${!FILES[@]}"; do
  src="${FILES[$pub]}"; [[ "$src" = /* ]] || src="$SRC/$src"
  [[ -f "$src" ]] || { echo "MISSING source: $src" >&2; bad=1; continue; }
  if grep -nE "$SECRET_RE" "$src" | cut -d: -f1 | sed "s#^#SECRET-PATTERN $src:#" | grep .; then bad=1; fi
  if grep -nE "$PII_RE" "$src" | cut -d: -f1 | sed "s#^#PERSONAL-DATA $src:#" | grep .; then bad=1; fi
done
[[ $bad -eq 0 ]] || { echo "REFUSED: fix the lines above (externalize to ~/.config/openclaw/operator.env) before syncing" >&2; exit 1; }
for pub in "${!FILES[@]}"; do
  src="${FILES[$pub]}"; [[ "$src" = /* ]] || src="$SRC/$src"
  mkdir -p "$EXPORT/$(dirname "$pub")"; cp -p "$src" "$EXPORT/$pub"
done
cat > "$EXPORT/README.md" <<'EOF_README'
# openclaw_setup — deployment fixes for OpenClaw (secrets-free export)

What this is: the local patches an Anyon OpenClaw deployment applies on top of the npm-installed OpenClaw bundle, the script
that re-applies them after every `npm install -g openclaw@<newer>` (`scripts/post-upgrade.sh`, run by
`systemd/openclaw-patch-check.timer` every 30 min with `--autoheal`), the gateway memory-hygiene watchdog, and the draft of
the upstream bug report for the exec-tool heap leak (`docs/upstream/`).

The one that matters most: `scripts/regraft-exec-abort-listener.sh`. OpenClaw 2026.5.20's exec tool never removes its abort
listener, so every shell call pins its run context; the gateway heap grew ~100 MB/h and aborted at the 4 GB V8 limit every
1.5-3 days. The 3-line fix and the evidence are in `docs/upstream/openclaw-exec-abort-listener-leak.md`.

Apply on a box: `bash scripts/post-upgrade.sh --check` (verify) or `bash scripts/post-upgrade.sh` (reapply + restart). Install
the units from `systemd/` under `~/.config/systemd/user/` and enable the two timers. Alerts go to the Signal number in
`~/.config/openclaw/operator.env` (`HYGIENE_SIGNAL_TARGET`, `ROGER_SIGNAL`), which is deliberately NOT in this repo.

Provenance: mirrored from the live deployment by `scripts/sync-fixes-export.sh`, which refuses to export any file matching a
secret or personal-data pattern. This repo has its own history; the live deployment's repo is never pushed.
EOF_README
cd "$EXPORT"
git add -A .
if git diff --cached --quiet; then echo "export: nothing changed"; [[ "$MODE" = push ]] || exit 0; else
  git diff --cached --stat | tail -3
  [[ "$MODE" = check ]] && { git reset -q; echo "check mode: no commit"; exit 0; }
  git -c user.name="openclaw deployment" -c user.email="openclaw@localhost" commit -q -m "sync fixes export $(date '+%Y-%m-%d %H:%M %Z')"
  echo "committed $(git rev-parse --short HEAD)"
fi
[[ "$MODE" = push ]] || exit 0
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE"
git push -u origin "$BRANCH" 2>&1 | tail -2
echo "pushed $BRANCH -> $(git remote get-url origin) @ $(git rev-parse --short HEAD)"
