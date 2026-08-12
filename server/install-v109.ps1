# NexGenX Windows Agent — v1.0.9 Installer / Upgrader
# ====================================================
# Public installer script. Agent SOURCE stays in the private repo
# NexGenX/ngx-windows-agent and is downloaded as a release zip.
#
# Install (Administrator):
#   $env:NEXGENX_GITHUB_TOKEN = "<fine-grained PAT with private release read>"
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/install-bootstrap.ps1)
#
# Upgrade:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent-installer/v1.0.9/upgrade-bootstrap.ps1)
#
# Or pass an explicit bundle URL (e.g. Mission Control / internal CDN):
#   .\install-v109.ps1 -BundleUrl "https://..."

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX\v109",
    [string]$LegacyPath = "C:\NexGenX",
    [string]$AgentRepo = "NexGenX/ngx-windows-agent",
    [string]$ReleaseTag = "v1.0.9",
    [string]$AssetName = "ngx-agent-v1.0.9.zip",
    [string]$BundleUrl = "",
    [string]$GitHubToken = "",
    [int]$Port = 9400,
    [switch]$Upgrade,
    [switch]$SkipPythonInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$AgentVersion = "1.0.9"
$TaskName = "NexGenXAgent"
$OldTaskNames = @("NexGenXAgent", "NexGenXAgent-v106", "NexGenXAgent-v107", "NexGenXAgent-v108")

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

if (-not $GitHubToken) { $GitHubToken = $env:NEXGENX_GITHUB_TOKEN }
if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }
if (-not $BundleUrl) { $BundleUrl = $env:NEXGENX_BUNDLE_URL }

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
    return $null
}

function Install-Python311 {
    Write-Step "Python not found. Downloading Python 3.11..."
    $pythonUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
    $installer = "$env:TEMP\python-3.11.9-amd64.exe"
    try {
        Invoke-WebRequest -Uri $pythonUrl -OutFile $installer -UseBasicParsing -TimeoutSec 180
    } catch {
        Write-Err "Failed to download Python. Install Python 3.11+ manually from python.org"
    }
    Write-Step "Installing Python (this may take a minute)..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_pip=1" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Err "Python installer exited with code $($proc.ExitCode)"
    }
    # Refresh PATH for this process
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Start-Sleep -Seconds 2
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    $found = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($c in @("C:\Python311\python.exe", "C:\Program Files\Python311\python.exe")) {
        if (Test-Path $c) { return $c }
    }
    Write-Err "Python installed but python.exe not found on PATH. Open a new Admin PowerShell and re-run."
}

$pyExe = Get-PythonExe
if (-not $pyExe) {
    if ($SkipPythonInstall) {
        Write-Err "No python.exe found and -SkipPythonInstall was set."
    }
    $pyExe = Install-Python311
}
Write-Ok "Using Python: $pyExe"

# ─── Stop ALL previous agents (tasks / services / PIDs on $Port) ───────
# Upgrades used to only stop NexGenXAgent + NexGenXAgent-v106. Leftover
# v1.0.7 tasks/services could reclaim :9400 after reboot and shadow v1.0.9.
Write-Step "Stopping previous agent tasks, services, and listeners..."

# 1) Stop + unregister every scheduled task that looks like ours
$taskMatches = @()
$taskMatches += $OldTaskNames
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -match 'NexGen' -or
    ($_.Actions.Execute -match 'NexGenX|agent_supervisor|agent_server') -or
    ($_.Actions.Arguments -match 'NexGenX|agent_supervisor|agent_server')
} | ForEach-Object { $taskMatches += $_.TaskName }
$taskMatches = $taskMatches | Select-Object -Unique
foreach ($tn in $taskMatches) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if (-not $t) { continue }
    try { Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch {}
    Write-Ok "Stopped task $tn"
    # Keep the canonical task name for re-register below; remove legacy names now
    if ($tn -ne $TaskName) {
        try {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
            Write-Ok "Unregistered legacy task $tn"
        } catch {}
    }
}

# 2) Stop Windows services if any were ever registered
Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'NexGen' -or $_.DisplayName -match 'NexGen'
} | ForEach-Object {
    try {
        if ($_.Status -ne 'Stopped') { Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue }
        Write-Ok "Stopped service $($_.Name)"
    } catch {}
}

