# NexGenX Windows Agent — Public Installer

**The one-liner installer for the NexGenX Windows Agent.**

This repository is **public** so customers can install without needing GitHub credentials.

---

## Quick install (one-liner, as Administrator)

Open **PowerShell as Administrator** and paste:

```powershell
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1)
```

That's it. The bootstrap will:
1. Download the real installer (this repo's `server/install.ps1`)
2. Run it, which:
   - Installs Python 3.11 if needed
   - Configures WinRM, RDP, and the firewall for remote administration
   - Downloads the agent code from the **private** `NexGenX/ngx-windows-agent` repo
   - Installs Python dependencies
   - Sets up the auto-start scheduled task
   - Starts the agent and displays the access code

## What gets installed

- **Python 3.11** (system-wide, from python.org)
- **NexGenX Agent** at `C:\NexGenX` (or your chosen `-InstallPath`)
- **Windows Scheduled Task** `NexGenXAgent` that starts the agent on boot
- **Windows Firewall rule** allowing TCP 9400 inbound (the agent's HTTP port)
- **noVNC** in `C:\NexGenX\noVNC` for browser-based desktop access
- **WinRM** enabled on port 5985
- **RDP** enabled on port 3389 (Network Level Authentication disabled so noVNC can connect)
- **Access code** persisted to `C:\ProgramData\NexGenX\agent_access.txt`

## Advanced usage

```powershell
# Custom install path
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1); .\install.ps1 -InstallPath 'D:\Agents\MyWorker'

# Specific version
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.0/install-bootstrap.ps1)

# Skip Python install (if you already have 3.10+)
.\install.ps1 -SkipPythonInstall

# Skip SHA-256 checksum verification (NOT recommended for production)
.\install.ps1 -SkipChecksum
```

## After install

The agent listens on **port 9400** (HTTP). The access code is shown in a Windows notification and saved to:

```
C:\ProgramData\NexGenX\agent_access.txt
```

Share the access code with the NexGenX AI gateway to control this machine:

- **HTTP API:** `http://<this-machine-ip>:9400` (with `X-Access-Code` header)
- **API docs:** `http://<this-machine-ip>:9400/docs`
- **Browser-based desktop (noVNC):** `http://<this-machine-ip>:6080/vnc.html`

## Files in this repo

| File | Purpose |
|------|---------|
| `install-bootstrap.ps1` | Tiny one-liner launcher (~3 KB). The thing customers actually run. |
| `server/install.ps1` | The full installer. Downloads agent code, sets up firewall, scheduled task, etc. |
| `README.md` | This file. |
| `DEPLOYMENT.md` | How the agent is distributed and how customer installs work at scale. |

## The agent source

The full agent source code lives in a **separate private repo** (`NexGenX/ngx-windows-agent`) that the installer pulls from. This public repo is **just the installer scripts** — no agent code, no secrets, no customer data.

This split lets us:
- ✅ Give customers a clean one-liner that doesn't require GitHub credentials
- ✅ Keep proprietary agent code private
- ✅ Update the installer without touching the agent source
- ✅ Pin specific customer installs to specific installer versions

## Troubleshooting

**"Execution of scripts is disabled on this system"** — Run this first:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1)
```

**"Failed to download installer"** — Check internet connectivity and that `raw.githubusercontent.com` is reachable.

**Agent installs but you can't connect to port 9400** — Check the Windows Firewall:
```powershell
Get-NetFirewallRule -DisplayName "NexGenX Agent Server"
```
If missing, re-run the installer (it's idempotent).

**Where do I find the access code?** — Three places:
1. Windows notification at install time
2. `C:\ProgramData\NexGenX\agent_access.txt`
3. The agent generates a new one each time it starts — check the log at `C:\NexGenX\agent.log`

## License

Proprietary — © NexGenX. Not for redistribution.
