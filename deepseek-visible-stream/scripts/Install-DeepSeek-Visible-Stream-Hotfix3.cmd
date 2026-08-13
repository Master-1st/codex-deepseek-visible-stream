@echo off
chcp 65001 >nul
title Install DeepSeek Codex Router 3.4
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DeepSeek-Visible-Stream-Hotfix3.ps1"
if errorlevel 1 (
  echo.
  echo Installation failed. See the error above.
)
echo.
pause
