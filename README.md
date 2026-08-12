# NexGenX Windows Agent — Public Installer

**This repository is installer scripts only.**  
Agent source lives in private `NexGenX/ngx-windows-agent` and ships as a private GitHub Release zip.

## Install (Administrator PowerShell)

```powershell
$env:NEXGENX_GITHUB_TOKEN = "<fine-grained PAT: Contents read on NexGenX/ngx-windows-agent>"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/install-bootstrap.ps1)
```

## Upgrade

```powershell
$env:NEXGENX_GITHUB_TOKEN = "<PAT>"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/upgrade-bootstrap.ps1)
```

## What v1.0.9 adds

- Skill runtime: `GET /skills`, `GET /skills/health`, `POST /skills/{name}/run`
- Skills: `desktop.health_check`, `content.linkedin_post`, `content.x_post`
- Same Session-safe start as v1.0.8 (Interactive `NexGenXAgent` + `Start-ScheduledTask`)
- Private bundle only — no agent source in this git tree

## After install

- Files: `C:\NexGenX\v109`
- API: `http://<ip>:9400`
- Access code: `C:\ProgramData\NexGenX\agent_access.txt`

## License

Proprietary — © NexGenX.
