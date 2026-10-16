@echo off
setlocal
title DrumTrainer
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Latest.ps1"
if errorlevel 1 pause
