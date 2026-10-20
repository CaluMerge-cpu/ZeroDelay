# ZeroDelay installer. Copies the app to %LOCALAPPDATA%\Programs\ZeroDelay for the current user,
# adds Desktop and Start menu shortcuts, and registers an uninstaller under Settings > Apps.
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\ZeroDelay'),
    [switch]$NoShortcuts,   # testing: copy files only
    [switch]$NoLaunch,
    [switch]$Update         # started by ZeroDelay's Update now button: no questions, reopen ZeroDelay afterwards
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName PresentationFramework

try {
    if ($Update) {
        # wait (up to 30 s) for the running ZeroDelay to close; it holds this mutex while open
        $deadline = (Get-Date).AddSeconds(30)
        $m = $null
        while ([Threading.Mutex]::TryOpenExisting('Local\ZeroDelayApp', [ref]$m)) {
            $m.Dispose()
            if ((Get-Date) -gt $deadline) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    foreach ($f in 'ZeroDelay.ps1', 'ZeroDelay.exe', 'ZeroDelay.ico', 'uninstall.ps1', 'LICENSE.txt', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll') {
        if (Test-Path (Join-Path $src $f)) { Copy-Item (Join-Path $src $f) (Join-Path $InstallDir $f) -Force }
    }
    # files from early versions that ran the app as FortniteOptimizer.ps1
    foreach ($old in 'FortniteOptimizer.ps1', 'Run Optimizer.bat') { Remove-Item (Join-Path $InstallDir $old) -Force -ErrorAction SilentlyContinue }
    $version = if ((Get-Content (Join-Path $InstallDir 'ZeroDelay.ps1') -TotalCount 80) -join "`n" -match "\`$AppVersion = '([\d.]+)'") { $Matches[1] } else { '1.0.0' }
    $app = Join-Path $InstallDir 'ZeroDelay.ps1'
    $ico = Join-Path $InstallDir 'ZeroDelay.ico'
    $ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $launchArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$app`""
    # ZeroDelay.exe asks for admin rights under its own name and icon (older setups launched PowerShell directly)
    $exe = Join-Path $InstallDir 'ZeroDelay.exe'
    $hasExe = Test-Path $exe

    if (-not $NoShortcuts) {
        $ws = New-Object -ComObject WScript.Shell
        $links = @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZeroDelay.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Programs')) 'ZeroDelay.lnk')
        )
        foreach ($l in $links) {
            $lnk = $ws.CreateShortcut($l)
            if ($hasExe) { $lnk.TargetPath = $exe; $lnk.Arguments = '' } else { $lnk.TargetPath = $ps; $lnk.Arguments = $launchArgs }
            $lnk.WorkingDirectory = $InstallDir
            $lnk.IconLocation = "$ico,0"; $lnk.Description = 'ZeroDelay - Fortnite latency optimizer'
            $lnk.Save()
        }
        # Per-user entry in Settings > Apps so it can be removed like any other program.
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZeroDelay'
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
        $kb = [int]((Get-ChildItem $InstallDir -File | Measure-Object Length -Sum).Sum / 1KB)
        New-ItemProperty -Path $key -Name EstimatedSize -Value $kb -PropertyType DWord -Force | Out-Null
    }

    if ($Update) {
        if (-not $NoLaunch) { if ($hasExe) { Start-Process $exe } else { Start-Process $ps -ArgumentList $launchArgs -WindowStyle Hidden } }
    } elseif (-not $NoLaunch) {
        $r = [Windows.MessageBox]::Show("ZeroDelay is installed. You will find it on your Desktop and in the Start menu.`n`nOpen it now? Windows will ask for administrator permission, because ZeroDelay changes system settings.", 'ZeroDelay setup', 'YesNo', 'Information')
        if ($r -eq 'Yes') { if ($hasExe) { Start-Process $exe } else { Start-Process $ps -ArgumentList $launchArgs -WindowStyle Hidden } }
    }
} catch {
    [Windows.MessageBox]::Show("ZeroDelay could not be installed:`n`n$($_.Exception.Message)", 'ZeroDelay setup', 'OK', 'Error') | Out-Null
    exit 1
}
