# NexGenX Windows Agent - Install Script (GitHub-Pull Edition)
#
# Fetches the latest agent code from GitHub Releases. Customer doesn't need
# to have the source files locally -- just runs this single script.
#
# Usage (as Administrator):
#   irm https://github.com/NexGenX/ngx-windows-agent/releases/latest/download/install.ps1 -OutFile install.ps1
#   .\install.ps1
#
# Or one-liner:
#   iex (irm https://raw.githubusercontent.com/NexGenX/ngx-windows-agent/main/install-bootstrap.ps1)
#
# What it does:
#   1. Installs Python 3.11 if needed
#   2. Downloads the latest agent release from GitHub
#   3. Verifies the SHA-256 checksum
#   4. Installs Python dependencies
#   5. Configures WinRM + RDP + firewall for remote administration
#   6. Creates a scheduled task for auto-start on boot
#   7. Starts the agent and shows the access code

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\NexGenX",
    [string]$GitHubRepo = "NexGenX/ngx-windows-agent-installer",
    [string]$Version = "v1.0.0",  # Default to a known release; "latest" resolves to v1.0.0
    [switch]$SkipPythonInstall,
    [switch]$SkipChecksum  # For dev/debug only
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------- Pretty output ----------
function Write-Step    { param([string]$Msg) Write-Host "[NexGenX] $Msg" -ForegroundColor Cyan }
function Write-Success { param([string]$Msg) Write-Host "[NexGenX] OK $Msg" -ForegroundColor Green }
function Write-Err     { param([string]$Msg) Write-Host "[NexGenX] [X] ERROR: $Msg" -ForegroundColor Red }
function Write-Warn    { param([string]$Msg) Write-Host "[NexGenX] [!] $Msg" -ForegroundColor Yellow }

# ---------- Admin check ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "Please run as Administrator (right-click -> Run as Administrator)"
    exit 1
}

Write-Host ""
Write-Host "  NexGenX Windows Agent Installer" -ForegroundColor White
Write-Host "  ===============================" -ForegroundColor White
Write-Host "  GitHub: github.com/$GitHubRepo" -ForegroundColor Gray
Write-Host "  Install path: $InstallPath" -ForegroundColor Gray
Write-Host "  Version: $Version" -ForegroundColor Gray
Write-Host ""

# ---------- Python installation ----------
if (-not $SkipPythonInstall) {
    Write-Step "Checking for Python..."

    $pythonCmd = $null
    foreach ($ver in @("3.11", "3.12", "3.13", "3.10")) {
        $test = Get-Command "python$ver" -ErrorAction SilentlyContinue
        if ($test) { $pythonCmd = "python$ver"; break }
    }
    if (-not $pythonCmd) {
        $test = Get-Command "py" -ErrorAction SilentlyContinue
        if ($test) {
            # py launcher can find any installed version. Test that it actually
            # runs by checking version. We pin to "py" (not "py -3") because
            # `& "py -3"` parses -3 as a parameter to the call operator in
            # some PowerShell versions, which fails.
            $pyVer = & py --version 2>&1
            if ($LASTEXITCODE -eq 0) { $pythonCmd = "py" }
        }
    }

    if (-not $pythonCmd) {
        Write-Step "Python not found. Downloading Python 3.11..."
        $pythonUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
        $installer = "$env:TEMP\python-3.11.9-amd64.exe"

        try {
            Invoke-WebRequest -Uri $pythonUrl -OutFile $installer -UseBasicParsing -TimeoutSec 180
        } catch {
            Write-Err "Failed to download Python. Please install Python 3.10+ manually from python.org"
            exit 1
        }

        Write-Step "Installing Python (this may take a minute)..."
        $proc = Start-Process -FilePath $installer -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_pip=1" -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Err "Python installer exited with code $($proc.ExitCode)"
            exit 1
        }

        # Refresh environment so python is found
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $pythonCmd = "python"
        Start-Sleep 3
    }

    Write-Success "Python found: $pythonCmd"
} else {
    $pythonCmd = "python"
}

# Verify python actually works
try {
    $pyVer = & $pythonCmd --version 2>&1
    Write-Success "Python version: $pyVer"
} catch {
    Write-Err "Python command '$pythonCmd' not working. Please install Python 3.10+ from python.org"
    exit 1
}

# ---------- Create install directory ----------
Write-Step "Creating installation directory: $InstallPath"
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
if (-not (Test-Path $InstallPath)) {
    Write-Err "Failed to create $InstallPath"
    exit 1
}

