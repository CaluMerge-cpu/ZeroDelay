# ZeroDelay installer. Copies the app to %ProgramFiles%\ZeroDelay, adds Desktop and Start menu shortcuts, and
# registers an uninstaller under Settings > Apps.
# ZeroDelay runs as administrator, so its files live where only administrators can change them: a normal program
# that could edit ZeroDelay.ps1 would otherwise get administrator rights the next time ZeroDelay starts.
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'ZeroDelay'),
    [switch]$NoShortcuts,   # testing: copy files only
    [switch]$NoLaunch,
    [switch]$Update         # started by ZeroDelay's Update now button: no questions, reopen ZeroDelay afterwards
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName PresentationFramework

$AppFiles = 'ZeroDelay.ps1', 'ZeroDelay.exe', 'ZeroDelay.ico', 'uninstall.ps1', 'LICENSE.txt', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll'
# where versions before 1.20 installed (per user, writable by any program the user runs)
$LegacyDir = Join-Path $env:LOCALAPPDATA 'Programs\ZeroDelay'

# running ZeroDelay windows (powershell.exe running a ZeroDelay.ps1); needs admin rights to see elevated processes
function Get-ZeroDelayProcess {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { "$($_.CommandLine)".IndexOf('\ZeroDelay.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                       "$($_.CommandLine)".IndexOf('\FortniteOptimizer.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}
function Test-AppMutex { $m = $null; if ([Threading.Mutex]::TryOpenExisting('Local\ZeroDelayApp', [ref]$m)) { $m.Dispose(); $true } else { $false } }

# removes the old per-user copy file by file; never follows a junction or symbolic link
function Remove-LegacyInstall {
    $item = Get-Item -LiteralPath $LegacyDir -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) { return }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($LegacyDir); return }   # removes the link only
    foreach ($f in $AppFiles + 'FortniteOptimizer.ps1', 'Run Optimizer.bat') {
        $p = Join-Path $LegacyDir $f
        $fi = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if ($fi -and -not $fi.PSIsContainer) { try { [IO.File]::Delete($p) } catch {} }
    }
    try { [IO.Directory]::Delete($LegacyDir) } catch {}   # only when it is empty now
    Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZeroDelay' -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Setup needs administrator rights to install to Program Files. Run ZeroDelay-Setup.exe again and choose Yes when Windows asks.'
    }

    if ($Update) {
        # wait (up to 30 s) for the running ZeroDelay to close; it holds this mutex while open
        $deadline = (Get-Date).AddSeconds(30)
        while ((Test-AppMutex) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    }
    # Still open (it did not close in time, or this is a normal setup run while ZeroDelay is open):
    # close it, because its files cannot be replaced while it runs.
    $running = Get-ZeroDelayProcess
    if ($running.Count -or (Test-AppMutex)) {
        if (-not $Update) {
            $r = [Windows.MessageBox]::Show("ZeroDelay is open. Setup will close it to update its files.`n`nContinue?", 'ZeroDelay setup', 'YesNo', 'Question')
            if ($r -ne 'Yes') { exit 1 }
        }
        foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        $deadline = (Get-Date).AddSeconds(10)
        while (((Get-ZeroDelayProcess).Count -or (Test-AppMutex)) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        if ((Get-ZeroDelayProcess).Count -or (Test-AppMutex)) {
            throw 'ZeroDelay is still running and its files are in use. Exit ZeroDelay from its tray icon (right-click > Exit), then run the setup again.'
        }
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    foreach ($f in $AppFiles) {
        if (Test-Path -LiteralPath (Join-Path $src $f)) { Copy-Item -LiteralPath (Join-Path $src $f) (Join-Path $InstallDir $f) -Force }
    }
    # files from early versions that ran the app as FortniteOptimizer.ps1
    foreach ($old in 'FortniteOptimizer.ps1', 'Run Optimizer.bat') { Remove-Item -LiteralPath (Join-Path $InstallDir $old) -Force -ErrorAction SilentlyContinue }
    $app = Join-Path $InstallDir 'ZeroDelay.ps1'
    # -List stops at the first match, wherever $AppVersion sits in the file
    $vm = Select-String -LiteralPath $app -Pattern "^\`$AppVersion = '([\d.]+)'" -List
    $version = if ($vm) { $vm.Matches[0].Groups[1].Value } else { '1.0.0' }
    $ico = Join-Path $InstallDir 'ZeroDelay.ico'
    $ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $launchArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$app`""
    # ZeroDelay.exe asks for admin rights under its own name and icon (older setups launched PowerShell directly)
    $exe = Join-Path $InstallDir 'ZeroDelay.exe'
    $hasExe = Test-Path -LiteralPath $exe

    # The "Start with Windows" task runs with admin rights: point it at the protected copy before the old one goes.
    $task = Get-ScheduledTask -TaskName 'ZeroDelay' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task -and "$($task.Actions[0].Arguments)".IndexOf($app, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        try { Set-ScheduledTask -TaskName 'ZeroDelay' -TaskPath '\' -Action (New-ScheduledTaskAction -Execute $ps -Argument "$launchArgs -Tray") -ErrorAction Stop | Out-Null }
        catch { Unregister-ScheduledTask -TaskName 'ZeroDelay' -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }   # ZeroDelay offers it again in Settings
    }

    if (-not $NoShortcuts) {
        $ws = New-Object -ComObject WScript.Shell
        # shortcuts that pointed at the old per-user copy
        foreach ($l in (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZeroDelay.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'ZeroDelay.lnk')) {
            Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
        }
        $links = @(
            (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'ZeroDelay.lnk'),
            (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'ZeroDelay.lnk')
        )
        foreach ($l in $links) {
            $lnk = $ws.CreateShortcut($l)
            if ($hasExe) { $lnk.TargetPath = $exe; $lnk.Arguments = '' } else { $lnk.TargetPath = $ps; $lnk.Arguments = $launchArgs }
            $lnk.WorkingDirectory = $InstallDir
            $lnk.IconLocation = "$ico,0"; $lnk.Description = 'ZeroDelay - Fortnite latency optimizer'
            $lnk.Save()
        }
        # Entry in Settings > Apps so it can be removed like any other program.
        $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZeroDelay'
        New-Item -Path $key -Force | Out-Null
        $props = @{
            DisplayName = 'ZeroDelay'; DisplayVersion = $version; Publisher = 'ZeroDelay'; DisplayIcon = $ico
            InstallLocation = $InstallDir; NoModify = 1; NoRepair = 1
            UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'uninstall.ps1')`""
        }
        foreach ($k in $props.Keys) {
            $type = if ($props[$k] -is [int]) { 'DWord' } else { 'String' }
            New-ItemProperty -Path $key -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
        }
        $kb = [int]((Get-ChildItem -LiteralPath $InstallDir -File | Measure-Object Length -Sum).Sum / 1KB)
        New-ItemProperty -Path $key -Name EstimatedSize -Value $kb -PropertyType DWord -Force | Out-Null
    }

    if ($InstallDir -ne $LegacyDir) { Remove-LegacyInstall }

    # Setup already runs as administrator, so ZeroDelay opens without a second permission prompt.
    if ($Update) {
        if (-not $NoLaunch) { if ($hasExe) { Start-Process $exe } else { Start-Process $ps -ArgumentList $launchArgs -WindowStyle Hidden } }
    } elseif (-not $NoLaunch) {
        $r = [Windows.MessageBox]::Show("ZeroDelay is installed. You will find it on your Desktop and in the Start menu.`n`nOpen it now?", 'ZeroDelay setup', 'YesNo', 'Information')
        if ($r -eq 'Yes') { if ($hasExe) { Start-Process $exe } else { Start-Process $ps -ArgumentList $launchArgs -WindowStyle Hidden } }
    }
} catch {
    [Windows.MessageBox]::Show("ZeroDelay could not be installed:`n`n$($_.Exception.Message)", 'ZeroDelay setup', 'OK', 'Error') | Out-Null
    exit 1
}
