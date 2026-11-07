# TahoeBoot Hardware & Intel UHD Graphics 730 Compatibility Report

## 1. Detected Target Machine Hardware

| Component | Measured Value | Status |
| :--- | :--- | :--- |
| **CPU** | Intel Core i5-11400 (Rocket Lake-S, 11th Gen, 6 Cores / 12 Threads @ 2.60 GHz) | **PASS** |
| **Virtualization** | Intel VT-x (`vmx`) enabled in BIOS; KVM (`/dev/kvm`, `kvm_intel nested=1`) | **PASS** |
| **Motherboard** | Gigabyte Technology Co., Ltd. `B560M DS3H V2` (UEFI BIOS `F6`) | **PASS** |
| **System Memory** | 16 GB DDR4 (`16,181 MB` physical; `8,192 MiB` allocated to macOS Tahoe guest) | **PASS** |
| **Integrated GPU** | `Intel(R) UHD Graphics 730` (Rocket Lake GT1, Gen12 / Xe-LP architecture) | **PASS** |
| **PCI Identification** | Bus `0000:00:02.0`, Vendor `0x8086`, Device `0x4c8b`, Subsystem `0x1458:0xd000`, Rev `0x04` | **PASS** |

---

## 2. Intel UHD Graphics 730 (`0x8086:0x4c8b`) Vulkan & Reims vGPU Investigation

### 2.1 Physical Hardware Vulkan Measurements (`tahoeboot-gpu-check`)

Running [`tahoeboot-gpu-check`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/gpu/src/main.rs) directly against the physical `Intel(R) UHD Graphics 730` (`0x8086:0x4c8b`) produces the following measured report ([`gpu-report-physical-uhd730.txt`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/logs/gpu-report-physical-uhd730.txt)):

```text
TAHOEBOOT GPU REPORT

GPU: Intel(R) UHD Graphics 730 (0x8086:0x4c8b)
Driver: Intel Corporation (101.7092) [kernel: native]
Vulkan: 1.4.323
Device: Physical GPU (Integrated GPU)
External memory: PASS (VK_EXT_external_memory_host=true, DMA_BUF=false, minImportedHostPointerAlignment=4096 bytes)
Host memory mapping: PASS (Zero-copy host pointer import verified (64 KiB @ 0x2870000, memoryTypeBits=0x6, selectedType=1))
Vulkan compute test: PASS (64/64 compute invocations verified (out[0]=0x5441484f, out[63]=0x54414a08))
Vulkan graphics test: PASS (64x64 offscreen render pass & pixel readback verified (RGBA=[64, 128, 191, 255]))
Reims compatibility: PASS (All Reims vGPU & metal2vulkan Vulkan 1.3/1.4, host pointer import, compute, and graphics pipeline checks passed)
GPU selection: PASS (Selected physical Intel UHD Graphics 730 (0x8086:0x4c8b))
Guest acceleration: NOT TESTED
```

### 2.2 Linux Driver Stack (`i915` + Mesa `ANV` 26.0.8) & `metal2vulkan` Architecture Analysis

Inspection of the upstream [`reims-vgpu`](file:///c:/Users/User/Documents/Tahoe/upstream/reims-vgpu/crates/reims-vgpu-vulkan/src/os/linux/import.rs) and [`metal2vulkan`](file:///c:/Users/User/Documents/Tahoe/upstream/metal2vulkan/crates/metal2vulkan-runtime/src/driver_defects.rs) source code confirms how Intel Gen12 / Xe-LP (`UHD Graphics 730` / `UHD Graphics 770`) operates on Linux:

1. **Linux Kernel Driver**: `i915` (exposing `/dev/dri/card0` and `/dev/dri/renderD128`).
2. **Mesa Vulkan ICD**: `/usr/share/vulkan/icd.d/intel_icd.json` (`libvulkan_intel.so`, `VK_DRIVER_ID_INTEL_OPEN_SOURCE_MESA`, Mesa `26.0.8` / Vulkan `1.4.335`).
3. **Zero-Copy Guest RAM Import (`VK_EXT_external_memory_host` + `/dev/udmabuf`)**:
   - Intel `i915` userptr pins anonymous & `memfd` shared pages at `minImportedHostPointerAlignment = 4096` bytes (1 host page), but cannot pin `VM_PFNMAP` dma-buf mappings by pointer (`RuntimeDriverDefect::UnpinnablePagesBreakHostMemory`).
   - In [`crates/reims-vgpu-vulkan/src/os/linux/import.rs`](file:///c:/Users/User/Documents/Tahoe/upstream/reims-vgpu/crates/reims-vgpu-vulkan/src/os/linux/import.rs) and [`host_ram.rs`](file:///c:/Users/User/Documents/Tahoe/upstream/reims-vgpu/crates/reims-vgpu-vulkan/src/os/linux/host_ram.rs), `learn_view_imports` detects this during `rvg_device_create`, sets `IMPORTS_NEED_FILES = true`, and invokes `host_ram::device_needs_ram(device)`.
   - `host_ram.rs` hands QEMU's whole `memory-backend-memfd,share=on` guest RAM allocation (`rt::HostRam::new`) to `metal2vulkan-runtime`, which imports the guest RAM by host pointer in chunks via `VK_EXT_external_memory_host` and resolves guest `MTLBuffer` no-copy views as runs inside that imported RAM.
   - Meanwhile, [`crates/reims-vgpu-vulkan/src/os/linux/vm.rs`](file:///c:/Users/User/Documents/Tahoe/upstream/reims-vgpu/crates/reims-vgpu-vulkan/src/os/linux/vm.rs) uses `/dev/udmabuf` (`fold_idle`) to fold scattered idle guest pages into 4 MiB dma-bufs so VMA mappings stay well within `vm.max_map_count = 2097152`.
4. **Intel Xe-LP Hardware Workarounds Built into `metal2vulkan-runtime`**:
   - `RuntimeDriverDefect::ImageSizeShortOfCompressionData`: On Xe-LP (Rocket Lake GT1 / UHD 730), ANV places an auxiliary CCS compression control buffer at `size / 256` aligned to 4096 bytes. `metal2vulkan-runtime` automatically rounds image allocations up to whole 256-byte chunks.
   - `RuntimeDriverDefect::PushedDescriptorsStaleAfterPipelineBinds`: Automatically re-pushes descriptor writes after pipeline binds on ANV.
   - `RuntimeDriverDefect::OcclusionCountPerColorOutput`: Handled via `Degradation::VisibilityCountPerColor`, preserving full `MTLGPUFamilyMac2` and `MTLGPUFamilyMetal3` support for macOS Tahoe.

### 2.3 WSL2 vs. Bare-Metal Linux Boot Distinction

- **Inside WSL2 (`6.18.54.1-microsoft-standard-WSL2`)**: Microsoft's WSL2 kernel exposes `/dev/dxg` (`dxgkrnl`) instead of `i915`, lacks `CONFIG_UDMABUF`, and Ubuntu 26.04's `mesa-vulkan-drivers` only enumerates `llvmpipe` inside WSL2. As required by Section 3.2 & 3.4, [`tahoeboot-gpu-check`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/gpu/src/main.rs) **explicitly rejects `llvmpipe`** in strict appliance mode (`GPU selection: FAIL`).
- **On Bare-Metal Boot from `TahoeBoot.iso` (Ubuntu 26.04 LTS kernel `7.0.0-38-generic`)**: The kernel loads `i915`, `kvm_intel`, and `udmabuf`, exposing the physical `Intel(R) UHD Graphics 730 (RKL GT1)` (`0x8086:0x4c8b`) via `intel_icd.json` (`ANV`).
