param([string]$Archive)
$ErrorActionPreference = 'Stop'
$version = 'v26.3.27'
$expected = 'D004C39288CE9ADA487C6F398C7C545F7D749E44BDFDD59DBC9F865AFBA4E1AD'
$destination = Join-Path $PSScriptRoot 'vendor\xray-hysteria2'
$cache = Join-Path $PSScriptRoot 'work\hysteria2-core-v26.3.27'
[void][IO.Directory]::CreateDirectory($cache)
if (-not $Archive) {
    $Archive = Join-Path $cache 'Xray-windows-64.zip'
    if (-not (Test-Path -LiteralPath $Archive)) {
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/XTLS/Xray-core/releases/download/$version/Xray-windows-64.zip" -OutFile $Archive
    }
}
if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $expected) { throw 'Hysteria2 core archive checksum mismatch; no binary was installed.' }
$extract = Join-Path $cache ('extract-' + [Guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath $Archive -DestinationPath $extract
[void][IO.Directory]::CreateDirectory($destination)
Copy-Item -LiteralPath (Join-Path $extract 'xray.exe') -Destination (Join-Path $destination 'xray.exe') -Force
$license = Join-Path $extract 'LICENSE'
if (-not (Test-Path -LiteralPath $license)) { $license = Join-Path $extract 'LICENSE.txt' }
Copy-Item -LiteralPath $license -Destination (Join-Path $destination 'LICENSE.txt') -Force
[IO.File]::WriteAllText((Join-Path $destination 'VERSION.txt'), $version, [Text.UTF8Encoding]::new($false))
Write-Output "Prepared isolated Hysteria2 Xray core $version. Legacy Xray is unchanged."
