#!/bin/bash
# =============================================================================
# TahoeBoot macOS Tahoe (macOS 26) Guest Setup & GPU Acceleration Verifier
# (`TahoeBoot/opencore/tahoe-guest-setup.sh`)
# =============================================================================
# Run inside the macOS Tahoe guest after first boot to:
#   1. Apply the mandatory Reims vGPU macOS 26 workaround:
#      `sudo defaults write /Library/Preferences/.GlobalPreferences.plist METAL_ERROR_MODE -int 5`
#   2. Verify `AppleParavirtGPU` and `ReimsVgpu.kext` are loaded in IORegistry.
#   3. Verify Metal framework recognizes the virtual Apple Paravirtualized GPU.
#   4. Verify Core Animation & WindowServer hardware acceleration status.
# =============================================================================
set -euo pipefail

echo "=== TAHOEBOOT MACOS TAHOE (26) GUEST GPU SETUP & VERIFICATION ==="

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "NOTE: This script executes inside the macOS Tahoe guest OS."
    exit 0
fi

echo "[1/4] Applying Reims vGPU macOS 26 Metal command buffer error mode workaround..."
sudo defaults write /Library/Preferences/.GlobalPreferences.plist METAL_ERROR_MODE -int 5
VAL="$(defaults read /Library/Preferences/.GlobalPreferences.plist METAL_ERROR_MODE || echo "")"
echo "      METAL_ERROR_MODE = ${VAL} (expected 5)"

echo "[2/4] Checking IORegistry for AppleParavirtGPU & ReimsVgpu PCI devices..."
ioreg -l | grep -E "AppleParavirtGPU|ReimsVgpu|apple-gfx|106b" | head -n 30 || true

echo "[3/4] Checking kextstat for Lilu & ReimsVgpu..."
kextstat | grep -E "Lilu|ReimsVgpu|AppleParavirtGPU" || true

echo "[4/4] Querying system_profiler SPDisplaysDataType for Metal support..."
system_profiler SPDisplaysDataType

echo "=== MACOS TAHOE GUEST GPU VERIFICATION COMPLETE ==="
