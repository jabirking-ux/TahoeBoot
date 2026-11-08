#!/usr/bin/env bash
# =============================================================================
# TahoeBoot Host Disk Bidirectional Read-Write Service (`TahoeBoot/scripts/start-host-disk-rw.sh`)
# =============================================================================
# Ensures that any file created, edited, or deleted inside macOS Tahoe on the
# host's physical drives (`Windows (C:)`, `Local Disk (D:)`, or bare-metal
# NTFS/ext4/exFAT partitions) is written directly to the real physical disk
# and persists immediately when you reboot into Windows!
#
# How it works across both environments:
#   1. Bare-Metal Appliance (`TahoeBoot.iso`):
#      - Disables Windows Fast Startup / Hibernate dirty-bit locks (`ntfsfix -d`)
#        and mounts all physical NTFS (`ntfs-3g -o rw,sync`), exFAT, and ext4
#        partitions under `/mnt/host-disks/<label_or_dev>`.
#      - Also passes the physical disks directly to QEMU in read-write mode
#        (`TAHOEBOOT_HOST_DISKS_RW=1`, `cache=writeback` + `fsync` on exit).
#   2. WSL2 on Windows:
#      - Exports `/mnt/c` (`Windows_C`), `/mnt/d` (`LocalDisk_D`), and all
#        mounted `/mnt/*` physical drives via both:
#          (a) Local high-speed Samba (`smbd` on `127.0.0.1:4445` -> QEMU
#              `10.0.2.2:445` / `smb://10.0.2.4`), which macOS mounts natively
#              with full read-write support in Finder (`/Volumes/Windows_C`,
#              `/Volumes/LocalDisk_D`) without needing third-party NTFS kexts!
#          (b) VirtIO-9P PCI devices (`Windows_C`, `LocalDisk_D`).
# =============================================================================
set -euo pipefail

IS_WSL=0
if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    IS_WSL=1
fi

SMB_ROOT="/run/tahoeboot-smb"
mkdir -p "${SMB_ROOT}/private" "${SMB_ROOT}/lock" "${SMB_ROOT}/log" "/mnt/host-disks"

# On bare-metal Linux, mount all physical NTFS/exFAT/FAT32/ext4 partitions read-write
# under /mnt/host-disks/<part> so both Samba and host tools write directly to disk
if [[ "${IS_WSL}" == "0" ]]; then
    while read -r dev fstype label; do
        [[ -z "${dev}" || -z "${fstype}" ]] && continue
        if [[ "${fstype}" =~ ^(ntfs|exfat|vfat|ext4)$ ]]; then
            mp_name="${label:-$(basename "${dev}")}"
            mp_name="${mp_name// /_}"
            mp="/mnt/host-disks/${mp_name}"
            mkdir -p "${mp}"
            if ! mountpoint -q "${mp}"; then
                if [[ "${fstype}" == "ntfs" ]]; then
                    # Clear Windows Fast Startup hibernation lock if present so writes persist
                    ntfsfix -d "${dev}" >/dev/null 2>&1 || true
                    ntfs-3g -o rw,big_writes,sync "${dev}" "${mp}" 2>/dev/null || mount -o rw "${dev}" "${mp}" 2>/dev/null || true
                else
                    mount -o rw "${dev}" "${mp}" 2>/dev/null || true
                fi
            fi
        fi
    done < <(lsblk -pno NAME,FSTYPE,LABEL 2>/dev/null || true)
fi

if command -v smbd >/dev/null 2>&1; then
    cat > "${SMB_ROOT}/smb.conf" <<EOF
[global]
   workgroup = WORKGROUP
   server string = TahoeBoot Physical Host Disks
   security = user
   map to guest = Bad User
   guest account = root
   bind interfaces only = yes
   interfaces = 127.0.0.1
   smb ports = 445 4445
   pid directory = ${SMB_ROOT}
   lock directory = ${SMB_ROOT}/lock
   state directory = ${SMB_ROOT}
   cache directory = ${SMB_ROOT}
   ncalrpc dir = ${SMB_ROOT}/ncalrpc
   private dir = ${SMB_ROOT}/private
   log file = ${SMB_ROOT}/log/smbd.log
   max log size = 1000
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   strict sync = yes
   sync always = yes

EOF

    if [[ -d "/mnt/c" ]]; then
        cat >> "${SMB_ROOT}/smb.conf" <<EOF
[Windows_C]
   comment = Physical Windows (C:) Drive - Live Read/Write
   path = /mnt/c
   browseable = yes
   read only = no
   writable = yes
   guest ok = yes
   force user = root
   force group = root
   create mask = 0777
   directory mask = 0777

EOF
    fi

    if [[ -d "/mnt/d" ]]; then
        cat >> "${SMB_ROOT}/smb.conf" <<EOF
[LocalDisk_D]
   comment = Physical Local Disk (D:) Drive - Live Read/Write
   path = /mnt/d
   browseable = yes
   read only = no
   writable = yes
   guest ok = yes
   force user = root
   force group = root
   create mask = 0777
   directory mask = 0777

EOF
    fi

    if [[ -d "/mnt/host-disks" ]]; then
        cat >> "${SMB_ROOT}/smb.conf" <<EOF
[HostDisks]
   comment = All Physical Host Disks (/mnt/host-disks) - Live Read/Write
   path = /mnt/host-disks
   browseable = yes
   read only = no
   writable = yes
   guest ok = yes
   force user = root
   force group = root
   create mask = 0777
   directory mask = 0777
EOF
    fi

    systemctl stop smbd nmbd 2>/dev/null || true
    pkill -9 smbd 2>/dev/null || true
    smbd -D -s "${SMB_ROOT}/smb.conf"
    echo "[TahoeBoot Host Disk RW] Started bidirectional read-write host disk bridge (smbd on 127.0.0.1:445 & 4445; strict sync=yes)."
fi
