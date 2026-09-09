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

function Test-ArchiveFile {
    param(
        [string]$Path,
        [pscustomobject]$Archive
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        (Get-FileHash -LiteralPath $Path -Algorithm $Archive.HashType).Hash.ToUpperInvariant() -eq $Archive.Checksum
    } catch { $false }
}

function Invoke-ResumableDownload {
    param(
        [pscustomobject]$Archive,
        [string]$Destination,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $partialPath = $Destination + '.partial'
    [void](New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force)
    if (Test-ArchiveFile $Destination $Archive) { return }
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Delete($Destination) }
    if (Test-ArchiveFile $partialPath $Archive) {
        [IO.File]::Move($partialPath, $Destination)
        return
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $response = $null
        $inputStream = $null
        $outputStream = $null
        try {
            $existingLength = if (Test-Path -LiteralPath $partialPath) { (Get-Item -LiteralPath $partialPath).Length } else { 0L }
            $request = [Net.HttpWebRequest]::Create($Archive.Url)
            $request.Method = 'GET'
            $request.UserAgent = 'Android-Social-Suite'
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            if ($existingLength -gt 0) { $request.AddRange($existingLength) }

            $response = [Net.HttpWebResponse]$request.GetResponse()
            $isPartial = $response.StatusCode -eq [Net.HttpStatusCode]::PartialContent
            if ($existingLength -gt 0 -and -not $isPartial) {
                $response.Dispose()
                $response = $null
                [IO.File]::Delete($partialPath)
                throw 'The download server did not accept the resume request; restarting this package.'
            }

            $mode = if ($existingLength -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
            $outputStream = [IO.File]::Open($partialPath, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $inputStream = $response.GetResponseStream()
            $totalLength = if ($response.ContentLength -gt 0) { $existingLength + $response.ContentLength } else { 0L }
            $downloaded = $existingLength
            $buffer = New-Object byte[] 1048576
            $lastUiUpdate = [DateTime]::UtcNow.AddSeconds(-1)
            while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outputStream.Write($buffer, 0, $read)
                $downloaded += $read
                if (([DateTime]::UtcNow - $lastUiUpdate).TotalMilliseconds -ge 250) {
                    if ($StatusLabel) {
                        if ($totalLength -gt 0) {
                            $percent = [Math]::Min(100, [Math]::Round(($downloaded * 100.0) / $totalLength))
                            $StatusLabel.Text = 'Downloading {0}: {1:N1} / {2:N1} MB ({3}%), attempt {4}/5' -f $Archive.PackagePath, ($downloaded / 1MB), ($totalLength / 1MB), $percent, $attempt
                        } else {
                            $StatusLabel.Text = 'Downloading {0}: {1:N1} MB, attempt {2}/5' -f $Archive.PackagePath, ($downloaded / 1MB), $attempt
                        }
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                    $lastUiUpdate = [DateTime]::UtcNow
                }
            }
            $outputStream.Flush()
            $outputStream.Dispose()
            $outputStream = $null
            $inputStream.Dispose()
            $inputStream = $null
            $response.Dispose()
            $response = $null

            if (-not (Test-ArchiveFile $partialPath $Archive)) {
                [IO.File]::Delete($partialPath)
                throw "Checksum failed for $($Archive.PackagePath)."
            }
            [IO.File]::Move($partialPath, $Destination)
            return
        } catch {
            $lastError = $_.Exception
            if ($attempt -lt 5) {
                if ($StatusLabel) { $StatusLabel.Text = "Download interrupted. Retrying $($Archive.PackagePath) ($($attempt + 1)/5)..." }
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt - 1)))
            }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
    throw "Download failed after 5 attempts for $($Archive.PackagePath). Partial data was kept for the next run. $($lastError.Message)"
}

function Move-DirectoryPortable {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source directory does not exist: $Source"
    }
    if (Test-Path -LiteralPath $Destination) {
        [IO.Directory]::Delete($Destination, $true)
    }

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach ($directory in Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Force) {
        $relativePath = $directory.FullName.Substring($sourceRoot.Length).TrimStart('\')
        [void](New-Item -ItemType Directory -Path (Join-Path $Destination $relativePath) -Force)
    }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force) {
        $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $targetPath = Join-Path $Destination $relativePath
        [void](New-Item -ItemType Directory -Path (Split-Path $targetPath -Parent) -Force)
        [IO.File]::Copy($file.FullName, $targetPath, $true)
    }
    [IO.Directory]::Delete($sourceRoot, $true)
}

