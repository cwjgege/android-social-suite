param(
    [switch]$SelfTest,
    [string]$CapturePreview,
    [switch]$Maintenance,
    [string]$SnapshotPath,
    [switch]$MeasureLatency,
    [string]$AdbJobName,
    [int]$OwnerPid = 0,
    [long]$OwnerStartTicks = 0
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
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr handle, int info, IntPtr buffer, int size, out int needed);

    public static string ReadCommandLine(int pid) {
        IntPtr handle = OpenProcess(0x1000, false, pid);
        if (handle == IntPtr.Zero) return null;
        IntPtr buffer = IntPtr.Zero;
        try {
            int needed;
            NtQueryInformationProcess(handle, 60, IntPtr.Zero, 0, out needed);
            if (needed <= 0) return null;
            buffer = Marshal.AllocHGlobal(needed);
            if (NtQueryInformationProcess(handle, 60, buffer, needed, out needed) != 0) return null;
            int length = (ushort)Marshal.ReadInt16(buffer);
            IntPtr text = Marshal.ReadIntPtr(buffer, IntPtr.Size == 8 ? 8 : 4);
            return Marshal.PtrToStringUni(text, length / 2);
        } finally {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            CloseHandle(handle);
        }
    }

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

public sealed class OwnedAdbJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    private IntPtr handle;
    public OwnedAdbJob(string name) {
        handle=CreateJobObject(IntPtr.Zero,name);
        if(handle==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        // Kill explicitly assigned clients only. Children, including the shared
        // ADB server, are permitted to leave this job automatically.
        ExtendedLimits limits=new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags=0x2000 | 0x1000;
        if(!SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
            int error=Marshal.GetLastWin32Error(); Dispose();
            throw new System.ComponentModel.Win32Exception(error);
        }
    }
    public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle);handle=IntPtr.Zero; } }
    private static string Quote(string value) {
        StringBuilder result=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='\"') { result.Append('\\',slashes*2+1);result.Append(c);slashes=0;continue; }
            result.Append('\\',slashes);slashes=0;result.Append(c);
        }
        result.Append('\\',slashes*2);result.Append('"');return result.ToString();
    }
    private static bool OwnerAlive(int pid, long ticks) {
        if(pid<=0) return true;
        try { using(System.Diagnostics.Process p=System.Diagnostics.Process.GetProcessById(pid)) {
            return !p.HasExited && p.StartTime.ToUniversalTime().Ticks==ticks;
        }} catch { return false; }
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
        public ushort showWindow, reservedSize;
        public IntPtr reservedBytes, standardInput, standardOutput, standardError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx { public StartupInfo startup; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr process, thread; public uint processId, threadId; }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnedSize);
    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CreateProcessW")]
    private static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);


    [StructLayout(LayoutKind.Sequential)]
    private struct JobAccounting {
        public long TotalUserTime, TotalKernelTime, PeriodUserTime, PeriodKernelTime;
        public uint TotalPageFaults, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, out JobAccounting info, uint length, IntPtr returnedLength);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    public string LastCleanupError { get; private set; }
    private uint ActiveClients() {
        JobAccounting info;
        if(!QueryInformationJobObject(handle,1,out info,(uint)Marshal.SizeOf(typeof(JobAccounting)),IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return info.ActiveProcesses;
    }
    public bool StopClients(int timeoutMs) {
        LastCleanupError="";
        if(handle==IntPtr.Zero) return true;
        try {
            if(ActiveClients()==0) return true;
            bool requested=TerminateJobObject(handle,1);
            int error=requested ? 0 : Marshal.GetLastWin32Error();
            if(!requested) {
                if(ActiveClients()==0) return true; // Exit raced with termination.
                LastCleanupError="Job termination failed (Win32 "+error+").";
                return false;
            }
            var watch=System.Diagnostics.Stopwatch.StartNew();
            while(ActiveClients()!=0) {
                if(watch.ElapsedMilliseconds>=timeoutMs) {
                    LastCleanupError="Owned ADB clients have not exited; cleanup remains pending.";
                    return false;
                }
                System.Threading.Thread.Sleep(20);
            }
            return true;
        } catch(Exception exception) {
            LastCleanupError="Cannot confirm ADB cleanup: "+exception.Message;
            return false;
        }
    }
    private static string ConfirmProcessExit(IntPtr process, int timeoutMs) {
        uint state=WaitForSingleObject(process,0);
        if(state==0) return null;
        if(state!=0x102) return "Process exit check failed (Win32 "+Marshal.GetLastWin32Error()+").";
        bool requested=TerminateProcess(process,1);
        int error=requested ? 0 : Marshal.GetLastWin32Error();
        state=WaitForSingleObject(process,(uint)timeoutMs);
        if(state==0) return null; // Also handles a normal exit racing with termination.
        if(state!=0x102) return "Process exit wait failed (Win32 "+Marshal.GetLastWin32Error()+").";
        return requested ? "ADB termination was requested but exit is still pending." : "ADB termination failed (Win32 "+error+"); exit is still pending.";
    }

    public OwnedAdbResult Run(string file, string[] args, int timeoutMs, int ownerPid, long ownerTicks) {
        if(!OwnerAlive(ownerPid,ownerTicks)) throw new OperationCanceledException("Manager closed.");
        if(handle==IntPtr.Zero) throw new ObjectDisposedException("OwnedAdbJob");
        if(!StopClients(2000)) throw new InvalidOperationException(LastCleanupError+" No new ADB client was started.");
        StringBuilder command=new StringBuilder(Quote(file));
        foreach(string arg in args) command.Append(' ').Append(Quote(arg));
        using(var input=new System.IO.Pipes.AnonymousPipeServerStream(System.IO.Pipes.PipeDirection.Out,System.IO.HandleInheritability.Inheritable))
        using(var outputPipe=new System.IO.Pipes.AnonymousPipeServerStream(System.IO.Pipes.PipeDirection.In,System.IO.HandleInheritability.Inheritable))
        using(var errorPipe=new System.IO.Pipes.AnonymousPipeServerStream(System.IO.Pipes.PipeDirection.In,System.IO.HandleInheritability.Inheritable)) {
            StartupInfoEx startup=new StartupInfoEx();
            startup.startup.cb=Marshal.SizeOf(typeof(StartupInfoEx));
            startup.startup.flags=0x100; // STARTF_USESTDHANDLES
            var inputClient=input.ClientSafePipeHandle;
            var outputClient=outputPipe.ClientSafePipeHandle;
            var errorClient=errorPipe.ClientSafePipeHandle;
            startup.startup.standardInput=inputClient.DangerousGetHandle();
            startup.startup.standardOutput=outputClient.DangerousGetHandle();
            startup.startup.standardError=errorClient.DangerousGetHandle();
            IntPtr listSize=IntPtr.Zero, jobValue=IntPtr.Zero, inherited=IntPtr.Zero;
            bool initialized=false;
            ProcessInformation process=new ProcessInformation();
            Exception commandFailure=null;
            string cleanupFailure=null;
            try {
                InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref listSize);
                if(listSize==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                startup.attributes=Marshal.AllocHGlobal(listSize);
                if(!InitializeProcThreadAttributeList(startup.attributes,2,0,ref listSize)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                initialized=true;
                jobValue=Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobValue,handle);
                // Assign before any child code runs. Never fall back to an unowned launch.
                if(!UpdateProcThreadAttribute(startup.attributes,0,new IntPtr(0x2000d),jobValue,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                inherited=Marshal.AllocHGlobal(3*IntPtr.Size);
                Marshal.WriteIntPtr(inherited,0,startup.startup.standardInput);
                Marshal.WriteIntPtr(inherited,IntPtr.Size,startup.startup.standardOutput);
                Marshal.WriteIntPtr(inherited,2*IntPtr.Size,startup.startup.standardError);
                if(!UpdateProcThreadAttribute(startup.attributes,0,new IntPtr(0x20002),inherited,new IntPtr(3*IntPtr.Size),IntPtr.Zero,IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                if(!OwnerAlive(ownerPid,ownerTicks)) throw new OperationCanceledException("Manager closed.");
                if(!CreateProcess(file,command,IntPtr.Zero,IntPtr.Zero,true,0x08080000,IntPtr.Zero,null,ref startup,out process)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                CloseHandle(process.thread); process.thread=IntPtr.Zero;
                input.DisposeLocalCopyOfClientHandle();
                outputPipe.DisposeLocalCopyOfClientHandle();
                errorPipe.DisposeLocalCopyOfClientHandle();
                input.Dispose(); // ADB is non-interactive: provide EOF on stdin.
                using(var output=new System.IO.StreamReader(outputPipe,System.Text.Encoding.UTF8))
                using(var error=new System.IO.StreamReader(errorPipe,System.Text.Encoding.UTF8)) {
                    var outputTask=output.ReadToEndAsync();
                    var errorTask=error.ReadToEndAsync();
                    var watch=System.Diagnostics.Stopwatch.StartNew();
                    try {
                        while(true) {
                            uint state=WaitForSingleObject(process.process,100);
                            if(state==0) break;
                            if(state!=0x102) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                            if(!OwnerAlive(ownerPid,ownerTicks)) throw new OperationCanceledException("Manager closed.");
                            if(watch.ElapsedMilliseconds>=timeoutMs) throw new TimeoutException("ADB command timed out after "+(timeoutMs/1000)+" seconds.");
                        }
                        if(!System.Threading.Tasks.Task.WaitAll(new System.Threading.Tasks.Task[]{outputTask,errorTask},2000)) throw new TimeoutException("ADB output did not close.");
                        uint exitCode;
                        if(!GetExitCodeProcess(process.process,out exitCode)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                        return new OwnedAdbResult { ExitCode=unchecked((int)exitCode), Output=outputTask.Result, Error=errorTask.Result };
                    } finally {
                        // Terminate before disposing redirected streams, including timeout paths.
                        cleanupFailure=ConfirmProcessExit(process.process,2000);
                    }
                }
            } catch(Exception exception) {
                commandFailure=exception;
                throw;
            } finally {
                // Exposed client handles are not owned by the outer pipe Dispose.
                // SafeHandle.Dispose is idempotent after the successful-launch cleanup.
                inputClient.Dispose();
                outputClient.Dispose();
                errorClient.Dispose();
                if(process.thread!=IntPtr.Zero) CloseHandle(process.thread);
                if(process.process!=IntPtr.Zero) {
                    cleanupFailure=ConfirmProcessExit(process.process,2000);
                    // The job retains ownership even after this handle is closed.
                    // Run refuses to create another client while that job is non-empty.
                    CloseHandle(process.process);
                }
                if(initialized) DeleteProcThreadAttributeList(startup.attributes);
                if(startup.attributes!=IntPtr.Zero) Marshal.FreeHGlobal(startup.attributes);
                if(jobValue!=IntPtr.Zero) Marshal.FreeHGlobal(jobValue);
                if(inherited!=IntPtr.Zero) Marshal.FreeHGlobal(inherited);
                if(cleanupFailure!=null) {
                    LastCleanupError=cleanupFailure;
                    throw new InvalidOperationException(cleanupFailure+" The client remains owned by its job; new commands are blocked until cleanup completes.",commandFailure);
                }
            }
        }
    }
}

public static class HostResourceNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryStatus {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    public static MemoryStatus GetMemory() {
        MemoryStatus status=new MemoryStatus();
        status.Length=(uint)Marshal.SizeOf(typeof(MemoryStatus));
        if(!GlobalMemoryStatusEx(ref status)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return status;
    }
}

public sealed class OwnedAdbResult {
    public int ExitCode;
    public string Output, Error;
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
$script:TunnelApk = @(
    (Join-Path $PSScriptRoot 'vendor\android-vpn\android-social-tunnel.apk'),
    (Join-Path $PSScriptRoot 'android-social-tunnel.apk')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$script:TunnelPackage = 'com.android.socialsuite.vpn'
$script:TunnelReceiver = 'com.android.socialsuite.vpn/.TunnelControlReceiver'
$script:TunnelVersionCode = 15
$script:AdbKey = Join-Path $env:USERPROFILE '.android\adbkey'
$script:TemplateName = 'social_template'
$script:SharedProxyPort = 10808
$script:ProxyPortStart = 18081
$script:ProxyPortEnd = 18180
$script:RuntimePolicy = [ordered]@{
    'hw.gpu.enabled' = 'yes'
    'hw.gpu.mode' = 'host'
    'fastboot.forceColdBoot' = 'yes'
    'fastboot.forceFastBoot' = 'no'
    'fastboot.forceChosenSnapshotBoot' = 'no'
}
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

function Invoke-OwnedAdb {
    $arguments = [string[]]@($args)
    if (-not $script:OwnedAdbJob) {
        $jobName = if ($Maintenance -and $AdbJobName) { $AdbJobName } else { 'Local\AndroidSocialAdb-' + [Guid]::NewGuid().ToString('N') }
        $script:OwnedAdbJob = [OwnedAdbJob]::new($jobName)
    }
    $timeout = if ($arguments -contains 'install' -or $arguments -contains 'push') { 120000 } else { 12000 }
    $result = $script:OwnedAdbJob.Run($script:AdbExe, $arguments, $timeout, $OwnerPid, $OwnerStartTicks)
    $global:LASTEXITCODE = $result.ExitCode
    $text = $result.Output
    if ($result.ExitCode -ne 0 -and $result.Error) { $text += $result.Error }
    if ($text) { $text.TrimEnd() -split '\r?\n' }
}

function Stop-BackgroundMaintenance {
    if ($script:MaintenanceProcess) {
        if (-not $script:MaintenanceProcess.HasExited) {
            $script:MaintenanceProcess.Kill()
            if (-not $script:MaintenanceProcess.WaitForExit(2000)) { throw 'Background task has not exited; no replacement task will be started.' }
        }
        $script:MaintenanceProcess.Dispose()
        $script:MaintenanceProcess = $null
    }
    if ($script:SnapshotFile -and (Test-Path -LiteralPath $script:SnapshotFile)) {
        try { [IO.File]::Delete($script:SnapshotFile) } catch { }
    }
    if ($script:BackgroundAdbJob) {
        if (-not $script:BackgroundAdbJob.StopClients(2000)) {
            throw ($script:BackgroundAdbJob.LastCleanupError + ' The existing job is retained; no replacement task will be started.')
        }
        $script:BackgroundAdbJob.Dispose()
        $script:BackgroundAdbJob = $null
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


function Get-ManagerOwnerTag {
    if (-not $script:ManagerOwnerTag) {
        $identity = [IO.Path]::GetFullPath($script:AvdRoot).TrimEnd('\').ToLowerInvariant()
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $script:ManagerOwnerTag = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-', '').Substring(0, 32).ToLowerInvariant() }
        finally { $hash.Dispose() }
    }
    $script:ManagerOwnerTag
}

function Get-ScaledDisplayProfile {
    param($Profile, [int]$ShortEdge = 0)
    $width = [int]$Profile.Width
    $height = [int]$Profile.Height
    $density = [int]$Profile.Density
    if ($width -le 0 -or $height -le 0 -or $density -le 0 -or $ShortEdge -lt 0) { throw 'Invalid display profile.' }
    $scale = if ($ShortEdge -eq 0) { 1.0 } else { [Math]::Min(1.0, $ShortEdge / [double][Math]::Min($width, $height)) }
    [pscustomobject]@{
        Width = $(if ($scale -eq 1.0) { $width } else { [Math]::Max(2, [int]([Math]::Round($width * $scale / 2) * 2)) })
        Height = $(if ($scale -eq 1.0) { $height } else { [Math]::Max(2, [int]([Math]::Round($height * $scale / 2) * 2)) })
        Density = [Math]::Max(120, [int][Math]::Round($density * $scale))
    }
}

function Get-PhoneResourceProfile {
    param([string]$Name)
    $config = [IO.File]::ReadAllText((Join-Path $script:AvdRoot ($Name + '.avd\config.ini')))
    $ram = 1536.0
    $cores = 2
    $estimated = $false
    if ($config -match '(?m)^hw\.ramSize\s*=\s*(\d+)\s*([MG]?)\s*$') {
        $ram = [double]$Matches[1]
        if ($Matches[2] -eq 'G') { $ram *= 1024 }
    } else { $estimated = $true }
    if ($config -match '(?m)^hw\.cpu\.ncore\s*=\s*(\d+)\s*$') { $cores = [int]$Matches[1] } else { $estimated = $true }
    if ($ram -le 0 -or $cores -le 0) { throw "Invalid resource settings for $Name." }
    [pscustomobject]@{ Name=$Name; RamMb=$ram; Cores=$cores; Estimated=$estimated }
}

function Confirm-PhoneResourceBudget {
    param([string]$Name, [hashtable]$Running)
    $warnings = [Collections.Generic.List[string]]::new()
    $candidate = Get-PhoneResourceProfile $Name
    $ramMb = $candidate.RamMb
    $cores = $candidate.Cores
    $count = 1
    foreach ($existing in Get-AvdNames) {
        if ($existing -eq $Name -or -not $Running.ContainsKey($existing)) { continue }
        $profile = Get-PhoneResourceProfile $existing
        $ramMb += $profile.RamMb
        $cores += $profile.Cores
        $count++
        if ($profile.Estimated) { $warnings.Add("$existing has incomplete resource settings; its budget is estimated.") }
    }
    if ($candidate.Estimated) { $warnings.Add('The selected phone has incomplete resource settings; its budget is estimated.') }
    try {
        $memory = [HostResourceNative]::GetMemory()
        $totalMb = $memory.TotalPhysical / 1MB
        $availableMb = $memory.AvailablePhysical / 1MB
        $reserveMb = [Math]::Max(3072, $totalMb * 0.20)
        $deviceOverheadMb = 1024
        if ($ramMb + $count * $deviceOverheadMb + $reserveMb -gt $totalMb) {
            $warnings.Add(('Configured guest RAM ({0:N1} GB), estimated emulator overhead and Windows reserve exceed {1:N1} GB of physical RAM.' -f ($ramMb/1024), ($totalMb/1024)))
        }
        if ($candidate.RamMb + $deviceOverheadMb + 2048 -gt $availableMb) {
            $warnings.Add(('Only {0:N1} GB is currently available; starting this {1:N1} GB phone may cause paging.' -f ($availableMb/1024), ($candidate.RamMb/1024)))
        }
    } catch { $warnings.Add('Available Windows memory could not be read. Check Task Manager before starting another phone.') }
    $logicalCores = [Environment]::ProcessorCount
    if ($cores -gt [Math]::Max(1, $logicalCores - 2)) {
        $warnings.Add("These phones request $cores vCPUs on a host with $logicalCores logical processors; simultaneous load may cause contention.")
    }
    if ($warnings.Count -eq 0) { return $true }
    $message = ($warnings -join "\n\n").Replace('\n', [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine + 'These are conservative estimates, not reserved RAM or CPU. Existing settings will not be changed. Start anyway?'
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, $message, 'Resource budget warning', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning, [Windows.Forms.MessageBoxDefaultButton]::Button2)
    return $answer -eq [Windows.Forms.DialogResult]::Yes
}

function Set-PhoneRuntimePolicy {
    param([string]$Name)
    if ((Get-RunningAvds).ContainsKey($Name)) { throw 'The phone is already running. Runtime settings were not changed.' }
    $dir = Join-Path $script:AvdRoot ($Name + '.avd')
    $path = Join-Path $dir 'config.ini'
    $original = [IO.File]::ReadAllText($path)
    $config = $original
    foreach ($entry in $script:RuntimePolicy.GetEnumerator()) {
        $pattern = '(?m)^' + [Regex]::Escape($entry.Key) + '\s*=.*$'
        $line = $entry.Key + ' = ' + $entry.Value
        if ($config -match $pattern) { $config = $config -replace $pattern, $line }
        else { $config = $config.TrimEnd() + [Environment]::NewLine + $line + [Environment]::NewLine }
    }
    if ($config -ceq $original) { return }
    $temp = Join-Path $dir ('runtime-policy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $config, [Text.UTF8Encoding]::new($false))
        if ((Get-RunningAvds).ContainsKey($Name)) { throw 'The phone started while its settings were being prepared.' }
        if ([IO.File]::ReadAllText($path) -cne $original) { throw 'Configuration changed. Retry without editing it concurrently.' }
        [IO.File]::Replace($temp, $path, (Join-Path $dir 'config.ini.before-runtime-policy.bak'))
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}

function Get-AvdProcesses {
    param([string]$Name)
    foreach ($process in @(Get-Process -Name 'qemu-system-x86_64', 'emulator' -ErrorAction SilentlyContinue)) {
        $commandLine = [EmulatorWindowNative]::ReadCommandLine($process.Id)
        if (-not $commandLine) {
            if (-not $process.HasExited) { throw 'Cannot identify an emulator process. Close its window or retry with the same Windows user.' }
            continue
        }
        if ($commandLine -match '(?:^|\s)-avd\s+"?([^"\s]+)') {
            $deviceName = $Matches[1]
            if (-not $Name -or $deviceName -eq $Name) {
                [pscustomobject]@{ Name = $deviceName; Process = $process }
            }
        }
    }
}

function Get-RunningAvds {
    param([switch]$Cached)
    if ($Cached -and $script:Form -and -not $Maintenance) { return $script:RunningSnapshot }
    $running = @{}
    try {
        foreach ($entry in Get-AvdProcesses) {
            $running[$entry.Name] = $true
        }
    } catch {
        foreach ($name in Get-AvdNames) {
            $avdDirectory = Join-Path $script:AvdRoot ($name + '.avd')
            if ([EmulatorWindowNative]::FindEmulator($name) -ne [IntPtr]::Zero) {
                $running[$name] = $true
                continue
            }
            # Lock files can survive shutdown. Check live file ownership instead.
            $files = @(Get-ChildItem -LiteralPath $avdDirectory -File -ErrorAction Stop | Where-Object {
                $_.Name -like '*.lock' -or $_.Name -like 'userdata-qemu.img*' -or
                $_.Name -like 'cache.img*' -or $_.Name -eq 'sdcard.img'
            })
            foreach ($file in $files) {
                $probe = $null
                try {
                    $probe = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                } catch [IO.IOException] {
                    $code = $_.Exception.HResult -band 0xffff
                    if ($code -in @(32, 33)) { $running[$name] = $true; break }
                    if ($code -notin @(2, 3)) { throw }
                } finally {
                    if ($probe) { $probe.Dispose() }
                }
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
    $running = Get-RunningAvds -Cached
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
        inbounds = @(
            [ordered]@{
                tag = 'android-socks-in'
                listen = '127.0.0.1'
                port = $Port
                protocol = 'socks'
                settings = [ordered]@{ auth = 'noauth'; udp = $true; ip = '127.0.0.1' }
            },
            [ordered]@{
                tag = 'proxy-test-http-in'
                listen = '127.0.0.1'
                port = ($Port + 1000)
                protocol = 'http'
                settings = [ordered]@{ timeout = 30 }
            }
        )
        outbounds = @($Outbound, [ordered]@{ tag = 'blocked'; protocol = 'blackhole' })
        routing = [ordered]@{ domainStrategy = 'AsIs'; rules = @([ordered]@{ type = 'field'; inboundTag = @('android-socks-in', 'proxy-test-http-in'); outboundTag = 'proxy-out' }) }
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
    if ($value -match '^vless://') {
        $vlessConfig = New-XrayConfigObject $value $Port
        return New-ProxyEnvelope $vlessConfig.outbounds[0] $Port
    }

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
        foreach ($process in @(Get-Process -Name xray -ErrorAction SilentlyContinue)) {
            $commandLine = [EmulatorWindowNative]::ReadCommandLine($process.Id)
            if ($commandLine -and $commandLine.IndexOf(('"' + $configPath + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return [pscustomobject]@{ ProcessId = $process.Id }
            }
        }
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
    $configJson = $null
    if ($owned -and (Test-TcpPort $port)) {
        $activeConfig = [IO.File]::ReadAllText((Get-XrayConfigPath $Name)) | ConvertFrom-Json
        $socks = @($activeConfig.inbounds | Where-Object { $_.protocol -eq 'socks' -and $_.port -eq $port })
        if ($socks.Count -gt 0) { return $port }
        $legacy = @($activeConfig.inbounds | Where-Object { $_.protocol -eq 'http' -and $_.port -eq $port })
        if ($legacy.Count -ne 1) { throw 'The active proxy configuration needs to be saved again with Set Proxy.' }
        $legacy[0].port = $port + 1000
        $legacyTag = [string]$legacy[0].tag
        $activeConfig.inbounds = @($activeConfig.inbounds) + @([pscustomobject]@{
            tag = 'android-vpn-socks'; listen = '127.0.0.1'; port = $port; protocol = 'socks'
            settings = @{ auth = 'noauth'; udp = $true; ip = '127.0.0.1' }
        })
        foreach ($rule in $activeConfig.routing.rules) {
            if ($rule.inboundTag -and $legacyTag -in $rule.inboundTag) {
                $rule.inboundTag = @($rule.inboundTag) + @('android-vpn-socks')
            }
        }
        $configJson = ConvertTo-Json -InputObject $activeConfig -Depth 24
        Test-XrayConfig $configJson
        Stop-Process -Id $owned.ProcessId -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 200
    }
    if (Test-TcpPort $port) { throw "Local port $port is occupied by another program." }

    $xray = Get-XrayExe
    if (-not $xray) { throw 'Xray core is missing. Reopen AndroidSocialSuite.exe to install it.' }
    if (-not $configJson) {
        $vlessUri = Unprotect-Secret $binding.encryptedUri
        $configJson = New-XrayConfigJson $vlessUri $port
    }
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

function Clear-AndroidSystemProxy {
    param([string]$Serial)
    $commands = @('settings put global http_proxy :0')
    foreach ($key in @('http_proxy', 'global_http_proxy_host', 'global_http_proxy_port', 'global_http_proxy_exclusion_list', 'global_proxy_pac_url', 'proxy_pac_url')) {
        $commands += "settings delete global $key"
    }
    Invoke-OwnedAdb -s $Serial shell ($commands -join ' && ') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to clear the legacy Android proxy settings.' }
}

function Invoke-DeviceTunnelControl {
    param(
        [string]$Serial,
        [ValidateSet('CONNECT', 'DISCONNECT', 'STATUS')][string]$Action,
        [int]$Port = 0
    )
    $arguments = @('-s', $Serial, 'shell', 'am', 'broadcast', '--receiver-foreground', '-a', "com.android.socialsuite.vpn.$Action", '-n', $script:TunnelReceiver)
    if ($Action -eq 'CONNECT') {
        $arguments += @('--es', 'socks_host', '127.0.0.1', '--ei', 'socks_port', [string]$Port)
    }
    (Invoke-OwnedAdb @arguments 2>&1 | Out-String).Trim()
}

function Ensure-DeviceTunnel {
    param([string]$Serial, [string]$Name, [int]$Port)
    if (-not (Test-Path -LiteralPath $script:TunnelApk -PathType Leaf)) {
        throw 'The embedded Android VPN component is missing. Reinstall Android Social Suite.'
    }

    $packageInfo = (Invoke-OwnedAdb -s $Serial shell dumpsys package $script:TunnelPackage 2>$null | Out-String)
    $installedVersion = 0
    if ($packageInfo -match '\bversionCode=(\d+)\b') { $installedVersion = [int]$Matches[1] }
    if ($installedVersion -lt $script:TunnelVersionCode) {
        Set-Status "Installing the managed VPN component on $Name..."
        $installOutput = (Invoke-OwnedAdb -s $Serial install -r -g $script:TunnelApk 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $installOutput -notmatch 'Success') {
            throw "VPN upgrade failed; existing component preserved: $($installOutput.Trim())"
        }
    }

    Invoke-OwnedAdb -s $Serial shell appops set $script:TunnelPackage ACTIVATE_VPN allow 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to authorize the Android VPN service.' }
    Clear-AndroidSystemProxy $Serial
    $reverseList = (Invoke-OwnedAdb -s $Serial reverse --list 2>$null | Out-String)
    if ($reverseList -notmatch ('(?m)\btcp:' + $Port + '\s+tcp:' + $Port + '\s*$')) {
        Invoke-OwnedAdb -s $Serial reverse "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create the private ADB tunnel to Xray.' }
    }
    $currentStatus = Invoke-DeviceTunnelControl $Serial STATUS
    $endpointPattern = 'running=true;host=127\.0\.0\.1;port=' + $Port + ';'
    if ($currentStatus -match $endpointPattern) { return }
    $connectOutput = Invoke-DeviceTunnelControl $Serial CONNECT $Port
    if ($connectOutput -notmatch 'accepted=true') { throw "Unable to start the Android VPN service: $connectOutput" }
    Start-Sleep -Milliseconds 900
    $statusOutput = Invoke-DeviceTunnelControl $Serial STATUS
    if ($statusOutput -notmatch $endpointPattern) { throw "The Android VPN endpoint did not become ready: $statusOutput" }
}

function Stop-DeviceTunnel {
    param([string]$Serial)
    if (-not $Serial) { return }
    [void](Invoke-DeviceTunnelControl $Serial DISCONNECT)
    Invoke-OwnedAdb -s $Serial reverse --remove-all 2>$null | Out-Null
    Clear-AndroidSystemProxy $Serial
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
    $running = Get-RunningAvds -Cached
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
    $managedRunningCount = @((Get-AvdNames) | Where-Object { $running.ContainsKey($_) }).Count
    $summary = '{0} device(s)    {1} running    Resource budget checked on Start' -f $script:AvdList.Items.Count, $managedRunningCount
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
    foreach ($button in @($script:DeleteButton, $script:SetProxyButton, $script:ClearProxyButton, $script:ResolutionButton)) {
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

    if ($script:Form -and -not $Maintenance) {
        $script:LatencyPending = $true
        Set-Status 'Latency test queued. Results will appear in the device cards.'
        return
    }

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
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.ipify.org' -Proxy ("http://127.0.0.1:$($port + 1000)") -TimeoutSec 15
        $proxyWatch.Stop()
        $exitIp = $response.Content.Trim()
        if ($exitIp -notmatch '^[0-9a-fA-F:.]+$') { throw 'The proxy responded, but the exit IP could not be identified.' }
        $tcpText = if ($null -ne $tcpLatency) { "$tcpLatency ms" } else { 'N/A (endpoint unavailable or timed out)' }
        $proxyLatency = [Math]::Round($proxyWatch.Elapsed.TotalMilliseconds)
        Set-PhoneLatencyResult $name "Host TCP $tcpText / HTTPS $proxyLatency ms"
        Set-Status "${name}: host proxy OK, exit $exitIp. Android connectivity and bandwidth not tested."
    } catch {
        $reason = $_.Exception.Message
        if ($reason.Length -gt 42) { $reason = $reason.Substring(0, 39) + '...' }
        Set-PhoneLatencyResult $name "Failed: $reason"
        Set-Status "$name latency test failed: $($_.Exception.Message)"
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

    $dialog.ClientSize = [Drawing.Size]::new(490, 450)

    $ramLabel = [Windows.Forms.Label]::new()
    $ramLabel.Text = 'Memory (RAM)'
    $ramLabel.Location = [Drawing.Point]::new(20, 148)
    $ramLabel.AutoSize = $true
    $ramBox = [Windows.Forms.ComboBox]::new()
    $ramBox.Location = [Drawing.Point]::new(20, 172)
    $ramBox.Size = [Drawing.Size]::new(216, 28)
    $ramBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $ramBox.DisplayMember = 'Label'
    foreach ($option in @(
        [pscustomobject]@{ Label = '2 GB'; Value = 2048 },
        [pscustomobject]@{ Label = '3 GB'; Value = 3072 },
        [pscustomobject]@{ Label = '4 GB'; Value = 4096 },
        [pscustomobject]@{ Label = '6 GB'; Value = 6144 }
    )) { [void]$ramBox.Items.Add($option) }
    $ramBox.SelectedIndex = 0

    $cpuLabel = [Windows.Forms.Label]::new()
    $cpuLabel.Text = 'CPU cores'
    $cpuLabel.Location = [Drawing.Point]::new(254, 148)
    $cpuLabel.AutoSize = $true
    $cpuBox = [Windows.Forms.ComboBox]::new()
    $cpuBox.Location = [Drawing.Point]::new(254, 172)
    $cpuBox.Size = [Drawing.Size]::new(216, 28)
    $cpuBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($option in @('2', '4', '6')) { [void]$cpuBox.Items.Add($option) }
    $cpuBox.SelectedIndex = 0

    $storageLabel = [Windows.Forms.Label]::new()
    $storageLabel.Text = 'Phone storage'
    $storageLabel.Location = [Drawing.Point]::new(20, 212)
    $storageLabel.AutoSize = $true
    $storageBox = [Windows.Forms.ComboBox]::new()
    $storageBox.Location = [Drawing.Point]::new(20, 236)
    $storageBox.Size = [Drawing.Size]::new(450, 28)
    $storageBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $storageBox.DisplayMember = 'Label'
    foreach ($option in @(
        [pscustomobject]@{ Label = '16 GB'; Value = '16G' },
        [pscustomobject]@{ Label = '32 GB (recommended)'; Value = '32G' },
        [pscustomobject]@{ Label = '64 GB'; Value = '64G' },
        [pscustomobject]@{ Label = '128 GB'; Value = '128G' }
    )) { [void]$storageBox.Items.Add($option) }
    $storageBox.SelectedIndex = 1

    $presetLabel = [Windows.Forms.Label]::new()
    $presetLabel.Text = 'Performance preset'
    $presetLabel.Location = [Drawing.Point]::new(20, 278)
    $presetLabel.AutoSize = $true
    $presetBox = [Windows.Forms.ComboBox]::new()
    $presetBox.Location = [Drawing.Point]::new(20, 300)
    $presetBox.Size = [Drawing.Size]::new(450, 28)
    $presetBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$presetBox.Items.Add('Social smooth - 4 GB / 4 cores / 720 short edge')
    [void]$presetBox.Items.Add('Custom - selected model resolution')
    $presetHint = [Windows.Forms.Label]::new()
    $presetHint.Text = 'Smooth mode preserves screen shape and adjusts density.\nExisting phones are unchanged; resource budget is checked on Start.'.Replace('\n', "`r`n")
    $presetHint.Location = [Drawing.Point]::new(20, 337)
    $presetHint.Size = [Drawing.Size]::new(450, 42)
    $presetBox.Add_SelectedIndexChanged({
        $smooth = $presetBox.SelectedIndex -eq 0
        if ($smooth) { $ramBox.SelectedIndex = 2; $cpuBox.SelectedIndex = 1 }
        $ramBox.Enabled = -not $smooth
        $cpuBox.Enabled = -not $smooth
    })
    $presetBox.SelectedIndex = 0

    $ok = [Windows.Forms.Button]::new()
    $ok.Text = 'Create'
    $ok.Location = [Drawing.Point]::new(274, 396)
    $ok.Size = [Drawing.Size]::new(94, 34)
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = 'Cancel'
    $cancel.Location = [Drawing.Point]::new(376, 396)
    $cancel.Size = [Drawing.Size]::new(94, 34)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.AddRange(@($nameLabel, $nameBox, $profileLabel, $profileBox, $ramLabel, $ramBox, $cpuLabel, $cpuBox, $storageLabel, $storageBox, $presetLabel, $presetBox, $presetHint, $ok, $cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    $result = $dialog.ShowDialog($script:Form)
    $details = if ($result -eq [Windows.Forms.DialogResult]::OK) {
        [pscustomobject]@{
            Name = $nameBox.Text.Trim()
            Profile = $profileBox.SelectedItem
            Ram = [int]$ramBox.SelectedItem.Value
            Cores = [int](([string]$cpuBox.SelectedItem -split ' ')[0])
            Storage = [string]$storageBox.SelectedItem.Value
            Smooth = $presetBox.SelectedIndex -eq 0
        }
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
    Invoke-OwnedAdb -s $serial shell mkdir -p $remoteDirectory | Out-Null
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
        Invoke-OwnedAdb -s $serial push $file $remotePath | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed.Add([IO.Path]::GetFileName($file)); continue }
        Invoke-OwnedAdb -s $serial shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d ("file://$remotePath") | Out-Null
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
        $output = Invoke-OwnedAdb -s $serial install -r $apk 2>&1
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

function Set-PhoneResolution {
    $name = Get-SelectedAvd
    if (-not $name -or $name -eq $script:TemplateName) { return }
    $dialog = $null
    $temp = $null
    try {
        if ((Get-RunningAvds).ContainsKey($name)) { throw 'Stop the phone before changing resolution.' }
        $dir = Join-Path $script:AvdRoot ($name + '.avd')
        $path = Join-Path $dir 'config.ini'
        $config = [IO.File]::ReadAllText($path)
        $current = @{}
        foreach ($key in @('hw.lcd.width', 'hw.lcd.height', 'hw.lcd.density')) {
            if ($config -notmatch ('(?m)^' + [Regex]::Escape($key) + '\s*=\s*(\d+)\s*$')) { throw "Missing display setting: $key" }
            $current[$key] = [int]$Matches[1]
            if ($current[$key] -le 0) { throw "Invalid display setting: $key" }
        }
        $originalPath = Join-Path $dir 'android-social-display-original.json'
        if (Test-Path -LiteralPath $originalPath) {
            $original = [IO.File]::ReadAllText($originalPath) | ConvertFrom-Json
        } else {
            $model = $null
            if ($config -match '(?m)^hw\.device\.name\s*=\s*([^\r\n]+)') {
                $deviceName = $Matches[1].Trim()
                $model = $script:DeviceProfiles | Where-Object { $_.DeviceName -eq $deviceName } | Select-Object -First 1
            }
            $original = if ($model) { $model } else { [pscustomobject]@{ Width = $current['hw.lcd.width']; Height = $current['hw.lcd.height']; Density = $current['hw.lcd.density'] } }
        }
        if ([int]$original.Width -le 0 -or [int]$original.Height -le 0 -or [int]$original.Density -le 0) { throw 'Invalid original display profile.' }
        $dialog = [Windows.Forms.Form]::new()
        $dialog.Text = "Resolution - $name"
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = [Drawing.Size]::new(510, 250)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $label = [Windows.Forms.Label]::new()
        $label.Text = "Current: $($current['hw.lcd.width']) x $($current['hw.lcd.height']) / $($current['hw.lcd.density']) dpi"
        $label.Location = [Drawing.Point]::new(20, 20)
        $label.AutoSize = $true
        $box = [Windows.Forms.ComboBox]::new()
        $box.Location = [Drawing.Point]::new(20, 55)
        $box.Size = [Drawing.Size]::new(470, 28)
        $box.DropDownStyle = 'DropDownList'
        $box.DisplayMember = 'Label'
        foreach ($preset in @(@{Name='Smooth';Edge=720}, @{Name='Balanced';Edge=900}, @{Name='HD';Edge=1080}, @{Name='Original profile';Edge=0})) {
            $display = Get-ScaledDisplayProfile $original $preset.Edge
            $w = $display.Width
            $h = $display.Height
            $dpi = $display.Density
            [void]$box.Items.Add([pscustomobject]@{Label="$($preset.Name) - $w x $h ($dpi dpi)";Width=$w;Height=$h;Density=$dpi})
        }
        $box.SelectedIndex = 0
        for ($i=0; $i -lt $box.Items.Count; $i++) {
            $option = $box.Items[$i]
            if ($option.Width -eq $current['hw.lcd.width'] -and $option.Height -eq $current['hw.lcd.height'] -and $option.Density -eq $current['hw.lcd.density']) { $box.SelectedIndex=$i; break }
        }
        $hint = [Windows.Forms.Label]::new()
        $hint.Text = 'Lower resolution reduces rendering load and sharpness. Aspect ratio is preserved and density adjusts automatically. Applies on next start. Apps, files, RAM and CPU are unchanged.'
        $hint.Location = [Drawing.Point]::new(20, 100)
        $hint.Size = [Drawing.Size]::new(470, 75)
        $save = [Windows.Forms.Button]::new()
        $save.Text = 'Save'
        $save.Location = [Drawing.Point]::new(286, 195)
        $save.Size = [Drawing.Size]::new(96, 34)
        $save.DialogResult = 'OK'
        $cancel = [Windows.Forms.Button]::new()
        $cancel.Text = 'Cancel'
        $cancel.Location = [Drawing.Point]::new(394, 195)
        $cancel.Size = [Drawing.Size]::new(96, 34)
        $cancel.DialogResult = 'Cancel'
        $dialog.Controls.AddRange(@($label,$box,$hint,$save,$cancel))
        $dialog.AcceptButton=$save
        $dialog.CancelButton=$cancel
        if ($dialog.ShowDialog($script:Form) -ne [Windows.Forms.DialogResult]::OK) { return }
        if ((Get-RunningAvds).ContainsKey($name)) { throw 'The phone started while settings were open. Stop it and retry.' }
        if ([IO.File]::ReadAllText($path) -cne $config) { throw 'Configuration changed. Reopen this dialog before saving.' }
        $choice=$box.SelectedItem
        $values=@{'hw.lcd.width'=$choice.Width;'hw.lcd.height'=$choice.Height;'hw.lcd.density'=$choice.Density}
        foreach ($entry in $values.GetEnumerator()) {
            $config=$config -replace ('(?m)^'+[Regex]::Escape($entry.Key)+'\s*=.*$'),($entry.Key+' = '+$entry.Value)
        }
        if (-not (Test-Path -LiteralPath $originalPath)) {
            [IO.File]::WriteAllText($originalPath,($original | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        }
        $id=[Guid]::NewGuid().ToString('N')
        $temp=Join-Path $dir ("resolution-$id.tmp")
        $backup=Join-Path $dir ("config.ini.before-resolution-$id.bak")
        [IO.File]::WriteAllText($temp,$config,[Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temp,$path,$backup)
        $temp=$null
        Set-Status "$name resolution saved: $($choice.Width) x $($choice.Height), $($choice.Density) dpi. Applies on next start; original config backed up."
    } catch { Show-Message $_.Exception.Message 'Resolution not saved' ([Windows.Forms.MessageBoxIcon]::Warning) }
    finally {
        if ($dialog) { $dialog.Dispose() }
        if ($temp -and (Test-Path -LiteralPath $temp)) { [IO.File]::Delete($temp) }
    }
}

function Set-PhonePerformanceConfig {
    param([string]$Config, $Details)
    $edge = if ($Details.Smooth) { 720 } else { 0 }
    $display = Get-ScaledDisplayProfile $Details.Profile $edge
    $values = [ordered]@{
        'hw.ramSize' = $Details.Ram
        'hw.cpu.ncore' = $Details.Cores
        'hw.lcd.width' = $display.Width
        'hw.lcd.height' = $display.Height
        'hw.lcd.density' = $display.Density
    }
    foreach ($entry in $script:RuntimePolicy.GetEnumerator()) { $values[$entry.Key] = $entry.Value }
    foreach ($entry in $values.GetEnumerator()) {
        $pattern = '(?m)^' + [Regex]::Escape($entry.Key) + '\s*=.*$'
        $line = $entry.Key + ' = ' + $entry.Value
        if ($Config -match $pattern) { $Config = $Config -replace $pattern, $line }
        else { $Config = $Config.TrimEnd() + "`r`n$line`r`n" }
    }
    return $Config
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
        $config = Set-PhonePerformanceConfig $config $details
        if ($config -match '(?m)^disk\.dataPartition\.size\s*=') {
            $config = $config -replace '(?m)^disk\.dataPartition\.size\s*=.*$', ('disk.dataPartition.size = ' + $details.Storage)
        } else {
            $config = $config.TrimEnd() + "`r`ndisk.dataPartition.size = $($details.Storage)`r`n"
        }
        [IO.File]::WriteAllText((Join-Path $destination 'config.ini'), $config, [Text.UTF8Encoding]::new($false))
        $edge = if ($details.Smooth) { 720 } else { 0 }
        $display = Get-ScaledDisplayProfile $profile $edge
        $originalDisplay = Get-ScaledDisplayProfile $profile
        [IO.File]::WriteAllText((Join-Path $destination 'android-social-display-original.json'), ($originalDisplay | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $profileRecord = [ordered]@{
            label = $profile.Label
            deviceName = $profile.DeviceName
            manufacturer = $profile.Manufacturer
            width = $display.Width
            height = $display.Height
            density = $display.Density
            performancePreset = $(if ($details.Smooth) { 'social-smooth' } else { 'custom' })
            ramMb = $details.Ram
            cpuCores = $details.Cores
            storage = $details.Storage
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
    try {
        if (-not (Confirm-PhoneResourceBudget $name $running)) { return }
        $binding = Get-ProxyBinding $name
        if ($binding) {
            $proxyPort = Start-XrayForAvd $name
            $proxyMode = "dedicated full VPN tunnel on port $proxyPort"
        } elseif (Test-TcpPort $script:SharedProxyPort) {
            $answer = [Windows.Forms.MessageBox]::Show($script:Form, 'No dedicated proxy is assigned. Start with the shared v2rayN proxy on port 10808?', 'Shared proxy fallback', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            $proxyPort = $script:SharedProxyPort
            $proxyMode = 'shared v2rayN proxy'
        } else {
            throw 'No dedicated proxy is assigned and the shared proxy on port 10808 is unavailable.'
        }

        Set-PhoneRuntimePolicy $name
        $ownerTag = Get-ManagerOwnerTag
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $script:EmulatorExe
        $info.Arguments = '-avd "{0}" -no-snapshot -accel on -gpu {1} -no-metrics -prop qemu.social_owner={2}' -f $name, $script:RuntimePolicy['hw.gpu.mode'], $ownerTag
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $false
        $info.EnvironmentVariables['ANDROID_AVD_HOME'] = $script:AvdRoot
        $info.EnvironmentVariables['ANDROID_EMULATOR_HOME'] = $script:EmulatorHome
        $info.EnvironmentVariables['ADB_VENDOR_KEYS'] = $script:AdbKey
        [void][Diagnostics.Process]::Start($info)
        Set-Status "$name is starting with $proxyMode; host GPU requested, cold boot without snapshot writes."
    } catch {
        Stop-XrayForAvd $name
        Show-Message $_.Exception.Message 'Start failed' ([Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Get-DeviceForAvd {
    param([string]$Name)
    foreach ($line in (Invoke-OwnedAdb devices 2>$null)) {
        if ($line -match '^(emulator-\d+)\s+device\s*$') {
            $serial = $Matches[1]
            $avdName = (Invoke-OwnedAdb -s $serial shell getprop ro.boot.qemu.avd_name 2>$null).Trim()
            if ($avdName -eq $Name) { return $serial }
        }
    }
    $null
}

function Stop-Phone {
    $name = Get-SelectedAvd
    if (-not $name -or $name -eq $script:TemplateName) { return }
    if (-not (Get-RunningAvds).ContainsKey($name)) {
        Stop-XrayForAvd $name
        $script:RunningSnapshot.Remove($name)
        Update-AvdList
        Set-Status "$name is stopped. You can now delete it."
        return
    }
    $serial = Get-DeviceForAvd $name
    if (-not $serial) {
        try {
            $targets = @(Get-AvdProcesses -Name $name)
            if ($targets.Count -eq 0) { throw 'No matching emulator process was found. Refresh the device list and retry.' }
            $answer = [Windows.Forms.MessageBox]::Show($script:Form, "$name is not responding through ADB. Force stop this phone? Unsaved changes inside Android may be lost.", 'Stop unresponsive phone', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            foreach ($entry in @(Get-AvdProcesses -Name $name)) {
                if (-not $entry.Process.HasExited) {
                    $entry.Process.Kill()
                    if (-not $entry.Process.WaitForExit(3000)) { throw 'The emulator has not exited yet. Refresh and retry.' }
                }
            }
            Stop-XrayForAvd $name
            $script:RunningSnapshot = Get-RunningAvds
            Update-AvdList
            Set-Status "$name stopped. Its saved device data is preserved."
        } catch { Show-Message $_.Exception.Message 'Stop failed' ([Windows.Forms.MessageBoxIcon]::Error) }
        return
    }
    try {
        Set-Status "Stopping $name safely..."
        Stop-DeviceTunnel $serial
        Invoke-OwnedAdb -s $serial shell reboot -p 2>$null | Out-Null
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
        $managedNames = @{}
        foreach ($managedName in Get-AvdNames) { $managedNames[$managedName] = $true }
        if ($managedNames.Count -eq 0) { return }
        $ownerTag = Get-ManagerOwnerTag
        $devices = @(Invoke-OwnedAdb devices)
        if ($LASTEXITCODE -ne 0) { throw 'ADB device discovery failed.' }
        foreach ($line in $devices) {
            if ($line -notmatch '^(emulator-\d+)\s+device\s*$') { continue }
            $serial = $Matches[1]
            try {
                $identity = @(Invoke-OwnedAdb -s $serial shell 'getprop ro.boot.qemu.avd_name; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id; getprop qemu.social_owner')
                if ($LASTEXITCODE -ne 0 -or $identity.Count -lt 4) { continue }
                $name = $identity[0].Trim()
                if ($name -notmatch '^[A-Za-z0-9_-]+$' -or $name -eq $script:TemplateName -or $identity[1].Trim() -ne '1') { continue }
                if (-not $managedNames.ContainsKey($name)) { continue }
                if ($identity[3].Trim() -cne $ownerTag) {
                    Set-Status "$name background maintenance skipped: restart it from this manager to confirm ownership."
                    continue
                }
                $bootId = $identity[2].Trim()
                $binding = Get-ProxyBinding $name
                if ($binding) { $proxyPort = Start-XrayForAvd $name }
                elseif (Test-TcpPort $script:SharedProxyPort) { $proxyPort = $script:SharedProxyPort }
                else { $proxyPort = 0 }
                $healthPath = Join-Path $script:RuntimeRoot ($name + '-vpn-health.json')
                $key = "$serial/$bootId/$proxyPort/$($script:TunnelVersionCode)"
                $cached = $false
                if (Test-Path -LiteralPath $healthPath) {
                    try {
                        $health = [IO.File]::ReadAllText($healthPath) | ConvertFrom-Json
                        $age = ([DateTime]::UtcNow - [DateTime]::Parse($health.checkedAt).ToUniversalTime()).TotalMinutes
                        $cached = $health.key -eq $key -and $age -ge 0 -and $age -lt 60
                    } catch { }
                }
                if ($proxyPort -gt 0) {
                    $status = Invoke-DeviceTunnelControl $serial STATUS
                    $endpointPattern = 'running=true;host=127\.0\.0\.1;port=' + $proxyPort + ';'
                    $reverse = (Invoke-OwnedAdb -s $serial reverse --list | Out-String)
                    if ($cached -and $status -match $endpointPattern -and $reverse -match ('(?m)\btcp:' + $proxyPort + '\s+tcp:' + $proxyPort + '\s*$')) { continue }
                    Ensure-DeviceTunnel $serial $name $proxyPort
                } else {
                    if ($cached) { continue }
                    Stop-DeviceTunnel $serial
                }
                $marker = Join-Path $script:AvdRoot ($name + '.avd\.per_device_proxy_v1')
                if (-not (Test-Path -LiteralPath $marker)) {
                    Invoke-OwnedAdb -s $serial shell cmd media_session volume --stream 3 --set 15 | Out-Null
                    if ($LASTEXITCODE -eq 0) { [IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), [Text.UTF8Encoding]::new($false)) }
                }
                $healthText = @{ key = $key; checkedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
                [IO.File]::WriteAllText($healthPath, $healthText, [Text.UTF8Encoding]::new($false))
                if ($proxyPort -gt 0) { Set-Status "$name VPN endpoint ready; Internet access not yet verified." }
            } catch { Set-Status "Device $serial background check failed: $($_.Exception.Message)" }
        }
    } catch { Set-Status "Device discovery failed: $($_.Exception.Message)" }
    finally { $script:InitializingDevices = $false }
}

if ($Maintenance) {
    $script:AutoLatencyTimer.Stop()
    function Set-Status { param([string]$Text) $script:WorkerStatus = $Text }
    function Set-PhoneLatencyResult { param([string]$Name, [string]$Text) $script:LatencyResults[$Name] = $Text }
    try {
        Initialize-RunningDevices
        if ($MeasureLatency) {
            foreach ($deviceName in Get-AvdNames) { Test-PhoneProxy -TargetName $deviceName -Automatic }
        }
        $snapshot = [ordered]@{
            running = @((Get-RunningAvds).Keys)
            latency = $script:LatencyResults
            status = $script:WorkerStatus
        } | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($SnapshotPath, $snapshot, [Text.UTF8Encoding]::new($false))
    } finally {
        if ($script:OwnedAdbJob) { $script:OwnedAdbJob.Dispose(); $script:OwnedAdbJob = $null }
        $script:AutoLatencyTimer.Dispose()
    }
    return
}

function Update-BackgroundMaintenance {
    if ($script:Closing) { return }
    if ([DateTime]::UtcNow -lt $script:MaintenanceRetryAfter) { return }
    if ($script:MaintenanceProcess) {
        if (-not $script:MaintenanceProcess.HasExited) {
            if (([DateTime]::UtcNow - $script:MaintenanceStartedAt).TotalSeconds -lt $script:MaintenanceTimeoutSeconds) { return }
            $script:MaintenanceRetryAfter = [DateTime]::UtcNow.AddSeconds(30)
            if ($script:MaintenanceRequestedLatency) { $script:LatencyPending = $true }
            try {
                Stop-BackgroundMaintenance
                Set-Status 'Background check timed out; owned ADB clients were released. Retrying in 30 seconds.'
            } catch { Set-Status $_.Exception.Message }
            return
        }
        $completed = $false
        try {
            if ($script:MaintenanceProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $script:SnapshotFile)) { throw 'Background check did not produce a result.' }
            $snapshot = [IO.File]::ReadAllText($script:SnapshotFile) | ConvertFrom-Json
            $script:RunningSnapshot = @{}
            foreach ($deviceName in $snapshot.running) { $script:RunningSnapshot[$deviceName] = $true }
            foreach ($entry in $snapshot.latency.PSObject.Properties) { $script:LatencyResults[$entry.Name] = [string]$entry.Value }
            Update-AvdList
            Sync-LatencyUi
            Sync-ActionStates
            Sync-EmulatorWindowPlacement
            if ($snapshot.status) { Set-Status $snapshot.status }
            $completed = $true
        } catch { Set-Status "Unable to load background results: $($_.Exception.Message)" }
        finally {
            if (-not $completed) {
                $script:MaintenanceRetryAfter = [DateTime]::UtcNow.AddSeconds(30)
                if ($script:MaintenanceRequestedLatency) { $script:LatencyPending = $true }
            }
            $script:NextMaintenance = [DateTime]::UtcNow.AddSeconds(30)
            try { Stop-BackgroundMaintenance }
            catch { $script:MaintenanceRetryAfter = [DateTime]::UtcNow.AddSeconds(30); throw }
        }
    }
    if ([DateTime]::UtcNow -lt $script:MaintenanceRetryAfter) { return }
    if ([DateTime]::UtcNow -lt $script:NextMaintenance -and -not $script:LatencyPending) { return }
    try {
        if ($script:BackgroundAdbJob) { Stop-BackgroundMaintenance }
        $jobName = 'Local\AndroidSocialWorker-' + [Guid]::NewGuid().ToString('N')
        $script:BackgroundAdbJob = [OwnedAdbJob]::new($jobName)
        $script:SnapshotFile = Join-Path $script:RuntimeRoot ('manager-status-' + $PID + '-' + [Guid]::NewGuid().ToString('N') + '.json')
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Maintenance -SnapshotPath "{1}" -AdbJobName "{2}" -OwnerPid {3} -OwnerStartTicks {4}' -f $PSCommandPath, $script:SnapshotFile, $jobName, $PID, ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
        $script:MaintenanceRequestedLatency = [bool]$script:LatencyPending
        if ($script:MaintenanceRequestedLatency) { $arguments += ' -MeasureLatency' }
        $script:MaintenanceTimeoutSeconds = [Math]::Max(180, 90 * @(Get-AvdNames).Count)
        $script:MaintenanceStartedAt = [DateTime]::UtcNow
        $script:MaintenanceProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $script:LatencyPending = $false
    } catch {
        $script:MaintenanceRetryAfter = [DateTime]::UtcNow.AddSeconds(30)
        $script:NextMaintenance = $script:MaintenanceRetryAfter
        if ($script:BackgroundAdbJob -and $script:BackgroundAdbJob.StopClients(0)) {
            $script:BackgroundAdbJob.Dispose(); $script:BackgroundAdbJob = $null
        }
        throw
    }
}

if ($SelfTest) {
    $failures = [Collections.Generic.List[string]]::new()
    $templateConfig = Join-Path $script:AvdRoot ($script:TemplateName + '.avd\config.ini')
    foreach ($check in @(
        @{ Name = 'Emulator'; Path = $script:EmulatorExe },
        @{ Name = 'ADB'; Path = $script:AdbExe },
        @{ Name = 'Template'; Path = (Join-Path $script:AvdRoot ($script:TemplateName + '.avd')) },
        @{ Name = 'Xray'; Path = (Get-XrayExe) },
        @{ Name = 'Android VPN component'; Path = $script:TunnelApk }
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
            $sampleConfig = New-XrayConfigJson $sample 18999 | ConvertFrom-Json
            if (-not @($sampleConfig.inbounds | Where-Object { $_.protocol -eq 'socks' -and $_.port -eq 18999 -and $_.settings.udp }).Count) { throw 'VLESS SOCKS5/UDP listener is missing.' }
            if (-not @($sampleConfig.inbounds | Where-Object { $_.protocol -eq 'http' -and $_.port -eq 19999 }).Count) { throw 'VLESS HTTP test listener is missing.' }
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

$script:RunningSnapshot = @{}
$script:NextMaintenance = [DateTime]::MinValue
$script:MaintenanceRetryAfter = [DateTime]::MinValue
$script:MaintenanceRequestedLatency = $false
$script:SnapshotFile = Join-Path $script:RuntimeRoot ('manager-status-' + $PID + '.json')
$script:CardFonts = @{
    Name = [Drawing.Font]::new('Bahnschrift SemiBold', 14)
    Status = [Drawing.Font]::new('Segoe UI Semibold', 9)
    Label = [Drawing.Font]::new('Segoe UI', 8.5)
    Value = [Drawing.Font]::new('Segoe UI Semibold', 10)
}
$script:Form = [Windows.Forms.Form]::new()
$script:Form.Text = 'Android Social Suite'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.ClientSize = [Drawing.Size]::new(1180, 760)
$script:Form.MinimumSize = [Drawing.Size]::new(1200, 720)
$script:Form.BackColor = [Drawing.Color]::FromArgb(250, 249, 247)
$script:Form.Font = [Drawing.Font]::new('Segoe UI', 9)
$script:Form.AllowDrop = $false
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
    @{ Text = 'Refresh'; X = 922; W = 108; Action = { Update-AvdList }; Kind = 'Neutral' },
    @{ Text = 'Resolution'; X = 1042; W = 114; Action = { Set-PhoneResolution }; Kind = 'Neutral' }
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
        'Resolution' { $script:ResolutionButton = $button }
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
$script:AvdList.Size = [Drawing.Size]::new(1132, 454)
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
$script:AvdList.MultiSelect = $false
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
    $selected = $eventArgs.Item.Selected
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
        [Windows.Forms.TextRenderer]::DrawText($graphics, $name, $script:CardFonts.Name, [Drawing.Point]::new($nameX, [int]($bounds.Y + 18)), [Drawing.Color]::FromArgb(15, 35, 58))
        $statusColor = if ($status -eq 'Running') { [Drawing.Color]::FromArgb(0, 126, 94) } else { [Drawing.Color]::FromArgb(194, 48, 42) }
        $statusBack = if ($status -eq 'Running') { [Drawing.Color]::FromArgb(226, 246, 238) } else { [Drawing.Color]::FromArgb(255, 232, 229) }
        $statusRect = [Drawing.RectangleF]::new($nameX, $bounds.Y + 55, 104, 30)
        $statusPath = New-RoundedRectanglePath $statusRect 14
        $statusBrush = [Drawing.SolidBrush]::new($statusBack)
        try { $graphics.FillPath($statusBrush, $statusPath) } finally { $statusBrush.Dispose(); $statusPath.Dispose() }
        [Windows.Forms.TextRenderer]::DrawText($graphics, $status, $script:CardFonts.Status, [Drawing.Rectangle]::new($nameX + 10, [int]($bounds.Y + 61), 86, 20), $statusColor, [Windows.Forms.TextFormatFlags]::HorizontalCenter)
        $available = $bounds.Width - 340
        $proxyX = [int]($bounds.X + 330)
        $profileX = [int]($bounds.X + 330 + ($available * 0.34))
        $latencyX = [int]($bounds.X + 330 + ($available * 0.68))
        foreach ($field in @(
            @{ X = $proxyX; Label = 'Proxy'; Value = $proxy },
            @{ X = $profileX; Label = 'Hardware profile'; Value = $profile },
            @{ X = $latencyX; Label = 'Latency'; Value = $latency }
        )) {
            [Windows.Forms.TextRenderer]::DrawText($graphics, $field.Label, $script:CardFonts.Label, [Drawing.Point]::new($field.X, [int]($bounds.Y + 37)), [Drawing.Color]::FromArgb(91, 108, 126))
            [Windows.Forms.TextRenderer]::DrawText($graphics, [string]$field.Value, $script:CardFonts.Value, [Drawing.Rectangle]::new($field.X, [int]($bounds.Y + 60), 230, 28), [Drawing.Color]::FromArgb(22, 43, 66), [Windows.Forms.TextFormatFlags]::EndEllipsis)
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
$script:AvdList.Add_MouseUp({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $target = $null
    foreach ($candidate in $sender.Items) {
        if ($candidate.Bounds.Contains($eventArgs.Location)) { $target = $candidate; break }
    }
    if (-not $target) { return }
    foreach ($candidate in $sender.Items) {
        if ($candidate -ne $target -and $candidate.Selected) { $candidate.Selected = $false }
    }
    $target.Selected = $true
    $target.Focused = $true
    Sync-ActionStates
    $sender.Invalidate()
})
$script:AvdList.Add_SelectedIndexChanged({
    Sync-ActionStates
    $script:AvdList.Invalidate()
})
$script:Form.Controls.Add($script:AvdList)

$script:SummaryLabel = [Windows.Forms.Label]::new()
$script:SummaryLabel.Location = [Drawing.Point]::new(24, 730)
$script:SummaryLabel.Size = [Drawing.Size]::new(430, 22)
$script:SummaryLabel.Anchor = 'Bottom,Left,Right'
$script:SummaryLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$script:SummaryLabel.ForeColor = [Drawing.Color]::FromArgb(83, 101, 119)
$script:Form.Controls.Add($script:SummaryLabel)

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
    try { Update-AvdList; Sync-LatencyUi; Sync-ActionStates; Update-BackgroundMaintenance }
    catch { Set-Status 'Device status will refresh automatically.' }
})
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 500
$timer.Add_Tick({
    if ($script:MovingWindow) { return }
    try { Update-BackgroundMaintenance }
    catch {
        if ($_.Exception.Message -notmatch '(?i)error:\s*(closed|offline)|device.*not found') {
            Set-Status 'Device status will refresh automatically.'
        }
    }
})
$timer.Start()
$script:Form.Add_ResizeBegin({ $script:MovingWindow = $true })
$script:Form.Add_ResizeEnd({ $script:MovingWindow = $false })
$script:Form.Add_FormClosed({
    $script:Closing = $true
    $timer.Stop()
    $script:AutoLatencyTimer.Stop()
    try { Stop-BackgroundMaintenance } catch { }
    if ($script:OwnedAdbJob) { $script:OwnedAdbJob.Dispose(); $script:OwnedAdbJob = $null }
})
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
foreach ($font in $script:CardFonts.Values) { $font.Dispose() }
