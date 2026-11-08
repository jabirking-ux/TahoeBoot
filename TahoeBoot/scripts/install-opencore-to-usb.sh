#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Universal OpenCore 1.0.8 USB EFI Installer
# (`TahoeBoot/scripts/install-opencore-to-usb.sh`)
# =============================================================================
# Installs the pre-built Universal x64 OpenCore 1.0.8 EFI (with Lilu,
# VirtualSMC, WhateverGreen, AppleALC, RestrictEvents, FeatureUnlock,
# CryptexFixup, and MCEReporterDisabler) onto the EFI System Partition of your
# USB drive so you can boot macOS directly on ANY Intel or AMD x86-64 PC!
#
# Can be run on:
#   1. Linux / WSL2: ./install-opencore-to-usb.sh /dev/sdX
#   2. macOS (in Recovery or Desktop Terminal): ./install-opencore-to-usb.sh diskX
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EFI_SOURCE="${TAHOEBOOT_ROOT}/opencore/EFI"

if [[ ! -d "${EFI_SOURCE}/OC" ]]; then
    echo "ERROR: OpenCore EFI source directory not found at ${EFI_SOURCE}" >&2
    exit 1
fi

TARGET_DEV="${1:-}"

if [[ -z "${TARGET_DEV}" ]]; then
    echo "Usage: $0 <disk_device>"
    echo "  Example on Linux/WSL : $0 /dev/sdb"
    echo "  Example inside macOS : $0 disk2"
    exit 1
fi

echo "==================================================================="
echo " TahoeBoot Universal x64 OpenCore USB EFI Installer"
echo "==================================================================="

OS_TYPE="$(uname -s)"

if [[ "${OS_TYPE}" == "Darwin" ]]; then
    # Running inside macOS
    DEV_BASE="$(basename "${TARGET_DEV}")"
    DEV_BASE="${DEV_BASE%%s*}" # disk2s1 -> disk2
    ESP_PART="${DEV_BASE}s1"

    echo "[TahoeBoot USB] Mounting EFI System Partition /dev/${ESP_PART} on macOS..."
    diskutil mount "${ESP_PART}" >/dev/null

    # Find the mounted volume path
    EFI_MNT="$(diskutil info "${ESP_PART}" | awk -F': *' '/Mount Point/{print $2}')"
    if [[ -z "${EFI_MNT}" || ! -d "${EFI_MNT}" ]]; then
        EFI_MNT="/Volumes/EFI"
    fi

    echo "[TahoeBoot USB] Copying Universal OpenCore 1.0.8 EFI to ${EFI_MNT}/EFI..."
    mkdir -p "${EFI_MNT}/EFI"
    cp -rf "${EFI_SOURCE}/"* "${EFI_MNT}/EFI/"
    diskutil unmount "${ESP_PART}" >/dev/null || true
    echo "[TahoeBoot USB] Done! Your USB drive is now bootable on ANY x64 PC."

else
    # Running on Linux / WSL2
    if [[ ! -b "${TARGET_DEV}" ]]; then
        echo "ERROR: Target device ${TARGET_DEV} is not a valid block device!" >&2
        exit 1
    fi

    # Determine partition 1 (e.g., /dev/sdb1 or /dev/nvme0n1p1)
    if [[ "${TARGET_DEV}" =~ [0-9]$ ]]; then
        ESP_PART="${TARGET_DEV}p1"
    else
        ESP_PART="${TARGET_DEV}1"
    fi

    if [[ ! -b "${ESP_PART}" ]]; then
        echo "ERROR: EFI System Partition ${ESP_PART} does not exist on ${TARGET_DEV}!" >&2
        exit 1
    fi

    MNT_TMP="$(mktemp -d /tmp/tahoe-usb-efi-XXXXXX)"
    cleanup() {
        umount "${MNT_TMP}" 2>/dev/null || true
        rm -rf "${MNT_TMP}"
    }
    trap cleanup EXIT

    echo "[TahoeBoot USB] Mounting ${ESP_PART} at ${MNT_TMP}..."
    mount -t vfat "${ESP_PART}" "${MNT_TMP}"
    mkdir -p "${MNT_TMP}/EFI"
    echo "[TahoeBoot USB] Copying Universal OpenCore 1.0.8 EFI to ${MNT_TMP}/EFI..."
    cp -rf "${EFI_SOURCE}/"* "${MNT_TMP}/EFI/"
    sync
    umount "${MNT_TMP}"
    echo "[TahoeBoot USB] Done! Universal x64 OpenCore 1.0.8 installed on ${TARGET_DEV}."
    echo "  -> You can now unplug this USB drive and boot it on ANY x64 PC!"
fi
