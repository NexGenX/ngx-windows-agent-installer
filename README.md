# NexGenX Windows Agent

**A secure, access-code-protected Windows control server** — the desktop-side component for the NexGenX AI Employee platform. Runs on a Windows VM and exposes screenshot, mouse, keyboard, and accessibility tree APIs to the Linux AI gateway.

---

## Architecture

```
┌─────────────────────────┐          ┌─────────────────────────┐
│   Windows VM            │          │   Linux LXC             │
│   (customer's desktop)  │          │   (NexGenX datacenter)  │
│                         │   API    │                         │
│  ┌───────────────────┐  │ ─────── │  ┌──────────────────┐   │
│  │ agent_server.py   │◄─┤  HTTPS  ├─►│ windows_agent.py│   │
│  │ (FastAPI, :9400)  │  │ X-Auth  │  │  (AI client)     │   │
│  └───────────────────┘  │ Code    │  └────────┬─────────┘   │
│  ┌───────────────────┐  │          │           │             │
│  │ noVNC (:6080)     │  │          │     AI model (me)      │
│  │ (browser access)  │  │          │                         │
│  └───────────────────┘  │          │                         │
└─────────────────────────┘          └─────────────────────────┘
```

**Two modes:**
- `agent_server.py` — Headless API server (for automated AI control)
- `tray_app.py` — System tray UI (shows access code, status, config)

---

## Installation on Windows VM

### Option A: One-click install (recommended)
```
1. Copy the entire `server/` folder to the Windows VM
2. Right-click `install.ps1` → "Run with PowerShell" → "Run as Administrator"
3. Done. The access code appears in a Windows notification.
```

### Option B: Manual install
```powershell
# Install Python 3.11+ from python.org (check "Add to PATH")
# Then:
cd C:\NexGenX
pip install -r requirements.txt
python agent_server.py
```

---

## Access Code System

On first run, the server **generates a 16-character hex access code** (e.g. `fb5337fda3ab6c84`).

**Where it's stored:**
- `C:\ProgramData\NexGenX\agent_access.txt` — the plain code
- `C:\ProgramData\NexGenX\agent_access_hash.txt` — SHA-256 hash for verification

**How it works:**
- Every API call requires the header `X-Access-Code: <code>`
- Invalid/missing code → HTTP 401
- The code is shown in a Windows toast notification on first start
- Retrieve it anytime from `C:\ProgramData\NexGenX\agent_access.txt`

**Sharing with the AI gateway:**
```bash
# On Linux gateway — set env vars:
export WINDOWS_AGENT_URL="http://192.168.10.209:9400"
export WINDOWS_AGENT_CODE="fb5337fda3ab6c84"
```

---

## API Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/ping` | No | Health check |
| `GET` | `/access_code` | No | Get masked code info |
| `GET` | `/screenshot` | Yes | Full screen PNG |
| `POST` | `/click?x=&y=&button=` | Yes | Click at x,y |
| `POST` | `/doubleclick?x=&y=` | Yes | Double click |
| `POST` | `/move?x=&y=` | Yes | Move mouse |
| `POST` | `/type?text=` | Yes | Type text |
| `POST` | `/key?key=` | Yes | Single key press |
| `POST` | `/hotkey?key1=&key2=` | Yes | Key combo |
| `POST` | `/scroll?clicks=&x=&y=` | Yes | Mouse scroll |
| `GET` | `/tree?depth=` | Yes | Full accessibility tree |
| `GET` | `/tree/clickable` | Yes | Only interactive elements |
| `GET` | `/find?text=` | Yes | Find element by text → x,y |
| `GET` | `/window/list` | Yes | List open windows |
| `GET` | `/info` | Yes | System info (screen size, etc.) |
| `GET` | `/vnc` | Yes | Check noVNC status |
| `POST` | `/access_code/reset` | Yes | Reset access code |

---

## Linux Client Usage

```python
from windows_agent import WindowsAgent

agent = WindowsAgent("192.168.10.209", "fb5337fda3ab6c84")

# Or from environment:
# agent = WindowsAgent.from_env()

# Take screenshot
img = agent.screenshot()
img.save("/tmp/desktop.png")

# Find and click a button by its label text
el = agent.find("Submit")
if el:
    agent.click(el.x, el.y)

# Get all clickable elements
elements = agent.clickable()
for el in elements:
    print(f"[{el.type}] {el.name} at ({el.x}, {el.y})")

# High-level: wait for element
el = agent.wait_for_element("Loading...", timeout=10)
```

---

## noVNC — Browser Desktop Access

The Windows VM also runs noVNC so customers can view their desktop in a browser:

```
http://<windows-vm-ip>:6080/vnc.html
```

The portal embeds this via iframe. No VPN, no RDP client — pure HTML5.

To install noVNC manually:
```powershell
# On the Windows VM:
git clone https://github.com/novnc/noVNC.git C:\NexGenX\noVNC
# Then run: websockify --web C:\NexGenX\noVNC 6080 localhost:5900
```

---

## Auto-start on Boot

The installer creates a Windows Scheduled Task (`NexGenXAgent`) that runs as Administrator at startup. To verify:
```powershell
Get-ScheduledTask -TaskName NexGenXAgent
```

---

## Security Notes

- Access code is stored as SHA-256 hash on disk (plain text also stored for user retrieval)
- API requires `X-Access-Code` header on every mutating request
- Firewall rule opens port 9400 inbound — restrict to NexGenX gateway IPs in production
- For production: add TLS (run behind nginx with HTTPS) and restrict `/access_code` endpoint
- noVNC websocket should be behind auth or restricted to portal proxy only

---

## Troubleshooting

**Server won't start:**
```powershell
python agent_server.py  # Run manually to see errors
```

**Access code not found:**
```powershell
Get-Content C:\ProgramData\NexGenX\agent_access.txt
```

**Firewall blocking:**
```powershell
New-NetFirewallRule -DisplayName "NexGenX Agent" -Direction Inbound -Protocol TCP -LocalPort 9400 -Action Allow
```

**pyautogui fails (remote desktop context):**
pyautogui needs a real display session. If running on a headless Server VM, it may not work via RDP. Use:
```powershell
# Install a virtual display driver or use Agent with RDP disconnected
```
