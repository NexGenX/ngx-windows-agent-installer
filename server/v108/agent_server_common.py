"""
NexGenX Agent Server - Cross-Platform Common Base
==================================================

Shared code for Windows / macOS / Linux agent servers. Provides:

- FastAPI app setup (CORS, metadata)
- Access code generation / storage / verification (SHA-256 + plain)
- File location helpers per-platform (`C:\\ProgramData\\NexGenX\\`,
  `/etc/nexgenx/`, `~/.config/nexgenx/`)
- Health, screenshot, input control, and info endpoints that are identical
  across all three platforms (input + screenshot use pyautogui / mss which
  work everywhere).
- The startup banner, run_server() helper, and CLI parsing.

Platform-specific modules (agent_server.py, agent_server_mac.py,
agent_server_linux.py) subclass `BaseAgent` and add their own:

- /tree, /tree/clickable, /find, /window/list   (accessibility tree)
- platform-specific screenshot fallback (only macOS uses osascript+screencapture;
  Windows + Linux both work fine with mss)

All three platforms expose the **same REST API** and respond with the same
JSON shapes so the AI gateway client (`windows_agent.py`) works unchanged.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import io
import logging
import os
import platform
import secrets
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Deque, Dict, List, Optional, Tuple

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.middleware.base import BaseHTTPMiddleware

# ─── Cross-platform input + screenshot libs ───────────────────────────────────
# pyautogui works on Windows / macOS / Linux (X11; Wayland needs python-xlib).
# mss works on Windows / macOS / Linux.
import pyautogui
import mss

# pyautogui safety: fail fast if cursor in top-left corner
pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.05


# ─── Access code paths (per-platform) ─────────────────────────────────────────

def _get_access_code_dir() -> Path:
    """Return the platform-appropriate directory for access code storage.

    Windows : C:\\ProgramData\\NexGenX\\
    macOS   : /etc/nexgenx/   (root-owned, shared across users)
    Linux   : /etc/nexgenx/   (root-owned, shared across users)

    Override with NEXGENX_DATA_DIR env var for tests/dev.
    """
    override = os.environ.get("NEXGENX_DATA_DIR")
    if override:
        return Path(override) / "NexGenX"

    system = platform.system()
    if system == "Windows":
        base = Path(os.environ.get("PROGRAMDATA", "C:/ProgramData"))
        return base / "NexGenX"
    # macOS + Linux
    return Path("/etc/nexgenx")


ACCESS_CODE_DIR = _get_access_code_dir()
ACCESS_CODE_FILE = ACCESS_CODE_DIR / "agent_access.txt"
ACCESS_CODE_HASH_FILE = ACCESS_CODE_DIR / "agent_access_hash.txt"
AUDIT_LOG_FILE = ACCESS_CODE_DIR / "audit.log"


# ─── Access code logic ────────────────────────────────────────────────────────

def generate_access_code() -> str:
    """Generate a new secure access code (16 hex chars)."""
    return secrets.token_hex(8)


def save_access_code(code: str) -> None:
    """Save access code (plain) and its SHA-256 hash. Best-effort chmod 0o600."""
    ACCESS_CODE_DIR.mkdir(parents=True, exist_ok=True)
    ACCESS_CODE_FILE.write_text(code)
    try:
        os.chmod(ACCESS_CODE_FILE, 0o600)
    except (PermissionError, OSError):
        pass  # on Windows chmod is a no-op for current user only

    h = hashlib.sha256(code.encode()).hexdigest()
    ACCESS_CODE_HASH_FILE.write_text(h)
    try:
        os.chmod(ACCESS_CODE_HASH_FILE, 0o600)
    except (PermissionError, OSError):
        pass


def load_access_code() -> Tuple[str, str]:
    """Load existing access code + hash, or generate new ones on first run."""
    ACCESS_CODE_DIR.mkdir(parents=True, exist_ok=True)

    if ACCESS_CODE_FILE.exists() and ACCESS_CODE_HASH_FILE.exists():
        code = ACCESS_CODE_FILE.read_text().strip()
        hash_stored = ACCESS_CODE_HASH_FILE.read_text().strip()
        if code and hash_stored:
            return code, hash_stored

    # First run — generate and save
    code = generate_access_code()
    save_access_code(code)
    hash_stored = hashlib.sha256(code.encode()).hexdigest()
    return code, hash_stored


def verify_access_code(code: Optional[str], stored_hash: str) -> bool:
    """Constant-time-ish SHA-256 verification (not strictly constant-time, but fine)."""
    if not code:
        return False
    return hashlib.sha256(code.encode()).hexdigest() == stored_hash


# ─── Global state (per-process) ───────────────────────────────────────────────
_access_code: Optional[str] = None
_access_hash: Optional[str] = None
_access_lock = threading.Lock()


def get_access() -> Tuple[str, str]:
    """Lazy-load the access code (thread-safe)."""
    global _access_code, _access_hash
    with _access_lock:
        if _access_code is None:
            _access_code, _access_hash = load_access_code()
        return _access_code, _access_hash


def reset_access_code_global() -> str:
    """Generate + save a new access code, update in-memory state."""
    global _access_code, _access_hash
    new_code = generate_access_code()
    save_access_code(new_code)
    with _access_lock:
        _access_code = new_code
        _access_hash = hashlib.sha256(new_code.encode()).hexdigest()
    return new_code


# ─── Base agent class ─────────────────────────────────────────────────────────

class BaseAgent:
    """Subclass and override `platform_name` + tree/find/window methods.

    Subclasses get a FastAPI app with all the platform-independent routes
    already wired up. They just add `/tree`, `/tree/clickable`, `/find`,
    `/window/list`, and (optionally) override `screenshot_to_bytes`.
    """

    platform_name: str = "unknown"  # set by subclass: "windows" / "macos" / "linux"
    agent_version: str = "1.0.8"
    # When the watchdog exits voluntarily (code 73), the supervisor restarts
    # the process. We capture the reason for /info reporting.
    last_restart_reason: str = "initial_start"
    # Will be set by supervisor; we read NGX_AGENT_GIT_SHA env if set.
    git_sha: str = "unknown"

    def __init__(self):
        self.app = FastAPI(
            title=f"NexGenX {self.platform_name.title()} Agent",
            version=self.agent_version,
        )
        # Restrict CORS to known portal/control origins. Wildcard + credentials
        # is a browser-blocked combo anyway; tighter list reduces attack surface.
        self.app.add_middleware(
            CORSMiddleware,
            allow_origins=[
                "http://localhost:3000",
                "http://localhost:5173",
                "http://127.0.0.1:3000",
                "http://127.0.0.1:5173",
            ],
            allow_credentials=False,
            allow_methods=["GET", "POST"],
            allow_headers=["X-Access-Code", "Content-Type"],
        )
        # Security headers on every response
        @self.app.middleware("http")
        async def add_security_headers(request, call_next):
            response = await call_next(request)
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Cache-Control"] = "no-store"
            return response
        # Capture git SHA + restart reason from env (set by supervisor)
        self.git_sha = os.environ.get("NGX_AGENT_GIT_SHA", "unknown")
        self.last_restart_reason = os.environ.get(
            "NGX_AGENT_RESTART_REASON", "initial_start"
        )
        # Start the in-process watchdog (v1.06+). The watchdog runs
        # subsystem checks in a daemon thread and exits with code 73
        # if recovery is impossible — the supervisor then restarts us.
        self._watchdog = None
        try:
            from agent_watchdog import Watchdog, set_watchdog
            wd = Watchdog()
            wd.start()
            self._watchdog = wd
            set_watchdog(wd)
        except Exception as e:
            # Watchdog is best-effort; if it can't start, the agent still runs.
            try:
                AUDIT_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
                with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
                    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    f.write(f"[{ts}] [watchdog] [start_failed] {e}\n")
            except Exception:
                pass
        self._register_routes()

    # ─── Auth dependency ───────────────────────────────────────────────────

    def require_access(self, x_access_code: Optional[str] = Header(None)) -> str:
        """FastAPI dependency — verifies X-Access-Code header."""
        _, stored_hash = get_access()
        if not verify_access_code(x_access_code, stored_hash):
            raise HTTPException(status_code=401, detail="Invalid or missing access code")
        return x_access_code

    # ─── Screenshot (overridable for platform-native fallbacks) ─────────────

    def screenshot_to_bytes(self, monitor: Optional[dict] = None) -> bytes:
        """Default screenshot via mss. macOS subclass falls back to screencapture."""
        with mss.mss() as s:
            mon = monitor or s.monitors[1]
            img = s.grab(mon)
            from PIL import Image
            buf = io.BytesIO()
            Image.frombytes("RGB", img.size, img.rgb).save(buf, format="PNG")
            return buf.getvalue()

    # ─── Platform-specific hooks (override in subclass) ────────────────────

    def get_tree_impl(self, depth: int) -> dict:
        """Return {"tree": <dict|None>, "platform": <str>, "error": <str|None>}."""
        raise NotImplementedError

    def get_clickable_impl(self) -> dict:
        """Return {"elements": [...], "count": int, "platform": str, "error": str|None}."""
        raise NotImplementedError

    def find_element_impl(self, text: str, exact: bool) -> dict:
        """Return {"found": bool, ...} dict."""
        raise NotImplementedError

    def list_windows_impl(self) -> dict:
        """Return {"windows": [...], "count": int, "error": str|None}."""
        raise NotImplementedError

    # ─── Route registration ─────────────────────────────────────────────────

    # Whitelists (pyautogui accepts more, but these are the safe set)
    ALLOWED_BUTTONS = {"left", "right", "middle"}
    # Subset of pyautogui's key names we permit. Anything else gets rejected.
    _letters_lower = {chr(c) for c in range(ord('a'), ord('z')+1)}
    _letters_upper = {chr(c) for c in range(ord('A'), ord('Z')+1)}
    _digits = {str(i) for i in range(10)}
    _modifiers = {
        "enter", "return", "tab", "escape", "esc", "space", "backspace",
        "delete", "del", "home", "end", "pageup", "pagedown", "pgup", "pgdn",
        "up", "down", "left", "right", "capslock", "numlock", "scrolllock",
        "insert", "printscreen", "pause", "menu",
    }
    _function_keys = {f"f{i}" for i in range(1, 13)}
    _modifier_keys = {
        "ctrl", "ctrlleft", "ctrlright", "alt", "altleft", "altright",
        "shift", "shiftleft", "shiftright", "win", "winleft", "winright",
        "cmd", "command", "option",
    }
    ALLOWED_KEYS = _letters_lower | _letters_upper | _digits | _modifiers | _function_keys | _modifier_keys
    # Bounds
    MAX_TYPE_CHARS = 1000
    MAX_TREE_DEPTH = 10
    SCROLL_LIMIT = 100
    COORD_LIMIT = 100000  # 100k pixels in any direction

    # Simple per-IP rate limiter (in-memory, per-process)
    _rate_buckets: Dict[str, List[float]] = {}
    _rate_lock = threading.Lock()
    RATE_LIMIT_PER_MIN = 60
    RATE_LIMIT_PER_HOUR = 600
    RESET_LIMIT_PER_HOUR = 5  # tighter limit on code reset

    def _rate_check(self, ip: str, per_min: int = None, per_hour: int = None) -> bool:
        """Returns True if request is allowed, False if over limit."""
        per_min = per_min or self.RATE_LIMIT_PER_MIN
        per_hour = per_hour or self.RATE_LIMIT_PER_HOUR
        now = time.time()
        with self._rate_lock:
            bucket = self._rate_buckets.setdefault(ip, [])
            # Prune old entries
            cutoff_hour = now - 3600
            cutoff_min = now - 60
            bucket[:] = [t for t in bucket if t > cutoff_hour]
            if len(bucket) >= per_hour:
                return False
            recent_min = [t for t in bucket if t > cutoff_min]
            if len(recent_min) >= per_min:
                return False
            bucket.append(now)
            return True

    def _client_ip(self, request: Request) -> str:
        return (request.client.host if request.client else "unknown")

    def _audit(self, ip: str, endpoint: str, outcome: str,
               duration_ms: int = 0, detail: str = "") -> None:
        """Append an entry to the audit log. Sanitizes long payloads."""
        try:
            AUDIT_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            line = f"[{ts}] [{ip}] [{endpoint}] [{outcome}] [{duration_ms}ms] {detail}\n"
            with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line)
        except Exception:
            # Audit logging must never crash the server
            pass

    def _register_routes(self):
        app = self.app
        dep = self.require_access

        @app.get("/ping")
        async def ping(request: Request):
            ip = self._client_ip(request)
            t0 = time.time()
            r = {
                "status": "ok",
                "platform": platform.system(),
                "agent_platform": self.platform_name,
                "hostname": socket.gethostname(),
            }
            self._audit(ip, "/ping", "ok", int((time.time()-t0)*1000))
            return r

        @app.get("/access_code")
        async def get_code(request: Request):
            ip = self._client_ip(request)
            if not self._rate_check(ip):
                self._audit(ip, "/access_code", "rate_limited")
                raise HTTPException(status_code=429, detail="Rate limit exceeded")
            code, _ = get_access()
            return {
                "masked": code[:4] + "****" + code[-4:],
                "length": len(code),
                "message": (
                    f"Full code shown in desktop notification / "
                    f"saved to {ACCESS_CODE_FILE}"
                ),
            }

        @app.get("/screenshot")
        async def get_screenshot(request: Request,
                                 x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            t0 = time.time()
            if not self._rate_check(ip):
                self._audit(ip, "/screenshot", "rate_limited")
                raise HTTPException(status_code=429, detail="Rate limit exceeded")
            try:
                dep(x_access_code)
            except HTTPException as e:
                self._audit(ip, "/screenshot", "auth_fail", int((time.time()-t0)*1000))
                raise
            try:
                png_bytes = self.screenshot_to_bytes()
            except Exception as e:
                err = str(e)
                hint = (
                    "Screenshot failed. Agent may be in Session 0 (no desktop). "
                    "Start via Scheduled Task NexGenXAgent (Interactive AtLogOn) "
                    "then Start-ScheduledTask — do not use Start-Process."
                )
                self._audit(ip, "/screenshot", "fail", int((time.time()-t0)*1000),
                            f"error={err[:200]}")
                raise HTTPException(
                    status_code=500,
                    detail={"error": err, "hint": hint},
                )
            self._audit(ip, "/screenshot", "ok", int((time.time()-t0)*1000),
                        f"size={len(png_bytes)}")
            return StreamingResponse(
                io.BytesIO(png_bytes),
                media_type="image/png",
                headers={"Content-Disposition": "inline"},
            )

        @app.post("/click")
        async def click(request: Request, x: int, y: int, button: str = "left",
                        x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            # Validate inputs
            if button not in self.ALLOWED_BUTTONS:
                self._audit(ip, "/click", "invalid_input", detail=f"button={button}")
                raise HTTPException(status_code=400, detail=f"button must be one of {self.ALLOWED_BUTTONS}")
            if not (-self.COORD_LIMIT <= x <= self.COORD_LIMIT and -self.COORD_LIMIT <= y <= self.COORD_LIMIT):
                self._audit(ip, "/click", "invalid_input", detail=f"coords=({x},{y})")
                raise HTTPException(status_code=400, detail="coordinates out of range")
            # Bounds check against actual screen
            try:
                sw, sh = pyautogui.size()
                if not (0 <= x <= sw and 0 <= y <= sh):
                    self._audit(ip, "/click", "out_of_bounds",
                                detail=f"screen=({sw},{sh}) click=({x},{y})")
                    raise HTTPException(status_code=400, detail=f"coordinates outside screen ({sw}x{sh})")
            except HTTPException:
                raise
            except Exception:
                pass  # if pyautogui can't report size, allow
            dep(x_access_code)
            pyautogui.click(x, y, button=button)
            self._audit(ip, "/click", "ok", detail=f"({x},{y},{button})")
            return {"ok": True, "x": x, "y": y, "button": button}

        @app.post("/doubleclick")
        async def doubleclick(request: Request, x: int, y: int,
                              x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not (-self.COORD_LIMIT <= x <= self.COORD_LIMIT and -self.COORD_LIMIT <= y <= self.COORD_LIMIT):
                self._audit(ip, "/doubleclick", "invalid_input")
                raise HTTPException(status_code=400, detail="coordinates out of range")
            dep(x_access_code)
            pyautogui.doubleClick(x, y)
            self._audit(ip, "/doubleclick", "ok", detail=f"({x},{y})")
            return {"ok": True, "x": x, "y": y}

        @app.post("/move")
        async def move(request: Request, x: int, y: int,
                       x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not (-self.COORD_LIMIT <= x <= self.COORD_LIMIT and -self.COORD_LIMIT <= y <= self.COORD_LIMIT):
                self._audit(ip, "/move", "invalid_input")
                raise HTTPException(status_code=400, detail="coordinates out of range")
            dep(x_access_code)
            pyautogui.moveTo(x, y)
            return {"ok": True, "x": x, "y": y}

        @app.post("/type")
        async def type_text(request: Request, text: str,
                            x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not text:
                self._audit(ip, "/type", "empty")
                return {"ok": True, "chars": 0}
            if len(text) > self.MAX_TYPE_CHARS:
                self._audit(ip, "/type", "too_long", detail=f"len={len(text)}")
                raise HTTPException(
                    status_code=400,
                    detail=f"text too long (max {self.MAX_TYPE_CHARS} chars)",
                )
            dep(x_access_code)
            pyautogui.write(text, interval=0.02)
            # Don't log full text in audit, just length + preview
            preview = text[:50].replace("\n", "\\n")
            self._audit(ip, "/type", "ok", detail=f"len={len(text)} preview='{preview}'")
            return {"ok": True, "chars": len(text)}

        @app.post("/key")
        async def keypress(request: Request, key: str,
                           x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if key.lower() not in self.ALLOWED_KEYS:
                self._audit(ip, "/key", "invalid_key", detail=f"key={key}")
                raise HTTPException(status_code=400, detail=f"key not in whitelist")
            dep(x_access_code)
            pyautogui.press(key)
            self._audit(ip, "/key", "ok", detail=f"key={key}")
            return {"ok": True, "key": key}

        @app.post("/hotkey")
        async def hotkey(request: Request, key1: str,
                         key2: Optional[str] = None, key3: Optional[str] = None,
                         x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            keys = [k for k in [key1, key2, key3] if k]
            for k in keys:
                if k.lower() not in self.ALLOWED_KEYS:
                    self._audit(ip, "/hotkey", "invalid_key", detail=f"key={k}")
                    raise HTTPException(status_code=400, detail=f"key '{k}' not in whitelist")
            dep(x_access_code)
            pyautogui.hotkey(*keys)
            self._audit(ip, "/hotkey", "ok", detail=f"keys={keys}")
            return {"ok": True, "keys": keys}

        @app.post("/scroll")
        async def scroll(request: Request, clicks: int,
                         x: Optional[int] = None, y: Optional[int] = None,
                         x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not (-self.SCROLL_LIMIT <= clicks <= self.SCROLL_LIMIT):
                self._audit(ip, "/scroll", "invalid_clicks", detail=f"clicks={clicks}")
                raise HTTPException(status_code=400,
                                    detail=f"clicks must be between -{self.SCROLL_LIMIT} and {self.SCROLL_LIMIT}")
            if x is not None and y is not None:
                if not (-self.COORD_LIMIT <= x <= self.COORD_LIMIT and -self.COORD_LIMIT <= y <= self.COORD_LIMIT):
                    self._audit(ip, "/scroll", "invalid_input")
                    raise HTTPException(status_code=400, detail="coordinates out of range")
            dep(x_access_code)
            if x is not None and y is not None:
                pyautogui.moveTo(x, y)
            pyautogui.scroll(clicks)
            return {"ok": True, "clicks": clicks}

        @app.get("/tree")
        async def get_tree(request: Request, depth: int = 3,
                           x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not (1 <= depth <= self.MAX_TREE_DEPTH):
                self._audit(ip, "/tree", "invalid_depth", detail=f"depth={depth}")
                raise HTTPException(status_code=400,
                                    detail=f"depth must be between 1 and {self.MAX_TREE_DEPTH}")
            dep(x_access_code)
            return self.get_tree_impl(depth)

        @app.get("/tree/clickable")
        async def get_clickable(request: Request,
                                x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not self._rate_check(ip):
                self._audit(ip, "/tree/clickable", "rate_limited")
                raise HTTPException(status_code=429, detail="Rate limit exceeded")
            dep(x_access_code)
            return self.get_clickable_impl()

        @app.get("/find")
        async def find_element(request: Request, text: str, exact: bool = False,
                               x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not text or len(text) > 200:
                raise HTTPException(status_code=400, detail="text must be 1-200 chars")
            dep(x_access_code)
            return self.find_element_impl(text, exact)

        @app.get("/window/list")
        async def list_windows(request: Request,
                               x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            if not self._rate_check(ip):
                self._audit(ip, "/window/list", "rate_limited")
                raise HTTPException(status_code=429, detail="Rate limit exceeded")
            dep(x_access_code)
            return self.list_windows_impl()

        @app.get("/vnc")
        async def vnc_status(request: Request,
                             x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            dep(x_access_code)
            sock = socket.socket()
            sock.settimeout(1)
            try:
                sock.connect(("127.0.0.1", 6080))
                return {"novnc_running": True, "url": "http://127.0.0.1:6080/vnc.html"}
            except Exception:
                return {
                    "novnc_running": False,
                    "url": None,
                    "hint": "Install noVNC (e.g. websockify + novnc) and run on :6080",
                }
            finally:
                sock.close()

        @app.get("/info")
        async def system_info(request: Request,
                              x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            dep(x_access_code)
            w, h = pyautogui.size()
            try:
                with mss.mss() as s:
                    n_mon = len(s.monitors)
            except Exception:
                n_mon = 0
            # Watchdog status (if available)
            wd_status = None
            if self._watchdog is not None:
                try:
                    wd_status = {
                        "uptime_s": round(self._watchdog.uptime_s(), 1),
                        "consecutive_failures": self._watchdog._overall_consecutive_failures,
                    }
                except Exception:
                    pass
            return {
                "hostname": socket.gethostname(),
                "platform": platform.system(),
                "agent_platform": self.platform_name,
                "screen_width": w,
                "screen_height": h,
                "monitors": n_mon,
                "python_version": sys.version,
                "agent_version": self.agent_version,
                "git_sha": self.git_sha,
                "last_restart_reason": self.last_restart_reason,
                "watchdog": wd_status,
                "access_code_file": str(ACCESS_CODE_FILE),
            }

        @app.get("/health/deep")
        async def health_deep(request: Request,
                             x_access_code: Optional[str] = Header(None)):
            """Run a synchronous full health check on all subsystems.
            Returns JSON with overall_ok, per-subsystem detail, and the
            last 20 watchdog recovery attempts. Used by operators and
            CI to verify the agent is healthy. 503 if any fatal
            subsystem has hit the failure threshold (we're about to
            exit for supervisor restart).
            """
            ip = self._client_ip(request)
            t0 = time.time()
            dep(x_access_code)
            if self._watchdog is None:
                return {
                    "overall_ok": False,
                    "error": "watchdog not running",
                    "agent_version": self.agent_version,
                }
            report = self._watchdog.check_all()
            recoveries = self._watchdog.last_recovery_log(20)
            status = 503 if report.will_exit else 200
            self._audit(ip, "/health/deep",
                        "ok" if report.overall_ok else "degraded",
                        int((time.time() - t0) * 1000),
                        detail=f"failures={report.consecutive_failures} will_exit={report.will_exit}")
            return JSONResponse(
                status_code=status,
                content={
                    **report.to_dict(),
                    "agent_version": self.agent_version,
                    "git_sha": self.git_sha,
                    "uptime_s": round(self._watchdog.uptime_s(), 1),
                    "last_restart_reason": self.last_restart_reason,
                    "recent_recoveries": recoveries,
                },
            )

        @app.post("/access_code/reset")
        async def reset_access_code(request: Request,
                                    x_access_code: Optional[str] = Header(None)):
            ip = self._client_ip(request)
            # Tighter limit on code resets
            if not self._rate_check(ip, per_min=2, per_hour=self.RESET_LIMIT_PER_HOUR):
                self._audit(ip, "/access_code/reset", "rate_limited")
                raise HTTPException(status_code=429, detail="Rate limit exceeded (resets)")
            dep(x_access_code)
            new_code = reset_access_code_global()
            self._audit(ip, "/access_code/reset", "ok",
                        detail=f"new_masked={new_code[:4]}****")
            return {
                "ok": True,
                "new_code_masked": new_code[:4] + "****" + new_code[-4:],
                "message": (
                    f"New access code saved. Retrieve from {ACCESS_CODE_FILE} "
                    f"on the desktop."
                ),
            }

    # ─── Server bootstrap ──────────────────────────────────────────────────

    def print_startup_info(self, code: str, port: int = 9400) -> None:
        """Print a friendly startup banner with the access code."""
        try:
            ip = socket.gethostbyname(socket.gethostname())
        except Exception:
            ip = "127.0.0.1"
        print("=" * 60)
        print(f"  NexGenX {self.platform_name.title()} Agent Server v{self.agent_version}")
        print("=" * 60)
        print(f"  Access Code: {code}")
        print(f"  Server IP:   {ip}")
        print(f"  Port:        {port}")
        print(f"  Docs:        http://{ip}:{port}/docs")
        print("=" * 60)
        print("  NOTE: Access code shown above. Keep it secret!")
        print("        It is also saved to:")
        print(f"        {ACCESS_CODE_FILE}")
        print("=" * 60)

    def run(self, port: int = 9400, host: str = "0.0.0.0", quiet: bool = False):
        """Start the FastAPI server (blocking)."""
        import uvicorn
        code, _ = get_access()
        if not quiet:
            self.print_startup_info(code, port=port)
        uvicorn.run(
            self.app, host=host, port=port, log_level="info",
            access_log=False, lifespan="off",
        )


# ─── CLI helper (shared) ─────────────────────────────────────────────────────

def add_common_cli_args(parser: argparse.ArgumentParser) -> None:
    """Add the --port / --host / --quiet flags to an argparse parser."""
    parser.add_argument("--port", type=int, default=9400,
                        help="Port to listen on (default: 9400)")
    parser.add_argument("--host", type=str, default="0.0.0.0",
                        help="Host to bind to (default: 0.0.0.0)")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress startup banner")
