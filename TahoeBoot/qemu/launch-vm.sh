#!/usr/bin/env bash
# =============================================================================
# TahoeBoot QEMU + Reims vGPU Virtual Machine Launcher (`TahoeBoot/qemu/launch-vm.sh`)
# =============================================================================
# Starts the macOS Tahoe virtual machine using:
#   - Reims-patched `qemu-system-x86_64` (`vendor/qemu`)
#   - Reims vGPU (`libreims_vgpu.so` + `ReimsVgpu.rom`)
#   - Physical Intel UHD Graphics 730 (`0x8086:0x4c8b`, `intel_icd.json`) on bare metal
#   - Fullscreen borderless presentation (`REIMS_VGPU_WINDOW_BORDERLESS=1`)
#   - ICH9 AHCI SATA port 3 (`ide-hd,bus=sata.3,drive=disk,rotation_rate=1`) by default
#     so macOS 26 Tahoe Recovery & Disk Utility always see the target installation disk!
#     (Matches `reims-ctl`'s `DiskController::Ahci` in `crates/reims-ctl/src/qemu.rs`.)
#   - Strict zero-auto-format policy: never runs `mkfs` or formats any disk/partition.
#   - Automatic WSL2 high-speed I/O staging (`/root/tahoe-vm-fast`) so running inside
#     WSL2 uses native Linux ext4 + KVM (`Skylake-Client-noTSX-IBRS`, 6 vCPUs) instead
#     of slow `/mnt/c` 9P I/O or CPU shader emulation.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"

# 1. Detect whether we are running on bare-metal Linux or inside WSL2
IS_WSL=0
if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    IS_WSL=1
fi

# 2. Run GPU & Host Pre-Flight Verification (on bare-metal Linux)
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

# 3. Locate persistent VM storage (strictly NO auto-formatting of any disk)
VM_DIR="${TAHOEBOOT_VM_DIR:-}"
if [[ -z "${VM_DIR}" ]]; then
    VM_DIR="$("${TAHOEBOOT_ROOT}/scripts/select-storage.sh")"
fi

if [[ ! -f "${VM_DIR}/opencore.qcow2" || ! -f "${VM_DIR}/OVMF_CODE.fd" ]]; then
    echo "CRITICAL [ERR_OPENCORE_MISSING]: OpenCore or OVMF missing in ${VM_DIR}." >&2
    exit 21
fi

# 4. Decompress UDIF DMG ('koly' trailer) to raw bootable installer.img if needed
INSTALLER_RAW=""
if [[ -f "${VM_DIR}/installer.img" ]]; then
    INSTALLER_RAW="${VM_DIR}/installer.img"
else
    INSTALLER_SRC=""
    if [[ -f "${VM_DIR}/macOS-Tahoe-online-installer.dmg" ]]; then
        INSTALLER_SRC="${VM_DIR}/macOS-Tahoe-online-installer.dmg"
    elif [[ -f "${VM_DIR}/recovery.dmg" ]]; then
        INSTALLER_SRC="${VM_DIR}/recovery.dmg"
    fi

    if [[ -n "${INSTALLER_SRC}" ]]; then
        if tail -c 512 "${INSTALLER_SRC}" 2>/dev/null | head -c 4 | grep -q "^koly"; then
            echo "[TahoeBoot Launch] Converting compressed UDIF DMG (${INSTALLER_SRC}) to raw bootable image (${VM_DIR}/installer.img)..."
            qemu-img convert -f dmg -O raw "${INSTALLER_SRC}" "${VM_DIR}/installer.img.part"
            mv -f "${VM_DIR}/installer.img.part" "${VM_DIR}/installer.img"
            INSTALLER_RAW="${VM_DIR}/installer.img"
        else
            INSTALLER_RAW="${INSTALLER_SRC}"
        fi
    fi
fi

