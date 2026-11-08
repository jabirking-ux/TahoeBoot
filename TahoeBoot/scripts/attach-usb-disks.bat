@echo off
title TahoeBoot USB Passthrough
cls
echo ===================================================
echo  TahoeBoot: Physical USB Drive Passthrough (usbipd)
echo ===================================================
echo.

set USBIPD="C:\Program Files\usbipd-win\usbipd.exe"

echo [1/3] Ensuring WSL2 is running...
wsl.exe -d Ubuntu -e true

echo [2/3] Sharing USB Drive (346d:5678) with hypervisor...
%USBIPD% bind --hardware-id 346d:5678 --force

echo [3/3] Attaching USB Drive to WSL2 (auto-attach enabled)...
%USBIPD% attach --wsl --hardware-id 346d:5678 --auto-attach

echo.
echo ===================================================
echo  Done! If you just installed usbipd for the first time,
echo  please UNPLUG your USB drive and PLUG IT BACK IN now!
echo ===================================================
echo.
pause
