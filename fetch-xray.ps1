param(
    [string]$Version = 'v25.10.15'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$destination = Join-Path $root 'vendor\xray'
$work = Join-Path $env:TEMP ('AndroidSocialXray-' + [Guid]::NewGuid().ToString('N'))
$zip = Join-Path $work 'Xray-windows-64.zip'
$extract = Join-Path $work 'extract'
$baseUrl = "https://github.com/XTLS/Xray-core/releases/download/$Version"

try {
    [void](New-Item -ItemType Directory -Path $destination -Force)
    [void](New-Item -ItemType Directory -Path $extract -Force)
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/Xray-windows-64.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    Copy-Item -LiteralPath (Join-Path $extract 'xray.exe') -Destination (Join-Path $destination 'xray.exe') -Force
    Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/XTLS/Xray-core/main/LICENSE' -OutFile (Join-Path $destination 'LICENSE.txt')
    Write-Output "Prepared embedded Xray $Version in $destination"
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

