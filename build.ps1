# Builds dist\ZeroDelay-Setup.exe from source using the .NET Framework C# compiler that ships with Windows.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw 'C# compiler not found (.NET Framework 4 is required).' }

$stage = Join-Path ([IO.Path]::GetTempPath()) "zerodelay-build-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $stage | Out-Null
try {
    Copy-Item (Join-Path $root 'ZeroDelay.ps1') $stage
    Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt')
    foreach ($f in 'install.ps1', 'uninstall.ps1', 'Setup.cs', 'Launcher.cs', 'ZeroDelay.manifest') { Copy-Item (Join-Path $root "installer\$f") $stage }
    $ico = Join-Path $root 'assets\ZeroDelay.ico'
    if (-not (Test-Path $ico)) { throw 'assets\ZeroDelay.ico is missing (run ZeroDelay once; it writes ZeroDelay.ico next to the script).' }
    Copy-Item $ico $stage

    # ZeroDelay.exe: the launcher Windows shows (name and icon) when it asks for administrator rights
    & $csc /nologo /target:winexe /optimize+ "/out:$(Join-Path $stage 'ZeroDelay.exe')" "/win32icon:$(Join-Path $stage 'ZeroDelay.ico')" `
        "/win32manifest:$(Join-Path $stage 'ZeroDelay.manifest')" /r:System.Windows.Forms.dll (Join-Path $stage 'Launcher.cs')
    if ($LASTEXITCODE -ne 0) { throw "Launcher compile failed ($LASTEXITCODE)." }

    $dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Force $dist | Out-Null
    Copy-Item (Join-Path $stage 'ZeroDelay.exe') $dist -Force
    $out = Join-Path $dist 'ZeroDelay-Setup.exe'
    $res = foreach ($n in 'ZeroDelay.ps1', 'ZeroDelay.exe', 'ZeroDelay.ico', 'install.ps1', 'uninstall.ps1', 'LICENSE.txt') { "/resource:$(Join-Path $stage $n),$n" }
    & $csc /nologo /target:winexe /optimize+ "/out:$out" "/win32icon:$(Join-Path $stage 'ZeroDelay.ico')" /r:System.Windows.Forms.dll @res (Join-Path $stage 'Setup.cs')
    if ($LASTEXITCODE -ne 0) { throw "Compiler failed ($LASTEXITCODE)." }
    $hash = (Get-FileHash $out -Algorithm SHA256).Hash
    "Built $out"
    "SHA-256: $hash"
} finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
