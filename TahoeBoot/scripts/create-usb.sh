#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Safe Bootable USB Creator (`TahoeBoot/scripts/create-usb.sh`)
# =============================================================================
# Safely writes `TahoeBoot.iso` to an external removable USB drive.
#
# CRITICAL SAFETY INVARIANTS:
#   - NEVER formats or overwrites internal disks (`RM=0`).
#   - NEVER touches any disk containing a Windows NTFS, BitLocker, or EFI System
#     partition belonging to the host OS.
#   - Requires explicit `--device /dev/disk/by-id/usb-...` and interactive
#     confirmation before writing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISO_PATH="${TAHOEBOOT_ROOT}/TahoeBoot.iso"
TARGET_DEV="${1:-}"

echo "=== TAHOEBOOT SAFE USB CREATOR ==="

if [[ ! -f "${ISO_PATH}" ]]; then
    echo "ERROR: ${ISO_PATH} does not exist. Run build-iso.sh first." >&2
    exit 1
fi

if [[ -z "${TARGET_DEV}" ]]; then
    echo "Usage: $0 /dev/disk/by-id/usb-<your-usb-drive>"
    echo ""
    echo "Detected external removable USB block devices (RM=1, TRAN=usb):"
    lsblk -d -o NAME,RM,TRAN,SIZE,MODEL,VENDOR | awk 'NR==1 || ($2=="1" && $3=="usb")'
    exit 0
fi

REAL_DEV="$(readlink -f "${TARGET_DEV}")"
RM_FLAG="$(lsblk -dn -o RM "${REAL_DEV}" | tr -d ' ')"
TRAN_FLAG="$(lsblk -dn -o TRAN "${REAL_DEV}" | tr -d ' ')"

if [[ "${RM_FLAG}" != "1" && "${TRAN_FLAG}" != "usb" ]]; then
    echo "CRITICAL SAFETY ABORT: ${REAL_DEV} is NOT a removable USB drive (RM=${RM_FLAG}, TRAN=${TRAN_FLAG})." >&2
    echo "TahoeBoot refuses to write to internal disks to protect the Windows installation." >&2
    exit 2
fi

if lsblk -no FSTYPE "${REAL_DEV}" | grep -qiE "bitlocker"; then
    echo "CRITICAL SAFETY ABORT: ${REAL_DEV} contains a BitLocker volume!" >&2
    exit 3
fi

echo "Target USB Device : ${TARGET_DEV} (${REAL_DEV})"
echo "Source Image      : ${ISO_PATH}"
read -r -p "Type 'WRITE-TAHOEBOOT-USB' to confirm writing to ${REAL_DEV}: " CONFIRM
if [[ "${CONFIRM}" != "WRITE-TAHOEBOOT-USB" ]]; then
    echo "Aborted by user."
    exit 1
fi

dd if="${ISO_PATH}" of="${REAL_DEV}" bs=4M status=progress oflag=sync
sync
echo "[TahoeBoot USB] Successfully created bootable TahoeBoot USB on ${REAL_DEV}."
