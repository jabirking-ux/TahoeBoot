#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Reims-Patched QEMU Builder (`TahoeBoot/qemu/build-qemu.sh`)
# =============================================================================
# Builds `qemu-system-x86_64` from `upstream/reims-vgpu/vendor/qemu` using a
# native Linux build directory (`/tmp/tahoe-qemu-build`) and links it against
# `libreims_vgpu` (`--enable-pvg --enable-kvm`).
# Installs the resulting binary to `TahoeBoot/qemu/bin/qemu-system-x86_64` and
# installs `ReimsVgpu.rom` + keymaps/firmware into `TahoeBoot/reims/share/`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"

QEMU_SRC="/root/tahoe-build/reims-vgpu/vendor/qemu"
if [[ ! -d "${QEMU_SRC}" ]]; then
    QEMU_SRC="${PROJECT_ROOT}/upstream/reims-vgpu/vendor/qemu"
fi
REIMS_DIST="/root/tahoe-build/reims-vgpu/target/dist-vulkan"
if [[ ! -d "${REIMS_DIST}" ]]; then
    REIMS_DIST="${PROJECT_ROOT}/upstream/reims-vgpu/target/dist-vulkan"
fi

BUILD_DIR="/root/tahoe-build/qemu-build"
mkdir -p "${BUILD_DIR}" "${TAHOEBOOT_ROOT}/qemu/bin" "${TAHOEBOOT_ROOT}/reims/share"

export PKG_CONFIG_PATH="${REIMS_DIST}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

echo "[TahoeBoot QEMU] Configuring Reims-patched QEMU in ${BUILD_DIR}..."
cd "${BUILD_DIR}"
if [[ ! -f "build.ninja" ]]; then
    "${QEMU_SRC}/configure" \
        --target-list=x86_64-softmmu \
        --enable-kvm \
        --enable-pvg \
        --enable-slirp \
        --enable-libusb \
        --enable-gtk \
        --disable-sdl \
        --disable-docs \
        --disable-werror
fi

echo "[TahoeBoot QEMU] Compiling qemu-system-x86_64 with ninja..."
ninja -j"$(nproc)" qemu-system-x86_64

cp -f "${BUILD_DIR}/qemu-system-x86_64" "${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-x86_64"
cp -f "${REIMS_DIST}/share/reims-vgpu/ReimsVgpu.rom" "${TAHOEBOOT_ROOT}/reims/share/ReimsVgpu.rom"
for rom in efi-virtio.rom kvmvapic.bin linuxboot_dma.bin; do
    if [[ -f "${QEMU_SRC}/pc-bios/${rom}" ]]; then
        cp -f "${QEMU_SRC}/pc-bios/${rom}" "${TAHOEBOOT_ROOT}/reims/share/${rom}"
    fi
done

echo "[TahoeBoot QEMU] Verifying compiled Reims PCI devices:"
LD_LIBRARY_PATH="${TAHOEBOOT_ROOT}/reims/lib" "${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-x86_64" -device help | grep -E "apple-gfx|apple-videotoolbox|apple-m2scaler"
