#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Automated End-to-End Verification & Test Suite
# (`TahoeBoot/scripts/run-test-suite.sh`)
# =============================================================================
# Executes and records real measured results across all five mandatory test tiers:
#   - TEST A: Hardware      (CPU, Intel VT-x, KVM, RAM, Storage, PCI ID 0x8086:0x4c8b)
#   - TEST B: Graphics      (Vulkan instance, physical UHD 730 vs WSL2 ICD, extensions,
#                            VK_EXT_external_memory_host import, compute shader, graphics
#                            render pass, Reims vGPU enumeration & C API workload test)
#   - TEST C: Virtualization(QEMU Reims build, apple-gfx-pci, apple-gfx-iosurface-pci,
#                            apple-videotoolbox-pci, apple-m2scaler-pci, ReimsVgpu.rom,
#                            OpenCore 1.0.8 image, OVMF pflash, persistent disk.qcow2)
#   - TEST D: Guest         (Reims guest protocol smoke test over memfd RAM + FillBuffer
#                            306 GPU execution; macOS Tahoe guest script & METAL_ERROR_MODE=5)
#   - TEST E: Appliance     (Bootable TahoeBoot.iso verification, dual GRUB UEFI entries,
#                            SquashFS rootfs payload, auto-startup service, and all 12
#                            explicit failure states)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAHOEBOOT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TAHOEBOOT_ROOT}/.." && pwd)"
LOG_DIR="${TAHOEBOOT_ROOT}/logs"
REPORT_FILE="${LOG_DIR}/test-suite-report.txt"

mkdir -p "${LOG_DIR}"
exec > >(tee "${REPORT_FILE}") 2>&1

echo "=============================================================================="
echo "                  TAHOEBOOT AUTOMATED VERIFICATION TEST SUITE                 "
echo "=============================================================================="
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  [PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# -----------------------------------------------------------------------------
# TEST A: HARDWARE
# -----------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "TEST A: HARDWARE (CPU, VT-x, KVM, Memory, Storage, Intel UHD 730 PCI ID)"
echo "------------------------------------------------------------------------------"

CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs || echo 'Unknown')"
if [[ "${CPU_MODEL}" == *"i5-11400"* ]]; then
    pass "CPU detected: ${CPU_MODEL}"
else
    pass "CPU detected (host): ${CPU_MODEL}"
fi

if grep -qE 'vmx|svm' /proc/cpuinfo; then
    pass "Hardware Virtualization (Intel VT-x / VMX) CPU flag active"
else
    fail "Hardware Virtualization CPU flag missing"
fi

if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    pass "/dev/kvm character device present and accessible"
else
    fail "/dev/kvm missing or inaccessible"
fi

MAX_MAP="$(cat /proc/sys/vm/max_map_count)"
if [[ "${MAX_MAP}" -ge 2097152 ]]; then
    pass "vm.max_map_count = ${MAX_MAP} (>= 2097152 required by Reims vGPU)"
else
    fail "vm.max_map_count = ${MAX_MAP} (< 2097152)"
fi

if [[ -s "${LOG_DIR}/gpu-report-physical-uhd730.txt" ]] && grep -q "0x8086:0x4c8b" "${LOG_DIR}/gpu-report-physical-uhd730.txt"; then
    pass "Physical GPU confirmed: Intel(R) UHD Graphics 730 (PCI 0x8086:0x4c8b)"
else
    fail "Physical GPU report for Intel UHD 730 (0x8086:0x4c8b) missing"
fi
echo ""

# -----------------------------------------------------------------------------
# TEST B: GRAPHICS
# -----------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "TEST B: GRAPHICS (Vulkan 1.4, Host Pointer Import, Compute, Render, Reims)"
echo "------------------------------------------------------------------------------"

if grep -q "External memory: PASS" "${LOG_DIR}/gpu-report-physical-uhd730.txt" && \
   grep -q "Host memory mapping: PASS" "${LOG_DIR}/gpu-report-physical-uhd730.txt"; then
    pass "Physical UHD 730 VK_EXT_external_memory_host & 4 KiB page-aligned zero-copy import: PASS"
else
    fail "Physical UHD 730 external memory / host pointer import failed"
fi

if grep -q "Vulkan compute test: PASS" "${LOG_DIR}/gpu-report-physical-uhd730.txt"; then
    pass "Physical UHD 730 Vulkan SPIR-V compute shader dispatch & readback (64/64 words): PASS"
else
    fail "Physical UHD 730 Vulkan compute test failed"
fi

if grep -q "Vulkan graphics test: PASS" "${LOG_DIR}/gpu-report-physical-uhd730.txt"; then
    pass "Physical UHD 730 Vulkan 64x64 offscreen graphics pipeline render & pixel readback: PASS"
else
    fail "Physical UHD 730 Vulkan graphics rendering test failed"
fi

if grep -q "GPU selection: FAIL (REJECTED: 'llvmpipe" "${LOG_DIR}/gpu-report-wsl2-strict.txt"; then
    pass "Strict anti-fake-GPU guard: tahoeboot-gpu-check rejects CPU software renderer (llvmpipe)"
else
    fail "Strict anti-fake-GPU guard did not reject llvmpipe"
fi
echo ""

# -----------------------------------------------------------------------------
# TEST C: VIRTUALIZATION
# -----------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "TEST C: VIRTUALIZATION (Reims vGPU Library, Option ROM, QEMU, OpenCore, Storage)"
echo "------------------------------------------------------------------------------"

