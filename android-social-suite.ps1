param(
    [switch]$SelfTest,
    [string]$SelfTestMarker
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ProductName = 'Android Social Suite'
$script:MinimumFreeBytes = 24GB
$script:RepositoryUrl = 'https://dl.google.com/android/repository/repository2-3.xml'
$script:SystemImageRepositoryUrl = 'https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml'
$script:RepositoryBaseUrl = 'https://dl.google.com/android/repository/'
$script:SystemImageBaseUrl = 'https://dl.google.com/android/repository/sys-img/google_apis_playstore/'
$script:SystemImagePackage = 'system-images;android-34;google_apis_playstore;x86_64'
$script:TermsUrl = 'https://developer.android.com/studio/terms'

if ($env:ANDROID_SOCIAL_SELFTEST -eq '1') {
    $SelfTest = $true
}

function Show-SuiteMessage {
    param(
        [string]$Text,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    [void][System.Windows.Forms.MessageBox]::Show(
        $Text,
        $script:ProductName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    )
}

function Get-InstallRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SOCIAL_HOME)) {
        return [IO.Path]::GetFullPath($env:ANDROID_SOCIAL_HOME)
    }

    $knownRoot = 'D:\AndroidSocialPhones'
    if (Test-Path -LiteralPath (Join-Path $knownRoot 'android-sdk\emulator\emulator.exe')) {
        return $knownRoot
    }

    $drive = [IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [IO.DriveType]::Fixed -and $_.IsReady } |
        Sort-Object AvailableFreeSpace -Descending |
        Select-Object -First 1

    if (-not $drive) {
        throw 'No writable fixed drive was found.'
    }

    Join-Path $drive.RootDirectory.FullName 'AndroidSocialPhones'
}

function Get-ArchiveInfo {
    param(
        [string]$RepositoryUrl,
        [string]$PackagePath,
        [string]$BaseUrl,
        [switch]$WindowsOnly
    )

    [xml]$repository = (Invoke-WebRequest -UseBasicParsing -Uri $RepositoryUrl).Content
    $package = @($repository.SelectNodes("//*[local-name()='remotePackage']")) |
        Where-Object { $_.GetAttribute('path') -eq $PackagePath } |
        Select-Object -First 1

    if (-not $package) {
        throw "Google repository does not contain package: $PackagePath"
    }

    $selected = $null
    foreach ($archive in @($package.SelectNodes(".//*[local-name()='archive']"))) {
        $hostNode = $archive.SelectSingleNode("./*[local-name()='host-os']")
        if ($WindowsOnly -and $hostNode -and $hostNode.InnerText -ne 'windows') { continue }
        if ($WindowsOnly -and -not $hostNode) { continue }
        $complete = $archive.SelectSingleNode("./*[local-name()='complete']")
        if ($complete) {
            $selected = $complete
            break
        }
    }

    if (-not $selected) {
        throw "No compatible archive was found for package: $PackagePath"
    }

    $urlNode = $selected.SelectSingleNode("./*[local-name()='url']")
    $checksumNode = $selected.SelectSingleNode("./*[local-name()='checksum']")
    if (-not $urlNode -or -not $checksumNode) {
        throw "Google repository metadata is incomplete for package: $PackagePath"
    }

    [pscustomobject]@{
        PackagePath = $PackagePath
        Url = $BaseUrl + $urlNode.InnerText
        Checksum = $checksumNode.InnerText.Trim().ToUpperInvariant()
        HashType = $checksumNode.GetAttribute('type').ToUpperInvariant()
    }
}

function Install-Archive {
    param(
        [pscustomobject]$Archive,
        [string]$ExpectedFolder,
        [string]$Destination,
        [string]$WorkRoot
    )

    $safeName = ($Archive.PackagePath -replace '[^A-Za-z0-9_-]', '_')
    $zipPath = Join-Path $WorkRoot ($safeName + '.zip')
    $extractPath = Join-Path $WorkRoot ($safeName + '-extract')

    Invoke-WebRequest -UseBasicParsing -Uri $Archive.Url -OutFile $zipPath
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm $Archive.HashType).Hash.ToUpperInvariant()
    if ($actualHash -ne $Archive.Checksum) {
        throw "Checksum failed for $($Archive.PackagePath)."
    }

    [void](New-Item -ItemType Directory -Path $extractPath -Force)
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $source = Join-Path $extractPath $ExpectedFolder
    if (-not (Test-Path -LiteralPath $source)) {
        $source = Get-ChildItem -LiteralPath $extractPath -Directory -Recurse -Filter $ExpectedFolder |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $source) {
        throw "Downloaded package has an unexpected layout: $($Archive.PackagePath)"
    }

    $parent = Split-Path $Destination -Parent
    [void](New-Item -ItemType Directory -Path $parent -Force)
    [IO.Directory]::Move($source, $Destination)
}

