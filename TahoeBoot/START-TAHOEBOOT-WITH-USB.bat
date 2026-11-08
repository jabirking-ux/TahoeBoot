@echo off
title TahoeBoot macOS Tahoe VM + USB Passthrough
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtual Machine
echo ===================================================================
echo.
echo [1/2] Connecting physical USB drive to hypervisor...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$b = (& 'C:\Program Files\usbipd-win\usbipd.exe' list 2>$null | Where-Object { $_ -match 'Mass' } | ForEach-Object { ($_ -split '\s+')[0] });" ^
    "if ($b) { & 'C:\Program Files\usbipd-win\usbipd.exe' bind --busid $b --force 2>$null; & 'C:\Program Files\usbipd-win\usbipd.exe' attach --wsl --busid $b 2>$null; Write-Host ('USB drive attached on Bus ' + $b) -ForegroundColor Green }"
echo.
echo [2/2] Starting macOS Tahoe VM...
echo.

wsl.exe -d Ubuntu -u root -- bash -lc "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir TAHOEBOOT_SKIP_GPU_CHECK=1 TAHOEBOOT_CPUS=6 TAHOEBOOT_MEMORY_MIB=8192; exec /mnt/c/Users/User/Documents/Tahoe/TahoeBoot/qemu/launch-vm.sh"

if %errorlevel% neq 0 (
    echo.
    echo VM exited with code: %errorlevel%
    pause
)
