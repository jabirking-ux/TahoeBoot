@echo off
title TahoeBoot macOS Tahoe VM
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtual Machine
echo ===================================================================
echo.
echo Starting macOS Tahoe VM...
echo.

wsl.exe -d Ubuntu -u root -- bash -lc "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir TAHOEBOOT_SKIP_GPU_CHECK=1 TAHOEBOOT_CPUS=6 TAHOEBOOT_MEMORY_MIB=8192; exec /mnt/c/Users/User/Documents/Tahoe/TahoeBoot/qemu/launch-vm.sh"

if %errorlevel% neq 0 (
    echo.
    echo VM exited with error code: %errorlevel%
    pause
)
