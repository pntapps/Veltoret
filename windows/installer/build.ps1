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
# LibVLC rebuilds its plugin cache on first run; a stale one would list the removed plugins.
Remove-Item "artifacts\publish\libvlc\win-x64\plugins\plugins.dat" -ErrorAction SilentlyContinue

Write-Host "Compiling installer ..."
& $iscc "/DAppVersion=$version" "/Qp" "installer\Veltoret.iss"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
Get-ChildItem "artifacts\installer\Veltoret-Setup-$version-x64.exe" | ForEach-Object { "{0}  {1:N1} MB" -f $_.FullName, ($_.Length / 1MB) }
