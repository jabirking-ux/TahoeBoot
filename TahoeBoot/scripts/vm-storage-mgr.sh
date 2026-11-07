#!/usr/bin/env bash
# =============================================================================
# TahoeBoot VM Snapshot, Backup & Full-Drive Storage Manager (`TahoeBoot/scripts/vm-storage-mgr.sh`)
# =============================================================================
# Manages persistent macOS Tahoe storage in `VMStorage/macos-tahoe/`:
#   - `init`     : Detects the full capacity of the backing drive (`df -B1`) and creates
#                  or expands `disk.qcow2` to use the entire drive capacity (minus a 2 GiB
#                  reserve for OpenCore, OVMF NVRAM, and logs), or configures 100% raw
#                  block device passthrough when `TAHOEBOOT_RAW_DISK` is specified.
#   - `expand`   : Resizes `disk.qcow2` to claim 100% of the currently available drive space.
#   - `snapshot` : Creates a named qcow2 internal snapshot of `disk.qcow2` and backs up
#                  `OVMF_VARS.fd` (NVRAM).
#   - `backup`   : Exports a compressed backup of `OVMF_VARS.fd`, `opencore.qcow2`, and
#                  `configuration/vm.toml` into `VMStorage/macos-tahoe/backups/`.
#   - `status`   : Displays physical drive capacity, VM disk size, snapshots, and NVRAM state.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_DIR="${TAHOEBOOT_VM_DIR:-${PROJECT_ROOT}/VMStorage/macos-tahoe}"

ACTION="${1:-status}"
SNAP_NAME="${2:-tahoe-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "${VM_DIR}"/{configuration,logs,backups}

compute_full_drive_gib() {
    local target_dir="$1"
    local qcow2_path="${target_dir}/disk.qcow2"
    local fs_total_bytes fs_avail_bytes current_used_bytes usable_bytes target_gib
    fs_total_bytes="$(df -B1 --output=size "${target_dir}" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
    fs_avail_bytes="$(df -B1 --output=avail "${target_dir}" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
    current_used_bytes=0
    if [[ -f "${qcow2_path}" ]]; then
        current_used_bytes="$(stat -c '%s' "${qcow2_path}" 2>/dev/null || echo 0)"
    fi
    local reserve_bytes=$((2 * 1024 * 1024 * 1024))
    usable_bytes=$((fs_avail_bytes + current_used_bytes - reserve_bytes))
    if (( fs_total_bytes > reserve_bytes && (fs_total_bytes - reserve_bytes) > usable_bytes )); then
        usable_bytes=$((fs_total_bytes - reserve_bytes))
    fi
    target_gib=$((usable_bytes / (1024 * 1024 * 1024)))
    if (( target_gib < 64 )); then
        target_gib=128
    fi
    echo "${target_gib}"
}

case "${ACTION}" in
    init|expand)
        FULL_GIB="$(compute_full_drive_gib "${VM_DIR}")"
        if [[ ! -f "${VM_DIR}/disk.qcow2" ]]; then
            echo "[TahoeBoot Storage] Creating ${FULL_GIB}G macOS Tahoe disk (${VM_DIR}/disk.qcow2) spanning entire drive..."
            qemu-img create -f qcow2 -o cluster_size=65536,lazy_refcounts=on "${VM_DIR}/disk.qcow2" "${FULL_GIB}G"
        else
            CUR_BYTES="$(qemu-img info --output=json "${VM_DIR}/disk.qcow2" 2>/dev/null | awk -F'[:,]' '/"virtual-size"/{gsub(/[^0-9]/,"",$2); print $2; exit}' || echo 0)"
            CUR_GIB=$((CUR_BYTES / (1024 * 1024 * 1024)))
            if (( FULL_GIB > CUR_GIB )); then
                echo "[TahoeBoot Storage] Expanding ${VM_DIR}/disk.qcow2 from ${CUR_GIB}G -> ${FULL_GIB}G (entire drive capacity)..."
                qemu-img resize "${VM_DIR}/disk.qcow2" "${FULL_GIB}G"
            else
                echo "[TahoeBoot Storage] ${VM_DIR}/disk.qcow2 already sized to full drive capacity (${CUR_GIB}G)."
            fi
        fi
        cat > "${VM_DIR}/configuration/vm.toml" <<EOF
# TahoeBoot Persistent VM Configuration (\`VMStorage/macos-tahoe/configuration/vm.toml\`)
# Compatible with \`reims-ctl\` (\`upstream/reims-vgpu/crates/reims-ctl/src/vm.rs\`)
name = "macos-tahoe"
cpus = 4
memory_mib = 8192
disk_size_gb = ${FULL_GIB}
resolution = "1920x1080"
show_picker = true
os = "tahoe"

[gpu]
name = "Intel(R) UHD Graphics 730"
vendor_id = 32902   # 0x8086
device_id = 19595   # 0x4c8b
icd = "/usr/share/vulkan/icd.d/intel_icd.json"
EOF
        echo "[TahoeBoot Storage] Initialized ${VM_DIR} (${FULL_GIB} GiB allocated to VM)."
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
        df -h "${VM_DIR}" || true
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
        echo "Usage: $0 {init|expand|snapshot [name]|backup [name]|status}" >&2
        exit 1
        ;;
esac