# 3) Kill anything listening on the agent port (any process name)
Start-Sleep -Seconds 1
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Warn "Killing listener pid=$($proc.Id) ($($proc.ProcessName)) on port $Port"
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# 4) Kill leftover agent processes by command line (old install paths)
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and (
        $_.CommandLine -match 'NexGenX\\.*(agent_server|agent_supervisor|agent_watchdog)' -or
        $_.CommandLine -match 'C:\\NexGenX\\.*(agent_server|agent_supervisor)' 
    )
} | ForEach-Object {
    Write-Warn "Killing leftover agent pid=$($_.ProcessId) ($($_.Name))"
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

Start-Sleep -Seconds 2
$still = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($still) {
    Write-Warn "Port $Port still in use after cleanup — upgrade will continue; verify listener after start"
} else {
    Write-Ok "Port $Port is free"
}

# ─── Download PRIVATE agent bundle ────────────────────────────────────
Write-Step "Downloading private agent bundle ($ReleaseTag)..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
$zipPath = Join-Path $env:TEMP $AssetName

if (-not $BundleUrl) {
    if (-not $GitHubToken) {
        Write-Err "Private agent bundle requires auth. Set NEXGENX_GITHUB_TOKEN (read access to NexGenX/ngx-windows-agent releases), or pass -BundleUrl to an internal CDN copy."
    }
    $BundleUrl = "https://api.github.com/repos/$AgentRepo/releases/assets"
    # Resolve asset id via API
    $relHeaders = @{
        "Authorization" = "Bearer $GitHubToken"
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "NexGenX-Installer"
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$AgentRepo/releases/tags/$ReleaseTag" -Headers $relHeaders -TimeoutSec 60
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) { Write-Err "Release $ReleaseTag has no asset named $AssetName" }
    $assetUrl = $asset.url
    Write-Ok "Found asset id=$($asset.id) size=$($asset.size)"
    $dlHeaders = @{
        "Authorization" = "Bearer $GitHubToken"
        "Accept" = "application/octet-stream"
        "User-Agent" = "NexGenX-Installer"
    }
    Invoke-WebRequest -Uri $assetUrl -Headers $dlHeaders -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
} else {
    Write-Ok "Using BundleUrl"
    $dlHeaders = @{ "User-Agent" = "NexGenX-Installer" }
    if ($GitHubToken) { $dlHeaders["Authorization"] = "Bearer $GitHubToken" }
    Invoke-WebRequest -Uri $BundleUrl -Headers $dlHeaders -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
}

if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1000) {
    Write-Err "Bundle download failed or file too small"
}
Write-Ok "Downloaded $([math]::Round((Get-Item $zipPath).Length/1KB,1)) KB"

# Extract to temp then copy files into InstallPath (handles ngx-agent-v109/ prefix)
$extractRoot = Join-Path $env:TEMP "ngx-agent-extract-$AgentVersion"
if (Test-Path $extractRoot) { Remove-Item $extractRoot -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force
$payload = $extractRoot
$nested = Join-Path $extractRoot "ngx-agent-v109"
if (Test-Path $nested) { $payload = $nested }

$required = @(
    "agent_server.py",
    "agent_server_common.py",
    "agent_supervisor.py",
    "agent_watchdog.py",
    "v107_module.py",
    "ocr_engine.py",
    "requirements.txt"
)
foreach ($f in $required) {
    $src = Join-Path $payload $f
    if (-not (Test-Path $src)) { Write-Err "Bundle missing required file: $f" }
    Copy-Item -Path $src -Destination (Join-Path $InstallPath $f) -Force
    Write-Ok "Installed $f"
}

# ─── Copy skills runtime + skills directories (v1.0.9 skill API) ─────
# The bundle includes skills_runtime/ and skills/ which are required for
# the /skills API endpoints to register. Without these, agent_server.py
# logs "[skills] WARNING: install failed..." and /skills returns 404.
$skillDirs = @("skills_runtime", "skills")
foreach ($dir in $skillDirs) {
    $srcDir = Join-Path $payload $dir
    $dstDir = Join-Path $InstallPath $dir
    if (-not (Test-Path $srcDir)) {
        Write-Err "Bundle missing required directory: $dir (skills API will not work without it)"
    }
    if (Test-Path $dstDir) { Remove-Item $dstDir -Recurse -Force }
    Copy-Item -Path $srcDir -Destination $dstDir -Recurse -Force
    $fileCount = (Get-ChildItem -Path $dstDir -Recurse -File).Count
    Write-Ok "Installed $dir/ ($fileCount files)"
}

# Also copy tray_app.py if present (system tray integration)
$traySrc = Join-Path $payload "tray_app.py"
if (Test-Path $traySrc) {
    Copy-Item -Path $traySrc -Destination (Join-Path $InstallPath "tray_app.py") -Force
    Write-Ok "Installed tray_app.py"
}

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue

# Pin / verify version string
$commonPath = Join-Path $InstallPath "agent_server_common.py"
$common = Get-Content $commonPath -Raw
$common2 = [regex]::Replace($common, 'agent_version:\s*str\s*=\s*"[^"]+"', "agent_version: str = `"$AgentVersion`"")
Set-Content -Path $commonPath -Value $common2 -Encoding UTF8
if ($common2 -notmatch "agent_version:\s*str\s*=\s*`"$AgentVersion`"") {
    Write-Err "Failed to pin agent_version to $AgentVersion in agent_server_common.py"
}
Write-Ok "Pinned agent_version to $AgentVersion"

# ─── Dependencies ─────────────────────────────────────────────────────
Write-Step "Installing Python dependencies..."
try {
    & $pyExe -m pip install --disable-pip-version-check --quiet -r (Join-Path $InstallPath "requirements.txt") 2>&1 | Out-Null
} catch {}
foreach ($pkg in @(
    "winrt-runtime",
    "winrt-Windows.Media.Ocr",
    "winrt-Windows.Globalization",
    "winrt-Windows.Graphics.Imaging",
    "winrt-Windows.Storage.Streams"
)) {
    try { & $pyExe -m pip install --disable-pip-version-check --quiet $pkg 2>&1 | Out-Null } catch {}
}
Write-Ok "Dependencies OK"

# ─── Firewall ─────────────────────────────────────────────────────────
Write-Step "Ensuring firewall rule for port $Port..."
try {
    $ruleName = "NexGenX Agent Server"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
    }
    Write-Ok "Firewall OK"
} catch { Write-Warn "Firewall skipped: $_" }

