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
    Write-Host "CalmKeeper 로그를 찾을 수 없습니다: $LogPath"
    Write-Host '먼저 dry-run을 실행하세요. 예:'
    Write-Host 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CalmKeeper.ps1 -SelfTest -NoTray'
    return
}

$lines = Get-Content -Path $LogPath -Tail $Tail -ErrorAction SilentlyContinue
if (-not $lines -or $lines.Count -eq 0) {
    Write-Host "CalmKeeper 로그가 비어 있습니다: $LogPath"
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

    if ($message -match 'skipped\s+(.+?)#(\d+):\s+(.+)$') {
        $skipRows.Add([pscustomobject]@{
            Time = $timestamp
            Process = $matches[1]
            Pid = [int]$matches[2]
            Reason = $matches[3]
        })
        continue
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

    if ($message -match '^(cool|watching|pressure|sensor unavailable|안정|감시 중|압박|센서 사용 불가)\b') {
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

Write-Host 'CalmKeeper 로그 요약'
Write-Host "로그: $LogPath"
Write-Host "분석한 줄 수: $($lines.Count)"
Write-Host "조치 수: 우선순위=$priorityCount, 메모리정리=$trimCount, 복원=$restoreCount, 건너뜀=$skipCount"

if ($statusRows.Count -gt 0) {
    Write-Host ''
    Write-Host '최근 상태:'
    $statusRows |
        Select-Object -Last 5 |
        ForEach-Object { Write-Host ("- {0} {1}" -f $_.Time, $_.Status) }
}

if ($actionRows.Count -gt 0) {
    Write-Host ''
    Write-Host "dry-run에서 선택된 프로세스 상위 목록:"
    $actionRows |
        Group-Object -Property Process |
        Sort-Object -Property Count -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            $priority = @($_.Group | Where-Object { $_.Action -eq 'priority' }).Count
            $trim = @($_.Group | Where-Object { $_.Action -eq 'trim' }).Count
            Write-Host ("- {0}: 전체={1}, 우선순위={2}, 메모리정리={3}" -f $_.Name, $_.Count, $priority, $trim)
        }

    Write-Host ''
    Write-Host '최근 조치 이유:'
    $actionRows |
        Select-Object -Last $Top |
        ForEach-Object {
            $reason = if ([string]::IsNullOrWhiteSpace($_.Reason)) { $_.Detail } else { $_.Reason }
            $actionLabel = if ($_.Action -eq 'priority') { '우선순위' } else { '메모리정리' }
            Write-Host ("- {0} {1} {2}#{3}: {4}" -f $_.Time, $actionLabel, $_.Process, $_.Pid, $reason)
        }
} else {
    Write-Host ''
    Write-Host '우선순위 또는 메모리 정리 조치가 없습니다.'
}

if ($skipRows.Count -gt 0) {
    Write-Host ''
    Write-Host '최근 건너뛴 조치:'
    $skipRows |
        Select-Object -Last 5 |
        ForEach-Object { Write-Host ("- {0} {1}#{2}: {3}" -f $_.Time, $_.Process, $_.Pid, $_.Reason) }
}

if ($ShowRecent) {
    Write-Host ''
    Write-Host '최근 원본 로그:'
    $lines | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
}



