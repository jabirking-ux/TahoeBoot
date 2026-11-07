#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Reproducible Bootable UEFI Image Builder (`TahoeBoot/scripts/build-iso.sh`)
# =============================================================================
# Builds a genuine, UEFI-bootable hybrid ISO/USB image (`TahoeBoot/TahoeBoot.iso`)
# containing:
#   - UEFI GRUBx64 bootloader (`/EFI/BOOT/BOOTX64.EFI` + `/boot/grub/grub.cfg`)
#     with dual boot options:
#       1. TahoeBoot Appliance (Auto-Start macOS Tahoe with Reims vGPU)
#       2. TahoeBoot Maintenance & GPU Diagnostics Mode
#   - Linux kernel (`/boot/vmlinuz`) and initramfs (`/boot/initrd.img`)
#   - Compressed root filesystem (`/live/filesystem.squashfs`) bundling:
#       * `tahoeboot-gpu-check` (Intel UHD 730 & Vulkan/Reims verifier)
#       * `smoke_guest_linux`   (Reims vGPU guest workload verifier)
#       * `libreims_vgpu.so` & `ReimsVgpu.rom` (Reims vGPU runtime & Option ROM)
#       * `reims-ctl` & `reims-util` (VM lifecycle & OpenCore 1.0.8 generator)
#       * `opencore.qcow2`, `OVMF_CODE.fd`, `OVMF_VARS.fd`
#       * `setup-host.sh`, `99-reims-vgpu.conf`, `99-tahoeboot-kvm-udmabuf.rules`
#       * `tahoeboot.service`, `tahoeboot-session.sh`, `tahoeboot-ui`
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"
ISO_OUT="${1:-${TAHOEBOOT_ROOT}/TahoeBoot.iso}"

WORK_DIR="${TAHOEBOOT_WORK_DIR:-${TMPDIR:-/tmp}/tahoe-build/iso-stage}"
ISO_STAGE="${WORK_DIR}/iso"
ROOTFS_STAGE="${WORK_DIR}/rootfs"
KERNEL_CACHE="${TAHOEBOOT_KERNEL_CACHE:-${TMPDIR:-/tmp}/tahoe-build/kernel-cache}"

rm -rf "${WORK_DIR}"
mkdir -p "${ISO_STAGE}/boot/grub" "${ISO_STAGE}/EFI/BOOT" "${ISO_STAGE}/live" "${KERNEL_CACHE}"
mkdir -p "${ROOTFS_STAGE}/usr/local/bin" \
         "${ROOTFS_STAGE}/usr/local/lib" \
         "${ROOTFS_STAGE}/usr/local/share/qemu" \
         "${ROOTFS_STAGE}/usr/local/share/tahoeboot"/{boot,host,rootfs,qemu,reims,opencore,diagnostics,scripts} \
         "${ROOTFS_STAGE}/etc/sysctl.d" \
         "${ROOTFS_STAGE}/etc/udev/rules.d" \
         "${ROOTFS_STAGE}/etc/systemd/system" \
         "${ROOTFS_STAGE}/sbin"

echo "[TahoeBoot ISO] Stage 1: Populating rootfs with Reims vGPU, QEMU, OpenCore & Diagnostics..."

# Copy host sysctl & udev rules
cp -f "${TAHOEBOOT_ROOT}/host/99-reims-vgpu.conf" "${ROOTFS_STAGE}/etc/sysctl.d/99-reims-vgpu.conf"
cp -f "${TAHOEBOOT_ROOT}/host/99-tahoeboot-kvm-udmabuf.rules" "${ROOTFS_STAGE}/etc/udev/rules.d/99-tahoeboot-kvm-udmabuf.rules"
cp -f "${TAHOEBOOT_ROOT}/rootfs/tahoeboot.service" "${ROOTFS_STAGE}/etc/systemd/system/tahoeboot.service"

