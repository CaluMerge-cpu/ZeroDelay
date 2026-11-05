# ZeroDelay uninstaller: removes the app, its shortcuts and its Settings > Apps entry.
# Settings ZeroDelay changed stay as they are, so the user is asked to press "Restore all" first.
Add-Type -AssemblyName PresentationFramework
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ZeroDelay runs as administrator; only an elevated uninstaller can see and close it, and the files in
# Program Files can only be removed with administrator rights.
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" } catch {}
    exit
}

$r = [Windows.MessageBox]::Show("Before uninstalling, open ZeroDelay and press 'Restore all' if you want your PC's original settings back. Uninstalling does not undo changes by itself.`n`nUninstall ZeroDelay now?", 'Uninstall ZeroDelay', 'YesNo', 'Question')
if ($r -ne 'Yes') { exit }

# deletes a folder without following junctions or symbolic links inside it (.NET removes the link, not its target)
function Remove-FolderSafely([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) { return }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Path); return }
    try { [IO.Directory]::Delete($Path, $true) } catch {}
}

# close a running ZeroDelay first (also one hidden in the tray). Plain substring match: '[' in a path is no wildcard.
$script = Join-Path $dir 'ZeroDelay.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { "$($_.CommandLine)".IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$deadline = (Get-Date).AddSeconds(10)
do {
    $m = $null; $open = [Threading.Mutex]::TryOpenExisting('Local\ZeroDelayApp', [ref]$m)
    if ($open) { $m.Dispose(); Start-Sleep -Milliseconds 300 }
} while ($open -and (Get-Date) -lt $deadline)

# "Start with Windows" task
Unregister-ScheduledTask -TaskName 'ZeroDelay' -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue

foreach ($f in 'CommonDesktopDirectory', 'CommonPrograms', 'Desktop', 'Programs') {
    Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath($f)) 'ZeroDelay.lnk') -Force -ErrorAction SilentlyContinue
}
foreach ($k in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZeroDelay', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZeroDelay') {
    Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue
}

$keep = [Windows.MessageBox]::Show("Also delete ZeroDelay's backups and history? Keep them if you might reinstall and still want to restore settings.", 'Uninstall ZeroDelay', 'YesNo', 'Question')
if ($keep -eq 'Yes') {
    Remove-FolderSafely (Join-Path $env:LOCALAPPDATA 'FortniteLatencyOptimizer')
    # this account's protected backup (see Get-SecureDataDir in ZeroDelay.ps1)
    $secure = Join-Path $env:ProgramData 'ZeroDelay'
    foreach ($f in "backup-$($id.User.Value).json", "backup-$($id.User.Value).json.bak") { Remove-Item -LiteralPath (Join-Path $secure $f) -Force -ErrorAction SilentlyContinue }
    Remove-FolderSafely (Join-Path $secure 'Update')
    if (-not (Get-ChildItem -LiteralPath $secure -Force -ErrorAction SilentlyContinue)) { try { [IO.Directory]::Delete($secure) } catch {} }
}

# the folder holding this script is removed after it exits
Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rd /s /q `"$dir`"" -WindowStyle Hidden
[Windows.MessageBox]::Show('ZeroDelay has been removed.', 'Uninstall ZeroDelay', 'OK', 'Information') | Out-Null
