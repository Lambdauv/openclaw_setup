#!/usr/bin/env python3
"""Unit test for gateway-memory-hygiene.py — mocked systemctl/openclaw via PATH shim; prints PASS/FAIL."""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)
        print("FAIL:", msg)


def run_case(name, rss_kb, idle, state=None, extra_env=None):
    """Run the script in a sandbox; return (calls, state_after, stdout)."""
    d = tempfile.mkdtemp(prefix="hyg-")
    shim = os.path.join(d, "bin")
    os.makedirs(shim)
    calls = os.path.join(d, "calls.log")
    for tool in ("systemctl", "openclaw"):
        p = os.path.join(shim, tool)
        with open(p, "w") as f:
            # `openclaw tasks list --json` answers with MOCK_TASKS_JSON (default: no tasks)
            # or fails when MOCK_TASKS_FAIL is set — exercises the real parse path.
            f.write("#!/usr/bin/env bash\necho \"%s $@\" >> %s\n" % (tool, calls) +
                    "if [ \"$1\" = tasks ] && [ \"$2\" = list ]; then\n"
                    "  if [ -n \"$MOCK_TASKS_FAIL\" ]; then exit 1; fi\n"
                    "  echo \"${MOCK_TASKS_JSON:-[]}\"\n"
                    "fi\nexit 0\n")
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    statef = os.path.join(d, "state.json")
    if state is not None:
        json.dump(state, open(statef, "w"))
    env = dict(os.environ)
    env.update({
        "PATH": shim + os.pathsep + env.get("PATH", ""),
        "HYGIENE_TEST_RSS_KB": str(rss_kb),
        "HYGIENE_TEST_IDLE": "1" if idle else "0",
        "HYGIENE_SIGNAL_TARGET": "test-target",   # no default in the script; must not look like a phone number (export scan)
        "HYGIENE_STATE": statef,
        "HYGIENE_LOG": os.path.join(d, "log"),
        "HYGIENE_SOFT_GB": "2.5", "HYGIENE_HARD_GB": "5",
        "HYGIENE_MIN_GAP_HOURS": "6", "HYGIENE_PING_GAP_HOURS": "1",
        # never read the live gateway log from a test; heap cases pass their own fixture
        "HYGIENE_GW_ERR_LOG": os.path.join(d, "no-such-gateway.err.log"),
        "HYGIENE_HEAP_HARD_GB": "3.6", "HYGIENE_HEAP_WINDOW_MIN": "10",
    })
    if extra_env:
        env.update(extra_env)
    r = subprocess.run([sys.executable, os.path.join(HERE, "gateway-memory-hygiene.py")],
                       capture_output=True, text=True, env=env, timeout=30)
    got_calls = open(calls).read() if os.path.exists(calls) else ""
    st = json.load(open(statef)) if os.path.exists(statef) else {}
    return got_calls, st, r.stdout


GB = 1048576
import time as _t
NOW = _t.time()

# 1: below soft -> no restart
c, st, out = run_case("below-soft", 1.0 * GB, idle=True)
check("restart" not in c, "1: no restart below soft (calls=%r)" % c)

# 2: over soft, NOT idle -> no restart
c, st, out = run_case("soft-busy", 3.0 * GB, idle=False)
check("restart" not in c, "2: no restart when busy")
check("NOT idle" in out, "2: logs busy status")

# 3: over soft, idle, no prior restart -> restart (silent: no ping)
c, st, out = run_case("soft-idle", 3.0 * GB, idle=True)
check("systemctl --user restart openclaw-gateway.service" in c, "3: soft restart fired (calls=%r)" % c)
check("message send" not in c, "3: soft restart is silent")
check(st.get("restarts") == 1, "3: state counted")

# 4: over soft, idle, but within MIN_GAP -> no restart
c, st, out = run_case("soft-gap", 3.0 * GB, idle=True,
                      state={"last_restart_ts": NOW - 3600, "last_ping_ts": 0, "restarts": 1})
check("restart" not in c, "4: gap respected")

# 5: over HARD, busy -> restart anyway + ping
c, st, out = run_case("hard-busy", 6.0 * GB, idle=False)
check("systemctl --user restart openclaw-gateway.service" in c, "5: hard restart fired")
check("message send" in c and "signal" in c, "5: hard restart pings Roger")

# 6: hard again within ping rate-limit -> restart, NO second ping
c, st, out = run_case("hard-ping-limit", 6.0 * GB, idle=False,
                      state={"last_restart_ts": NOW - 7200, "last_ping_ts": NOW - 60, "restarts": 3})
check("systemctl --user restart openclaw-gateway.service" in c, "6: hard restart still fires")
check("message send" not in c, "6: ping rate-limited")

