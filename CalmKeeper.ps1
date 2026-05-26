param(
    [switch]$NoTray,
    [switch]$Once,
    [switch]$WhatIf,
    [switch]$SelfTest,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'calmkeeper.config.json')
)

$ErrorActionPreference = 'Continue'
$script:AppName = 'CalmKeeper'
$script:LogPath = Join-Path $PSScriptRoot 'calmkeeper.log'
$script:OriginalPriorities = @{}
$script:CpuSamples = @{}
$script:RecentForegroundPids = @{}
$script:RecentForegroundNames = @{}
$script:ProcessActionAt = @{}
$script:LastActionAt = [datetime]::MinValue
$script:CpuCount = [Math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS)
$script:Paused = $false
$script:LastStatus = 'starting'
$script:LastCheckSummary = 'not checked yet'
$script:LastActionSummary = 'none'

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue

$nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace CalmKeeper {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;

        public MEMORYSTATUSEX() {
            dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        }
    }

    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

        [DllImport("psapi.dll", SetLastError = true)]
        public static extern bool EmptyWorkingSet(IntPtr hProcess);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    }
}
'@

try {
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction SilentlyContinue
} catch {
    # The type may already be loaded when the script is re-run in the same host.
}

function Get-DefaultConfig {
    [pscustomobject]@{
        checkIntervalSeconds = 5
        cpuHighPercent = 85
        memoryHighPercent = 82
        cpuCoolPercent = 55
        memoryCoolPercent = 70
        actionCooldownSeconds = 20
        perProcessActionCooldownSeconds = 120
        foregroundGraceSeconds = 30
        minimumProcessMemoryMB = 250
        minimumProcessCpuPercent = 3
        maxCpuPercentForMemoryTrim = 2
        memoryEmergencyPercent = 92
        maxProcessesPerPass = 5
        lowerPriority = $true
        trimWorkingSet = $true
        restorePriorities = $true
        dryRun = $false
        protectForegroundProcess = $true
        protectForegroundProcessName = $true
        protectedProcessNames = @(
            'System', 'Idle', 'Registry', 'Secure System',
            'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'smss',
            'svchost', 'dllhost', 'WmiPrvSE', 'unsecapp', 'dasHost',
            'fontdrvhost', 'WUDFHost', 'dwm', 'explorer',
            'ApplicationFrameHost', 'TextInputHost', 'ctfmon', 'Taskmgr',
            'SearchIndexer', 'SearchHost', 'SearchProtocolHost', 'SearchFilterHost',
            'StartMenuExperienceHost',
            'ShellExperienceHost', 'RuntimeBroker', 'sihost',
            'audiodg', 'spoolsv', 'taskhostw', 'MoUsoCoreWorker', 'TiWorker',
            'Memory Compression', 'MsMpEng', 'NisSrv',
            'SecurityHealthService', 'SecurityHealthSystray', 'SecurityHealthHost',
            'powershell', 'powershell_ise', 'pwsh', 'cmd', 'conhost',
            'Code', 'devenv', 'Codex'
        )
        logRetentionLines = 1000
    }
}

