"""
NexGenX Windows Agent Server
=============================
Secure Windows control server with access code authentication.
Run this on the Windows VM �?" the Linux AI gateway calls these endpoints.

Access code: generated on first run, displayed in UI and stored securely.
Every API call must include the access code in the X-Access-Code header.

This module is a thin platform-specific subclass of `BaseAgent` (in
`agent_server_common.py`). All routes, auth, and the FastAPI app come from
the common base. The Windows-specific bit is the accessibility tree, which
uses the `uiautomation` package (Windows UI Automation API).

Usage:
    python agent_server.py [--port 9400] [--no-ui]
"""

import argparse
import platform
import socket
import sys

from agent_server_common import BaseAgent, add_common_cli_args


class WindowsAgent(BaseAgent):
    """Windows implementation of the NexGenX desktop agent.

    Differences from the base class:
      - Uses `uiautomation` for the accessibility tree (Windows UIA API)
      - Uses mss + pyautogui (same as base; works on Windows)
    """

    platform_name = "windows"

    def get_tree_impl(self, depth: int) -> dict:
        try:
            import uiautomation as auto
        except ImportError:
            return {"error": "uiautomation not installed", "platform": "windows", "tree": None}

        def serialize_element(el, current_depth=0):
            if current_depth > depth:
                return None
            try:
                rect = el.BoundingRectangle
                name = el.Name if el.Name else ""
                control_type = (el.ControlTypeName if hasattr(el, 'ControlTypeName')
                                else str(el.ControlType))
                value = (el.Value if hasattr(el, 'Value') and callable(el.Value) else "")
                item_status = (el.ItemStatus if hasattr(el, 'ItemStatus')
                               and callable(el.ItemStatus) else "")

                children = []
                if current_depth < depth:
                    try:
                        for child in el.GetChildren() or []:
                            child_data = serialize_element(child, current_depth + 1)
                            if child_data:
                                children.append(child_data)
                    except Exception:
                        pass

                return {
                    "name": str(name)[:200],
                    "type": str(control_type),
                    "value": str(value)[:200],
                    "status": str(item_status),
                    "rect": {
                        "x": int(rect.left), "y": int(rect.top),
                        "w": int(rect.width()), "h": int(rect.height())
                    } if rect and rect.width() > 0 else None,
                    "children": children,
                    "depth": current_depth,
                }
            except Exception:
                return None

        try:
            desktop = auto.GetRootControl()
            tree = serialize_element(desktop)
            return {"tree": tree, "platform": "windows"}
        except Exception as e:
            return {"error": str(e), "platform": "windows", "tree": None}

    def get_clickable_impl(self) -> dict:
        try:
            import uiautomation as auto
        except ImportError:
            return {"error": "uiautomation not installed",
                    "elements": [], "count": 0, "platform": "windows"}

        clickable = []

        def find_clickable(el, depth=0):
            if depth > 6:
                return
            try:
                control_type = (el.ControlTypeName if hasattr(el, 'ControlTypeName')
                                else str(el.ControlType))
                clickable_types = [
                    "ButtonControl", "EditControl", "TextControl",
                    "HyperlinkControl", "MenuItemControl", "TabControl",
                    "ComboBoxControl", "CheckBoxControl", "RadioButtonControl",
                    "ListItemControl", "TreeItemControl", "SliderControl",
                ]
                is_clickable = any(ct in control_type for ct in clickable_types)
                rect = el.BoundingRectangle

                if is_clickable and rect and rect.width() > 2:
                    try:
                        name = el.Name if el.Name else ""
                        value = (el.Value if hasattr(el, 'Value')
                                 and callable(el.Value) else "")
                        if name or value:
                            clickable.append({
                                "name": str(name)[:150],
                                "type": control_type.replace("Control", ""),
                                "value": str(value)[:150],
                                "x": int(rect.left + rect.width() / 2),
                                "y": int(rect.top + rect.height() / 2),
                                "w": int(rect.width()),
                                "h": int(rect.height()),
                            })
                    except Exception:
                        pass

                if depth < 6:
                    try:
                        for child in el.GetChildren() or []:
                            find_clickable(child, depth + 1)
                    except Exception:
                        pass
            except Exception:
                pass

        try:
            desktop = auto.GetRootControl()
            find_clickable(desktop)
            return {"elements": clickable, "count": len(clickable), "platform": "windows"}
        except Exception as e:
            return {"error": str(e), "elements": [], "count": 0, "platform": "windows"}

    def find_element_impl(self, text: str, exact: bool) -> dict:
        try:
            import uiautomation as auto
        except ImportError:
            return {"found": False, "text": text, "error": "uiautomation not installed"}

        try:
            if exact:
                search_func = lambda e, t=text: e.Name == t
            else:
                search_func = lambda e, t=text: t.lower() in (e.Name or "").lower()

            el = auto.WalkTree(
                auto.GetRootControl(), maxDepth=10,
                includeTop=False,
                yieldCondition=lambda e, depth: bool(search_func(e) and
                                         e.BoundingRectangle.width() > 2)
            )
            # WalkTree returns a generator in 2.0.x -- grab the first match
            el = next(iter(el), None)
            if el:
                rect = el.BoundingRectangle
                return {
                    "found": True,
                    "name": el.Name,
                    "type": str(el.ControlType),
                    "x": int(rect.left + rect.width() / 2),
                    "y": int(rect.top + rect.height() / 2),
                    "rect": {"x": int(rect.left), "y": int(rect.top),
                             "w": int(rect.width()), "h": int(rect.height())},
                }
            return {"found": False, "text": text}
        except Exception as e:
            return {"found": False, "text": text, "error": str(e)}

    def list_windows_impl(self) -> dict:
        try:
            import uiautomation as auto
        except ImportError:
            return {"error": "uiautomation not installed", "windows": []}

        windows = []
        try:
            for w in auto.GetRootControl().GetChildren():
                rect = w.BoundingRectangle
                name = w.Name if w.Name else ""
                if name and rect and rect.width() > 100:
                    windows.append({
                        "name": name[:200],
                        "type": str(w.ControlType),
                        "x": int(rect.left), "y": int(rect.top),
                        "w": int(rect.width()), "h": int(rect.height()),
                    })
        except Exception as e:
            return {"error": str(e), "windows": []}
        return {"windows": windows, "count": len(windows)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NexGenX Windows Agent Server")
    add_common_cli_args(parser)
    args = parser.parse_args()

    agent = WindowsAgent()
    # v107: install tier 1 vision + verification endpoints (OCR, find_text,
    # state, click_verified, verify, diff, health, workflow/linkedin_post)
    try:
        from v107_module import install_routes as v107_install_routes
        v107_install_routes(agent.app, agent)
    except Exception as e:
        print(f"[v107] WARNING: install failed, tier 1 endpoints disabled: {e}")
    agent.run(port=args.port, host=args.host, quiet=args.quiet)