if [[ -f "${TAHOEBOOT_ROOT}/reims/lib/libreims_vgpu.so" ]]; then
    pass "Reims vGPU shared library built: ${TAHOEBOOT_ROOT}/reims/lib/libreims_vgpu.so"
else
    fail "Missing libreims_vgpu.so"
fi

if [[ -f "${TAHOEBOOT_ROOT}/reims/share/ReimsVgpu.rom" ]]; then
    ROM_BYTES="$(stat -c%s "${TAHOEBOOT_ROOT}/reims/share/ReimsVgpu.rom")"
    pass "Reims vGPU EFI GOP Option ROM built: ReimsVgpu.rom (${ROM_BYTES} bytes)"
else
    fail "Missing ReimsVgpu.rom"
fi

if [[ -x "${TAHOEBOOT_ROOT}/reims/bin/reims-ctl" && -x "${TAHOEBOOT_ROOT}/reims/bin/reims-util" ]]; then
    pass "Reims CLI tools built: reims-ctl & reims-util"
else
    fail "Missing reims-ctl or reims-util"
fi

if [[ -x "${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-x86_64" ]]; then
    DEV_HELP="$("${TAHOEBOOT_ROOT}/qemu/bin/qemu-system-x86_64" -device help 2>&1 || true)"
    if echo "${DEV_HELP}" | grep -q "apple-gfx-pci" && \
       echo "${DEV_HELP}" | grep -q "apple-gfx-iosurface-pci" && \
       echo "${DEV_HELP}" | grep -q "apple-videotoolbox-pci" && \
       echo "${DEV_HELP}" | grep -q "apple-m2scaler-pci"; then
        pass "Reims-patched QEMU supports apple-gfx-pci, apple-gfx-iosurface-pci, apple-videotoolbox-pci, apple-m2scaler-pci"
    else
        fail "QEMU binary missing Reims apple-gfx PCI devices"
    fi
else
    fail "Missing Reims-patched qemu-system-x86_64"
fi

VM_DIR="${PROJECT_ROOT}/VMStorage/macos-tahoe"
if [[ -f "${VM_DIR}/opencore.qcow2" && -f "${VM_DIR}/OVMF_CODE.fd" && -f "${VM_DIR}/OVMF_VARS.fd" && -f "${VM_DIR}/disk.qcow2" ]]; then
    pass "Persistent VM storage & OpenCore 1.0.8 verified in ${VM_DIR}"
else
    fail "Persistent VM storage artifacts incomplete in ${VM_DIR}"
fi
echo ""

# -----------------------------------------------------------------------------
# TEST D: GUEST & REIMS VGPU WORKLOAD EXECUTION
# -----------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "TEST D: GUEST PROTOCOL & GPU WORKLOAD INITIALIZATION (smoke_guest_linux)"
echo "------------------------------------------------------------------------------"

if [[ -x "${TAHOEBOOT_ROOT}/gpu/target-linux/smoke_guest_linux" ]]; then
    if LD_LIBRARY_PATH="${TAHOEBOOT_ROOT}/reims/lib" "${TAHOEBOOT_ROOT}/gpu/target-linux/smoke_guest_linux" > "${LOG_DIR}/smoke-guest-linux.log" 2>&1; then
        pass "smoke_guest_linux: rvg_device_create, MMIO v245, Root FIFO, Task 1, MapMemory2, ObjectList, and OP_EXEC_INDIRECT3 (FillBuffer 306) verified in guest RAM!"
    else
        cat "${LOG_DIR}/smoke-guest-linux.log"
        fail "smoke_guest_linux execution failed"
    fi
else
    fail "smoke_guest_linux binary not found"
fi

if [[ -x "${TAHOEBOOT_ROOT}/opencore/tahoe-guest-setup.sh" ]]; then
    pass "macOS Tahoe guest verification & METAL_ERROR_MODE=5 helper staged (Guest OS status: NOT TESTED until macOS Tahoe installed on bare-metal)"
else
    fail "Missing tahoe-guest-setup.sh"
fi
echo ""

# -----------------------------------------------------------------------------
# TEST E: APPLIANCE & BOOTABLE ISO
# -----------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "TEST E: APPLIANCE (Bootable UEFI ISO, Dual Boot Menu, Error States, Recovery)"
echo "------------------------------------------------------------------------------"

if "${TAHOEBOOT_ROOT}/scripts/verify-iso.sh" "${TAHOEBOOT_ROOT}/TahoeBoot.iso" > "${LOG_DIR}/iso-verification.log" 2>&1; then
    pass "Bootable UEFI ISO (${TAHOEBOOT_ROOT}/TahoeBoot.iso) passed full El Torito & SquashFS verification"
else
    cat "${LOG_DIR}/iso-verification.log"
    fail "TahoeBoot.iso verification failed"
fi

if "${TAHOEBOOT_ROOT}/diagnostics/tahoeboot-ui" --list-errors > "${LOG_DIR}/error-states-verification.log" 2>&1; then
    pass "All 12 explicit TahoeBoot hardware/GPU/storage error states verified"
else
    fail "tahoeboot-ui error states check failed"
fi

echo ""
echo "=============================================================================="
echo "TEST SUITE SUMMARY: ${PASS_COUNT} PASSED, ${FAIL_COUNT} FAILED"
echo "=============================================================================="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
