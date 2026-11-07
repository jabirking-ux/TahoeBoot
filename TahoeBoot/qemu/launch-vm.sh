#!/usr/bin/env bash
# =============================================================================
# TahoeBoot QEMU + Reims vGPU Virtual Machine Launcher (`TahoeBoot/qemu/launch-vm.sh`)
# =============================================================================
# Starts the macOS Tahoe virtual machine using:
#   - Reims-patched `qemu-system-x86_64` (`vendor/qemu`)
#   - Reims vGPU (`libreims_vgpu.so` + `ReimsVgpu.rom`)
#   - Physical Intel UHD Graphics 730 (`0x8086:0x4c8b`, `intel_icd.json`)
#   - Fullscreen borderless presentation (`REIMS_VGPU_WINDOW_BORDERLESS=1`)
#   - All four Reims PCI devices:
#       * `apple-gfx-pci`           (106b:eeee, romfile=ReimsVgpu.rom)
#       * `apple-gfx-iosurface-pci` (106b:eeef)
#       * `apple-videotoolbox-pci`  (106b:1a03)
#       * `apple-m2scaler-pci`      (106b:1a0b)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"

# 1. Run GPU & Host Pre-Flight Verification
GPU_CHECK="${TAHOEBOOT_ROOT}/gpu/target-linux/release/tahoeboot-gpu-check"
if [[ -x "/usr/local/bin/tahoeboot-gpu-check" ]]; then
    GPU_CHECK="/usr/local/bin/tahoeboot-gpu-check"
fi

if [[ "${TAHOEBOOT_SKIP_GPU_CHECK:-0}" != "1" && -x "${GPU_CHECK}" ]]; then
    echo "[TahoeBoot Launch] Running mandatory hardware GPU verification..."
    if ! "${GPU_CHECK}"; then
        echo "CRITICAL: tahoeboot-gpu-check failed! Refusing to start with fake/software GPU acceleration." >&2
        echo "          Run '${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui --error ERR_GPU_UNSUPPORTED' for details." >&2
        exit 20
    fi
fi

# 2. Locate persistent VM storage
VM_DIR="${TAHOEBOOT_VM_DIR:-}"
if [[ -z "${VM_DIR}" ]]; then
    VM_DIR="$("${TAHOEBOOT_ROOT}/scripts/select-storage.sh")"
fi

if [[ ! -f "${VM_DIR}/opencore.qcow2" || ! -f "${VM_DIR}/OVMF_CODE.fd" ]]; then
    echo "CRITICAL [ERR_OPENCORE_MISSING]: OpenCore or OVMF missing in ${VM_DIR}." >&2
    exit 21
fi

if [[ ! -f "${VM_DIR}/disk.qcow2" ]]; then
    echo "CRITICAL [ERR_STORAGE_NOT_FOUND]: disk.qcow2 missing in ${VM_DIR}." >&2
    exit 22
fi

# 3. Prefer `reims-ctl start` when invoked via standard VM home, or invoke Reims QEMU directly
REIMS_CTL="${TAHOEBOOT_ROOT}/reims/bin/reims-ctl"
if [[ ! -x "${REIMS_CTL}" ]]; then
    REIMS_CTL="${PROJECT_ROOT}/upstream/reims-vgpu/target/release/reims-ctl"
fi

QEMU_BIN="${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-x86_64"
if [[ ! -x "${QEMU_BIN}" ]]; then
    QEMU_BIN="${PROJECT_ROOT}/upstream/reims-vgpu/vendor/qemu/build/qemu-system-x86_64"
fi

REIMS_LIB_DIR="${TAHOEBOOT_ROOT}/reims/lib"
if [[ ! -d "${REIMS_LIB_DIR}" || ! -f "${REIMS_LIB_DIR}/libreims_vgpu.so" ]]; then
    REIMS_LIB_DIR="${PROJECT_ROOT}/upstream/reims-vgpu/target/dist-vulkan/lib"
fi

REIMS_ROM_DIR="${TAHOEBOOT_ROOT}/reims/share"
if [[ ! -f "${REIMS_ROM_DIR}/ReimsVgpu.rom" ]]; then
    REIMS_ROM_DIR="${PROJECT_ROOT}/upstream/reims-vgpu/target/dist-vulkan/share/reims-vgpu"
fi

