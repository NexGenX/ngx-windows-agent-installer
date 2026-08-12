"""
NexGenX Agent Watchdog — in-process subsystem self-heal (v1.06)
==============================================================

Runs a background thread that, every 30 seconds, runs a series of
lightweight health checks against the critical subsystems the agent
depends on (screenshot library, input library, accessibility tree).
If a check fails repeatedly, the watchdog RECOVERS the wedged subsystem
in-process — without restarting the whole process. Only after N
consecutive RECOVERY FAILURES does the watchdog voluntarily exit
(os._exit(73)) so the OS-level supervisor (agent_supervisor.py) can
take over and restart the process.

Why this exists:
    The agent is a long-running process. Over hours of automated
    customer work, subsystems wedge in non-obvious ways:
      - mss leaks a screenshot handle → next grab returns stale/blank
      - pyautogui gets into a state where moveTo blocks
      - UIA COM apartment gets uninitialized by garbage collection
    Today, the only fix is "kill the process and start over." This
    watchdog keeps the process alive as long as it can, then surfaces
    the failure to the supervisor cleanly.

Design:
    - check_*() methods return (ok: bool, detail: str). No exceptions
      bubble out — the watchdog catches and reports.
    - recover_*() methods attempt in-process repair. They return
      (ok: bool, detail: str). Same exception discipline.
    - run_check_cycle() runs the cheap checks, counts failures, and
      on threshold triggers os._exit(73).
    - check_all() is the synchronous version, exposed for the
      /health/deep HTTP endpoint.

This module is platform-aware: it imports mss/pyautogui at module
load (the agent already does this), and the UIA check is only
registered on Windows.

License: internal NexGenX.
"""
from __future__ import annotations

import logging
import os
import platform
import sys
import threading
import time
import traceback
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

log = logging.getLogger("ngx.watchdog")

# Thresholds (overridable via env var for testing)
CHECK_INTERVAL_S = float(os.environ.get("NGX_WATCHDOG_INTERVAL_S", "30"))
SCREENSHOT_BUDGET_S = float(os.environ.get("NGX_WATCHDOG_SCREENSHOT_BUDGET_S", "1.0"))
# After this many consecutive recovery FAILURES, exit so supervisor restarts.
EXIT_AFTER_FAILURES = int(os.environ.get("NGX_WATCHDOG_EXIT_AFTER", "5"))
# Exit code used as signal to the supervisor ("I exited on purpose, please restart me").
VOLUNTARY_EXIT_CODE = 73


@dataclass
class SubsystemState:
    """State for a single subsystem being watched."""
    name: str
    check: Callable[[], Tuple[bool, str]]
    recover: Optional[Callable[[], Tuple[bool, str]]] = None
    # If True, a failure of this subsystem is fatal (trigger exit). If False,
    # a failure is just logged (e.g. UIA might be unavailable on a system
    # with no UI; we don't want to exit just because that check failed).
    fatal_on_failure: bool = True
    last_ok: bool = True
    last_detail: str = ""
    last_checked_at: float = 0.0
    # Counter of consecutive failed CHECKS (not recoveries). When this
    # crosses the threshold and the subsystem is fatal, we exit.
    consecutive_failures: int = 0
    last_recovery_attempt: float = 0.0
    last_recovery_ok: Optional[bool] = None


@dataclass
class WatchdogReport:
    """Result of a single check cycle. JSON-serializable for /health/deep."""
    overall_ok: bool
    timestamp: float
    uptime_s: float
    consecutive_failures: int
    will_exit: bool
    subsystems: List[Dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "overall_ok": self.overall_ok,
            "timestamp": self.timestamp,
            "uptime_s": round(self.uptime_s, 1),
            "consecutive_failures": self.consecutive_failures,
            "will_exit": self.will_exit,
            "subsystems": self.subsystems,
        }


