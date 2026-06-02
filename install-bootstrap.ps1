# =============================================================================
# NexGenX Windows Agent — Public Bootstrap Installer
# https://github.com/NexGenX/ngx-windows-agent-installer
#
# This is a SMALL public script (under 2 KB) that customers run as Admin:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1)
#
# It downloads the REAL installer from the same public repo and runs it.
# No GitHub credentials required.
#
# For unattended/scripted installs:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/install-bootstrap.ps1); .\install.ps1 -InstallPath 'C:\NexGenX'
# =============================================================================

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX",
    [string]$Version = "latest"  # "latest" or a tag like "v1.0.0"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Resolve the public repo location
$PublicRepo = "NexGenX/ngx-windows-agent-installer"

Write-Host ""
Write-Host "  NexGenX Windows Agent Bootstrap" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host "  Repo:   github.com/$PublicRepo" -ForegroundColor Gray
Write-Host "  Target: $InstallPath" -ForegroundColor Gray
Write-Host ""

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[NexGenX] ERROR: Please run as Administrator (right-click PowerShell -> Run as Administrator)" -ForegroundColor Red
    exit 1
}

# Build URL to the real install.ps1
$baseUrl = if ($Version -eq "latest") {
    "https://raw.githubusercontent.com/$PublicRepo/main"
} else {
    "https://raw.githubusercontent.com/$PublicRepo/$Version"
}
$installUrl = "$baseUrl/server/install.ps1"

Write-Host "[NexGenX] Downloading installer from $installUrl..." -ForegroundColor Cyan
$installer = "$env:TEMP\ngx-install.ps1"

try {
    # Use -DisableKeepAlive to avoid PowerShell's per-process HTTP cache, which
    # can serve a stale version of the file even when GitHub has been updated.
    Invoke-WebRequest -Uri $installUrl -OutFile $installer -UseBasicParsing -TimeoutSec 60 -DisableKeepAlive
    $downloadedBytes = (Get-Item $installer).Length
    if ($downloadedBytes -lt 1000) {
        throw "Downloaded file is too small ($downloadedBytes bytes) — likely a 404 page"
    }
    Write-Host "[NexGenX] Downloaded $downloadedBytes bytes" -ForegroundColor Green
} catch {
    Write-Host "[NexGenX] ERROR: Failed to download installer: $_" -ForegroundColor Red
    Write-Host "[NexGenX] If the repo URL has changed, get the latest from https://github.com/$PublicRepo" -ForegroundColor Yellow
    exit 1
}

Write-Host "[NexGenX] Running installer..." -ForegroundColor Cyan
Write-Host ""

# Execute the real installer.
# NOTE: Use -ExecutionPolicy Bypass when invoking the downloaded file because
# Windows default execution policy may block .ps1 files in the TEMP directory
# (which is Untrusted by the system zone check). The bootstrap's own
# `iex (irm ...)` invocation is OK because it runs in-process, but the
# downloaded file needs its own policy override.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -InstallPath $InstallPath -Version $Version

# Clean up downloaded installer
Remove-Item $installer -Force -ErrorAction SilentlyContinue