# 4. Read configurable parameters (defaults for i5-11400 / 16GB RAM target hardware)
CPUS="${TAHOEBOOT_CPUS:-4}"
MEMORY_MIB="${TAHOEBOOT_MEMORY_MIB:-8192}"
RESOLUTION="${TAHOEBOOT_RESOLUTION:-1920x1080}"
RES_W="${RESOLUTION%x*}"
RES_H="${RESOLUTION#*x}"
SSH_PORT="${TAHOEBOOT_SSH_PORT:-2222}"

# 5. Explicitly select Intel UHD Graphics 730 (0x8086:0x4c8b) and borderless fullscreen
export LD_LIBRARY_PATH="${REIMS_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export REIMS_VGPU_VENDOR_ID="${REIMS_VGPU_VENDOR_ID:-0x8086}"
export REIMS_VGPU_DEVICE_ID="${REIMS_VGPU_DEVICE_ID:-0x4c8b}"
export REIMS_VGPU_WINDOW_BORDERLESS="${REIMS_VGPU_WINDOW_BORDERLESS:-1}"
if [[ -f "/usr/share/vulkan/icd.d/intel_icd.json" && -z "${VK_DRIVER_FILES:-}" ]]; then
    export VK_DRIVER_FILES="/usr/share/vulkan/icd.d/intel_icd.json"
fi

OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
CPU_FLAGS="Haswell-noTSX,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on"

QEMU_ARGS=(
    -name "TahoeBoot-macOS-Tahoe"
    -machine "q35,memory-backend=ram,dump-guest-core=off"
    -object "memory-backend-memfd,id=ram,size=${MEMORY_MIB}M,share=on"
    -accel "kvm"
    -m "${MEMORY_MIB}M"
    -cpu "${CPU_FLAGS}"
    -smp "${CPUS},sockets=1,cores=${CPUS},threads=1"
    -global "ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
    -global "ICH9-LPC.disable_s3=1"
    -device "pcie-root-port,bus=pcie.0,addr=0x1,slot=1,x-speed=16,x-width=32"
    -device "isa-applesmc,osk=${OSK}"
    -drive "if=pflash,format=raw,readonly=on,file=${VM_DIR}/OVMF_CODE.fd"
    -drive "if=pflash,format=raw,file=${VM_DIR}/OVMF_VARS.fd"
    -smbios "type=2"
    -device "ich9-ahci,id=sata,addr=0x2"
    -drive "id=opencore,if=none,format=qcow2,file=${VM_DIR}/opencore.qcow2"
    -device "ide-hd,bus=sata.2,drive=opencore,bootindex=1"
    -drive "id=disk,if=none,format=qcow2,file=${VM_DIR}/disk.qcow2,discard=unmap"
    -device "nvme,drive=disk,serial=reims-ctl,addr=0xa"
    -L "${REIMS_ROM_DIR}"
    -vga "none"
    -display "none"
    -device "apple-gfx-pci,id=gfx,bus=pcie.0,addr=0x4,displays=1,resolution=${RESOLUTION},romfile=ReimsVgpu.rom"
    -device "apple-gfx-iosurface-pci,id=iosfc,gpu=gfx,bus=pcie.0,addr=0x6"
    -device "apple-videotoolbox-pci,id=video,bus=pcie.0,addr=0x8"
    -device "apple-m2scaler-pci,id=scaler,bus=pcie.0,addr=0x9"
    -device "qemu-xhci,id=xhci,addr=0x5,conditional-intr-mapping=on"
    -device "usb-kbd,id=kbd,bus=xhci.0"
    -device "usb-tablet,id=tablet,bus=xhci.0"
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27,addr=0x3"
    -serial "file:${VM_DIR}/logs/console.log"
    -D "${VM_DIR}/logs/qemu.log"
)

if [[ -f "${VM_DIR}/recovery.dmg" ]]; then
    QEMU_ARGS+=(
        -drive "id=installer,if=none,format=raw,snapshot=on,file=${VM_DIR}/recovery.dmg"
        -device "ide-hd,bus=sata.4,drive=installer"
    )
fi

echo "[TahoeBoot Launch] Starting Reims-accelerated macOS Tahoe VM (${CPUS} vCPUs, ${MEMORY_MIB} MiB RAM, ${RESOLUTION})..."
exec "${QEMU_BIN}" "${QEMU_ARGS[@]}" "$@"
