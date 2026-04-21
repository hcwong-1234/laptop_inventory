<#
    collect_inventory_and_upload.ps1

    - Collects Windows laptop inventory
    - Opens SSH tunnel to 152.42.228.57 using PASSWORD (you type it)
    - Inserts into MySQL table dsg_it.asset_inv
    - Saves a local log in Inventory\COMPUTERNAME_inventory.txt
#>

param()

#############################
# CONFIGURATION
#############################

# SSH / tunnel settings
$SshHost       = "152.42.228.57"
$SshUser       = "root"
$LocalDbPort   = 3307                # local forwarded port
$RemoteDbHost  = "127.0.0.1"         # DB host as seen from the Linux server
$RemoteDbPort  = 3306                # MySQL default

# MySQL settings
$MysqlUser = "romel"
$MysqlPass = "ia5lnbvo8j"
$MysqlDb   = "dsg_it"

# Paths based on where this script lives (e.g. USB)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Local log file on same drive
$OutDir  = Join-Path $ScriptDir "Inventory"
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}
$OutFile = Join-Path $OutDir ("{0}_inventory.txt" -f $env:COMPUTERNAME)


#############################
# HELPER FUNCTIONS
#############################

function Require-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "[ERROR] '$Name' is not available in PATH." -ForegroundColor Red
        if ($InstallHint) {
            Write-Host $InstallHint -ForegroundColor Yellow
        }
        Write-Host "Please install it and re-run this script." -ForegroundColor Yellow
        exit 1
    }
}

function Escape-SqlLiteral {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        return ""
    }
    # Escape single quotes for SQL
    return $Value.Replace("'", "''")
}


#############################
# DEPENDENCY CHECKS
#############################

Write-Host "Checking dependencies..." -ForegroundColor Cyan

Require-Command -Name "ssh"   -InstallHint "Enable 'OpenSSH Client' in Windows Optional Features."
Require-Command -Name "mysql" -InstallHint "Install MySQL client and ensure mysql.exe is in PATH."

Write-Host "Dependencies OK." -ForegroundColor Green
Write-Host ""


#############################
# COLLECT INVENTORY DATA
#############################

Write-Host "Collecting inventory data..." -ForegroundColor Cyan

$now           = Get-Date
$inventoryDate = $now.ToString("yyyy-MM-dd HH:mm:ss")

$computerName  = $env:COMPUTERNAME
$loggedInUser  = $env:USERNAME

$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

$serialNumber  = $bios.SerialNumber
$manufacturer  = $cs.Manufacturer
$model         = $cs.Model
$osName        = $os.Caption
$osVersion     = $os.Version
$osArch        = $os.OSArchitecture
$cpuName       = $cpu.Name
$totalRamBytes = [Int64]$cs.TotalPhysicalMemory
$domain        = $cs.Domain

# Disks info (JSON)
$disksInfoObj = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID, Size, FreeSpace
$disksInfo = $disksInfoObj | ConvertTo-Json -Depth 3

# MAC addresses (JSON)
$macInfoObj = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE" |
    Select-Object Description, MACAddress
$macAddresses = $macInfoObj | ConvertTo-Json -Depth 3

# ipconfig and systeminfo raw text
$ipConfig      = (ipconfig /all | Out-String)
$systeminfoRaw = (systeminfo | Out-String)

Write-Host "Inventory collected." -ForegroundColor Green


#############################
# WRITE LOCAL LOG (ON USB)
#############################

"========================================" | Out-File -FilePath $OutFile -Encoding UTF8
"  COMPANY LAPTOP INVENTORY SNAPSHOT"     | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"========================================" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Date/Time      : $inventoryDate"         | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Computer Name  : $computerName"          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Logged-in User : $loggedInUser"          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Serial Number  : $serialNumber"          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Manufacturer   : $manufacturer"          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Model          : $model"                 | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"OS Name        : $osName"                | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"OS Version     : $osVersion"             | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"OS Arch        : $osArch"                | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"CPU Name       : $cpuName"               | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Total RAM      : $totalRamBytes bytes"   | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Domain/Workgrp : $domain"                | Out-File -FilePath $OutFile -Encoding UTF8 -Append
""                                          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[DISKS JSON]"                             | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$disksInfo                                 | Out-File -FilePath $OutFile -Encoding UTF8 -Append
""                                          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[MAC ADDRESSES JSON]"                     | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$macAddresses                              | Out-File -FilePath $OutFile -Encoding UTF8 -Append
""                                          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[IPCONFIG RAW]"                           | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$ipConfig                                  | Out-File -FilePath $OutFile -Encoding UTF8 -Append
""                                          | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[SYSTEMINFO RAW]"                         | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$systeminfoRaw                             | Out-File -FilePath $OutFile -Encoding UTF8 -Append

Write-Host "Local log written to: $OutFile" -ForegroundColor DarkGray
Write-Host ""


#############################
# PREPARE SQL INSERT
#############################

