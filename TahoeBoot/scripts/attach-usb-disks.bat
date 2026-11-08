@echo off
title TahoeBoot USB Passthrough
cls
echo ===================================================
echo  TahoeBoot: Physical USB Drive Passthrough (usbipd)
echo ===================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$b = (& 'C:\Program Files\usbipd-win\usbipd.exe' list | Where-Object { $_ -match 'Mass' } | ForEach-Object { ($_ -split '\s+')[0] });" ^
    "if (-not $b) { Write-Host 'No USB Mass Storage device found. Please plug in your USB drive.' -ForegroundColor Yellow; exit 1 };" ^
    "Write-Host ('Found USB Drive at Bus ID: ' + $b) -ForegroundColor Green;" ^
    "Write-Host 'Sharing USB Drive with hypervisor...' -ForegroundColor Cyan;" ^
    "& 'C:\Program Files\usbipd-win\usbipd.exe' bind --busid $b --force;" ^
    "Write-Host 'Attaching USB Drive to WSL2...' -ForegroundColor Cyan;" ^
    "& 'C:\Program Files\usbipd-win\usbipd.exe' attach --wsl --busid $b;" ^
    "if ($LASTEXITCODE -eq 0) { Write-Host '===================================================' -ForegroundColor Green; Write-Host ' SUCCESS: Physical USB drive attached to hypervisor!' -ForegroundColor Green; Write-Host ' Open macOS Recovery Disk Utility to see your drive!' -ForegroundColor Green; Write-Host '===================================================' -ForegroundColor Green } else { Write-Host ('Status / Exit code: ' + $LASTEXITCODE) -ForegroundColor Yellow }"

echo.
pause
