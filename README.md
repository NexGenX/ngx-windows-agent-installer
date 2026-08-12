# NexGenX Windows Agent — Public Installer

**This repository is installer scripts only.**  
Agent source lives in private `NexGenX/ngx-windows-agent`. Bundles can be fetched from a private GitHub Release **or** a site-hosted zip (no GitHub token).

## Upgrade (recommended, tokenless)

```powershell
$env:NEXGENX_BUNDLE_URL = "https://nexgenx.org/ngx-agent-v1.0.9.zip"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/upgrade-bootstrap.ps1)
```

## Install (tokenless)

```powershell
$env:NEXGENX_BUNDLE_URL = "https://nexgenx.org/ngx-agent-v1.0.9.zip"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/install-bootstrap.ps1)
```

## Install / upgrade via private GitHub release

```powershell
$env:NEXGENX_GITHUB_TOKEN = "<fine-grained PAT: Contents read on NexGenX/ngx-windows-agent>"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/upgrade-bootstrap.ps1)
```

## What v1.0.9 adds

- Skill runtime: `GET /skills`, `GET /skills/health`, `POST /skills/{name}/run`
- Skills: `desktop.health_check`, `content.linkedin_post`, `content.x_post`
- Session-safe start: Interactive `NexGenXAgent` + `Start-ScheduledTask`
- Public git tree stays scripts-only

## After install

- Files: `C:\NexGenX\v109`
- API: `http://<ip>:9400`
- Access code: `C:\ProgramData\NexGenX\agent_access.txt`

## License

Proprietary — © NexGenX.
