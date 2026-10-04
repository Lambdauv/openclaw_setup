#!/usr/bin/env python3
"""gateway-memory-hygiene.py — proactive, idle-aware gateway restart before heap death.

WHY: the OpenClaw 2026.5.20 gateway leaks memory (qmd runs its llama.cpp reranker IN-PROCESS in
query searchMode; rerank contexts accumulate): 37x V8-heap-OOM SIGABRT + 4x kernel OOM-kill between
2026-06-15 and 2026-07-16, each killing EVERY in-flight session — this is how long-horizon jobs died
silently. Until the leak is fixed upstream, convert unplanned mid-task crashes into PLANNED
idle-time restarts:

  SOFT (default 2.5 GB): restart ONLY if the gateway is idle — no session file activity in the last
        IDLE_WINDOW_MIN minutes AND no active task in `openclaw tasks list` (a turn blocked on a
        long exec touches NO session file; mtimes alone declared "idle" mid-julia-run on 2026-07-29
        and the restart SIGKILL'd the computation) — AND >= MIN_GAP_HOURS since the last hygiene
        restart. Task registry unverifiable counts as NOT idle. Silent.
  HARD (default 5 GB):   restart immediately regardless of activity (a controlled bounce beats
        swap-death + kernel OOM at 9 GB) + one Signal ping to Roger (rate-limited to 1/hour).

Scheduled by openclaw-gateway-hygiene.timer (OnCalendar every 10 min, wall-clock — the docs-check
OnUnitActiveSec deadlock lesson). No action unless a threshold trips; one status line per run.

State: ~/.openclaw/router-state/gateway-hygiene.state.json   Log: /tmp/openclaw-gateway-hygiene.log
Env knobs: HYGIENE_SOFT_GB, HYGIENE_HARD_GB, HYGIENE_MIN_GAP_HOURS, HYGIENE_IDLE_WINDOW_MIN,
           HYGIENE_SIGNAL_TARGET, HYGIENE_UNIT. Test hooks: HYGIENE_TEST_RSS_KB, HYGIENE_TEST_IDLE,
           HYGIENE_STATE, HYGIENE_LOG (and a PATH shim for systemctl/openclaw).
"""
import glob
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
UNIT = os.getenv("HYGIENE_UNIT", "openclaw-gateway.service")
SOFT_KB = float(os.getenv("HYGIENE_SOFT_GB", "2.5")) * 1048576
HARD_KB = float(os.getenv("HYGIENE_HARD_GB", "5")) * 1048576
MIN_GAP_S = float(os.getenv("HYGIENE_MIN_GAP_HOURS", "6")) * 3600
IDLE_WINDOW_MIN = int(os.getenv("HYGIENE_IDLE_WINDOW_MIN", "5"))
PING_GAP_S = float(os.getenv("HYGIENE_PING_GAP_HOURS", "1")) * 3600
SIGNAL_TARGET = os.getenv("HYGIENE_SIGNAL_TARGET", "")   # set in ~/.config/openclaw/operator.env (untracked); empty = log only
# RSS-floor trend alarm (2026-10-04): the patch check proves the patch TEXT is present, not that the leak is gone. A leak shows
# as a rising floor of RSS between busy spikes (the 09-21..10-01 leak: +100 MB/h). Samples live in the state file; the floor
# of each of TREND_BINS equal bins over TREND_WINDOW_H must rise by >= TREND_RISE_MB without a drop to alarm (one ping/day).
TREND_WINDOW_H = float(os.getenv("HYGIENE_TREND_WINDOW_H", "24"))
TREND_BINS = int(os.getenv("HYGIENE_TREND_BINS", "4"))
TREND_RISE_MB = float(os.getenv("HYGIENE_TREND_RISE_MB", "500"))
TREND_MIN_PER_BIN = int(os.getenv("HYGIENE_TREND_MIN_PER_BIN", "6"))
TREND_PING_GAP_S = float(os.getenv("HYGIENE_TREND_PING_GAP_H", "24")) * 3600
STATE = os.getenv("HYGIENE_STATE", os.path.join(HOME, ".openclaw/router-state/gateway-hygiene.state.json"))
LOG = os.getenv("HYGIENE_LOG", "/tmp/openclaw-gateway-hygiene.log")
# 2026-10-01: the crash is the V8 HEAP limit (--max-old-space-size=4096), not RSS. Heap reached 3.95 GB at RSS 2.96 GB,
# under the 5 GB RSS HARD line, so 4 ABRT crashes (09-21..09-27) went unseen. The gateway logs heapUsedBytes in its
# "memory pressure" lines; HEAP_HARD fires on the MIN over the window (one garbage spike is not live heap).
GW_ERR_LOG = os.getenv("HYGIENE_GW_ERR_LOG", os.path.join(HOME, ".openclaw/logs/gateway.err.log"))
HEAP_HARD_B = float(os.getenv("HYGIENE_HEAP_HARD_GB", "3.6")) * 1e9
HEAP_WINDOW_S = float(os.getenv("HYGIENE_HEAP_WINDOW_MIN", "10")) * 60
SESSIONS_GLOB = os.getenv("HYGIENE_SESSIONS_GLOB", os.path.join(HOME, ".openclaw/agents/*/sessions/*.jsonl"))


