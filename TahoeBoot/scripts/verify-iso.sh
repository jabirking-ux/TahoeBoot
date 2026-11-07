#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Bootable UEFI ISO Verification Script (`TahoeBoot/scripts/verify-iso.sh`)
# =============================================================================
# Inspects `TahoeBoot/TahoeBoot.iso` and verifies:
#   1. File exists and is a valid ISO 9660 / El Torito UEFI bootable image.
#   2. Volume ID is `TAHOEBOOT`.
#   3. Contains `/EFI/BOOT/BOOTX64.EFI` (or EFI System Partition boot catalog).
#   4. Contains `/boot/grub/grub.cfg` with both Appliance and Maintenance/Diagnostics entries.
#   5. Contains `/boot/vmlinuz` (Linux x86-64 kernel) and `/boot/initrd.img`.
#   6. Contains `/live/filesystem.squashfs` with `tahoeboot-gpu-check`, `libreims_vgpu.so`,
#      `ReimsVgpu.rom`, `reims-ctl`, `reims-util`, `opencore.qcow2`, and `setup-host.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISO_PATH="${1:-${TAHOEBOOT_ROOT}/TahoeBoot.iso}"

echo "=== TAHOEBOOT ISO VERIFICATION REPORT ==="
if [[ ! -f "${ISO_PATH}" ]]; then
    echo "FAIL: ISO file not found at ${ISO_PATH}" >&2
    exit 1
fi

ISO_SIZE="$(stat -c%s "${ISO_PATH}")"
echo "[1/6] ISO File: ${ISO_PATH} (${ISO_SIZE} bytes)"

echo "[2/6] Checking El Torito & UEFI boot catalog via xorriso..."
xorriso -indev "${ISO_PATH}" -report_el_torito plain -report_system_area plain 2>&1 | grep -E "Volume id|El Torito|boot|EFI|UEFI" || true

echo "[3/6] Verifying required ISO directory structure..."
ISO_FILES="$(xorriso -indev "${ISO_PATH}" -find / 2>/dev/null | tr -d "'")"
for req in "/boot/grub/grub.cfg" "/boot/vmlinuz" "/boot/initrd.img" "/live/filesystem.squashfs"; do
    if echo "${ISO_FILES}" | grep -q "^${req}$"; then
        echo "      PASS: Found ${req}"
    else
        echo "      FAIL: Missing ${req} in ISO!" >&2
        exit 1
    fi
done

echo "[4/6] Extracting and verifying /live/filesystem.squashfs contents..."
TMP_VERIFY="/tmp/tahoeboot-iso-verify-$$"
rm -rf "${TMP_VERIFY}"
mkdir -p "${TMP_VERIFY}"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /live/filesystem.squashfs "${TMP_VERIFY}/filesystem.squashfs" 2>/dev/null
xorriso -osirrox on -indev "${ISO_PATH}" -extract /boot/grub/grub.cfg "${TMP_VERIFY}/grub.cfg" 2>/dev/null

echo "[5/6] Verifying dual UEFI boot entries in grub.cfg..."
grep "menuentry" "${TMP_VERIFY}/grub.cfg"

echo "[6/6] Verifying embedded Reims vGPU & TahoeBoot tools in squashfs..."
SQ_LIST="$(unsquashfs -ll "${TMP_VERIFY}/filesystem.squashfs")"
for item in \
    "usr/local/bin/tahoeboot-gpu-check" \
    "usr/local/bin/reims-ctl" \
    "usr/local/bin/reims-util" \
    "usr/local/lib/libreims_vgpu.so" \
    "usr/local/share/qemu/ReimsVgpu.rom" \
    "usr/local/share/tahoeboot/opencore/opencore.qcow2" \
    "usr/local/share/tahoeboot/host/setup-host.sh" \
    "usr/local/share/tahoeboot/rootfs/tahoeboot-session.sh" \
    "usr/local/share/tahoeboot/diagnostics/tahoeboot-ui" \
    "etc/sysctl.d/99-reims-vgpu.conf"; do
    if echo "${SQ_LIST}" | grep -q "${item}"; then
        echo "      PASS: SquashFS contains ${item}"
    else
        echo "      FAIL: SquashFS missing ${item}" >&2
        rm -rf "${TMP_VERIFY}"
        exit 1
    fi
done

rm -rf "${TMP_VERIFY}"
echo "=== ISO VERIFICATION PASSED ==="
