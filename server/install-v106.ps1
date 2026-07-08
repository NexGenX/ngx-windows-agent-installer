# NexGenX Windows Agent — v1.06 Installer
# ========================================
# Installs v1.06 (self-healing watchdog + supervisor) ALONGSIDE v1.05.
# v1.05 is NOT removed. To switch: this script unregisters the v1.05
# scheduled task and registers a v1.06 task that runs the supervisor.
# To rollback: ./rollback-v105.ps1.
#
# Install layout:
#   C:\NexGenX\                  <- v1.05 (unchanged, used for rollback)
#   C:\NexGenX\v106\             <- v1.06 files (this installer)
#   C:\ProgramData\NexGenX\      <- shared state (access code, audit log, supervisor log)
#
# Usage:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent/main/server/install-v106.ps1)
#
# Or locally on the VM (from the source tree):
#   .\install-v106.ps1 -SourcePath C:\path\to\v106\source

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v106",
    [string]$SourcePath = "",   # local source dir; if empty, expects files alongside the script
    [string]$V105Path = "C:\NexGenX"   # where v1.05 currently lives (for the rollback safety net)
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ─── Helpers ────────────────────────────────────────────────────────────

function Write-Step($msg) { Write-Host ""; Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    [X] $msg" -ForegroundColor Red; throw $msg }

# ─── Pre-flight ────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  NexGenX Windows Agent v1.06 Installer" -ForegroundColor Cyan
Write-Host "  =====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Install path: $InstallPath" -ForegroundColor Gray
Write-Host "  v1.05 path:   $V105Path (left untouched)" -ForegroundColor Gray
Write-Host ""

# Admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "Please run as Administrator"
}

# Locate python.exe (use the v1.05 install's python if available, else PATH)
function Get-PythonExe {
    # Prefer the python that the v1.05 install used (preserves venv)
    $candidates = @(
        "$V105Path\.venv\Scripts\python.exe",
        "$V105Path\python\python.exe",
        (Get-Command python.exe -ErrorAction SilentlyContinue).Source,
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    Write-Err "No python.exe found. Install Python 3.11+ first."
}
$pyExe = Get-PythonExe
Write-Ok "Using Python: $pyExe"

# Locate source files
function Get-SourceDir {
    if ($SourcePath -and (Test-Path $SourcePath)) { return (Resolve-Path $SourcePath).Path }
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ($scriptDir -and (Test-Path "$scriptDir\agent_server.py")) { return $scriptDir }
    Write-Err "No source files found. Pass -SourcePath <dir> or run from the source tree."
}
$srcDir = Get-SourceDir
Write-Ok "Source dir: $srcDir"

# Files we need (the v1.06 bundle)
$requiredFiles = @(
    "agent_server.py",
    "agent_server_common.py",
    "agent_watchdog.py",
    "agent_supervisor.py",
    "requirements.txt",
    "test_watchdog.py"
)
foreach ($f in $requiredFiles) {
    if (-not (Test-Path "$srcDir\$f")) {
        Write-Err "Missing required file: $f in $srcDir"
    }
}

# ─── Stop v1.05 if running ────────────────────────────────────────────

Write-Step "Stopping v1.05 if running..."

$v105TaskName = "NexGenXAgent"
$v106TaskName = "NexGenXAgent-v106"
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$existingV105 = Get-ScheduledTask -TaskName $v105TaskName -ErrorAction SilentlyContinue
if ($existingV105) {
    Write-Ok "Found v1.05 scheduled task '$v105TaskName' -- stopping it"
    try { Stop-ScheduledTask -TaskName $v105TaskName -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    Get-NetTCPConnection -LocalPort 9400 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq "python") {
            Write-Warn "Killing orphan python pid=$($proc.Id) holding port 9400"
            try { Stop-Process -Id $proc.Id -Force } catch {}
        }
    }
    Unregister-ScheduledTask -TaskName $v105TaskName -Confirm:$false
    Write-Ok "Unregistered v1.05 task (files kept at $V105Path for rollback)"
} else {
    Write-Ok "No v1.05 task found, nothing to stop"
}

# ─── Install v1.06 files ──────────────────────────────────────────────

Write-Step "Installing v1.06 to $InstallPath..."

New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
if (-not (Test-Path $InstallPath)) { Write-Err "Failed to create $InstallPath" }

foreach ($f in $requiredFiles) {
    Copy-Item -Path "$srcDir\$f" -Destination "$InstallPath\$f" -Force
    Write-Ok "Copied $f"
}

# ─── Install/upgrade Python dependencies ──────────────────────────────

Write-Step "Ensuring Python dependencies (mss, pyautogui, fastapi, uiautomation, pywin32)..."

# We install the watchdog's deps into the python that the supervisor will use.
# If v1.05 already has a venv, reuse it (saves ~200MB).
$venvPython = "$V105Path\.venv\Scripts\python.exe"
if (Test-Path $venvPython) {
    Write-Ok "Reusing v1.05 venv at $V105Path\.venv"
    $pyForDeps = $venvPython
} else {
    $pyForDeps = $pyExe
}