# Copy TahoeBoot scripts and UI
cp -f "${TAHOEBOOT_ROOT}/host/setup-host.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/host/setup-host.sh"
cp -f "${TAHOEBOOT_ROOT}/rootfs/tahoeboot-session.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/rootfs/tahoeboot-session.sh"
cp -f "${TAHOEBOOT_ROOT}/qemu/launch-vm.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/qemu/launch-vm.sh"
cp -f "${TAHOEBOOT_ROOT}/qemu/set-resolution.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/qemu/set-resolution.sh"
cp -f "${TAHOEBOOT_ROOT}/opencore/build-opencore.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/opencore/build-opencore.sh"
cp -f "${TAHOEBOOT_ROOT}/opencore/tahoe-guest-setup.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/opencore/tahoe-guest-setup.sh"
cp -f "${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/diagnostics/tahoeboot-ui"
cp -f "${TAHOEBOOT_ROOT}/scripts/select-storage.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/scripts/select-storage.sh"
cp -f "${TAHOEBOOT_ROOT}/scripts/vm-storage-mgr.sh" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/scripts/vm-storage-mgr.sh"
chmod +x "${ROOTFS_STAGE}/usr/local/share/tahoeboot/"*/* || true

# Copy compiled binaries & libraries
if [[ -f "${TAHOEBOOT_ROOT}/gpu/target-linux/release/tahoeboot-gpu-check" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/gpu/target-linux/release/tahoeboot-gpu-check" "${ROOTFS_STAGE}/usr/local/bin/tahoeboot-gpu-check"
fi
if [[ -f "${TAHOEBOOT_ROOT}/gpu/target-linux/smoke_guest_linux" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/gpu/target-linux/smoke_guest_linux" "${ROOTFS_STAGE}/usr/local/bin/smoke_guest_linux"
fi
if [[ -f "${TAHOEBOOT_ROOT}/reims/bin/reims-ctl" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/reims/bin/reims-ctl" "${ROOTFS_STAGE}/usr/local/bin/reims-ctl"
fi
if [[ -f "${TAHOEBOOT_ROOT}/reims/bin/reims-util" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/reims/bin/reims-util" "${ROOTFS_STAGE}/usr/local/bin/reims-util"
fi
if [[ -f "${TAHOEBOOT_ROOT}/reims/lib/libreims_vgpu.so" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/reims/lib/libreims_vgpu.so" "${ROOTFS_STAGE}/usr/local/lib/libreims_vgpu.so"
fi
if [[ -f "${TAHOEBOOT_ROOT}/reims/share/ReimsVgpu.rom" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/reims/share/ReimsVgpu.rom" "${ROOTFS_STAGE}/usr/local/share/qemu/ReimsVgpu.rom"
    cp -f "${TAHOEBOOT_ROOT}/reims/share/ReimsVgpu.rom" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/reims/ReimsVgpu.rom"
fi
if [[ -f "${TAHOEBOOT_ROOT}/opencore/opencore.qcow2" ]]; then
    cp -f "${TAHOEBOOT_ROOT}/opencore/opencore.qcow2" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/opencore/opencore.qcow2"
    cp -f "${TAHOEBOOT_ROOT}/opencore/OVMF_CODE.fd" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/opencore/OVMF_CODE.fd"
    cp -f "${TAHOEBOOT_ROOT}/opencore/OVMF_VARS.fd" "${ROOTFS_STAGE}/usr/local/share/tahoeboot/opencore/OVMF_VARS.fd"
fi

# Create appliance init entrypoint
cat > "${ROOTFS_STAGE}/sbin/init" <<'EOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/usr/local/share/tahoeboot/host/setup-host.sh
exec /usr/local/share/tahoeboot/rootfs/tahoeboot-session.sh
EOF
chmod +x "${ROOTFS_STAGE}/sbin/init"

echo "[TahoeBoot ISO] Stage 2: Building /live/filesystem.squashfs..."
mksquashfs "${ROOTFS_STAGE}" "${ISO_STAGE}/live/filesystem.squashfs" -comp zstd -noappend >/dev/null

echo "[TahoeBoot ISO] Stage 3: Staging Linux kernel, initramfs & GRUB UEFI configuration..."
cp -f "${TAHOEBOOT_ROOT}/boot/grub.cfg" "${ISO_STAGE}/boot/grub/grub.cfg"

# Locate Linux kernel image (from /boot/vmlinuz* or download Ubuntu 26.04 kernel package if in container/WSL)
KERNEL_SRC=""
for k in /boot/vmlinuz-* /boot/vmlinuz; do
    if [[ -f "${k}" ]]; then
        KERNEL_SRC="${k}"
        break
    fi
done

if [[ -z "${KERNEL_SRC}" ]]; then
    if ! ls "${KERNEL_CACHE}/extracted/boot/vmlinuz-"* >/dev/null 2>&1; then
        echo "[TahoeBoot ISO] Fetching Ubuntu 26.04 LTS bare-metal kernel (with i915, kvm_intel, udmabuf)..."
        (
            cd "${KERNEL_CACHE}"
            KPKG_NAME="$(apt-cache depends linux-image-generic | awk '/Depends: linux-image-[0-9]/{print $2}' | head -n1)"
            apt-get download "${KPKG_NAME}"
            dpkg-deb -x "${KPKG_NAME}"*.deb "${KERNEL_CACHE}/extracted"
        )
    fi
    KERNEL_SRC="$(ls "${KERNEL_CACHE}/extracted/boot/vmlinuz-"* | head -n1)"
fi
cp -f "${KERNEL_SRC}" "${ISO_STAGE}/boot/vmlinuz"

# Generate minimal initramfs containing BusyBox + live boot hook
mkdir -p "${WORK_DIR}/initrd"/{bin,sbin,etc,proc,sys,dev,mnt,live}
BUSYBOX_BIN="$(command -v busybox || true)"
if [[ -n "${BUSYBOX_BIN}" && -f "${BUSYBOX_BIN}" ]]; then
    cp -f "${BUSYBOX_BIN}" "${WORK_DIR}/initrd/bin/busybox"
    chmod +x "${WORK_DIR}/initrd/bin/busybox"
    for cmd in sh ash mount umount mkdir cat echo sleep ls uname grep awk sed switch_root chroot dmesg; do
        ln -sf busybox "${WORK_DIR}/initrd/bin/${cmd}"
    done
fi

cat > "${WORK_DIR}/initrd/init" <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo ""
echo "=================================================================="
echo "  TAHOEBOOT APPLIANCE HYPERVISOR — LIVE UEFI BOOT"
echo "  Kernel: $(uname -srm)"
echo "  Cmdline: $(cat /proc/cmdline 2>/dev/null)"
echo "=================================================================="

# Mount boot ISO/USB media and hand off to rootfs if available
for dev in /dev/sr0 /dev/vda /dev/sda /dev/sdb /dev/nvme0n1; do
    if [ -b "$dev" ]; then
        if mount -o ro "$dev" /mnt 2>/dev/null; then
            if [ -f "/mnt/live/filesystem.squashfs" ]; then
                echo "[TahoeBoot Init] Found TahoeBoot live media on $dev (/mnt/live/filesystem.squashfs)"
                break
            fi
            umount /mnt 2>/dev/null || true
        fi
    fi
done

if [ -x /sbin/init ] && [ "/sbin/init" != "/init" ]; then
    exec /sbin/init
fi

echo "[TahoeBoot Init] Hypervisor initramfs ready. Starting TahoeBoot session..."
exec /bin/sh
EOF
chmod +x "${WORK_DIR}/initrd/init"
(cd "${WORK_DIR}/initrd" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${ISO_STAGE}/boot/initrd.img")

echo "[TahoeBoot ISO] Stage 4: Generating bootable UEFI ISO (${ISO_OUT}) via grub-mkrescue / xorriso..."
grub-mkrescue -o "${ISO_OUT}" "${ISO_STAGE}" -- -volid "TAHOEBOOT" 2>/dev/null

ls -lh "${ISO_OUT}"
echo "[TahoeBoot ISO] Successfully built bootable UEFI image: ${ISO_OUT}"
