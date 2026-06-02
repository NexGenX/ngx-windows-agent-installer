# NexGenX Windows Agent — Bootstrap Installer
# This is a tiny launcher that just calls the real install.ps1 from the repo.
# Customers can use this as a one-liner: iex (irm this-file)
#
# Full installer: https://github.com/NexGenX/ngx-windows-agent/blob/main/server/install.ps1

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX",
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "  NexGenX Windows Agent Bootstrap" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[NexGenX] Please run as Administrator" -ForegroundColor Red
    exit 1
}

# Download the real installer
$url = if ($Version -eq "latest") {
    "https://raw.githubusercontent.com/NexGenX/ngx-windows-agent/main/server/install.ps1"
} else {
    "https://raw.githubusercontent.com/NexGenX/ngx-windows-agent/$Version/server/install.ps1"
}

Write-Host "[NexGenX] Downloading installer from $url..." -ForegroundColor Cyan
$installer = "$env:TEMP\ngx-install.ps1"

try {
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 60
} catch {
    Write-Host "[NexGenX] Failed to download installer: $_" -ForegroundColor Red
    exit 1
}

Write-Host "[NexGenX] Running installer..." -ForegroundColor Cyan
Write-Host ""

# Execute the real installer with the same parameters
& $installer -InstallPath $InstallPath -Version $Version

# Clean up
Remove-Item $installer -Force -ErrorAction SilentlyContinue
