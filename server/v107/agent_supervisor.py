"""
NexGenX Agent Supervisor — process-level restart wrapper (v1.06)
=================================================================

This is the entry point the Windows scheduled task launches. It:
  1. Imports the real agent (agent_server.py -> WindowsAgent)
  2. Runs the agent in a loop
  3. If the agent exits with code != 0, restarts it with backoff
     (1s, 2s, 4s, 8s, 16s, 32s, 60s, then 60s forever)
  4. Logs every restart to AUDIT_LOG_FILE with reason
  5. If the agent exits with code 0 (clean shutdown), the supervisor
     also exits cleanly

Exit code semantics (what the agent should do):
  0   = clean shutdown, do not restart
  73  = voluntary exit (watchdog gave up), restart with backoff
  any other = unexpected crash, restart with backoff

Why this is a separate process:
    The watchdog inside the agent can repair subsystems but cannot
    always recover (e.g. native mss handle corruption that even a
    re-import doesn't fix). The supervisor is the "circuit breaker
    of last resort" — if the agent keeps dying, the supervisor's
    backoff prevents a tight crash loop from filling the log.

Why a separate Python script and not a PowerShell loop:
    A PowerShell loop loses the process tree when the WinRM session
    that launched it ends. A Python script as a scheduled task child
    keeps its process tree intact across disconnects, same as the
    agent itself.

Configuration via env vars (all optional):
    NGX_AGENT_PORT     : port for the agent (default 9400)
    NGX_AGENT_HOST     : bind address (default 0.0.0.0)
    NGX_AGENT_QUIET    : if set, suppress agent startup banner
    NGX_SUPERVISOR_MAX_BACKOFF_S : cap on backoff (default 60)
    NGX_SUPERVISOR_LOG : path to supervisor log (default <data_dir>/supervisor.log)
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ─── Configuration ───────────────────────────────────────────────────────

PORT = int(os.environ.get("NGX_AGENT_PORT", "9400"))
HOST = os.environ.get("NGX_AGENT_HOST", "0.0.0.0")
QUIET = bool(os.environ.get("NGX_AGENT_QUIET"))
MAX_BACKOFF_S = int(os.environ.get("NGX_SUPERVISOR_MAX_BACKOFF_S", "60"))
BACKOFF_STEPS = (1, 2, 4, 8, 16, 32, 60)  # seconds; final 60 repeats

# Compute data dir (mirror agent_server_common's logic)
if os.name == "nt":
    base = Path(os.environ.get("PROGRAMDATA", "C:/ProgramData"))
    DATA_DIR = base / "NexGenX"
else:
    DATA_DIR = Path("/etc/nexgenx")
DATA_DIR.mkdir(parents=True, exist_ok=True)
SUPERVISOR_LOG = Path(os.environ.get(
    "NGX_SUPERVISOR_LOG", str(DATA_DIR / "supervisor.log")
))


# ─── Logging (we can't rely on the agent's logging config) ───────────────

def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] [supervisor] {msg}\n"
    try:
        sys.stderr.write(line)
        sys.stderr.flush()
    except Exception:
        pass
    try:
        with open(SUPERVISOR_LOG, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


# ─── Boot-time port cleanup ────────────────────────────────────────────────

def kill_port_squatter(port: int) -> None:
    """Kill any process holding our port that isn't us.

    This runs once at supervisor startup. If a stale agent from a previous
    session (or a zombie v1.05 Interactive task) is holding the port, we
    kill it so the supervisor's agent child can bind. We only kill
    python.exe / pythonw.exe processes — never anything else.
    """
    if os.name != "nt":
        return
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             f"Get-NetTCPConnection -State Listen -LocalPort {port} -ErrorAction SilentlyContinue | "
             f"ForEach-Object {{ $p = Get-Process -Id $_.OwningProcess; "
             f"if ($p.ProcessName -match 'python') {{ "
             f"Write-Output ('killing pid=' + $p.Id + ' name=' + $p.ProcessName + ' cmd=' + $p.Path); "
             f"Stop-Process -Id $p.Id -Force }}}}"],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip():
            log(f"boot-time port cleanup: {result.stdout.strip()}")
            time.sleep(2)
        else:
            log(f"boot-time port cleanup: port {port} is free")
    except Exception as e:
        log(f"boot-time port cleanup: failed (non-fatal): {e}")


# ─── Crash-loop alerting ────────────────────────────────────────────────────

ALERT_THRESHOLD = 5  # consecutive failures before alerting
ALERT_COOLDOWN_S = 300  # only alert once per 5 minutes

def send_crash_alert(attempt: int, last_exit_code: int) -> None:
    """Log a prominent crash-loop alert after N consecutive failures.

    Currently writes to the supervisor log (which Hermes cron monitors).
    Future: POST to a Hermes webhook endpoint for immediate Telegram alert.
    """
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    alert_msg = (
        f"⚠️ CRASH-LOOP ALERT: agent has failed {attempt} consecutive times. "
        f"Last exit code: {last_exit_code}. "
        f"Check supervisor.log for details. "
        f"Likely cause: port conflict (Error 10048) or missing v107 module."
    )
    log("=" * 60)
    log(alert_msg)
    log("=" * 60)


# ─── The supervisor loop ──────────────────────────────────────────────────

def run_agent_subprocess(port: int, host: str) -> int:
    """Run the agent in a subprocess, return its exit code.

    We use subprocess instead of importing agent_server so the child
    has a clean process boundary (e.g. native COM apartment, signal
    handling, sys.modules) and so a crash in the child is fully
    isolated from the supervisor.
    """
    # Use python.exe (NOT pythonw.exe) for the agent child even when the
    # supervisor itself runs under pythonw.exe. pythonw.exe has no
    # stdout/stderr handles, so any print() in agent_server.py crashes
    # immediately with IOError. The supervisor is headless-safe (it only
    # writes to a log file), but the agent is not.
    if os.name == "nt" and "pythonw.exe" in sys.executable:
        python_exe = sys.executable.replace("pythonw.exe", "python.exe")
    else:
        python_exe = sys.executable
    cmd = [python_exe, "-u", "agent_server.py",
           "--port", str(port), "--host", host]
    if QUIET:
        cmd.append("--quiet")
    log(f"launching agent: {' '.join(cmd)} (cwd={os.getcwd()})")
    try:
        # On Windows, CREATE_NEW_PROCESS_GROUP so we can Ctrl-C the child
        # without killing the supervisor.
        kwargs: dict = {}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
        proc = subprocess.Popen(cmd, **kwargs)
        return proc.wait()
    except KeyboardInterrupt:
        # Supervisor got Ctrl-C; propagate to child and exit
        log("supervisor received SIGINT, terminating child")
        try:
            proc.terminate()  # type: ignore[name-defined]
        except Exception:
            pass
        return 130
    except Exception as e:
        log(f"failed to launch agent: {e}")
        return 1


def backoff_for(attempt: int) -> int:
    """Return the backoff in seconds for a given attempt count (1-based)."""
    if attempt <= 0:
        return 0
    if attempt > len(BACKOFF_STEPS):
        return BACKOFF_STEPS[-1]
    return BACKOFF_STEPS[attempt - 1]


def main() -> int:
    log("=" * 60)
    log("NexGenX Agent Supervisor v1.06 starting")
    log(f"  port={PORT} host={HOST} quiet={QUIET} max_backoff={MAX_BACKOFF_S}s")
    log(f"  supervisor log: {SUPERVISOR_LOG}")
    log("=" * 60)

    # Boot-time port cleanup: kill any stale python process holding our port
    kill_port_squatter(PORT)

    # SIGTERM/SIGINT handler: clean shutdown (so Windows service stop works)
    stop_requested = {"v": False}

    def _on_signal(signum, frame):
        log(f"signal {signum} received, will stop after current run")
        stop_requested["v"] = True

    if os.name == "nt":
        try:
            signal.signal(signal.SIGINT, _on_signal)
            signal.signal(signal.SIGTERM, _on_signal)
        except Exception:
            pass
    else:
        signal.signal(signal.SIGINT, _on_signal)
        signal.signal(signal.SIGTERM, _on_signal)

    attempt = 0
    last_exit_code = 0
    while not stop_requested["v"]:
        t0 = time.time()
        last_exit_code = run_agent_subprocess(PORT, HOST)
        elapsed = time.time() - t0
        log(f"agent exited with code={last_exit_code} after {elapsed:.1f}s")
        if last_exit_code == 0:
            log("clean exit (code 0), supervisor stopping")
            return 0
        # Non-zero: schedule restart with backoff
        reason = "watchdog_voluntary_exit" if last_exit_code == 73 else "agent_crash"
        # Reset attempt counter on watchdog voluntary exits (code 73) —
        # those mean "I gave up, please restart me" which is a normal
        # operational event, not a crash loop. Crashes (other non-zero)
        # keep accumulating so we don't tight-loop a broken process.
        if last_exit_code == 73:
            attempt = 0
        attempt += 1
        wait_s = min(backoff_for(attempt), MAX_BACKOFF_S)
        log(f"restart attempt={attempt} wait={wait_s}s reason={reason}")
        # Alert on sustained crash-loop
        if attempt == ALERT_THRESHOLD:
            send_crash_alert(attempt, last_exit_code)
        # Sleep in small chunks so a signal interrupts us
        for _ in range(wait_s):
            if stop_requested["v"]:
                break
            time.sleep(1)
    log("stop requested, supervisor exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
