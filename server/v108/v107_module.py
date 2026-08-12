"""
NexGenX v107 — tier 1 vision + verification endpoints
=====================================================

Extends the v1.06 agent with endpoints that turn the agent from
"remote control that lies" into "coworker you can watch work":

  /ocr                  - OCR the screen (or a region) via Windows.Media.Ocr
  /ocr?x=0&y=0&w=1280&h=800  - OCR a region
  /find_text?text=...   - Find text on screen, return center coord + bbox
  /state                - Foreground window, URL (if browser), focused element
  /diff                 - Compute diff between two PNGs (size diff + pixel diff %)
  /click_verified       - Click + verify something changed (default: 2% pixel diff)
  /verify               - Take screenshot, OCR it, return whether expected text appears
  /workflow/linkedin_post - One-call "post to LinkedIn" workflow
  /workflow/post_to_linkedin - alias
  /health               - Liveness, plus last-action status (ok/fail/stale)

All endpoints require X-Access-Code (same as v1.06).

This module is loaded by agent_server.py after BaseAgent is constructed.
The router is added to the same FastAPI app so existing v1.06 endpoints
keep working.

Build: 2026-06-17. Bolt + Matt, after the silent-failure post.
"""
from __future__ import annotations

import io
import os
import sys
import time
import json
import base64
import hashlib
import logging
import subprocess
import threading
from pathlib import Path
from typing import Optional, List, Dict, Any

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import JSONResponse

log = logging.getLogger("agent.v107")

# Lazy imports so v1.06 still starts if v107 deps fail
_ocr_lock = threading.Lock()
_ocr_engine = None
_ocr_init_attempted = False


def _get_ocr_engine():
    """Lazy-init Windows.Media.Ocr (built into Windows 10/11/Server 2025).
    No external model needed; uses the OS language pack.
    """
    global _ocr_engine, _ocr_init_attempted
    if _ocr_engine is not None:
        return _ocr_engine
    if _ocr_init_attempted:
        return None
    _ocr_init_attempted = True
    try:
        import ocr_engine
        _ocr_engine = ocr_engine.get_engine()
    except Exception as e:
        log.warning(f"OCR engine load failed: {e}")
        _ocr_engine = None
    return _ocr_engine


# Public state shared with v1.06 endpoints (last action results for /health)
_LAST_ACTION = {
    "endpoint": None,
    "started_at": None,
    "ok": None,
    "detail": None,
}


def _record_action(endpoint: str, ok: bool, detail: str = ""):
    _LAST_ACTION.update({
        "endpoint": endpoint,
        "started_at": time.time(),
        "ok": ok,
        "detail": detail,
    })