# 7: RSS unresolvable -> no action (shim systemctl returns MainPID empty -> None path)
c, st, out = run_case("no-rss", 0.0001, idle=True, extra_env={"HYGIENE_TEST_RSS_KB": ""})
check("restart" not in c, "7: no action when RSS unresolvable")

# 8: over soft, session-files idle, but an agent task is RUNNING -> no restart.
# 2026-07-29 18:10: a turn blocked on a long exec (julia) touches no session file, so
# mtime-idleness declared "idle" mid-computation; the SOFT restart hung 90s then SIGKILL'd
# the exec and an in-flight Slack delivery. Session mtimes alone are NOT an idleness signal.
c, st, out = run_case("soft-idle-task-running", 3.0 * GB, idle=True,
                      extra_env={"MOCK_TASKS_JSON": '[{"taskId":"t1","status":"running"}]'})
check("restart" not in c, "8: no SOFT restart while an agent task is running (calls=%r)" % c)
check("RUNNING" in out or "running" in out, "8: logs the running-task reason")

# 9: over soft, idle, task registry unverifiable -> no restart (any doubt -> not idle;
# the HARD threshold still owns the wedged-gateway case)
c, st, out = run_case("soft-idle-tasks-fail", 3.0 * GB, idle=True,
                      extra_env={"MOCK_TASKS_FAIL": "1"})
check("restart" not in c, "9: no SOFT restart when tasks list fails (calls=%r)" % c)

# 10: over soft, idle, only settled tasks in the registry -> restart proceeds
# (recovery case: the guard must notice quiet and not deadlock the mitigation)
c, st, out = run_case("soft-idle-tasks-settled", 3.0 * GB, idle=True,
                      extra_env={"MOCK_TASKS_JSON":
                                 '[{"status":"completed"},{"status":"failed"},{"status":"lost"}]'})
check("systemctl --user restart openclaw-gateway.service" in c,
      "10: settled tasks must not block the soft restart (calls=%r)" % c)

# 11: HARD ignores the task gate entirely (restart even with a running task)
c, st, out = run_case("hard-task-running", 6.0 * GB, idle=False,
                      extra_env={"MOCK_TASKS_JSON": '[{"taskId":"t1","status":"running"}]'})
check("systemctl --user restart openclaw-gateway.service" in c,
      "11: HARD restart fires regardless of running tasks")

# 12-13: the REAL `openclaw tasks list --json` shape on 2026.5.20 is an OBJECT {count, runtime, status, tasks: [...]},
# not a list. The parser iterated the dict's keys, threw, and reported "unverifiable" on every run: the SOFT path was
# dead (129 "idle but task registry unverifiable" lines, 0 soft restarts). This mock answered a list, so tests kept passing.
c, st, out = run_case("soft-idle-real-shape-settled", 3.0 * GB, idle=True,
                      extra_env={"MOCK_TASKS_JSON": '{"count":2,"runtime":null,"status":null,"tasks":[{"status":"succeeded"},{"status":"failed"}]}'})
check("systemctl --user restart openclaw-gateway.service" in c,
      "12: real CLI object shape with settled tasks must allow the soft restart (calls=%r out=%r)" % (c, out))
c, st, out = run_case("soft-idle-real-shape-running", 3.0 * GB, idle=True,
                      extra_env={"MOCK_TASKS_JSON": '{"count":1,"tasks":[{"status":"running"}]}'})
check("restart" not in c and ("RUNNING" in out or "running" in out),
      "13: real CLI object shape with a running task blocks the soft restart (calls=%r)" % c)

# 14-17: the crash is a V8 HEAP limit (--max-old-space-size=4096), not RSS. On 2026-10-01 the heap reached 3.95 GB while
# RSS was 2.96 GB, under the 5 GB RSS HARD line: four ABRT crashes 09-21..09-27 that this watchdog could not see.
# Trigger on the gateway's own "memory pressure" heapUsedBytes samples: the MIN over the window (garbage can spike
# one sample; a high floor means live heap) >= HEAP_HARD, counting only samples after the gateway started.
from datetime import datetime as _dt, timezone as _tz, timedelta as _td
def _line(ts, heap):
    return ("%s [diagnostics/memory] memory pressure: level=critical reason=heap_threshold rssBytes=2900000000 "
            "heapUsedBytes=%d thresholdBytes=2147483648 memoryPressureSnapshot=disabled\n"
            % (_dt.fromtimestamp(ts, _tz(_td(hours=-7))).isoformat(timespec="milliseconds"), heap))
def heap_case(name, samples, start_ts, idle=False):
    f = tempfile.mktemp(prefix="gwerr-")
    open(f, "w").write("".join(_line(ts, h) for ts, h in samples))
    return run_case(name, 2.0 * GB, idle=idle, extra_env={
        "HYGIENE_GW_ERR_LOG": f, "HYGIENE_TEST_GW_START_TS": str(start_ts),
        "MOCK_TASKS_JSON": '{"tasks":[{"status":"running"}]}'})
