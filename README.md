# TahoeBoot

Bootable UEFI USB appliance that starts a minimal Ubuntu 26.04 Linux hypervisor and boots a fullscreen **macOS Tahoe (macOS 26)** virtual machine with hardware GPU acceleration through **Reims vGPU** (`apple-gfx-pci`) and **metal2vulkan** on an Intel Rocket Lake host.

No Windows background services, no VirtIO-GPU software fallback, and no modifications to the internal Windows drive. You plug in the USB stick and an external SSD (`LABEL=TAHOE_VM`), select `TahoeBoot` in the motherboard UEFI boot menu, and boot straight into OpenCore 1.0.8 and macOS Tahoe.

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
  - **VM Disk**: Separate external USB 3.2 / NVMe SSD formatted `ext4` or `exfat` with filesystem label `TAHOE_VM` (holding `opencore.qcow2`, `OVMF_CODE.fd`, `OVMF_VARS.fd`, and the 128 GiB `disk.qcow2`)

Hardware is probed at boot. If the GPU check tool (`tahoeboot-gpu-check`) sees a software rasterizer (`llvmpipe`, `lavapipe`, `swiftshader`) or a GPU missing `VK_EXT_external_memory_host`, it aborts startup and prints the exact failing check rather than silently dropping to unaccelerated graphics.

---

## How the Graphics Pipeline Works

macOS does not have drivers for Intel Gen12 integrated graphics (`0x8086:0x4c8b`). Instead of PCIe passthrough of an unsupported iGPU, TahoeBoot runs the upstream **Reims vGPU** stack:

```text
Physical Intel UHD Graphics 730 (0x8086:0x4c8b)
  └─ Linux i915 / DRM renderD128 + /dev/udmabuf
      └─ Mesa ANV Vulkan 1.4 driver + intel-media-va-driver (VA-API)
          └─ metal2vulkan (Apple AIR / metallib -> SPIR-V & Vulkan runtime)
              └─ libreims_vgpu (Reims vGPU host runtime)
                  └─ Patched QEMU 11.1.50 (q35 + memory-backend-memfd,share=on)
                      ├─ apple-gfx-pci           (106b:eeee, ReimsVgpu.rom GOP)
                      ├─ apple-gfx-iosurface-pci (106b:eeef, zero-copy IOSurface mapper)
                      ├─ apple-videotoolbox-pci  (106b:1a03, VA-API H.264/HEVC/VP9/JPEG)
                      └─ apple-m2scaler-pci      (106b:1a0b, M2 display scaler)
                          └─ OpenCore 1.0.8 + ReimsVgpu.kext (Lilu + WhateverGreen)
                              └─ macOS 26 AppleParavirtGPU -> Metal.framework
```

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
│   │   ├── launch-vm.sh                  # Starts Reims-patched QEMU with all 4 apple-* PCI devices
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
│       ├── select-storage.sh             # Mounts VM disk by UUID or LABEL=TAHOE_VM (blocks NTFS/BitLocker)
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

Use [`create-usb.sh`](TahoeBoot/scripts/create-usb.sh) on Linux (it checks `lsblk` transport/removable flags and refuses to write to any disk containing Windows NTFS or BitLocker partitions), or flash `TahoeBoot.iso` with Rufus (DD mode) / BalenaEtcher on Windows:

```bash
sudo ./TahoeBoot/scripts/create-usb.sh /dev/sdX TahoeBoot/TahoeBoot.iso
```

### 3. Prepare the Persistent External SSD (`LABEL=TAHOE_VM`)

Format a dedicated external SSD partition with label `TAHOE_VM` (`mkfs.ext4 -L TAHOE_VM /dev/sdY1`) and initialize the VM directory:

```bash
mkdir -p /mnt/tahoe-storage/macos-tahoe/{configuration,logs,backups}
cp TahoeBoot/opencore/{opencore.qcow2,OVMF_CODE.fd,OVMF_VARS.fd} /mnt/tahoe-storage/macos-tahoe/
qemu-img create -f qcow2 /mnt/tahoe-storage/macos-tahoe/disk.qcow2 128G
```

