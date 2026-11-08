#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Host Disk Bidirectional Persistence Sync
# (`TahoeBoot/scripts/sync-host-disks.sh`)
# =============================================================================
# Ensures any file or folder created or modified inside macOS Tahoe on the
# `Windows_C` or `LocalDisk_D` partitions of `host-disks-mirror.qcow2` is
# written directly onto the real Windows physical NVMe SSD (`C:\` and `D:\`)
# so changes persist when rebooting to Windows!
# =============================================================================
set -euo pipefail

HOST_MIRROR="${1:-/root/tahoe-vm-fast/host-disks-mirror.qcow2}"
if [[ ! -f "${HOST_MIRROR}" ]]; then
    exit 0
fi

MNT_C_IMG="/tmp/tahoe-sync-win-c"
MNT_D_IMG="/tmp/tahoe-sync-win-d"
mkdir -p "${MNT_C_IMG}" "${MNT_D_IMG}"

cleanup() {
    umount "${MNT_C_IMG}" 2>/dev/null || true
    umount "${MNT_D_IMG}" 2>/dev/null || true
    if [[ -n "${NBD_DEV:-}" ]]; then
        qemu-nbd -d "${NBD_DEV}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

modprobe nbd max_part=16 2>/dev/null || true

NBD_DEV=""
for dev in /dev/nbd0 /dev/nbd1 /dev/nbd2 /dev/nbd3; do
    if [[ -b "${dev}" ]] && qemu-nbd -c "${dev}" "${HOST_MIRROR}" 2>/dev/null; then
        NBD_DEV="${dev}"
        break
    fi
done

if [[ -n "${NBD_DEV}" ]]; then
    partprobe "${NBD_DEV}" 2>/dev/null || true
    sleep 1

    # Sync Partition 3 (Windows_C) -> C:\MacOS_Physical_Sync and Desktop\MacOS_Physical_Sync
    if [[ -b "${NBD_DEV}p3" ]] && mount -t exfat -o ro "${NBD_DEV}p3" "${MNT_C_IMG}" 2>/dev/null; then
        echo "[TahoeBoot Sync] Syncing macOS changes from Windows_C partition to C:\\MacOS_Physical_Sync & Desktop..."
        mkdir -p "/mnt/c/MacOS_Physical_Sync" "/mnt/c/Users/User/Desktop/MacOS_Physical_Sync" 2>/dev/null || true
        rsync -rt --exclude=".Spotlight-V100" --exclude=".fseventsd" --exclude=".Trashes" --exclude="._*" \
            "${MNT_C_IMG}/" "/mnt/c/MacOS_Physical_Sync/" 2>/dev/null || true
        rsync -rt --exclude=".Spotlight-V100" --exclude=".fseventsd" --exclude=".Trashes" --exclude="._*" \
            "${MNT_C_IMG}/" "/mnt/c/Users/User/Desktop/MacOS_Physical_Sync/" 2>/dev/null || true
        umount "${MNT_C_IMG}"
    fi

    # Sync Partition 4 (LocalDisk_D) -> D:\MacOS_Physical_Sync and D:\
    if [[ -b "${NBD_DEV}p4" ]] && mount -t exfat -o ro "${NBD_DEV}p4" "${MNT_D_IMG}" 2>/dev/null; then
        echo "[TahoeBoot Sync] Syncing macOS changes from LocalDisk_D partition to physical D:\\ drive..."
        mkdir -p "/mnt/d/MacOS_Physical_Sync" 2>/dev/null || true
        rsync -rt --exclude=".Spotlight-V100" --exclude=".fseventsd" --exclude=".Trashes" --exclude="._*" \
            "${MNT_D_IMG}/" "/mnt/d/MacOS_Physical_Sync/" 2>/dev/null || true
        rsync -rt --ignore-existing --exclude=".Spotlight-V100" --exclude=".fseventsd" --exclude=".Trashes" --exclude="._*" \
            "${MNT_D_IMG}/" "/mnt/d/" 2>/dev/null || true
        umount "${MNT_D_IMG}"
    fi
fi

# Also mirror between D:\MacOS_Physical_Sync and C:\Users\User\Desktop\MacOS_Physical_Sync
if [[ -d "/mnt/d/MacOS_Physical_Sync" && -d "/mnt/c/Users/User/Desktop" ]]; then
    mkdir -p "/mnt/c/Users/User/Desktop/MacOS_Physical_Sync" 2>/dev/null || true
    rsync -rt --exclude=".Spotlight-V100" --exclude=".fseventsd" --exclude=".Trashes" --exclude="._*" \
        "/mnt/d/MacOS_Physical_Sync/" "/mnt/c/Users/User/Desktop/MacOS_Physical_Sync/" 2>/dev/null || true
fi
sync
echo "[TahoeBoot Sync] All macOS physical drive changes flushed to Windows C:\\ and D:\\."
