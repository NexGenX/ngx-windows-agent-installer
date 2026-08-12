# NexGenX Windows Agent — Upgrade to v1.0.9
#
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

Write-Host ""
Write-Host "  NexGenX Agent Upgrade → v1.0.9" -ForegroundColor Cyan
Write-Host ""

$installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v109.ps1"
$installerScript = irm $installerUrl
$scriptBlock = [scriptblock]::Create($installerScript)
& $scriptBlock -InstallPath $InstallPath -Upgrade -GitHubToken $GitHubToken -BundleUrl $BundleUrl
Write-Host "  Upgrade finished." -ForegroundColor Green
