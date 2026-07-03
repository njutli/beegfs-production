#!/bin/bash
set -euo pipefail

# ============================================================
# Server Preparation (Single Server)
#
# Prepares a server for BeeGFS deployment:
#   - Time sync (chrony)
#   - NOPASSWD sudo
#   - Essential packages
#   - Firewall rules
#   - Create BeeGFS directories
#
# Disk layout (already done by admin):
#   Slaves: nvme1n1(ext4→/mnt/beegfs-meta) + nvme2n1(XFS→/data/disk1) + nvme3n1(XFS→/data/disk2)
#   Client: nvme1n1(ext4→/mnt/beegfs-meta)
#
# Usage: sudo bash prepare-servers.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

SUDO_USER="${SUDO_USER:-sunrise}"
BEEGFS_META_MOUNT="/mnt/beegfs-meta"
BEEGFS_META_DIR="${BEEGFS_META_MOUNT}/beegfs_meta"

echo "========================================"
echo "BeeGFS Server Preparation"
echo "Host: $(hostname)"
echo "========================================"

# ============================================================
# 1. Time synchronisation
# ============================================================

echo ""
echo ">>> Time synchronisation..."
apt-get update -qq

if systemctl is-active systemd-timesyncd &>/dev/null; then
    echo "  systemd-timesyncd already active."
elif ! command -v chronyd &>/dev/null && ! command -v ntpd &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntp >/dev/null 2>&1 || {
        echo "  ERROR: failed to install time sync package."
        exit 1
    }
    systemctl enable chrony --now 2>/dev/null || systemctl enable ntp --now 2>/dev/null || true
fi
echo "  Time sync enabled."

# ============================================================
# 2. Grant NOPASSWD sudo
# ============================================================

echo ""
echo ">>> Granting passwordless sudo to ${SUDO_USER}..."
if ! grep -q "^${SUDO_USER} ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/${SUDO_USER} 2>/dev/null; then
    echo "${SUDO_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${SUDO_USER}
    chmod 440 /etc/sudoers.d/${SUDO_USER}
fi
echo "  Done."

# ============================================================
# 3. Install essential packages
# ============================================================

echo ""
echo ">>> Installing essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget tar gzip build-essential dkms linux-headers-$(uname -r) \
    htop iotop iftop sysstat fio \
    >/dev/null 2>&1
echo "  Packages installed."

# ============================================================
# 4. Firewall
# ============================================================

echo ""
echo ">>> Configuring firewall (role=${PREPARE_ROLE:-slave})..."
if [ "${PREPARE_ROLE:-slave}" = "client" ]; then
    PORTS=(8008 8005 8004);    PORT_NAMES=("mgmtd" "meta" "client")
else
    PORTS=(8005 8003);          PORT_NAMES=("meta" "storage")
fi
if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    echo "  Using UFW..."
    for i in "${!PORTS[@]}"; do
        ufw allow ${PORTS[$i]}/tcp comment "BeeGFS ${PORT_NAMES[$i]}"
    done
elif command -v firewall-cmd &>/dev/null; then
    echo "  Using firewalld..."
    for p in "${PORTS[@]}"; do
        firewall-cmd --permanent --add-port=${p}/tcp 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
else
    echo "  No firewall detected. Ports: ${PORTS[*]}"
fi

# ============================================================
# 5. Create BeeGFS directories
# ============================================================

echo ""
echo ">>> Preparing BeeGFS directories..."

# --- Metadata: nvme1n1 (ext4) ---
if mountpoint -q "${BEEGFS_META_MOUNT}" 2>/dev/null; then
    echo "  Metadata mount: ${BEEGFS_META_MOUNT} ($(df -h ${BEEGFS_META_MOUNT} | tail -1 | awk '{print $1}'))"
    mkdir -p "${BEEGFS_META_DIR}"
    chown -R beegfs:beegfs "${BEEGFS_META_MOUNT}" 2>/dev/null || true
    echo "  Created: ${BEEGFS_META_DIR}"
else
    echo "  WARNING: ${BEEGFS_META_MOUNT} 未挂载。请先格式化并挂载 nvme1n1:"
    echo "    mkfs.ext4 -F /dev/nvme1n1 && mount /dev/nvme1n1 ${BEEGFS_META_MOUNT}"
fi

