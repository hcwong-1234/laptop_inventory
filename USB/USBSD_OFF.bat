@echo off
setlocal
set SCRIPT=%~dp0USBSD_OFF.ps1

:: Prefer PowerShell version with ExecutionPolicy bypass; fall back to direct reg edits if it fails.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Quiet 2>nul
if %ERRORLEVEL%==0 goto done

echo PowerShell run failed or blocked; falling back to registry edits...
reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\USBSTOR" /v Start /t REG_DWORD /d 4 /f
reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\sdbus" /v Start /t REG_DWORD /d 4 /f

:done
echo USB storage devices and SD card reader have been disabled.
endlocal
