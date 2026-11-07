# TahoeBoot

Bootable UEFI USB appliance that starts a minimal Ubuntu 26.04 Linux hypervisor and boots a fullscreen **macOS Tahoe (macOS 26)** virtual machine with hardware GPU acceleration through **Reims vGPU** (`apple-gfx-pci` / `apple-gfx-mmio`) and **metal2vulkan** on an Intel Rocket Lake host.

No Windows background services, no VirtIO-GPU software fallback, and **strictly zero auto-formatting of any host disk or partition**. You plug in the USB stick and an external SSD (`LABEL=TAHOE_VM`), select `TahoeBoot` in the motherboard UEFI boot menu, and boot straight into OpenCore 1.0.8 and macOS Tahoe.

[![License: GPL-2.0-or-later OR LGPL-3.0-or-later](https://img.shields.io/badge/license-GPL--2.0--or--later%20OR%20LGPL--3.0--or--later-blue.svg)](LICENSE)
[![Build & Release TahoeBoot ISO](https://github.com/jabirking-ux/TahoeBoot/actions/workflows/release-iso.yml/badge.svg)](https://github.com/jabirking-ux/TahoeBoot/actions/workflows/release-iso.yml)

---

## Target Hardware

Built and tested against:

- **CPU**: Intel Core i5-11400 (6C/12T, Rocket Lake, VT-x / EPT)
- **GPU**: Intel UHD Graphics 730 (`PCI 0x8086:0x4c8b`, RocketLake-S GT1)
- **Motherboard**: Gigabyte B560M DS3H V2 (UEFI boot, VT-d / IOMMU enabled)
- **Memory**: 16 GB DDR4 (8 GB allocated to guest via `memory-backend-memfd,share=on`, 8 GB retained for host/ANV shader cache & `udmabuf`)
- **Storage**:
  - **Boot USB**: `TahoeBoot.iso` flashed to any >= 4 GB USB drive
  - **VM Disk (Full Drive Capacity, Zero Auto-Formatting)**: Separate external USB 3.2 / NVMe SSD (`LABEL=TAHOE_VM` or raw GPT partition `PARTLABEL=TAHOE_RAW`). TahoeBoot **never** runs `mkfs` or formats any partition automatically. On boot, [`select-storage.sh`](TahoeBoot/scripts/select-storage.sh) mounts your existing `LABEL=TAHOE_VM` volume, queries its usable capacity (`df -B1 --output=size,avail`), and creates or expands the sparse virtual image `disk.qcow2` to span the **entire capacity of the drive** (leaving 2 GiB for `opencore.qcow2`, `OVMF_VARS.fd`, and logs).
  - **Installer Disk Detection (`sata.3` AHCI)**: By default, [`launch-vm.sh`](TahoeBoot/qemu/launch-vm.sh) attaches `disk.qcow2` to ICH9 AHCI SATA port 3 (`-device ide-hd,bus=sata.3,drive=disk,rotation_rate=1`), matching upstream `reims-ctl` (`DiskController::Ahci`), because macOS 26 Tahoe's recovery installer does not enumerate generic QEMU NVMe controllers during initial setup. Inside macOS Recovery -> **Disk Utility**, select **`QEMU HARDDISK Media`** (~440 GB / 410 GiB) and click **Erase** (APFS, GUID Partition Map) when you are ready to install.

Hardware is probed at boot. On bare metal, if the GPU check tool (`tahoeboot-gpu-check`) sees a software rasterizer (`llvmpipe`, `lavapipe`, `swiftshader`) or a GPU missing `VK_EXT_external_memory_host`, it aborts startup and prints the exact failing check rather than silently dropping to unaccelerated graphics.

---

## How the Graphics Pipeline & Apple Silicon Paravirtualization Work

macOS does not have drivers for Intel Gen12 integrated graphics (`0x8086:0x4c8b`). Instead of PCIe passthrough of an unsupported iGPU, TahoeBoot runs the upstream **Reims vGPU** stack, which exposes Apple's own paravirtualized Silicon devices (`apple-gfx`, `apple-gfx-iosurface`, `apple-videotoolbox`, and `apple-m2scaler`) to the guest:

```text
Physical Intel UHD Graphics 730 (0x8086:0x4c8b)
  └─ Linux i915 / DRM renderD128 + /dev/udmabuf
      └─ Mesa ANV Vulkan 1.4 driver + intel-media-va-driver (VA-API)
          └─ metal2vulkan (Apple AIR / metallib -> SPIR-V & Vulkan runtime)
              └─ libreims_vgpu (Reims vGPU host runtime)
                  └─ Patched QEMU 11.1.50 (q35 KVM or vmapple ARM64)
                      ├─ apple-gfx-pci / mmio    (106b:eeee, ReimsVgpu.rom GOP)
                      ├─ apple-gfx-iosurface-pci (106b:eeef, zero-copy IOSurface mapper)
                      ├─ apple-videotoolbox-pci  (106b:1a03, VA-API H.264/HEVC/VP9/JPEG)
                      └─ apple-m2scaler-pci      (106b:1a0b, M2 display scaler)
                          └─ OpenCore 1.0.8 + ReimsVgpu.kext (Lilu + WhateverGreen)
                              └─ macOS 26 AppleParavirtGPU -> Metal.framework
```

### Native KVM (`q35` + `apple-gfx-pci`) vs. Full Apple Silicon Emulation (`vmapple` `aarch64`)

TahoeBoot includes two launchers in [`TahoeBoot/qemu/`](TahoeBoot/qemu/):

1. **[`TahoeBoot/qemu/launch-vm.sh`](TahoeBoot/qemu/launch-vm.sh) (Default — Recommended for Intel Core i5-11400)**:
   - Runs `qemu-system-x86_64 -accel kvm` (`Skylake-Client-noTSX-IBRS,kvm=on,vmx=on`, 6 vCPUs, 8 GiB `memfd` RAM) at **near-native Rocket Lake hardware CPU speed** while paravirtualizing the **Apple Silicon GPU, IOSurface mapper, VideoToolbox engine, and M2 display scaler** (`apple-gfx-pci`, `apple-gfx-iosurface-pci`, `apple-videotoolbox-pci`, `apple-m2scaler-pci`) via `ReimsVgpu.kext`.
   - When launched inside WSL2 on Windows, [`launch-vm.sh`](TahoeBoot/qemu/launch-vm.sh) automatically caches active VM images onto native Linux `ext4` (`/root/tahoe-vm-fast`) to bypass WSL2's slow `/mnt/c` 9P filesystem bottleneck and avoids running heavy M2 scaler compute shaders on CPU `llvmpipe`.
2. **[`TahoeBoot/qemu/launch-apple-silicon.sh`](TahoeBoot/qemu/launch-apple-silicon.sh) (`vmapple` ARM64 Machine Emulation)**:
   - Emulates an Apple Silicon `arm64` Mac (`-M vmapple`, `apple-gfx-mmio`, `vmapple-virtio-blk-pci`, `apple-videotoolbox-pci`, `apple-m2scaler-pci`), drawing on upstream `reims-vgpu` (`hw/vmapple/vmapple.c`) and **[ChefKissInc/QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)**.
   - *Note*: Because the host CPU is an x86-64 Intel Core i5-11400, running `qemu-system-aarch64` requires multi-threaded TCG software instruction translation (`-accel tcg,thread=multi`), whereas `launch-vm.sh` executes natively on KVM hardware virtualization.

### Verified Measurements on Physical Intel UHD 730 (`0x8086:0x4c8b`)

Before building the appliance image, we wrote [`tahoeboot-gpu-check`](TahoeBoot/gpu/src/main.rs) and [`smoke_guest_linux`](TahoeBoot/gpu/src/smoke_guest_linux.c) to test the physical GPU and the Reims vGPU C API directly:

| Layer | Check | Result |
| :--- | :--- | :--- |
| **PCI / Driver** | `0x8086:0x4c8b` (`INTEGRATED_GPU`), Vulkan `1.4.323` | `PASS` ([`gpu-report-physical-uhd730.txt`](TahoeBoot/logs/gpu-report-physical-uhd730.txt)) |
| **Host Memory Import** | `VK_EXT_external_memory_host` (`minImportedHostPointerAlignment = 4096`) + 64 KiB zero-copy page-aligned host import | `PASS` |
| **Vulkan Compute** | SPIR-V compute shader (`f(i) = (i * 7) ^ 0xA5A50000` + `0x11111111`, 64/64 words verified) | `PASS` |
| **Vulkan Graphics** | 64×64 `R8G8B8A8_UNORM` offscreen render pass + pixel readback (`[31, 199, 107, 255]`) | `PASS` |
| **Reims vGPU Protocol** | `smoke_guest_linux`: `rvg_device_create`, MMIO v245, Root FIFO, Task 1 handshake, `MapMemory2`, `ObjectList`, `OP_EXEC_INDIRECT3` (`FillBuffer` 306) | `PASS` ([`smoke-guest-linux.log`](TahoeBoot/logs/smoke-guest-linux.log)) |
| **Live UEFI ISO Boot** | OVMF -> GRUB 2.14 -> Linux `7.0.0-43-generic` -> `/init` appliance startup | `PASS` ([`live-iso-boot.log`](TahoeBoot/logs/live-iso-boot.log)) |
| **Live OpenCore + Reims Boot** | QEMU `q35` + `apple-gfx-pci` + `ReimsVgpu.rom` -> 1920×1080 BGRA8 GOP import -> OpenCore 1.0.8 disk boot | `PASS` ([`live-opencore-reims-boot.log`](TahoeBoot/logs/live-opencore-reims-boot.log)) |

---

## Repository Layout

```text
.
├── TahoeBoot/
│   ├── boot/
│   │   └── grub.cfg                      # Dual-entry UEFI GRUB menu (Appliance + Diagnostics)
│   ├── diagnostics/
│   │   └── tahoeboot-ui                  # Boot splash, diagnostics TUI, and 12 explicit error codes
│   ├── docs/
│   │   ├── HARDWARE_AND_GPU_REPORT.md    # UHD 730 Vulkan & Reims vGPU measurements
│   │   ├── INSTALLATION_GUIDE.md         # Step-by-step USB + external SSD setup
│   │   └── TROUBLESHOOTING_AND_RECOVERY.md
│   ├── gpu/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs                   # tahoeboot-gpu-check (Vulkan 1.4, host import, compute, render)
│   │       ├── smoke_guest_linux.c       # Guest-side Reims vGPU MMIO & FillBuffer (306) verifier
│   │       ├── compute.comp              # GLSL compute test shader (+ compiled .spv)
│   │       ├── render.vert               # GLSL vertex test shader (+ compiled .spv)
│   │       └── render.frag               # GLSL fragment test shader (+ compiled .spv)
│   ├── host/
│   │   ├── 99-reims-vgpu.conf            # sysctl vm.max_map_count = 2097152
│   │   ├── 99-tahoeboot-kvm-udmabuf.rules# udev permissions for /dev/kvm, /dev/udmabuf, /dev/dri
│   │   └── setup-host.sh                 # Kernel module loader (kvm_intel, udmabuf, i915) & rlimits
│   ├── logs/                             # Recorded hardware, guest smoke test, and live boot logs
│   ├── opencore/
│   │   ├── build-opencore.sh             # Generates OpenCore 1.0.8 + ReimsVgpu.kext via reims-util
│   │   ├── tahoe-guest-setup.sh          # In-guest macOS Tahoe Metal & AppleParavirtGPU verifier
│   │   ├── opencore.qcow2                # Pre-built OpenCore 1.0.8 boot image
│   │   ├── OVMF_CODE.fd                  # Pre-built UEFI firmware code
│   │   └── OVMF_VARS.fd                  # Pre-built UEFI NVRAM variables
│   ├── qemu/
│   │   ├── launch-vm.sh                  # Fast KVM + Reims vGPU launcher (SATA AHCI port 3 + ext4 cache)
│   │   ├── launch-apple-silicon.sh       # Apple Silicon (vmapple / aarch64) emulation launcher
│   │   └── set-resolution.sh             # Updates guest GOP resolution (1920x1080, 2560x1440, etc.)
│   ├── reims/
│   │   ├── include/reims_vgpu.h          # Reims vGPU C API header
│   │   ├── pkgconfig/reims-vgpu.pc
│   │   └── share/ReimsVgpu.rom           # Compiled EFI GOP Option ROM for apple-gfx-pci
│   ├── rootfs/
│   │   ├── tahoeboot-session.sh          # Kiosk session wrapper (Cage / Weston / SDL3 KMSDRM)
│   │   └── tahoeboot.service             # systemd unit for automatic appliance boot
│   └── scripts/
│       ├── build-iso.sh                  # Builds TahoeBoot.iso (GRUB UEFI + kernel + SquashFS)
│       ├── verify-iso.sh                 # Verifies El Torito UEFI catalog, SquashFS, and payloads
│       ├── create-usb.sh                 # Flashes TahoeBoot.iso to removable USB (blocks internal disks)
│       ├── select-storage.sh             # Mounts VM disk by UUID or LABEL=TAHOE_VM (never auto-formats)
│       ├── vm-storage-mgr.sh             # Snapshot, backup, and qcow2 integrity manager
│       └── run-test-suite.sh             # 18-check automated test suite (Tests A through E)
└── .github/workflows/
    └── release-iso.yml                   # GitHub Actions CI that builds & attaches TahoeBoot.iso to Releases
```

---

## Quick Start

### 1. Download or Build `TahoeBoot.iso`

Download `TahoeBoot.iso` (and `TahoeBoot.iso.sha256`) from the [**Releases**](https://github.com/jabirking-ux/TahoeBoot/releases) page, or build it from source on Ubuntu 24.04 / 26.04:

```bash
./TahoeBoot/scripts/build-iso.sh
./TahoeBoot/scripts/verify-iso.sh TahoeBoot/TahoeBoot.iso
```

### 2. Flash the Bootable USB

Use [`create-usb.sh`](TahoeBoot/scripts/create-usb.sh) on Linux (it checks `lsblk` transport/removable flags, refuses internal drives, and requires interactive confirmation), or flash `TahoeBoot.iso` with Rufus (DD mode) / BalenaEtcher on Windows:

```bash
sudo ./TahoeBoot/scripts/create-usb.sh /dev/disk/by-id/usb-<your-usb-drive>
```

### 3. Connect Your Persistent External SSD (`LABEL=TAHOE_VM`)

TahoeBoot **never** formats any drive or partition automatically. Label an existing partition on your external SSD `TAHOE_VM` (for example with `e2label /dev/sdY1 TAHOE_VM` or via your disk manager).

On boot (or when you run `./TahoeBoot/scripts/vm-storage-mgr.sh init`), TahoeBoot inspects the drive's available space and creates or expands a sparse `disk.qcow2` virtual disk file spanning the **entire drive capacity**, attached on SATA port `sata.3` (`QEMU HARDDISK Media`).

To fetch the official Apple macOS Tahoe recovery image:

```bash
reims-util online-installer tahoe --output VMStorage/macos-tahoe/macOS-Tahoe-online-installer.dmg
```

[`launch-vm.sh`](TahoeBoot/qemu/launch-vm.sh) automatically converts the compressed UDIF `.dmg` into a raw bootable `installer.img` on first launch so OpenCore's HFS+ driver displays **macOS Base System / Install macOS Tahoe** in the boot picker. Inside macOS Recovery, open **Disk Utility**, select **`QEMU HARDDISK Media`**, erase it as **APFS (GUID Partition Map)** if installing onto a blank virtual disk for the first time, and run **Install macOS Tahoe**.

---

## Automated Verification Suite

Run all 18 hardware, Vulkan, Reims vGPU guest protocol, and ISO structure checks with:

```bash
./TahoeBoot/scripts/run-test-suite.sh
```

---

## Credits & Open-Source Projects Used

TahoeBoot is built on top of the work of the following open-source projects and maintainers:

### Core Virtual GPU & Metal-to-Vulkan Translation
- **[Reims vGPU (`steelbrain/reims-vgpu`)](https://github.com/steelbrain/reims-vgpu)** by **Anees Iqbal ([@steelbrain](https://github.com/steelbrain))** — The core virtual Apple GPU (`apple-gfx-pci` & `apple-gfx-mmio`), IOSurface mapper (`apple-gfx-iosurface-pci`), VideoToolbox hardware video bridge (`apple-videotoolbox-pci`), M2 display scaler (`apple-m2scaler-pci`), EFI GOP Option ROM (`ReimsVgpu.rom`), `ReimsVgpu.kext`, and `reims-ctl` VM manager. Documentation at [reims-vgpu.com](https://reims-vgpu.com/).
- **[metal2vulkan (`steelbrain/metal2vulkan`)](https://github.com/steelbrain/metal2vulkan)** by **Anees Iqbal ([@steelbrain](https://github.com/steelbrain))** — Translates Apple Metal shaders (AIR / `.metallib` bitcode) into Vulkan SPIR-V and executes Metal API calls, command buffers, argument buffers, and host-imported memory ranges on Linux Vulkan drivers.
- **[reims-util (`steelbrain/reims-util`)](https://github.com/steelbrain/reims-util)** by **Anees Iqbal ([@steelbrain](https://github.com/steelbrain))** — Builds the `opencore.qcow2` boot disk (packaging OpenCore, `Lilu.kext`, `WhateverGreen.kext`, and `ReimsVgpu.kext`), extracts `OVMF_CODE.fd` / `OVMF_VARS.fd`, and downloads chunklist-verified macOS recovery images directly from Apple's software update catalog.

### Apple Silicon Emulation, Hypervisor, Bootloader & Firmware
- **[QEMU (`qemu/qemu`)](https://www.qemu.org/)** ([Reims-patched fork](https://github.com/steelbrain/qemu), including **`vmapple`** patches by **Alexander Graf**, **Phil Dennis-Jordan**, **Mohamed Mediouni**, and **Jesus Martínez**) — Q35 x86-64 KVM hardware virtualization, `vmapple` ARM64 machine emulation, `memory-backend-memfd`, and the `hw/display/apple-gfx*` PCIe/MMIO device models.
- **[ChefKiss Inferno / QEMUAppleSilicon (`ChefKissInc/QEMUAppleSilicon`)](https://github.com/ChefKissInc/QEMUAppleSilicon)** by **[ChefKissInc](https://github.com/ChefKissInc)** — Open-source Apple ARM64 SoC and device guest emulation on top of QEMU (`upstream/QEMUAppleSilicon`).
- **[OpenCorePkg (`acidanthera/OpenCorePkg`)](https://github.com/acidanthera/OpenCorePkg)**, **[Lilu (`acidanthera/Lilu`)](https://github.com/acidanthera/Lilu)**, and **[WhateverGreen (`acidanthera/WhateverGreen`)](https://github.com/acidanthera/WhateverGreen)** by **[Acidanthera](https://github.com/acidanthera)** — UEFI bootloader and kernel extension patching framework used to boot macOS Tahoe in a virtual machine and load `ReimsVgpu.kext` (`upstream/OpenCorePkg`).
- **[OSX-KVM (`kholia/OSX-KVM`)](https://github.com/kholia/OSX-KVM)** by **Dhiru Kholia ([@kholia](https://github.com/kholia))** — KVM CPU MSR, Skylake/Rocket Lake CPUID flags, and QEMU Q35 tuning reference for macOS guests on Linux KVM (`upstream/OSX-KVM`).
- **[OC4VM (`antecedent/OC4VM`)](https://github.com/antecedent/OC4VM)** and **[Quickemu (`quickemu-project/quickemu`)](https://github.com/quickemu-project/quickemu)** — Reference configurations for macOS QEMU topology, SMBIOS, and AppleSMC OSK handling (`upstream/OC4VM`, `upstream/quickemu`).
- **[TianoCore EDK II / OVMF (`tianocore/edk2`)](https://github.com/tianocore/edk2)** — Open-source UEFI firmware (`OVMF_CODE.fd` and `OVMF_VARS.fd`) for QEMU virtual machines.
- **[Linux Kernel](https://www.kernel.org/)** (Ubuntu 26.04 `linux-image-generic`) — Provides `kvm_intel` hardware virtualization, `i915` DRM graphics driver for Intel Rocket Lake, and `/dev/udmabuf` zero-copy scatter-gather guest page buffers.

### Host Graphics, Display & Appliance Stack
- **[Mesa 3D (`anv` Intel Vulkan driver)](https://www.mesa3d.org/)** — Vulkan 1.4 implementation for Intel Gen12 / UHD Graphics 730, providing `VK_EXT_external_memory_host` and `VK_EXT_external_memory_dma_buf`.
- **[intel-media-driver (`iHD`) & libva](https://github.com/intel/media-driver)** — Hardware VA-API video decode/encode driver for Intel Gen12 GPUs, used by `reims-vgpu-video-vaapi` to accelerate `apple-videotoolbox-pci`.
- **[ash (`ash-rs/ash`)](https://github.com/ash-rs/ash)** — Rust Vulkan bindings used both by `reims-vgpu`/`metal2vulkan` and by `tahoeboot-gpu-check`.
- **[SDL3 (`libsdl-org/SDL`)](https://github.com/libsdl-org/SDL)** — Windowing and direct KMS/DRM / Wayland Vulkan surface presentation used by `reims-vgpu-window`.
- **[GNU GRUB](https://www.gnu.org/software/grub/)**, **[GNU xorriso](https://www.gnu.org/software/xorriso/)**, **[squashfs-tools](https://github.com/plougher/squashfs-tools)**, and **[BusyBox](https://busybox.net/)** — Used to assemble the hybrid UEFI bootable ISO (`TahoeBoot.iso`) and initramfs.
- **[Cage (`cage-kiosk/cage`)](https://github.com/cage-kiosk/cage)**, **[Weston](https://gitlab.freedesktop.org/wayland/weston)**, and **[PipeWire](https://pipewire.org/)** — Wayland kiosk compositors and low-latency audio routing supported by [`tahoeboot-session.sh`](TahoeBoot/rootfs/tahoeboot-session.sh).

---

## License

TahoeBoot is dual-licensed under your choice of:

- **GNU General Public License v2.0 or later** ([`LICENSES/GPL-2.0-or-later.txt`](LICENSES/GPL-2.0-or-later.txt))
- **GNU Lesser General Public License v3.0 or later** ([`LICENSES/LGPL-3.0-or-later.txt`](LICENSES/LGPL-3.0-or-later.txt), supplementing [`LICENSES/GPL-3.0-or-later.txt`](LICENSES/GPL-3.0-or-later.txt))

SPDX-License-Identifier: `GPL-2.0-or-later OR LGPL-3.0-or-later`

See [`LICENSE`](LICENSE) for full details and third-party component license notices.
