#!/usr/bin/env bash
# =============================================================================
# TahoeBoot OpenCore 1.0.8 Universal x64 & Multi-OS Dual-Boot Builder
# (`TahoeBoot/opencore/build-opencore.sh`)
# =============================================================================
# Generates and verifies:
#   - `opencore.qcow2` & `opencore.img` (OpenCore 1.0.8 GPT/ESP disk image)
#   - Standalone `TahoeBoot/opencore/EFI/` directory (ready to copy onto any
#     FAT32 EFI System Partition or USB drive for seamless dual-booting of
#     macOS Tahoe, Windows 10/11, and Linux, AND booting a macOS USB drive on
#     ANY Intel/AMD x64 PC!)
#
# Included Kernel Extensions (`EFI/OC/Kexts/`):
#   - `Lilu.kext`                (1.7.2 — Acidanthera kernel patch engine)
#   - `ReimsVgpu.kext`           (Reims Metal 3 / IOSurface vGPU plugin for VM)
#   - `VirtualSMC.kext`          (1.3.8 — SMC emulation for booting on ANY real x64 PC!)
#   - `RestrictEvents.kext`      (1.1.6 — Board-ID/VMM/CPU/RAM/OTA unlock patches)
#   - `FeatureUnlock.kext`       (1.1.8 — Unlocks Continuity, Sidecar, Night Shift, AirPlay)
#   - `WhateverGreen.kext`       (1.7.1 — Intel/AMD/NVIDIA GPU patches on real x64 PCs)
#   - `AppleALC.kext`            (1.9.8 — Onboard audio codecs on real x64 PCs)
#   - `CryptexFixup.kext`        (1.0.5 — Cryptex / Rosetta patches across x64 CPUs)
#   - `MCEReporterDisabler.kext` (Disables AppleMCEReporter panics on AMD & modern Intel)
#
# Included UEFI Drivers (`EFI/OC/Drivers/`):
#   - `OpenRuntime.efi`          (Core UEFI runtime services)
#   - `OpenHfsPlus.efi`          (Apple HFS+ recovery & installer volumes)
#   - `OpenNtfsDxe.efi`          (Windows NTFS volumes — shows Windows disks!)
#   - `Ext4Dxe.efi`              (Linux ext4 volumes — shows Linux disks!)
#   - `NvmExpressDxe.efi`        (NVMe SSD controller enumeration)
#   - `VirtioPciDeviceDxe.efi`, `Virtio10.efi`, `VirtioBlkDxe.efi`, `VirtioScsiDxe.efi`
#   - `OpenCanopy.efi`           (Graphical boot picker with GoldenGate icons)
#   - `AudioDxe.efi`             (Boot chime audio driver)
#   - `OpenPartitionDxe.efi`     (GPT / Apple Partition Map driver)
#   - `OpenLinuxBoot.efi`        (Automatic Linux kernel/initrd dual-boot scanner)
#   - `ResetNvramEntry.efi`, `ToggleSipEntry.efi`, `FirmwareSettingsEntry.efi`
#
# Included UEFI Tools (`EFI/OC/Tools/`):
#   - `OpenShell.efi`            (Interactive UEFI Shell)
#   - `ListPartitions.efi`       (Lists all physical & virtual disks/partitions)
#   - `CleanNvram.efi`           (NVRAM cleaner)
#   - `ResetSystem.efi`          (System reboot/shutdown utility)
#   - `CsrUtil.efi`              (SIP configuration utility)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"
VM_DIR="${1:-${PROJECT_ROOT}/VMStorage/macos-tahoe}"
EXTRA_KEXTS_DIR="${SCRIPT_DIR}/extra-kexts"

REIMS_UTIL="${TAHOEBOOT_ROOT}/reims/bin/reims-util"
if [[ ! -x "${REIMS_UTIL}" ]]; then
    REIMS_UTIL="${PROJECT_ROOT}/upstream/reims-util/target/release/reims-util"
fi

