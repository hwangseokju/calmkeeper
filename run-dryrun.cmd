@echo off
set "SCRIPT_DIR=%~dp0"
start "CalmKeeper Dry Run" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%CalmKeeper.ps1" -WhatIf
