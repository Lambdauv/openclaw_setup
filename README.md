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