function Install-XrayCore {
    param([string]$Root)

    $destination = Join-Path $Root 'xray-core'
    $xrayExe = Join-Path $destination 'xray.exe'
    $embeddedXray = Join-Path $PSScriptRoot 'xray.exe'
    $embeddedLicense = Join-Path $PSScriptRoot 'XRAY-LICENSE.txt'
    if (Test-Path -LiteralPath $embeddedXray) {
        [void](New-Item -ItemType Directory -Path $destination -Force)
        $needsCopy = (-not (Test-Path -LiteralPath $xrayExe)) -or ((Get-FileHash -LiteralPath $embeddedXray -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $xrayExe -Algorithm SHA256).Hash)
        if ($needsCopy) { Copy-Item -LiteralPath $embeddedXray -Destination $xrayExe -Force }
        if (Test-Path -LiteralPath $embeddedLicense) { Copy-Item -LiteralPath $embeddedLicense -Destination (Join-Path $destination 'LICENSE.txt') -Force }
        return
    }
    if (Test-Path -LiteralPath $xrayExe) { return }

    $workRoot = Join-Path $env:TEMP ('AndroidSocialXray-' + [Guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $workRoot 'Xray-windows-64.zip'
    $extractPath = Join-Path $workRoot 'extract'
    try {
        [void](New-Item -ItemType Directory -Path $workRoot -Force)
        [void](New-Item -ItemType Directory -Path $extractPath -Force)
        $headers = @{ 'User-Agent' = 'Android-Social-Suite' }
        $release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
        $asset = @($release.assets | Where-Object { $_.name -eq 'Xray-windows-64.zip' }) | Select-Object -First 1
        if (-not $asset) { throw 'The official Xray Windows 64-bit package was not found.' }
        Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $asset.browser_download_url -OutFile $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        if (-not (Test-Path -LiteralPath (Join-Path $extractPath 'xray.exe'))) {
            throw 'The official Xray package has an unexpected layout.'
        }
        if (Test-Path -LiteralPath $destination) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $destination,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::DeletePermanently,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
            )
        }
        [IO.Directory]::Move($extractPath, $destination)
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $workRoot,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::DeletePermanently,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
            )
        }
    }
}