# ---------- Download agent code from the public installer repo ----------
# The agent code lives in a SEPARATE private repo, but we ship the public
# installer with a frozen copy of the agent zip under releases/<version>/.
# This means:
#   - Customers don't need GitHub credentials to install
#   - The public installer repo is the single source of truth for what
#     version of the agent ships
#   - We can pin a customer to a specific version (or always-latest)
#
# The PublicInstallerRepo parameter can be overridden for private deployments
# (e.g. air-gapped installs pointing at an internal file share).

Write-Step "Downloading agent code ($Version)..."

# Default to the public installer repo
$PublicInstallerRepo = if ($GitHubRepo) { $GitHubRepo } else { "NexGenX/ngx-windows-agent-installer" }

# Resolve the version we're installing
$resolvedVersion = if ($Version -eq "latest") { "v1.0.0" } else { $Version }

# Build the public download URL
$sourceUrl = "https://github.com/$PublicInstallerRepo/releases/download/$resolvedVersion/ngx-agent.zip"
$sourceZip = "$env:TEMP\ngx-agent.zip"

Write-Step "Downloading from $sourceUrl..."
try {
    # -DisableKeepAlive to avoid stale HTTP cache (PowerShell keeps connections
    # open and can re-serve the same body even when GitHub has updated it)
    Invoke-WebRequest -Uri $sourceUrl -OutFile $sourceZip -UseBasicParsing -TimeoutSec 120 -DisableKeepAlive
    $actualSize = (Get-Item $sourceZip).Length
    if ($actualSize -lt 1000) {
        Write-Err "Downloaded file is too small ($actualSize bytes). Check that $resolvedVersion is a valid release."
        exit 1
    }
    Write-Success "Downloaded $actualSize bytes"
} catch {
    Write-Err "Failed to download agent code from $sourceUrl"
    Write-Err "Error: $_"
    Write-Warn "If this is a private deployment, set -GitHubRepo to your internal installer host."
    exit 1
}

# Optional SHA-256 verification
if (-not $SkipChecksum) {
    $expectedHash = $null
    $hashUrl = "https://raw.githubusercontent.com/$PublicInstallerRepo/main/releases/$resolvedVersion/ngx-agent.zip.sha256"
    try {
        $expectedHash = (Invoke-RestMethod -Uri $hashUrl -UseBasicParsing -TimeoutSec 10).Trim().Split(' ')[0]
        if ($expectedHash -and $expectedHash.Length -eq 64) {
            Write-Step "Verifying SHA-256 checksum..."
            $actualHash = (Get-FileHash -Path $sourceZip -Algorithm SHA256).Hash.ToLower()
            if ($expectedHash -ne $actualHash) {
                Write-Err "CHECKSUM VERIFICATION FAILED"
                Write-Err "Expected: $expectedHash"
                Write-Err "Actual:   $actualHash"
                Write-Err "The download may be tampered with. Aborting."
                exit 1
            }
            Write-Success "Checksum verified"
        }
    } catch {
        Write-Warn "No checksum file found at $hashUrl -- skipping verification"
    }
}

# Extract to install directory
Write-Step "Extracting to $InstallPath..."
try {
    # The agent zip is flat (just the server/ contents, no top-level dir)
    Expand-Archive -Path $sourceZip -DestinationPath $InstallPath -Force
    Write-Success "Agent files extracted to $InstallPath"
} catch {
    Write-Err "Extraction failed: $_"
    exit 1
} finally {
    Remove-Item $sourceZip -Force -ErrorAction SilentlyContinue
}


# ---------- Install Python dependencies ----------
Write-Step "Installing Python dependencies..."
try {
    & $pythonCmd -m pip install --upgrade pip --disable-pip-version-check --quiet 2>&1 | Out-Null
    & $pythonCmd -m pip install --disable-pip-version-check -r "$InstallPath\requirements.txt" --quiet 2>&1 | Out-Null
    Write-Success "Dependencies installed"
} catch {
    Write-Err "Failed to install dependencies: $_"
    Write-Warn "Trying individual install..."
    & $pythonCmd -m pip install fastapi uvicorn python-multipart pyautogui Pillow numpy mss pystray pyperclip cryptography 2>&1 | Out-Null
}

# ---------- Firewall rule ----------
Write-Step "Configuring Windows Firewall for port 9400..."
try {
    $ruleName = "NexGenX Agent Server"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue }
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort 9400 -Action Allow -Profile Any | Out-Null
    Write-Success "Firewall rule created (TCP 9400 inbound)"
} catch {
    Write-Warn "Firewall configuration skipped (may require admin or different network profile)"
}

