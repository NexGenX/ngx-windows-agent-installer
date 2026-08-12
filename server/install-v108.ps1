# NexGenX Windows Agent — v1.0.8 Installer / Upgrader
# ====================================================
# Unified install with OCR/vision, correct version reporting, and
# Session-safe start (Interactive Scheduled Task only).
#
# Fresh install:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/install-bootstrap.ps1)
#
# Upgrade existing machine:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.8/upgrade-bootstrap.ps1)

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v108",
    [string]$LegacyPath = "C:\NexGenX",
    [string]$Branch = "v1.0.8",
    [string]$PublicRepo = "NexGenX/ngx-windows-agent-installer",
    [int]$Port = 9400,
    [switch]$Upgrade
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$AgentVersion = "1.0.8"
$TaskName = "NexGenXAgent"
$OldTaskNames = @("NexGenXAgent", "NexGenXAgent-v106")

function Write-Step($msg) { Write-Host ""; Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    [X] $msg" -ForegroundColor Red; throw $msg }

Write-Host ""
Write-Host "  NexGenX Windows Agent v$AgentVersion" -ForegroundColor Cyan
Write-Host "  ==================================" -ForegroundColor Cyan
if ($Upgrade) { Write-Host "  Mode: UPGRADE" -ForegroundColor Yellow }
else { Write-Host "  Mode: INSTALL" -ForegroundColor Gray }
Write-Host "  Path: $InstallPath" -ForegroundColor Gray
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Err "Please run as Administrator" }

# ─── Python ───────────────────────────────────────────────────────────
function Get-PythonExe {
    $candidates = @(
        "$LegacyPath\.venv\Scripts\python.exe",
        "$LegacyPath\v106\.venv\Scripts\python.exe",
        "$InstallPath\.venv\Scripts\python.exe",
        (Get-Command python.exe -ErrorAction SilentlyContinue).Source,
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    Write-Err "No python.exe found. Install Python 3.11+ first (or run the classic install.ps1 once)."
}
$pyExe = Get-PythonExe
Write-Ok "Using Python: $pyExe"

# ─── Stop old tasks / listeners ───────────────────────────────────────
Write-Step "Stopping previous agent tasks..."
foreach ($tn in $OldTaskNames) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($t) {
        try { Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch {}
        Write-Ok "Stopped task $tn"
    }
}
Start-Sleep -Seconds 2
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -match "python") {
        Write-Warn "Killing orphan python pid=$($proc.Id) on port $Port"
        try { Stop-Process -Id $proc.Id -Force } catch {}
    }
}

# ─── Download v108 bundle ─────────────────────────────────────────────
Write-Step "Downloading v$AgentVersion files..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
$baseUrl = "https://raw.githubusercontent.com/$PublicRepo/$Branch/server/v108"
$files = @(
    "agent_server.py",
    "agent_server_common.py",
    "agent_supervisor.py",
    "agent_watchdog.py",
    "v107_module.py",
    "ocr_engine.py",
    "requirements.txt"
)
foreach ($f in $files) {
    $dest = Join-Path $InstallPath $f
    Invoke-WebRequest -Uri "$baseUrl/$f" -OutFile $dest -UseBasicParsing -TimeoutSec 60
    Write-Ok "Fetched $f"
}

# Safety: force agent_version string
$commonPath = Join-Path $InstallPath "agent_server_common.py"
$common = Get-Content $commonPath -Raw
$common = [regex]::Replace($common, 'agent_version:\s*str\s*=\s*"[^"]+"', "agent_version: str = `"$AgentVersion`"")
Set-Content -Path $commonPath -Value $common -Encoding UTF8
Write-Ok "Pinned agent_version to $AgentVersion"

# ─── Dependencies ─────────────────────────────────────────────────────
Write-Step "Installing Python dependencies..."
try {
    & $pyExe -m pip install --disable-pip-version-check --quiet -r (Join-Path $InstallPath "requirements.txt") 2>&1 | Out-Null
} catch {}
$ocrPkgs = @(
    "winrt-runtime",
    "winrt-Windows.Media.Ocr",
    "winrt-Windows.Globalization",
    "winrt-Windows.Graphics.Imaging",
    "winrt-Windows.Storage.Streams"
)
foreach ($pkg in $ocrPkgs) {
    try { & $pyExe -m pip install --disable-pip-version-check --quiet $pkg 2>&1 | Out-Null } catch {}
}
Write-Ok "Dependencies OK"

# ─── Firewall (idempotent) ────────────────────────────────────────────
Write-Step "Ensuring firewall rule for port $Port..."
try {
    $ruleName = "NexGenX Agent Server"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
    }
    Write-Ok "Firewall OK"
} catch {
    Write-Warn "Firewall skipped: $_"
}

# ─── Scheduled task (Interactive only) ────────────────────────────────
Write-Step "Registering scheduled task '$TaskName' (Interactive / AtLogOn)..."
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskAction = New-ScheduledTaskAction `
    -Execute $pyExe `
    -Argument "`"$InstallPath\agent_supervisor.py`"" `
    -WorkingDirectory $InstallPath
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -ExecutionTimeLimit "00:00:00"

foreach ($tn in $OldTaskNames) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
        Write-Ok "Unregistered old task $tn"
    }
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Principal $taskPrincipal `
    -Settings $taskSettings `
    -Description "NexGenX Windows Agent Server v$AgentVersion (OCR + self-healing)" | Out-Null