# 5. WSL2 Native ext4 High-Speed I/O Acceleration:
#    If VM_DIR is on /mnt/c (Windows NTFS over 9P), random IOPS is 20-50x slower than native ext4.
#    Mirror active boot images into /root/tahoe-vm-fast on native Linux ext4 so boot & install fly!
ACTIVE_VM_DIR="${VM_DIR}"
if [[ "${IS_WSL}" == "1" && "${VM_DIR}" == /mnt/* && "${TAHOEBOOT_DISABLE_FAST_CACHE:-0}" != "1" ]]; then
    FAST_DIR="/root/tahoe-vm-fast"
    mkdir -p "${FAST_DIR}/logs"
    echo "[TahoeBoot Speedup] WSL2 detected with /mnt/* path: staging VM images on native ext4 (${FAST_DIR}) to eliminate 9P I/O bottleneck..."
    for f in opencore.qcow2 OVMF_CODE.fd OVMF_VARS.fd; do
        if [[ ! -f "${FAST_DIR}/${f}" || "${VM_DIR}/${f}" -nt "${FAST_DIR}/${f}" ]]; then
            cp -f "${VM_DIR}/${f}" "${FAST_DIR}/${f}"
        fi
    done
    if [[ ! -f "${FAST_DIR}/disk.qcow2" ]]; then
        if [[ -f "${VM_DIR}/disk.qcow2" ]]; then
            cp --sparse=always -f "${VM_DIR}/disk.qcow2" "${FAST_DIR}/disk.qcow2"
        else
            qemu-img create -f qcow2 -o cluster_size=65536,lazy_refcounts=on "${FAST_DIR}/disk.qcow2" 410G >/dev/null
        fi
    fi
    if [[ -n "${INSTALLER_RAW}" && -f "${INSTALLER_RAW}" ]]; then
        if [[ ! -f "${FAST_DIR}/installer.img" || "${INSTALLER_RAW}" -nt "${FAST_DIR}/installer.img" ]]; then
            echo "[TahoeBoot Speedup] Caching 2.5 GiB installer.img onto native Linux ext4 (${FAST_DIR}/installer.img)..."
            cp --sparse=always -f "${INSTALLER_RAW}" "${FAST_DIR}/installer.img"
        fi
        INSTALLER_RAW="${FAST_DIR}/installer.img"
    fi
    ACTIVE_VM_DIR="${FAST_DIR}"
fi

mkdir -p "${ACTIVE_VM_DIR}/logs" "${VM_DIR}/logs"

RAW_DISK_DEV="${TAHOEBOOT_RAW_DISK:-}"
if [[ -z "${RAW_DISK_DEV}" && -f "${VM_DIR}/.raw_disk_device" ]]; then
    RAW_DISK_DEV="$(cat "${VM_DIR}/.raw_disk_device")"
fi

DISK_CACHE_OPT="${TAHOEBOOT_DISK_CACHE:-writeback}"
if [[ -n "${RAW_DISK_DEV}" && -b "${RAW_DISK_DEV}" ]]; then
    DISK_DRIVE_ARG="id=disk,if=none,format=raw,file=${RAW_DISK_DEV},cache=none,aio=native,discard=unmap"
    echo "[TahoeBoot Storage] Using 100% raw block device passthrough: ${RAW_DISK_DEV}"
elif [[ -f "${ACTIVE_VM_DIR}/disk.qcow2" ]]; then
    DISK_DRIVE_ARG="id=disk,if=none,format=qcow2,file=${ACTIVE_VM_DIR}/disk.qcow2,cache=${DISK_CACHE_OPT},aio=threads,discard=unmap"
else
    echo "CRITICAL [ERR_STORAGE_NOT_FOUND]: Neither raw block device nor disk.qcow2 found in ${ACTIVE_VM_DIR}." >&2
    exit 22
fi

# 6. Locate Reims-patched QEMU & Reims vGPU runtime
QEMU_BIN="${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-x86_64"
if [[ -x "/root/tahoe-build/qemu-build/qemu-system-x86_64" && "${IS_WSL}" == "1" ]]; then
    QEMU_BIN="/root/tahoe-build/qemu-build/qemu-system-x86_64"
elif [[ ! -x "${QEMU_BIN}" ]]; then
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

# 7. Read configurable parameters (tuned for Intel Core i5-11400 6C/12T & 16GB RAM)
CPUS="${TAHOEBOOT_CPUS:-6}"
MEMORY_MIB="${TAHOEBOOT_MEMORY_MIB:-8192}"
RESOLUTION="${TAHOEBOOT_RESOLUTION:-1920x1080}"
SSH_PORT="${TAHOEBOOT_SSH_PORT:-2222}"
# IMPORTANT: Default disk controller MUST be 'ahci' (sata.3) so macOS 26 Tahoe's installer
# and Disk Utility see the 410 GiB target disk (`reims-ctl` `src/vm.rs` lines 148-153)!
DISK_CONTROLLER="${TAHOEBOOT_DISK_CONTROLLER:-ahci}"

# 8. Graphics & GPU configuration:
#    - On bare-metal Linux (`/dev/dri/renderD128` + `intel_icd.json`): full Reims vGPU
#      (`apple-gfx-pci` + `apple-gfx-iosurface-pci` + `apple-videotoolbox-pci` + `apple-m2scaler-pci`)
#      on the physical Intel UHD Graphics 730 (`0x8086:0x4c8b`).
#    - Inside WSL2 (where `/dev/dri/renderD128` does not exist and Vulkan falls back to `llvmpipe` CPU):
#      default to `vmware-svga` (`-display gtk`) or `apple-gfx-pci` WITHOUT `apple-m2scaler-pci`
#      so `llvmpipe` is not forced to execute 7 heavy M2 scaler compute shaders on the CPU every frame!
HAS_INTEL_DRI=0
if [[ -e "/dev/dri/renderD128" && -f "/usr/share/vulkan/icd.d/intel_icd.json" ]]; then
    HAS_INTEL_DRI=1
fi

GRAPHICS_MODE="${TAHOEBOOT_GRAPHICS:-auto}"
if [[ "${GRAPHICS_MODE}" == "auto" ]]; then
    if [[ "${HAS_INTEL_DRI}" == "1" ]]; then
        GRAPHICS_MODE="reims-vgpu"
    elif [[ "${IS_WSL}" == "1" ]]; then
        # In WSL2 without /dev/dri/renderD128, macOS Recovery/Installer uses the EFI framebuffer
        # either way (Reims docs/qemu.md line 108: "a macOS installer or recovery image, which has
        # no driver of the device's own, takes the boot framebuffer over"). Using vmware-svga in WSL2
        # avoids running metal2vulkan + M2 scaler compute shaders on llvmpipe CPU!
        GRAPHICS_MODE="vmware-svga"
    else
        GRAPHICS_MODE="reims-vgpu"
    fi
fi

export LD_LIBRARY_PATH="${REIMS_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if [[ "${HAS_INTEL_DRI}" == "1" ]]; then
    export REIMS_VGPU_VENDOR_ID="${REIMS_VGPU_VENDOR_ID:-0x8086}"
    export REIMS_VGPU_DEVICE_ID="${REIMS_VGPU_DEVICE_ID:-0x4c8b}"
    export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/usr/share/vulkan/icd.d/intel_icd.json}"
    export VK_ICD_FILENAMES="${VK_DRIVER_FILES}"
fi

# Match upstream `reims-ctl` (`src/vm.rs` lines 441-447): Skylake-Client-noTSX-IBRS with nested VMX
OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
CPU_MODEL="${TAHOEBOOT_CPU_MODEL:-Skylake-Client-noTSX-IBRS}"
CPU_FLAGS="${CPU_MODEL},kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,vmx=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"

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
    -drive "if=pflash,format=raw,readonly=on,file=${ACTIVE_VM_DIR}/OVMF_CODE.fd"
    -drive "if=pflash,format=raw,file=${ACTIVE_VM_DIR}/OVMF_VARS.fd"
    -smbios "type=2"
    -device "ich9-ahci,id=sata,addr=0x2"
    -drive "id=opencore,if=none,format=qcow2,file=${ACTIVE_VM_DIR}/opencore.qcow2"
    -device "ide-hd,bus=sata.2,drive=opencore,bootindex=1"
    -drive "${DISK_DRIVE_ARG}"
)

# Attach target installation/system disk on ICH9 AHCI SATA port 3 (`sata.3`) by default
# so macOS Tahoe Disk Utility & Installer detect it immediately!
if [[ "${DISK_CONTROLLER}" == "nvme" ]]; then
    QEMU_ARGS+=(-device "nvme,drive=disk,serial=reims-ctl,addr=0xa")
else
    QEMU_ARGS+=(-device "ide-hd,bus=sata.3,drive=disk,rotation_rate=1")
fi

# Attach installer image on ICH9 AHCI SATA port 4 (`sata.4`)
if [[ -n "${INSTALLER_RAW}" && -f "${INSTALLER_RAW}" ]]; then
    QEMU_ARGS+=(
        -drive "id=installer,if=none,format=raw,snapshot=on,file=${INSTALLER_RAW}"
        -device "ide-hd,bus=sata.4,drive=installer"
    )
fi

QEMU_ARGS+=(
    -L "${REIMS_ROM_DIR}"
    -vga "none"
)

if [[ "${GRAPHICS_MODE}" == "vmware-svga" ]]; then
    unset REIMS_VGPU_WINDOW || true
    unset REIMS_VGPU_LOG || true
    QEMU_ARGS+=(
        -device "vmware-svga,id=gfx,bus=pcie.0,addr=0x4"
        -display "gtk,show-cursor=on"
    )
else
    export REIMS_VGPU_WINDOW_BORDERLESS="${REIMS_VGPU_WINDOW_BORDERLESS:-1}"
    QEMU_ARGS+=(
        -display "none"
        -device "apple-gfx-pci,id=gfx,bus=pcie.0,addr=0x4,displays=1,resolution=${RESOLUTION},romfile=ReimsVgpu.rom"
        -device "apple-gfx-iosurface-pci,id=iosfc,gpu=gfx,bus=pcie.0,addr=0x6"
    )
    # Only attach apple-videotoolbox-pci and apple-m2scaler-pci when backed by physical GPU DRI
    # (prevents llvmpipe CPU from compiling/running M2 scaler compute shaders on every frame).
    if [[ "${HAS_INTEL_DRI}" == "1" || "${TAHOEBOOT_FORCE_VIDEO_ACCEL:-0}" == "1" ]]; then
        QEMU_ARGS+=(
            -device "apple-videotoolbox-pci,id=video,bus=pcie.0,addr=0x8"
            -device "apple-m2scaler-pci,id=scaler,bus=pcie.0,addr=0x9"
        )
    fi
fi

QEMU_ARGS+=(
    -device "qemu-xhci,id=xhci,addr=0x5,conditional-intr-mapping=on"
    -device "usb-kbd,id=kbd,bus=xhci.0"
    -device "usb-tablet,id=tablet,bus=xhci.0"
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27,addr=0x3"
    -serial "file:${VM_DIR}/logs/console.log"
    -D "${VM_DIR}/logs/qemu.log"
)

echo "[TahoeBoot Launch] Starting macOS Tahoe VM:"
echo "  - Mode       : ${GRAPHICS_MODE} (Disk Controller: ${DISK_CONTROLLER^^} on sata.3, 410 GiB)"
echo "  - Resources  : ${CPUS} vCPUs (${CPU_MODEL}, KVM), ${MEMORY_MIB} MiB RAM, ${RESOLUTION}"
echo "  - Storage Dir: ${ACTIVE_VM_DIR}"
exec "${QEMU_BIN}" "${QEMU_ARGS[@]}" "$@"
