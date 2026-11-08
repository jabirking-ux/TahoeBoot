@echo off
title TahoeBoot macOS Tahoe VM + USB Passthrough
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtual Machine
echo ===================================================================
echo.
set USBIPD="C:\Program Files\usbipd-win\usbipd.exe"
if exist %USBIPD% (
    for /f "tokens=1" %%i in ('%USBIPD% list ^| findstr /i "Mass"') do set BUSID=%%i
    if not "%BUSID%"=="" (
        echo [TahoeBoot USB] Attaching USB Drive (Bus %BUSID%) to hypervisor...
        %USBIPD% bind --busid %BUSID% --force >nul 2>&1
        %USBIPD% attach --wsl --busid %BUSID% >nul 2>&1
        echo [TahoeBoot USB] Physical USB drive attached.
    )
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