To install macOS Tahoe for the first time, fetch the Apple recovery image with `reims-util` (or `reims-ctl create`) and place `recovery.dmg` inside `/mnt/tahoe-storage/macos-tahoe/recovery.dmg`:

```bash
reims-util installer --version 26 -o /mnt/tahoe-storage/macos-tahoe/recovery.dmg
```

### 4. Boot the Appliance

1. Reboot your PC and press **F12** (Gigabyte B560M boot menu).
2. Select your UEFI USB drive (`TahoeBoot`).
3. GRUB offers two boot modes:
   - **`1. TahoeBoot Appliance — Launch macOS Tahoe (Reims vGPU Accelerated)`** (default)
   - **`2. TahoeBoot Maintenance & GPU Diagnostics Mode (tahoeboot-gpu-check)`**
4. In Appliance mode, TahoeBoot configures `vm.max_map_count=2097152`, loads `kvm_intel`, `udmabuf`, and `i915`, runs `tahoeboot-gpu-check`, and starts QEMU fullscreen in OpenCore 1.0.8.

---

## Automated Verification Suite

Run all 18 hardware, Vulkan, Reims vGPU guest protocol, and ISO structure checks with:

```bash
./TahoeBoot/scripts/run-test-suite.sh
```

---

## Credits & Open-Source Projects Used

TahoeBoot is an integration appliance built on top of the hard work of several open-source projects and maintainers:

