# ZeroDelay uninstaller: removes the app, its shortcuts and its Settings > Apps entry.
# Settings ZeroDelay changed stay as they are, so the user is asked to press "Restore all" first.
Add-Type -AssemblyName PresentationFramework
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$r = [Windows.MessageBox]::Show("Before uninstalling, open ZeroDelay and press 'Restore all' if you want your PC's original settings back. Uninstalling does not undo changes by itself.`n`nUninstall ZeroDelay now?", 'Uninstall ZeroDelay', 'YesNo', 'Question')
if ($r -ne 'Yes') { exit }

# close a running ZeroDelay first
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$dir\ZeroDelay.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# "Start with Windows" task (it runs with admin rights, so removing it may ask for permission)
if (Get-ScheduledTask -TaskName 'ZeroDelay' -TaskPath '\' -ErrorAction SilentlyContinue) {
    try { Unregister-ScheduledTask -TaskName 'ZeroDelay' -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    catch { try { Start-Process schtasks.exe -ArgumentList '/Delete /TN ZeroDelay /F' -Verb RunAs -WindowStyle Hidden -Wait } catch {} }
}

foreach ($l in (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZeroDelay.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'ZeroDelay.lnk')) {
    Remove-Item $l -Force -ErrorAction SilentlyContinue
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZeroDelay' -Recurse -Force -ErrorAction SilentlyContinue

$keep = [Windows.MessageBox]::Show("Also delete ZeroDelay's backups and history? Keep them if you might reinstall and still want to restore settings.", 'Uninstall ZeroDelay', 'YesNo', 'Question')
if ($keep -eq 'Yes') { Remove-Item (Join-Path $env:LOCALAPPDATA 'FortniteLatencyOptimizer') -Recurse -Force -ErrorAction SilentlyContinue }

# the folder holding this script is removed after it exits
Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rd /s /q `"$dir`"" -WindowStyle Hidden
[Windows.MessageBox]::Show('ZeroDelay has been removed.', 'Uninstall ZeroDelay', 'OK', 'Information') | Out-Null