function Install-Archive {
    param(
        [pscustomobject]$Archive,
        [string]$ExpectedFolder,
        [string]$Destination,
        [string]$WorkRoot,
        [string]$CacheRoot,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $safeName = ($Archive.PackagePath -replace '[^A-Za-z0-9_-]', '_')
    $zipPath = Join-Path $CacheRoot ($safeName + '.zip')
    $extractPath = Join-Path $WorkRoot ($safeName + '-extract')

    Invoke-ResumableDownload -Archive $Archive -Destination $zipPath -StatusLabel $StatusLabel

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
    if (Test-Path -LiteralPath $Destination) {
        [IO.Directory]::Delete($Destination, $true)
    }
    Move-DirectoryPortable -Source $source -Destination $Destination
}

function Get-AndroidEnvironmentState {
    param([string]$Root)

    $sdkRoot = Join-Path $Root 'android-sdk'
    [pscustomobject]@{
        Emulator = Test-Path -LiteralPath (Join-Path $sdkRoot 'emulator\emulator.exe') -PathType Leaf
        PlatformTools = Test-Path -LiteralPath (Join-Path $sdkRoot 'platform-tools\adb.exe') -PathType Leaf
        SystemImage = Test-Path -LiteralPath (Join-Path $sdkRoot 'system-images\android-34\google_apis_playstore\x86_64\system.img') -PathType Leaf
        Template = Test-Path -LiteralPath (Join-Path $Root 'android-avd\social_template.avd\config.ini') -PathType Leaf
    }
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
        Move-DirectoryPortable -Source $extractPath -Destination $destination
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

function Install-ApplicationEntryPoints {
    param([string]$Root)

    $sourceExe = $env:ANDROID_SOCIAL_LAUNCHER_EXE
    if ([string]::IsNullOrWhiteSpace($sourceExe) -or -not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
        return
    }

    try {
        $installedExe = Join-Path $Root 'AndroidSocialSuite.exe'
        $sourceFullPath = [IO.Path]::GetFullPath($sourceExe)
        $installedFullPath = [IO.Path]::GetFullPath($installedExe)
        if (-not $sourceFullPath.Equals($installedFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            $needsCopy = (-not (Test-Path -LiteralPath $installedFullPath -PathType Leaf)) -or
                ((Get-FileHash -LiteralPath $sourceFullPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $installedFullPath -Algorithm SHA256).Hash)
            if ($needsCopy) { Copy-Item -LiteralPath $sourceFullPath -Destination $installedFullPath -Force }
        }

        $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        $programs = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::StartMenu)) 'Programs'
        [void](New-Item -ItemType Directory -Path $programs -Force)
        $shell = New-Object -ComObject WScript.Shell
        foreach ($shortcutPath in @(
            (Join-Path $desktop 'Android Social Suite.lnk'),
            (Join-Path $programs 'Android Social Suite.lnk')
        )) {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $installedFullPath
            $shortcut.WorkingDirectory = $Root
            $shortcut.IconLocation = "$installedFullPath,0"
            $shortcut.Description = 'Open Android Social Suite virtual device manager'
            $shortcut.Save()
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    } catch {
        Show-SuiteMessage "Android Social Suite is installed, but Windows could not create its shortcuts.`r`n`r`nYou can still open it from:`r`n$(Join-Path $Root 'AndroidSocialSuite.exe')`r`n`r`n$($_.Exception.Message)" ([System.Windows.Forms.MessageBoxIcon]::Warning)
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

    $state = Get-AndroidEnvironmentState $Root
    $missing = [Collections.Generic.List[string]]::new()
    if (-not $state.Emulator) { $missing.Add('Android Emulator') }
    if (-not $state.PlatformTools) { $missing.Add('Platform Tools') }
    if (-not $state.SystemImage) { $missing.Add('Android 14 Google Play image') }
    if (-not $state.Template) { $missing.Add('device template') }
    if ($missing.Count -eq 0) { return }

    $downloadNotice = if ($missing.Count -eq 1 -and $missing[0] -eq 'device template') {
        'No large download is required.'
    } else {
        'Only missing Android components will be downloaded. Existing SDK files, phones, apps, media, and proxy bindings will be reused.'
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Android Social Suite needs to install or repair: $($missing -join ', ').`r`n`r`nInstall location: $Root`r`n$downloadNotice`r`n`r`nBy selecting Yes, you confirm that you have reviewed and accept the Android SDK License Agreement:`r`n$($script:TermsUrl)",
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
        $cacheRoot = Join-Path $Root 'download-cache'
        [void](New-Item -ItemType Directory -Path $cacheRoot -Force)

        $sdkRoot = Join-Path $Root 'android-sdk'
        if (-not $state.Emulator -or -not $state.PlatformTools) {
            $label.Text = 'Reading Google package metadata...'
            [System.Windows.Forms.Application]::DoEvents()
        }
        if (-not $state.Emulator) {
            $emulator = Get-ArchiveInfo $script:RepositoryUrl 'emulator' $script:RepositoryBaseUrl -WindowsOnly
            $label.Text = 'Downloading and installing Android Emulator...'
            [System.Windows.Forms.Application]::DoEvents()
            Install-Archive -Archive $emulator -ExpectedFolder 'emulator' -Destination (Join-Path $sdkRoot 'emulator') -WorkRoot $workRoot -CacheRoot $cacheRoot -StatusLabel $label
        }
        if (-not $state.PlatformTools) {
            $platformTools = Get-ArchiveInfo $script:RepositoryUrl 'platform-tools' $script:RepositoryBaseUrl -WindowsOnly
            $label.Text = 'Downloading and installing Platform Tools...'
            [System.Windows.Forms.Application]::DoEvents()
            Install-Archive -Archive $platformTools -ExpectedFolder 'platform-tools' -Destination (Join-Path $sdkRoot 'platform-tools') -WorkRoot $workRoot -CacheRoot $cacheRoot -StatusLabel $label
        }
        if (-not $state.SystemImage) {
            $label.Text = 'Reading Android system image metadata...'
            [System.Windows.Forms.Application]::DoEvents()
            $systemImage = Get-ArchiveInfo $script:SystemImageRepositoryUrl $script:SystemImagePackage $script:SystemImageBaseUrl
            $label.Text = 'Downloading Android 14 Google Play image. This is the largest step...'
            [System.Windows.Forms.Application]::DoEvents()
            Install-Archive -Archive $systemImage -ExpectedFolder 'x86_64' -Destination (Join-Path $sdkRoot 'system-images\android-34\google_apis_playstore\x86_64') -WorkRoot $workRoot -CacheRoot $cacheRoot -StatusLabel $label
        }
        if (-not $state.Template) {
            $label.Text = 'Creating the protected device template...'
            [System.Windows.Forms.Application]::DoEvents()
            New-BaseAvd $Root 'social_template'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'android-avd\social_phone_01.ini'))) {
            New-BaseAvd $Root 'social_phone_01'
        }
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
    $environmentState = Get-AndroidEnvironmentState $root
    if (-not ($environmentState.Emulator -and $environmentState.PlatformTools -and $environmentState.SystemImage -and $environmentState.Template)) {
        Install-AndroidEnvironment $root
    }

    Install-XrayCore $root
    Install-ApplicationEntryPoints $root

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
