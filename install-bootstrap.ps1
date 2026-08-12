# NexGenX Windows Agent — Public Bootstrap (v1.0.8)
# Public repo = installer scripts only. Agent source stays private.
#
#   $env:NEXGENX_GITHUB_TOKEN = "<PAT with read access to private ngx-windows-agent releases>"
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/install-bootstrap.ps1)

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v108",
    [string]$Version = "v108",
    [string]$Branch = "v1.0.8",
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

if ($Version -eq "v108") {
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v108.ps1"
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    & $scriptBlock -InstallPath $InstallPath -GitHubToken $GitHubToken -BundleUrl $BundleUrl
} else {
    Write-Host "Legacy Version=$Version — use main branch installers. Prefer v108." -ForegroundColor Yellow
    if ($Version -eq "v107") {
        $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/main/server/install-v107.ps1"
    } else {
        $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/main/server/install-v106.ps1"
    }
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    $scriptBlock.Invoke(@($InstallPath))
}
Write-Host "  Bootstrap finished." -ForegroundColor Green
