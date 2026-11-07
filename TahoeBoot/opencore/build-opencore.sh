#!/usr/bin/env bash
# =============================================================================
# TahoeBoot OpenCore & OVMF Image Builder (`TahoeBoot/opencore/build-opencore.sh`)
# =============================================================================
# Generates and verifies:
#   - `opencore.qcow2` (OpenCore 1.0.8 GPT/ESP disk image with Lilu.kext 1.7.2,
#     ReimsVgpu.kext for macOS 26 Tahoe AppleParavirtGPU + Metal framework hooks,
#     OpenCanopy.efi graphical picker, and `ShowPicker = true`).
#   - `OVMF_CODE.fd` and `OVMF_VARS.fd` UEFI firmware images.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"
VM_DIR="${1:-${PROJECT_ROOT}/VMStorage/macos-tahoe}"

REIMS_UTIL="${TAHOEBOOT_ROOT}/reims/bin/reims-util"
if [[ ! -x "${REIMS_UTIL}" ]]; then
    REIMS_UTIL="${PROJECT_ROOT}/upstream/reims-util/target/release/reims-util"
fi

if [[ ! -x "${REIMS_UTIL}" ]]; then
    echo "ERROR: reims-util binary not found at ${REIMS_UTIL}" >&2
    exit 1
fi

mkdir -p "${VM_DIR}" "${TAHOEBOOT_ROOT}/opencore"

echo "[TahoeBoot OpenCore] Generating OpenCore 1.0.8 image (ShowPicker=true) + OVMF firmware..."
"${REIMS_UTIL}" opencore \
    --show-picker \
    --ovmf-dir "${VM_DIR}" \
    -o "${VM_DIR}/opencore.qcow2"

cp -f "${VM_DIR}/opencore.qcow2" "${TAHOEBOOT_ROOT}/opencore/opencore.qcow2"
cp -f "${VM_DIR}/OVMF_CODE.fd" "${TAHOEBOOT_ROOT}/opencore/OVMF_CODE.fd"
cp -f "${VM_DIR}/OVMF_VARS.fd" "${TAHOEBOOT_ROOT}/opencore/OVMF_VARS.fd"

echo "[TahoeBoot OpenCore] Verifying generated artifacts:"
ls -lh "${VM_DIR}/opencore.qcow2" "${VM_DIR}/OVMF_CODE.fd" "${VM_DIR}/OVMF_VARS.fd"
qemu-img info "${VM_DIR}/opencore.qcow2"
echo "[TahoeBoot OpenCore] OpenCore & OVMF generation complete."
