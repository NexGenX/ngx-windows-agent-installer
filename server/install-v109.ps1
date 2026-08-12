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

if (-not $GitHubToken) { $GitHubToken = $env:NEXGENX_GITHUB_TOKEN }
if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }

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
    Write-Err "No python.exe found. Install Python 3.11+ first."
}
$pyExe = Get-PythonExe
Write-Ok "Using Python: $pyExe"

# ─── Stop old tasks ───────────────────────────────────────────────────
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
            Write-Err "Agent is in Session 0. Use Start-ScheduledTask -TaskName $TaskName while a user is logged on."
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
} else {
    Write-Warn "Access code file missing at $codeFile"
}

Write-Host ""
Write-Host "  v$AgentVersion ready" -ForegroundColor Green
Write-Host "  Task:  $TaskName" -ForegroundColor Gray
Write-Host "  Files: $InstallPath" -ForegroundColor Gray
Write-Host "  Never start with Start-Process — use Start-ScheduledTask." -ForegroundColor Yellow
Write-Host ""
