param(
    [switch]$SelfTest,
    [string]$CapturePreview
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('EmulatorWindowNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class EmulatorWindowNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);

    public static IntPtr FindEmulator(string avdName) {
        IntPtr result = IntPtr.Zero;
        string prefix = "Android Emulator - " + avdName + ":";
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;
            StringBuilder title = new StringBuilder(512);
            GetWindowText(hWnd, title, title.Capacity);
            if (title.ToString().StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) {
                result = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
}

$script:ZxingDll = @(
    (Join-Path $PSScriptRoot 'zxing.dll'),
    (Join-Path $PSScriptRoot 'vendor\zxing\zxing.dll')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$script:LatencyResults = @{}
$script:AutoLatencyTimer = [Windows.Forms.Timer]::new()
$script:AutoLatencyTimer.Interval = 300000
$script:AutoLatencyTimer.Add_Tick({
    try { Test-AllPhoneProxies -Automatic }
    catch { Set-Status 'Automatic latency test skipped while a device connection was changing.' }
})
$script:AutoLatencyTimer.Start()
$script:PlacedEmulatorWindows = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$script:BaseRoot = $env:ANDROID_SOCIAL_HOME
if ([string]::IsNullOrWhiteSpace($script:BaseRoot)) {
    $knownRoot = 'D:\AndroidSocialPhones'
    if (Test-Path -LiteralPath (Join-Path $knownRoot 'android-sdk\emulator\emulator.exe')) {
        $script:BaseRoot = $knownRoot
    } else {
        $script:BaseRoot = $PSScriptRoot
    }
}

$script:AvdRoot = Join-Path $script:BaseRoot 'android-avd'
$script:SdkRoot = Join-Path $script:BaseRoot 'android-sdk'
$script:EmulatorHome = Join-Path $script:BaseRoot 'emulator-home'
$script:EmulatorExe = Join-Path $script:SdkRoot 'emulator\emulator.exe'
$script:AdbExe = Join-Path $script:SdkRoot 'platform-tools\adb.exe'
$script:AdbKey = Join-Path $env:USERPROFILE '.android\adbkey'
$script:TemplateName = 'social_template'
$script:SharedProxyPort = 10808
$script:ProxyPortStart = 18081
$script:ProxyPortEnd = 18180
$script:RecommendedRunning = 2
$script:ProfileRoot = Join-Path $script:BaseRoot 'proxy-profiles'
$script:RuntimeRoot = Join-Path $script:BaseRoot 'proxy-runtime'
$script:BindingsFile = Join-Path $script:ProfileRoot 'bindings.json'
$script:InitializingDevices = $false
$script:DeviceProfiles = @(
    [pscustomobject]@{ Label = 'Google Pixel 4'; DeviceName = 'pixel_4'; Manufacturer = 'Google'; Width = 1080; Height = 2280; Density = 440; Ram = '1536M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Google Pixel 5'; DeviceName = 'pixel_5'; Manufacturer = 'Google'; Width = 1080; Height = 2340; Density = 440; Ram = '1536M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Google Pixel 6'; DeviceName = 'pixel_6'; Manufacturer = 'Google'; Width = 1080; Height = 2400; Density = 420; Ram = '1536M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Google Pixel 7'; DeviceName = 'pixel_7'; Manufacturer = 'Google'; Width = 1080; Height = 2400; Density = 420; Ram = '1536M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Google Pixel 8'; DeviceName = 'pixel_8'; Manufacturer = 'Google'; Width = 1080; Height = 2400; Density = 420; Ram = '1792M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Google Pixel 8 Pro'; DeviceName = 'pixel_8_pro'; Manufacturer = 'Google'; Width = 1344; Height = 2992; Density = 480; Ram = '2048M'; Cores = 4 },
    [pscustomobject]@{ Label = 'Samsung Galaxy S22 layout'; DeviceName = 'galaxy_s22_layout'; Manufacturer = 'Samsung'; Width = 1080; Height = 2340; Density = 420; Ram = '1792M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Samsung Galaxy S23 Ultra layout'; DeviceName = 'galaxy_s23_ultra_layout'; Manufacturer = 'Samsung'; Width = 1440; Height = 3088; Density = 500; Ram = '2048M'; Cores = 4 },
    [pscustomobject]@{ Label = 'Compact Android Phone'; DeviceName = 'compact_phone'; Manufacturer = 'Generic'; Width = 720; Height = 1600; Density = 320; Ram = '1280M'; Cores = 2 },
    [pscustomobject]@{ Label = 'Medium Android Phone'; DeviceName = 'medium_phone'; Manufacturer = 'Generic'; Width = 1080; Height = 2160; Density = 400; Ram = '1536M'; Cores = 2 },
    [pscustomobject]@{ Label = '10-inch Android Tablet'; DeviceName = 'tablet_10'; Manufacturer = 'Generic'; Width = 1600; Height = 2560; Density = 320; Ram = '2048M'; Cores = 4 }
)
$script:MediaExtensions = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.heif', '.mp4', '.mov', '.m4v', '.webm')
$script:ApkExtensions = @('.apk')

$env:ANDROID_AVD_HOME = $script:AvdRoot
$env:ANDROID_EMULATOR_HOME = $script:EmulatorHome
$env:ADB_VENDOR_KEYS = $script:AdbKey

foreach ($directory in @($script:EmulatorHome, $script:ProfileRoot, $script:RuntimeRoot)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = 'Android Social Phone Manager',
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    [void][System.Windows.Forms.MessageBox]::Show(
        $script:Form,
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    )
}

function Set-Status {
    param([string]$Text)
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Get-XrayExe {
    $candidates = @(
        (Join-Path $script:BaseRoot 'xray-core\xray.exe'),
        $env:XRAY_EXE,
        (Join-Path $env:USERPROFILE 'Desktop\v2rayN-windows-64\v2rayN-windows-64\bin\xray\xray.exe'),
        (Join-Path $env:USERPROFILE 'Desktop\v2rayN_v5.39\v2rayN-Core\xray.exe')
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    $null
}

function Get-AvdNames {
    @(Get-ChildItem -LiteralPath $script:AvdRoot -Filter '*.ini' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName } |
        Where-Object { $_ -ne $script:TemplateName } |
        Sort-Object)
}

function Get-RunningAvds {
    $running = @{}
    try {
        foreach ($process in Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction Stop) {
            if ($process.CommandLine -match '(?:^|\s)-avd\s+"?([^"\s]+)') {
                $running[$Matches[1]] = $true
            }
        }
    } catch {
        foreach ($name in Get-AvdNames) {
            $avdDirectory = Join-Path $script:AvdRoot ($name + '.avd')
            if (Get-ChildItem -LiteralPath $avdDirectory -Filter '*.lock' -ErrorAction SilentlyContinue) {
                $running[$name] = $true
            }
        }
    }
    $running
}

function Set-EmulatorWindowSafePosition {
    param([string]$Name)
    $handle = [EmulatorWindowNative]::FindEmulator($Name)
    if ($handle -eq [IntPtr]::Zero) { return $false }

    $rect = [EmulatorWindowNative+RECT]::new()
    if (-not [EmulatorWindowNative]::GetWindowRect($handle, [ref]$rect)) { return $false }
    $width = [Math]::Max(320, $rect.Right - $rect.Left)
    $height = [Math]::Max(480, $rect.Bottom - $rect.Top)
    $work = [Windows.Forms.Screen]::FromHandle($handle).WorkingArea
    $margin = 48
    $maxWidth = [Math]::Max(320, $work.Width - ($margin * 2))
    $maxHeight = [Math]::Max(480, $work.Height - ($margin * 2))
    $scale = [Math]::Min(1.0, [Math]::Min($maxWidth / $width, $maxHeight / $height))
    $targetWidth = [Math]::Max(320, [int][Math]::Floor($width * $scale))
    $targetHeight = [Math]::Max(480, [int][Math]::Floor($height * $scale))
    $targetX = $work.Left + [int][Math]::Floor(($work.Width - $targetWidth) / 2)
    $targetY = $work.Top + [int][Math]::Floor(($work.Height - $targetHeight) / 2)
    [void][EmulatorWindowNative]::MoveWindow($handle, $targetX, $targetY, $targetWidth, $targetHeight, $true)
    $true
}

function Sync-EmulatorWindowPlacement {
    $running = Get-RunningAvds
    foreach ($name in @($script:PlacedEmulatorWindows)) {
        if (-not $running.ContainsKey($name)) { [void]$script:PlacedEmulatorWindows.Remove($name) }
    }
    foreach ($name in @($running.Keys)) {
        if (-not $script:PlacedEmulatorWindows.Contains($name) -and (Set-EmulatorWindowSafePosition $name)) {
            [void]$script:PlacedEmulatorWindows.Add($name)
        }
    }
}

function Protect-Secret {
    param([string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
        $prefix = 'CU:'
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
    } catch [Security.Cryptography.CryptographicException] {
        $scope = [Security.Cryptography.DataProtectionScope]::LocalMachine
        $prefix = 'LM:'
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
    }
    $prefix + [Convert]::ToBase64String($protected)
}

function Unprotect-Secret {
    param([string]$Value)
    if ($Value.StartsWith('LM:')) {
        $scope = [Security.Cryptography.DataProtectionScope]::LocalMachine
        $payload = $Value.Substring(3)
    } elseif ($Value.StartsWith('CU:')) {
        $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
        $payload = $Value.Substring(3)
    } else {
        $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
        $payload = $Value
    }
    $protected = [Convert]::FromBase64String($payload)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        $scope
    )
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-ProxyBindings {
    if (-not (Test-Path -LiteralPath $script:BindingsFile)) { return @() }
    try {
        $wrapper = [IO.File]::ReadAllText($script:BindingsFile) | ConvertFrom-Json
        if (-not $wrapper -or -not $wrapper.bindings) { return @() }
        @($wrapper.bindings)
    } catch {
        throw 'The encrypted proxy binding file is damaged. Clear or restore proxy-profiles\bindings.json.'
    }
}

function Save-ProxyBindings {
    param([object[]]$Bindings)
    $wrapper = [ordered]@{
        version = 1
        bindings = @($Bindings)
    }
    $json = ConvertTo-Json -InputObject $wrapper -Depth 6
    [IO.File]::WriteAllText($script:BindingsFile, $json, [Text.UTF8Encoding]::new($false))
}

function Get-ProxyBinding {
    param([string]$Name)
    @(Get-ProxyBindings | Where-Object { $_.avdName -eq $Name }) | Select-Object -First 1
}

function Get-FreeProxyPort {
    $used = @{}
    foreach ($binding in Get-ProxyBindings) { $used[[int]$binding.port] = $true }
    for ($port = $script:ProxyPortStart; $port -le $script:ProxyPortEnd; $port++) {
        if (-not $used.ContainsKey($port)) { return $port }
    }
    throw 'No dedicated proxy ports are available. Remove an unused phone binding first.'
}

function Set-ProxyBinding {
    param([string]$Name, [string]$VlessUri)
    $bindings = [Collections.Generic.List[object]]::new()
    $existing = $null
    foreach ($binding in Get-ProxyBindings) {
        if ($binding.avdName -eq $Name) { $existing = $binding } else { $bindings.Add($binding) }
    }
    $port = if ($existing) { [int]$existing.port } else { Get-FreeProxyPort }
    $bindings.Add([pscustomobject]@{
        avdName = $Name
        port = $port
        protocol = Get-ProxyType $VlessUri
        encryptedUri = Protect-Secret $VlessUri
        updatedAt = (Get-Date).ToString('o')
    })
    Save-ProxyBindings -Bindings $bindings.ToArray()
    $port
}

function Remove-ProxyBinding {
    param([string]$Name)
    $remaining = @(Get-ProxyBindings | Where-Object { $_.avdName -ne $Name })
    Save-ProxyBindings -Bindings $remaining
}

function ConvertFrom-QueryString {
    param([string]$Query)
    $result = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        $key = [Web.HttpUtility]::UrlDecode($parts[0])
        $value = if ($parts.Count -gt 1) { [Web.HttpUtility]::UrlDecode($parts[1]) } else { '' }
        $result[$key] = $value
    }
    $result
}

function Get-QueryValue {
    param($Query, [string]$Name, [string]$Default = '')
    if ($Query.ContainsKey($Name)) { return $Query[$Name] }
    $Default
}

function New-XrayConfigObject {
    param([string]$VlessUri, [int]$Port)

    if ($VlessUri -notmatch '^vless://') { throw 'Only a vless:// share link is supported.' }
    try { $uri = [Uri]$VlessUri } catch { throw 'The VLESS share link is invalid.' }
    $id = [Uri]::UnescapeDataString(($uri.UserInfo -split ':')[0])
    if ($id -notmatch '^[0-9a-fA-F-]{32,36}$') { throw 'The VLESS user ID is missing or invalid.' }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Port -le 0) { throw 'The VLESS server address or port is invalid.' }

    $query = ConvertFrom-QueryString $uri.Query
    $network = (Get-QueryValue $query 'type' 'tcp').ToLowerInvariant()
    if ($network -eq 'splithttp') { $network = 'xhttp' }
    $supportedNetworks = @('tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'kcp')
    if ($network -notin $supportedNetworks) { throw "Unsupported VLESS transport: $network" }

    $security = (Get-QueryValue $query 'security' 'none').ToLowerInvariant()
    if ($security -notin @('none', 'tls', 'reality')) { throw "Unsupported VLESS security: $security" }
    $user = [ordered]@{ id = $id; encryption = (Get-QueryValue $query 'encryption' 'none') }
    $flow = Get-QueryValue $query 'flow'
    if ($flow) { $user.flow = $flow }

    $stream = [ordered]@{ network = $network; security = $security }
    $sni = Get-QueryValue $query 'sni' (Get-QueryValue $query 'serverName' '')
    $fingerprint = Get-QueryValue $query 'fp' ''
    $alpnValue = Get-QueryValue $query 'alpn' ''
    $alpn = if ($alpnValue) { @($alpnValue.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) } else { @() }

    if ($security -eq 'tls') {
        $tls = [ordered]@{ serverName = $sni; allowInsecure = ((Get-QueryValue $query 'allowInsecure' '0') -in @('1', 'true')) }
        if ($fingerprint) { $tls.fingerprint = $fingerprint }
        if ($alpn.Count -gt 0) { $tls.alpn = $alpn }
        $stream.tlsSettings = $tls
    } elseif ($security -eq 'reality') {
        $reality = [ordered]@{
            serverName = $sni
            fingerprint = $(if ($fingerprint) { $fingerprint } else { 'chrome' })
            publicKey = (Get-QueryValue $query 'pbk')
            shortId = (Get-QueryValue $query 'sid')
            spiderX = (Get-QueryValue $query 'spx' '/')
        }
        if (-not $reality.publicKey) { throw 'The REALITY public key (pbk) is missing.' }
        $stream.realitySettings = $reality
    }

    $transportHost = Get-QueryValue $query 'host' ''
    $path = Get-QueryValue $query 'path' '/'
    switch ($network) {
        'ws' {
            $headers = [ordered]@{}
            if ($transportHost) { $headers.Host = $transportHost }
            $stream.wsSettings = [ordered]@{ path = $path; headers = $headers }
        }
        'grpc' {
            $stream.grpcSettings = [ordered]@{
                serviceName = (Get-QueryValue $query 'serviceName' $path.TrimStart('/'))
                multiMode = ((Get-QueryValue $query 'mode' '') -eq 'multi')
            }
        }
        'httpupgrade' { $stream.httpupgradeSettings = [ordered]@{ host = $transportHost; path = $path } }
        'xhttp' {
            $xhttp = [ordered]@{ host = $transportHost; path = $path }
            $mode = Get-QueryValue $query 'mode' ''
            if ($mode) { $xhttp.mode = $mode }
            $extra = Get-QueryValue $query 'extra' ''
            if ($extra) {
                try { $xhttp.extra = ($extra | ConvertFrom-Json) } catch { throw 'The xHTTP extra parameter is not valid JSON.' }
            }
            $stream.xhttpSettings = $xhttp
        }
        'kcp' {
            $stream.kcpSettings = [ordered]@{
                seed = (Get-QueryValue $query 'seed' '')
                header = [ordered]@{ type = (Get-QueryValue $query 'headerType' 'none') }
            }
        }
        'tcp' {
            $headerType = Get-QueryValue $query 'headerType' 'none'
            if ($headerType -ne 'none') { $stream.tcpSettings = [ordered]@{ header = [ordered]@{ type = $headerType } } }
        }
    }

    [ordered]@{
        log = [ordered]@{ loglevel = 'warning' }
        inbounds = @([ordered]@{
            tag = 'android-http-in'
            listen = '127.0.0.1'
            port = $Port
            protocol = 'http'
            settings = [ordered]@{ timeout = 30 }
        })
        outbounds = @(
            [ordered]@{
                tag = 'vless-out'
                protocol = 'vless'
                settings = [ordered]@{
                    vnext = @([ordered]@{
                        address = $uri.Host
                        port = $uri.Port
                        users = @($user)
                    })
                }
                streamSettings = $stream
            },
            [ordered]@{ tag = 'blocked'; protocol = 'blackhole' }
        )
        routing = [ordered]@{
            domainStrategy = 'AsIs'
            rules = @([ordered]@{ type = 'field'; inboundTag = @('android-http-in'); outboundTag = 'vless-out' })
        }
    }
}

function ConvertFrom-Base64Text {
    param([string]$Value)
    $normalized = [Web.HttpUtility]::UrlDecode($Value.Trim()).Replace('-', '+').Replace('_', '/')
    while (($normalized.Length % 4) -ne 0) { $normalized += '=' }
    try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized)) }
    catch { throw 'The proxy link contains invalid Base64 data.' }
}

function Get-ProxyType {
    param([string]$Value)
    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('{')) { return 'Xray JSON' }
    if ($trimmed -match '^([A-Za-z0-9+.-]+)://') {
        switch ($Matches[1].ToLowerInvariant()) {
            'vless' { 'VLESS' }
            'vmess' { 'VMess' }
            'trojan' { 'Trojan' }
            'ss' { 'Shadowsocks' }
            'socks' { 'SOCKS5' }
            'socks5' { 'SOCKS5' }
            'http' { 'HTTP' }
            'https' { 'HTTPS' }
            default { $Matches[1].ToUpperInvariant() }
        }
        return
    }
    'Unknown'
}

function New-StreamSettingsFromQuery {
    param($Query, [string]$DefaultSecurity = 'none')
    $network = (Get-QueryValue $Query 'type' (Get-QueryValue $Query 'net' 'tcp')).ToLowerInvariant()
    if ($network -eq 'splithttp') { $network = 'xhttp' }
    if ($network -eq 'raw') { $network = 'tcp' }
    if ($network -notin @('tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'kcp')) { throw "Unsupported transport: $network" }
    $security = (Get-QueryValue $Query 'security' (Get-QueryValue $Query 'tls' $DefaultSecurity)).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($security)) { $security = $DefaultSecurity }
    if ($security -notin @('none', 'tls', 'reality')) { throw "Unsupported transport security: $security" }
    $stream = [ordered]@{ network = $network; security = $security }
    $sni = Get-QueryValue $Query 'sni' (Get-QueryValue $Query 'serverName' '')
    $fingerprint = Get-QueryValue $Query 'fp' ''
    $alpnValue = Get-QueryValue $Query 'alpn' ''
    if ($security -eq 'tls') {
        $tls = [ordered]@{ serverName = $sni; allowInsecure = ((Get-QueryValue $Query 'allowInsecure' (Get-QueryValue $Query 'insecure' '0')) -in @('1', 'true')) }
        if ($fingerprint) { $tls.fingerprint = $fingerprint }
        if ($alpnValue) { $tls.alpn = @($alpnValue.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) }
        $stream.tlsSettings = $tls
    } elseif ($security -eq 'reality') {
        $reality = [ordered]@{
            serverName = $sni
            fingerprint = $(if ($fingerprint) { $fingerprint } else { 'chrome' })
            publicKey = (Get-QueryValue $Query 'pbk')
            shortId = (Get-QueryValue $Query 'sid')
            spiderX = (Get-QueryValue $Query 'spx' '/')
        }
        if (-not $reality.publicKey) { throw 'The REALITY public key (pbk) is missing.' }
        $stream.realitySettings = $reality
    }
    $transportHost = Get-QueryValue $Query 'host' ''
    $path = Get-QueryValue $Query 'path' '/'
    switch ($network) {
        'ws' {
            $headers = [ordered]@{}
            if ($transportHost) { $headers.Host = $transportHost }
            $stream.wsSettings = [ordered]@{ path = $path; headers = $headers }
        }
        'grpc' { $stream.grpcSettings = [ordered]@{ serviceName = (Get-QueryValue $Query 'serviceName' $path.TrimStart('/')); multiMode = ((Get-QueryValue $Query 'mode' '') -eq 'multi') } }
        'httpupgrade' { $stream.httpupgradeSettings = [ordered]@{ host = $transportHost; path = $path } }
        'xhttp' {
            $xhttp = [ordered]@{ host = $transportHost; path = $path }
            $mode = Get-QueryValue $Query 'mode' ''
            if ($mode) { $xhttp.mode = $mode }
            $stream.xhttpSettings = $xhttp
        }
        'kcp' { $stream.kcpSettings = [ordered]@{ seed = (Get-QueryValue $Query 'seed' ''); header = [ordered]@{ type = (Get-QueryValue $Query 'headerType' 'none') } } }
        'tcp' {
            $headerType = Get-QueryValue $Query 'headerType' 'none'
            if ($headerType -ne 'none') { $stream.tcpSettings = [ordered]@{ header = [ordered]@{ type = $headerType } } }
        }
    }
    $stream
}

function New-ProxyEnvelope {
    param($Outbound, [int]$Port)
    if ($Outbound -is [Collections.IDictionary]) { $Outbound['tag'] = 'proxy-out' }
    else { $Outbound | Add-Member -NotePropertyName tag -NotePropertyValue 'proxy-out' -Force }
    [ordered]@{
        log = [ordered]@{ loglevel = 'warning' }
        inbounds = @([ordered]@{ tag = 'android-http-in'; listen = '127.0.0.1'; port = $Port; protocol = 'http'; settings = [ordered]@{ timeout = 30 } })
        outbounds = @($Outbound, [ordered]@{ tag = 'blocked'; protocol = 'blackhole' })
        routing = [ordered]@{ domainStrategy = 'AsIs'; rules = @([ordered]@{ type = 'field'; inboundTag = @('android-http-in'); outboundTag = 'proxy-out' }) }
    }
}

function New-UniversalProxyConfigObject {
    param([string]$ProxyValue, [int]$Port)
    $value = $ProxyValue.Trim()
    if ($value.StartsWith('{')) {
        try { $json = $value | ConvertFrom-Json } catch { throw 'The Xray JSON is invalid.' }
        $outbound = if ($json.protocol) { $json } elseif ($json.outbounds) { @($json.outbounds | Where-Object { $_.protocol -notin @('blackhole', 'freedom', 'dns') }) | Select-Object -First 1 } else { $null }
        if (-not $outbound -or -not $outbound.protocol) { throw 'Paste one Xray outbound object or a config containing a supported outbound.' }
        if ($outbound.protocol -notin @('vless', 'vmess', 'trojan', 'shadowsocks', 'socks', 'http', 'wireguard', 'hysteria')) { throw "Unsupported Xray outbound protocol: $($outbound.protocol)" }
        return New-ProxyEnvelope $outbound $Port
    }
    if ($value -match '^vless://') { return New-XrayConfigObject $value $Port }

    if ($value -match '^vmess://') {
        $payload = $value.Substring(8).Split('#')[0]
        try { $data = (ConvertFrom-Base64Text $payload) | ConvertFrom-Json } catch { throw 'The VMess share link is invalid.' }
        if (-not $data.add -or -not $data.port -or -not $data.id) { throw 'The VMess server, port, or user ID is missing.' }
        $query = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($pair in @{
            type = $data.net; security = $data.tls; sni = $data.sni; fp = $data.fp; alpn = $data.alpn; host = $data.host; path = $data.path; serviceName = $data.path; headerType = $data.type
        }.GetEnumerator()) { if ($null -ne $pair.Value) { $query[$pair.Key] = [string]$pair.Value } }
        $user = [ordered]@{ id = [string]$data.id; alterId = $(if ($data.aid) { [int]$data.aid } else { 0 }); security = $(if ($data.scy) { [string]$data.scy } else { 'auto' }) }
        $outbound = [ordered]@{ protocol = 'vmess'; settings = [ordered]@{ vnext = @([ordered]@{ address = [string]$data.add; port = [int]$data.port; users = @($user) }) }; streamSettings = (New-StreamSettingsFromQuery $query) }
        return New-ProxyEnvelope $outbound $Port
    }

    if ($value -match '^trojan://') {
        try { $uri = [Uri]$value } catch { throw 'The Trojan share link is invalid.' }
        if (-not $uri.Host -or $uri.Port -le 0 -or -not $uri.UserInfo) { throw 'The Trojan server, port, or password is missing.' }
        $query = ConvertFrom-QueryString $uri.Query
        $outbound = [ordered]@{
            protocol = 'trojan'
            settings = [ordered]@{ servers = @([ordered]@{ address = $uri.Host; port = $uri.Port; password = [Uri]::UnescapeDataString($uri.UserInfo) }) }
            streamSettings = (New-StreamSettingsFromQuery $query 'tls')
        }
        return New-ProxyEnvelope $outbound $Port
    }

    if ($value -match '^ss://') {
        $raw = $value.Substring(5).Split('#')[0]
        $queryPart = ''
        if ($raw.Contains('?')) { $queryPart = $raw.Substring($raw.IndexOf('?') + 1); $raw = $raw.Substring(0, $raw.IndexOf('?')) }
        $query = ConvertFrom-QueryString $queryPart
        if (Get-QueryValue $query 'plugin' '') { throw 'Shadowsocks plugin links are not supported by the embedded Xray core.' }
        if ($raw.Contains('@')) {
            $parts = $raw.Split('@', 2)
            $credentials = [Web.HttpUtility]::UrlDecode($parts[0])
            if (-not $credentials.Contains(':')) { $credentials = ConvertFrom-Base64Text $credentials }
            $endpoint = $parts[1]
        } else {
            $decoded = ConvertFrom-Base64Text $raw
            $at = $decoded.LastIndexOf('@')
            if ($at -lt 1) { throw 'The Shadowsocks share link is invalid.' }
            $credentials = $decoded.Substring(0, $at)
            $endpoint = $decoded.Substring($at + 1)
        }
        $colon = $credentials.IndexOf(':')
        if ($colon -lt 1) { throw 'The Shadowsocks method or password is missing.' }
        $method = $credentials.Substring(0, $colon)
        $password = $credentials.Substring($colon + 1)
        try { $endpointUri = [Uri]("ss://user@$endpoint") } catch { throw 'The Shadowsocks server address is invalid.' }
        $outbound = [ordered]@{ protocol = 'shadowsocks'; settings = [ordered]@{ servers = @([ordered]@{ address = $endpointUri.Host; port = $endpointUri.Port; method = $method; password = $password }) } }
        return New-ProxyEnvelope $outbound $Port
    }

    if ($value -match '^(socks5?|https?)://') {
        try { $uri = [Uri]$value } catch { throw 'The upstream proxy URL is invalid.' }
        if (-not $uri.Host -or $uri.Port -le 0) { throw 'The upstream proxy server or port is missing.' }
        $credentials = if ($uri.UserInfo) { $uri.UserInfo.Split(':', 2) } else { @() }
        if ($uri.Scheme -in @('socks', 'socks5')) {
            $server = [ordered]@{ address = $uri.Host; port = $uri.Port }
            if ($credentials.Count -gt 0) { $server.users = @([ordered]@{ user = [Uri]::UnescapeDataString($credentials[0]); pass = $(if ($credentials.Count -gt 1) { [Uri]::UnescapeDataString($credentials[1]) } else { '' }) }) }
            $outbound = [ordered]@{ protocol = 'socks'; settings = [ordered]@{ servers = @($server) } }
        } else {
            $server = [ordered]@{ address = $uri.Host; port = $uri.Port }
            if ($credentials.Count -gt 0) { $server.users = @([ordered]@{ user = [Uri]::UnescapeDataString($credentials[0]); pass = $(if ($credentials.Count -gt 1) { [Uri]::UnescapeDataString($credentials[1]) } else { '' }) }) }
            $outbound = [ordered]@{ protocol = 'http'; settings = [ordered]@{ servers = @($server) } }
            if ($uri.Scheme -eq 'https') { $outbound.streamSettings = [ordered]@{ network = 'tcp'; security = 'tls'; tlsSettings = [ordered]@{ serverName = $uri.Host } } }
        }
        return New-ProxyEnvelope $outbound $Port
    }
    throw 'Supported inputs: VLESS, VMess, Trojan, Shadowsocks, SOCKS5, HTTP/HTTPS, or an Xray outbound JSON object.'
}

function New-XrayConfigJson {
    param([string]$VlessUri, [int]$Port)
    ConvertTo-Json -InputObject (New-UniversalProxyConfigObject $VlessUri $Port) -Depth 24
}

function Test-TcpPort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne(700)) { return $false }
        $client.EndConnect($result)
        $true
    } catch { $false } finally { $client.Close() }
}