function Get-ClampedInt {
    param(
        [object]$Value,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    try {
        $number = [int]$Value
    } catch {
        $number = $Default
    }

    return [Math]::Min($Maximum, [Math]::Max($Minimum, $number))
}

function Get-ClampedDouble {
    param(
        [object]$Value,
        [double]$Default,
        [double]$Minimum,
        [double]$Maximum
    )

    try {
        $number = [double]$Value
    } catch {
        $number = $Default
    }

    return [Math]::Min($Maximum, [Math]::Max($Minimum, $number))
}

function Normalize-Config {
    param([object]$Config)

    $default = Get-DefaultConfig
    $Config.checkIntervalSeconds = Get-ClampedInt $Config.checkIntervalSeconds $default.checkIntervalSeconds 1 3600
    $Config.cpuHighPercent = Get-ClampedDouble $Config.cpuHighPercent $default.cpuHighPercent 1 100
    $Config.memoryHighPercent = Get-ClampedDouble $Config.memoryHighPercent $default.memoryHighPercent 1 100
    $Config.cpuCoolPercent = Get-ClampedDouble $Config.cpuCoolPercent $default.cpuCoolPercent 0 100
    $Config.memoryCoolPercent = Get-ClampedDouble $Config.memoryCoolPercent $default.memoryCoolPercent 0 100

    if ($Config.cpuCoolPercent -gt $Config.cpuHighPercent) {
        $Config.cpuCoolPercent = [Math]::Max(0, $Config.cpuHighPercent - 5)
    }
    if ($Config.memoryCoolPercent -gt $Config.memoryHighPercent) {
        $Config.memoryCoolPercent = [Math]::Max(0, $Config.memoryHighPercent - 5)
    }

    $Config.actionCooldownSeconds = Get-ClampedInt $Config.actionCooldownSeconds $default.actionCooldownSeconds 0 3600
    $Config.perProcessActionCooldownSeconds = Get-ClampedInt $Config.perProcessActionCooldownSeconds $default.perProcessActionCooldownSeconds 0 86400
    $Config.foregroundGraceSeconds = Get-ClampedInt $Config.foregroundGraceSeconds $default.foregroundGraceSeconds 0 3600
    $Config.minimumProcessMemoryMB = Get-ClampedInt $Config.minimumProcessMemoryMB $default.minimumProcessMemoryMB 1 1048576
    $Config.minimumProcessCpuPercent = Get-ClampedDouble $Config.minimumProcessCpuPercent $default.minimumProcessCpuPercent 0 100
    $Config.maxCpuPercentForMemoryTrim = Get-ClampedDouble $Config.maxCpuPercentForMemoryTrim $default.maxCpuPercentForMemoryTrim 0 100
    $Config.memoryEmergencyPercent = Get-ClampedDouble $Config.memoryEmergencyPercent $default.memoryEmergencyPercent 1 100
    $Config.maxProcessesPerPass = Get-ClampedInt $Config.maxProcessesPerPass $default.maxProcessesPerPass 1 100
    $Config.lowerPriority = [bool]$Config.lowerPriority
    $Config.trimWorkingSet = [bool]$Config.trimWorkingSet
    $Config.restorePriorities = [bool]$Config.restorePriorities
    $Config.dryRun = [bool]$Config.dryRun
    $Config.protectForegroundProcess = [bool]$Config.protectForegroundProcess
    $Config.protectForegroundProcessName = [bool]$Config.protectForegroundProcessName
    $Config.logRetentionLines = Get-ClampedInt $Config.logRetentionLines $default.logRetentionLines 0 100000

    if ($null -eq $Config.protectedProcessNames) {
        $Config.protectedProcessNames = $default.protectedProcessNames
    } elseif ($Config.protectedProcessNames -isnot [array]) {
        $Config.protectedProcessNames = @($Config.protectedProcessNames)
    }

    return $Config
}

function Write-Log {
    param([string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    try {
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop

        $retention = [int]$script:Config.logRetentionLines
        if ($retention -gt 0 -and (Test-Path $script:LogPath)) {
            $file = Get-Item $script:LogPath -ErrorAction SilentlyContinue
            if ($file -and $file.Length -gt 1048576) {
                $tail = Get-Content -Path $script:LogPath -Tail $retention -ErrorAction Stop
                Set-Content -Path $script:LogPath -Value $tail -Encoding UTF8 -ErrorAction Stop
            }
        }
    } catch {
        Write-Verbose $line
    }
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        $default = Get-DefaultConfig
        $default | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8
        return (Normalize-Config $default)
    }

    try {
        $loaded = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $default = Get-DefaultConfig

        foreach ($property in $default.PSObject.Properties.Name) {
            if (-not ($loaded.PSObject.Properties.Name -contains $property)) {
                $loaded | Add-Member -MemberType NoteProperty -Name $property -Value $default.$property
            }
        }

        return (Normalize-Config $loaded)
    } catch {
        Write-Log "Config read failed, using defaults: $($_.Exception.Message)"
        return (Normalize-Config (Get-DefaultConfig))
    }
}

function Install-StartupShortcut {
    $startup = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startup "$script:AppName.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
    $shortcut.Description = 'CalmKeeper background CPU/RAM smoother'
    $shortcut.Save()
    Write-Host "Startup shortcut installed: $shortcutPath"
}

function Uninstall-StartupShortcut {
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "$script:AppName.lnk"
    if (Test-Path $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "Startup shortcut removed: $shortcutPath"
    } else {
        Write-Host 'Startup shortcut was not installed.'
    }
}

if ($InstallStartup) {
    Install-StartupShortcut
    return
}

if ($UninstallStartup) {
    Uninstall-StartupShortcut
    return
}

if (-not $Once) {
    $mutexCreated = $false
    try {
        $script:SingleInstanceMutex = New-Object System.Threading.Mutex($true, 'Local\CalmKeeperCpuRamSmoother', [ref]$mutexCreated)
    } catch {
        $mutexCreated = $true
    }

    if (-not $mutexCreated) {
        Write-Host 'CalmKeeper is already running.'
        return
    }
}

$script:Config = Read-Config
$script:DryRun = [bool]($WhatIf -or $script:Config.dryRun)

try {
    $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
    [void]$script:CpuCounter.NextValue()
} catch {
    $script:CpuCounter = $null
    Write-Log "CPU performance counter unavailable, falling back to CIM: $($_.Exception.Message)"
}

function Get-SystemCpuPercent {
    try {
        if ($script:CpuCounter) {
            return [Math]::Round($script:CpuCounter.NextValue(), 1)
        }
    } catch {
        $script:CpuCounter = $null
    }

    try {
        $avg = Get-CimInstance -ClassName Win32_Processor |
            Measure-Object -Property LoadPercentage -Average |
            Select-Object -ExpandProperty Average
        return [Math]::Round([double]$avg, 1)
    } catch {
        Write-Log "CPU status unavailable: $($_.Exception.Message)"
        return $null
    }
}

function Get-SystemMemoryStatus {
    try {
        $mem = New-Object CalmKeeper.MEMORYSTATUSEX
        if ([CalmKeeper.NativeMethods]::GlobalMemoryStatusEx($mem)) {
            $used = $mem.ullTotalPhys - $mem.ullAvailPhys
            return [pscustomobject]@{
                IsAvailable = $true
                LoadPercent = [int]$mem.dwMemoryLoad
                UsedGB = [Math]::Round($used / 1GB, 2)
                TotalGB = [Math]::Round($mem.ullTotalPhys / 1GB, 2)
                AvailableGB = [Math]::Round($mem.ullAvailPhys / 1GB, 2)
            }
        }
    } catch {
        Write-Log "Memory status failed: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        IsAvailable = $false
        LoadPercent = 0
        UsedGB = 0
        TotalGB = 0
        AvailableGB = 0
    }
}

function Get-ForegroundProcessId {
    if (-not [bool]$script:Config.protectForegroundProcess) {
        return $null
    }

    try {
        $hwnd = [CalmKeeper.NativeMethods]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) {
            return $null
        }

        [uint32]$foregroundProcessId = 0
        [void][CalmKeeper.NativeMethods]::GetWindowThreadProcessId($hwnd, [ref]$foregroundProcessId)
        if ($foregroundProcessId -gt 0) {
            $pid = [int]$foregroundProcessId
            $script:RecentForegroundPids[$pid] = Get-Date

            if ([bool]$script:Config.protectForegroundProcessName) {
                try {
                    $process = Get-Process -Id $pid -ErrorAction Stop
                    if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
                        $script:RecentForegroundNames[$process.ProcessName] = Get-Date
                    }
                } catch {
                    Write-Log "Foreground process name check failed for PID $pid`: $($_.Exception.Message)"
                }
            }

            return $pid
        }
    } catch {
        Write-Log "Foreground process check failed: $($_.Exception.Message)"
    }

    return $null
}

