# USB/SD Toggle Scripts

Scripts to enable or disable USB mass storage (`USBSTOR`) and SD card bus (`sdbus`) service start values.

## Files
- `USBSD_OFF.bat`: Disable USB/SD using `reg add`.
- `USBSD_ON.bat`: Enable USB/SD using `reg add`.
- `USBSD_OFF.ps1`: Disable USB/SD with PowerShell.
- `USBSD_ON.ps1`: Enable USB/SD with PowerShell.

## Requirements
- Run **as Administrator** (needed to write under `HKLM`).
- A reboot may be required for changes to take effect.

## BAT Usage (fastest)
1) Right-click `USBSD_OFF.bat` or `USBSD_ON.bat` and choose **Run as administrator**.  
2) The BAT tries to run the PowerShell script with `-ExecutionPolicy Bypass`; if PowerShell is blocked, it falls back to direct `reg add` commands.  
3) Confirm the UAC prompt; the script updates `USBSTOR` and `sdbus` start values (4 = disabled, 3 = enabled).

## PowerShell Usage
1) Open PowerShell **as Administrator** in this folder.  
2) If the process execution policy is `Undefined`, the script will temporarily set it to `RemoteSigned` and revert to `Undefined` after it finishes. Otherwise, it leaves your policy untouched.  
3) If the machine policy is `Restricted`, launch with bypass:  
   - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\USBSD_OFF.ps1`  
   - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\USBSD_ON.ps1`  
4) Run one of:
   - Disable: `.\USBSD_OFF.ps1`
   - Enable:  `.\USBSD_ON.ps1`
5) Optional quiet mode (no success message): add `-Quiet`.

## Notes
- The PowerShell scripts use `Set-ItemProperty` with `-ErrorAction Stop` for quicker failure reporting and omit pauses for faster automation.
- Services use `Start` values: `4 = Disabled`, `3 = Manual`. No network access is required.
