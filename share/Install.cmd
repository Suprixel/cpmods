@echo off
setlocal
title cpmods setup
if not exist "%~dp0cpmods\setup.ps1" goto notextracted

where powershell >nul 2>nul
if errorlevel 1 goto nops5
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpmods\bootstrap.ps1"
goto done

:nops5
rem Windows PowerShell is missing: use PowerShell 7 directly when it is installed
set "PW="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PW=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PW if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PW=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not defined PW goto nopwsh
"%PW%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpmods\setup.ps1"

:done
if errorlevel 1 goto fail
echo.
pause
exit /b 0

:nopwsh
echo PowerShell is missing on this PC. Install PowerShell 7 (the file ending in win-x64.msi), then run Install.cmd again.
start "" "https://github.com/PowerShell/PowerShell/releases/latest"

:fail
echo.
echo Setup did not finish. Read the message above, fix it, then run Install.cmd again.
echo If you are stuck, send this file to whoever gave you cpmods:
echo   %LOCALAPPDATA%\cpmods-setup.log
pause
exit /b 1

:notextracted
rem Started from inside the zip (only this file was unpacked): find the zip and unpack all of it
echo.
echo Install.cmd was opened from inside the zip, so the rest of cpmods is missing.
echo Looking for the zip to unpack it...
set "CPSELF=%~f0"
set "CPX=%LOCALAPPDATA%\cpmods-unpacked"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n = (Split-Path -Leaf (Split-Path -Parent $env:CPSELF)) -replace '^Temp\d+_', ''; $sf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue; $dirs = @($sf.'{374DE290-123F-4565-9164-39C4925E467B}', ($env:USERPROFILE + '\Downloads'), [Environment]::GetFolderPath('Desktop')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique; $z = Get-ChildItem -LiteralPath $dirs -Filter '*.zip' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $n -or $_.Name -like 'cpmods*.zip' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if (-not $z) { exit 2 }; if (Test-Path -LiteralPath $env:CPX) { Remove-Item -LiteralPath $env:CPX -Recurse -Force }; Expand-Archive -LiteralPath $z.FullName -DestinationPath $env:CPX -Force; Write-Host ('Unpacked ' + $z.FullName)"
if errorlevel 1 goto manual
if not exist "%CPX%\Install.cmd" goto manual
call "%CPX%\Install.cmd"
exit /b %errorlevel%

:manual
echo.
echo Could not find the zip by itself.
echo Right-click the zip file, choose "Extract All...", open the new folder, then double-click Install.cmd there.
pause
exit /b 1
