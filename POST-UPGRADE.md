# POST-UPGRADE.md — Reapply after EVERY OpenClaw upgrade

> **When:** after every `npm install -g openclaw@<newer>` — manual **or** auto-upgrade.
> Each upgrade re-extracts the npm package and **clobbers** the bundled-JS patches,
> drops the grafted Discord extension, and uninstalls the Slack plugin.
>
> **One command does it all (idempotent):**
> ```bash
> bash ~/.openclaw/scripts/post-upgrade.sh        # apply all + restart once + verify
> bash ~/.openclaw/scripts/post-upgrade.sh --check # verify only (table + exit code)
> ```
>
> **You don't have to remember — it auto-heals.** `openclaw-patch-check.timer` runs
> `post-upgrade.sh --autoheal` every ~30 min: if an upgrade has clobbered any patch it
> **automatically reapplies them, restarts the gateway, and sends Roger ONE Signal ping**
> covering both the detection and the result (e.g. *"🔧 clobbered patches (stream) —
> reapplied + restarted; all 5 present now ✓"*). Silent when healthy. If a reapply can't
> fix it (bundle shape changed in the new release), the single ping says so and points here.

This file is the authoritative checklist. CLAUDE.md points here; don't duplicate the list there.

## The patches (7)

> Patches 1–5 and 7 target **OpenClaw's** dist (clobbered on `npm install -g openclaw@*`). Patch 6 targets **qmd's** dist (clobbered on `npm install -g @tobilu/qmd@*`). Different upgrade triggers, but the **same auto-heal mechanism catches both** — `openclaw-patch-check.timer` verifies all 7 every ~30 min regardless of what clobbered them.

| # | Patch | Why it's needed | Reapply | Verify (present = patched) |
|---|-------|-----------------|---------|----------------------------|
| 1 | **Discord extension graft** | OpenClaw 2026.5.x ships without `dist/extensions/discord/`; graft the 2026.4.29 extension + 3 deps. Without it: no Discord. | `scripts/regraft-discord-extension.sh` | `ls -d ~/.npm-global/lib/node_modules/openclaw/dist/extensions/discord` |
| 2 | **narrative-timeout** | memory-core hardcodes `NARRATIVE_TIMEOUT_MS=6e4` (60s) — too short for any subagent boot + first token; 3am dream narratives all time out. Raise to `6e5` (600s). | `scripts/regraft-narrative-timeout.sh` | `grep -h openclaw-narrative-timeout dist/dreaming-phases-*.js` |
| 3 | **Slack plugin install** | Slack is an external plugin as of 5.20; the upgrade removes it. Without it the gateway pins the event loop retrying the configured-but-uninstalled account. | `openclaw plugins install @openclaw/slack` | `ls -d ~/.openclaw/npm/node_modules/@openclaw/slack` |
| 4 | **subagent-timeout** | Spawned subagents are hard-capped at a hardcoded **600s** per-run agent-timeout (`agent-via-gateway` `?? 600`); the 3600s config never propagates. Heavy chip-design subagents hard-fail. Patch `?? 600`→`?? 3600`. | `scripts/regraft-subagent-timeout.sh` | `grep -c openclaw-subagent-timeout dist/agent-via-gateway-*.js` |
| 5 | **stream-progress** | OpenClaw liveness only marks progress at model-call start/end — it never counts the streamed `thinking_delta` it already receives, so long DeepSeek reasoning trips the stall/stuck-recovery watchdogs. Patch emits a throttled `run.progress` on each real delta (keyed by `ctx.params.{runId,sessionId,sessionKey}`). | `scripts/regraft-stream-progress.sh` | `grep -c openclaw-stream-progress dist/selection-*.js` |
| 6 | **qmd-fts-tokenizer** (qmd dist) | qmd's BM25 leg is blind to **dotted identifiers** — `sanitizeFTS5Term` strips `.`/`/`/`:` and concatenates (`192.168.88.254`→`192168888254`→0 hits) while content is `unicode61`-tokenized on dots. Hyphens already phrase-split; dots/slashes/colons didn't. Patch makes `isHyphenatedToken`+`sanitizeHyphenatedTerm` treat `. / :` like `-` → phrase query → matches. Proven: IP/path/version searches 0→5 hits, no regression. **Upstream PR preferred long-term: `docs/qmd-fts-dotted-identifiers-upstream.md`.** | `scripts/regraft-qmd-fts-tokenizer.sh` | `grep -F 'split(/[.\/:-]+/)' ~/.npm-global/lib/node_modules/@tobilu/qmd/dist/store.js` |
| 7 | **exec-abort-listener** | The exec tool (`dist/bash-tools-*.js`) adds `signal.addEventListener("abort", onAbortSignal, { once: true })` and never removes it when the command finishes; the tool-call signal is long-lived, so EVERY agent shell command leaked a listener that pins the whole run context (incl. a full parsed session store, ~2.5 MB). Gateway V8 heap grew ~100 MB/h to the 4 GB limit → ABRT every 1.5–3 days (09-21/24/26/27). Root-caused 2026-10-01 from two heap snapshots (onAbortSignal closures 56→283 for 270 exec calls). Patch detaches the listener when `run.promise` settles (abort after completion was already a no-op). | `scripts/regraft-exec-abort-listener.sh` | `grep -c openclaw-exec-abort-listener dist/bash-tools-*.js` |

All seven regraft scripts are **idempotent** (marker-guarded, dated `.openclaw-orig` backup, `node --check`, `--revert`). `post-upgrade.sh` runs 1,2,4,5,6,7 + installs 3 if missing, restarts the gateway **once**, then verifies. (Patch 6 doesn't strictly need the restart — qmd is CLI-spawned per query — but the shared restart is harmless.)

## Global siblings that must persist (NOT reapply patches)

These are **upgrade-durable** — an `npm install -g openclaw@<newer>` only re-extracts the `openclaw/` subtree, so it does **not** touch independent global siblings or files in `$HOME`. There is **nothing to reapply**; they are listed only so an operator never `npm prune -g` / `npm uninstall -g`'s them. `post-upgrade.sh` logs a **NOTE** (advisory only — does *not* count toward the patch-missing total or trigger auto-heal) if either is gone.

| Dep | What / why | Reinstall if deleted |
|---|---|---|
| **`@tobilu/qmd@2.5.3`** (global sibling at `~/.npm-global/lib/node_modules/@tobilu/qmd`, bin `~/.npm-global/bin/qmd`) | The **active memory backend** (`memory.backend=qmd`) — OpenClaw spawns the `qmd` CLI for all 9 agents' recall (no version pin; CLI-integrated, parses `--json`). Runs embeddinggemma-300M + Qwen3-reranker-0.6B + qmd-query-expansion-1.7B via its OWN nested node-llama-cpp. `memory.qmd.searchMode=query` engages the full BM25+vec+HyDE+rerank pipeline (upgraded 2.1.0→2.5.3 + flipped vsearch→query on 2026-05-29; 2.5.x adopts legacy embeddinggemma vectors at distance 0 — no re-embed). If deleted, recall breaks for all agents (OpenClaw warns + returns []). | `npm install -g @tobilu/qmd@2.5.3` — then verify `qmd --version` + a `qmd vsearch "x" --json` before relying on it |
| **`node-llama-cpp@3.18.1`** (global sibling at `~/.npm-global/lib/node_modules/node-llama-cpp`) | Powers the **local** memorySearch embeddings provider (OpenClaw lazily `import()`s it; resolvable from `openclaw/dist` via the global-root in node's module walk — proven against the `pptxgenjs` sibling). Prebuilt CPU/Vulkan binary, no source build (no cmake needed). | `NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm install -g node-llama-cpp@3.18.1` |
| **embeddinggemma GGUF** (`~/.node-llama-cpp/models/hf_ggml-org_embeddinggemma-300m-qat-Q8_0.gguf`, ~314 MB) | The default local embedding model (`hf:ggml-org/...` — **ungated** mirror, 768-dim). Auto-downloads on first use if absent; pre-pulled so first use is a no-op. | `npx --no node-llama-cpp pull --dir ~/.node-llama-cpp/models hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf` |

> **Note:** `agents.defaults.memorySearch` is set to `enabled:true, provider:"local"` but is **inert** — while `memory.backend=qmd`, qmd self-embeds and the builtin memorySearch provider is never exercised (`Provider: qmd (requested: qmd)` in `openclaw memory status`). It is kept as a **dormant fallback**: if qmd is ever unavailable, OpenClaw degrades to builtin-on-embeddinggemma instead of failing. node-llama-cpp is NOT dead weight either way — it's the inference engine *inside* qmd. See memories `project_2026-05-29_node_llama_cpp_local_embeddings` + `project_2026-05-29_qmd_upgrade_and_query_mode`.

## Procedure

```bash
# after `npm install -g openclaw@<newer>`:
bash ~/.openclaw/scripts/post-upgrade.sh
# expect: final verification shows all 7 [ OK ], exit 0, "ALL PATCHES PRESENT ✓"
```

If `post-upgrade.sh` reports a patch **STILL MISSING** after running, its regraft script's content-anchor didn't match — the bundle shape changed in the new release. Open that regraft script, find the new anchor in the relevant `dist/*.js`, update `PRE`/`POST`, and re-run. (The bundle filename hashes change every release; the scripts already glob, so only the *content* anchor can break.)

## Rollback

Each patch: `bash scripts/regraft-<name>.sh --revert` (restores the dated `.openclaw-orig` backup). Slack plugin: `openclaw plugins uninstall @openclaw/slack`.

## Related

- Per-patch design + history: HANDOVER.md §5/§7/§9 and memory `project_subagent_timeout_600s_cap`, `project_memory_core_model_override_bug`, `feedback_openclaw_5x_dropped_discord`.
- Bundled-JS patch conventions: memory `feedback_bundled_js_patch_practices`.
- The auto-detector: `~/.config/systemd/user/openclaw-patch-check.{service,timer}` (copy in `migration/systemd/`).