function Get-XrayConfigPath {
    param([string]$Name)
    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    Join-Path (Join-Path $script:RuntimeRoot $safeName) 'config.json'
}

function Get-XrayProcessForAvd {
    param([string]$Name)
    $configPath = Get-XrayConfigPath $Name
    try {
        @(Get-CimInstance Win32_Process -Filter "Name='xray.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($configPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) |
            Select-Object -First 1
    } catch { $null }
}

function Test-XrayConfig {
    param([string]$ConfigJson)
    $xray = Get-XrayExe
    if (-not $xray) { throw 'Xray core is missing. Reopen AndroidSocialSuite.exe to install it.' }
    $testPath = Join-Path $env:TEMP ('android-vless-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($testPath, $ConfigJson, [Text.UTF8Encoding]::new($false))
        $output = & $xray run -test -c $testPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($output | Out-String).Trim()) }
    } finally {
        if (Test-Path -LiteralPath $testPath) { [IO.File]::Delete($testPath) }
    }
}

function Start-XrayForAvd {
    param([string]$Name)
    $binding = Get-ProxyBinding $Name
    if (-not $binding) { return $null }
    $port = [int]$binding.port
    $owned = Get-XrayProcessForAvd $Name
    if ($owned -and (Test-TcpPort $port)) { return $port }
    if (Test-TcpPort $port) { throw "Local port $port is occupied by another program." }

    $xray = Get-XrayExe
    if (-not $xray) { throw 'Xray core is missing. Reopen AndroidSocialSuite.exe to install it.' }
    $vlessUri = Unprotect-Secret $binding.encryptedUri
    $configJson = New-XrayConfigJson $vlessUri $port
    $configPath = Get-XrayConfigPath $Name
    $configDirectory = Split-Path $configPath -Parent
    [void](New-Item -ItemType Directory -Path $configDirectory -Force)
    [IO.File]::WriteAllText($configPath, $configJson, [Text.UTF8Encoding]::new($false))

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $xray
    $info.Arguments = 'run -c "{0}"' -f $configPath
    $info.WorkingDirectory = Split-Path $xray -Parent
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    Start-Sleep -Milliseconds 700
    if ($process.HasExited -or -not (Test-TcpPort $port)) {
        throw "The dedicated Xray proxy for $Name could not start. Use Set VLESS again to validate the node."
    }
    $port
}

