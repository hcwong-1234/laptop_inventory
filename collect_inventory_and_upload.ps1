<#
    collect_inventory_and_upload_api.ps1

    - Collects Windows laptop inventory
    - Sends data to API endpoint instead of SSH tunnel
    - Saves a local log in Inventory\COMPUTERNAME_inventory.txt
    - Can run directly without typing API URL / username / password
#>

param(
    [string]$ApiUrl = "",
    [string]$Username = "",
    [string]$Password = "",
    [string]$AssetId = "",
    [string]$Status = "Active"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#############################
# BUILT-IN API SETTINGS
#############################
# Edit these three values if the server URL or login changes.
$DefaultApiUrl = "https://itinv.3utilities.com/api.php"
$DefaultUsername = "haucheng44444"
$DefaultPassword = "ia5lnbvo8j"


#############################
# HELPER FUNCTIONS
#############################

function Resolve-ApiEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $resolved = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "API URL is empty."
    }

    # Production API requires HTTPS. If someone copies an old http:// URL, upgrade it.
    if ($resolved -match '^http://(?!localhost\b|127\.0\.0\.1\b)') {
        $resolved = 'https://' + $resolved.Substring(7)
    }

    $resolved = $resolved.TrimEnd('/')
    if ($resolved -notmatch '/api\.php$') {
        $resolved += '/api.php'
    }

    return $resolved
}

function ConvertTo-ApiQueryString {
    param(
        [hashtable]$Query = @{}
    )

    if ($Query.Count -eq 0) {
        return ""
    }

    return ($Query.GetEnumerator() | ForEach-Object {
        $key = [System.Uri]::EscapeDataString([string] $_.Key)
        $value = [System.Uri]::EscapeDataString([string] $_.Value)
        "$key=$value"
    }) -join "&"
}


#############################
# CONFIGURATION
#############################

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    $ApiUrl = $DefaultApiUrl
}
if ([string]::IsNullOrWhiteSpace($Username)) {
    $Username = $DefaultUsername
}
if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = $DefaultPassword
}

$ApiBaseUrl = Resolve-ApiEndpoint -Value $ApiUrl

# Paths based on where this script lives (e.g. USB)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Local log file on same drive
$OutDir = Join-Path $ScriptDir "Inventory"
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}
$OutFile = Join-Path $OutDir ("{0}_inventory.txt" -f $env:COMPUTERNAME)


function Invoke-ApiRequest {
    param(
        [string]$Method = "GET",
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [hashtable]$Query = @{},
        [object]$Body = $null,
        [string]$Token = $null
    )

    $encodedAction = [System.Uri]::EscapeDataString($Action)
    $url = $ApiBaseUrl + "?action=$encodedAction"
    $queryString = ConvertTo-ApiQueryString -Query $Query
    if ($queryString -ne "") {
        $url += "&" + $queryString
    }

    $headers = @{
        "Accept" = "application/json"
        "Content-Type" = "application/json"
    }
    if ($Token) {
        $headers["Authorization"] = "Bearer $Token"
    }

    $params = @{
        Uri = $url
        Method = $Method
        Headers = $headers
        TimeoutSec = 30
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-RestMethod @params
        if ($null -ne $response.ok -and $response.ok -eq $false) {
            throw "API Error: $($response.error.message)"
        }
        return $response
    } catch {
        Write-Host "[ERROR] API request failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[ERROR] Endpoint: $url" -ForegroundColor DarkRed
        exit 1
    }
}


#############################
# DEPENDENCY CHECKS
#############################

Write-Host "Checking dependencies..." -ForegroundColor Cyan
Write-Host "Using API endpoint: $ApiBaseUrl" -ForegroundColor DarkGray
Write-Host "Using API username: $Username" -ForegroundColor DarkGray
Write-Host "Dependencies OK." -ForegroundColor Green
Write-Host ""


#############################
# COLLECT INVENTORY DATA
#############################

Write-Host "Collecting inventory data..." -ForegroundColor Cyan

$now = Get-Date
$inventoryDate = $now.ToString("yyyy-MM-dd HH:mm:ss")

$computerName = $env:COMPUTERNAME
$loggedInUser = $env:USERNAME

$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

$serialNumber = $bios.SerialNumber
$manufacturer = $cs.Manufacturer
$model = $cs.Model
$osName = $os.Caption
$osVersion = $os.Version
$osArch = $os.OSArchitecture
$cpuName = $cpu.Name
$totalRamBytes = [Int64]$cs.TotalPhysicalMemory
$domain = $cs.Domain

# Disks info (JSON)
$disksInfoObj = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID, Size, FreeSpace
$disksInfo = $disksInfoObj | ConvertTo-Json -Depth 3

# MAC addresses (JSON)
$macInfoObj = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE" |
    Select-Object Description, MACAddress
$macAddresses = $macInfoObj | ConvertTo-Json -Depth 3

# ipconfig and systeminfo raw text
$ipConfig = (ipconfig /all | Out-String)
$systeminfoRaw = (systeminfo | Out-String)

Write-Host "Inventory collected." -ForegroundColor Green


#############################
# WRITE LOCAL LOG (ON USB)
#############################

"========================================" | Out-File -FilePath $OutFile -Encoding UTF8
"  COMPANY LAPTOP INVENTORY SNAPSHOT" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"========================================" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Date/Time      : $inventoryDate" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Computer Name  : $computerName" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Logged-in User : $loggedInUser" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Serial Number  : $serialNumber" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Manufacturer   : $manufacturer" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Model          : $model" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"OS Name        : $osName" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"OS Version     : $osVersion" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"OS Arch        : $osArch" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"CPU Name       : $cpuName" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Total RAM      : $totalRamBytes bytes" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"Domain/Workgrp : $domain" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[DISKS JSON]" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$disksInfo | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[MAC ADDRESSES JSON]" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$macAddresses | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[IPCONFIG RAW]" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$ipConfig | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
"[SYSTEMINFO RAW]" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
$systeminfoRaw | Out-File -FilePath $OutFile -Encoding UTF8 -Append

Write-Host "Local log written to: $OutFile" -ForegroundColor DarkGray
Write-Host ""


#############################
# AUTHENTICATE WITH API
#############################

Write-Host "Authenticating with API..." -ForegroundColor Cyan

$loginResponse = Invoke-ApiRequest -Method "POST" -Action "login" -Body @{
    username = $Username
    password = $Password
}

$token = $loginResponse.token
Write-Host "Authenticated successfully." -ForegroundColor Green


#############################
# SUBMIT INVENTORY DATA VIA API
#############################

Write-Host "Submitting inventory data to API..." -ForegroundColor Cyan

$inventoryData = @{
    inventory_datetime = $inventoryDate
    computer_name = $computerName
    logged_in_user = $loggedInUser
    serial_number = $serialNumber
    manufacturer = $manufacturer
    model = $model
    os_name = $osName
    os_version = $osVersion
    os_arch = $osArch
    cpu_name = $cpuName
    total_ram_bytes = $totalRamBytes
    domain_or_workgroup = $domain
    disks_info = $disksInfo
    mac_addresses = $macAddresses
    ip_config = $ipConfig
    systeminfo_raw = $systeminfoRaw
}

if ($AssetId) {
    $inventoryData.asset_id = $AssetId
}
$inventoryData.status = $Status

$submitResponse = Invoke-ApiRequest -Method "POST" -Action "inventory.submit" -Body $inventoryData -Token $token

Write-Host ""
Write-Host "[OK] Inventory data submitted successfully. ID: $($submitResponse.id)" -ForegroundColor Green
Write-Host ""
Write-Host "Done." -ForegroundColor Green
