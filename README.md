# CalmKeeper

CalmKeeper는 Windows에서 CPU/RAM 압박이 높아질 때 백그라운드 앱을 조심스럽게 진정시키는 보호 도구입니다.

앱을 강제로 종료하지 않습니다. 현재 사용 중인 앱과 Windows 핵심 프로세스를 보호하면서, 안전한 백그라운드 후보에만 보수적인 조치를 합니다.

- 백그라운드 프로세스 우선순위를 `Normal`에서 `BelowNormal`로 낮춤
- RAM 압박이 높을 때 메모리 작업셋 working set 정리
- 시스템이 안정되면 기억해 둔 우선순위 복원
- 트레이 아이콘에서 상태, 모드, 마지막 확인, 마지막 조치, 일시정지, 지금 확인, 설정, 로그, 종료 제공
- 중복 실행 방지

## 실행

일반 실행:

```bat
run-calmkeeper.cmd
```

이 실행 파일은 터미널 창을 계속 열어두지 않습니다. `wscript.exe`를 통해 CalmKeeper를 숨김 백그라운드 프로세스로 띄웁니다.

처음에는 실제 조치를 하지 않는 dry-run으로 관찰하는 것을 추천합니다.

```bat
run-dryrun.cmd
```

dry-run도 터미널 창 없이 트레이에서 실행됩니다.

Windows 11에서는 트레이 아이콘이 시계 근처의 `^` 숨겨진 아이콘 안에 들어갈 수 있습니다.

1회 dry-run 테스트:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CalmKeeper.ps1 -Once -WhatIf -NoTray
```

강제 dry-run 자가 테스트:

```bat
run-selftest.cmd
```

## 체크 주기

기본값은 **5초마다 확인**입니다.

설정 파일의 `checkIntervalSeconds` 값으로 바꿀 수 있습니다.

```json
"checkIntervalSeconds": 5
```

분으로 환산하면 약 **0.08분마다**입니다. 너무 짧게 줄이면 CalmKeeper 자체가 부담이 될 수 있으니 5초 아래로 낮추는 것은 추천하지 않습니다.

## 로그 분석

dry-run을 켠 뒤 CalmKeeper가 어떤 프로세스를 건드릴 뻔했는지 요약합니다.

```bat
analyze-log.cmd
```

또는 직접 실행:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Analyze-CalmKeeperLog.ps1
```

요약에는 조치 수, 많이 선택된 프로세스, 최근 조치 이유, 건너뛴 조치, 최근 상태가 표시됩니다. active 모드로 쓰기 전에 이 결과를 보고 보호 목록과 기준값을 조정하는 것이 안전합니다.

## Windows 시작 시 자동 실행

시작프로그램 등록:

```bat
install-startup.cmd
```

시작프로그램 제거:

```bat
uninstall-startup.cmd
```

## 설정

설정 파일:

```text
calmkeeper.config.json
```

주요 항목:

- `checkIntervalSeconds`: 확인 주기. 기본 5초
- `cpuHighPercent`: CPU 압박으로 판단할 기준
- `memoryHighPercent`: RAM 압박으로 판단할 기준
- `cpuCoolPercent`, `memoryCoolPercent`: 안정 상태로 보고 우선순위를 복원할 기준
- `foregroundGraceSeconds`: 최근 사용한 앱을 보호하는 시간
- `perProcessActionCooldownSeconds`: 같은 프로세스를 반복해서 건드리지 않는 시간
- `maxCpuPercentForMemoryTrim`: CPU를 쓰는 중인 프로세스는 메모리 정리에서 보호하는 기준
- `requirePagingForMemoryTrim`: RAM 사용률만 높을 때는 정리하지 않고 실제 페이징/가용 메모리 부족을 함께 확인
- `memoryPagesPerSecHigh`: 메모리 페이징이 높다고 볼 기준
- `minimumAvailableMemoryMB`: 사용 가능 메모리가 이 값보다 낮으면 RAM 압박으로 판단
- `memoryEmergencyPercent`: RAM 긴급 상태 기준
- `protectForegroundProcessName`: 최근 사용한 앱과 같은 이름의 helper 프로세스도 보호
- `protectForegroundChildren`: `true`면 포그라운드 앱의 자식 프로세스(렌더러, 언어 서버 등)도 보호. 기본값 `true`
- `foregroundChildrenDepth`: 자식 보호 시 조상을 몇 단계까지 올라갈지. 기본값 `4` (증손자까지)
- `protectedProcessNames`: 절대 건드리지 않을 프로세스 목록
- `dryRun`: `true`면 실제 변경 없이 로그만 남김

현재 기본값은 버벅임 방지를 우선해서 보수적으로 잡혀 있습니다.

- RAM 조치는 88% 이상부터 시작
- RAM이 높아도 Pages/sec와 사용 가능 메모리가 정상이라면 작업셋 정리를 하지 않음
- 최근 사용 앱 이름은 5분 동안 보호
- 같은 프로세스는 기본 10분 동안 반복 조치하지 않음
- Chrome, Edge, Claude, ChatGPT, OneDrive, KakaoTalk, Telegram 같은 인터랙티브 앱은 기본 보호 목록에 포함
- 상태 로그는 기본 60초 간격으로 제한해 로그 폭주를 줄임

설정 파일을 저장하면 다음 체크 주기에 자동으로 반영됩니다. CalmKeeper를 재시작하지 않아도 됩니다.

## 역할 분리

CalmKeeper가 맡는 일:

- 백그라운드 앱의 CPU/RAM 부담 완화
- 활성 앱 보호
- 안전 후보만 우선순위 낮추기/메모리 작업셋 정리

CalmKeeper가 맡지 않는 일:

- 그래픽 드라이버 reset 해결
- CPU 발열/펌웨어 throttling 해결
- 전원 모드/BIOS/드라이버 자동 변경
- 앱 강제 종료

그래픽 reset, CPU 제한, 전원/드라이버 문제는 별도 진단 도구에서 다루는 것이 맞습니다.
