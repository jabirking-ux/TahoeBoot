@echo off
title TahoeBoot USB Passthrough
cls
echo ===================================================
echo  TahoeBoot: Physical USB Drive Passthrough (usbipd)
echo ===================================================
echo.

set USBIPD="C:\Program Files\usbipd-win\usbipd.exe"
if not exist %USBIPD% (
    echo ERROR: usbipd is not installed.
    pause
    exit /b 1
)

echo [1/3] Finding USB Flash Drive...
for /f "tokens=1" %%i in ('%USBIPD% list ^| findstr /i "Mass"') do set BUSID=%%i

if "%BUSID%"=="" (
    echo No USB Mass Storage device found. Please make sure your USB drive is plugged in.
    pause
    exit /b 1
)

echo Found USB Drive at Bus ID: %BUSID%
echo.
echo [2/3] Sharing USB Drive with hypervisor...
%USBIPD% bind --busid %BUSID% --force
echo.
echo [3/3] Attaching USB Drive to WSL2...
%USBIPD% attach --wsl --busid %BUSID%
echo.
if %errorlevel% equ 0 (
    echo ===================================================
    echo  SUCCESS: Physical USB drive attached to hypervisor!
    echo  It is now passed directly into macOS Disk Utility!
    echo ===================================================
) else (
    echo Status / Exit code: %errorlevel%
)
echo.
pause
