#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Host Disk & Windows Dual-Boot Mirror + Bidirectional Sync Generator
# (`TahoeBoot/scripts/create-host-disk-mirror.sh`)
# =============================================================================
# Builds a sparse GPT disk image (`host-disks-mirror.qcow2`, 477 GiB / 512 GB)
# mirroring the host's physical `WAR 512GB` NVMe SSD layout so that when
# running inside WSL2 (where Windows locks `\\.\PhysicalDrive0`), BOTH the
# OpenCore 1.0.8 boot picker AND macOS Tahoe Disk Utility / Finder immediately
# show and mount all host volumes in the default sidebar:
#   - Partition 1: EFI System Partition (100 MiB FAT32) containing the real
#                  Windows Boot Manager (`\EFI\Microsoft\Boot\bootmgfw.efi`
#                  from `C:\Windows\Boot\EFI`), so **Windows** appears in the
#                  OpenCore graphical boot picker!
#   - Partition 2: Microsoft Reserved Partition (16 MiB MSR)
#   - Partition 3: `Windows (C:)` (412 GiB formatted exFAT volume synced with
#                  `C:\MacOS_Physical_Sync` and `C:\Users\User\Desktop\MacOS_Physical_Sync`)
#   - Partition 4: `Local Disk (D:)` (62 GiB formatted exFAT volume synced with
#                  `D:\MacOS_Physical_Sync` and top-level files on `D:\`)
#
# Why exFAT on Partitions 3 & 4 inside the mirror image?
#   1. In macOS Disk Utility's default "Show Only Volumes" view, unformatted
#      partitions are hidden. Formatting Partitions 3 & 4 with valid exFAT
#      superblocks causes macOS `diskarbitrationd` to mount BOTH `Windows (C:)`
#      and `Local Disk (D:)` READ-WRITE in Disk Utility and `/Volumes/`!
#   2. Paired with `TahoeBoot/scripts/sync-host-disks.sh`, any file created or
#      edited on `Windows (C:)` or `Local Disk (D:)` in macOS persists directly
#      onto the real Windows `C:\` and `D:\` physical SSD when you reboot to
#      Windows!
#
# Strictly SAFE on host files: NEVER formats any real host partition!
# =============================================================================
set -euo pipefail

OUT_QCOW2="${1:-/root/tahoe-vm-fast/host-disks-mirror.qcow2}"
TMP_ESP="$(mktemp /tmp/win-esp-XXXXXX.fat32)"
TMP_RAW="/root/tahoe-vm-fast/host-disks-mirror.raw"
MNT_C_IMG="/tmp/tahoe-mnt-win-c"
MNT_D_IMG="/tmp/tahoe-mnt-win-d"

mkdir -p "$(dirname "${OUT_QCOW2}")" "${MNT_C_IMG}" "${MNT_D_IMG}"

cleanup() {
    umount "${MNT_C_IMG}" 2>/dev/null || true
    umount "${MNT_D_IMG}" 2>/dev/null || true
    if [[ -n "${LOOP_DEV:-}" ]]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
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
rm -f "${TMP_RAW}"
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

# Attach loop device with partition scanning so we can format Partitions 3 and 4
# with real Read-Write exFAT filesystems (visible in macOS Disk Utility & Finder!)
LOOP_DEV="$(losetup --find --show -P "${TMP_RAW}")"
partprobe "${LOOP_DEV}" 2>/dev/null || true
sleep 1

if [[ -b "${LOOP_DEV}p3" ]] && command -v mkfs.exfat >/dev/null 2>&1; then
    echo "[TahoeBoot Dual-Boot] Formatting Partition 3 as R/W exFAT volume 'Windows_C' (412 GiB)..."
    mkfs.exfat -L "Windows_C" "${LOOP_DEV}p3" >/dev/null
    if mount -t exfat "${LOOP_DEV}p3" "${MNT_C_IMG}" 2>/dev/null; then
        mkdir -p "/mnt/c/MacOS_Physical_Sync" "/mnt/c/Users/User/Desktop/MacOS_Physical_Sync" 2>/dev/null || true
        cat > "${MNT_C_IMG}/README_WINDOWS_C_SYNC.txt" <<'EOF'
===============================================================================
TAHOEBOOT PHYSICAL DRIVE R/W BRIDGE — Windows (C:)
===============================================================================
Any file or folder you create or modify on this "Windows_C" volume in macOS
is automatically synchronized to your physical Windows NVMe SSD at:
  - C:\MacOS_Physical_Sync\
  - C:\Users\User\Desktop\MacOS_Physical_Sync\
when you close or reboot the VM into Windows!

For instant live access to the entire C:\ and D:\ filesystem trees while the VM
is running, open Finder -> Connect to Server (Cmd + K) ->
  smb://guest:@10.0.2.2/Windows_C
  smb://guest:@10.0.2.2/LocalDisk_D
===============================================================================
EOF
        cp -rf /mnt/c/MacOS_Physical_Sync/* "${MNT_C_IMG}/" 2>/dev/null || true
        cp -rf /mnt/c/Users/User/Desktop/MacOS_Physical_Sync/* "${MNT_C_IMG}/" 2>/dev/null || true
        sync
        umount "${MNT_C_IMG}"
    fi
fi

if [[ -b "${LOOP_DEV}p4" ]] && command -v mkfs.exfat >/dev/null 2>&1; then
    echo "[TahoeBoot Dual-Boot] Formatting Partition 4 as R/W exFAT volume 'LocalDisk_D' (62 GiB)..."
    mkfs.exfat -L "LocalDisk_D" "${LOOP_DEV}p4" >/dev/null
    if mount -t exfat "${LOOP_DEV}p4" "${MNT_D_IMG}" 2>/dev/null; then
        mkdir -p "/mnt/d/MacOS_Physical_Sync" 2>/dev/null || true
        cat > "${MNT_D_IMG}/README_LOCALDISK_D_SYNC.txt" <<'EOF'
===============================================================================
TAHOEBOOT PHYSICAL DRIVE R/W BRIDGE — Local Disk (D:)
===============================================================================
Any file or folder you create or modify on this "LocalDisk_D" volume in macOS
is automatically synchronized directly to your physical Windows D:\ drive at:
  - D:\MacOS_Physical_Sync\
  - D:\ (top-level synced files)
when you close or reboot the VM into Windows!
===============================================================================
EOF
        # Copy small top-level documents/files (< 25 MB) from D:\ so the user sees their actual D:\ files immediately
        find /mnt/d -maxdepth 1 -type f -size -25M \
            ! -name "pagefile.sys" ! -name "DumpStack.log.tmp" ! -name "*.ini" \
            -exec cp -f {} "${MNT_D_IMG}/" \; 2>/dev/null || true
        cp -rf /mnt/d/MacOS_Physical_Sync/* "${MNT_D_IMG}/" 2>/dev/null || true
        sync
        umount "${MNT_D_IMG}"
    fi
fi

losetup -d "${LOOP_DEV}"
LOOP_DEV=""

qemu-img convert -f raw -O qcow2 "${TMP_RAW}" "${OUT_QCOW2}"
echo "[TahoeBoot Dual-Boot] Created formatted & populated host NVMe mirror at ${OUT_QCOW2}:"
qemu-img info "${OUT_QCOW2}"
