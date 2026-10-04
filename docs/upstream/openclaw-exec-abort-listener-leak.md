# Upstream issue draft — NOT FILED (needs Roger's OK; external send)

**Title:** exec tool leaks one AbortSignal listener per call, pinning the agent run context; gateway V8 heap OOMs every 1.5-3 days (2026.5.20)

**Version:** OpenClaw 2026.5.20 (e510042), Node v22.22.2, Linux.

**Symptom:** under steady agent activity the gateway's V8 heap grows ~100 MB/h. It aborts at the 4 GB heap limit
every 1.5-3 days.

**Root cause:** in the exec tool (`dist/bash-tools-*.js`):

```js
signal.addEventListener("abort", onAbortSignal, { once: true });
```

Nothing removes this listener when the command finishes; `{ once: true }` removes it only if the signal fires. The
tool-call signal is a long-lived composite AbortSignal, and Node keeps it in `gcPersistentSignals` while it has
listeners. So every exec call leaves a listener whose closure pins the entire run context:
`onAbortSignal` -> `yieldTimer` -> async-local store -> `withSessionWriteLock` -> run params -> `prepared` ->
`cronSession.store`. That includes the parsed session store, with each entry's ~23 KB skills prompt.

**Evidence:**
- Two heap snapshots 5.5 h apart: live heap 522 -> 1090 MB; `onAbortSignal` closures 56 -> 283 for 270 exec calls;
  +10,379 copies of the skills-catalog prompt (+236 MB). The GC-root path (non-weak edges) is as above.
- A minimal Node harness leaves 1000 listeners after 1000 calls with the original code, and 0 with the fix.

**Fix** (applied locally since 2026-10-01; heap stable since, gateway RSS ~1.1-1.3 GB over 2+ days):

```js
signal.addEventListener("abort", onAbortSignal, { once: true });
if (signal) run.promise.then(
  () => signal.removeEventListener("abort", onAbortSignal),
  () => signal.removeEventListener("abort", onAbortSignal));
```

Behaviour while the command runs is unchanged. After the command settles, an abort was already a no-op (a kill on a
finished process).
