@echo off
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel% equ 0 (pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1") else (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1")
if errorlevel 1 pause