function Test-ForegroundProtectedPid {
    param([int]$ProcessId)

    if (-not [bool]$script:Config.protectForegroundProcess) {
        return $false
    }

    $graceSeconds = [Math]::Max(0, [int]$script:Config.foregroundGraceSeconds)
    $now = Get-Date

    foreach ($id in @($script:RecentForegroundPids.Keys)) {
        if (($now - $script:RecentForegroundPids[$id]).TotalSeconds -gt $graceSeconds) {
            $script:RecentForegroundPids.Remove($id)
        }
    }

    return $script:RecentForegroundPids.ContainsKey($ProcessId)
}

function Test-ForegroundProtectedName {
    param([string]$ProcessName)

    if (-not [bool]$script:Config.protectForegroundProcessName) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        return $false
    }

    $graceSeconds = [Math]::Max(0, [int]$script:Config.foregroundGraceSeconds)
    $now = Get-Date

    foreach ($name in @($script:RecentForegroundNames.Keys)) {
        if (($now - $script:RecentForegroundNames[$name]).TotalSeconds -gt $graceSeconds) {
            $script:RecentForegroundNames.Remove($name)
        }
    }

    return $script:RecentForegroundNames.ContainsKey($ProcessName)
}

function Get-ProtectedNameSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $script:Config.protectedProcessNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$set.Add([string]$name)
            [void]$set.Add(([string]$name).Replace('.exe', ''))
        }
    }
    return $set
}