def log(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {"last_restart_ts": 0, "last_ping_ts": 0, "restarts": 0}


def save_state(st):
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w") as f:
            json.dump(st, f)
    except Exception:
        pass


def gateway_rss_kb():
    """RSS of the gateway MainPID in KB, or None if not resolvable."""
    if os.getenv("HYGIENE_TEST_RSS_KB"):
        return float(os.environ["HYGIENE_TEST_RSS_KB"])
    try:
        pid = subprocess.run(["systemctl", "--user", "show", UNIT, "-p", "MainPID", "--value"],
                             capture_output=True, text=True, timeout=15).stdout.strip()
        if not pid or pid == "0":
            return None
        for ln in open("/proc/%s/status" % pid):
            if ln.startswith("VmRSS:"):
                return float(ln.split()[1])
    except Exception:
        return None
    return None


def gateway_start_ts():
    """Epoch seconds the gateway's main process started, or None."""
    if os.getenv("HYGIENE_TEST_GW_START_TS"):
        return float(os.environ["HYGIENE_TEST_GW_START_TS"])
    try:
        v = subprocess.run(["systemctl", "--user", "show", UNIT, "-p", "ExecMainStartTimestamp", "--value"],
                           capture_output=True, text=True, timeout=15).stdout.strip()
        if v:
            r = subprocess.run(["date", "-d", v, "+%s"], capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip():
                return float(r.stdout.strip())
    except Exception:
        pass
    # Fallback (systemctl unreachable, e.g. no session bus): the gateway process's own uptime.
    if os.getenv("HYGIENE_TEST_NO_PGREP"):
        return None
    try:
        # Identify by argv, not by pattern: `pgrep -f` also matches any shell whose command line merely
        # CONTAINS the pattern (it returned the calling shell's 0 s uptime on 2026-10-01).
        et = []
        for p in os.listdir("/proc"):
            if not p.isdigit():
                continue
            try:
                argv = open("/proc/%s/cmdline" % p, "rb").read().split(b"\0")
            except OSError:
                continue
            if len(argv) >= 3 and os.path.basename(argv[0]) == b"node" and any(
                    a.endswith(b"openclaw/dist/index.js") and i + 1 < len(argv) and argv[i + 1] == b"gateway"
                    for i, a in enumerate(argv)):
                v = subprocess.run(["ps", "-o", "etimes=", "-p", p], capture_output=True, text=True,
                                   timeout=5).stdout.strip()
                if v:
                    et.append(float(v))
        return time.time() - max(et) if et else None
    except Exception:
        return None


def heap_samples(since_ts):
    """[(epoch, heapUsedBytes)] from the gateway's memory-pressure lines newer than since_ts and inside the window."""
    import re as _re
    from datetime import datetime as _dt
    out = []
    try:
        with open(GW_ERR_LOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4 * 1024 * 1024))   # tail only: the log can be large
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return out
    floor = max(since_ts or 0, time.time() - HEAP_WINDOW_S)
    for ln in data.splitlines():
        if "memory pressure:" not in ln or "heapUsedBytes=" not in ln:
            continue
        m = _re.search(r"heapUsedBytes=(\d+)", ln)
        try:
            ts = _dt.fromisoformat(ln.split()[0]).timestamp()
        except (ValueError, IndexError):
            continue
        if m and ts > floor:
            out.append((ts, float(m.group(1))))
    return out


def is_idle():
    """Idle = no session file touched in the last IDLE_WINDOW_MIN minutes. Filesystem-based so it
    works even when the gateway CLI is unresponsive; any doubt -> NOT idle (conservative)."""
    if os.getenv("HYGIENE_TEST_IDLE") is not None:
        return os.environ["HYGIENE_TEST_IDLE"] == "1"
    try:
        cutoff = time.time() - IDLE_WINDOW_MIN * 60
        for p in glob.iglob(SESSIONS_GLOB):
            if os.path.getmtime(p) > cutoff:
                return False
        return True
    except Exception:
        return False


ACTIVE_TASK_STATUSES = {"running", "pending", "queued", "starting"}

# Long background chains (run-chain.sh) touch NAME.hb every ~30s while their producer lives.
# They are a work surface the session-file and task-registry checks cannot see (2026-08-10).
CHAIN_GLOBS = os.getenv(
    "HYGIENE_CHAIN_GLOBS",
    os.path.join(HOME, ".openclaw/workspace/simulations/*/build/chains/*.hb") + ":" +
    os.path.join(HOME, ".openclaw/chains/*.hb"),
).split(":")
CHAIN_FRESH_S = int(os.getenv("HYGIENE_CHAIN_FRESH_S", "180"))
MAX_HARD_DEFERRALS = int(os.getenv("HYGIENE_MAX_HARD_DEFERRALS", "6"))


def fresh_chain_heartbeats():
    """Names of chains whose heartbeat is fresh. Empty list means none seen (or unreadable)."""
    import glob as _glob
    out, now = [], time.time()
    for pat in CHAIN_GLOBS:
        for hb in _glob.glob(pat):
            try:
                if now - os.path.getmtime(hb) <= CHAIN_FRESH_S:
                    out.append(os.path.basename(hb)[:-3])
            except OSError:
                continue
    return out


def has_active_tasks():
    """True (something is running), False (registry readable, nothing active), or None (unknown).

    Session-file mtimes miss a whole class of live work: an agent turn blocked on a long exec
    (julia, 2026-07-29 18:10) writes nothing to its session file until the exec returns, so the
    mtime check declared "idle" mid-computation; the SOFT restart hung on stop-sigterm for 90s and
    systemd SIGKILL'd the exec plus an in-flight Slack delivery. The task registry sees that turn
    as status=running, so SOFT requires BOTH signals quiet. Only the SOFT path calls this —
    HARD must still fire when the gateway is too wedged to answer the CLI."""
    try:
        r = subprocess.run(["openclaw", "tasks", "list", "--json"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        tasks = json.loads(r.stdout)
        # 2026.5.20 answers an OBJECT {count, runtime, status, tasks:[...]}; older builds a list. Iterating the
        # object's keys threw on every run -> "unverifiable" -> the SOFT path never fired (found 2026-10-01).
        if isinstance(tasks, dict):
            tasks = tasks.get("tasks")
        if not isinstance(tasks, list):
            return None
        return any(str(t.get("status", "")).lower() in ACTIVE_TASK_STATUSES for t in tasks if isinstance(t, dict))
    except Exception:
        return None


def restart_gateway(reason):
    log("RESTART gateway: %s" % reason)
    try:
        subprocess.run(["systemctl", "--user", "restart", UNIT], timeout=90)
        return True
    except Exception as e:
        log("restart FAILED: %s" % e)
        return False


def ping(msg):
    if not SIGNAL_TARGET:
        log("ping skipped (no HYGIENE_SIGNAL_TARGET): %s" % msg)
        return
    try:
        subprocess.run(["openclaw", "message", "send", "--channel", "signal",
                        "--target", SIGNAL_TARGET, "-m", msg], capture_output=True, timeout=30)
    except Exception as e:
        log("ping failed: %s" % e)


def rss_floor_trend(samples, now):
    """samples: [[ts, rss_kb], ...]. Returns (rise_mb, floors_gb) when every bin is populated, else (None, floors)."""
    w = TREND_WINDOW_H * 3600
    floors = []
    for k in range(TREND_BINS):
        lo = now - w + k * w / TREND_BINS
        hi = lo + w / TREND_BINS
        vals = [r for ts, r in samples if lo <= ts < hi]
        if len(vals) < TREND_MIN_PER_BIN:
            return None, floors
        floors.append(min(vals) / 1048576)
    if any(floors[i + 1] < floors[i] - 0.05 for i in range(len(floors) - 1)):   # a drop of > 50 MB breaks the trend
        return 0.0, floors
    return (floors[-1] - floors[0]) * 1024, floors


def record_and_check_trend(st, now, rss_kb, start):
    """Append this run's RSS sample (post-restart only) and alarm on a rising floor. Mutates st; caller saves."""
    keep_after = max(now - 2 * TREND_WINDOW_H * 3600, float(start or 0))
    samples = [s for s in st.get("rss_samples", []) if isinstance(s, list) and len(s) == 2 and float(s[0]) >= keep_after]
    samples.append([now, float(rss_kb)])
    st["rss_samples"] = samples
    rise, floors = rss_floor_trend(samples, now)
    if rise is None or rise < TREND_RISE_MB:
        return False
    msg = ("RSS floor rose %.0f MB over the last %.0f h (bin floors %s GB) — a leak signature. The patch check says nothing "
           "about behaviour: run `bash ~/.openclaw/scripts/post-upgrade.sh --check`, then grep 'memory pressure' in "
           "logs/gateway.err.log" % (rise, TREND_WINDOW_H, "/".join("%.2f" % f for f in floors)))
    log("TREND: " + msg)
    if now - float(st.get("last_trend_ping_ts", 0) or 0) >= TREND_PING_GAP_S:
        ping("gateway-memory-hygiene: " + msg)
        st["last_trend_ping_ts"] = now
    return True


def main():
    rss = gateway_rss_kb()
    if rss is None:
        log("status: gateway RSS unresolvable (unit down or PID gone) — no action")
        return 0
    st = load_state()
    now = time.time()
    gb = rss / 1048576
    start = gateway_start_ts()
    since = max(start or 0, float(st.get("last_restart_ts", 0) or 0))
    record_and_check_trend(st, now, rss, start)
    save_state(st)
    # Unknown start -> no heap trigger: pre-restart samples inside the window would re-fire right after a restart.
    hs = heap_samples(since) if start is not None else []
    heap_floor = min(h for _, h in hs) if len(hs) >= 2 else None
    heap_hard = heap_floor is not None and heap_floor >= HEAP_HARD_B
    if heap_hard:
        log("status: V8 heap floor %.2f GB over %d samples in %.0f min >= %.1f GB (rss %.2f GB) — HEAP HARD"
            % (heap_floor / 1e9, len(hs), HEAP_WINDOW_S / 60, HEAP_HARD_B / 1e9, gb))
    if rss >= HARD_KB or heap_hard:
        # 2026-08-10: the HARD branch deliberately ignores idleness — a runaway must be stopped.
        # But on 2026-08-10 05:00 it SIGTERM'd a 16-minute-old mesh generation that was a
        # descendant of the gateway cgroup and had nothing to do with the leak, costing the
        # campaign a multi-hour job. run-chain.sh now detaches chains into their own systemd
        # scope so they survive; this deferral covers chains started before that fix and any
        # other in-cgroup long work. Bounded: after MAX_HARD_DEFERRALS consecutive deferrals we
        # restart anyway, because an unbounded defer would re-create the runaway we exist to stop.
        fresh = fresh_chain_heartbeats()
        deferrals = int(st.get("hard_deferrals", 0))
        if fresh and deferrals < MAX_HARD_DEFERRALS:
            st["hard_deferrals"] = deferrals + 1
            log("status: rss=%.2fGB HARD, but %d chain heartbeat(s) fresh (%s) — deferring "
                "restart %d/%d" % (gb, len(fresh), ", ".join(fresh[:3]),
                                   deferrals + 1, MAX_HARD_DEFERRALS))
            save_state(st)
            return 0
        if fresh:
            log("status: rss=%.2fGB HARD with %d fresh chain(s) but deferral budget exhausted "
                "(%d) — restarting anyway" % (gb, len(fresh), deferrals))
        st["hard_deferrals"] = 0
        why = ("HEAP HARD: V8 heap floor %.2fGB >= %.1fGB (heap limit 4.0GB)" % (heap_floor / 1e9, HEAP_HARD_B / 1e9)
               if heap_hard else "HARD threshold: rss=%.2fGB >= %.1fGB" % (gb, HARD_KB / 1048576))
        ok = restart_gateway(why)
        st["last_restart_ts"] = now
        st["restarts"] = st.get("restarts", 0) + 1
        if ok and now - st.get("last_ping_ts", 0) >= PING_GAP_S:
            ping("gateway-memory-hygiene: %s — did a controlled restart "
                 "(leak mitigation; see /tmp/openclaw-gateway-hygiene.log)" % why)
            st["last_ping_ts"] = now
        save_state(st)
        return 0
    if rss >= SOFT_KB:
        gap = now - st.get("last_restart_ts", 0)
        if gap < MIN_GAP_S:
            log("status: rss=%.2fGB over soft, but only %.1fh since last hygiene restart — wait" % (gb, gap / 3600))
            return 0
        if not is_idle():
            log("status: rss=%.2fGB over soft, gateway NOT idle — wait for a quiet window" % gb)
            return 0
        active = has_active_tasks()
        if active is not False:
            log("status: rss=%.2fGB over soft, sessions idle but %s — wait" % (
                gb, "agent task(s) RUNNING (long execs never touch session files)" if active
                else "task registry unverifiable (any doubt -> not idle)"))
            return 0
        restart_gateway("SOFT threshold at idle: rss=%.2fGB >= %.1fGB" % (gb, SOFT_KB / 1048576))
        st["last_restart_ts"] = now
        st["restarts"] = st.get("restarts", 0) + 1
        save_state(st)
        return 0
    log("status: rss=%.2fGB ok (soft %.1fGB / hard %.1fGB)" % (gb, SOFT_KB / 1048576, HARD_KB / 1048576))
    return 0


if __name__ == "__main__":
    sys.exit(main())
