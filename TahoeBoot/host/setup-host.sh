#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Host Environment Setup & Verification (`TahoeBoot/host/setup-host.sh`)
# =============================================================================
# Configures the Linux host environment for Reims vGPU & QEMU KVM virtualization:
#   1. Sets persistent `vm.max_map_count = 2097152` in `/etc/sysctl.d/99-reims-vgpu.conf`
#      (Reims vGPU maps guest scatter-gather pages into the host address space).
#   2. Loads `kvm`, `kvm_intel` (with `nested=1`), `udmabuf`, and `i915` kernel modules.
#   3. Installs udev rules `/etc/udev/rules.d/99-tahoeboot-kvm-udmabuf.rules` so
#      `/dev/kvm`, `/dev/udmabuf`, and `/dev/dri/renderD*` are accessible to the
#      appliance session without root escalation.
#   4. Raises `RLIMIT_NOFILE` (`nofile = 1048576`) for dma-buf file descriptor pools.
# =============================================================================
set -euo pipefail

echo "[TahoeBoot Host] Applying sysctl vm.max_map_count=2097152..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-reims-vgpu.conf <<'EOF'
# Required by Reims vGPU / metal2vulkan for macOS guest scatter-gather memory mappings
vm.max_map_count = 2097152
EOF
sysctl -w vm.max_map_count=2097152

echo "[TahoeBoot Host] Installing udev permissions for /dev/kvm, /dev/udmabuf, /dev/dri..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-tahoeboot-kvm-udmabuf.rules <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0666"
KERNEL=="udmabuf", GROUP="kvm", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", GROUP="video", MODE="0666"
EOF

echo "[TahoeBoot Host] Configuring security limits for dma-buf descriptors..."
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-tahoeboot.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
EOF

echo "[TahoeBoot Host] Loading kernel modules (kvm_intel, udmabuf, i915)..."
modprobe kvm || true
modprobe kvm_intel nested=1 || true
modprobe udmabuf || echo "[WARN] udmabuf module not present in running kernel (expected in WSL2; present on bare-metal Ubuntu kernel)"
modprobe i915 || true

if [[ -e /dev/kvm ]]; then
    chmod 0666 /dev/kvm || true
fi
if [[ -e /dev/udmabuf ]]; then
    chmod 0666 /dev/udmabuf || true
fi

echo "[TahoeBoot Host] Host configuration complete."
