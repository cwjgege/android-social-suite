@echo off
set "SETUP_SCRIPT=%~dp0enable-android-hypervisor.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File %SETUP_SCRIPT%'"
