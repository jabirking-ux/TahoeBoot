@echo off
title TahoeBoot macOS Tahoe VM + USB Passthrough
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtual Machine
echo ===================================================================
echo.
set USBIPD="C:\Program Files\usbipd-win\usbipd.exe"
if exist %USBIPD% (
    echo [TahoeBoot USB] Ensuring hypervisor is running and attaching USB drive...
    wsl.exe -d Ubuntu -e true
    %USBIPD% bind --hardware-id 346d:5678 --force >nul 2>&1
    start "" /b %USBIPD% attach --wsl --hardware-id 346d:5678 --auto-attach >nul 2>&1
)
echo.
echo Starting macOS Tahoe VM...
echo.

wsl.exe -d Ubuntu -u root -- bash -lc "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir TAHOEBOOT_SKIP_GPU_CHECK=1 TAHOEBOOT_CPUS=6 TAHOEBOOT_MEMORY_MIB=8192; exec /mnt/c/Users/User/Documents/Tahoe/TahoeBoot/qemu/launch-vm.sh"

if %errorlevel% neq 0 (
    echo.
    echo VM exited with code: %errorlevel%
    pause
)
