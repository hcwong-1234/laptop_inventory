<#
.SYNOPSIS
  Installs MySQL (client) and OpenSSH client on Windows,
  and ensures mysql.exe is in PATH for this session and system-wide.

  Run this script in an elevated (Administrator) PowerShell.
#>

#region Helper functions
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO]  $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "[ OK ]  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN]  $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERR ]  $Message" -ForegroundColor Red
}
#endregion

#region Check for Administrator
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
    exit 1
}
#endregion

#region Ensure winget exists
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Err "winget is not available. Please install App Installer from Microsoft Store and try again."
    exit 1
}
#endregion

#region Ensure MySQL client is installed and in PATH
Write-Info "Checking for mysql.exe in PATH..."
$mysqlCmd = Get-Command mysql.exe -ErrorAction SilentlyContinue

if ($mysqlCmd) {
    Write-OK "MySQL client already available: $($mysqlCmd.Source)"
} else {
    Write-Info "mysql.exe not found in PATH. Checking common install locations under 'C:\Program Files\MySQL'..."

    $mysqlExe = Get-ChildItem "C:\Program Files\MySQL" -Recurse -Filter "mysql.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "Server" } |
                Select-Object -First 1

    if (-not $mysqlExe) {
        Write-Info "MySQL Server (with client) not found. Installing via winget (Oracle.MySQL)..."
        winget install -e --id Oracle.MySQL --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Err "winget failed to install Oracle.MySQL (exit code: $LASTEXITCODE)."
            exit 1
        }

        # Try locating mysql.exe again after install
        $mysqlExe = Get-ChildItem "C:\Program Files\MySQL" -Recurse -Filter "mysql.exe" -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match "Server" } |
                    Select-Object -First 1
    }

    if (-not $mysqlExe) {
        Write-Err "mysql.exe still not found after installation. Please check your MySQL installation."
        exit 1
    }

    $mysqlBin = Split-Path $mysqlExe.FullName
    Write-OK "Found MySQL client at: $mysqlBin"

    # Update MACHINE PATH safely (no setx, so no 1024-char truncation)
    Write-Info "Adding MySQL bin to system PATH (Machine scope) if needed..."
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")

    if ($machinePath -notlike "*$mysqlBin*") {
        $newMachinePath = $machinePath.TrimEnd(";") + ";" + $mysqlBin
        [Environment]::SetEnvironmentVariable("Path", $newMachinePath, "Machine")
        Write-OK "MySQL bin added to system PATH."
    } else {
        Write-Info "MySQL bin already present in system PATH."
    }

    # Also update PATH for THIS PowerShell session
    if ($env:Path -notlike "*$mysqlBin*") {
        $env:Path = $env:Path.TrimEnd(";") + ";" + $mysqlBin
        Write-OK "MySQL bin added to current session PATH."
    } else {
        Write-Info "MySQL bin already present in current session PATH."
    }
}

# Verify mysql
try {
    $mysqlVersion = & mysql --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $mysqlVersion) {
        Write-OK "MySQL client is working: $mysqlVersion"
    } else {
        Write-Warn "mysql command did not return a version string. Please test manually: 'mysql --version'."
    }
} catch {
    Write-Err "Failed to run 'mysql --version'. Error: $($_.Exception.Message)"
    exit 1
}
#endregion

#region Ensure OpenSSH Client is installed
Write-Info "Checking OpenSSH client (ssh.exe)..."
$sshCmd = Get-Command ssh.exe -ErrorAction SilentlyContinue

if ($sshCmd) {
    $sshVer = (& ssh -V) 2>&1
    Write-OK "OpenSSH client already installed: $sshVer"
} else {
    Write-Info "OpenSSH client not found in PATH. Checking Windows capabilities..."

    $sshCap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Client*"

    if (-not $sshCap) {
        Write-Err "OpenSSH.Client capability not found. This is unusual for modern Windows 10/11."
        exit 1
    }

    if ($sshCap.State -ne "Installed") {
        Write-Info "Installing OpenSSH.Client capability..."
        Add-WindowsCapability -Online -Name $sshCap.Name
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to install OpenSSH.Client capability (exit code: $LASTEXITCODE)."
            exit 1
        }
        Write-OK "OpenSSH client installed."

        # Recheck ssh
        $sshCmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
        if ($sshCmd) {
            $sshVer = (& ssh -V) 2>&1
            Write-OK "OpenSSH client is now available: $sshVer"
        } else {
            Write-Warn "OpenSSH client installed but ssh.exe not seen in PATH yet. You may need to open a new PowerShell window."
        }
    } else {
        Write-OK "OpenSSH.Client capability is installed but ssh.exe is not found in PATH."
        Write-Warn "Try opening a new PowerShell window, or confirm 'C:\Windows\System32\OpenSSH' is in PATH."
    }
}
#endregion

Write-Host ""
Write-OK "All dependencies (MySQL client & OpenSSH client) appear to be installed."
Write-Info "You can now run your script, e.g.:"
Write-Host "  .\collect_inventory_and_upload.ps1" -ForegroundColor White
