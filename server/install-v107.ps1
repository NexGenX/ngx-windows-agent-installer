# NexGenX Windows Agent — v1.07 Installer
# ========================================
# Installs v1.06 (self-healing watchdog + supervisor) + v107 vision module (OCR, verified clicks)
# This is the FULL version with OCR, find_text, click_verified, verify, and workflow endpoints.
#
# Usage (as Administrator):
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/server/install-v107.ps1)
#
# Or from local source:
#   .\install-v107.ps1 -SourcePath C:\path\to\source

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v106",
    [string]$V105Path = "C:\NexGenX"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "  NexGenX Windows Agent v1.0.7" -ForegroundColor Cyan
Write-Host "  ===============================" -ForegroundColor Cyan
Write-Host "  With OCR + Vision + Verified Clicks" -ForegroundColor Gray
Write-Host ""

# Step 1: Run v1.06 installer first (base + self-healing)
Write-Host "[1/4] Installing v1.06 base..." -ForegroundColor Yellow
$InstallV106 = "https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/server/install-v106.ps1"
$null = New-Item -ItemType Directory -Force -Path $InstallPath
$v106Script = (irm $InstallV106)
$scriptBlock = [scriptblock]::Create($v106Script)
$scriptBlock.Invoke(@($InstallPath, $V105Path))

# Step 2: Install v107 vision dependencies
Write-Host "[2/4] Installing v107 vision dependencies..." -ForegroundColor Yellow
pip install winrt-runtime 2>$null
pip install winrt-Windows.Media.Ocr 2>$null
pip install winrt-Windows.Globalization 2>$null
pip install winrt-Windows.Graphics.Imaging 2>$null
pip install winrt-Windows.Storage.Streams 2>$null

# Step 3: Download v107 module files
Write-Host "[3/4] Downloading v107 vision module..." -ForegroundColor Yellow
$V107BaseUrl = "https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/main/server/v107"
Invoke-WebRequest -Uri "$V107BaseUrl/v107_module.py" -OutFile "$InstallPath\v107_module.py"
Invoke-WebRequest -Uri "$V107BaseUrl/ocr_engine.py" -OutFile "$InstallPath\ocr_engine.py"

# Step 4: Patch agent_server.py to load v107
Write-Host "[4/4] Patching agent_server.py to load v107..." -ForegroundColor Yellow
$serverFile = "$InstallPath\agent_server.py"
if (Test-Path $serverFile) {
    $content = Get-Content $serverFile -Raw
    if ($content -notmatch "v107_module") {
        $content = $content -replace "(agent\s*=\s*WindowsAgent\(\))", "`$1`nfrom v107_module import install_routes`nv107_install_routes(agent.app, agent)"
        Set-Content -Path $serverFile -Value $content -Encoding UTF8
        Write-Host "  Patched agent_server.py" -ForegroundColor Green
    } else {
        Write-Host "  agent_server.py already patched" -ForegroundColor Gray
    }
} else {
    # Download the v107-patched agent_server.py
    Invoke-WebRequest -Uri "$V107BaseUrl/agent_server_v107.py" -OutFile "$InstallPath\agent_server.py"
    Write-Host "  Downloaded v107-patched agent_server.py" -ForegroundColor Green
}

# Restart the agent
Write-Host ""
Write-Host "Restarting agent..." -ForegroundColor Yellow
schtasks /End /TN "NexGenXAgent" 2>$null
Start-Sleep 2
schtasks /Run /TN "NexGenXAgent"
Start-Sleep 5

# Verify v107 is loaded
try {
    $health = Invoke-RestMethod -Uri "http://localhost:9400/health" -TimeoutSec 10
    if ($health.v107 -eq $true) {
        Write-Host ""
        Write-Host "  v1.0.7 installed successfully!" -ForegroundColor Green
        Write-Host "  OCR available: $($health.ocr_available)" -ForegroundColor Green
    } else {
        Write-Host "  Agent running but v107 not detected. Check logs." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Agent starting up - check http://localhost:9400/health in a few seconds" -ForegroundColor Yellow
}

Write-Host ""
$accessCode = Get-Content C:\ProgramData\NexGenX\agent_access.txt -ErrorAction SilentlyContinue
Write-Host "  Access code: $accessCode" -ForegroundColor Cyan
Write-Host ""