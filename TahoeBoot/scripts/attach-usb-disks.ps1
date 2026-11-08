<#
.SYNOPSIS
    TahoeBoot Physical USB Disk Passthrough & Universal x64 USB Flasher
    (`TahoeBoot/scripts/attach-usb-disks.ps1`)
.DESCRIPTION
    1. Detects all physical USB drives plugged into this Windows PC (`BusType -eq 'USB'`)
       and attaches them directly into WSL2 (`wsl --mount \\.\PhysicalDriveN --bare`)
       so `TahoeBoot/qemu/launch-vm.sh` passes the physical USB drive straight into
       macOS Tahoe Disk Utility & the macOS Installer!
    2. Never auto-formats your USB drive — you control formatting inside macOS Disk Utility.
    3. Can also install the Universal x64 OpenCore 1.0.8 EFI (`TahoeBoot\opencore\EFI`)
       onto any USB drive's EFI System Partition so it boots on ANY Intel/AMD x64 PC!
#>
param(
    [switch]$InstallUniversalEfiToUsb,
    [int]$DiskNumber = -1
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$EfiSource = Join-Path $RepoRoot "TahoeBoot\opencore\EFI"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[TahoeBoot USB] Requesting Administrator elevation to attach physical drive to WSL2..." -ForegroundColor Yellow
    $argsList = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    if ($InstallUniversalEfiToUsb) { $argsList += " -InstallUniversalEfiToUsb" }
    if ($DiskNumber -ge 0) { $argsList += " -DiskNumber $DiskNumber" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argsList -Wait
    exit 0
}

Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host " TahoeBoot Physical USB Disk Passthrough & Universal x64 Boot Tool" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan

$usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
if (-not $usbDisks) {
    Write-Host "[TahoeBoot USB] No physical USB flash drive / external USB SSD is currently plugged in." -ForegroundColor Yellow
    Write-Host "  -> Please plug in your physical USB drive into any USB port on your PC." -ForegroundColor Green
    Write-Host "  -> Then run this script again (or launch the VM): it will pass the real physical USB drive" -ForegroundColor Green
    Write-Host "     directly into macOS Disk Utility & the installer as a raw USB 3.0 device without formatting it!" -ForegroundColor Green
    Write-Host "  -> Whenever you plug in a physical USB drive, re-run this script (or launch-vm.sh) and it will" -ForegroundColor Green
    Write-Host "     be passed through directly to the macOS Tahoe VM!" -ForegroundColor Green
    exit 0
}

foreach ($disk in $usbDisks) {
    if ($DiskNumber -ge 0 -and $disk.Number -ne $DiskNumber) {
        continue
    }
    $devId = "\\.\PhysicalDrive$($disk.Number)"
    $sizeGb = [math]::Round($disk.Size / 1GB, 2)
    Write-Host "[TahoeBoot USB] Found Physical USB Disk #$($disk.Number): $($disk.FriendlyName) ($sizeGb GB) [$devId]" -ForegroundColor Green

    if ($InstallUniversalEfiToUsb) {
        $espPart = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $_.PartitionNumber -eq 1 } | Select-Object -First 1
        if ($espPart) {
            $driveLetter = $espPart.DriveLetter
            if (-not $driveLetter) {
                Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $espPart.PartitionNumber -AssignDriveLetter -ErrorAction SilentlyContinue
                $espPart = Get-Partition -DiskNumber $disk.Number -PartitionNumber $espPart.PartitionNumber
                $driveLetter = $espPart.DriveLetter
            }
            if ($driveLetter) {
                Write-Host "[TahoeBoot USB] Copying Universal x64 OpenCore 1.0.8 EFI (with RestrictEvents + FeatureUnlock + VirtualSMC) to $($driveLetter):\EFI..." -ForegroundColor Cyan
                Copy-Item -Path "$EfiSource\*" -Destination "$($driveLetter):\EFI\" -Recurse -Force
                Write-Host "[TahoeBoot USB] Universal x64 OpenCore EFI installed on USB Disk #$($disk.Number)!" -ForegroundColor Green
            }
        }
    }

    Write-Host "[TahoeBoot USB] Releasing Windows volume lock (taking Disk #$($disk.Number) offline)..." -ForegroundColor Cyan
    Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction SilentlyContinue

    Write-Host "[TahoeBoot USB] Mounting $devId into WSL2 (--bare) for direct QEMU USB 3.0 passthrough..." -ForegroundColor Cyan
    wsl --mount $devId --bare
}

Write-Host "[TahoeBoot USB] Physical USB disk(s) attached to WSL2. Launching or restarting VM will expose them directly in Disk Utility!" -ForegroundColor Green
