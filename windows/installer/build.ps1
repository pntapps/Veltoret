# Builds the Windows installer: publishes Veltoret (Release, self-contained x64), trims what Veltoret never
# uses, then compiles installer\Veltoret.iss with Inno Setup 6.7+.
#   powershell -ExecutionPolicy Bypass -File installer\build.ps1
# Output: artifacts\installer\Veltoret-Setup-<version>-x64.exe
$ErrorActionPreference = "Stop"
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $repo

$csproj = [xml](Get-Content "src\Veltoret.App\Veltoret.App.csproj")
$version = ($csproj.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
if (-not $version) { $version = "1.0.0" }

$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup" }

Write-Host "Publishing Veltoret $version ..."
if (Test-Path "artifacts\publish") { Remove-Item "artifacts\publish" -Recurse -Force }
dotnet publish src\Veltoret.App -c Release -r win-x64 --self-contained true `
    -p:PublishReadyToRun=true -p:DebugType=none -o artifacts\publish -nologo -v q
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# LibVLC plugins Veltoret never loads: it only plays (casting has its own stream server).
foreach ($dir in "visualization", "access_output", "stream_out") {
    $p = "artifacts\publish\libvlc\win-x64\plugins\$dir"
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}
# Rebuild LibVLC's plugin cache for the trimmed set (what vlc-cache-gen does). Without it LibVLC loads every
# plugin DLL each time it starts, which takes seconds on low-power PCs; the app can't write it under Program Files.
$vlcDir = (Resolve-Path "artifacts\publish\libvlc\win-x64").Path
Remove-Item "$vlcDir\plugins\plugins.dat" -ErrorAction SilentlyContinue
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VlcCacheGen
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool SetDllDirectory(string path);
    [DllImport("libvlc.dll")] public static extern IntPtr libvlc_new(int argc, string[] argv);
    [DllImport("libvlc.dll")] public static extern void libvlc_release(IntPtr instance);
}
'@
[VlcCacheGen]::SetDllDirectory($vlcDir) | Out-Null
$vlc = [VlcCacheGen]::libvlc_new(1, @("--reset-plugins-cache"))
if ($vlc -eq [IntPtr]::Zero) { throw "libvlc_new failed while building the plugin cache" }
[VlcCacheGen]::libvlc_release($vlc)
if (-not (Test-Path "$vlcDir\plugins\plugins.dat")) { throw "LibVLC didn't write plugins\plugins.dat" }

Write-Host "Compiling installer ..."
& $iscc "/DAppVersion=$version" "/Qp" "installer\Veltoret.iss"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
Get-ChildItem "artifacts\installer\Veltoret-Setup-$version-x64.exe" | ForEach-Object { "{0}  {1:N1} MB" -f $_.FullName, ($_.Length / 1MB) }