Write-Ok "Task registered as $TaskName"

# NEVER Start-Process the long-running agent — that lands in Session 0.
Write-Step "Starting agent via Start-ScheduledTask (not Start-Process)..."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 4

# ─── Verification ─────────────────────────────────────────────────────
Write-Step "Verifying..."

$healthy = $false
for ($i = 0; $i -lt 12; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/ping" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -eq 200) { $healthy = $true; break }
    } catch { Start-Sleep -Seconds 2 }
}
if (-not $healthy) {
    Write-Err "Agent did not respond to /ping. Check Task Scheduler and $env:PROGRAMDATA\NexGenX\supervisor.log"
}
Write-Ok "/ping OK"

# Session check
$conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Ok "Listener PID=$($proc.Id) SessionId=$($proc.SessionId)"
        if ($proc.SessionId -eq 0) {
            Write-Err "Agent is in Session 0 (no desktop). Screenshots will fail. Do not use Start-Process. Re-run this installer while a user is logged on, or log off/on so AtLogOn fires, then Start-ScheduledTask -TaskName $TaskName"
        }
    }
}

# /health (v107)
try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 10
    if ($health.v107 -ne $true) {
        Write-Err "/health missing v107=true"
    }
    if ($health.agent_version -and $health.agent_version -ne $AgentVersion) {
        Write-Err "/health agent_version=$($health.agent_version) expected $AgentVersion"
    }
    Write-Ok "/health v107=$($health.v107) agent_version=$($health.agent_version) ocr=$($health.ocr_available)"
} catch {
    Write-Err "/health failed: $_"
}

# /info version
$codeFile = "$env:PROGRAMDATA\NexGenX\agent_access.txt"
if (Test-Path $codeFile) {
    $code = (Get-Content $codeFile -Raw).Trim()
    $headers = @{ "X-Access-Code" = $code }
    try {
        $info = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/info" -Headers $headers -TimeoutSec 10
        if ($info.agent_version -ne $AgentVersion) {
            Write-Err "/info agent_version=$($info.agent_version) expected $AgentVersion"
        }
        Write-Ok "/info agent_version=$($info.agent_version)"
    } catch {
        Write-Warn "/info failed: $_"
    }
    try {
        $shot = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/screenshot" -Headers $headers -UseBasicParsing -TimeoutSec 15
        if ($shot.StatusCode -eq 200 -and $shot.RawContentLength -gt 100) {
            Write-Ok "/screenshot OK ($($shot.RawContentLength) bytes)"
        } else {
            Write-Warn "/screenshot unexpected response"
        }
    } catch {
        Write-Warn "/screenshot failed (user may not have an interactive desktop yet): $_"
    }
} else {
    Write-Warn "Access code file missing at $codeFile — skipped /info and /screenshot checks"
}

Write-Host ""
Write-Host "  v$AgentVersion ready" -ForegroundColor Green
Write-Host "  Task:   $TaskName" -ForegroundColor Gray
Write-Host "  Files:  $InstallPath" -ForegroundColor Gray
Write-Host "  Logs:   $env:PROGRAMDATA\NexGenX\supervisor.log" -ForegroundColor Gray
Write-Host "  Code:   $env:PROGRAMDATA\NexGenX\agent_access.txt" -ForegroundColor Gray
Write-Host ""
Write-Host "  Reminder: never start the agent with Start-Process." -ForegroundColor Yellow
Write-Host "  Always: Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Yellow
Write-Host ""
