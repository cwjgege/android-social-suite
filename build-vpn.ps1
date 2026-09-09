param(
    [string]$SdkRoot = 'D:\AndroidSocialPhones\android-sdk'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$project = Join-Path $root 'android-vpn'
$buildRoot = Join-Path $project 'build'
$expectedPrefix = [IO.Path]::GetFullPath($project).TrimEnd('\') + '\'
$resolvedBuild = [IO.Path]::GetFullPath($buildRoot)
if (-not $resolvedBuild.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe VPN build directory.'
}
$keystore = Join-Path $project 'android-social-tunnel.jks'
$previousKeystore = Join-Path $buildRoot 'android-social-tunnel.jks'
if (-not (Test-Path -LiteralPath $keystore) -and (Test-Path -LiteralPath $previousKeystore)) {
    Copy-Item -LiteralPath $previousKeystore -Destination $keystore
}
if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }

$javaHome = Join-Path $root 'android-jdk\jdk-17.0.20.1+1'
$buildTools = Join-Path $SdkRoot 'build-tools\34.0.0'
$androidJar = Join-Path $SdkRoot 'platforms\android-34\android.jar'
$aapt2 = Join-Path $buildTools 'aapt2.exe'
$d8 = Join-Path $buildTools 'd8.bat'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksigner = Join-Path $buildTools 'apksigner.bat'
$javac = Join-Path $javaHome 'bin\javac.exe'
$jar = Join-Path $javaHome 'bin\jar.exe'
$keytool = Join-Path $javaHome 'bin\keytool.exe'
$nativeLibrary = Join-Path $root 'vendor\android-vpn\libhev-socks5-tunnel.so'
$output = Join-Path $root 'vendor\android-vpn\android-social-tunnel.apk'
$env:JAVA_HOME = $javaHome
$env:Path = (Join-Path $javaHome 'bin') + ';' + $env:Path

foreach ($path in @($androidJar, $aapt2, $d8, $zipalign, $apksigner, $javac, $jar, $keytool, $nativeLibrary)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing VPN build dependency: $path" }
}

$classes = Join-Path $buildRoot 'classes'
$dex = Join-Path $buildRoot 'dex'
$staging = Join-Path $buildRoot 'staging'
New-Item -ItemType Directory -Force -Path $classes, $dex, (Join-Path $staging 'lib\x86_64') | Out-Null

$unsigned = Join-Path $buildRoot 'base-unsigned.apk'
$withFiles = Join-Path $buildRoot 'with-files.apk'
$aligned = Join-Path $buildRoot 'aligned.apk'
& $aapt2 link -I $androidJar --manifest (Join-Path $project 'AndroidManifest.xml') -o $unsigned
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed.' }

$sources = @(Get-ChildItem -LiteralPath (Join-Path $project 'src') -Filter *.java -Recurse | ForEach-Object FullName)
& $javac -encoding UTF-8 -source 8 -target 8 -classpath $androidJar -d $classes @sources
if ($LASTEXITCODE -ne 0) { throw 'Java compilation failed.' }
$classFiles = @(Get-ChildItem -LiteralPath $classes -Filter *.class -Recurse | ForEach-Object FullName)
& $d8 --release --lib $androidJar --output $dex @classFiles
if ($LASTEXITCODE -ne 0) { throw 'D8 compilation failed.' }

Copy-Item -LiteralPath $unsigned -Destination $withFiles
Copy-Item -LiteralPath $nativeLibrary -Destination (Join-Path $staging 'lib\x86_64\libhev-socks5-tunnel.so')
Push-Location $staging
try { & $jar uf $withFiles -C $dex classes.dex -C $staging lib }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'APK assembly failed.' }

& $zipalign -f 4 $withFiles $aligned
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed.' }
if (-not (Test-Path -LiteralPath $keystore)) {
    & $keytool -genkeypair -noprompt -keystore $keystore -storetype JKS -storepass androidsocialsuite -keypass androidsocialsuite -alias androidsocialsuite -keyalg RSA -keysize 2048 -validity 36500 -dname 'CN=Android Social Suite, O=Android Social Suite, C=US'
    if ($LASTEXITCODE -ne 0) { throw 'Signing key creation failed.' }
}
& $apksigner sign --ks $keystore --ks-key-alias androidsocialsuite --ks-pass pass:androidsocialsuite --key-pass pass:androidsocialsuite --out $output $aligned
if ($LASTEXITCODE -ne 0) { throw 'APK signing failed.' }
& $apksigner verify --verbose $output
if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }

Write-Output "Built: $output"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"