function Get-ProcessSnapshot {
    $now = Get-Date
    [void](Get-ForegroundProcessId)
    $protected = Get-ProtectedNameSet
    $minMemBytes = [int64]$script:Config.minimumProcessMemoryMB * 1MB
    $minCpu = [double]$script:Config.minimumProcessCpuPercent
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            if ($process.Id -le 4 -or $process.Id -eq $PID) {
                continue
            }
            if (Test-ForegroundProtectedPid -ProcessId $process.Id) {
                continue
            }
            if (Test-ForegroundProtectedName -ProcessName $process.ProcessName) {
                continue
            }
            if ($protected.Contains($process.ProcessName)) {
                continue
            }

            $cpuPercent = 0.0
            $hasCpuSample = $false
            try {
                $totalCpu = $process.TotalProcessorTime.TotalSeconds
                if ($script:CpuSamples.ContainsKey($process.Id)) {
                    $previous = $script:CpuSamples[$process.Id]
                    $elapsed = [Math]::Max(0.1, ($now - $previous.Time).TotalSeconds)
                    $delta = [Math]::Max(0, $totalCpu - $previous.Total)
                    $cpuPercent = [Math]::Round(($delta / $elapsed) * 100 / $script:CpuCount, 1)
                    $hasCpuSample = $true
                }
                $script:CpuSamples[$process.Id] = [pscustomobject]@{
                    Total = $totalCpu
                    Time = $now
                }
            } catch {
                $cpuPercent = 0.0
            }

            if ($process.WorkingSet64 -lt $minMemBytes -and (-not $hasCpuSample -or $cpuPercent -lt $minCpu)) {
                continue
            }

            $items.Add([pscustomobject]@{
                Process = $process
                Id = $process.Id
                Name = $process.ProcessName
                MemoryMB = [Math]::Round($process.WorkingSet64 / 1MB, 1)
                CpuPercent = $cpuPercent
                HasCpuSample = $hasCpuSample
            })
        } catch {
            continue
        }
    }

    return $items
}