if [ "${PREPARE_ROLE:-slave}" != "client" ]; then
# --- Storage: 两块独立 NVMe → XFS, 挂载到 /data/disk1, /data/disk2 ---
# 官方 XFS 挂载参数 (per storage_tuning 文档)
XFS_OPTS="noatime,nodiratime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,allocsize=131072k"
STORAGE_DEVS=(/dev/nvme2n1 /dev/nvme3n1)
STORAGE_DIRS=(/data/disk1 /data/disk2)

# 检测 md0: 若 nvme2n1/nvme3n1 是 md0 成员, 与"独立两块 XFS"设计冲突, 要求先拆除
if [ -b /dev/md0 ] && mdadm --detail /dev/md0 2>/dev/null | grep -qE 'nvme2n1|nvme3n1'; then
    echo "  ERROR: /dev/md0 包含 nvme2n1/nvme3n1 ($(mdadm --detail /dev/md0 2>/dev/null | grep -iE 'Raid Level|State' | tr '\n' ' '))"
    echo "  工程设计为'两块独立 XFS', 与 RAID0 冲突。请先手动拆除 md0 (破坏性, 清除数据):"
    echo "    sudo mdadm --stop /dev/md0"
    echo "    sudo mdadm --zero-superblock /dev/nvme2n1 /dev/nvme3n1"
    echo "  拆除后重跑本脚本。"
    exit 1
fi

for i in 0 1; do
    dev="${STORAGE_DEVS[$i]}"
    dir="${STORAGE_DIRS[$i]}"
    if [ ! -b "$dev" ]; then
        echo "  ERROR: $dev 不存在"; exit 1
    fi
    if mountpoint -q "$dir" 2>/dev/null; then
        cur_fs=$(findmnt -no FSTYPE "$dir" 2>/dev/null || echo unknown)
        cur_opts=$(findmnt -no OPTIONS "$dir" 2>/dev/null || echo unknown)
        echo "  $dir: 已挂载 ($cur_fs), opts=$cur_opts"
        if [ "$cur_fs" != "xfs" ]; then
            echo "  ERROR: $dir 不是 XFS。请先卸载并格式化: umount $dir; mkfs.xfs <dev>"
            exit 1
        fi
        # 挂载参数是否含官方关键项? 不含则卸载重挂
        if ! echo "$cur_opts" | grep -q 'logbufs=8' || ! echo "$cur_opts" | grep -q 'allocsize=131072k'; then
            src=$(findmnt -no SOURCE "$dir" 2>/dev/null || echo "")
            echo "  挂载参数非官方推荐, 卸载后用官方参数重挂..."
            umount "$dir"
            mount -o "$XFS_OPTS" "$src" "$dir"
            echo "  重挂: $src -> $dir ($XFS_OPTS)"
        fi
    else
        # 未挂载: 检查/格式化为 XFS 后挂载
        if ! blkid "$dev" 2>/dev/null | grep -q 'TYPE="xfs"'; then
            echo "  格式化 $dev 为 XFS ..."
            mkfs.xfs -f "$dev"
        fi
        mkdir -p "$dir"
        mount -o "$XFS_OPTS" "$dev" "$dir"
        echo "  挂载: $dev -> $dir ($XFS_OPTS)"
        uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || echo "")
        if [ -n "$uuid" ] && ! grep -q " $dir " /etc/fstab 2>/dev/null; then
            echo "UUID=$uuid $dir xfs $XFS_OPTS 0 0" >> /etc/fstab
            echo "  fstab 已添加 $dir"
        fi
    fi
    chown -R beegfs:beegfs "$dir" 2>/dev/null || true
done
else
    echo "  [skip] storage disks (role=client, 无 storage 服务)"
fi

echo ""
echo ">>> Setting file descriptor limits..."
cat > /etc/security/limits.d/99-beegfs.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF
echo "  Done."

# ============================================================
# 6. Result summary
# ============================================================

echo ""
echo "========================================"
echo "Server preparation complete!"
echo "========================================"
echo ""
echo "Checks:"
echo "  Time sync:            $(systemctl is-active chrony 2>/dev/null || systemctl is-active ntp 2>/dev/null || systemctl is-active systemd-timesyncd 2>/dev/null || echo 'UNKNOWN')"
echo "  NOPASSWD sudo:        $(if sudo -n true 2>/dev/null; then echo 'OK'; else echo 'FAILED'; fi)"
echo "  Metadata mount:       $(mountpoint -q /mnt/beegfs-meta 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
echo "  Storage disk1:        $(mountpoint -q /data/disk1 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
echo "  Storage disk2:        $(mountpoint -q /data/disk2 2>/dev/null && echo 'OK' || echo 'NOT MOUNTED')"
