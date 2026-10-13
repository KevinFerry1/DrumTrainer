@echo off
setlocal
title DrumTrainer Windows
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DrumTrainer.ps1"
if errorlevel 1 (
  echo.
  echo DrumTrainer could not start. Read the message above for details.
  pause
)
