# NexGenX Windows Agent — Upgrade to v1.0.8
# Public installer only; agent bundle from private release.
#
#   $env:NEXGENX_GITHUB_TOKEN = "<PAT>"
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/upgrade-bootstrap.ps1)

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v108",
    [string]$Branch = "v1.0.8",
    [string]$GitHubToken = "",
    [string]$BundleUrl = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PublicRepo = "NexGenX/ngx-windows-agent-installer"
if (-not $GitHubToken) { $GitHubToken = $env:NEXGENX_GITHUB_TOKEN }
if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }

Write-Host ""
Write-Host "  NexGenX Agent Upgrade → v1.0.8" -ForegroundColor Cyan
Write-Host ""

$installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v108.ps1"
$installerScript = irm $installerUrl
$scriptBlock = [scriptblock]::Create($installerScript)
& $scriptBlock -InstallPath $InstallPath -Upgrade -GitHubToken $GitHubToken -BundleUrl $BundleUrl
Write-Host "  Upgrade finished." -ForegroundColor Green