# Escape strings
$inventoryDateEsc = Escape-SqlLiteral $inventoryDate
$computerNameEsc  = Escape-SqlLiteral $computerName
$loggedInUserEsc  = Escape-SqlLiteral $loggedInUser
$serialNumberEsc  = Escape-SqlLiteral $serialNumber
$manufacturerEsc  = Escape-SqlLiteral $manufacturer
$modelEsc         = Escape-SqlLiteral $model
$osNameEsc        = Escape-SqlLiteral $osName
$osVersionEsc     = Escape-SqlLiteral $osVersion
$osArchEsc        = Escape-SqlLiteral $osArch
$cpuNameEsc       = Escape-SqlLiteral $cpuName
$domainEsc        = Escape-SqlLiteral $domain
$disksInfoEsc     = Escape-SqlLiteral $disksInfo
$macAddressesEsc  = Escape-SqlLiteral $macAddresses
$ipConfigEsc      = Escape-SqlLiteral $ipConfig
$systeminfoEsc    = Escape-SqlLiteral $systeminfoRaw

# total_ram_bytes numeric (can be NULL)
if ($totalRamBytes -gt 0) {
    $totalRamVal = $totalRamBytes
} else {
    $totalRamVal = "NULL"
}

$insertTemplate = @"
INSERT INTO asset_inv (
    inventory_datetime,
    computer_name,
    logged_in_user,
    serial_number,
    manufacturer,
    model,
    os_name,
    os_version,
    os_arch,
    cpu_name,
    total_ram_bytes,
    domain_or_workgroup,
    disks_info,
    mac_addresses,
    ip_config,
    systeminfo_raw
) VALUES (
    '{0}',
    '{1}',
    '{2}',
    '{3}',
    '{4}',
    '{5}',
    '{6}',
    '{7}',
    '{8}',
    '{9}',
    {10},
    '{11}',
    '{12}',
    '{13}',
    '{14}',
    '{15}'
);
"@

$insertSql = [string]::Format(
    $insertTemplate,
    $inventoryDateEsc,
    $computerNameEsc,
    $loggedInUserEsc,
    $serialNumberEsc,
    $manufacturerEsc,
    $modelEsc,
    $osNameEsc,
    $osVersionEsc,
    $osArchEsc,
    $cpuNameEsc,
    $totalRamVal,
    $domainEsc,
    $disksInfoEsc,
    $macAddressesEsc,
    $ipConfigEsc,
    $systeminfoEsc
)

# Write SQL to a temp .sql file in the script directory
$sqlFilePath = Join-Path $ScriptDir "inventory_insert.sql"
$insertSql | Out-File -FilePath $sqlFilePath -Encoding UTF8

Write-Host "SQL file written to: $sqlFilePath" -ForegroundColor DarkGray


#############################
# OPEN SSH TUNNEL (PASSWORD PROMPT IN NEW WINDOW)
#############################

Write-Host ""
Write-Host "A new PowerShell window will open with the SSH tunnel command." -ForegroundColor Cyan
Write-Host "In that window, type your SSH password for $SshUser@$SshHost and leave it OPEN." -ForegroundColor Yellow
Write-Host ""

# Build the ssh command string
$sshCommand = "ssh -N -L $LocalDbPort`:$RemoteDbHost`:$RemoteDbPort $SshUser@$SshHost"

# Open a new PowerShell window running the SSH tunnel
Start-Process -FilePath "powershell" -ArgumentList "-NoExit","-Command",$sshCommand -WindowStyle Normal

# Wait for user to authenticate
Read-Host "After you have successfully logged in and the SSH tunnel is running, press ENTER here to continue"

#############################
# EXECUTE MYSQL INSERT VIA TUNNEL
#############################

Write-Host "Executing MySQL insert via SSH tunnel on localhost:$LocalDbPort ..." -ForegroundColor Cyan

$mysqlArgs = @(
    "-u", $MysqlUser,
    "-p$MysqlPass",
    "-h", "127.0.0.1",
    "-P", $LocalDbPort,
    "-D", $MysqlDb
)

$mysqlProcess = Start-Process -FilePath "mysql" `
    -ArgumentList $mysqlArgs `
    -RedirectStandardInput $sqlFilePath `
    -NoNewWindow `
    -Wait `
    -PassThru

if ($mysqlProcess.ExitCode -eq 0) {
    Write-Host ""
    Write-Host "[OK] Inventory row inserted into $MysqlDb.asset_inv successfully." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[ERROR] MySQL client exited with code $($mysqlProcess.ExitCode)." -ForegroundColor Red
    Write-Host "Check SSH tunnel, MySQL credentials, and table structure." -ForegroundColor Yellow
}

# Clean up temp SQL file
if (Test-Path $sqlFilePath) {
    Remove-Item $sqlFilePath -Force
}

Write-Host ""
Write-Host "You can now close the separate SSH tunnel window manually." -ForegroundColor DarkGray
Write-Host "Done." -ForegroundColor Green
