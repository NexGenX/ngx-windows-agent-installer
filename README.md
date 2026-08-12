# NexGenX Windows Agent — Public Installer

**This repository is installer scripts only.**  
Agent source code lives in the private repo `NexGenX/ngx-windows-agent` and is distributed as a **private GitHub Release** zip.

## Install (Administrator PowerShell)

```powershell
$env:NEXGENX_GITHUB_TOKEN = "<fine-grained PAT: Contents read on NexGenX/ngx-windows-agent>"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/install-bootstrap.ps1)
```

## Upgrade

```powershell
$env:NEXGENX_GITHUB_TOKEN = "<PAT>"
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/upgrade-bootstrap.ps1)
```

### Internal CDN (no GitHub token on the endpoint)

```powershell
iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/install-bootstrap.ps1); `
  # or call install-v108 with -BundleUrl "https://your-cdn/ngx-agent-v1.0.8.zip"
```

Pass `-BundleUrl` into the bootstrap once wired, or run `server/install-v108.ps1` locally with `-BundleUrl`.

## What v1.0.8 fixes

- One version string (`1.0.8`) on `/info` and `/health`
- Session-safe start: Interactive scheduled task `NexGenXAgent` + `Start-ScheduledTask` (never bare `Start-Process`)
- Installer post-checks: `/ping`, Session ≠ 0, health/version, screenshot smoke
- **No agent source in this public git tree**

## After install

- API: `http://<ip>:9400` with `X-Access-Code`
- Access code: `C:\ProgramData\NexGenX\agent_access.txt`
- Files: `C:\NexGenX\v108`
- Task: `NexGenXAgent`

## If screenshots fail

```powershell
Get-Process python | Select Id, SessionId
Start-ScheduledTask -TaskName NexGenXAgent
```

Do **not** recover with `Start-Process`.

## Publishing a new agent bundle (maintainers)

From the private repo CI or a trusted machine:

1. Build `ngx-agent-vX.Y.Z.zip` from private `server/` (+ vision modules)
2. `gh release create vX.Y.Z ngx-agent-vX.Y.Z.zip --repo NexGenX/ngx-windows-agent`
3. Bump public installer scripts to that tag/asset name

## License

Proprietary — © NexGenX.