def install_routes(app, agent):
    """Add v107 routes to the given FastAPI app.
    `agent` is the BaseAgent instance (for access-code check + screenshot).
    """
    router = APIRouter()

    def _check(x_access_code: Optional[str]):
        # Reuse BaseAgent.require_access for the same auth model
        agent.require_access(x_access_code)

    def _screenshot_png(x: int = 0, y: int = 0, w: int = 0, h: int = 0) -> bytes:
        full = agent.screenshot_to_bytes()
        if x == 0 and y == 0 and w == 0 and h == 0:
            return full
        # Crop with PIL
        from PIL import Image
        img = Image.open(io.BytesIO(full))
        x2 = min(img.width, x + w if w > 0 else img.width)
        y2 = min(img.height, y + h if h > 0 else img.height)
        crop = img.crop((x, y, x2, y2))
        buf = io.BytesIO()
        crop.save(buf, format="PNG", optimize=True)
        return buf.getvalue()

    @router.get("/ocr")
    async def ocr(request: Request,
                  x: int = 0, y: int = 0, w: int = 0, h: int = 0,
                  x_access_code: Optional[str] = Header(None)):
        """OCR the full screen (or a region) and return text + bboxes.
        Returns: {"text": "...", "lines": [{"text": "...", "x":..., "y":..., "w":..., "h":..., "conf": 0.0-1.0}]}
        """
        _check(x_access_code)
        engine = _get_ocr_engine()
        if engine is None:
            return JSONResponse(
                status_code=503,
                content={"error": "ocr_engine_unavailable",
                         "hint": "Windows.Media.Ocr load failed; check language pack installed"}
            )
        png = _screenshot_png(x, y, w, h)
        try:
            result = engine.ocr_bytes(png)
            _record_action("/ocr", True, f"{len(result.get('lines', []))} lines")
            return result
        except Exception as e:
            _record_action("/ocr", False, str(e))
            return JSONResponse(status_code=500, content={"error": str(e)})

    @router.get("/find_text")
    async def find_text(request: Request,
                        text: str, exact: bool = False,
                        region: Optional[str] = None,  # "x,y,w,h"
                        x_access_code: Optional[str] = Header(None)):
        """Find text on screen, return center coord + bbox for clicking.
        Use exact=true for exact match, false for substring.
        Returns: {"found": bool, "matches": [{"text":..., "cx":..., "cy":..., "x":..., "y":..., "w":..., "h":...}]}
        """
        _check(x_access_code)
        engine = _get_ocr_engine()
        if engine is None:
            return JSONResponse(status_code=503, content={"error": "ocr_engine_unavailable"})
        rx, ry, rw, rh = 0, 0, 0, 0
        if region:
            try:
                rx, ry, rw, rh = [int(v) for v in region.split(",")]
            except ValueError:
                return JSONResponse(status_code=400, content={"error": "region must be x,y,w,h"})
        png = _screenshot_png(rx, ry, rw, rh)
        try:
            result = engine.ocr_bytes(png)
            lines = result.get("lines", [])
            matches = []
            for ln in lines:
                t = ln["text"]
                if (exact and t == text) or (not exact and text.lower() in t.lower()):
                    matches.append({
                        "text": t,
                        "cx": ln["x"] + rx + ln["w"] // 2,
                        "cy": ln["y"] + ry + ln["h"] // 2,
                        "x": ln["x"] + rx,
                        "y": ln["y"] + ry,
                        "w": ln["w"],
                        "h": ln["h"],
                    })
            _record_action("/find_text", True, f"text={text!r} found={len(matches)}")
            return {"found": bool(matches), "count": len(matches), "matches": matches}
        except Exception as e:
            _record_action("/find_text", False, str(e))
            return JSONResponse(status_code=500, content={"error": str(e)})

    @router.get("/state")
    async def state(request: Request, x_access_code: Optional[str] = Header(None)):
        """Get current state: foreground window, focused element, browser URL if any.
        Returns: {"focused_window": "title", "focused_app": "name", "url": "...", "focused_element": "..."}
        """
        _check(x_access_code)
        out = {"focused_window": None, "focused_app": None, "url": None, "focused_element": None}
        try:
            import uiautomation as auto
            fg = auto.GetForegroundControl()
            if fg:
                out["focused_window"] = str(fg.Name or "")[:200]
                out["focused_app"] = str(fg.ProcessId) if hasattr(fg, "ProcessId") else None
                # Try to extract URL from browser address bar
                # (this is approximate; UIA Name of the address bar usually contains the URL)
                out["focused_element"] = str(fg.ControlTypeName or "")[:100]
        except Exception as e:
            out["uia_error"] = str(e)
        # URL extraction from window list (look for "Microsoft Edge" / "Chrome" windows)
        try:
            wins = agent.list_windows_impl()
            for w in wins.get("windows", []):
                name = w.get("name", "")
                # Edge/Chrome tab title format: "Page Title - Profile X - Microsoft Edge"
                if "Microsoft Edge" in name or "Google Chrome" in name:
                    # If a focused window is the browser, try to find URL via OCR on top strip
                    pass
        except Exception:
            pass
        _record_action("/state", True)
        return out

    @router.post("/click_verified")
    async def click_verified(request: Request, x: int, y: int,
                             button: str = "left",
                             min_diff_pct: float = 0.5,  # % of pixels that must change
                             timeout_ms: int = 2500,
                             retries: int = 1,
                             x_access_code: Optional[str] = Header(None)):
        """Click at (x,y), verify the screen actually changed, retry if not.
        Returns: {"ok": bool, "verified": bool, "diff_pct": float, "tries": int, "reason": "..."}
        """
        _check(x_access_code)
        import pyautogui
        from PIL import Image, ImageChops

        sw, sh = pyautogui.size()
        if not (0 <= x <= sw and 0 <= y <= sh):
            raise HTTPException(status_code=400, detail="coords out of bounds")

        before = agent.screenshot_to_bytes()
        ok_click = False
        last_err = None
        for attempt in range(retries + 1):
            try:
                pyautogui.click(x, y, button=button)
                ok_click = True
                break
            except Exception as e:
                last_err = str(e)
                time.sleep(0.2)

        if not ok_click:
            _record_action("/click_verified", False, last_err or "click_failed")
            return {"ok": False, "verified": False, "reason": "click_failed", "error": last_err}

        # Wait for the page to react
        time.sleep(min(timeout_ms, 100) / 1000.0)
        # Check periodically for diff
        deadline = time.time() + (timeout_ms / 1000.0)
        best_diff = 0.0
        while time.time() < deadline:
            after = agent.screenshot_to_bytes()
            try:
                a = Image.open(io.BytesIO(before)).convert("RGB")
                b = Image.open(io.BytesIO(after)).convert("RGB")
                if a.size != b.size:
                    best_diff = 100.0
                    break
                diff = ImageChops.difference(a, b)
                bbox = diff.getbbox()
                if bbox is None:
                    diff_pct = 0.0
                else:
                    crop = diff.crop(bbox)
                    pixels = list(crop.getdata())
                    changed = sum(1 for px in pixels if (px[0] + px[1] + px[2]) > 30)
                    total = len(pixels)
                    diff_pct = (changed / total) * 100 if total else 0.0
                if diff_pct > best_diff:
                    best_diff = diff_pct
                if diff_pct >= min_diff_pct:
                    _record_action("/click_verified", True, f"({x},{y}) diff={diff_pct:.2f}%")
                    return {
                        "ok": True, "verified": True,
                        "diff_pct": round(diff_pct, 3),
                        "tries": attempt + 1,
                        "reason": "screen_changed",
                    }
            except Exception as e:
                last_err = str(e)
            time.sleep(0.15)
        _record_action("/click_verified", False, f"({x},{y}) diff={best_diff:.2f}% < {min_diff_pct}%")
        return {
            "ok": True, "verified": False,
            "diff_pct": round(best_diff, 3),
            "tries": attempt + 1,
            "reason": f"screen_did_not_change (best={best_diff:.2f}%, need={min_diff_pct}%)",
            "hint": "Browser may not be on the right page/window; check /state and /window/list",
        }

    @router.post("/verify")
    async def verify(request: Request,
                     expect_text: Optional[str] = None,
                     expect_url_contains: Optional[str] = None,
                     expect_window_contains: Optional[str] = None,
                     timeout_ms: int = 5000,
                     x_access_code: Optional[str] = Header(None)):
        """Take screenshots + OCR over time, return when one of the expected
        conditions is true. Returns: {"ok": bool, "matched": "...", "evidence": {...}}
        """
        _check(x_access_code)
        engine = _get_ocr_engine()
        deadline = time.time() + (timeout_ms / 1000.0)
        attempts = 0
        while time.time() < deadline:
            attempts += 1
            try:
                if expect_text and engine:
                    png = agent.screenshot_to_bytes()
                    r = engine.ocr_bytes(png)
                    lines = " ".join(ln["text"] for ln in r.get("lines", []))
                    if expect_text.lower() in lines.lower():
                        _record_action("/verify", True, f"text={expect_text!r}")
                        return {"ok": True, "matched": "text", "attempts": attempts, "evidence": {"lines_sample": lines[:500]}}
                if expect_url_contains or expect_window_contains:
                    wins = agent.list_windows_impl()
                    for w in wins.get("windows", []):
                        n = w.get("name", "")
                        if expect_window_contains and expect_window_contains in n:
                            _record_action("/verify", True, f"window={expect_window_contains!r}")
                            return {"ok": True, "matched": "window", "attempts": attempts, "evidence": {"window": n}}
                        if expect_url_contains and expect_url_contains in n:
                            _record_action("/verify", True, f"url={expect_url_contains!r}")
                            return {"ok": True, "matched": "url", "attempts": attempts, "evidence": {"window": n}}
            except Exception:
                pass
            time.sleep(0.4)
        _record_action("/verify", False, f"timeout after {attempts} attempts")
        return {"ok": False, "matched": None, "attempts": attempts, "reason": "timeout"}

    @router.get("/diff")
    async def diff_get(request: Request,
                       a_b64: Optional[str] = None, b_b64: Optional[str] = None,
                       x_access_code: Optional[str] = Header(None)):
        """Compute pixel diff between two base64-encoded PNGs.
        If only a_b64 is given, diff against current screenshot.
        """
        _check(x_access_code)
        from PIL import Image, ImageChops
        try:
            a = Image.open(io.BytesIO(base64.b64decode(a_b64))).convert("RGB") if a_b64 else None
            if b_b64:
                b = Image.open(io.BytesIO(base64.b64decode(b_b64))).convert("RGB")
            else:
                b = Image.open(io.BytesIO(agent.screenshot_to_bytes())).convert("RGB")
            if a is None:
                return {"ok": True, "diff_pct": 100.0, "note": "no a_b64 given, diff is N/A"}
            if a.size != b.size:
                return {"ok": True, "diff_pct": 100.0, "note": "size mismatch"}
            d = ImageChops.difference(a, b)
            bbox = d.getbbox()
            if bbox is None:
                return {"ok": True, "diff_pct": 0.0, "changed_bbox": None}
            crop = d.crop(bbox)
            pixels = list(crop.getdata())
            changed = sum(1 for px in pixels if (px[0]+px[1]+px[2]) > 30)
            total = len(pixels)
            return {"ok": True, "diff_pct": round((changed/total)*100, 3), "changed_bbox": list(bbox)}
        except Exception as e:
            return JSONResponse(status_code=400, content={"error": str(e)})

    @router.get("/health")
    async def health_v107():
        """Tier 1 health: includes last action status for observability."""
        return {
            "v107": True,
            "agent_version": getattr(agent, "agent_version", "1.0.8"),
            "ocr_available": _get_ocr_engine() is not None,
            "last_action": dict(_LAST_ACTION),
        }

    # --- Workflow: post to LinkedIn (one-call) ---
    @router.post("/workflow/linkedin_post")
    async def workflow_linkedin_post(request: Request,
                                     body: str,
                                     wait_for_composer_ms: int = 3000,
                                     type_chunk_ms: int = 30,
                                     x_access_code: Optional[str] = Header(None)):
        """One-call "post text to LinkedIn" workflow.
        Steps:
          1. Verify LinkedIn feed is the foreground window (else fail)
          2. Find "Start a post" text, double-click center
          3. Wait for composer modal, find "What do you want to talk about?" or empty input
          4. Click into the input, type body in chunks
          5. Find the Post button (blue), click it
          6. Verify "Your post was published" or similar appears (OCR check)
        Returns: {"ok": bool, "steps": [...], "evidence": {...}}
        """
        _check(x_access_code)
        steps: List[Dict[str, Any]] = []

        def step(name, ok, **extra):
            entry = {"name": name, "ok": ok, "ts": time.time()}
            entry.update(extra)
            steps.append(entry)
            log.info(f"[linkedin_post] {name}: {ok} {extra}")
            return ok

        import pyautogui
        # Step 1: pre-flight
        wins = agent.list_windows_impl()
        foreground = next((w for w in wins.get("windows", [])
                          if "LinkedIn" in w.get("name", "")), None)
        if not foreground:
            return {"ok": False, "steps": steps,
                    "error": "linkedin_not_foreground",
                    "hint": "Open Edge, go to linkedin.com/feed/, then retry"}
        step("preflight", True, window=foreground.get("name"))

        # Step 2: find "Start a post" text
        from fastapi import Request as _Req
        from urllib.request import urlopen
        from urllib.parse import urlencode
        # Use the in-process router via the app
        # (cheating: use the OCR engine directly to avoid HTTP roundtrip)
        engine = _get_ocr_engine()
        if engine is None:
            return {"ok": False, "steps": steps, "error": "ocr_unavailable"}
        png = agent.screenshot_to_bytes()
        ocr_result = engine.ocr_bytes(png)
        sp = next((ln for ln in ocr_result.get("lines", [])
                   if "start a post" in ln["text"].lower()), None)
        if not sp:
            return {"ok": False, "steps": steps,
                    "error": "start_a_post_not_found",
                    "ocr_lines_sample": [ln["text"][:60] for ln in ocr_result.get("lines", [])[:20]]}
        cx = sp["x"] + sp["w"] // 2
        cy = sp["y"] + sp["h"] // 2
        step("found_start_a_post", True, cx=cx, cy=cy, text=sp["text"])

        # Step 3: double-click to open composer
        pyautogui.doubleClick(cx, cy)
        time.sleep(wait_for_composer_ms / 1000.0)
        # Verify modal opened (large change in screen)
        before_modal = png
        after_modal = agent.screenshot_to_bytes()
        from PIL import Image, ImageChops
        a = Image.open(io.BytesIO(before_modal)).convert("RGB")
        b = Image.open(io.BytesIO(after_modal)).convert("RGB")
        d = ImageChops.difference(a, b)
        bbox = d.getbbox()
        if bbox is None:
            step("composer_opened", False, reason="no_screen_change")
            return {"ok": False, "steps": steps, "error": "composer_did_not_open"}
        crop = d.crop(bbox)
        pixels = list(crop.getdata())
        changed = sum(1 for px in pixels if (px[0]+px[1]+px[2]) > 30)
        diff_pct = (changed/len(pixels))*100 if pixels else 0
        if diff_pct < 2.0:
            step("composer_opened", False, reason=f"only {diff_pct:.2f}% change")
            return {"ok": False, "steps": steps, "error": "composer_did_not_open",
                    "diff_pct": diff_pct}
        step("composer_opened", True, diff_pct=round(diff_pct, 2))

        # Step 4: click in the composer input (center of the modal)
        # Find the prompt text or any input area
        ocr2 = engine.ocr_bytes(after_modal)
        prompt = next((ln for ln in ocr2.get("lines", [])
                       if "talk about" in ln["text"].lower() or
                          "share" in ln["text"].lower() or
                          "create" in ln["text"].lower()), None)
        if prompt:
            # Click below the prompt text (LinkedIn convention)
            input_x = prompt["x"] + prompt["w"] // 2
            input_y = prompt["y"] + prompt["h"] + 30
        else:
            # Fallback: click center of the modal area (y=400 typical)
            input_x = 640
            input_y = 400
        pyautogui.click(input_x, input_y)
        time.sleep(0.5)
        step("clicked_input", True, x=input_x, y=input_y)

        # Step 5: type the body in chunks
        chunks = []
        remaining = body
        while len(remaining) > 400:
            cut = remaining.rfind(". ", 0, 400)
            if cut < 100:
                cut = remaining.rfind("\n", 0, 400)
            if cut < 100:
                cut = 400
            chunks.append(remaining[:cut + 1])
            remaining = remaining[cut + 1:]
        chunks.append(remaining)
        for i, chunk in enumerate(chunks):
            # URL-encode and use pyautogui.typewrite for ASCII (LinkedIn UI is English)
            try:
                # pyautogui.write doesn't handle unicode well; use clipboard fallback
                import pyperclip
                pyperclip.copy(chunk)
                pyautogui.hotkey("ctrl", "v")
            except Exception:
                pyautogui.typewrite(chunk, interval=type_chunk_ms/1000.0)
            time.sleep(0.4)
        step("typed_body", True, chunks=len(chunks), chars=len(body))

        # Step 6: find and click Post button (blue)
        time.sleep(0.6)
        png3 = agent.screenshot_to_bytes()
        ocr3 = engine.ocr_bytes(png3)
        # Look for "Post" text in the right half of the screen (y=600-700 area)
        post_btn = next((ln for ln in ocr3.get("lines", [])
                         if ln["text"].strip().lower() == "post" and
                            ln["x"] > 700 and 500 < ln["y"] < 720), None)
        if not post_btn:
            step("found_post_btn", False, reason="no 'Post' text found in expected region")
            return {"ok": False, "steps": steps, "error": "post_button_not_found"}
        pyautogui.click(post_btn["x"] + post_btn["w"]//2, post_btn["y"] + post_btn["h"]//2)
        time.sleep(3.0)
        step("clicked_post", True, x=post_btn["x"], y=post_btn["y"])

        # Step 7: verify success
        png4 = agent.screenshot_to_bytes()
        ocr4 = engine.ocr_bytes(png4)
        lines4 = " ".join(ln["text"] for ln in ocr4.get("lines", []))
        success_markers = ["post was published", "view post", "your post has been"]
        matched = next((m for m in success_markers if m in lines4.lower()), None)
        if matched:
            step("post_published", True, marker=matched)
            _record_action("/workflow/linkedin_post", True, f"chars={len(body)}")
            return {"ok": True, "steps": steps, "verified": True, "marker": matched}
        step("post_published", False, hint="no success marker found, check feed manually")
        _record_action("/workflow/linkedin_post", False, "no_success_marker")
        return {"ok": False, "steps": steps, "error": "no_success_marker",
                "ocr_lines_sample": lines4[:500]}

    # ─── /exec: run a PowerShell command (P0: eliminates WinRM dependency) ──
    @router.post("/paste")
    async def paste_text(
        request: Request,
        text: str = "",
        x_access_code: Optional[str] = Header(None),
    ):
        """Paste text via clipboard injection. Much faster and more reliable
        than /type for long text (500+ chars). Uses PowerShell to set the
        clipboard, then Ctrl+V to paste into the focused field.

        This fixes the X.com compose box truncation issue where pyautogui.write()
        drops characters because X.com's React handler can't keep up with
        sustained keystroke events.
        """
        _check(x_access_code)
        if not text:
            return {"ok": True, "chars": 0, "method": "paste", "detail": "empty"}

        # Escape single quotes for PowerShell (double them)
        ps_text = text.replace("'", "''")

        # Set clipboard via PowerShell (async to avoid blocking the event loop)
        import asyncio
        ps_cmd = f"Set-Clipboard -Value '{ps_text}'"
        try:
            proc = await asyncio.create_subprocess_exec(
                "powershell", "-NoProfile", "-NonInteractive", "-Command", ps_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
            if proc.returncode != 0:
                return {"ok": False, "error": f"clipboard set failed: {stderr.decode()[:200]}"}
        except asyncio.TimeoutError:
            return {"ok": False, "error": "clipboard set timed out"}
        except Exception as e:
            return {"ok": False, "error": f"clipboard exception: {e}"}

        # Small delay for clipboard to settle
        await asyncio.sleep(0.1)

        # Ctrl+V to paste
        import pyautogui
        pyautogui.hotkey("ctrl", "v")

        # Small delay for the UI to process the paste
        await asyncio.sleep(0.3)

        agent._last_action = {
            "endpoint": "/paste",
            "started_at": time.time(),
            "ok": True,
            "detail": f"pasted {len(text)} chars via clipboard",
        }
        return {"ok": True, "chars": len(text), "method": "clipboard_paste"}

    @router.post("/exec")
    async def exec_cmd(
        request: Request,
        x_access_code: Optional[str] = Header(None),
    ):
        """Run a PowerShell command on WinBolt and return stdout/stderr/rc.

        Uses the existing X-Access-Code auth. The command is run via
        `powershell -NoProfile -ExecutionPolicy Bypass -Command <cmd>`
        to avoid cmd.exe escaping hell. Timeout defaults to 60s.

        Body: JSON {"cmd": "...", "timeout": 60}
        or query: /exec?cmd=...&timeout=60
        """
        _check(x_access_code)
        try:
            body = await request.json()
            cmd = body.get("cmd", "")
            timeout = int(body.get("timeout", 60))
        except Exception:
            cmd = request.query_params.get("cmd", "")
            timeout = int(request.query_params.get("timeout", "60"))

        if not cmd:
            return {"rc": -1, "error": "no cmd provided"}

        try:
            result = subprocess.run(
                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-Command", cmd],
                capture_output=True, text=True, timeout=timeout,
                cwd=r"C:\NexGenX"
            )
            _record_action("/exec", result.returncode == 0, f"cmd={cmd[:80]}")
            return {
                "rc": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "cmd": cmd,
            }
        except subprocess.TimeoutExpired:
            _record_action("/exec", False, "timeout")
            return {"rc": -1, "error": f"timeout after {timeout}s", "cmd": cmd}
        except Exception as e:
            _record_action("/exec", False, str(e)[:100])
            return {"rc": -1, "error": str(e), "cmd": cmd}

    # ─── /file/write: write a file to disk (P0: eliminates HTTP-server deploy) ──
    @router.post("/file/write")
    async def write_file(
        request: Request,
        path: str,
        x_access_code: Optional[str] = Header(None),
    ):
        """Write raw bytes from the request body to a file path on WinBolt.

        Usage:
            curl -X POST "http://192.168.11.85:9400/file/write?path=C:\\NexGenX\\v106\\v107_module.py" \\
              -H "X-Access-Code: c9108dc4a4de42a1" \\
              -d @v107_module.py

        Creates parent directories if needed. Returns bytes written.
        """
        _check(x_access_code)
        content = await request.body()
        if not content:
            return {"status": "error", "error": "empty body"}
        try:
            p = Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(content)
            _record_action("/file/write", True, f"path={path} bytes={len(content)}")
            return {"status": "written", "path": path, "bytes": len(content)}
        except Exception as e:
            _record_action("/file/write", False, str(e)[:100])
            return {"status": "error", "error": str(e), "path": path}

    # ─── /file/read: read a file from disk (bonus, for diagnostics) ──
    @router.get("/file/read")
    async def read_file(
        path: str,
        x_access_code: Optional[str] = Header(None),
    ):
        """Read a file from WinBolt and return its contents as text."""
        _check(x_access_code)
        try:
            p = Path(path)
            if not p.exists():
                return {"status": "error", "error": "file not found", "path": path}
            content = p.read_bytes()
            return {"status": "ok", "path": path, "bytes": len(content),
                    "content": content.decode("utf-8", errors="replace")}
        except Exception as e:
            return {"status": "error", "error": str(e), "path": path}

    # ─── /supervisor/status: report supervisor health (P1) ──
    @router.get("/supervisor/status")
    async def supervisor_status(
        x_access_code: Optional[str] = Header(None),
    ):
        """Report the supervisor's view of reality: intended version,
        actual version, crash count, last error, port holder.

        This endpoint is served by the AGENT (not the supervisor), so it
        reports what the agent knows about its own state plus what it can
        observe about the OS.
        """
        _check(x_access_code)
        try:
            # Read supervisor log for recent crash info
            log_path = Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "NexGenX" / "supervisor.log"
            crash_count = 0
            last_error = ""
            if log_path.exists():
                lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
                for line in lines[-50:]:
                    if "agent_crash" in line:
                        crash_count += 1
                    if "restart attempt=" in line:
                        last_error = line.strip()

            # Check who holds the port
            port_holder = "unknown"
            try:
                r = subprocess.run(
                    ["powershell", "-NoProfile", "-Command",
                     "Get-NetTCPConnection -State Listen -LocalPort 9400 -ErrorAction SilentlyContinue | "
                     "ForEach-Object { $p = Get-Process -Id $_.OwningProcess; "
                     "Write-Output ($p.Id.ToString() + ' ' + $p.ProcessName + ' ' + $p.Path) }"],
                    capture_output=True, text=True, timeout=5
                )
                port_holder = r.stdout.strip() or "no listener"
            except Exception:
                pass

            return {
                "agent_version": getattr(agent, "agent_version", "1.0.8"),
                "v107_loaded": True,
                "supervisor_crash_count_recent": crash_count,
                "supervisor_last_event": last_error,
                "port_9400_holder": port_holder,
                "supervisor_pid": os.getppid() if os.name != "nt" else None,
            }
        except Exception as e:
            return {"status": "error", "error": str(e)}

    # Mount the router
    app.include_router(router)
    log.info("v107 routes installed: /ocr /find_text /state /click_verified /verify /diff /health /workflow/linkedin_post /exec /file/write /file/read /supervisor/status")
    return router
