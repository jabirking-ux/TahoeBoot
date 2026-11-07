#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Persistent Storage Selector (`TahoeBoot/scripts/select-storage.sh`)
# =============================================================================
# Safely discovers and mounts external persistent storage for the macOS Tahoe
# virtual machine by stable filesystem UUID (`UUID=...`), label (`LABEL=TAHOE_VM`),
# or GPT partition label (`PARTLABEL=TAHOE_RAW`), NEVER relying on `/dev/sda` or
# `/dev/sdb` and strictly refusing any internal disk containing Windows (`NTFS` /
# `BitLocker` / `Microsoft reserved` / `Basic data`).
#
# Full-Drive Allocation:
#   - Automatically measures the actual usable capacity of the target drive
#     (`df -B1 --output=avail,size`) and creates or expands `disk.qcow2` to use
#     the entire physical drive (leaving only a 2 GiB safety margin for
#     `opencore.qcow2`, `OVMF_VARS.fd`, and logs).
#   - Also supports direct raw block device passthrough (`PARTLABEL=TAHOE_RAW`
#     or `TAHOEBOOT_RAW_DISK`) so the VM can own 100% of a dedicated drive directly.
# =============================================================================
set -euo pipefail

MOUNT_POINT="${1:-/mnt/tahoe-storage}"
TARGET_LABEL="${TAHOEBOOT_STORAGE_LABEL:-TAHOE_VM}"
TARGET_UUID="${TAHOEBOOT_STORAGE_UUID:-}"
TARGET_RAW_PARTLABEL="${TAHOEBOOT_RAW_PARTLABEL:-TAHOE_RAW}"

echo "[TahoeBoot Storage] Scanning block devices by stable UUID / LABEL..." >&2

# Helper: size or auto-expand disk.qcow2 to use the ENTIRE capacity of the drive
ensure_full_drive_capacity() {
    local vm_dir="$1"
    local qcow2_path="${vm_dir}/disk.qcow2"
    mkdir -p "${vm_dir}"/{configuration,logs,backups}

    # Copy bundled OpenCore 1.0.8 & OVMF if not yet present on the target drive
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local bundled_oc="${script_dir}/../opencore"
    for f in opencore.qcow2 OVMF_CODE.fd OVMF_VARS.fd; do
        if [[ ! -f "${vm_dir}/${f}" && -f "${bundled_oc}/${f}" ]]; then
            cp -f "${bundled_oc}/${f}" "${vm_dir}/${f}"
        fi
    done

    # Query total & available bytes on the drive backing vm_dir
    local fs_total_bytes fs_avail_bytes current_used_bytes usable_bytes target_gib
    fs_total_bytes="$(df -B1 --output=size "${vm_dir}" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
    fs_avail_bytes="$(df -B1 --output=avail "${vm_dir}" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
    current_used_bytes=0
    if [[ -f "${qcow2_path}" ]]; then
        current_used_bytes="$(stat -c '%s' "${qcow2_path}" 2>/dev/null || echo 0)"
    fi

    # Reserve 2 GiB for OpenCore, OVMF_VARS, logs, and filesystem metadata; allocate the rest to the VM
    local reserve_bytes=$((2 * 1024 * 1024 * 1024))
    usable_bytes=$((fs_avail_bytes + current_used_bytes - reserve_bytes))
    if (( fs_total_bytes > reserve_bytes && (fs_total_bytes - reserve_bytes) > usable_bytes )); then
        usable_bytes=$((fs_total_bytes - reserve_bytes))
    fi

    target_gib=$((usable_bytes / (1024 * 1024 * 1024)))
    if (( target_gib < 64 )); then
        target_gib=128
    fi

    if ! command -v qemu-img >/dev/null 2>&1; then
        return 0
    fi

    if [[ ! -f "${qcow2_path}" ]]; then
        if [[ "${TAHOEBOOT_CREATE_DISK:-1}" == "0" ]]; then
            echo "[TahoeBoot Storage] Notice: ${qcow2_path} not found and TAHOEBOOT_CREATE_DISK=0." >&2
            return 0
        fi
        echo "[TahoeBoot Storage] Creating sparse virtual image ${qcow2_path} (${target_gib} GiB logical capacity; NO host disk formatting is ever performed)..." >&2
        qemu-img create -f qcow2 -o cluster_size=65536,lazy_refcounts=on "${qcow2_path}" "${target_gib}G" >&2
    else
        local cur_virtual_bytes cur_virtual_gib
        cur_virtual_bytes="$(qemu-img info --output=json "${qcow2_path}" 2>/dev/null | awk -F'[:,]' '/"virtual-size"/{gsub(/[^0-9]/,"",$2); print $2; exit}' || echo 0)"
        cur_virtual_gib=$((cur_virtual_bytes / (1024 * 1024 * 1024)))
        if (( target_gib > cur_virtual_gib )); then
            echo "[TahoeBoot Storage] Expanding ${qcow2_path} from ${cur_virtual_gib} GiB -> ${target_gib} GiB (full drive capacity)..." >&2
            qemu-img resize "${qcow2_path}" "${target_gib}G" >&2 || true
        fi
    fi
}

# 1. If running in local workspace development mode where VMStorage/macos-tahoe exists directly:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_VMSTORAGE="$(cd "${SCRIPT_DIR}/../.." && pwd)/VMStorage"
if [[ -d "${LOCAL_VMSTORAGE}/macos-tahoe" ]]; then
    echo "[TahoeBoot Storage] Found workspace persistent storage at: ${LOCAL_VMSTORAGE}/macos-tahoe" >&2
    ensure_full_drive_capacity "${LOCAL_VMSTORAGE}/macos-tahoe"
    echo "${LOCAL_VMSTORAGE}/macos-tahoe"
    exit 0
fi

# 2. Check /dev/disk/by-uuid or /dev/disk/by-label
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

# 4. Optional dedicated raw partition / whole-disk block passthrough (`PARTLABEL=TAHOE_RAW`)
if [[ -e "/dev/disk/by-partlabel/${TARGET_RAW_PARTLABEL}" ]]; then
    RAW_NODE="$(readlink -f "/dev/disk/by-partlabel/${TARGET_RAW_PARTLABEL}")"
    RAW_PARENT="$(lsblk -no PKNAME "${RAW_NODE}" | head -n1)"
    if [[ -z "${RAW_PARENT}" ]] || ! lsblk -no FSTYPE "/dev/${RAW_PARENT}" | grep -qiE "ntfs|bitlocker"; then
        mkdir -p "${MOUNT_POINT}/macos-tahoe"/{configuration,logs,backups}
        echo "${RAW_NODE}" > "${MOUNT_POINT}/macos-tahoe/.raw_disk_device"
        echo "[TahoeBoot Storage] Detected dedicated raw drive/partition ${RAW_NODE} (100% raw block passthrough)" >&2
    fi
fi

ensure_full_drive_capacity "${MOUNT_POINT}/macos-tahoe"
echo "${MOUNT_POINT}/macos-tahoe"
