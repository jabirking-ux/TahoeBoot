# TahoeBoot Installation, Build & Appliance Operation Guide

## 1. Overview & Architecture

**TahoeBoot** is a reproducible, bootable UEFI USB appliance (`TahoeBoot.iso`) that boots directly into a minimal Ubuntu 26.04 LTS x86-64 hypervisor and launches a fullscreen **macOS Tahoe (macOS 26)** virtual machine with genuine guest-side Metal GPU acceleration powered by **Reims vGPU** (`libreims_vgpu.so` + `ReimsVgpu.rom`) and **metal2vulkan** on the host's physical **Intel UHD Graphics 730 (`0x8086:0x4c8b`)**.

```
Physical Intel UHD 730 (PCI 0x8086:0x4c8b, Rocket Lake GT1 / Xe-LP)
        │
Linux i915 Kernel Driver + /dev/udmabuf + /dev/kvm (vm.max_map_count = 2097152)
        │
Mesa ANV Vulkan 1.4 Driver (/usr/share/vulkan/icd.d/intel_icd.json)
        │
Reims vGPU (libreims_vgpu.so) + metal2vulkan-runtime (VK_EXT_external_memory_host)
        │
Reims-patched QEMU (apple-gfx-pci, apple-gfx-iosurface-pci, apple-videotoolbox-pci, apple-m2scaler-pci)
        │
OpenCore 1.0.8 (Lilu.kext + ReimsVgpu.kext, ShowPicker = true)
        │
macOS Tahoe 26 Guest (AppleParavirtGPU.kext -> Metal 3 Framework -> Core Animation / WindowServer)
```

---

## 2. Repository Layout

```text
TahoeBoot/
├── TahoeBoot.iso                          # Bootable UEFI Hybrid ISO/USB Appliance Image
├── boot/
│   └── grub.cfg                           # Dual UEFI Boot Menu (Appliance Mode + Diagnostics Mode)
├── rootfs/
│   ├── tahoeboot.service                  # Systemd automatic startup unit
│   └── tahoeboot-session.sh               # Wayland fullscreen kiosk + pre-flight GPU verification
├── host/
│   ├── setup-host.sh                      # Configures sysctl, udev, kernel modules (kvm_intel, udmabuf, i915)
│   ├── 99-reims-vgpu.conf                 # Persistent vm.max_map_count = 2097152
│   └── 99-tahoeboot-kvm-udmabuf.rules     # Permissions for /dev/kvm, /dev/udmabuf, /dev/dri/renderD*
├── gpu/
│   ├── Cargo.toml                         # tahoeboot-gpu-check Rust crate manifest
│   └── src/
│       ├── main.rs                        # 13-step Intel UHD 730 + Vulkan + Reims verifier
│       ├── compute.comp / compute.spv     # SPIR-V compute verification shader
│       ├── render.vert / render.vert.spv  # SPIR-V offscreen vertex shader
│       ├── render.frag / render.frag.spv  # SPIR-V offscreen fragment shader
│       └── smoke_guest_linux.c            # C guest workload test over libreims_vgpu (FillBuffer 306)
├── reims/
│   ├── bin/                               # Compiled reims-ctl & reims-util binaries
│   ├── lib/                               # Compiled libreims_vgpu.so & libreims_vgpu.a
│   └── share/                             # Compiled ReimsVgpu.rom EFI GOP Option ROM
├── qemu/
│   ├── bin/                               # Compiled Reims-patched qemu-system-x86_64
│   ├── launch-vm.sh                       # Fullscreen borderless VM launcher for Intel UHD 730
│   └── set-resolution.sh                  # Resolution switcher (1920x1080, 2560x1440, 3840x2160)
├── opencore/
│   ├── build-opencore.sh                  # Builds opencore.qcow2 (OpenCore 1.0.8 + ReimsVgpu.kext) & OVMF
│   ├── tahoe-guest-setup.sh               # Guest post-install script (METAL_ERROR_MODE=5 & IORegistry check)
│   ├── opencore.qcow2                     # Generated OpenCore boot image (ShowPicker = true)
│   ├── OVMF_CODE.fd                       # UEFI firmware code
│   └── OVMF_VARS.fd                       # Persistent UEFI NVRAM variables
├── diagnostics/
│   └── tahoeboot-ui                       # Liquid Glass splash, diagnostics screen & 12 error state panels
├── scripts/
│   ├── build-iso.sh                       # Reproducible bootable UEFI ISO builder
│   ├── verify-iso.sh                      # ISO 9660 / El Torito / SquashFS verifier
│   ├── create-usb.sh                      # Safe removable USB flasher (protects internal Windows disks)
│   ├── select-storage.sh                  # UUID/LABEL external SSD selector
│   ├── vm-storage-mgr.sh                  # Snapshot, backup & NVRAM management utility
│   └── run-test-suite.sh                  # End-to-end automated verification suite (Tests A–E)
├── logs/                                  # Hardware, GPU, smoke test, and ISO verification logs
└── docs/                                  # Complete documentation & reports
```

---

## 3. Preparing External Persistent Storage & Writing the Bootable USB

### Step 1: Prepare External Persistent SSD (`LABEL=TAHOE_VM`)
**TahoeBoot never auto-formats or runs `mkfs` on any disk or partition.** Prepare a partition on your external SSD labeled `TAHOE_VM` yourself (never touch internal Windows NTFS/BitLocker drives), and initialize the persistent macOS Tahoe directory structure:
```bash
TahoeBoot/scripts/vm-storage-mgr.sh init
TahoeBoot/opencore/build-opencore.sh
```
This creates a sparse `disk.qcow2` file inside the mounted directory (attached on ICH9 AHCI SATA port `sata.3` so macOS Tahoe Disk Utility detects it immediately during installation).
To download the official macOS Tahoe recovery image directly from Apple's software distribution servers into `VMStorage/macos-tahoe/recovery.dmg`, run:
```bash
TahoeBoot/reims/bin/reims-util recovery --os tahoe -o VMStorage/macos-tahoe/recovery.dmg
```

### Step 2: Flash `TahoeBoot.iso` to a USB Drive
Use [`create-usb.sh`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/scripts/create-usb.sh), which strictly verifies that the target device has `RM=1` and `TRAN=usb` and contains no Windows BitLocker partitions:
```bash
sudo TahoeBoot/scripts/create-usb.sh /dev/disk/by-id/usb-<your-usb-drive>
```

### Step 3: Booting into TahoeBoot & First-Time Guest Setup
1. Turn on the Gigabyte `B560M DS3H V2` system and press `F12` to select the **TahoeBoot** UEFI USB entry.
2. Select **`1. TahoeBoot Appliance — Launch macOS Tahoe (Reims vGPU Accelerated)`**.
3. TahoeBoot automatically loads `i915`, `kvm_intel`, and `udmabuf`, verifies the physical `Intel(R) UHD Graphics 730` (`0x8086:0x4c8b`) via `tahoeboot-gpu-check`, and starts the fullscreen borderless VM.
4. At the **OpenCore 1.0.8** boot picker, select **macOS Tahoe**.
5. Inside macOS Tahoe, run [`tahoe-guest-setup.sh`](file:///c:/Users/User/Documents/Tahoe/TahoeBoot/opencore/tahoe-guest-setup.sh) once to set `METAL_ERROR_MODE = 5` in `/Library/Preferences/.GlobalPreferences.plist` and verify `AppleParavirtGPU` + Metal 3 hardware acceleration.