function Stop-XrayForAvd {
    param([string]$Name)
    $process = Get-XrayProcessForAvd $Name
    if ($process) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 150
    }
    $configPath = Get-XrayConfigPath $Name
    if (Test-Path -LiteralPath $configPath) {
        try { [IO.File]::Delete($configPath) } catch { }
    }
}

function Get-SelectedAvd {
    if ($script:AvdList.SelectedItems.Count -eq 0) {
        Show-Message 'Select a phone first.' 'No selection' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $null
    }
    $script:AvdList.SelectedItems[0].Text
}

function Get-DeviceProfileLabel {
    param([string]$Name)
    $profilePath = Join-Path $script:AvdRoot ($Name + '.avd\android-social-profile.json')
    if (-not (Test-Path -LiteralPath $profilePath)) { return 'Existing profile' }
    try {
        $profile = [IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        if ($profile.label) { return [string]$profile.label }
    } catch { }
    'Existing profile'
}

function Update-AvdList {
    $selectedName = if ($script:AvdList.SelectedItems.Count -gt 0) { $script:AvdList.SelectedItems[0].Text } else { $null }
    $running = Get-RunningAvds
    $bindings = @{}
    foreach ($binding in Get-ProxyBindings) { $bindings[$binding.avdName] = $binding }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($name in Get-AvdNames) {
        $status = if ($running.ContainsKey($name)) { 'Running' } else { 'Stopped' }
        $profileLabel = Get-DeviceProfileLabel $name
        $proxy = if ($bindings.ContainsKey($name)) { 'Dedicated :' + $bindings[$name].port } elseif ($name -eq $script:TemplateName) { '-' } else { 'Not assigned' }
        $latency = if ($script:LatencyResults.ContainsKey($name)) { [string]$script:LatencyResults[$name] } else { 'Not tested' }
        $rows.Add([pscustomobject]@{ Name = $name; Status = $status; Proxy = $proxy; Profile = $profileLabel; Latency = $latency })
    }
    $signature = ($rows | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Name, $_.Status, $_.Proxy, $_.Profile }) -join ';'
    if ($script:LastDeviceSignature -ne $signature) {
        $script:AvdList.BeginUpdate()
        try {
            $script:AvdList.Items.Clear()
            foreach ($row in $rows) {
                $item = [Windows.Forms.ListViewItem]::new($row.Name)
                [void]$item.SubItems.Add($row.Status)
                [void]$item.SubItems.Add($row.Proxy)
                [void]$item.SubItems.Add($row.Profile)
                [void]$item.SubItems.Add($row.Latency)
                if ($row.Name -eq $selectedName) { $item.Selected = $true }
                [void]$script:AvdList.Items.Add($item)
            }
            $script:LastDeviceSignature = $signature
        } finally {
            $script:AvdList.EndUpdate()
        }
        $script:AvdList.Invalidate()
    }
    $summary = '{0} device(s)    {1} running    Recommended concurrent limit: {2}' -f $script:AvdList.Items.Count, $running.Count, $script:RecommendedRunning
    if ($script:SummaryLabel.Text -ne $summary) { $script:SummaryLabel.Text = $summary }
    Sync-ActionStates
}