function Set-CalmPriority {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Reason = ''
    )

    if (-not [bool]$script:Config.lowerPriority) {
        return $false
    }

    try {
        $current = $Process.PriorityClass
        $target = $null

        if ($current -eq [System.Diagnostics.ProcessPriorityClass]::Normal) {
            $target = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        } elseif ($current -eq [System.Diagnostics.ProcessPriorityClass]::AboveNormal) {
            $target = [System.Diagnostics.ProcessPriorityClass]::Normal
        }

        if (-not $target) {
            return $false
        }

        if (-not $script:OriginalPriorities.ContainsKey($Process.Id)) {
            $script:OriginalPriorities[$Process.Id] = [pscustomobject]@{
                Name = $Process.ProcessName
                Priority = $current
                ChangedAt = Get-Date
            }
        }

        if (-not $script:DryRun) {
            $Process.PriorityClass = $target
        }

        $detail = if ([string]::IsNullOrWhiteSpace($Reason)) { '' } else { " reason=[$Reason]" }
        Write-Log "Priority $($Process.ProcessName)#$($Process.Id): $current -> $target$detail"
        return $true
    } catch {
        Write-Log "Priority skipped $($Process.ProcessName)#$($Process.Id): $($_.Exception.Message)"
        return $false
    }
}

function Invoke-WorkingSetTrim {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Reason = ''
    )

    if (-not [bool]$script:Config.trimWorkingSet) {
        return $false
    }

    try {
        if (-not $script:DryRun) {
            [void][CalmKeeper.NativeMethods]::EmptyWorkingSet($Process.Handle)
        }

        $detail = if ([string]::IsNullOrWhiteSpace($Reason)) { '' } else { " reason=[$Reason]" }
        Write-Log "Working set trim $($Process.ProcessName)#$($Process.Id)$detail"
        return $true
    } catch {
        Write-Log "Working set trim skipped $($Process.ProcessName)#$($Process.Id): $($_.Exception.Message)"
        return $false
    }
}

function Test-ProcessActionReady {
    param(
        [int]$ProcessId,
        [string]$ActionName
    )

    $cooldown = [Math]::Max(0, [int]$script:Config.perProcessActionCooldownSeconds)
    $key = "$ActionName`:$ProcessId"

    if (-not $script:ProcessActionAt.ContainsKey($key)) {
        return $true
    }

    return ((Get-Date) - $script:ProcessActionAt[$key]).TotalSeconds -ge $cooldown
}

function Set-ProcessActionTime {
    param(
        [int]$ProcessId,
        [string]$ActionName
    )

    $script:ProcessActionAt["$ActionName`:$ProcessId"] = Get-Date
}

function Set-LastActionSummary {
    param(
        [string]$ActionName,
        [string]$ProcessName,
        [int]$ProcessId,
        [string]$Reason = ''
    )

    $summary = '{0} {1}#{2} at {3:HH:mm:ss}' -f $ActionName, $ProcessName, $ProcessId, (Get-Date)
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $summary = "$summary - $Reason"
    }
    $script:LastActionSummary = $summary
}

function Get-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 70
    )

    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $MaxLength) {
        return $Text
    }

    if ($MaxLength -le 3) {
        return $Text.Substring(0, $MaxLength)
    }

    return $Text.Substring(0, $MaxLength - 3) + '...'
}

function Restore-CalmPriorities {
    if (-not [bool]$script:Config.restorePriorities) {
        return 0
    }

    $restored = 0
    foreach ($id in @($script:OriginalPriorities.Keys)) {
        $record = $script:OriginalPriorities[$id]
        try {
            $process = Get-Process -Id $id -ErrorAction Stop
            if ($process.ProcessName -eq $record.Name) {
                if (-not $script:DryRun) {
                    $process.PriorityClass = $record.Priority
                }
                Write-Log "Priority restored $($process.ProcessName)#$($process.Id): $($record.Priority)"
                Set-LastActionSummary -ActionName 'restore' -ProcessName $process.ProcessName -ProcessId $process.Id -Reason 'system cooled'
                $restored++
            }
        } catch {
            # Process exited; forget the remembered priority.
        }
        $script:OriginalPriorities.Remove($id)
    }

    return $restored
}

