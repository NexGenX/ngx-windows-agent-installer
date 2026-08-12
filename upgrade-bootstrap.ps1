# NexGenX Windows Agent — Upgrade to v1.0.8
#
# One-liner (Administrator PowerShell):
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/upgrade-bootstrap.ps1)
#
# Stops old tasks, installs v1.0.8 files, keeps ProgramData access code,
# starts via Interactive Scheduled Task NexGenXAgent.

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v108",
    [string]$Branch = "v1.0.8"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PublicRepo = "NexGenX/ngx-windows-agent-installer"

Write-Host ""
Write-Host "  NexGenX Agent Upgrade → v1.0.8" -ForegroundColor Cyan
Write-Host "  ==============================" -ForegroundColor Cyan
Write-Host ""

$installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v108.ps1"
$installerScript = irm $installerUrl
$scriptBlock = [scriptblock]::Create($installerScript)
& $scriptBlock -InstallPath $InstallPath -Upgrade

Write-Host ""
Write-Host "  Upgrade finished." -ForegroundColor Green
