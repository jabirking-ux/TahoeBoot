#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Host Disk & Windows Dual-Boot Mirror Generator
# (`TahoeBoot/scripts/create-host-disk-mirror.sh`)
# =============================================================================
# Builds a sparse GPT disk image (`host-disks-mirror.qcow2`, 477 GiB / 512 GB)
# mirroring the host's physical `WAR 512GB` NVMe SSD layout so that when
# running inside WSL2 (where Windows locks `\\.\PhysicalDrive0`), both the
# OpenCore 1.0.8 boot picker and macOS Tahoe Disk Utility / Finder see:
#   - Partition 1: EFI System Partition (100 MiB FAT32) containing the real
#                  Windows Boot Manager (`\EFI\Microsoft\Boot\bootmgfw.efi`
#                  from `C:\Windows\Boot\EFI`), so **Windows** appears in the
#                  OpenCore graphical boot picker!
#   - Partition 2: Microsoft Reserved Partition (16 MiB MSR)
#   - Partition 3: `Windows (C:)` (412 GiB partition)
#   - Partition 4: `Local Disk (D:)` (63 GiB partition)
#
# Strictly READ-ONLY on host files: NEVER modifies or formats any real host disk!
# =============================================================================
set -euo pipefail

OUT_QCOW2="${1:-/root/tahoe-vm-fast/host-disks-mirror.qcow2}"
TMP_ESP="$(mktemp /tmp/win-esp-XXXXXX.fat32)"
TMP_RAW="$(mktemp /tmp/host-mirror-XXXXXX.raw)"

cleanup() {
    rm -f "${TMP_ESP}" "${TMP_RAW}"
}
trap cleanup EXIT

echo "[TahoeBoot Dual-Boot] Building 100 MiB Windows EFI System Partition image from C:\\Windows\\Boot\\EFI..."
dd if=/dev/zero of="${TMP_ESP}" bs=1M count=100 status=none
mkfs.vfat -F 32 -n "SYSTEM" "${TMP_ESP}" >/dev/null

mmd -i "${TMP_ESP}" ::/EFI ::/EFI/Microsoft ::/EFI/Microsoft/Boot ::/EFI/Microsoft/Recovery ::/EFI/Boot
if [[ -f "/mnt/c/Windows/Boot/EFI/bootmgfw.efi" ]]; then
    mcopy -i "${TMP_ESP}" /mnt/c/Windows/Boot/EFI/bootmgfw.efi ::/EFI/Microsoft/Boot/bootmgfw.efi
    mcopy -i "${TMP_ESP}" /mnt/c/Windows/Boot/EFI/bootmgr.efi ::/EFI/Microsoft/Boot/bootmgr.efi || true
    mcopy -i "${TMP_ESP}" /mnt/c/Windows/Boot/EFI/memtest.efi ::/EFI/Microsoft/Boot/memtest.efi || true
fi

# Create sparse 512 GB (512110190592 bytes) raw image matching WAR 512GB NVMe
truncate -s 512110190592 "${TMP_RAW}"

# Partition with sgdisk to match the host's WAR 512GB NVMe GPT layout:
#   1: 100 MiB EFI System Partition (C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
#   2: 16 MiB Microsoft Reserved (E3C9E316-0B5C-4DB8-817D-F92DF00215AE)
#   3: 412 GiB Windows (C:) Basic Data (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
#   4: 62 GiB Local Disk (D:) Basic Data (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
sgdisk -Z "${TMP_RAW}" >/dev/null
sgdisk \
    -n 1:2048:+100M -t 1:ef00 -c 1:"EFI System Partition" \
    -n 2:0:+16M     -t 2:0c01 -c 2:"Microsoft reserved partition" \
    -n 3:0:+412G    -t 3:0700 -c 3:"Windows (C:)" \
    -n 4:0:+62G     -t 4:0700 -c 4:"Local Disk (D:)" \
    "${TMP_RAW}" >/dev/null

# Write the populated 100 MiB FAT32 Windows ESP into Partition 1 (LBA 2048 = 1 MiB offset)
dd if="${TMP_ESP}" of="${TMP_RAW}" bs=1M seek=1 conv=notrunc status=none

mkdir -p "$(dirname "${OUT_QCOW2}")"
qemu-img convert -f raw -O qcow2 "${TMP_RAW}" "${OUT_QCOW2}"
echo "[TahoeBoot Dual-Boot] Created sparse host NVMe mirror at ${OUT_QCOW2}:"
qemu-img info "${OUT_QCOW2}"
