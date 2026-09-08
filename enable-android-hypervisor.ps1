$ErrorActionPreference = "Stop"

$resultPath = Join-Path $PSScriptRoot "android-hypervisor-result.json"
$logPath = Join-Path $PSScriptRoot "android-hypervisor-setup.log"
$restartNeeded = $false

Start-Transcript -Path $logPath -Force | Out-Null

try {
    $featureNames = @("HypervisorPlatform", "VirtualMachinePlatform")

    foreach ($featureName in $featureNames) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
        if ($feature.State -ne "Enabled") {
            $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart
            if ($enableResult.RestartNeeded) {
                $restartNeeded = $true
            }
        }
    }

    & bcdedit.exe /set hypervisorlaunchtype auto | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit failed with exit code $LASTEXITCODE"
    }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions, VMMonitorModeExtensions
    $features = foreach ($featureName in $featureNames) {
        Get-WindowsOptionalFeature -Online -FeatureName $featureName | Select-Object FeatureName, State
    }

    [pscustomobject]@{
        Success = $true
        RestartNeeded = $restartNeeded
        Cpu = $cpu
        Features = $features
        CompletedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $resultPath -Encoding UTF8
}
catch {
    [pscustomobject]@{
        Success = $false
        Error = $_.Exception.Message
        CompletedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $resultPath -Encoding UTF8
    throw
}
finally {
    Stop-Transcript | Out-Null
}