function Invoke-CalmPass {
    $checkStartedAt = Get-Date

    if ($script:Paused) {
        $script:LastStatus = 'paused'
        $script:LastCheckSummary = 'paused'
        return $script:LastStatus
    }

    $cpu = Get-SystemCpuPercent
    $mem = Get-SystemMemoryStatus

    if ($null -eq $cpu -or -not $mem.IsAvailable) {
        $cpuText = if ($null -eq $cpu) { 'unknown' } else { "$cpu%" }
        $memText = if ($mem.IsAvailable) { "$($mem.LoadPercent)%" } else { 'unknown' }
        $script:LastStatus = "sensor unavailable CPU $cpuText, RAM $memText"
        $script:LastCheckSummary = "checked $($checkStartedAt.ToString('HH:mm:ss')) - sensors unavailable"
        Write-Log $script:LastStatus
        return $script:LastStatus
    }

    $highCpu = $cpu -ge [double]$script:Config.cpuHighPercent
    $highMem = $mem.LoadPercent -ge [double]$script:Config.memoryHighPercent
    $cool = ($cpu -le [double]$script:Config.cpuCoolPercent) -and
        ($mem.LoadPercent -le [double]$script:Config.memoryCoolPercent)

    if ($cool) {
        $restored = Restore-CalmPriorities
        $script:LastStatus = "cool CPU $cpu%, RAM $($mem.LoadPercent)%"
        if ($restored -gt 0) {
            $script:LastStatus += ", restored $restored"
        }
        $script:LastCheckSummary = "checked $($checkStartedAt.ToString('HH:mm:ss')) - cool"
        return $script:LastStatus
    }

    if (-not ($highCpu -or $highMem)) {
        $script:LastStatus = "watching CPU $cpu%, RAM $($mem.LoadPercent)%"
        $script:LastCheckSummary = "checked $($checkStartedAt.ToString('HH:mm:ss')) - watching"
        return $script:LastStatus
    }

    $cooldown = [int]$script:Config.actionCooldownSeconds
    if (((Get-Date) - $script:LastActionAt).TotalSeconds -lt $cooldown) {
        $script:LastStatus = "pressure CPU $cpu%, RAM $($mem.LoadPercent)%, cooling down"
        $script:LastCheckSummary = "checked $($checkStartedAt.ToString('HH:mm:ss')) - cooldown"
        return $script:LastStatus
    }

    $candidates = Get-ProcessSnapshot
    $selectedById = @{}
    $maxPerPass = [int]$script:Config.maxProcessesPerPass
    $minMemMb = [double]$script:Config.minimumProcessMemoryMB
    $minCpu = [double]$script:Config.minimumProcessCpuPercent
    $maxCpuForTrim = [double]$script:Config.maxCpuPercentForMemoryTrim
    $emergencyMem = $mem.LoadPercent -ge [double]$script:Config.memoryEmergencyPercent

    if ($highCpu) {
        $cpuSelected = $candidates |
            Where-Object { $_.HasCpuSample -and $_.CpuPercent -ge $minCpu } |
            Sort-Object -Property @{ Expression = 'CpuPercent'; Descending = $true }, @{ Expression = 'MemoryMB'; Descending = $true } |
            Select-Object -First $maxPerPass

        foreach ($item in $cpuSelected) {
            $selectedById[$item.Id] = $item
        }
    }

    if ($highMem) {
        $memSelected = $candidates |
            Where-Object {
                $_.MemoryMB -ge $minMemMb -and
                (
                    ($_.HasCpuSample -and $_.CpuPercent -le $maxCpuForTrim) -or
                    $emergencyMem
                )
            } |
            Sort-Object -Property @{ Expression = 'MemoryMB'; Descending = $true }, @{ Expression = 'CpuPercent'; Descending = $true } |
            Select-Object -First $maxPerPass

        foreach ($item in $memSelected) {
            $selectedById[$item.Id] = $item
        }
    }

    $actions = 0
    foreach ($item in $selectedById.Values) {
        try {
            $priorityReason = "process CPU $($item.CpuPercent)% >= $minCpu%, system CPU $cpu%"
            if ($highCpu -and
                $item.HasCpuSample -and
                $item.CpuPercent -ge $minCpu -and
                (Test-ProcessActionReady -ProcessId $item.Id -ActionName 'priority') -and
                (Set-CalmPriority -Process $item.Process -Reason $priorityReason)) {
                Set-ProcessActionTime -ProcessId $item.Id -ActionName 'priority'
                Set-LastActionSummary -ActionName 'priority' -ProcessName $item.Name -ProcessId $item.Id -Reason $priorityReason
                $actions++
            }

            $trimReason = if ($emergencyMem) {
                "RAM $($mem.LoadPercent)% >= emergency $($script:Config.memoryEmergencyPercent)%, working set $($item.MemoryMB) MB"
            } else {
                "RAM $($mem.LoadPercent)% >= $($script:Config.memoryHighPercent)%, working set $($item.MemoryMB) MB, process CPU $($item.CpuPercent)% <= $maxCpuForTrim%"
            }
            if ($highMem -and
                $item.MemoryMB -ge $minMemMb -and
                (($item.HasCpuSample -and $item.CpuPercent -le $maxCpuForTrim) -or $emergencyMem) -and
                (Test-ProcessActionReady -ProcessId $item.Id -ActionName 'trim') -and
                (Invoke-WorkingSetTrim -Process $item.Process -Reason $trimReason)) {
                Set-ProcessActionTime -ProcessId $item.Id -ActionName 'trim'
                Set-LastActionSummary -ActionName 'trim' -ProcessName $item.Name -ProcessId $item.Id -Reason $trimReason
                $actions++
            }
        } catch {
            Write-Log "Action failed $($item.Name)#$($item.Id): $($_.Exception.Message)"
        }
    }

    if ($actions -gt 0) {
        $script:LastActionAt = Get-Date
        $script:LastStatus = "pressure CPU $cpu%, RAM $($mem.LoadPercent)%, actions $actions"
        $script:LastCheckSummary = "checked $($checkStartedAt.ToString('HH:mm:ss')) - acted on $actions"
    } else {
        $script:LastStatus = "pressure CPU $cpu%, RAM $($mem.LoadPercent)%, no safe candidates"
        $script:LastCheckSummary = "checked $($checkStartedAt.ToString('HH:mm:ss')) - no safe candidates"
    }
    Write-Log $script:LastStatus
    return $script:LastStatus
}

