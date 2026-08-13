@echo off
chcp 65001 >nul
title Test DeepSeek Visible Streaming
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DeepSeek-Visible-Streaming.ps1"
echo.
pause
