#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Appliance Kiosk Session (`TahoeBoot/rootfs/tahoeboot-session.sh`)
# =============================================================================
# Automatically handles the boot and startup experience:
#   - Inspects `/proc/cmdline` for `tahoeboot.mode=diagnostics` or `tahoeboot.mode=appliance`
#   - Displays Liquid Glass splash screen
#   - Runs `tahoeboot-gpu-check` to verify physical Intel UHD 730 (0x8086:0x4c8b),
#     Mesa ANV Vulkan 1.4, `VK_EXT_external_memory_host`, `/dev/udmabuf`, `/dev/kvm`,
#     and `vm.max_map_count = 2097152`.
#   - Launches a lightweight Wayland kiosk compositor (`cage -s --` or `weston`)
#     that hides the host desktop and presents the macOS Tahoe VM fullscreen.
#   - On any hardware/GPU check failure, presents the explicit TahoeBoot error panel.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p /run/user/0
chmod 0700 /run/user/0
export XDG_RUNTIME_DIR="/run/user/0"
export REIMS_VGPU_WINDOW_BORDERLESS=1

CMDLINE="$(cat /proc/cmdline 2>/dev/null || echo "")"
if [[ "${CMDLINE}" == *"tahoeboot.mode=diagnostics"* ]]; then
    "${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui" --diagnostics
    echo ""
    echo "Entering TahoeBoot Maintenance & Diagnostics Shell..."
    exec /bin/bash --login
fi

"${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui" --splash

# Verify KVM
if [[ ! -e /dev/kvm ]]; then
    "${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui" --error ERR_KVM_UNAVAILABLE
    exit 1
fi

# Verify GPU & Vulkan
if ! "${TAHOEBOOT_ROOT}/gpu/target-linux/release/tahoeboot-gpu-check"; then
    "${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui" --error ERR_GPU_UNSUPPORTED
    exit 1
fi

# Start PipeWire audio in background if available
if command -v pipewire >/dev/null 2>&1; then
    pipewire &
fi

# Launch fullscreen Wayland kiosk compositor (Cage preferred, fallback to Weston or direct DRM/X11)
if command -v cage >/dev/null 2>&1; then
    exec cage -s -- "${TAHOEBOOT_ROOT}/qemu/launch-vm.sh"
elif command -v weston >/dev/null 2>&1; then
    exec weston --shell=kiosk-shell.so -- "${TAHOEBOOT_ROOT}/qemu/launch-vm.sh"
else
    exec "${TAHOEBOOT_ROOT}/qemu/launch-vm.sh"
fi
