# TahoeBoot Troubleshooting, Recovery & Error Reference Guide

## 1. Explicit Error Codes (`tahoeboot-ui --error <CODE>`)

TahoeBoot never silently falls back to software rendering or an unaccelerated framebuffer. If any layer of the hardware, hypervisor, Vulkan, Reims vGPU, or storage stack fails, [`tahoeboot-ui`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/diagnostics/tahoeboot-ui) halts startup and presents a diagnostic panel with one of the following 12 error codes:

| Error Code | Failing Layer | Root Cause & Remediation |
| :--- | :--- | :--- |
| `ERR_VTX_DISABLED` | CPU / BIOS | Intel VT-x (`vmx`) is disabled. Enter Gigabyte `B560M DS3H V2` UEFI BIOS -> enable **Intel Virtualization Technology**. |
| `ERR_KVM_UNAVAILABLE` | Linux Kernel | `/dev/kvm` is missing or lacks permissions. Run `modprobe kvm_intel nested=1` and `/usr/local/share/tahoeboot/host/setup-host.sh`. |
| `ERR_VULKAN_MISSING` | Host Graphics | Vulkan loader (`libvulkan.so.1`) or `/usr/share/vulkan/icd.d/intel_icd.json` is missing. Verify `mesa-vulkan-drivers` installation. |
| `ERR_GPU_UNSUPPORTED` | GPU Selection | Only CPU software renderers (`llvmpipe`, `lavapipe`, `SwiftShader`) were found, or physical GPU lacks required Vulkan 1.3/1.4 features. Boot `TahoeBoot.iso` on bare-metal so `i915` binds to `0x8086:0x4c8b`. |
| `ERR_UDMABUF_OR_HOST_MEMORY` | Host Memory | `/dev/udmabuf` is unavailable or `vm.max_map_count < 2097152`. Run `modprobe udmabuf` and `sysctl -w vm.max_map_count=2097152`. |
| `ERR_REIMS_INIT_FAILED` | Reims vGPU | `rvg_device_create` failed to initialize `libreims_vgpu.so`. Run `reims-ctl doctor` and `smoke_guest_linux` to inspect the failure. |
| `ERR_QEMU_LAUNCH_FAILED` | QEMU / KVM | `qemu-system-x86_64` exited during initialization. Inspect `VMStorage/macos-tahoe/logs/qemu.log` and verify `ReimsVgpu.rom`. |
| `ERR_OPENCORE_MISSING` | Bootloader | `opencore.qcow2`, `OVMF_CODE.fd`, or `OVMF_VARS.fd` is missing. Run [`build-opencore.sh`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/opencore/build-opencore.sh). |
| `ERR_STORAGE_NOT_FOUND` | VM Storage | External SSD (`LABEL=TAHOE_VM`) or `disk.qcow2` not found. Connect external storage and run [`select-storage.sh`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/scripts/select-storage.sh). |
| `ERR_GUEST_GPU_INIT_FAILED` | macOS Guest | `AppleParavirtGPU` or `ReimsVgpu.kext` failed to bind in macOS Tahoe. Run `reims-ctl update-opencore` and apply `METAL_ERROR_MODE=5` via [`tahoe-guest-setup.sh`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/opencore/tahoe-guest-setup.sh). |
| `ERR_DISPLAY_INIT_FAILED` | Wayland / KMS | Wayland compositor (`cage`/`weston`) or SDL3 presentation window could not open display. Verify `/dev/dri/card0` permissions. |
| `ERR_MEMORY_ALLOC_FAILED` | Host RAM | Host could not allocate `8192 MiB` `memory-backend-memfd` RAM. Reduce `TAHOEBOOT_MEMORY_MIB=6144` if host memory is constrained. |

---

## 2. Maintenance & Recovery Mode

At the TahoeBoot UEFI GRUB menu, select:

> **`2. TahoeBoot Maintenance & GPU Diagnostics Mode (tahoeboot-gpu-check)`**

This boots the appliance with `tahoeboot.mode=diagnostics`, runs [`tahoeboot-gpu-check`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/gpu/src/main.rs) automatically, displays the Liquid Glass diagnostics summary, and drops into an interactive root recovery shell with the following utilities on `PATH`:

- `tahoeboot-gpu-check` — Full 13-step Intel UHD 730 & Vulkan/Reims hardware verifier.
- `smoke_guest_linux` — Standalone Reims vGPU C API (`rvg_device_create`) + `FillBuffer` (306) GPU workload test.
- `reims-ctl doctor` / `reims-ctl gpus` — Upstream Reims host & GPU diagnostics.
- `/usr/local/share/tahoeboot/opencore/build-opencore.sh` — Rebuilds `opencore.qcow2` and resets `OVMF_VARS.fd` (NVRAM reset).
- `/usr/local/share/tahoeboot/scripts/vm-storage-mgr.sh` — Creates/restores qcow2 snapshots and NVRAM backups.