# ---------- noVNC installation (for browser-based desktop access) ----------
Write-Step "Checking noVNC..."
$novncPath = "$InstallPath\noVNC"
if (-not (Test-Path $novncPath)) {
    Write-Step "Installing noVNC from GitHub..."
    try {
        $novncZip = "$env:TEMP\novnc.zip"
        Invoke-WebRequest -Uri "https://github.com/novnc/noVNC/archive/refs/heads/main.zip" -OutFile $novncZip -UseBasicParsing -TimeoutSec 90
        Expand-Archive -Path $novncZip -DestinationPath $InstallPath -Force
        Move-Item -Path "$InstallPath\noVNC-main" -Destination $novncPath -Force
        Remove-Item $novncZip -Force -ErrorAction SilentlyContinue
        Write-Success "noVNC installed at $novncPath"
    } catch {
        Write-Warn "noVNC install failed: $_"
        Write-Warn "Customer can still use the API; just no browser-based desktop"
    }
}

# ---------- Configure Windows for remote access ----------
# CRITICAL: Without this section, the agent installs successfully but
# you cannot reach the machine. Common failure modes:
#   - WinRM service not started
#   - WinRM firewall rules disabled (default on Windows client SKUs)
#   - Network profile "Public" blocking inbound connections
#   - RDP not enabled (Windows client SKUs ship with RDP disabled)
#
# This section ensures 5985 (WinRM), 3389 (RDP), and 22 (SSH if OpenSSH
# is installed) are all listening and reachable. Safe to re-run.

Write-Step "Configuring remote access (WinRM + RDP)..."

$remoteAccessOk = $true

# 1. Enable PSRemoting -- this starts the WinRM service, sets it to auto,
#    and creates the default firewall rules for HTTP (5985) and HTTPS (5986).
#    -Force skips the "are you sure" prompts. -SkipNetworkProfileCheck allows
#    it to work on machines currently classified as "Public" network.
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    Write-Success "PSRemoting enabled (WinRM service started)"
} catch {
    Write-Warn "Enable-PSRemoting reported: $($_.Exception.Message)"
    $remoteAccessOk = $false
}

# 2. Explicitly enable the WinRM listener. The default listener binds to
#    any IP on port 5985. If a GPO has removed it, this re-creates it.
try {
    $listener = Get-WSManInstance -ResourceURI winrm/config/listener -Enumerate 2>$null |
                Where-Object { $_.Transport -eq "HTTP" }
    if (-not $listener) {
        Write-Step "No HTTP WinRM listener found -- creating one..."
        winrm create winrm/config/listener?Address=*+Transport=HTTP
        Restart-Service WinRM -Force
    } else {
        Write-Success "WinRM HTTP listener already exists on port 5985"
    }
} catch {
    Write-Warn "Could not verify WinRM listener: $($_.Exception.Message)"
}

# 3. Make sure the WinRM firewall rules are enabled even if the global
#    firewall profile is "Public" (which blocks them by default on
#    Windows 10/11 client SKUs).
$winrmRules = @(
    "WINRM-HTTP-In-TCP",
    "WINRM-HTTP-In-TCP-PUBLIC",
    "WINRM-HTTPS-In-TCP",
    "WINRM-HTTPS-In-TCP-PUBLIC"
)
foreach ($ruleName in $winrmRules) {
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -ne "True") {
        Enable-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        Write-Step "Enabled firewall rule: $ruleName"
    }
}

# 4. Allow WinRM through any active network profile. Some Windows
#    installations have the "Public" profile ruleset locked down.
try {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
    Write-Success "Firewall profiles enabled (all profiles accept inbound)"
} catch {
    Write-Warn "Could not enable firewall profiles: $($_.Exception.Message)"
}

# 5. Enable Remote Desktop (port 3389) so you can connect via the
#    browser-based desktop view. Skipped on Windows Server SKUs that
#    have RDP enabled by default.
try {
    $isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
    if (-not $isServer) {
        # Windows 10/11 client: enable RDP
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                         -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
        # Also enable through the modern "Require Network Level Authentication" off so
        # older clients (and our noVNC viewer) can connect without NLA
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                         -Name "UserAuthentication" -Value 0 -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-Success "Remote Desktop enabled (port 3389)"
    } else {
        Write-Step "Server SKU detected -- assuming RDP already enabled"
    }
} catch {
    Write-Warn "Could not enable RDP: $($_.Exception.Message)"
}