c, st, out = heap_case("heap-hard-sustained", [(NOW - 480, 3.80e9), (NOW - 240, 3.70e9), (NOW - 60, 3.90e9)], NOW - 86400)
check("systemctl --user restart openclaw-gateway.service" in c,
      "14: sustained heap >= 3.6 GB restarts even while busy (calls=%r out=%r)" % (c, out))
check("heap" in out.lower(), "14: logs the heap reason")
c, st, out = heap_case("heap-spike", [(NOW - 480, 2.20e9), (NOW - 240, 3.95e9), (NOW - 60, 2.40e9)], NOW - 86400)
check("restart" not in c, "15: a single heap spike (garbage) must not restart (calls=%r)" % c)
c, st, out = heap_case("heap-pre-restart", [(NOW - 480, 3.80e9), (NOW - 400, 3.90e9)], NOW - 300)
check("restart" not in c, "16: samples from before the gateway started are ignored (no restart loop) (calls=%r)" % c)
c, st, out = heap_case("heap-one-sample", [(NOW - 60, 3.90e9)], NOW - 86400)
check("restart" not in c, "17: one sample is not 'sustained' (calls=%r)" % c)

# 18: gateway start UNKNOWN -> the heap trigger must not act (pre-restart samples would re-trigger a restart
# loop right after a crash/manual restart). Fail safe; the RSS HARD line still stands.
f18 = tempfile.mktemp(prefix="gwerr-")
open(f18, "w").write("".join(_line(ts, h) for ts, h in [(NOW - 480, 3.8e9), (NOW - 60, 3.9e9)]))
c, st, out = run_case("heap-start-unknown", 2.0 * GB, idle=False, extra_env={
    "HYGIENE_GW_ERR_LOG": f18, "HYGIENE_TEST_GW_START_TS": "", "HYGIENE_TEST_NO_PGREP": "1"})
check("restart" not in c, "18: unknown gateway start -> no heap restart (calls=%r out=%r)" % (c, out))


# --- RSS-floor trend alarm (2026-10-04): a leak is a rising floor between spikes; spikes alone are not ---
def _samples(hours, fn):
    return [[NOW - h * 3600, fn(h)] for h in [x / 6 for x in range(int(hours * 6), 0, -1)]]   # one sample per 10 min
flat_spiky = _samples(26, lambda h: 1.2 * GB + (1.8 * GB if int(h * 6) % 6 == 0 else 0))     # 1.2 GB floor, hourly 3 GB spikes
rising = _samples(26, lambda h: 1.0 * GB + (26 - h) * 0.05 * GB)                              # +50 MB/h -> +1.2 GB/24 h
c, st, out = run_case("trend-flat-spiky", 1.2 * GB, idle=False, state={"rss_samples": flat_spiky},
                      extra_env={"HYGIENE_TEST_GW_START_TS": str(NOW - 30 * 3600)})
check("TREND" not in out and "message send" not in c, "19: hourly spikes on a flat floor are not a trend (out=%r)" % out[-300:])
check(len(st.get("rss_samples", [])) >= 150, "19: samples are kept in the state (%d)" % len(st.get("rss_samples", [])))
c, st, out = run_case("trend-rising", 2.3 * GB, idle=False, state={"rss_samples": rising},
                      extra_env={"HYGIENE_TEST_GW_START_TS": str(NOW - 30 * 3600)})
check("TREND" in out and "message send" in c and "signal" in c, "20: a +50 MB/h floor over 24 h alarms (out=%r calls=%r)" % (out[-300:], c))
check(st.get("last_trend_ping_ts", 0) > NOW - 60, "20: trend ping stamped")
c, st, out = run_case("trend-rising-ratelimited", 2.3 * GB, idle=False,
                      state={"rss_samples": rising, "last_trend_ping_ts": NOW - 3600},
                      extra_env={"HYGIENE_TEST_GW_START_TS": str(NOW - 30 * 3600)})
check("TREND" in out and "message send" not in c, "21: trend logged but ping rate-limited to one per day (calls=%r)" % c)
c, st, out = run_case("trend-restart-in-window", 2.3 * GB, idle=False, state={"rss_samples": rising},
                      extra_env={"HYGIENE_TEST_GW_START_TS": str(NOW - 6 * 3600)})
check("TREND" not in out and "message send" not in c, "22: samples before the gateway's start are dropped, no trend (out=%r)" % out[-200:])
check(all(s[0] >= NOW - 6 * 3600 - 1 for s in st.get("rss_samples", [])), "22: pre-restart samples pruned")

print("PASS" if not fails else "FAILED (%d)" % len(fails))
sys.exit(1 if fails else 0)
