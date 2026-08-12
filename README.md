# NexGenX Windows Agent — Public Installer

One-liner install and upgrade for the NexGenX / NexLink Windows Agent.

## Install (new machine)

Open **PowerShell as Administrator**:

```powershell
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/install-bootstrap.ps1)
```

## Upgrade (existing machine)

```powershell
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/upgrade-bootstrap.ps1)
```

Upgrade keeps the access code in `C:\ProgramData\NexGenX\`, replaces agent files with **v1.0.8**, and restarts via the Interactive scheduled task.

## What v1.0.8 fixes

- **One version everywhere** — `/info` and `/health` both report `1.0.8` (plus `v107: true` for OCR).
- **Session-safe start** — agent starts with `Start-ScheduledTask` on task `NexGenXAgent` (Interactive + AtLogOn). Never use bare `Start-Process` for the long-running agent (that puts it in Session 0; `/ping` works but `/screenshot` fails).
- **Post-checks** — installer fails if `/ping` fails, Session is 0, or version/health is wrong.

## After install

- API: `http://<ip>:9400` with header `X-Access-Code`
- Access code: `C:\ProgramData\NexGenX\agent_access.txt`
- Files: `C:\NexGenX\v108`
- Task: `NexGenXAgent`
- Logs: `C:\ProgramData\NexGenX\supervisor.log`

## If screenshots fail

1. Check session: `Get-Process python | Select Id,SessionId`
2. If SessionId is `0`, stop it and run:
   ```powershell
   Start-ScheduledTask -TaskName NexGenXAgent
   ```
3. Do **not** use `Start-Process python ... agent_server.py` for recovery.

## Older versions

```powershell
# v1.0.7 path (legacy)
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1)
```

## License

Proprietary — © NexGenX.
