@echo off
title TahoeBoot macOS Tahoe VM
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtual Machine
echo ===================================================================
echo.
echo [1/2] Attaching physical USB drive to hypervisor...
wsl.exe --mount \\.\PhysicalDrive1 --bare 2>nul
if %errorlevel% equ 0 (
    echo       Physical USB drive attached successfully!
) else (
    echo       Note: To attach physical USB, right-click this .bat and choose 'Run as administrator'.
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
