param(
    [string]$LogPath = (Join-Path $PSScriptRoot 'calmkeeper.log'),
    [int]$Top = 10,
    [int]$Tail = 5000,
    [switch]$ShowRecent
)

$ErrorActionPreference = 'Continue'

function Get-ClampedPositiveInt {
    param(
        [int]$Value,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    if ($Value -lt $Minimum) {
        return $Default
    }

    return [Math]::Min($Maximum, $Value)
}

$Top = Get-ClampedPositiveInt -Value $Top -Default 10 -Minimum 1 -Maximum 100
$Tail = Get-ClampedPositiveInt -Value $Tail -Default 5000 -Minimum 1 -Maximum 100000

if (-not (Test-Path $LogPath)) {
    Write-Host "No CalmKeeper log found at: $LogPath"
    Write-Host 'Run a dry-run first, for example:'
    Write-Host 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CalmKeeper.ps1 -SelfTest -NoTray'
    return
}

$lines = Get-Content -Path $LogPath -Tail $Tail -ErrorAction SilentlyContinue
if (-not $lines -or $lines.Count -eq 0) {
    Write-Host "CalmKeeper log is empty: $LogPath"
    return
}

$actionRows = New-Object System.Collections.Generic.List[object]
$statusRows = New-Object System.Collections.Generic.List[object]
$restoreRows = New-Object System.Collections.Generic.List[object]
$skipRows = New-Object System.Collections.Generic.List[object]

foreach ($line in $lines) {
    $timestamp = $null
    $message = $line
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$') {
        $timestamp = $matches[1]
        $message = $matches[2]
    }

    if ($message -match '^Priority restored\s+(.+?)#(\d+):\s+(.+)$') {
        $restoreRows.Add([pscustomobject]@{
            Time = $timestamp
            Process = $matches[1]
            Pid = [int]$matches[2]
            Priority = $matches[3]
        })
        continue
    }

    if ($message -match '^(Priority|Working set trim)\s+(.+?)#(\d+)(?::\s+(.+?))?(?:\s+reason=\[(.*)\])?$') {
        $actionRows.Add([pscustomobject]@{
            Time = $timestamp
            Action = if ($matches[1] -eq 'Priority') { 'priority' } else { 'trim' }
            Process = $matches[2]
            Pid = [int]$matches[3]
            Detail = $matches[4]
            Reason = $matches[5]
        })
        continue
    }

    if ($message -match 'skipped\s+(.+?)#(\d+):\s+(.+)$') {
        $skipRows.Add([pscustomobject]@{
            Time = $timestamp
            Process = $matches[1]
            Pid = [int]$matches[2]
            Reason = $matches[3]
        })
        continue
    }

    if ($message -match '^(cool|watching|pressure|sensor unavailable)\b') {
        $statusRows.Add([pscustomobject]@{
            Time = $timestamp
            Status = $message
        })
    }
}

$priorityCount = @($actionRows | Where-Object { $_.Action -eq 'priority' }).Count
$trimCount = @($actionRows | Where-Object { $_.Action -eq 'trim' }).Count
$restoreCount = $restoreRows.Count
$skipCount = $skipRows.Count

Write-Host 'CalmKeeper Log Summary'
Write-Host "Log: $LogPath"
Write-Host "Lines analyzed: $($lines.Count)"
Write-Host "Actions: priority=$priorityCount, trim=$trimCount, restores=$restoreCount, skipped=$skipCount"

if ($statusRows.Count -gt 0) {
    Write-Host ''
    Write-Host 'Recent status:'
    $statusRows |
        Select-Object -Last 5 |
        ForEach-Object { Write-Host ("- {0} {1}" -f $_.Time, $_.Status) }
}

if ($actionRows.Count -gt 0) {
    Write-Host ''
    Write-Host "Top processes touched or selected in dry-run:"
    $actionRows |
        Group-Object -Property Process |
        Sort-Object -Property Count -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            $priority = @($_.Group | Where-Object { $_.Action -eq 'priority' }).Count
            $trim = @($_.Group | Where-Object { $_.Action -eq 'trim' }).Count
            Write-Host ("- {0}: total={1}, priority={2}, trim={3}" -f $_.Name, $_.Count, $priority, $trim)
        }

    Write-Host ''
    Write-Host 'Most recent action reasons:'
    $actionRows |
        Select-Object -Last $Top |
        ForEach-Object {
            $reason = if ([string]::IsNullOrWhiteSpace($_.Reason)) { $_.Detail } else { $_.Reason }
            Write-Host ("- {0} {1} {2}#{3}: {4}" -f $_.Time, $_.Action, $_.Process, $_.Pid, $reason)
        }
} else {
    Write-Host ''
    Write-Host 'No priority or working-set actions found.'
}

if ($skipRows.Count -gt 0) {
    Write-Host ''
    Write-Host 'Recent skipped actions:'
    $skipRows |
        Select-Object -Last 5 |
        ForEach-Object { Write-Host ("- {0} {1}#{2}: {3}" -f $_.Time, $_.Process, $_.Pid, $_.Reason) }
}

if ($ShowRecent) {
    Write-Host ''
    Write-Host 'Recent raw log lines:'
    $lines | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
}