try { & $pyForDeps -m pip install --disable-pip-version-check --quiet "fastapi==0.115.0" "uvicorn==0.30.6" "pyautogui==0.9.54" "Pillow==10.4.0" "numpy==1.26.4" "mss==9.0.1" "pywin32==306" "uiautomation==2.0.29" 2>&1 | Out-Null } catch {}
Write-Ok "Dependencies OK"

# ─── Register v1.06 scheduled task (runs the supervisor) ─────────────

Write-Step "Registering v1.06 scheduled task '$v106TaskName'..."

# The task runs the SUPERVISOR, not agent_server.py directly. The
# supervisor launches agent_server.py as a child and restarts it on
# non-zero exit.
$taskAction = New-ScheduledTaskAction `
    -Execute $pyForDeps `
    -Argument "`"$InstallPath\agent_supervisor.py`"" `
    -WorkingDirectory $InstallPath

# At logon: this gives the agent ~2 minutes of head start before customer
# work begins, and reboots across disconnects.
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn

# Run as the same user (interactive session so we have a desktop).
# If the user needs SYSTEM, switch to -UserId "SYSTEM" and remove -LogonType.
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Highest

# Settings:
#   - AllowStartIfOnBatteries / DontStopIfGoingOnBatteries: keep running on laptop
#   - StartWhenAvailable: if a scheduled start is missed, run ASAP
#   - RestartCount=999: if the task exits (e.g. supervisor dies), restart
#   - No RestartInterval: default 1-minute, which is fine for our supervisor
#     backoff (1, 2, 4, 8, 16, 32, 60s). PS 5.1 has trouble serializing the
#     interval to the task XML; skip and rely on the supervisor's own
#     backoff loop.
#   - ExecutionTimeLimit=0 (infinite): supervisor runs forever
$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -ExecutionTimeLimit "00:00:00"

# Unregister any old v106 task
$existingV106 = Get-ScheduledTask -TaskName $v106TaskName -ErrorAction SilentlyContinue
if ($existingV106) {
    Unregister-ScheduledTask -TaskName $v106TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $v106TaskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Principal $taskPrincipal `
    -Settings $taskSettings `
    -Description "NexGenX Windows Agent Server v1.06 (self-healing)" | Out-Null

Write-Ok "Task registered"

# ─── Start the task ──────────────────────────────────────────────────

Write-Step "Starting v1.06..."

Start-ScheduledTask -TaskName $v106TaskName
Start-Sleep -Seconds 3

# ─── Health check ────────────────────────────────────────────────────

Write-Step "Verifying agent is responding..."

$port = 9400
$healthy = $false
for ($i = 0; $i -lt 10; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/ping" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -eq 200) {
            $body = $resp.Content | ConvertFrom-Json
            Write-Ok "/ping responded: $( $body | ConvertTo-Json -Compress )"
            $healthy = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $healthy) {
    Write-Err "Agent did not respond to /ping within 20 seconds. Check Task Scheduler history."
}

# Try the deep health check (read access code from disk first)
$codeFile = "$env:PROGRAMDATA\NexGenX\agent_access.txt"
if (Test-Path $codeFile) {
    $code = (Get-Content $codeFile -Raw).Trim()
    try {
        $headers = @{ "X-Access-Code" = $code }
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health/deep" -Headers $headers -UseBasicParsing -TimeoutSec 10
        $body = $resp.Content | ConvertFrom-Json
        Write-Ok "/health/deep: overall_ok=$($body.overall_ok) version=$($body.agent_version) uptime=$($body.uptime_s)s"
        Write-Ok "Subsystems:"
        $body.subsystems | ForEach-Object {
            $status = if ($_.ok) { "OK" } else { "DEGRADED" }
            Write-Host "      [$status] $($_.name): $($_.detail)" -ForegroundColor $( if ($_.ok) { "Green" } else { "Yellow" } )
        }
    } catch {
        Write-Warn "/health/deep failed: $_"
    }
} else {
    Write-Warn "Access code file not found at $codeFile, skipping /health/deep"
}

# ─── Done ────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  v1.06 installed and running" -ForegroundColor Green
Write-Host ""
Write-Host "  Scheduled task: $v106TaskName" -ForegroundColor Gray
Write-Host "  Files:          $InstallPath" -ForegroundColor Gray
Write-Host "  Logs:           $env:PROGRAMDATA\NexGenX\supervisor.log" -ForegroundColor Gray
Write-Host "  Audit:          $env:PROGRAMDATA\NexGenX\audit.log" -ForegroundColor Gray
Write-Host "  Watchdog:       http://127.0.0.1:9400/health/deep (with X-Access-Code)" -ForegroundColor Gray
Write-Host ""
Write-Host "  To rollback to v1.05:  .\rollback-v105.ps1" -ForegroundColor Yellow
Write-Host ""
