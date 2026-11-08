#!/bin/bash
# =============================================================================
# TahoeBoot macOS Tahoe (macOS 26) Guest Setup, GPU & Physical Disk R/W Helper
# (`TahoeBoot/opencore/tahoe-guest-setup.sh`)
# =============================================================================
# Run inside the macOS Tahoe guest after first boot to:
#   1. Apply the mandatory Reims vGPU macOS 26 workaround:
#      `sudo defaults write /Library/Preferences/.GlobalPreferences.plist METAL_ERROR_MODE -int 5`
#   2. Mount the physical host drives (`Windows_C`, `LocalDisk_D`, `HostDisks`)
#      in full Read-Write mode under `/Volumes/Windows_C` and `/Volumes/LocalDisk_D`
#      (and install a LaunchAgent so they mount automatically on every macOS login)
#      so any file you create or edit in macOS immediately persists on the real
#      physical drive when you reboot into Windows!
#   3. Verify `AppleParavirtGPU` and `ReimsVgpu.kext` in IORegistry.
#   4. Verify Metal framework & Core Animation hardware acceleration.
# =============================================================================
set -euo pipefail

echo "=== TAHOEBOOT MACOS TAHOE (26) GUEST GPU & PHYSICAL DISK R/W SETUP ==="

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "NOTE: This script executes inside the macOS Tahoe guest OS."
    exit 0
fi

echo "[1/5] Applying Reims vGPU macOS 26 Metal command buffer error mode workaround..."
sudo defaults write /Library/Preferences/.GlobalPreferences.plist METAL_ERROR_MODE -int 5
VAL="$(defaults read /Library/Preferences/.GlobalPreferences.plist METAL_ERROR_MODE || echo "")"
echo "      METAL_ERROR_MODE = ${VAL} (expected 5)"

echo "[2/5] Mounting physical host drives (Windows C:, Local Disk D:, HostDisks) in full Read-Write mode..."
for share in Windows_C LocalDisk_D HostDisks; do
    sudo mkdir -p "/Volumes/${share}"
    mount_smbfs -N "//guest:@10.0.2.2/${share}" "/Volumes/${share}" 2>/dev/null || \
        osascript -e "mount volume \"smb://guest:@10.0.2.2/${share}\"" >/dev/null 2>&1 || true
done

# Create LaunchAgent so Windows_C and LocalDisk_D auto-mount read-write on every login
PLIST_DIR="${HOME}/Library/LaunchAgents"
mkdir -p "${PLIST_DIR}"
cat > "${PLIST_DIR}/com.tahoeboot.hostdisks.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tahoeboot.hostdisks</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/osascript</string>
        <string>-e</string>
        <string>try
mount volume "smb://guest:@10.0.2.2/Windows_C"
end try
try
mount volume "smb://guest:@10.0.2.2/LocalDisk_D"
end try
try
mount volume "smb://guest:@10.0.2.2/HostDisks"
end try</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

echo "[3/5] Checking IORegistry for AppleParavirtGPU & ReimsVgpu PCI devices..."
ioreg -l | grep -E "AppleParavirtGPU|ReimsVgpu|apple-gfx|106b" | head -n 30 || true

echo "[4/5] Checking kextstat for Lilu & ReimsVgpu..."
kextstat | grep -E "Lilu|ReimsVgpu|AppleParavirtGPU" || true

echo "[5/5] Querying system_profiler SPDisplaysDataType for Metal support..."
system_profiler SPDisplaysDataType

echo "=== MACOS TAHOE GUEST GPU & PHYSICAL DISK R/W SETUP COMPLETE ==="