# ─── Scheduled task ───────────────────────────────────────────────────
Write-Step "Registering scheduled task '$TaskName' (Interactive / AtLogOn)..."
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskAction = New-ScheduledTaskAction -Execute $pyExe -Argument "`"$InstallPath\agent_supervisor.py`"" -WorkingDirectory $InstallPath
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -ExecutionTimeLimit "00:00:00"

foreach ($tn in $OldTaskNames) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
        Write-Ok "Unregistered old task $tn"
    }
}
Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Description "NexGenX Windows Agent Server v$AgentVersion" | Out-Null
Write-Ok "Task registered"

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
if (-not $healthy) { Write-Err "Agent did not respond to /ping. Check Task Scheduler and $env:PROGRAMDATA\NexGenX\supervisor.log" }
Write-Ok "/ping OK"

$conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Ok "Listener PID=$($proc.Id) SessionId=$($proc.SessionId)"
        if ($proc.SessionId -eq 0) {
            # RMM / remote upgrades often start the task before an interactive user exists.
            # Files + task are installed; desktop skills need a real logon session.
            Write-Warn "Agent is in Session 0 (no interactive desktop yet). After a user logs on, run: Start-ScheduledTask -TaskName $TaskName"
            if (-not $Upgrade) {
                Write-Err "Agent is in Session 0. Use Start-ScheduledTask -TaskName $TaskName while a user is logged on."
            }
        }
    }
}

try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 10
    if ($health.v107 -ne $true) { Write-Err "/health missing v107=true" }
    if ($health.agent_version -and $health.agent_version -ne $AgentVersion) {
        Write-Err "/health agent_version=$($health.agent_version) expected $AgentVersion"
    }
    Write-Ok "/health v107=$($health.v107) agent_version=$($health.agent_version) ocr=$($health.ocr_available)"
} catch { Write-Err "/health failed: $_" }

$codeFile = "$env:PROGRAMDATA\NexGenX\agent_access.txt"
if (Test-Path $codeFile) {
    $code = (Get-Content $codeFile -Raw).Trim()
    $headers = @{ "X-Access-Code" = $code }
    try {
        $info = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/info" -Headers $headers -TimeoutSec 10
        if ($info.agent_version -ne $AgentVersion) { Write-Err "/info agent_version=$($info.agent_version) expected $AgentVersion" }
        Write-Ok "/info agent_version=$($info.agent_version)"
    } catch { Write-Warn "/info failed: $_" }
    try {
        $shot = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/screenshot" -Headers $headers -UseBasicParsing -TimeoutSec 15
        if ($shot.StatusCode -eq 200 -and $shot.RawContentLength -gt 100) {
            Write-Ok "/screenshot OK ($($shot.RawContentLength) bytes)"
        }
    } catch { Write-Warn "/screenshot failed (no interactive desktop yet?): $_" }
    # Verify skills API
    try {
        $skillsResp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/skills" -Headers $headers -UseBasicParsing -TimeoutSec 10
        if ($skillsResp.StatusCode -eq 200) {
            Write-Ok "/skills API OK"
        }
    } catch {
        Write-Warn "/skills not responding (may need agent restart): $_"
    }
} else {
    Write-Warn "Access code file missing at $codeFile"
}

Write-Host ""
Write-Host "  v$AgentVersion ready" -ForegroundColor Green
Write-Host "  Task:  $TaskName" -ForegroundColor Gray
Write-Host "  Files: $InstallPath" -ForegroundColor Gray
Write-Host "  Never start with Start-Process — use Start-ScheduledTask." -ForegroundColor Yellow
Write-Host ""