function Invoke-SelfTest {
    Write-Host "$script:AppName self-test running in dry-run mode."
    Write-Log 'Self-test started'

    $script:DryRun = $true
    $script:Config.cpuHighPercent = 1
    $script:Config.memoryHighPercent = 1
    $script:Config.cpuCoolPercent = 0
    $script:Config.memoryCoolPercent = 0
    $script:Config.actionCooldownSeconds = 0
    $script:Config.perProcessActionCooldownSeconds = 0
    $script:Config.minimumProcessMemoryMB = 1
    $script:Config.minimumProcessCpuPercent = 0
    $script:Config.memoryEmergencyPercent = 1
    $script:Config.maxProcessesPerPass = 3

    Write-Host 'Pass 1: warm CPU samples'
    [void](Get-ProcessSnapshot)
    Write-Host 'samples warmed'
    Start-Sleep -Seconds 2
    Write-Host 'Pass 2: forced pressure selection'
    Invoke-CalmPass | Write-Host
    Write-Host "Last check: $script:LastCheckSummary"
    Write-Host "Last action: $script:LastActionSummary"

    Stop-CalmKeeper 'Self-test stopped'
}

function Stop-CalmKeeper {
    param([string]$Reason = 'stopping')

    try {
        $restored = Restore-CalmPriorities
        Write-Log "$Reason, restored $restored priorities"
    } catch {
        Write-Log "$Reason, priority restore failed: $($_.Exception.Message)"
    }
}

