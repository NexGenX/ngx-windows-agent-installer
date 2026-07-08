# NexGenX Windows Agent — v1.05 Rollback
# ========================================
# One-line rollback from v1.06 to v1.05. Used if v1.06 is broken.
# Assumes v1.05 files are still in place at C:\NexGenX\ (we never
# deleted them when installing v1.06).
#
# Usage (on the WinBolt VM, as Administrator):
#   .\rollback-v105.ps1
#
# What it does:
#   1. Stops the v1.06 task
#   2. Re-registers the v1.05 task pointing at C:\NexGenX\agent_server.py
#   3. Starts v1.05
#   4. Verifies /ping
# That's it. v1.06 files are left in place at C:\NexGenX\v106\ for
# forensics — delete manually once you're sure v1.05 is good.

[CmdletBinding()]
param(
    [string]$V105Path = "C:\NexGenX",
    [int]$Port = 9400
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host ""; Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    [X] $msg" -ForegroundColor Red; throw $msg }

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Err "Please run as Administrator" }

Write-Host ""
Write-Host "  NexGenX Rollback: v1.06 -> v1.05" -ForegroundColor Yellow
Write-Host "  ================================" -ForegroundColor Yellow
Write-Host ""

$v105TaskName = "NexGenXAgent"
$v106TaskName = "NexGenXAgent-v106"

# Verify v1.05 files exist
if (-not (Test-Path "$V105Path\agent_server.py")) {
    Write-Err "v1.05 files not found at $V105Path. Cannot rollback."
}

# Locate python (the v1.05 venv, or system python)
$pyExe = $null
$candidates = @(
    "$V105Path\.venv\Scripts\python.exe",
    "$V105Path\python\python.exe",
    (Get-Command python.exe -ErrorAction SilentlyContinue).Source
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $pyExe = $c; break }
}
if (-not $pyExe) { Write-Err "No python.exe found" }
Write-Ok "Using Python: $pyExe"

Write-Step "Stopping v1.06..."
$v106Task = Get-ScheduledTask -TaskName $v106TaskName -ErrorAction SilentlyContinue
if ($v106Task) {
    try { Stop-ScheduledTask -TaskName $v106TaskName -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName $v106TaskName -Confirm:$false
    Write-Ok "Unregistered v1.06 task"
} else {
    Write-Ok "No v1.06 task to stop"
}

# Kill anything still holding port 9400
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq "python") {
            Write-Warn "Killing orphan python pid=$($proc.Id) holding port $Port"
            try { Stop-Process -Id $proc.Id -Force } catch { }
        }
    }
Start-Sleep -Seconds 1

Write-Step "Re-registering v1.05 task '$v105TaskName'..."

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskAction = New-ScheduledTaskAction `
    -Execute $pyExe `
    -Argument "`"$V105Path\agent_server.py`"" `
    -WorkingDirectory $V105Path
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

$existing = Get-ScheduledTask -TaskName $v105TaskName -ErrorAction SilentlyContinue
if ($existing) { Unregister-ScheduledTask -TaskName $v105TaskName -Confirm:$false }

Register-ScheduledTask `
    -TaskName $v105TaskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Principal $taskPrincipal `
    -Settings $taskSettings `
    -Description "NexGenX Windows Agent Server v1.05 (rollback target)" | Out-Null

Write-Ok "Task registered"

Write-Step "Starting v1.05..."
Start-ScheduledTask -TaskName $v105TaskName
Start-Sleep -Seconds 3

Write-Step "Verifying /ping..."
$healthy = $false
for ($i = 0; $i -lt 10; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/ping" -UseBasicParsing -TimeoutSec 5
        if ($resp.StatusCode -eq 200) {
            $body = $resp.Content | ConvertFrom-Json
            Write-Ok "/ping responded: $($body | ConvertTo-Json -Compress)"
            $healthy = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 2
    }
}
if (-not $healthy) {
    Write-Err "v1.05 did not respond to /ping within 20 seconds. Check Task Scheduler history."
}

Write-Host ""
Write-Host "  v1.05 restored, /ping OK" -ForegroundColor Green
Write-Host ""
Write-Host "  v1.06 files are still at C:\NexGenX\v106\ — delete manually when you're done debugging." -ForegroundColor Gray
Write-Host ""