function New-BaseAvd {
    param(
        [string]$Root,
        [string]$Name
    )

    $avdRoot = Join-Path $Root 'android-avd'
    $sdkRoot = Join-Path $Root 'android-sdk'
    $avdDirectory = Join-Path $avdRoot ($Name + '.avd')
    $pointerPath = Join-Path $avdRoot ($Name + '.ini')
    $imageDirectory = Join-Path $sdkRoot 'system-images\android-34\google_apis_playstore\x86_64\'
    $escapedImageDirectory = $imageDirectory.Replace('\', '\\')
    [void](New-Item -ItemType Directory -Path $avdDirectory -Force)

    $config = @"
PlayStore.enabled = yes
abi.type = x86_64
avd.id = $Name
avd.ini.displayname = $Name
avd.ini.encoding = UTF-8
avd.name = $Name
disk.cachePartition = yes
disk.cachePartition.size = 66MB
disk.dataPartition.size = 6442450944
fastboot.forceColdBoot = yes
fastboot.forceFastBoot = no
hw.accelerometer = yes
hw.audioInput = yes
hw.audioOutput = yes
hw.battery = yes
hw.camera.back = emulated
hw.camera.front = none
hw.cpu.arch = x86_64
hw.cpu.ncore = 2
hw.device.manufacturer = Google
hw.device.name = pixel_7
hw.gps = yes
hw.gpu.enabled = yes
hw.gpu.mode = auto
hw.gyroscope = yes
hw.initialOrientation = portrait
hw.keyboard = yes
hw.keyboard.charmap = qwerty2
hw.lcd.density = 420
hw.lcd.height = 2400
hw.lcd.width = 1080
hw.mainKeys = no
hw.ramSize = 1536M
hw.screen = multi-touch
hw.sdCard = yes
image.sysdir.1 = $escapedImageDirectory
runtime.network.latency = none
runtime.network.speed = full
sdcard.size = 512 MB
showDeviceFrame = yes
tag.display = Google Play
tag.id = google_apis_playstore
vm.heapSize = 228M
"@

    [IO.File]::WriteAllText(
        (Join-Path $avdDirectory 'config.ini'),
        $config,
        [Text.UTF8Encoding]::new($false)
    )
    $pointer = "avd.ini.encoding=UTF-8`r`npath=$avdDirectory`r`ntarget=android-34`r`n"
    [IO.File]::WriteAllText($pointerPath, $pointer, [Text.UTF8Encoding]::new($false))
}

function Install-AndroidEnvironment {
    param([string]$Root)

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'A 64-bit Windows installation is required.'
    }

    $rootDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Root))
    if ($rootDrive.AvailableFreeSpace -lt $script:MinimumFreeBytes) {
        throw ('At least 24 GB of free space is required on {0}. Available: {1:N1} GB.' -f $rootDrive.Name, ($rootDrive.AvailableFreeSpace / 1GB))
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "First-time setup downloads Android Emulator, Platform Tools, and an Android 14 Google Play system image directly from Google.`r`n`r`nInstall location: $Root`r`nExpected download: several GB`r`n`r`nBy selecting Yes, you confirm that you have reviewed and accept the Android SDK License Agreement:`r`n$($script:TermsUrl)",
        $script:ProductName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        exit 0
    }

    $progress = [System.Windows.Forms.Form]::new()
    $progress.Text = $script:ProductName
    $progress.StartPosition = 'CenterScreen'
    $progress.ClientSize = [Drawing.Size]::new(540, 130)
    $progress.FormBorderStyle = 'FixedDialog'
    $progress.ControlBox = $false
    $label = [System.Windows.Forms.Label]::new()
    $label.Location = [Drawing.Point]::new(22, 22)
    $label.Size = [Drawing.Size]::new(495, 42)
    $label.Text = 'Preparing the Android runtime...'
    $bar = [System.Windows.Forms.ProgressBar]::new()
    $bar.Location = [Drawing.Point]::new(22, 78)
    $bar.Size = [Drawing.Size]::new(495, 22)
    $bar.Style = 'Marquee'
    $progress.Controls.Add($label)
    $progress.Controls.Add($bar)
    $progress.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $workRoot = Join-Path $env:TEMP ('AndroidSocialSuite-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $Root -Force)
        [void](New-Item -ItemType Directory -Path $workRoot -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $Root 'android-sdk') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $Root 'android-avd') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $Root 'emulator-home') -Force)

        $label.Text = 'Reading Google package metadata...'
        [System.Windows.Forms.Application]::DoEvents()
        $emulator = Get-ArchiveInfo $script:RepositoryUrl 'emulator' $script:RepositoryBaseUrl -WindowsOnly
        $platformTools = Get-ArchiveInfo $script:RepositoryUrl 'platform-tools' $script:RepositoryBaseUrl -WindowsOnly
        $systemImage = Get-ArchiveInfo $script:SystemImageRepositoryUrl $script:SystemImagePackage $script:SystemImageBaseUrl

        $sdkRoot = Join-Path $Root 'android-sdk'
        $label.Text = 'Downloading and installing Android Emulator...'
        [System.Windows.Forms.Application]::DoEvents()
        Install-Archive $emulator 'emulator' (Join-Path $sdkRoot 'emulator') $workRoot

        $label.Text = 'Downloading and installing Platform Tools...'
        [System.Windows.Forms.Application]::DoEvents()
        Install-Archive $platformTools 'platform-tools' (Join-Path $sdkRoot 'platform-tools') $workRoot

        $label.Text = 'Downloading Android 14 Google Play image. This is the largest step...'
        [System.Windows.Forms.Application]::DoEvents()
        Install-Archive $systemImage 'x86_64' (Join-Path $sdkRoot 'system-images\android-34\google_apis_playstore\x86_64') $workRoot

        $label.Text = 'Creating the protected template and first phone...'
        [System.Windows.Forms.Application]::DoEvents()
        New-BaseAvd $Root 'social_template'
        New-BaseAvd $Root 'social_phone_01'
    }
    finally {
        $progress.Close()
        $progress.Dispose()
        if (Test-Path -LiteralPath $workRoot) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $workRoot,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::DeletePermanently,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
            )
        }
    }

    Show-SuiteMessage 'Installation completed. The phone manager will open now.'
}

try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $root = Get-InstallRoot
    $emulatorExe = Join-Path $root 'android-sdk\emulator\emulator.exe'
    if (-not (Test-Path -LiteralPath $emulatorExe)) {
        Install-AndroidEnvironment $root
    }

    Install-XrayCore $root

    $env:ANDROID_SOCIAL_HOME = $root
    $managerPath = Join-Path $PSScriptRoot 'android-avd-manager.ps1'
    if (-not (Test-Path -LiteralPath $managerPath)) {
        throw 'The embedded manager component is missing.'
    }

    if ($SelfTest) {
        & $managerPath -SelfTest
        if ($LASTEXITCODE -ne 0) {
            throw 'Embedded manager self-test failed.'
        }
        $markerPath = if ($SelfTestMarker) { $SelfTestMarker } else { $env:ANDROID_SOCIAL_SELFTEST_MARKER }
        if ($markerPath) {
            [IO.File]::WriteAllText(
                $markerPath,
                (Get-Date).ToString('o'),
                [Text.UTF8Encoding]::new($false)
            )
        }
    } else {
        & $managerPath
    }
}
catch {
    Show-SuiteMessage $_.Exception.Message ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
