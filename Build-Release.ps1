<#
    Build-Release.ps1 - developer-side build. Produces:
        build\BeckhoffRTLinuxSetup.exe                 (the program, via ps2exe)
        dist\BeckhoffRTLinuxSetup-Setup-<version>.exe  (the installer, via Inno Setup)  <- give THIS to customers
    Normally started by Build-Release.bat. Needs internet the first time (ps2exe module, Inno Setup).
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$src  = Join-Path $root 'BeckhoffRTLinuxSetup.ps1'
$iss  = Join-Path $root 'BeckhoffRTLinuxSetup.iss'
$exe  = Join-Path $root 'build\BeckhoffRTLinuxSetup.exe'
foreach ($f in $src, $iss, (Join-Path $root 'DISCLAIMER.txt')) {
    if (-not (Test-Path $f)) { throw "Missing file: $f" }
}
$version = (Select-String -Path $src -Pattern "^\`$ToolVersion\s*=\s*'([^']+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $version) { $version = '1.0.0' }
Write-Host "== Beckhoff RT Linux Setup - release build v$version" -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. script -> exe
Write-Host "`n[1/2] Compiling PowerShell script to exe (ps2exe)..." -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "      ps2exe module not found - installing for the current user from the PowerShell Gallery"
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe
New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
if (Test-Path $exe) { Remove-Item $exe -Force }
Invoke-ps2exe -inputFile $src -outputFile $exe -noConsole -STA -x64 `
    -title 'Beckhoff RT Linux Setup (unofficial)' `
    -product 'Beckhoff RT Linux Setup - unofficial tool' `
    -company 'Abdullah Omar, Beckhoff UAE (personal tool, not a Beckhoff product)' `
    -copyright "Abdullah Omar $(Get-Date -Format yyyy) - unofficial, unsupported, use at your own risk" `
    -version "$version.0" `
    -description 'UNOFFICIAL tool by Abdullah Omar (Beckhoff UAE). Provisions a Beckhoff RT Linux controller over SSH. Not a Beckhoff product.'
if (-not (Test-Path $exe)) { throw "ps2exe did not produce $exe" }
Write-Host "      OK: $exe" -ForegroundColor Green

# ---------------------------------------------------------------- 2. exe -> installer
Write-Host "`n[2/2] Building the installer (Inno Setup)..." -ForegroundColor Cyan
function Find-ISCC {
    $candidates = @(
        "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) + @((Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source)
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
$iscc = Find-ISCC
if (-not $iscc) {
    Write-Host "      Inno Setup not found - installing it with winget (JRSoftware.InnoSetup)..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget install --id JRSoftware.InnoSetup -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        $iscc = Find-ISCC
    }
    if (-not $iscc) { throw "Inno Setup 6 is required. Install it from https://jrsoftware.org/isdl.php and run this build again." }
}
Write-Host "      using $iscc"
# keep the .iss version in sync with the script
(Get-Content $iss -Raw) -replace '#define MyAppVersion\s+"[^"]+"', "#define MyAppVersion   `"$version`"" | Set-Content $iss -Encoding ASCII
New-Item -ItemType Directory -Force -Path (Join-Path $root 'dist') | Out-Null
& $iscc /Qp $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
$out = Join-Path $root "dist\BeckhoffRTLinuxSetup-Setup-$version.exe"
Write-Host "`nDONE. Give customers this file:" -ForegroundColor Green
Write-Host "      $out" -ForegroundColor Green
Write-Host "      (unsigned: Windows SmartScreen shows a warning on first run - sign with a code-signing certificate to avoid it)"
