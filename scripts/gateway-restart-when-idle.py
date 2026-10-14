#!/usr/bin/env python3
"""gateway-restart-when-idle.py — restart openclaw-gateway at the first idle moment, to load a bundle patch.

A bundle patch (scripts/regraft-*.sh) takes effect only when the gateway restarts, and a restart kills every agent
turn in flight (and any run-chain wrapper living in the gateway's cgroup). This waits for a moment when nothing runs,
then restarts once.

Idle uses gateway-memory-hygiene.py's own tests. All three must hold on CONFIRM consecutive checks, POLL seconds apart:
  - no agent session file touched in the last HYGIENE_IDLE_WINDOW_MIN minutes (default 5);
  - the task registry readable and nothing running, pending, queued or starting;
  - no run-chain heartbeat fresher than HYGIENE_CHAIN_FRESH_S (default 180 s).

Usage: gateway-restart-when-idle.py [--max-hours 8] [--poll 30] [--confirm 2] [--reason TEXT] [--dry-run]
Logs to /tmp/openclaw-restart-when-idle.log. Exit 0 after a restart (or a dry-run idle hit), 1 on timeout.
"""
import argparse, importlib.util, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.getenv("RESTART_WHEN_IDLE_LOG", "/tmp/openclaw-restart-when-idle.log")


def log(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_hygiene():
    spec = importlib.util.spec_from_file_location("hygiene", os.path.join(HERE, "gateway-memory-hygiene.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def idle_now(hy):
    """(idle?, reason). Any doubt counts as busy."""
    if not hy.is_idle():
        return False, "a session file was touched in the last %d min" % hy.IDLE_WINDOW_MIN
    active = hy.has_active_tasks()
    if active is None:
        return False, "task registry unreadable"
    if active:
        return False, "a task is running"
    chains = hy.fresh_chain_heartbeats()
    if chains:
        return False, "chain heartbeat fresh: %s" % ",".join(chains[:3])
    return True, "idle"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-hours", type=float, default=8.0)
    ap.add_argument("--poll", type=float, default=30.0)
    ap.add_argument("--confirm", type=int, default=2)
    ap.add_argument("--reason", default="load a bundle patch")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    # FORCE the user bus: a shell started from an RDP session inherits a dead /tmp/dbus-* address, and every
    # `systemctl --user` call then fails with rc 1 and no output (2026-10-14 11:42: the first run waited two hours
    # for an idle moment, then could not restart). setdefault() kept the dead value; tests had mocked subprocess.
    env = dict(os.environ)
    env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/%d/bus" % os.getuid()
    env["XDG_RUNTIME_DIR"] = "/run/user/%d" % os.getuid()

    def main_pid():
        r = subprocess.run(["systemctl", "--user", "show", "-p", "MainPID", "--value", "openclaw-gateway"],
                           capture_output=True, text=True, env=env)
        pid = (r.stdout or "").strip()
        return pid if r.returncode == 0 and pid.isdigit() and pid != "0" else ""

    # Preflight on the REAL side-effect path, before waiting hours for an idle moment.
    if not main_pid():
        log("ERROR: `systemctl --user show openclaw-gateway` gives no MainPID; refusing to wait (fix the user bus first)")
        return 2
    hy = load_hygiene()
    deadline = time.time() + a.max_hours * 3600
    streak, last_reason = 0, ""
    log("waiting to restart the gateway (%s); max %.1f h, poll %.0f s, confirm %d" % (a.reason, a.max_hours, a.poll, a.confirm))
    while time.time() < deadline:
        ok, why = idle_now(hy)
        streak = streak + 1 if ok else 0
        if why != last_reason:
            log("state: %s" % why)
            last_reason = why
        if streak >= a.confirm:
            if a.dry_run:
                log("DRY RUN: idle confirmed; would restart now")
                return 0
            old = main_pid()
            log("idle confirmed; restarting openclaw-gateway (pid %s)" % old)
            r = subprocess.run(["systemctl", "--user", "restart", "openclaw-gateway"], capture_output=True, text=True, env=env)
            time.sleep(5)
            st = subprocess.run(["systemctl", "--user", "is-active", "openclaw-gateway"], capture_output=True, text=True, env=env).stdout.strip()
            new = main_pid()
            ok = r.returncode == 0 and st == "active" and new and new != old
            log("restart rc=%d, state=%s, pid %s -> %s: %s" % (r.returncode, st, old, new, "OK" if ok else "FAILED"
                + (" (%s)" % (r.stderr or "").strip()[:200] if r.returncode else "")))
            return 0 if ok else 2
        time.sleep(a.poll)
    log("timed out after %.1f h without an idle moment; no restart" % a.max_hours)
    return 1


if __name__ == "__main__":
    sys.exit(main())
