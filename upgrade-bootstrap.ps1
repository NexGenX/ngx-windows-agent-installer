# NexGenX Windows Agent — Upgrade to v1.0.9
# Public installer only; agent bundle from private release or CDN.
#
# Tokenless (site-hosted zip):
#   $env:NEXGENX_BUNDLE_URL = "https://nexgenx.org/ngx-agent-v1.0.9.zip"
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/upgrade-bootstrap.ps1)
#
# Or private GitHub release:
#   $env:NEXGENX_GITHUB_TOKEN = "<PAT>"
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/upgrade-bootstrap.ps1)

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v109",
    [string]$Branch = "v1.0.9",
    [string]$GitHubToken = "",
    [string]$BundleUrl = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PublicRepo = "NexGenX/ngx-windows-agent-installer"

if (-not $GitHubToken) { $GitHubToken = $env:NEXGENX_GITHUB_TOKEN }
if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }
if (-not $BundleUrl) { $BundleUrl = $env:NEXGENX_BUNDLE_URL }

Write-Host ""
Write-Host "  NexGenX Agent Upgrade → v1.0.9" -ForegroundColor Cyan
if ($BundleUrl) { Write-Host "  BundleUrl: $BundleUrl" -ForegroundColor Gray }
Write-Host ""

$installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v109.ps1"
$installerScript = irm $installerUrl
$scriptBlock = [scriptblock]::Create($installerScript)
& $scriptBlock -InstallPath $InstallPath -Upgrade -GitHubToken $GitHubToken -BundleUrl $BundleUrl
Write-Host "  Upgrade finished." -ForegroundColor Green
