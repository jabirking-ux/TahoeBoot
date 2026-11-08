@echo off
title TahoeBoot macOS Tahoe VM + USB Passthrough
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtual Machine
echo ===================================================================
echo.
echo [1/2] Connecting physical USB drive to VM...
powershell -NoProfile -Command "Get-Disk | Where-Object BusType -eq 'USB' | Set-Disk -IsOffline $true" >nul 2>&1
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "Get-Disk | Where-Object BusType -eq 'USB' | Select-Object -ExpandProperty Number -First 1"') do (
    wsl.exe --mount \\.\PhysicalDrive%%i --bare >nul 2>&1
)
echo.
echo [2/2] Starting macOS Tahoe VM...
echo.

wsl.exe -d Ubuntu -u root -- bash -lc "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir TAHOEBOOT_SKIP_GPU_CHECK=1 TAHOEBOOT_CPUS=6 TAHOEBOOT_MEMORY_MIB=8192; exec /mnt/c/Users/User/Documents/Tahoe/TahoeBoot/qemu/launch-vm.sh"

if %errorlevel% neq 0 (
    echo.
    echo VM exited with code: %errorlevel%
    pause
)
