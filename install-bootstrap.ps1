# NexGenX Windows Agent — Public Bootstrap (v1.0.8)
# https://github.com/NexGenX/ngx-windows-agent-installer
#
# Install (Administrator PowerShell):
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/install-bootstrap.ps1)
#
# Optional: -Version v107 or v106 for older installers on main.

[CmdletBinding()]
param(
    [string]$InstallPath = "",
    [string]$Version = "v108",
    [string]$Branch = "v1.0.8"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PublicRepo = "NexGenX/ngx-windows-agent-installer"

Write-Host ""
Write-Host "  NexGenX Windows Agent Bootstrap" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host "  Version: $Version" -ForegroundColor Gray
Write-Host ""

if ($Version -eq "v108") {
    if (-not $InstallPath) { $InstallPath = "C:\NexGenX\v108" }
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/install-v108.ps1"
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    & $scriptBlock -InstallPath $InstallPath
} elseif ($Version -eq "v107") {
    if (-not $InstallPath) { $InstallPath = "C:\NexGenX\v106" }
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/main/server/install-v107.ps1"
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    $scriptBlock.Invoke(@($InstallPath))
} else {
    if (-not $InstallPath) { $InstallPath = "C:\NexGenX\v106" }
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/main/server/install-v106.ps1"
    $installerScript = irm $installerUrl
    $scriptBlock = [scriptblock]::Create($installerScript)
    $scriptBlock.Invoke(@($InstallPath))
}

Write-Host ""
Write-Host "  Bootstrap finished." -ForegroundColor Green
