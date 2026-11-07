# TahoeBoot (`TahoeBoot/` Directory Reference)

See the top-level [`README.md`](../README.md) for full architecture details, hardware test measurements on the Intel Core i5-11400 / Intel UHD Graphics 730 (`0x8086:0x4c8b`), quick-start instructions, open-source credits, and license information (`GPL-2.0-or-later OR LGPL-3.0-or-later`).

## Quick Links

- **Hardware & Intel UHD 730 Compatibility Report**: [`docs/HARDWARE_AND_GPU_REPORT.md`](docs/HARDWARE_AND_GPU_REPORT.md)
- **Installation & Operation Guide**: [`docs/INSTALLATION_GUIDE.md`](docs/INSTALLATION_GUIDE.md)
- **Troubleshooting, Recovery & 12 Error States**: [`docs/TROUBLESHOOTING_AND_RECOVERY.md`](docs/TROUBLESHOOTING_AND_RECOVERY.md)
- **GPU Diagnostic Tool (`tahoeboot-gpu-check`)**: [`gpu/src/main.rs`](gpu/src/main.rs)
- **Linux Guest GPU Workload Smoke Test (`smoke_guest_linux`)**: [`gpu/src/smoke_guest_linux.c`](gpu/src/smoke_guest_linux.c)
- **QEMU + Reims vGPU Fullscreen Launcher**: [`qemu/launch-vm.sh`](qemu/launch-vm.sh)
- **OpenCore 1.0.8 + `ReimsVgpu.kext` Builder**: [`opencore/build-opencore.sh`](opencore/build-opencore.sh)
- **Bootable UEFI ISO Builder & Verifier**: [`scripts/build-iso.sh`](scripts/build-iso.sh) & [`scripts/verify-iso.sh`](scripts/verify-iso.sh)
- **Safe External USB Creator**: [`scripts/create-usb.sh`](scripts/create-usb.sh)
- **Automated Test Suite (Tests A–E)**: [`scripts/run-test-suite.sh`](scripts/run-test-suite.sh)