function Start-ConsoleLoop {
    Write-Host "$script:AppName running. Press Ctrl+C to exit."
    try {
        while ($true) {
            Invoke-CalmPass | Write-Host
            Start-Sleep -Seconds ([int]$script:Config.checkIntervalSeconds)
        }
    } finally {
        Stop-CalmKeeper 'Console loop stopped'
    }
}

function Start-TrayApp {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Shield
    $notify.Text = $script:AppName
    $notify.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = $menu.Items.Add('Status: starting')
    $statusItem.Enabled = $false
    $checkItem = $menu.Items.Add('Last check: not checked yet')
    $checkItem.Enabled = $false
    $modeItem = $menu.Items.Add("Mode: $(if ($script:DryRun) { 'dry-run' } else { 'active' })")
    $modeItem.Enabled = $false
    $lastActionItem = $menu.Items.Add('Last action: none')
    $lastActionItem.Enabled = $false
    [void]$menu.Items.Add('-')

    $pauseItem = $menu.Items.Add('Pause')
    $pauseItem.Add_Click({
        $script:Paused = -not $script:Paused
        if ($script:Paused) {
            $pauseItem.Text = 'Resume'
            $statusItem.Text = 'Status: paused'
            $checkItem.Text = 'Last check: paused'
            Write-Log 'Paused from tray'
        } else {
            $pauseItem.Text = 'Pause'
            Write-Log 'Resumed from tray'
        }
    })

    $runNowItem = $menu.Items.Add('Check now')
    $runNowItem.Add_Click({
        $status = Invoke-CalmPass
        $statusItem.Text = "Status: $status"
        $checkItem.Text = "Last check: $script:LastCheckSummary"
        $lastActionItem.Text = "Last action: $(Get-ShortText $script:LastActionSummary 100)"
    })

    $configItem = $menu.Items.Add('Open config')
    $configItem.Add_Click({
        Start-Process notepad.exe -ArgumentList "`"$ConfigPath`""
    })

    $logItem = $menu.Items.Add('Open log')
    $logItem.Add_Click({
        if (-not (Test-Path $script:LogPath)) {
            New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
        }
        Start-Process notepad.exe -ArgumentList "`"$script:LogPath`""
    })

    [void]$menu.Items.Add('-')
    $exitItem = $menu.Items.Add('Exit')
    $exitItem.Add_Click({
        Write-Log 'Exiting from tray'
        Stop-CalmKeeper 'Tray exit'
        [System.Windows.Forms.Application]::Exit()
    })

    $notify.ContextMenuStrip = $menu
    $notify.BalloonTipTitle = $script:AppName
    $notify.BalloonTipText = 'CPU/RAM smoother is running.'
    $notify.ShowBalloonTip(1500)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(1000, [int]$script:Config.checkIntervalSeconds * 1000)
    $timer.Add_Tick({
        $status = Invoke-CalmPass
        $statusItem.Text = "Status: $status"
        $checkItem.Text = "Last check: $script:LastCheckSummary"
        $lastActionItem.Text = "Last action: $(Get-ShortText $script:LastActionSummary 100)"
        $tip = "$script:AppName - $status"
        $notify.Text = Get-ShortText $tip 63
    })
    $timer.Start()

    Write-Log "Tray app started. DryRun=$script:DryRun"
    try {
        [System.Windows.Forms.Application]::Run()
    } finally {
        Stop-CalmKeeper 'Tray app stopped'
        $notify.Visible = $false
        $notify.Dispose()
    }
}

Write-Log "Started. PID=$PID DryRun=$script:DryRun Config=$ConfigPath"
Start-Sleep -Milliseconds 1200

if ($Once) {
    try {
        Invoke-CalmPass | Write-Host
    } finally {
        Stop-CalmKeeper 'One-time run stopped'
    }
    return
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($NoTray) {
    Start-ConsoleLoop
} else {
    Start-TrayApp
}
