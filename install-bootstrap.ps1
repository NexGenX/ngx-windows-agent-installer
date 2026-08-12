# NexGenX Windows Agent — Public Bootstrap (v1.0.9)
# Public repo = installer scripts only. Agent source stays private.
#
#   $env:NEXGENX_GITHUB_TOKEN = "<fine-grained PAT: Contents read on NexGenX/ngx-windows-agent>"
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/install-bootstrap.ps1)

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v109",
    [string]$Version = "v109",
    [string]$Branch = "v1.0.9",
    [string]$GitHubToken = "",
    [string]$BundleUrl = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PublicRepo = "NexGenX/ngx-windows-agent-installer"

Write-Host ""
Write-Host "  NexGenX Windows Agent Bootstrap" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host "  Version: $Version" -ForegroundColor Gray
Write-Host ""

if (-not $GitHubToken) { $GitHubToken = $env:NEXGENX_GITHUB_TOKEN }
if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }

if ($Version -eq "v109") {
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v109.ps1"
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    & $scriptBlock -InstallPath $InstallPath -GitHubToken $GitHubToken -BundleUrl $BundleUrl
} elseif ($Version -eq "v108") {
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/v1.0.8/server/install-v108.ps1"
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    & $scriptBlock -InstallPath $(if ($InstallPath) { $InstallPath } else { "C:\NexGenX\v108" }) -GitHubToken $GitHubToken -BundleUrl $BundleUrl
} else {
    Write-Host "Unknown Version=$Version" -ForegroundColor Yellow
    throw "Unsupported Version"
}
Write-Host "  Bootstrap finished." -ForegroundColor Green
