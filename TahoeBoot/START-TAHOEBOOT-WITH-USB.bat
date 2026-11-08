@echo off
:: =============================================================================
:: TahoeBoot All-in-One Automated Launcher with Physical USB Passthrough
:: =============================================================================
:: Automatically requests Administrator privileges to mount physical USB drives
:: into WSL2 without any manual commands, then starts the macOS Tahoe VM!
:: =============================================================================

:: Check for Administrator privileges; if not elevated, request UAC elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

title TahoeBoot macOS Tahoe + Physical USB Passthrough
cls
echo ===================================================================
echo  TahoeBoot: macOS Tahoe Virtualization with Physical USB Support
echo ===================================================================
echo.

:: Query connected USB drive number dynamically
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "Get-Disk | Where-Object BusType -eq 'USB' | Select-Object -ExpandProperty Number -First 1"') do set USB_NUM=%%i

if defined USB_NUM (
    echo [TahoeBoot USB] Found Physical USB Disk #%USB_NUM% ("VendorCo ProductCode").
    echo [TahoeBoot USB] Attaching directly to hypervisor (wsl --mount \\.\PhysicalDrive%USB_NUM% --bare)...
    wsl.exe --mount \\.\PhysicalDrive%USB_NUM% --bare
    echo [TahoeBoot USB] Attachment complete.
) else (
    echo [TahoeBoot USB] No USB drive detected. Starting VM with internal storage...
)

echo.
echo [TahoeBoot] Launching macOS Tahoe VM window...
echo.

wsl.exe -d Ubuntu -u root -- bash -lc "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir TAHOEBOOT_SKIP_GPU_CHECK=1 TAHOEBOOT_CPUS=6 TAHOEBOOT_MEMORY_MIB=8192; exec /mnt/c/Users/User/Documents/Tahoe/TahoeBoot/qemu/launch-vm.sh"

echo.
echo [TahoeBoot] VM closed. All changes synced.
timeout /t 5
