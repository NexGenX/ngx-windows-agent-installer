# NexGenX Windows Agent — Public Bootstrap Installer
# https://github.com/NexGenX/ngx-windows-agent-installer
#
# One-liner (as Administrator):
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1)
#
# Defaults to v1.0.7 (with OCR + vision). For v1.0.6 only:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1); Install-NexGenXAgent -Version v106

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX",
    [string]$Version = "v107"  # "v107" (default, with OCR) or "v106" (base)
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$PublicRepo = "NexGenX/ngx-windows-agent-installer"

Write-Host ""
Write-Host "  NexGenX Windows Agent Bootstrap" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host "  Repo:   github.com/$PublicRepo" -ForegroundColor Gray
Write-Host "  Version: $Version" -ForegroundColor Gray
Write-Host ""

# Download and run the appropriate installer
if ($Version -eq "v107") {
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/main/server/install-v107.ps1"
} else {
    $installerUrl = "https://raw.githubusercontent.com/$PublicRepo/main/server/install-v106.ps1"
}

Write-Host "  Downloading installer..." -ForegroundColor Gray
$installerScript = irm $installerUrl
$scriptBlock = [scriptblock]::Create($installerScript)
$scriptBlock.Invoke(@($InstallPath))

Write-Host ""
Write-Host "  Installation complete!" -ForegroundColor Green
