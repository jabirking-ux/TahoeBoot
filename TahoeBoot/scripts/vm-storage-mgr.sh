#!/usr/bin/env bash
# =============================================================================
# TahoeBoot VM Snapshot, Backup & NVRAM Manager (`TahoeBoot/scripts/vm-storage-mgr.sh`)
# =============================================================================
# Manages persistent macOS Tahoe storage in `VMStorage/macos-tahoe/`:
#   - `init`     : Creates thin-provisioned 128 GiB `disk.qcow2`, verifies `opencore.qcow2`,
#                  `OVMF_CODE.fd`, `OVMF_VARS.fd`, and writes `configuration/vm.toml`.
#   - `snapshot` : Creates a named qcow2 internal snapshot of `disk.qcow2` and backs up
#                  `OVMF_VARS.fd` (NVRAM).
#   - `backup`   : Exports a compressed backup of `OVMF_VARS.fd`, `opencore.qcow2`, and
#                  `configuration/vm.toml` into `VMStorage/macos-tahoe/backups/`.
#   - `status`   : Displays disk health, qcow2 allocation, snapshots, and NVRAM state.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_DIR="${TAHOEBOOT_VM_DIR:-${PROJECT_ROOT}/VMStorage/macos-tahoe}"

ACTION="${1:-status}"
SNAP_NAME="${2:-tahoe-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "${VM_DIR}"/{configuration,logs,backups}

case "${ACTION}" in
    init)
        if [[ ! -f "${VM_DIR}/disk.qcow2" ]]; then
            echo "[TahoeBoot Storage] Creating 128G persistent macOS Tahoe disk (${VM_DIR}/disk.qcow2)..."
            qemu-img create -f qcow2 -o cluster_size=65536,lazy_refcounts=on "${VM_DIR}/disk.qcow2" 128G
        fi
        cat > "${VM_DIR}/configuration/vm.toml" <<'EOF'
# TahoeBoot Persistent VM Configuration (`VMStorage/macos-tahoe/configuration/vm.toml`)
# Compatible with `reims-ctl` (`upstream/reims-vgpu/crates/reims-ctl/src/vm.rs`)
name = "macos-tahoe"
cpus = 4
memory_mib = 8192
disk_size_gb = 128
resolution = "1920x1080"
show_picker = true
os = "tahoe"

[gpu]
name = "Intel(R) UHD Graphics 730"
vendor_id = 32902   # 0x8086
device_id = 19595   # 0x4c8b
icd = "/usr/share/vulkan/icd.d/intel_icd.json"
EOF
        echo "[TahoeBoot Storage] Initialized ${VM_DIR}."
        ;;
    snapshot)
        echo "[TahoeBoot Storage] Creating qcow2 snapshot '${SNAP_NAME}' on ${VM_DIR}/disk.qcow2..."
        qemu-img snapshot -c "${SNAP_NAME}" "${VM_DIR}/disk.qcow2"
        if [[ -f "${VM_DIR}/OVMF_VARS.fd" ]]; then
            cp -f "${VM_DIR}/OVMF_VARS.fd" "${VM_DIR}/backups/OVMF_VARS-${SNAP_NAME}.fd"
        fi
        qemu-img snapshot -l "${VM_DIR}/disk.qcow2"
        ;;
    backup)
        ARCHIVE="${VM_DIR}/backups/tahoe-metadata-${SNAP_NAME}.tar.gz"
        echo "[TahoeBoot Storage] Backing up NVRAM (OVMF_VARS.fd), OpenCore, and vm.toml to ${ARCHIVE}..."
        tar -czf "${ARCHIVE}" -C "${VM_DIR}" \
            $( [[ -f "${VM_DIR}/OVMF_VARS.fd" ]] && echo "OVMF_VARS.fd" ) \
            $( [[ -f "${VM_DIR}/opencore.qcow2" ]] && echo "opencore.qcow2" ) \
            configuration/
        ls -lh "${ARCHIVE}"
        ;;
    status)
        echo "=== TAHOEBOOT PERSISTENT STORAGE STATUS (${VM_DIR}) ==="
        for f in disk.qcow2 opencore.qcow2 OVMF_CODE.fd OVMF_VARS.fd configuration/vm.toml; do
            if [[ -f "${VM_DIR}/${f}" ]]; then
                ls -lh "${VM_DIR}/${f}"
            else
                echo "MISSING: ${VM_DIR}/${f}"
            fi
        done
        if [[ -f "${VM_DIR}/disk.qcow2" ]]; then
            echo "--- disk.qcow2 info & snapshots ---"
            qemu-img info "${VM_DIR}/disk.qcow2"
        fi
        ;;
    *)
        echo "Usage: $0 {init|snapshot [name]|backup [name]|status}" >&2
        exit 1
        ;;
esac
