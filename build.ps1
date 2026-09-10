param(
    [string]$Configuration = 'Release',
    [string]$OutputName = 'AndroidSocialSuite.exe'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$releaseDirectory = Join-Path $root 'release'
$output = Join-Path $releaseDirectory $OutputName
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$xrayExe = Join-Path $root 'vendor\xray\xray.exe'
$xrayLicense = Join-Path $root 'vendor\xray\LICENSE.txt'
$hysteria2Exe = Join-Path $root 'vendor\xray-hysteria2\xray.exe'
$hysteria2License = Join-Path $root 'vendor\xray-hysteria2\LICENSE.txt'
$zxingDll = Join-Path $root 'vendor\zxing\zxing.dll'
$zxingLicense = Join-Path $root 'vendor\zxing\LICENSE.txt'
$appIcon = Join-Path $root 'assets\android-social-suite.ico'
$appIconPng = Join-Path $root 'assets\android-social-suite-icon.png'
$tunnelApk = Join-Path $root 'vendor\android-vpn\android-social-tunnel.apk'
$tunnelLicense = Join-Path $root 'vendor\android-vpn\HEV-SOCKS5-TUNNEL-LICENSE.txt'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The 64-bit .NET Framework C# compiler was not found.'
}
if (-not (Test-Path -LiteralPath $xrayExe) -or -not (Test-Path -LiteralPath $xrayLicense)) {
    throw 'Embedded Xray files are missing. Run .\fetch-xray.ps1 first.'
}
if (-not (Test-Path -LiteralPath $hysteria2Exe) -or -not (Test-Path -LiteralPath $hysteria2License)) {
    throw 'Embedded Hysteria2 core is missing. Run .\fetch-hysteria2-core.ps1 first.'
}
if (-not (Test-Path -LiteralPath $zxingDll) -or -not (Test-Path -LiteralPath $zxingLicense)) {
    throw 'Embedded ZXing.Net files are missing. Run .\fetch-zxing.ps1 first.'
}
if (-not (Test-Path -LiteralPath $appIcon)) { throw "Application icon is missing: $appIcon" }
if (-not (Test-Path -LiteralPath $appIconPng)) { throw "Application icon image is missing: $appIconPng" }
if (-not (Test-Path -LiteralPath $tunnelApk) -or -not (Test-Path -LiteralPath $tunnelLicense)) {
    throw 'Managed Android VPN files are missing. Run .\build-vpn.ps1 first.'
}

[void](New-Item -ItemType Directory -Path $releaseDirectory -Force)

& $compiler `
    /nologo `
    /target:winexe `
    /optimize+ `
    /platform:anycpu `
    "/win32icon:$appIcon" `
    /reference:System.Windows.Forms.dll `
    "/out:$output" `
    "/resource:$root\android-social-suite.ps1,android-social-suite.ps1" `
    "/resource:$root\android-avd-manager.ps1,android-avd-manager.ps1" `
    "/resource:$xrayExe,xray.exe" `
    "/resource:$xrayLicense,XRAY-LICENSE.txt" `
    "/resource:$hysteria2Exe,xray-hysteria2.exe" `
    "/resource:$hysteria2License,HYSTERIA2-XRAY-LICENSE.txt" `
    "/resource:$zxingDll,zxing.dll" `
    "/resource:$zxingLicense,ZXING-LICENSE.txt" `
    "/resource:$appIcon,app-icon.ico" `
    "/resource:$appIconPng,app-icon.png" `
    "/resource:$tunnelApk,android-social-tunnel.apk" `
    "/resource:$tunnelLicense,HEV-SOCKS5-TUNNEL-LICENSE.txt" `
    "$root\AndroidSocialSuiteLauncher.cs"


if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE."
}

$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
Write-Output "Built: $output"
Write-Output "SHA256: $hash"
