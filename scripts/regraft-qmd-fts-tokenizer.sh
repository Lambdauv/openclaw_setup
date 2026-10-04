#!/usr/bin/env bash
# regraft-qmd-fts-tokenizer.sh — patch qmd's FTS5 query builder so DOTTED identifiers
# (IPs, file extensions, dotted module/version strings, paths) are matched by the lexical
# (BM25) leg instead of being silently mangled.
#
# THE BUG (qmd 2.5.3, dist/store.js):
#   buildFTS5Query routes a plain term either through isHyphenatedToken()->sanitizeHyphenatedTerm()
#   (splits on '-' into an FTS5 phrase — so "DeepSeek-V4-Flash" works) OR falls to sanitizeFTS5Term()
#   which does replace(/[^\p{L}\p{N}'_]/gu,'') — STRIPPING dots/slashes/colons and concatenating.
#   The content is indexed with unicode61 (splits on '.'), so "192.168.88.254" is stored as tokens
#   192/168/88/254 but the query becomes the single token "192168888254" -> ZERO BM25 hits.
#   Proven on the live 7090-doc corpus: search "192.168.88.254" -> 0; search "192 168 88 254" -> 5.
#
# THE FIX: treat '.', '/', ':' the same way '-' is already treated — split into a phrase query.
#   isHyphenatedToken regex: also accept those separators internally.
#   sanitizeHyphenatedTerm:  split on /[.\/:-]+/ instead of '-'.
#
# This is a CLOBBERED-ON-UPGRADE qmd-dist patch: reapply after every `npm install -g @tobilu/qmd@*`.
# post-upgrade.sh checks/reapplies it (PATCHES var) and openclaw-patch-check.timer auto-heals it.
# Upstream PR proposal lives in docs/qmd-fts-dotted-identifiers-upstream.md — prefer that long-term.
#
# Modes:
#   (default)   apply the patch idempotently (backup + node --check)
#   --check     exit 0 if patched, 1 if not (no changes) — used by post-upgrade.sh
#   --revert    restore the dated .openclaw-orig backup
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

QMD_ROOT="$(npm root -g 2>/dev/null)/@tobilu/qmd"
[ -d "$QMD_ROOT" ] || QMD_ROOT="$HOME/.npm-global/lib/node_modules/@tobilu/qmd"
STORE="$QMD_ROOT/dist/store.js"
MARKER='[.\/:-]+'   # present only after patching (sanitizeHyphenatedTerm split)

is_patched(){ [ -f "$STORE" ] && grep -qF "split(/[.\/:-]+/)" "$STORE"; }

if [ ! -f "$STORE" ]; then echo "regraft-qmd-fts: store.js not found at $STORE (qmd not installed?)"; exit 2; fi

case "${1:-}" in
  --check)  is_patched && exit 0 || exit 1 ;;
  --revert)
    bak="$(ls -t "$STORE".openclaw-orig.* 2>/dev/null | head -1)"
    if [ -n "$bak" ]; then cp -p "$bak" "$STORE"; echo "regraft-qmd-fts: reverted from $bak"; else echo "regraft-qmd-fts: no backup to revert"; fi
    exit 0 ;;
esac

if is_patched; then echo "regraft-qmd-fts: already patched ✓"; exit 0; fi

cp -p "$STORE" "$STORE.openclaw-orig.$(date +%Y%m%dT%H%M%S)"

python3 - "$STORE" <<'PY'
import sys, re
p = sys.argv[1]
src = open(p, encoding='utf-8').read()
orig = src

# 1) isHyphenatedToken regex: accept internal . / : as well as -
old_re = r"""/^[\p{L}\p{N}][\p{L}\p{N}'-]*-[\p{L}\p{N}][\p{L}\p{N}'-]*$/u"""
new_re = r"""/^[\p{L}\p{N}][\p{L}\p{N}'.\/:-]*[.\/:-][\p{L}\p{N}][\p{L}\p{N}'.\/:-]*$/u"""
assert src.count(old_re) == 1, f"isHyphenatedToken regex anchor count={src.count(old_re)} (expected 1)"
src = src.replace(old_re, new_re)

# 2) sanitizeHyphenatedTerm: split on . / : - (not just -)
old_sp = "term.split('-').map(t => sanitizeFTS5Term(t))"
new_sp = "term.split(/[.\\/:-]+/).map(t => sanitizeFTS5Term(t))"
assert src.count(old_sp) == 1, f"split anchor count={src.count(old_sp)} (expected 1)"
src = src.replace(old_sp, new_sp)

assert src != orig, "no change applied"
open(p, 'w', encoding='utf-8').write(src)
print("  applied: isHyphenatedToken regex + sanitizeHyphenatedTerm split now cover . / : -")
PY

node --check "$STORE" && echo "regraft-qmd-fts: node --check OK ✓" || { echo "regraft-qmd-fts: node --check FAILED — reverting"; bak="$(ls -t "$STORE".openclaw-orig.* | head -1)"; cp -p "$bak" "$STORE"; exit 1; }
is_patched && echo "regraft-qmd-fts: PATCHED ✓" || { echo "regraft-qmd-fts: marker missing after patch?!"; exit 1; }
