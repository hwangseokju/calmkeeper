# CalmKeeper

CalmKeeper is a small Windows background utility that gently reduces pressure when CPU or RAM usage gets high.

It does not kill apps. It protects the foreground app and common Windows system processes, then applies conservative actions to background candidates:

- lowers eligible background process priority from `Normal` to `BelowNormal`, or from `AboveNormal` to `Normal`
- trims working sets for memory-heavy background processes when RAM pressure is high
- restores remembered priorities after the machine cools down
- exposes Pause, config, log, and Exit through a tray icon
- prevents duplicate background instances

## Run

Double-click:

```bat
run-calmkeeper.cmd
```

Or run directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CalmKeeper.ps1
```

For a one-time dry-run test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CalmKeeper.ps1 -Once -WhatIf -NoTray
```

## Start with Windows

Double-click:

```bat
install-startup.cmd
```

To remove it from startup:

```bat
uninstall-startup.cmd
```

## Settings

Edit `calmkeeper.config.json`.

Useful knobs:

- `cpuHighPercent`: CPU level that triggers priority calming
- `memoryHighPercent`: RAM level that triggers working-set trimming
- `cpuCoolPercent` and `memoryCoolPercent`: levels that restore remembered priorities
- `foregroundGraceSeconds`: protects recently used foreground apps for a short time after switching away
- `perProcessActionCooldownSeconds`: avoids repeatedly touching the same process
- `maxCpuPercentForMemoryTrim`: avoids trimming busy processes unless memory is at emergency level
- `memoryEmergencyPercent`: allows more aggressive RAM trimming only when memory pressure is severe
- `protectedProcessNames`: processes never touched; keep Windows security, shell, and work-critical apps here
- `dryRun`: set to `true` to log what would happen without changing anything

## Notes

This is intentionally gentle. Windows already has a scheduler and memory manager; CalmKeeper helps most when lots of background apps are open and one or two are consuming resources while you are trying to keep the active app responsive.

The stricter defaults are designed to reduce stutter caused by the smoother itself: CPU actions require a real CPU delta sample, recently focused apps stay protected briefly, and memory trimming avoids processes that are actively using CPU.

No background utility can guarantee that every slowdown disappears; thermal throttling, failing disks, driver stalls, Windows Update, malware scans, and low physical RAM can still cause lag. CalmKeeper is built to reduce the common "too many background apps are open" case without making the active app worse.
