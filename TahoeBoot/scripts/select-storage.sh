#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Persistent Storage Selector (`TahoeBoot/scripts/select-storage.sh`)
# =============================================================================
# Safely discovers and mounts external persistent storage for the macOS Tahoe
# virtual machine by stable filesystem UUID (`UUID=...`) or label (`LABEL=TAHOE_VM`),
# NEVER relying on `/dev/sda` or `/dev/sdb` and strictly refusing any internal
# disk containing Windows (`NTFS` / `BitLocker` / `Microsoft reserved` / `Basic data`).
# =============================================================================
set -euo pipefail

MOUNT_POINT="${1:-/mnt/tahoe-storage}"
TARGET_LABEL="${TAHOEBOOT_STORAGE_LABEL:-TAHOE_VM}"
TARGET_UUID="${TAHOEBOOT_STORAGE_UUID:-}"

echo "[TahoeBoot Storage] Scanning block devices by stable UUID / LABEL..." >&2

# 1. If running in local workspace development mode where VMStorage/macos-tahoe exists directly:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_VMSTORAGE="$(cd "${SCRIPT_DIR}/../.." && pwd)/VMStorage"
if [[ -d "${LOCAL_VMSTORAGE}/macos-tahoe" ]]; then
    echo "[TahoeBoot Storage] Found workspace persistent storage at: ${LOCAL_VMSTORAGE}/macos-tahoe" >&2
    echo "${LOCAL_VMSTORAGE}/macos-tahoe"
    exit 0
fi

# 2. Check /dev/disk/by-uuid if TARGET_UUID is provided
DEV_NODE=""
if [[ -n "${TARGET_UUID}" && -e "/dev/disk/by-uuid/${TARGET_UUID}" ]]; then
    DEV_NODE="$(readlink -f "/dev/disk/by-uuid/${TARGET_UUID}")"
    echo "[TahoeBoot Storage] Resolved UUID=${TARGET_UUID} -> ${DEV_NODE}" >&2
elif [[ -e "/dev/disk/by-label/${TARGET_LABEL}" ]]; then
    DEV_NODE="$(readlink -f "/dev/disk/by-label/${TARGET_LABEL}")"
    echo "[TahoeBoot Storage] Resolved LABEL=${TARGET_LABEL} -> ${DEV_NODE}" >&2
fi

if [[ -z "${DEV_NODE}" ]]; then
    echo "ERROR [ERR_STORAGE_NOT_FOUND]: Persistent VM disk (LABEL=${TARGET_LABEL} or UUID=${TARGET_UUID}) not found." >&2
    echo "Available external block devices (non-Windows):" >&2
    lsblk -o NAME,RM,TRAN,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINT | grep -vE "ntfs|BitLocker" || true
    exit 10
fi

# 3. Safety verification: NEVER touch an internal disk that holds Windows / NTFS partitions
PARENT_DISK="$(lsblk -no PKNAME "${DEV_NODE}" | head -n1)"
if [[ -n "${PARENT_DISK}" ]]; then
    if lsblk -no FSTYPE "/dev/${PARENT_DISK}" | grep -qiE "ntfs|bitlocker"; then
        echo "CRITICAL SAFETY ABORT: Device ${DEV_NODE} shares physical disk /dev/${PARENT_DISK} with a Windows NTFS/BitLocker partition!" >&2
        exit 11
    fi
fi

mkdir -p "${MOUNT_POINT}"
if ! mountpoint -q "${MOUNT_POINT}"; then
    mount "${DEV_NODE}" "${MOUNT_POINT}"
fi

mkdir -p "${MOUNT_POINT}/macos-tahoe"/{configuration,logs,backups}
echo "${MOUNT_POINT}/macos-tahoe"
