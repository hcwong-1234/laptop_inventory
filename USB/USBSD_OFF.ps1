# USB and SD Card disable script
# Disables USB mass storage (USBSTOR) and SD card bus (sdbus) by setting Start=4.
# Run from elevated PowerShell:  Run as Administrator.

param(
    [switch]$Quiet
)

$executionPolicyScope = 'Process'
$originalPolicy = Get-ExecutionPolicy -Scope $executionPolicyScope
$policyChanged = $false
$scriptSucceeded = $false

if ($originalPolicy -eq 'Undefined') {
    try {
        Set-ExecutionPolicy -Scope $executionPolicyScope -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        $policyChanged = $true
    }
    catch {
        Write-Error "Failed to set execution policy to RemoteSigned: $_"
        exit 1
    }
}

function Assert-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator privileges are required to modify HKLM services. Right-click PowerShell and select 'Run as administrator'."
    }
}

function Set-ServiceStartValue {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        [Parameter(Mandatory)]
        [int]$StartValue
    )

    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    Set-ItemProperty -Path $path -Name Start -Value $StartValue -Type DWord -Force -ErrorAction Stop
}

try {
    Assert-Admin
    Set-ServiceStartValue -ServiceName 'USBSTOR' -StartValue 4
    Set-ServiceStartValue -ServiceName 'sdbus'   -StartValue 4

    if (-not $Quiet) {
        Write-Host "USB storage devices and SD card reader have been disabled. A reboot may be required for changes to take effect." -ForegroundColor Green
    }

    $scriptSucceeded = $true
}
catch {
    Write-Error $_
}
finally {
    if ($policyChanged) {
        try {
            Set-ExecutionPolicy -Scope $executionPolicyScope -ExecutionPolicy $originalPolicy -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not revert execution policy to ${originalPolicy}: $_"
        }
    }

    if (-not $scriptSucceeded) {3
        exit 1
    }
}
