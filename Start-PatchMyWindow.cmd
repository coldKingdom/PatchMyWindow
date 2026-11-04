@echo off
setlocal
set "PSHOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSHOST=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PSHOST%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0PatchMyWindow.ps1"
if errorlevel 1 pause
