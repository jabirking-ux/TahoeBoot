#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Universal x64 & Acidanthera Kext Fetcher
# (`TahoeBoot/opencore/fetch-extra-kexts.sh`)
# =============================================================================
# Downloads the latest official Acidanthera releases of:
#   - RestrictEvents.kext  (hardware/board-id/memory/CPU name & OTA patches)
#   - FeatureUnlock.kext   (unlocks Continuity, Sidecar, Night Shift, AirPlay)
#   - VirtualSMC.kext      (SMC emulation for booting on ANY real x64 PC!)
#   - WhateverGreen.kext   (Intel/AMD/NVIDIA GPU patches for real x64 PCs)
#   - AppleALC.kext        (onboard audio codecs on real x64 PCs)
#   - CryptexFixup.kext    (Rosetta / OS cryptex patches across x86-64 CPUs)
#   - MCEReporterDisabler.kext (prevents MCE panics on AMD & modern Intel x64)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"
EXTRA_DIR="${SCRIPT_DIR}/extra-kexts"
mkdir -p "${EXTRA_DIR}"

for repo in acidanthera/RestrictEvents acidanthera/FeatureUnlock acidanthera/VirtualSMC acidanthera/WhateverGreen acidanthera/AppleALC acidanthera/CryptexFixup; do
    name="${repo#*/}"
    echo "[TahoeBoot Kexts] Fetching latest release of ${repo}..."
    url="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | grep -o 'https://[^"]*RELEASE\.zip' | head -n1)"
    if [[ -z "${url}" ]]; then
        echo "  -> WARNING: Could not resolve latest release URL for ${repo}"
        continue
    fi
    echo "  -> Downloading ${url}"
    tmp_zip="/tmp/${name}-release.zip"
    tmp_dir="/tmp/${name}-extracted"
    rm -rf "${tmp_zip}" "${tmp_dir}"
    curl -fsSL "${url}" -o "${tmp_zip}"
    mkdir -p "${tmp_dir}"
    unzip -qo "${tmp_zip}" -d "${tmp_dir}"
    if [[ -d "${tmp_dir}/Kexts" ]]; then
        cp -rf "${tmp_dir}/Kexts/${name}.kext" "${EXTRA_DIR}/"
    elif [[ -d "${tmp_dir}/${name}.kext" ]]; then
        cp -rf "${tmp_dir}/${name}.kext" "${EXTRA_DIR}/"
    fi
    rm -rf "${tmp_zip}" "${tmp_dir}"
done

if [[ -d "${PROJECT_ROOT}/upstream/OSX-KVM/OpenCore/EFI/OC/Kexts/MCEReporterDisabler.kext" ]]; then
    cp -rf "${PROJECT_ROOT}/upstream/OSX-KVM/OpenCore/EFI/OC/Kexts/MCEReporterDisabler.kext" "${EXTRA_DIR}/"
fi

echo "[TahoeBoot Kexts] Staged extra kexts in ${EXTRA_DIR}:"
ls -la "${EXTRA_DIR}"