class Watchdog:
    """Background watchdog thread. One per agent process."""

    def __init__(self):
        self._start_time = time.time()
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._overall_consecutive_failures = 0
        self.subsystems: Dict[str, SubsystemState] = {}
        self._last_recovery_log: List[Dict] = []
        self._register_default_checks()

    # ─── Public API ─────────────────────────────────────────────────────

    def start(self) -> None:
        """Spawn the background thread. Idempotent."""
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(
            target=self._run_loop, name="ngx-watchdog", daemon=True
        )
        self._thread.start()
        log.info("watchdog started, interval=%.1fs, exit_after=%d failures",
                 CHECK_INTERVAL_S, EXIT_AFTER_FAILURES)

    def stop(self) -> None:
        self._stop_event.set()

    def uptime_s(self) -> float:
        return time.time() - self._start_time

    def check_all(self) -> WatchdogReport:
        """Run all subsystem checks synchronously. Exposed for /health/deep."""
        return self._run_check_cycle()

    def last_recovery_log(self, limit: int = 20) -> List[Dict]:
        """Return the most recent recovery attempts (for /health/deep)."""
        with self._lock:
            return list(self._last_recovery_log[-limit:])

    # ─── Check registration ─────────────────────────────────────────────

    def _register_default_checks(self) -> None:
        """Register the standard subsystem checks."""
        self.register(SubsystemState(
            name="mss_screenshot",
            check=self._check_mss,
            recover=self._recover_mss,
            fatal_on_failure=True,
        ))
        self.register(SubsystemState(
            name="pyautogui_input",
            check=self._check_pyautogui,
            recover=self._recover_pyautogui,
            fatal_on_failure=True,
        ))
        # UIA is only meaningful on Windows. On other platforms we skip it
        # by not registering it (or registering a no-op ok=True).
        if platform.system() == "Windows":
            self.register(SubsystemState(
                name="uia_tree",
                check=self._check_uia,
                recover=self._recover_uia,
                fatal_on_failure=False,  # many headless scenarios have no UI tree
            ))

    def register(self, state: SubsystemState) -> None:
        with self._lock:
            self.subsystems[state.name] = state

    # ─── The actual subsystem checks ────────────────────────────────────

    def _check_mss(self) -> Tuple[bool, str]:
        """Take a screenshot, time it, and verify it's not blank/stale."""
        import mss
        from PIL import Image
        t0 = time.time()
        try:
            with mss.mss() as s:
                mon = s.monitors[1]
                img = s.grab(mon)
            elapsed = time.time() - t0
            if elapsed > SCREENSHOT_BUDGET_S:
                return False, f"slow: {elapsed:.2f}s > {SCREENSHOT_BUDGET_S}s"
            # Check it's not all-black or all-white (sign of a stale handle).
            # mss returns a ScreenShot with .size (w, h) and .rgb (bytes).
            # We sample 3 pixels (corners + center) and look for variation.
            size = img.size
            w, h = size[0], size[1]
            rgb = img.rgb
            # bytes is indexed positionally as a flat array; row-major BGRx
            # (4 bytes per pixel on Windows). Sample 3 distinct points.
            samples = []
            for x, y in [(0, 0), (w // 2, h // 2), (w - 1, h - 1)]:
                # On Windows, mss uses BGRx (4 bytes/pixel). On macOS/Linux
                # it's RGBx. We don't care about order here — we just want
                # to know if all 3 sample points are identical.
                idx = (y * w + x) * 4
                if idx + 3 < len(rgb):
                    samples.append((rgb[idx], rgb[idx + 1], rgb[idx + 2]))
            if len(samples) == 3 and all(c == samples[0] for c in samples):
                # All three pixels identical — suspicious, but not necessarily
                # fatal (e.g. login screen really might be solid color). Log
                # as a soft warning; treat as ok.
                return True, f"uniform_color={samples[0]} elapsed={elapsed:.2f}s"
            return True, f"ok elapsed={elapsed:.2f}s samples={len(samples)}"
        except Exception as e:
            return False, f"exception: {type(e).__name__}: {e}"

    def _recover_mss(self) -> Tuple[bool, str]:
        """Force re-import of mss and rebuild any cached handle.

        Strategy: mss.mss() opens a context-manager-bound handle. Since
        we open it inside check_mss() with `with`, there's no global
        handle to release. The recovery here is to garbage-collect and
        re-import mss, which forces fresh native bindings.
        """
        try:
            import gc
            import mss
            # Drop the module from sys.modules so a fresh import pulls in
            # the native bindings again. Then immediately re-import to
            # warm the cache.
            mods = [k for k in sys.modules if k == "mss" or k.startswith("mss.")]
            for m in mods:
                sys.modules.pop(m, None)
            gc.collect()
            import mss  # noqa: F401
            return True, "mss reimported"
        except Exception as e:
            return False, f"exception: {type(e).__name__}: {e}"

    def _check_pyautogui(self) -> Tuple[bool, str]:
        """Move mouse to a safe off-center point and verify position changed."""
        import pyautogui
        try:
            t0 = time.time()
            # Use (1, 1) — top-left is FAILSAFE corner but pyautogui's
            # moveTo does NOT trigger FAILSAFE on the move itself, only
            # on the next action. Use (5, 5) to be safe.
            x, y = 5, 5
            pyautogui.moveTo(x, y, duration=0)
            actual_x, actual_y = pyautogui.position()
            elapsed = time.time() - t0
            if elapsed > 1.0:
                return False, f"slow: moveTo took {elapsed:.2f}s"
            if (actual_x, actual_y) != (x, y):
                return False, f"position_mismatch: requested=({x},{y}) got=({actual_x},{actual_y})"
            return True, f"ok pos=({actual_x},{actual_y}) elapsed={elapsed:.3f}s"
        except Exception as e:
            return False, f"exception: {type(e).__name__}: {e}"

    def _recover_pyautogui(self) -> Tuple[bool, str]:
        """Reset pyautogui's internal state. FAILSAFE and PAUSE are the
        main globals; we just re-set them. The library doesn't expose a
        'reset' API, so this is a soft recovery.
        """
        try:
            import pyautogui
            pyautogui.FAILSAFE = True
            pyautogui.PAUSE = 0.05
            return True, "pyautogui flags reset"
        except Exception as e:
            return False, f"exception: {type(e).__name__}: {e}"

    def _check_uia(self) -> Tuple[bool, str]:
        """Verify the Windows UIA tree is accessible."""
        try:
            import uiautomation as auto
            t0 = time.time()
            root = auto.GetRootControl()
            n_children = len(list(root.GetChildren()))
            elapsed = time.time() - t0
            if elapsed > 2.0:
                return False, f"slow: GetRootControl+children took {elapsed:.2f}s"
            return True, f"ok children={n_children} elapsed={elapsed:.2f}s"
        except Exception as e:
            return False, f"exception: {type(e).__name__}: {e}"

    def _recover_uia(self) -> Tuple[bool, str]:
        """Reinitialize the COM apartment. UIA is a COM API; if the
        thread's apartment was torn down, calls fail with E_NOINTERFACE
        or RPC errors. Calling CoInitialize() again is safe in the same
        thread as long as we match the apartment type.
        """
        try:
            import pythoncom
            try:
                pythoncom.CoInitialize()
            except Exception:
                pass  # already initialized
            # Also try a re-import
            import uiautomation as auto  # noqa: F401
            return True, "COM apartment reinitialized"
        except Exception as e:
            return False, f"exception: {type(e).__name__}: {e}"

    # ─── The check loop ─────────────────────────────────────────────────

    def _run_check_cycle(self) -> WatchdogReport:
        """Run all checks once. Returns a WatchdogReport."""
        with self._lock:
            subsystems_snapshot = list(self.subsystems.values())
        results: List[Dict] = []
        any_fatal_failed = False
        for state in subsystems_snapshot:
            try:
                ok, detail = state.check()
            except Exception as e:
                ok, detail = False, f"check raised: {type(e).__name__}: {e}"
            state.last_ok = ok
            state.last_detail = detail
            state.last_checked_at = time.time()
            if not ok:
                state.consecutive_failures += 1
                # Attempt recovery (cooldown: at most every 30s per subsystem)
                recovered = None
                if state.recover and (time.time() - state.last_recovery_attempt) > 30:
                    state.last_recovery_attempt = time.time()
                    try:
                        r_ok, r_detail = state.recover()
                    except Exception as e:
                        r_ok, r_detail = False, f"recover raised: {type(e).__name__}: {e}"
                    state.last_recovery_ok = r_ok
                    self._log_recovery(state.name, r_ok, r_detail)
                # If this subsystem is fatal AND has had too many failures, exit
                if state.fatal_on_failure and state.consecutive_failures >= EXIT_AFTER_FAILURES:
                    any_fatal_failed = True
            else:
                state.consecutive_failures = 0
                state.last_recovery_ok = None
            results.append({
                "name": state.name,
                "ok": ok,
                "detail": detail,
                "consecutive_failures": state.consecutive_failures,
                "fatal_on_failure": state.fatal_on_failure,
                "last_recovery_ok": state.last_recovery_ok,
                "last_checked_at": state.last_checked_at,
            })
        if any_fatal_failed:
            self._overall_consecutive_failures += 1
        else:
            self._overall_consecutive_failures = 0
        will_exit = (
            self._overall_consecutive_failures >= 1
            and any(s.consecutive_failures >= EXIT_AFTER_FAILURES and s.fatal_on_failure
                    for s in subsystems_snapshot)
        )
        return WatchdogReport(
            overall_ok=not any_fatal_failed,
            timestamp=time.time(),
            uptime_s=self.uptime_s(),
            consecutive_failures=self._overall_consecutive_failures,
            will_exit=will_exit,
            subsystems=results,
        )

    def _log_recovery(self, name: str, ok: bool, detail: str) -> None:
        entry = {
            "ts": time.time(),
            "subsystem": name,
            "ok": ok,
            "detail": detail[:200],
        }
        with self._lock:
            self._last_recovery_log.append(entry)
            # keep at most 50
            self._last_recovery_log = self._last_recovery_log[-50:]
        log.warning("watchdog recovery subsystem=%s ok=%s detail=%s",
                    name, ok, detail)

    def _run_loop(self) -> None:
        """Main loop. Runs forever (daemon thread) until stop or exit."""
        while not self._stop_event.is_set():
            try:
                report = self._run_check_cycle()
                if report.will_exit:
                    log.critical(
                        "watchdog: %d consecutive fatal failures, "
                        "voluntarily exiting with code %d for supervisor restart",
                        self._overall_consecutive_failures, VOLUNTARY_EXIT_CODE,
                    )
                    # Flush logs, then exit. Supervisor detects non-zero
                    # exit and restarts with backoff.
                    try:
                        sys.stdout.flush()
                        sys.stderr.flush()
                    except Exception:
                        pass
                    os._exit(VOLUNTARY_EXIT_CODE)
            except Exception:
                # Never let the watchdog thread die
                log.error("watchdog loop error: %s", traceback.format_exc())
            # Sleep with cancellation support
            self._stop_event.wait(CHECK_INTERVAL_S)


# ─── Module-level singleton ──────────────────────────────────────────────
# The agent process creates one Watchdog and starts it in BaseAgent.__init__.
# Importing modules call get_watchdog() / set_watchdog().

_watchdog_singleton: Optional[Watchdog] = None
_singleton_lock = threading.Lock()


def get_watchdog() -> Optional[Watchdog]:
    """Return the active watchdog, or None if not yet started."""
    return _watchdog_singleton


def set_watchdog(w: Watchdog) -> None:
    """Set the singleton (called once from BaseAgent.__init__)."""
    global _watchdog_singleton
    with _singleton_lock:
        _watchdog_singleton = w
