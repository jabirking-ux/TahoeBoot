#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Resolution & Display Mode Switcher (`TahoeBoot/qemu/set-resolution.sh`)
# =============================================================================
# Supports:
#   - 1920x1080 (Full HD, default initial target for UHD 730)
#   - 2560x1440 (QHD)
#   - 3840x2160 (4K UHD / macOS HiDPI Retina scaling via `apple-m2scaler-pci`)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_TOML="${PROJECT_ROOT}/VMStorage/macos-tahoe/configuration/vm.toml"

RES="${1:-1920x1080}"
case "${RES}" in
    1920x1080|2560x1440|3840x2160)
        ;;
    *)
        echo "ERROR: Unsupported resolution '${RES}'. Supported: 1920x1080, 2560x1440, 3840x2160" >&2
        exit 1
        ;;
esac

if [[ -f "${VM_TOML}" ]]; then
    sed -i "s/^resolution = .*/resolution = \"${RES}\"/" "${VM_TOML}"
    echo "[TahoeBoot Display] Updated ${VM_TOML} resolution to ${RES}."
else
    echo "export TAHOEBOOT_RESOLUTION=${RES}"
fi
