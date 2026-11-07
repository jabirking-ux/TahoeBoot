#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Apple Silicon (`vmapple` / `aarch64`) Emulation Launcher
# (`TahoeBoot/qemu/launch-apple-silicon.sh`)
# =============================================================================
# Emulates an Apple Silicon (`arm64` / `vmapple`) macOS machine using:
#   - Reims-patched `qemu-system-aarch64` (`hw/vmapple/vmapple.c`)
#   - `apple-gfx-mmio` (Reims vGPU MMIO Apple Paravirtualized GPU)
#   - `apple-videotoolbox-pci` (106b:1a03) & `apple-m2scaler-pci` (106b:1a0b)
#   - `vmapple-virtio-blk-pci` (`aux` & `root` drives)
#   - Reference architecture from `steelbrain/reims-vgpu` (`crates/reims-ctl/src/qemu.rs`
#     `vmapple()`) and `ChefKissInc/QEMUAppleSilicon` (`upstream/QEMUAppleSilicon`).
#
# IMPORTANT PERFORMANCE NOTE ON INTEL x86_64 HOSTS (Core i5-11400):
#   - Running `qemu-system-aarch64` on an x86_64 CPU requires `-accel tcg,thread=multi`
#     (software instruction translation of ARM64 -> x86_64), which is ~10-20x slower
#     for CPU workloads than `TahoeBoot/qemu/launch-vm.sh` (`qemu-system-x86_64 -accel kvm`),
#     which runs natively on Intel VT-x/KVM hardware virtualization while still using
#     the exact same Apple Paravirtualized GPU (`apple-gfx-pci` + `ReimsVgpu.kext`)!
#   - Strict zero-auto-format policy: never runs `mkfs` or formats any disk/partition.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"

VM_DIR="${TAHOEBOOT_VM_DIR:-${PROJECT_ROOT}/VMStorage/macos-tahoe-arm64}"
mkdir -p "${VM_DIR}/logs"

QEMU_AARCH64="${TAHOEBOOT_QEMU_AARCH64:-${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-aarch64}"
if [[ ! -x "${QEMU_AARCH64}" ]]; then
    if [[ -x "/root/tahoe-build/qemu-build/qemu-system-aarch64" ]]; then
        QEMU_AARCH64="/root/tahoe-build/qemu-build/qemu-system-aarch64"
    elif command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU_AARCH64="$(command -v qemu-system-aarch64)"
    else
        echo "ERROR: qemu-system-aarch64 not found." >&2
        echo "       Build with: configure --target-list=x86_64-softmmu,aarch64-softmmu --enable-pvg --enable-gnutls" >&2
        exit 1
    fi
fi

CPUS="${TAHOEBOOT_CPUS:-6}"
MEMORY_MIB="${TAHOEBOOT_MEMORY_MIB:-8192}"
RESOLUTION="${TAHOEBOOT_RESOLUTION:-1920x1080}"
ECID="${TAHOEBOOT_VMAPPLE_ECID:-3131946958635128}"
AVPBOOTER="${TAHOEBOOT_AVPBOOTER:-${VM_DIR}/AVPBooter.vmapple2.bin}"
AUX_IMG="${VM_DIR}/aux.img.trimmed"
ROOT_IMG="${VM_DIR}/disk.raw"

HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "aarch64" || "${HOST_ARCH}" == "arm64" ]]; then
    ACCEL="kvm"
else
    ACCEL="tcg,thread=multi,tb-size=2048"
    echo "================================================================================"
    echo "[TahoeBoot Apple Silicon Mode] Host CPU is ${HOST_ARCH} (Intel Core i5-11400)."
    echo "  Using multi-threaded TCG ARM64 emulation (-accel ${ACCEL}) + vmapple machine."
    echo "  TIP: For full native KVM hardware speed on Intel i5-11400 with Apple GPU"
    echo "       paravirtualization (apple-gfx-pci), use: TahoeBoot/qemu/launch-vm.sh"
    echo "================================================================================"
fi

if [[ ! -f "${AVPBOOTER}" || ! -f "${AUX_IMG}" || ! -f "${ROOT_IMG}" ]]; then
    cat <<EOF >&2
[TahoeBoot Apple Silicon Mode] Ready to boot QEMU 'vmapple' (aarch64) machine.
Required Apple Silicon Virtualization.framework artifacts in ${VM_DIR}:
  1. AVPBooter ROM : ${AVPBOOTER}
  2. Trimmed Aux   : ${AUX_IMG} (dd if=aux.img of=aux.img.trimmed bs=16384 skip=1)
  3. Root Disk     : ${ROOT_IMG} (restored from UniversalMac_26.x_Restore.ipsw)

To run macOS Tahoe immediately at native KVM speed on your Intel Core i5-11400
(with Apple Paravirtualized GPU 'apple-gfx-pci' + OpenCore 1.0.8 + SATA AHCI disk):
  ./TahoeBoot/qemu/launch-vm.sh
EOF
    exit 2
fi

exec "${QEMU_AARCH64}" \
    -name "TahoeBoot-AppleSilicon-vmapple" \
    -accel "${ACCEL}" \
    -M "vmapple,uuid=${ECID}" \
    -cpu "max,pauth-impdef=on" \
    -m "${MEMORY_MIB}M" \
    -smp "${CPUS}" \
    -bios "${AVPBOOTER}" \
    -drive "file=${AUX_IMG},if=pflash,format=raw" \
    -drive "file=${ROOT_IMG},if=pflash,format=raw" \
    -drive "file=${AUX_IMG},if=none,id=aux,format=raw,cache=writeback,aio=threads" \
    -drive "file=${ROOT_IMG},if=none,id=root,format=raw,cache=writeback,aio=threads" \
    -device "vmapple-virtio-blk-pci,variant=aux,drive=aux" \
    -device "vmapple-virtio-blk-pci,variant=root,drive=root" \
    -global "apple-gfx-mmio.displays=1" \
    -global "apple-gfx-mmio.resolution=${RESOLUTION}" \
    -device "apple-videotoolbox-pci,id=video" \
    -device "apple-m2scaler-pci,id=scaler" \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:2223-:22" \
    -device "virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:28" \
    -serial "file:${VM_DIR}/logs/console.log" \
    -D "${VM_DIR}/logs/qemu.log" \
    "$@"
