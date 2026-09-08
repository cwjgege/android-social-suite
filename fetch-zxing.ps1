$ErrorActionPreference = 'Stop'

$version = '0.16.11'
$root = $PSScriptRoot
$vendor = Join-Path $root 'vendor\zxing'
$token = [Guid]::NewGuid().ToString('N')
$archive = Join-Path $env:TEMP "ZXing.Net.$version.$token.zip"
$expanded = Join-Path $env:TEMP "ZXing.Net.$version.$token"
$packageUrl = "https://www.nuget.org/api/v2/package/ZXing.Net/$version"

try {
    New-Item -ItemType Directory -Force -Path $vendor | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force

    $dll = @(
        (Join-Path $expanded 'lib\net48\zxing.dll'),
        (Join-Path $expanded 'lib\net47\zxing.dll'),
        (Join-Path $expanded 'lib\net45\zxing.dll'),
        (Join-Path $expanded 'lib\net40\zxing.dll')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $dll) { throw 'No compatible .NET Framework zxing.dll was found in the NuGet package.' }

    $license = Get-ChildItem -LiteralPath $expanded -File | Where-Object { $_.Name -match '^licen[cs]e(\..+)?$' } | Select-Object -First 1
    if (-not $license) { throw 'The ZXing.Net license file was not found in the NuGet package.' }

    Copy-Item -LiteralPath $dll -Destination (Join-Path $vendor 'zxing.dll') -Force
    Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $vendor 'LICENSE.txt') -Force
    Write-Host "ZXing.Net $version is ready in $vendor"
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    if (Test-Path -LiteralPath $expanded) {
        $resolved = [IO.Path]::GetFullPath($expanded)
        $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