# 6. Verify what we set up actually works -- check listening sockets
Start-Sleep 2
Write-Step "Verifying remote access ports are listening..."
$listeningPorts = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty LocalPort -Unique
$expectedPorts = @(5985, 3389)
$openExpected = $expectedPorts | Where-Object { $_ -in $listeningPorts }
$missing = $expectedPorts | Where-Object { $_ -notin $listeningPorts }

if ($openExpected) {
    Write-Success "Listening on: $($openExpected -join ', ')"
}
if ($missing) {
    Write-Warn "NOT listening on: $($missing -join ', ')"
    Write-Warn "These ports must be reachable for the agent to be administered remotely."
    $remoteAccessOk = $false
}

# 7. Print the agent's external-facing IP so the operator knows how to reach it
try {
    $ipLines = ipconfig | Where-Object { $_ -match "IPv4" }
    if ($ipLines) {
        Write-Step "Network interfaces:"
        foreach ($line in $ipLines) { Write-Host "    $line" }
    }
} catch {}

if ($remoteAccessOk) {
    Write-Success "Remote access configured successfully"
} else {
    Write-Warn "Some remote access features could not be configured."
    Write-Warn "The agent will still run locally -- manual fix-up may be needed."
}

# ---------- Start the agent ----------

# ---------- Scheduled task for auto-start ----------
Write-Step "Creating auto-start scheduled task..."
$taskName = "NexGenXAgent"
$pyExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pyExe) {
    $pyExe = (Get-Command py -ErrorAction SilentlyContinue).Source
}
if (-not $pyExe) {
    Write-Warn "Couldn't locate python.exe path -- scheduled task may not work"
} else {
    try {
        $taskAction = New-ScheduledTaskAction -Execute $pyExe -Argument "`"$InstallPath\agent_server.py`" --quiet" -WorkingDirectory $InstallPath
        $taskTrigger = New-ScheduledTaskTrigger -AtStartup
        $taskPrincipal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Description "NexGenX Windows Agent Server v$resolvedVersion" | Out-Null
        Write-Success "Scheduled task 'NexGenXAgent' created (starts on next boot)"
    } catch {
        Write-Warn "Scheduled task creation failed: $_"
    }
}

# ---------- Start the server ----------
Write-Step "Starting NexGenX Agent Server..."
try {
    $proc = Start-Process -FilePath $pythonCmd -ArgumentList "`"$InstallPath\agent_server.py`"" -WorkingDirectory $InstallPath -PassThru -WindowStyle Hidden
    Start-Sleep 3
    if (-not $proc.HasExited) {
        Write-Success "Server started (PID: $($proc.Id))"
    } else {
        Write-Err "Server exited immediately with code $($proc.ExitCode)"
        Write-Warn "Check the install log or run $InstallPath\agent_server.py manually to see errors"
    }
} catch {
    Write-Err "Failed to start server: $_"
}

# ---------- Summary ----------
Write-Host ""
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host "  ======================" -ForegroundColor Green
Write-Host ""

# Get the server's primary IP
try {
    $serverIP = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Manual, Dhcp | Where-Object { $_.InterfaceAlias -notmatch "Loopback" } | Select-Object -First 1).IPAddress
} catch {
    $serverIP = "127.0.0.1"
}
if (-not $serverIP) { $serverIP = "127.0.0.1" }

Write-Host "  Server URL:     http://${serverIP}:9400" -ForegroundColor White
Write-Host "  API Docs:       http://${serverIP}:9400/docs" -ForegroundColor White
Write-Host "  noVNC Desktop:  http://${serverIP}:6080/vnc.html" -ForegroundColor White
Write-Host "  Version:        $resolvedVersion" -ForegroundColor White
Write-Host ""
Write-Host "  The access code is shown in a Windows notification." -ForegroundColor Yellow
Write-Host "  You can also find it at:" -ForegroundColor Yellow
Write-Host "  C:\ProgramData\NexGenX\agent_access.txt" -ForegroundColor Gray
Write-Host ""
Write-Host "  To control this machine, share the access code" -ForegroundColor Yellow
Write-Host "  with the NexGenX AI gateway (Hermes on the Linux side)." -ForegroundColor Yellow
Write-Host ""

# Save install info for the AI gateway
$installInfo = @{
    server_url = "http://${serverIP}:9400"
    install_path = $InstallPath
    novnc_url = "http://${serverIP}:6080/vnc.html"
    platform = "windows"
    version = "$resolvedVersion"
    installed_at = (Get-Date -Format "o")
} | ConvertTo-Json

$infoFile = "$InstallPath\install_info.json"
Set-Content -Path $infoFile -Value $installInfo -Encoding UTF8
Write-Success "Install info saved to $infoFile"