if [[ ! -x "${REIMS_UTIL}" ]]; then
    echo "ERROR: reims-util binary not found at ${REIMS_UTIL}" >&2
    exit 1
fi

if [[ ! -d "${EXTRA_KEXTS_DIR}/RestrictEvents.kext" || ! -d "${EXTRA_KEXTS_DIR}/FeatureUnlock.kext" ]]; then
    if [[ -x "${SCRIPT_DIR}/fetch-extra-kexts.sh" ]]; then
        "${SCRIPT_DIR}/fetch-extra-kexts.sh"
    fi
fi

mkdir -p "${VM_DIR}" "${TAHOEBOOT_ROOT}/opencore"

KEXT_ARGS=()
for kext_spec in \
    "VirtualSMC.kext,8.0.0,99.99.99" \
    "RestrictEvents.kext,12.0.0,99.99.99" \
    "FeatureUnlock.kext,16.0.0,99.99.99" \
    "WhateverGreen.kext,10.0.0,99.99.99" \
    "AppleALC.kext,8.0.0,99.99.99" \
    "CryptexFixup.kext,22.0.0,99.99.99" \
    "MCEReporterDisabler.kext,18.0.0,99.99.99"
do
    kext_name="${kext_spec%%,*}"
    bounds="${kext_spec#*,}"
    if [[ -d "${EXTRA_KEXTS_DIR}/${kext_name}" ]]; then
        KEXT_ARGS+=(--add-kext "${EXTRA_KEXTS_DIR}/${kext_name},${bounds}")
    fi
done

echo "[TahoeBoot OpenCore] Generating OpenCore 1.0.8 Universal x64 & Multi-OS Dual-Boot image (ShowPicker=true, ScanPolicy=0) + OVMF..."
"${REIMS_UTIL}" opencore \
    --show-picker \
    --ovmf-dir "${VM_DIR}" \
    "${KEXT_ARGS[@]}" \
    -o "${VM_DIR}/opencore.qcow2"

cp -f "${VM_DIR}/opencore.qcow2" "${TAHOEBOOT_ROOT}/opencore/opencore.qcow2"
cp -f "${VM_DIR}/OVMF_CODE.fd" "${TAHOEBOOT_ROOT}/opencore/OVMF_CODE.fd"
cp -f "${VM_DIR}/OVMF_VARS.fd" "${TAHOEBOOT_ROOT}/opencore/OVMF_VARS.fd"

# Also export raw image and extract the complete standalone `TahoeBoot/opencore/EFI/` folder
RAW_TMP="$(mktemp /tmp/opencore-efi-XXXXXX.raw)"
qemu-img convert -f qcow2 -O raw "${VM_DIR}/opencore.qcow2" "${RAW_TMP}"

EFI_OUT="${TAHOEBOOT_ROOT}/opencore/EFI"
rm -rf "${EFI_OUT}"
mkdir -p "${EFI_OUT}"

if command -v mcopy >/dev/null 2>&1; then
    echo "[TahoeBoot OpenCore] Extracting standalone Universal x64 OpenCore EFI folder to ${EFI_OUT}..."
    # GPT ESP starts at LBA 2048 = byte offset 1048576
    mcopy -s -n -i "${RAW_TMP}@@1048576" ::/EFI/* "${EFI_OUT}/"
fi
rm -f "${RAW_TMP}"

echo "[TahoeBoot OpenCore] Verifying generated artifacts:"
ls -lh "${VM_DIR}/opencore.qcow2" "${VM_DIR}/OVMF_CODE.fd" "${VM_DIR}/OVMF_VARS.fd"
if [[ -d "${EFI_OUT}/OC" ]]; then
    echo "[TahoeBoot OpenCore] Standalone EFI directory contents (${EFI_OUT}):"
    ls -la "${EFI_OUT}/OC/Drivers" "${EFI_OUT}/OC/Tools" "${EFI_OUT}/OC/Kexts"
fi
echo "[TahoeBoot OpenCore] OpenCore 1.0.8 Universal x64 + Multi-OS EFI & OVMF generation complete."