function Find-ScreenQrText {
    if (-not $script:ZxingDll) { throw 'The QR decoder is missing from this package.' }
    if (-not ('ZXing.BarcodeReader' -as [type])) { Add-Type -Path $script:ZxingDll }

    $reader = New-Object ZXing.BarcodeReader
    $reader.AutoRotate = $true
    $reader.Options.TryHarder = $true
    $screenNumber = 0

    foreach ($screen in [Windows.Forms.Screen]::AllScreens) {
        $screenNumber++
        $bounds = $screen.Bounds
        $bitmap = New-Object Drawing.Bitmap($bounds.Width, $bounds.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size, [Drawing.CopyPixelOperation]::SourceCopy)
            $result = $reader.Decode($bitmap)
            if ($result -and ([string]$result.BarcodeFormat -eq 'QR_CODE')) {
                return [pscustomobject]@{ Text = $result.Text.Trim(); Screen = $screenNumber }
            }
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
    return $null
}

function Prompt-VlessUri {
    param([string]$Name)
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = "Set proxy for $Name"
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [Drawing.Size]::new(620, 190)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $label = [Windows.Forms.Label]::new()
    $label.Text = 'Paste VLESS, VMess, Trojan, SS, SOCKS5, HTTP(S), or one Xray outbound JSON object.'
    $label.Location = [Drawing.Point]::new(18, 18)
    $label.Size = [Drawing.Size]::new(585, 36)
    $box = [Windows.Forms.TextBox]::new()
    $box.Location = [Drawing.Point]::new(18, 62)
    $box.Size = [Drawing.Size]::new(584, 25)
    $box.UseSystemPasswordChar = $true
    $show = [Windows.Forms.CheckBox]::new()
    $show.Text = 'Show link'
    $show.Location = [Drawing.Point]::new(20, 99)
    $show.Add_CheckedChanged({ $box.UseSystemPasswordChar = -not $show.Checked })
    $ok = [Windows.Forms.Button]::new()
    $ok.Text = 'Validate and Save'
    $ok.Location = [Drawing.Point]::new(350, 135)
    $ok.Size = [Drawing.Size]::new(135, 34)
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = 'Cancel'
    $cancel.Location = [Drawing.Point]::new(493, 135)
    $cancel.Size = [Drawing.Size]::new(109, 34)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $scan = [Windows.Forms.Button]::new()
    $scan.Text = 'Scan Screen QR'
    $scan.Location = [Drawing.Point]::new(16, 135)
    $scan.Size = [Drawing.Size]::new(155, 34)
    $scan.Add_Click({
        try {
            $scan.Enabled = $false
            $dialog.Hide()
            Start-Sleep -Milliseconds 250
            $qr = Find-ScreenQrText
            $dialog.Show()
            $dialog.Activate()
            if (-not $qr) {
                Show-Message 'No QR code was found. Make the complete QR code visible, enlarge it, and try again.' 'QR code not found' ([Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            $box.Text = $qr.Text
            $scheme = if ($qr.Text -match '^([a-zA-Z][a-zA-Z0-9+.-]*):') { $Matches[1].ToUpperInvariant() } elseif ($qr.Text.StartsWith('{')) { 'XRAY JSON' } else { 'UNKNOWN' }
            Set-Status "$scheme QR code found on display $($qr.Screen). Review it, then choose Validate and Save."
        } catch {
            $dialog.Show()
            $dialog.Activate()
            Show-Message $_.Exception.Message 'QR scan failed' ([Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $scan.Enabled = $true
        }
    })
    $dialog.Controls.AddRange(@($label, $box, $show, $scan, $ok, $cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $result = $dialog.ShowDialog($script:Form)
    $value = if ($result -eq [Windows.Forms.DialogResult]::OK) { $box.Text.Trim() } else { $null }
    $dialog.Dispose()
    $value
}

function Set-VlessForPhone {
    $name = Get-SelectedAvd
    if (-not $name) { return }
    if ($name -eq $script:TemplateName) {
        Show-Message 'Assign the node to a phone, not to the protected template.' 'Template protected' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ((Get-RunningAvds).ContainsKey($name)) {
        Show-Message 'Stop this Android phone before setting or replacing its proxy.' 'Phone must be stopped' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $link = Prompt-VlessUri $name
    if (-not $link) { return }
    try {
        Set-Status "Validating the proxy configuration for $name..."
        $existing = Get-ProxyBinding $name
        $testPort = if ($existing) { [int]$existing.port } else { Get-FreeProxyPort }
        Test-XrayConfig (New-XrayConfigJson $link $testPort)
        Stop-XrayForAvd $name
        $port = Set-ProxyBinding $name $link
        if ((Get-RunningAvds).ContainsKey($name)) { [void](Start-XrayForAvd $name) }
        Update-AvdList
        $proxyType = Get-ProxyType $link
        Set-Status "$name now has its own encrypted $proxyType proxy on local port $port."
        Show-Message "$proxyType proxy saved for $name.`r`nDedicated local port: $port`r`nUse Test Proxy to confirm its exit IP."
    } catch {
        Show-Message $_.Exception.Message 'Proxy validation failed' ([Windows.Forms.MessageBoxIcon]::Error)
        Set-Status 'Proxy was not changed.'
    }
}

function Clear-VlessForPhone {
    $name = Get-SelectedAvd
    if (-not $name -or $name -eq $script:TemplateName) { return }
    if ((Get-RunningAvds).ContainsKey($name)) {
        Show-Message 'Stop this Android phone before clearing its proxy.' 'Phone must be stopped' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not (Get-ProxyBinding $name)) {
        Show-Message "$name has no dedicated proxy binding."
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, "Remove the dedicated proxy binding from $name?", 'Clear Proxy', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    Stop-XrayForAvd $name
    Remove-ProxyBinding $name
    Update-AvdList
    Set-Status "Dedicated proxy removed from $name."
}

function Get-DeviceListControl {
    if (-not $script:Form) { return $null }
    $pending = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
    $pending.Enqueue($script:Form)
    while ($pending.Count -gt 0) {
        $control = $pending.Dequeue()
        if ($control -is [Windows.Forms.ListView]) { return $control }
        foreach ($child in $control.Controls) { $pending.Enqueue($child) }
    }
    return $null
}

function Sync-LatencyUi {
    $list = Get-DeviceListControl
    if (-not $list) { return }
    foreach ($item in $list.Items) {
        while ($item.SubItems.Count -le 4) { [void]$item.SubItems.Add('') }
        $next = if ($script:LatencyResults.ContainsKey($item.Text)) { [string]$script:LatencyResults[$item.Text] } else { 'Not tested' }
        if ($item.SubItems[4].Text -ne $next) {
            $item.SubItems[4].Text = $next
            $list.Invalidate($item.Bounds)
        }
    }
}

function Sync-ActionStates {
    if (-not $script:AvdList) { return }
    $hasSelection = $script:AvdList.SelectedItems.Count -gt 0
    $isRunning = $hasSelection -and $script:AvdList.SelectedItems[0].SubItems.Count -gt 1 -and $script:AvdList.SelectedItems[0].SubItems[1].Text -eq 'Running'
    if ($script:StartButton) { $script:StartButton.Enabled = $hasSelection -and -not $isRunning }
    if ($script:StopButton) { $script:StopButton.Enabled = $hasSelection -and $isRunning }
    foreach ($button in @($script:DeleteButton, $script:SetProxyButton, $script:ClearProxyButton)) {
        if ($button) { $button.Enabled = $hasSelection -and -not $isRunning }
    }
}

function Set-PhoneLatencyResult {
    param([string]$Name, [string]$Text)
    $script:LatencyResults[$Name] = $Text
    Sync-LatencyUi
    [Windows.Forms.Application]::DoEvents()
}

function Test-AllPhoneProxies {
    param([switch]$Automatic)
    $list = Get-DeviceListControl
    if (-not $list) { return }
    $names = @($list.Items | ForEach-Object { $_.Text } | Where-Object { $_ -and $_ -ne $script:TemplateName })
    if ($names.Count -eq 0) { return }

    $mode = if ($Automatic) { 'Automatic' } else { 'Manual' }
    Set-Status "$mode latency test started for $($names.Count) phone(s)..."
    foreach ($phoneName in $names) {
        Test-PhoneProxy -TargetName $phoneName -Automatic:$Automatic
    }
    Set-Status "$mode latency test complete. Results refresh automatically every 5 minutes."
}

function Get-XrayEndpointFromConfig {
    param([string]$ConfigPath)

    try {
        $config = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
        $outbound = @($config.outbounds | Where-Object { $_.protocol -notin @('freedom', 'blackhole') }) | Select-Object -First 1
        if (-not $outbound) { return $null }
        if ($outbound.settings.vnext) {
            return [pscustomobject]@{ Host = [string]$outbound.settings.vnext[0].address; Port = [int]$outbound.settings.vnext[0].port }
        }
        if ($outbound.settings.servers) {
            return [pscustomobject]@{ Host = [string]$outbound.settings.servers[0].address; Port = [int]$outbound.settings.servers[0].port }
        }
        if ($outbound.settings.address -and $outbound.settings.port) {
            return [pscustomobject]@{ Host = [string]$outbound.settings.address; Port = [int]$outbound.settings.port }
        }
        if ($outbound.settings.peers -and $outbound.settings.peers[0].endpoint -match '^\[?([^\]]+)\]?:([0-9]+)$') {
            return [pscustomobject]@{ Host = $Matches[1]; Port = [int]$Matches[2] }
        }
    } catch {
        return $null
    }
    return $null
}

function Measure-TcpLatency {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 2500)

    $samples = @()
    foreach ($attempt in 1..3) {
        $client = New-Object Net.Sockets.TcpClient
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $pending = $client.BeginConnect($HostName, $Port, $null, $null)
            if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { continue }
            $client.EndConnect($pending)
            $watch.Stop()
            $samples += $watch.Elapsed.TotalMilliseconds
        } catch {
        } finally {
            $watch.Stop()
            $client.Dispose()
        }
    }
    if ($samples.Count -eq 0) { return $null }
    [Math]::Round(($samples | Measure-Object -Average).Average)
}

function Test-PhoneProxy {
    param([string]$TargetName, [switch]$Automatic)
    if ([string]::IsNullOrWhiteSpace($TargetName)) {
        Test-AllPhoneProxies
        return
    }
    $name = $TargetName
    if (-not $name -or $name -eq $script:TemplateName) { return }
    $binding = Get-ProxyBinding $name
    if (-not $binding) {
        Set-PhoneLatencyResult $name 'No dedicated proxy'
        return
    }
    $wasRunning = [bool](Get-XrayProcessForAvd $name)
    try {
        Set-PhoneLatencyResult $name 'Testing...'
        Set-Status "Testing latency and the independent exit for $name..."
        $port = Start-XrayForAvd $name
        $endpoint = Get-XrayEndpointFromConfig (Get-XrayConfigPath $name)
        $tcpLatency = if ($endpoint) { Measure-TcpLatency $endpoint.Host $endpoint.Port } else { $null }
        $proxyWatch = [Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.ipify.org' -Proxy ("http://127.0.0.1:$port") -TimeoutSec 15
        $proxyWatch.Stop()
        $exitIp = $response.Content.Trim()
        if ($exitIp -notmatch '^[0-9a-fA-F:.]+$') { throw 'The proxy responded, but the exit IP could not be identified.' }
        $tcpText = if ($null -ne $tcpLatency) { "$tcpLatency ms" } else { 'N/A (endpoint unavailable or timed out)' }
        $proxyLatency = [Math]::Round($proxyWatch.Elapsed.TotalMilliseconds)
        Set-PhoneLatencyResult $name "TCP $tcpText / HTTPS $proxyLatency ms"
        Set-Status "${name}: TCP $tcpText, HTTPS $proxyLatency ms, exit $exitIp"
    } catch {
        $reason = $_.Exception.Message
        if ($reason.Length -gt 42) { $reason = $reason.Substring(0, 39) + '...' }
        Set-PhoneLatencyResult $name "Failed: $reason"
        Set-Status "$name latency test failed: $($_.Exception.Message)"
        Set-Status "$name proxy test failed."
    } finally {
        if (-not $wasRunning -and -not (Get-RunningAvds).ContainsKey($name)) { Stop-XrayForAvd $name }
    }
}

function Prompt-NewPhoneDetails {
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = 'Create a new phone'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [Drawing.Size]::new(490, 230)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $nameLabel = [Windows.Forms.Label]::new()
    $nameLabel.Text = 'Phone name'
    $nameLabel.Location = [Drawing.Point]::new(20, 20)
    $nameLabel.AutoSize = $true
    $nameBox = [Windows.Forms.TextBox]::new()
    $nameBox.Location = [Drawing.Point]::new(20, 44)
    $nameBox.Size = [Drawing.Size]::new(450, 25)
    $nameBox.Text = 'social_phone_01'

    $profileLabel = [Windows.Forms.Label]::new()
    $profileLabel.Text = 'Hardware profile'
    $profileLabel.Location = [Drawing.Point]::new(20, 84)
    $profileLabel.AutoSize = $true
    $profileBox = [Windows.Forms.ComboBox]::new()
    $profileBox.Location = [Drawing.Point]::new(20, 108)
    $profileBox.Size = [Drawing.Size]::new(450, 28)
    $profileBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $profileBox.DisplayMember = 'Label'
    foreach ($profile in $script:DeviceProfiles) { [void]$profileBox.Items.Add($profile) }
    $profileBox.SelectedIndex = 1

    $ok = [Windows.Forms.Button]::new()
    $ok.Text = 'Create'
    $ok.Location = [Drawing.Point]::new(274, 174)
    $ok.Size = [Drawing.Size]::new(94, 34)
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = 'Cancel'
    $cancel.Location = [Drawing.Point]::new(376, 174)
    $cancel.Size = [Drawing.Size]::new(94, 34)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.AddRange(@($nameLabel, $nameBox, $profileLabel, $profileBox, $ok, $cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    $result = $dialog.ShowDialog($script:Form)
    $details = if ($result -eq [Windows.Forms.DialogResult]::OK) {
        [pscustomobject]@{ Name = $nameBox.Text.Trim(); Profile = $profileBox.SelectedItem }
    } else { $null }
    $dialog.Dispose()
    $details
}

function Import-MediaFiles {
    param([string[]]$Paths)
    $name = Get-SelectedAvd
    if (-not $name) { return }
    if (-not (Get-RunningAvds).ContainsKey($name)) {
        Show-Message 'Start the selected Android phone before importing media.' 'Phone is stopped' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $serial = Get-DeviceForAvd $name
    if (-not $serial) {
        Show-Message 'The selected phone is still booting. Wait until Android is ready and drop the files again.' 'Phone not ready' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $mediaFiles = @($Paths | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        ($script:MediaExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant())
    })
    if ($mediaFiles.Count -eq 0) {
        Show-Message 'Drop JPG, PNG, WEBP, HEIC, MP4, MOV, M4V, or WEBM files.' 'Unsupported files' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $remoteDirectory = '/sdcard/DCIM/AndroidSocialSuite'
    & $script:AdbExe -s $serial shell mkdir -p $remoteDirectory | Out-Null
    if ($LASTEXITCODE -ne 0) { Show-Message 'Could not create the phone media folder.' 'Import failed' ([Windows.Forms.MessageBoxIcon]::Error); return }

    $imported = 0
    $failed = [Collections.Generic.List[string]]::new()
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $index = 0
    foreach ($file in $mediaFiles) {
        $index++
        $extension = [IO.Path]::GetExtension($file).ToLowerInvariant()
        $baseName = [IO.Path]::GetFileNameWithoutExtension($file) -replace '[^A-Za-z0-9._-]', '_'
        if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = 'media' }
        $remoteName = '{0}-{1:D2}-{2}{3}' -f $stamp, $index, $baseName, $extension
        $remotePath = "$remoteDirectory/$remoteName"
        Set-Status ("Importing {0} of {1} into {2}..." -f $index, $mediaFiles.Count, $name)
        & $script:AdbExe -s $serial push $file $remotePath | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed.Add([IO.Path]::GetFileName($file)); continue }
        & $script:AdbExe -s $serial shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d ("file://$remotePath") | Out-Null
        if ($LASTEXITCODE -eq 0) { $imported++ } else { $failed.Add([IO.Path]::GetFileName($file)) }
    }

    if ($failed.Count -eq 0) {
        Set-Status "$imported media file(s) imported into $name."
        Show-Message "$imported file(s) were added to the AndroidSocialSuite album.`r`nLocation: $remoteDirectory" 'Media import completed'
    } else {
        Set-Status "$imported imported, $($failed.Count) failed."
        Show-Message ("Imported: $imported`r`nFailed: $($failed.Count)`r`n`r`n" + ($failed -join "`r`n")) 'Media import partially completed' ([Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function Install-ApkFiles {
    param([string[]]$Paths)
    $name = Get-SelectedAvd
    if (-not $name) { return }
    if (-not (Get-RunningAvds).ContainsKey($name)) {
        Show-Message 'Start the selected Android phone before installing an APK.' 'Phone is stopped' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $serial = Get-DeviceForAvd $name
    if (-not $serial) {
        Show-Message 'The selected phone is still booting. Wait until Android is ready and drop the APK again.' 'Phone not ready' ([Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $apkFiles = @($Paths | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        ($script:ApkExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant())
    })
    if ($apkFiles.Count -eq 0) { return }

    $installed = 0
    $failed = [Collections.Generic.List[string]]::new()
    $index = 0
    foreach ($apk in $apkFiles) {
        $index++
        $apkName = [IO.Path]::GetFileName($apk)
        Set-Status ("Installing APK {0} of {1} on {2}: {3}" -f $index, $apkFiles.Count, $name, $apkName)
        $output = & $script:AdbExe -s $serial install -r $apk 2>&1
        if ($LASTEXITCODE -eq 0 -and (($output | Out-String) -match 'Success')) {
            $installed++
        } else {
            $failureText = (($output | Out-String).Trim() -replace '[\r\n]+', ' ')
            if ($failureText.Length -gt 180) { $failureText = $failureText.Substring(0, 180) + '...' }
            $failed.Add("$apkName`: $failureText")
        }
    }

    if ($failed.Count -eq 0) {
        Set-Status "$installed APK file(s) installed on $name."
        Show-Message "$installed APK file(s) installed successfully on $name." 'APK installation completed'
    } else {
        Set-Status "$installed installed, $($failed.Count) failed."
        Show-Message ("Installed: $installed`r`nFailed: $($failed.Count)`r`n`r`n" + ($failed -join "`r`n")) 'APK installation partially completed' ([Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function Handle-DroppedFiles {
    param([string[]]$Paths)
    $media = @($Paths | Where-Object { $script:MediaExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
    $apks = @($Paths | Where-Object { $script:ApkExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
    if ($media.Count -gt 0) { Import-MediaFiles $media }
    if ($apks.Count -gt 0) { Install-ApkFiles $apks }
    if ($media.Count -eq 0 -and $apks.Count -eq 0) {
        Show-Message 'Drop supported photos, videos, or standard .apk files.' 'Unsupported files' ([Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function New-Phone {
    $details = Prompt-NewPhoneDetails
    if (-not $details) { return }
    $name = $details.Name
    $profile = $details.Profile
    if (-not $name) { return }
    if ($name -notmatch '^[A-Za-z0-9_-]+$') { Show-Message 'Invalid name.' 'Invalid name' ([Windows.Forms.MessageBoxIcon]::Warning); return }
    if ($name -eq $script:TemplateName) { Show-Message 'That name is reserved.'; return }
    $templateConfig = Join-Path $script:AvdRoot ($script:TemplateName + '.avd\config.ini')
    $destination = Join-Path $script:AvdRoot ($name + '.avd')
    $pointerPath = Join-Path $script:AvdRoot ($name + '.ini')
    if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $pointerPath)) { Show-Message 'A phone with that name already exists.'; return }
    try {
        Set-Status "Creating $name..."
        [void](New-Item -ItemType Directory -Path $destination)
        $config = [IO.File]::ReadAllText($templateConfig)
        $config = $config -replace '(?m)^avd\.id\s*=.*$', "avd.id = $name"
        $config = $config -replace '(?m)^avd\.name\s*=.*$', "avd.name = $name"
        $config = $config -replace '(?m)^avd\.ini\.displayname\s*=.*$', "avd.ini.displayname = $name"
        $config = $config -replace '(?m)^hw\.keyboard\s*=.*$', 'hw.keyboard = yes'
        $config = $config -replace '(?m)^hw\.device\.manufacturer\s*=.*$', ('hw.device.manufacturer = ' + $profile.Manufacturer)
        $config = $config -replace '(?m)^hw\.device\.name\s*=.*$', ('hw.device.name = ' + $profile.DeviceName)
        $config = $config -replace '(?m)^hw\.lcd\.width\s*=.*$', ('hw.lcd.width = ' + $profile.Width)
        $config = $config -replace '(?m)^hw\.lcd\.height\s*=.*$', ('hw.lcd.height = ' + $profile.Height)
        $config = $config -replace '(?m)^hw\.lcd\.density\s*=.*$', ('hw.lcd.density = ' + $profile.Density)
        $config = $config -replace '(?m)^hw\.ramSize\s*=.*$', ('hw.ramSize = ' + $profile.Ram)
        $config = $config -replace '(?m)^hw\.cpu\.ncore\s*=.*$', ('hw.cpu.ncore = ' + $profile.Cores)
        [IO.File]::WriteAllText((Join-Path $destination 'config.ini'), $config, [Text.UTF8Encoding]::new($false))
        $profileRecord = [ordered]@{
            label = $profile.Label
            deviceName = $profile.DeviceName
            manufacturer = $profile.Manufacturer
            width = $profile.Width
            height = $profile.Height
            density = $profile.Density
            createdAt = (Get-Date).ToString('o')
        } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $destination 'android-social-profile.json'), $profileRecord, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($pointerPath, "avd.ini.encoding=UTF-8`r`npath=$destination`r`ntarget=android-34`r`n", [Text.UTF8Encoding]::new($false))
        Update-AvdList
        Set-Status "$name created. Assign a VLESS node before starting it."
    } catch { Show-Message $_.Exception.Message 'Create failed' ([Windows.Forms.MessageBoxIcon]::Error) }
}

function Start-Phone {
    $name = Get-SelectedAvd
    if (-not $name) { return }
    if ($name -eq $script:TemplateName) { Show-Message 'Create a phone from the protected template instead.'; return }
    $running = Get-RunningAvds
    if ($running.ContainsKey($name)) { Show-Message "$name is already running."; return }
    if ($running.Count -ge $script:RecommendedRunning) {
        $answer = [Windows.Forms.MessageBox]::Show($script:Form, 'Two phones are already running. Starting another may slow Windows. Continue?', 'Concurrent limit warning', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    try {
        $binding = Get-ProxyBinding $name
        if ($binding) {
            $proxyPort = Start-XrayForAvd $name
            $proxyMode = "dedicated proxy on port $proxyPort"
        } elseif (Test-TcpPort $script:SharedProxyPort) {
            $answer = [Windows.Forms.MessageBox]::Show($script:Form, 'No dedicated proxy is assigned. Start with the shared v2rayN proxy on port 10808?', 'Shared proxy fallback', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            $proxyPort = $script:SharedProxyPort
            $proxyMode = 'shared v2rayN proxy'
        } else {
            throw 'No dedicated proxy is assigned and the shared proxy on port 10808 is unavailable.'
        }

        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $script:EmulatorExe
        $info.Arguments = '-avd "{0}" -no-snapshot-load -accel on -gpu host -no-metrics -http-proxy http://127.0.0.1:{1}' -f $name, $proxyPort
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $false
        $info.EnvironmentVariables['ANDROID_AVD_HOME'] = $script:AvdRoot
        $info.EnvironmentVariables['ANDROID_EMULATOR_HOME'] = $script:EmulatorHome
        $info.EnvironmentVariables['ADB_VENDOR_KEYS'] = $script:AdbKey
        [void][Diagnostics.Process]::Start($info)
        Set-Status "$name is starting with $proxyMode."
    } catch {
        Stop-XrayForAvd $name
        Show-Message $_.Exception.Message 'Start failed' ([Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Get-DeviceForAvd {
    param([string]$Name)
    foreach ($line in (& $script:AdbExe devices 2>$null)) {
        if ($line -match '^(emulator-\d+)\s+device\s*$') {
            $serial = $Matches[1]
            $avdName = (& $script:AdbExe -s $serial shell getprop ro.boot.qemu.avd_name 2>$null).Trim()
            if ($avdName -eq $Name) { return $serial }
        }
    }
    $null
}

function Stop-Phone {
    $name = Get-SelectedAvd
    if (-not $name -or $name -eq $script:TemplateName) { return }
    if (-not (Get-RunningAvds).ContainsKey($name)) { Stop-XrayForAvd $name; Show-Message "$name is already stopped."; return }
    $serial = Get-DeviceForAvd $name
    if (-not $serial) { Show-Message 'The phone is still booting. Wait a moment and try again.' 'Not ready' ([Windows.Forms.MessageBoxIcon]::Warning); return }
    try {
        Set-Status "Stopping $name safely..."
        & $script:AdbExe -s $serial shell reboot -p 2>$null | Out-Null
        Stop-XrayForAvd $name
        Set-Status "$name stopped."
    } catch { Show-Message $_.Exception.Message 'Stop failed' ([Windows.Forms.MessageBoxIcon]::Error) }
}

function Delete-Phone {
    $name = Get-SelectedAvd
    if (-not $name -or $name -eq $script:TemplateName) { return }
    if ((Get-RunningAvds).ContainsKey($name)) { Show-Message 'Stop the phone before deleting it.'; return }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, "Move $name and all of its apps, data, and proxy binding to the Recycle Bin?", 'Confirm deletion', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $avdDirectory = Join-Path $script:AvdRoot ($name + '.avd')
    $pointerPath = Join-Path $script:AvdRoot ($name + '.ini')
    try {
        Stop-XrayForAvd $name
        Remove-ProxyBinding $name
        if (Test-Path -LiteralPath $avdDirectory) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($avdDirectory, 'OnlyErrorDialogs', 'SendToRecycleBin', 'DoNothing') }
        if (Test-Path -LiteralPath $pointerPath) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($pointerPath, 'OnlyErrorDialogs', 'SendToRecycleBin', 'DoNothing') }
        Update-AvdList
        Set-Status "$name moved to the Recycle Bin."
    } catch { Show-Message $_.Exception.Message 'Delete failed' ([Windows.Forms.MessageBoxIcon]::Error) }
}

function Initialize-RunningDevices {
    if ($script:InitializingDevices) { return }
    $script:InitializingDevices = $true
    try {
        foreach ($line in (& $script:AdbExe devices 2>$null)) {
            if ($line -notmatch '^(emulator-\d+)\s+device\s*$') { continue }
            $serial = $Matches[1]
            $name = (& $script:AdbExe -s $serial shell getprop ro.boot.qemu.avd_name 2>$null).Trim()
            $booted = (& $script:AdbExe -s $serial shell getprop sys.boot_completed 2>$null).Trim()
            if (-not $name -or $name -eq $script:TemplateName -or $booted -ne '1') { continue }

            $binding = Get-ProxyBinding $name
            if ($binding) {
                $proxyPort = [int]$binding.port
                if (-not (Test-TcpPort $proxyPort)) { [void](Start-XrayForAvd $name) }
                $desiredGuestProxy = "10.0.2.2:$proxyPort"
            } else {
                $desiredGuestProxy = ':0'
            }
            $currentGuestProxy = (& $script:AdbExe -s $serial shell settings get global http_proxy 2>$null).Trim()
            if ($currentGuestProxy -ne $desiredGuestProxy) {
                & $script:AdbExe -s $serial shell settings put global http_proxy $desiredGuestProxy 2>$null | Out-Null
            }

            $marker = Join-Path $script:AvdRoot ($name + '.avd\.per_device_proxy_v1')
            if (Test-Path -LiteralPath $marker) { continue }
            & $script:AdbExe -s $serial shell cmd media_session volume --stream 3 --set 15 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { & $script:AdbExe -s $serial shell 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do input keyevent 24; done' 2>$null | Out-Null }
            [IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), [Text.UTF8Encoding]::new($false))
            Set-Status "$name initialized: Android proxy $desiredGuestProxy active, media volume maximum."
        }
    } catch {
        if ($_.Exception.Message -notmatch '(?i)error:\s*(closed|offline)|device.*not found') {
            Set-Status 'Device initialization will retry after the connection stabilizes.'
        }
    } finally { $script:InitializingDevices = $false }
}

if ($SelfTest) {
    $failures = [Collections.Generic.List[string]]::new()
    $templateConfig = Join-Path $script:AvdRoot ($script:TemplateName + '.avd\config.ini')
    foreach ($check in @(
        @{ Name = 'Emulator'; Path = $script:EmulatorExe },
        @{ Name = 'ADB'; Path = $script:AdbExe },
        @{ Name = 'Template'; Path = (Join-Path $script:AvdRoot ($script:TemplateName + '.avd')) },
        @{ Name = 'Xray'; Path = (Get-XrayExe) }
    )) {
        if ($check.Path -and (Test-Path -LiteralPath $check.Path)) { Write-Output ("PASS $($check.Name): $($check.Path)") } else { $failures.Add("Missing $($check.Name): $($check.Path)") }
    }
    if (Test-Path -LiteralPath $templateConfig) {
        $templateText = [IO.File]::ReadAllText($templateConfig)
        if ($templateText -match '(?m)^hw\.keyboard\s*=\s*yes\s*$') { Write-Output 'PASS template hardware keyboard enabled' } else { $failures.Add('Template hardware keyboard is not enabled.') }
    }
    $secret = 'vless-self-test-value'
    if ((Unprotect-Secret (Protect-Secret $secret)) -eq $secret) { Write-Output 'PASS Windows DPAPI encryption' } else { $failures.Add('Windows DPAPI round trip failed.') }
    if (Get-XrayExe) {
        try {
            $sample = 'vless://11111111-1111-4111-8111-111111111111@example.com:443?encryption=none&security=tls&sni=example.com&type=ws&host=example.com&path=%2Fws#selftest'
            Test-XrayConfig (New-XrayConfigJson $sample 18999)
            Write-Output 'PASS generated VLESS/Xray configuration'
        } catch { $failures.Add('Generated Xray configuration failed: ' + $_.Exception.Message) }
    }
    $avds = @(Get-AvdNames)
    if ($avds.Count -gt 0) { Write-Output ('PASS AVD discovery: ' + ($avds -join ', ')) } else { $failures.Add('No AVDs were discovered.') }
    if (Test-Path -LiteralPath $script:EmulatorExe) {
        $accelOutput = & $script:EmulatorExe -accel-check 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Output ('PASS acceleration: ' + (($accelOutput | Out-String).Trim())) } else { $failures.Add('Acceleration check failed.') }
    }
    if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
    Write-Output 'SELF-TEST PASSED'
    return
}

function New-RoundedRectanglePath {
    param([Drawing.RectangleF]$Rectangle, [single]$Radius)
    $path = [Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $Radius * 2
    $arc = [Drawing.RectangleF]::new($Rectangle.X, $Rectangle.Y, $diameter, $diameter)
    $path.AddArc($arc, 180, 90)
    $arc.X = $Rectangle.Right - $diameter
    $path.AddArc($arc, 270, 90)
    $arc.Y = $Rectangle.Bottom - $diameter
    $path.AddArc($arc, 0, 90)
    $arc.X = $Rectangle.Left
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()
    $path
}

$script:Form = [Windows.Forms.Form]::new()
$script:Form.Text = 'Android Social Suite'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.ClientSize = [Drawing.Size]::new(1180, 760)
$script:Form.MinimumSize = [Drawing.Size]::new(1120, 720)
$script:Form.BackColor = [Drawing.Color]::FromArgb(250, 249, 247)
$script:Form.Font = [Drawing.Font]::new('Segoe UI', 9)
$script:Form.AllowDrop = $true
$iconPath = @(
    (Join-Path $PSScriptRoot 'app-icon.ico'),
    (Join-Path $PSScriptRoot 'assets\android-social-suite.ico')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (Test-Path -LiteralPath $iconPath) {
    $script:Form.Icon = [Drawing.Icon]::new($iconPath)
}
$brandImagePath = @(
    (Join-Path $PSScriptRoot 'app-icon.png'),
    (Join-Path $PSScriptRoot 'assets\android-social-suite-icon.png')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($brandImagePath) { $script:BrandBitmap = [Drawing.Image]::FromFile($brandImagePath) }

$brand = [Windows.Forms.PictureBox]::new()
$brand.Location = [Drawing.Point]::new(28, 18)
$brand.Size = [Drawing.Size]::new(48, 48)
$brand.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
if ($script:BrandBitmap) { $brand.Image = $script:BrandBitmap }
$script:Form.Controls.Add($brand)

$title = [Windows.Forms.Label]::new()
$title.Text = 'Android Social Suite'
$title.Font = [Drawing.Font]::new('Bahnschrift SemiBold', 19)
$title.ForeColor = [Drawing.Color]::FromArgb(15, 35, 58)
$title.Location = [Drawing.Point]::new(88, 16)
$title.AutoSize = $true
$script:Form.Controls.Add($title)

$subtitle = [Windows.Forms.Label]::new()
$subtitle.Text = 'Virtual Device Manager'
$subtitle.Font = [Drawing.Font]::new('Segoe UI', 10)
$subtitle.ForeColor = [Drawing.Color]::FromArgb(91, 108, 126)
$subtitle.Location = [Drawing.Point]::new(91, 50)
$subtitle.AutoSize = $true
$script:Form.Controls.Add($subtitle)

$headerLine = [Windows.Forms.Panel]::new()
$headerLine.Location = [Drawing.Point]::new(0, 78)
$headerLine.Size = [Drawing.Size]::new(1180, 1)
$headerLine.Anchor = 'Top,Left,Right'
$headerLine.BackColor = [Drawing.Color]::FromArgb(224, 228, 231)
$script:Form.Controls.Add($headerLine)

$buttonSpecs = @(
    @{ Text = 'Create Phone'; X = 24; W = 158; Action = { New-Phone }; Kind = 'Primary' },
    @{ Text = 'Start'; X = 194; W = 96; Action = { Start-Phone }; Kind = 'Success' },
    @{ Text = 'Stop'; X = 302; W = 96; Action = { Stop-Phone }; Kind = 'Neutral' },
    @{ Text = 'Delete'; X = 410; W = 96; Action = { Delete-Phone }; Kind = 'Danger' },
    @{ Text = 'Set Proxy'; X = 518; W = 126; Action = { Set-VlessForPhone }; Kind = 'Neutral' },
    @{ Text = 'Clear Proxy'; X = 656; W = 126; Action = { Clear-VlessForPhone }; Kind = 'Neutral' },
    @{ Text = 'Test All'; X = 794; W = 116; Action = { Test-PhoneProxy }; Kind = 'Accent' },
    @{ Text = 'Refresh'; X = 922; W = 108; Action = { Update-AvdList }; Kind = 'Neutral' }
)
foreach ($spec in $buttonSpecs) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $spec.Text
    $button.Location = [Drawing.Point]::new($spec.X, 92)
    $button.Size = [Drawing.Size]::new($spec.W, 44)
    $button.Anchor = 'Top,Left'
    $button.Font = [Drawing.Font]::new('Segoe UI Semibold', 9.5)
    $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    switch ($spec.Kind) {
        'Primary' {
            $button.BackColor = [Drawing.Color]::FromArgb(5, 134, 181)
            $button.ForeColor = [Drawing.Color]::White
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(5, 134, 181)
        }
        'Success' {
            $button.BackColor = [Drawing.Color]::FromArgb(8, 166, 151)
            $button.ForeColor = [Drawing.Color]::White
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(8, 166, 151)
        }
        'Danger' {
            $button.BackColor = [Drawing.Color]::FromArgb(255, 246, 244)
            $button.ForeColor = [Drawing.Color]::FromArgb(194, 48, 42)
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(241, 199, 194)
        }
        'Accent' {
            $button.BackColor = [Drawing.Color]::FromArgb(244, 250, 255)
            $button.ForeColor = [Drawing.Color]::FromArgb(4, 112, 166)
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(137, 199, 231)
        }
        default {
            $button.BackColor = [Drawing.Color]::FromArgb(253, 253, 252)
            $button.ForeColor = [Drawing.Color]::FromArgb(25, 49, 74)
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(205, 214, 221)
        }
    }
    $button.Add_Click($spec.Action)
    $script:Form.Controls.Add($button)
    switch ($spec.Text) {
        'Start' { $script:StartButton = $button }
        'Stop' { $script:StopButton = $button }
        'Delete' { $script:DeleteButton = $button }
        'Set Proxy' { $script:SetProxyButton = $button }
        'Clear Proxy' { $script:ClearProxyButton = $button }
    }
}

$galleryTitle = [Windows.Forms.Label]::new()
$galleryTitle.Text = 'Device Gallery'
$galleryTitle.Font = [Drawing.Font]::new('Bahnschrift SemiBold', 20)
$galleryTitle.ForeColor = [Drawing.Color]::FromArgb(15, 35, 58)
$galleryTitle.Location = [Drawing.Point]::new(24, 153)
$galleryTitle.AutoSize = $true
$script:Form.Controls.Add($galleryTitle)

$gallerySubtitle = [Windows.Forms.Label]::new()
$gallerySubtitle.Text = 'Android virtual phones ready for your social media work.'
$gallerySubtitle.Font = [Drawing.Font]::new('Segoe UI', 9.5)
$gallerySubtitle.ForeColor = [Drawing.Color]::FromArgb(91, 108, 126)
$gallerySubtitle.Location = [Drawing.Point]::new(27, 184)
$gallerySubtitle.AutoSize = $true
$script:Form.Controls.Add($gallerySubtitle)

$script:AvdList = [Windows.Forms.ListView]::new()
$script:AvdList.Location = [Drawing.Point]::new(24, 216)
$script:AvdList.Size = [Drawing.Size]::new(1132, 300)
$script:AvdList.Anchor = 'Top,Bottom,Left,Right'
$script:AvdList.View = [Windows.Forms.View]::Tile
$script:AvdList.TileSize = [Drawing.Size]::new(1090, 132)
$script:AvdList.FullRowSelect = $true
$script:AvdList.MultiSelect = $false
$script:AvdList.GridLines = $false
$script:AvdList.HeaderStyle = [Windows.Forms.ColumnHeaderStyle]::None
$script:AvdList.BorderStyle = [Windows.Forms.BorderStyle]::None
$script:AvdList.BackColor = [Drawing.Color]::FromArgb(250, 249, 247)
$script:AvdList.HideSelection = $false
$script:AvdList.OwnerDraw = $true
$script:AvdList.Font = [Drawing.Font]::new('Segoe UI', 10)
[void]$script:AvdList.Columns.Add('Name', 275)
[void]$script:AvdList.Columns.Add('Status', 120)
[void]$script:AvdList.Columns.Add('Proxy', 180)
[void]$script:AvdList.Columns.Add('Hardware profile', 245)
[void]$script:AvdList.Columns.Add('Latency', 245)
$doubleBuffered = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
$doubleBuffered.SetValue($script:AvdList, $true, $null)
$script:AvdList.Add_DrawItem({
    param($sender, $eventArgs)
    $graphics = $eventArgs.Graphics
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $bounds = [Drawing.RectangleF]::new($eventArgs.Bounds.X + 2, $eventArgs.Bounds.Y + 3, $eventArgs.Bounds.Width - 8, $eventArgs.Bounds.Height - 8)
    $selected = ($eventArgs.State -band [Windows.Forms.ListViewItemStates]::Selected) -ne 0
    $background = if ($selected) { [Drawing.Color]::FromArgb(239, 249, 252) } else { [Drawing.Color]::FromArgb(255, 255, 254) }
    $border = if ($selected) { [Drawing.Color]::FromArgb(7, 143, 197) } else { [Drawing.Color]::FromArgb(214, 223, 229) }
    $path = New-RoundedRectanglePath $bounds 10
    $fill = [Drawing.SolidBrush]::new($background)
    $pen = [Drawing.Pen]::new($border, $(if ($selected) { 2 } else { 1 }))
    try {
        $graphics.FillPath($fill, $path)
        $graphics.DrawPath($pen, $path)
        if ($selected) {
            $accent = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(7, 143, 197))
            try { $graphics.FillRectangle($accent, [Drawing.RectangleF]::new($bounds.X, $bounds.Y + 18, 4, $bounds.Height - 36)) } finally { $accent.Dispose() }
        }
        if ($script:BrandBitmap) { $graphics.DrawImage($script:BrandBitmap, [Drawing.RectangleF]::new($bounds.X + 24, $bounds.Y + 28, 68, 68)) }
        $item = $eventArgs.Item
        $name = $item.Text
        $status = if ($item.SubItems.Count -gt 1) { $item.SubItems[1].Text } else { 'Stopped' }
        $proxy = if ($item.SubItems.Count -gt 2) { $item.SubItems[2].Text } else { 'Not assigned' }
        $profile = if ($item.SubItems.Count -gt 3) { $item.SubItems[3].Text } else { 'Existing profile' }
        $latency = if ($item.SubItems.Count -gt 4) { $item.SubItems[4].Text } else { 'Not tested' }
        $nameX = [int]($bounds.X + 118)
        [Windows.Forms.TextRenderer]::DrawText($graphics, $name, [Drawing.Font]::new('Bahnschrift SemiBold', 14), [Drawing.Point]::new($nameX, [int]($bounds.Y + 18)), [Drawing.Color]::FromArgb(15, 35, 58))
        $statusColor = if ($status -eq 'Running') { [Drawing.Color]::FromArgb(0, 126, 94) } else { [Drawing.Color]::FromArgb(194, 48, 42) }
        $statusBack = if ($status -eq 'Running') { [Drawing.Color]::FromArgb(226, 246, 238) } else { [Drawing.Color]::FromArgb(255, 232, 229) }
        $statusRect = [Drawing.RectangleF]::new($nameX, $bounds.Y + 55, 104, 30)
        $statusPath = New-RoundedRectanglePath $statusRect 14
        $statusBrush = [Drawing.SolidBrush]::new($statusBack)
        try { $graphics.FillPath($statusBrush, $statusPath) } finally { $statusBrush.Dispose(); $statusPath.Dispose() }
        [Windows.Forms.TextRenderer]::DrawText($graphics, $status, [Drawing.Font]::new('Segoe UI Semibold', 9), [Drawing.Rectangle]::new($nameX + 10, [int]($bounds.Y + 61), 86, 20), $statusColor, [Windows.Forms.TextFormatFlags]::HorizontalCenter)
        $available = $bounds.Width - 340
        $proxyX = [int]($bounds.X + 330)
        $profileX = [int]($bounds.X + 330 + ($available * 0.34))
        $latencyX = [int]($bounds.X + 330 + ($available * 0.68))
        foreach ($field in @(
            @{ X = $proxyX; Label = 'Proxy'; Value = $proxy },
            @{ X = $profileX; Label = 'Hardware profile'; Value = $profile },
            @{ X = $latencyX; Label = 'Latency'; Value = $latency }
        )) {
            [Windows.Forms.TextRenderer]::DrawText($graphics, $field.Label, [Drawing.Font]::new('Segoe UI', 8.5), [Drawing.Point]::new($field.X, [int]($bounds.Y + 37)), [Drawing.Color]::FromArgb(91, 108, 126))
            [Windows.Forms.TextRenderer]::DrawText($graphics, [string]$field.Value, [Drawing.Font]::new('Segoe UI Semibold', 10), [Drawing.Rectangle]::new($field.X, [int]($bounds.Y + 60), 230, 28), [Drawing.Color]::FromArgb(22, 43, 66), [Windows.Forms.TextFormatFlags]::EndEllipsis)
        }
    } finally {
        $fill.Dispose()
        $pen.Dispose()
        $path.Dispose()
    }
})
$script:AvdList.Add_Resize({
    if ($script:AvdList.ClientSize.Width -gt 100) { $script:AvdList.TileSize = [Drawing.Size]::new($script:AvdList.ClientSize.Width - 26, 132) }
})
$script:AvdList.Add_SelectedIndexChanged({ Sync-ActionStates; $script:AvdList.Invalidate() })
$script:Form.Controls.Add($script:AvdList)

$script:SummaryLabel = [Windows.Forms.Label]::new()
$script:SummaryLabel.Location = [Drawing.Point]::new(24, 730)
$script:SummaryLabel.Size = [Drawing.Size]::new(430, 22)
$script:SummaryLabel.Anchor = 'Bottom,Left,Right'
$script:SummaryLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$script:SummaryLabel.ForeColor = [Drawing.Color]::FromArgb(83, 101, 119)
$script:Form.Controls.Add($script:SummaryLabel)

$dropPanel = [Windows.Forms.Panel]::new()
$dropPanel.Location = [Drawing.Point]::new(24, 540)
$dropPanel.Size = [Drawing.Size]::new(1132, 130)
$dropPanel.Anchor = 'Bottom,Left,Right'
$dropPanel.BackColor = [Drawing.Color]::FromArgb(245, 250, 253)
$dropPanel.BorderStyle = [Windows.Forms.BorderStyle]::None
$dropPanel.AllowDrop = $true
$dropPanel.Add_Paint({
    param($sender, $eventArgs)
    $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(126, 190, 225), 1.5)
    $pen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash
    try { $eventArgs.Graphics.DrawRectangle($pen, 1, 1, $sender.Width - 3, $sender.Height - 3) } finally { $pen.Dispose() }
})
$dropLabel = [Windows.Forms.Label]::new()
$dropLabel.Text = "Drop images, videos, or APKs here`r`nMedia is added to the AndroidSocialSuite album"
$dropLabel.Font = [Drawing.Font]::new('Segoe UI Semibold', 11)
$dropLabel.ForeColor = [Drawing.Color]::FromArgb(24, 59, 87)
$dropLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$dropLabel.Location = [Drawing.Point]::new(4, 4)
$dropLabel.Size = [Drawing.Size]::new($dropPanel.ClientSize.Width - 8, $dropPanel.ClientSize.Height - 8)
$dropLabel.Anchor = 'Top,Bottom,Left,Right'
$dropLabel.BackColor = $dropPanel.BackColor
$dropLabel.AllowDrop = $true
$dropPanel.Controls.Add($dropLabel)
$script:Form.Controls.Add($dropPanel)

$mediaDragEnter = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $paths = [string[]]$eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        $hasSupportedFile = @($paths | Where-Object {
            ($script:MediaExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant()) -or
            ($script:ApkExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant())
        }).Count -gt 0
        $eventArgs.Effect = if ($hasSupportedFile) { [Windows.Forms.DragDropEffects]::Copy } else { [Windows.Forms.DragDropEffects]::None }
    }
}
$mediaDragDrop = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        Handle-DroppedFiles ([string[]]$eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    }
}
$dropPanel.Add_DragEnter($mediaDragEnter)
$dropPanel.Add_DragDrop($mediaDragDrop)
$dropLabel.Add_DragEnter($mediaDragEnter)
$dropLabel.Add_DragDrop($mediaDragDrop)

$autoTestLabel = [Windows.Forms.Label]::new()
$autoTestLabel.Text = 'Automatic latency testing runs every 5 minutes.'
$autoTestLabel.Location = [Drawing.Point]::new(24, 686)
$autoTestLabel.Size = [Drawing.Size]::new(1132, 22)
$autoTestLabel.Anchor = 'Bottom,Left,Right'
$autoTestLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$autoTestLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$autoTestLabel.ForeColor = [Drawing.Color]::FromArgb(102, 120, 139)
$script:Form.Controls.Add($autoTestLabel)

$script:StatusLabel = [Windows.Forms.Label]::new()
$script:StatusLabel.Text = 'Ready'
$script:StatusLabel.Location = [Drawing.Point]::new(470, 730)
$script:StatusLabel.Size = [Drawing.Size]::new(686, 22)
$script:StatusLabel.Anchor = 'Bottom,Left,Right'
$script:StatusLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(0, 119, 91)
$script:StatusLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$script:Form.Controls.Add($script:StatusLabel)

$script:AvdList.Add_DoubleClick({ Start-Phone })
$script:Form.Add_Shown({
    try { Update-AvdList; Sync-LatencyUi; Sync-ActionStates; Sync-EmulatorWindowPlacement }
    catch { Set-Status 'Device status will refresh automatically.' }
})
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 4000
$timer.Add_Tick({
    try { Update-AvdList; Initialize-RunningDevices; Sync-EmulatorWindowPlacement }
    catch {
        if ($_.Exception.Message -notmatch '(?i)error:\s*(closed|offline)|device.*not found') {
            Set-Status 'Device status will refresh automatically.'
        }
    }
})
$timer.Start()
$script:Form.Add_FormClosed({ $script:AutoLatencyTimer.Stop() })
if ($CapturePreview) {
    Update-AvdList
    Sync-LatencyUi
    $script:Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $script:Form.Location = [Drawing.Point]::new(-32000, -32000)
    $script:Form.Show()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
    [Windows.Forms.Application]::DoEvents()
    $previewBitmap = [Drawing.Bitmap]::new($script:Form.Width, $script:Form.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $script:Form.DrawToBitmap($previewBitmap, [Drawing.Rectangle]::new(0, 0, $script:Form.Width, $script:Form.Height))
        $previewBitmap.Save([IO.Path]::GetFullPath($CapturePreview), [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $previewBitmap.Dispose()
        $script:Form.Close()
    }
} else {
    [void]$script:Form.ShowDialog()
}
$timer.Stop()
$timer.Dispose()
$script:AutoLatencyTimer.Stop()
$script:AutoLatencyTimer.Dispose()