### Core Virtual GPU & Metal-to-Vulkan Translation
- **[Reims vGPU (`reims-vgpu`)](https://github.com/steelbrain/reims-vgpu)** by **Anees Iqbal ([@steelbrain](https://github.com/steelbrain))** — The core virtual Apple GPU (`apple-gfx-pci`), IOSurface mapper (`apple-gfx-iosurface-pci`), VideoToolbox hardware video bridge (`apple-videotoolbox-pci`), M2 display scaler (`apple-m2scaler-pci`), EFI GOP Option ROM (`ReimsVgpu.rom`), `ReimsVgpu.kext`, and `reims-ctl` VM manager. Documentation at [reims-vgpu.com](https://reims-vgpu.com/).
- **[metal2vulkan](https://github.com/steelbrain/metal2vulkan)** by **Anees Iqbal ([@steelbrain](https://github.com/steelbrain))** — Translates Apple Metal shaders (AIR / `.metallib` bitcode) into Vulkan SPIR-V and executes Metal API calls, command buffers, argument buffers, and host-imported memory ranges on Linux Vulkan drivers.
- **[reims-util](https://github.com/steelbrain/reims-util)** by **Anees Iqbal ([@steelbrain](https://github.com/steelbrain))** — Builds the `opencore.qcow2` boot disk (packaging OpenCore, `Lilu.kext`, `WhateverGreen.kext`, and `ReimsVgpu.kext`), extracts `OVMF_CODE.fd` / `OVMF_VARS.fd`, and downloads chunklist-verified macOS recovery images directly from Apple's software update catalog.

### Hypervisor, Bootloader & Firmware
- **[QEMU](https://www.qemu.org/)** ([Reims-patched fork](https://github.com/steelbrain/qemu)) — Q35 machine emulation, KVM hardware virtualization, `memory-backend-memfd`, and the `hw/display/apple-gfx*` PCIe device models.
- **[OpenCorePkg](https://github.com/acidanthera/OpenCorePkg)**, **[Lilu](https://github.com/acidanthera/Lilu)**, and **[WhateverGreen](https://github.com/acidanthera/WhateverGreen)** by **[Acidanthera](https://github.com/acidanthera)** — UEFI bootloader and kernel extension patching framework used to boot macOS Tahoe in a virtual machine and load `ReimsVgpu.kext`.
- **[TianoCore EDK II / OVMF](https://github.com/tianocore/edk2)** — Open-source UEFI firmware (`OVMF_CODE.fd` and `OVMF_VARS.fd`) for QEMU virtual machines.
- **[Linux Kernel](https://www.kernel.org/)** (Ubuntu 26.04 `linux-image-generic`) — Provides `kvm_intel` hardware virtualization, `i915` DRM graphics driver for Intel Rocket Lake, and `/dev/udmabuf` zero-copy scatter-gather guest page buffers.

### Host Graphics, Display & Appliance Stack
- **[Mesa 3D (`anv` Intel Vulkan driver)](https://www.mesa3d.org/)** — Vulkan 1.4 implementation for Intel Gen12 / UHD Graphics 730, providing `VK_EXT_external_memory_host` and `VK_EXT_external_memory_dma_buf`.
- **[intel-media-driver (`iHD`) & libva](https://github.com/intel/media-driver)** — Hardware VA-API video decode/encode driver for Intel Gen12 GPUs, used by `reims-vgpu-video-vaapi` to accelerate `apple-videotoolbox-pci`.
- **[ash](https://github.com/ash-rs/ash)** — Rust Vulkan bindings used both by `reims-vgpu`/`metal2vulkan` and by `tahoeboot-gpu-check`.
- **[SDL3 (`libsdl-org/SDL`)](https://github.com/libsdl-org/SDL)** — Windowing and direct KMS/DRM / Wayland Vulkan surface presentation used by `reims-vgpu-window`.
- **[GNU GRUB](https://www.gnu.org/software/grub/)**, **[GNU xorriso](https://www.gnu.org/software/xorriso/)**, **[squashfs-tools](https://github.com/plougher/squashfs-tools)**, and **[BusyBox](https://busybox.net/)** — Used to assemble the hybrid UEFI bootable ISO (`TahoeBoot.iso`) and initramfs.

### Related Open-Source Projects & Companion Tools
If you are customizing or extending TahoeBoot, these open-source projects integrate directly with this stack:
- **[Cage (`cage-kiosk/cage`)](https://github.com/cage-kiosk/cage)** & **[Weston](https://gitlab.freedesktop.org/wayland/weston)** — Single-application Wayland kiosk compositors supported out-of-the-box by [`tahoeboot-session.sh`](TahoeBoot/rootfs/tahoeboot-session.sh) (`cage -s -- launch-vm.sh`).
- **[OC4VM (`antecedent/OC4VM`)](https://github.com/antecedent/OC4VM)** & **[Quickemu (`quickemu-project/quickemu`)](https://github.com/quickemu-project/quickemu)** — Reference configurations for macOS QEMU topology, SMBIOS, and AppleSMC OSK handling.
- **[ Looking Glass / Scream / PipeWire](https://pipewire.org/)** — Low-latency audio routing (`pipewire` is started automatically by `tahoeboot-session.sh` when present).
- **[corpnewt/ProperTree](https://github.com/corpnewt/ProperTree)** & **[ic005k/OCAuxiliaryTools](https://github.com/ic005k/OCAuxiliaryTools)** — Plist editors and OpenCore config validators if you want to customize `opencore.qcow2` boot arguments (`-v`, `keepsyms=1`, or custom SMBIOS data).

---

## License

TahoeBoot is dual-licensed under your choice of:

- **GNU General Public License v2.0 or later** ([`LICENSES/GPL-2.0-or-later.txt`](LICENSES/GPL-2.0-or-later.txt))
- **GNU Lesser General Public License v3.0 or later** ([`LICENSES/LGPL-3.0-or-later.txt`](LICENSES/LGPL-3.0-or-later.txt), supplementing [`LICENSES/GPL-3.0-or-later.txt`](LICENSES/GPL-3.0-or-later.txt))

SPDX-License-Identifier: `GPL-2.0-or-later OR LGPL-3.0-or-later`

See [`LICENSE`](LICENSE) for full details and third-party component license notices.
