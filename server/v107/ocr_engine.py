"""
Windows.Media.Ocr engine wrapper for v107.
Uses the `winrt-Windows.Media.Ocr` package (clean WinRT projection).
"""
from __future__ import annotations

import io
import logging
import threading
from typing import List, Dict, Any

log = logging.getLogger("agent.v107.ocr")


class OcrEngine:
    """Thin wrapper around Windows.Media.Ocr via winrt."""

    def __init__(self):
        # Import lazily to keep startup fast
        from winrt.windows.media.ocr import OcrEngine
        from winrt.windows.globalization import Language
        from winrt.windows.graphics.imaging import BitmapDecoder, SoftwareBitmap
        from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream, RandomAccessStreamReference

        lang = Language("en-US")
        self._engine = OcrEngine.try_create_from_language(lang)
        if self._engine is None:
            # Try user profile languages
            self._engine = OcrEngine.try_create_from_user_profile_languages()
        if self._engine is None:
            raise RuntimeError("OcrEngine.try_create_from_language returned None; no language pack installed")
        log.info("Windows.Media.Ocr engine ready (en-US)")

    def ocr_bytes(self, png: bytes) -> Dict[str, Any]:
        """Run OCR on a PNG byte string. Returns dict with text + lines.
        Lines have: text, x, y, w, h (top-left coords in image pixels).
        """
        from winrt.windows.graphics.imaging import BitmapDecoder, SoftwareBitmap
        from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream, RandomAccessStreamReference

        # Write PNG bytes to an in-memory stream
        stream = InMemoryRandomAccessStream()
        writer = DataWriter(stream.get_output_stream_at(0))
        writer.write_bytes(bytearray(png))
        writer.store_async().get()  # wait for the async store
        writer.close()

        # Seek to start so the decoder reads from the beginning
        stream.seek(0)

        # Decode the PNG and get a SoftwareBitmap
        decoder = BitmapDecoder.create_async(stream).get()
        # Use no-arg form first (it returns the bitmap in its native format)
        try:
            bitmap = decoder.get_software_bitmap_async().get()
        except Exception:
            # Fall back to explicit BGRA8 conversion
            from winrt.windows.graphics.imaging import BitmapPixelFormat, BitmapAlphaMode
            bitmap = decoder.get_software_bitmap_async(
                BitmapPixelFormat.BGRA8,
                BitmapAlphaMode.IGNORE
            ).get()

        # Run OCR (this is the slow part)
        result = self._engine.recognize_async(bitmap).get()

        out: Dict[str, Any] = {"text": "", "lines": []}
        for line in result.lines:
            txt = str(line.text)
            # The winrt wrapper doesn't expose OcrLine.bounding_box directly,
            # so we aggregate the bounding rects of the words in the line.
            words = list(line.words) if line.words else []
            if words:
                rects = [w.bounding_rect for w in words]
                x = min(int(r.x) for r in rects)
                y = min(int(r.y) for r in rects)
                x2 = max(int(r.x + r.width) for r in rects)
                y2 = max(int(r.y + r.height) for r in rects)
                w = x2 - x
                h = y2 - y
            else:
                x = y = w = h = 0
            out["lines"].append({"text": txt, "x": x, "y": y, "w": w, "h": h})
            out["text"] += txt + "\n"
        return out


_engine_lock = threading.Lock()
_engine_instance = None


def get_engine():
    """Singleton. Cached after first successful init."""
    global _engine_instance
    if _engine_instance is not None:
        return _engine_instance
    with _engine_lock:
        if _engine_instance is not None:
            return _engine_instance
        _engine_instance = OcrEngine()
        return _engine_instance
