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
echo ">>> Configuring firewall..."
if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    echo "  Using UFW..."
    ufw allow 8008/tcp comment 'BeeGFS mgmtd'
    ufw allow 8005/tcp comment 'BeeGFS meta'
    ufw allow 8003/tcp comment 'BeeGFS storage'
    ufw allow 8004/tcp comment 'BeeGFS client'
elif command -v firewall-cmd &>/dev/null; then
    echo "  Using firewalld..."
    firewall-cmd --permanent --add-port=8008/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=8005/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=8003/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=8004/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
else
    echo "  No firewall detected. Ports: TCP 8003, 8004, 8005, 8008"
fi

# ============================================================
# 5. Create BeeGFS directories
# ============================================================

echo ""
echo ">>> Creating BeeGFS directories..."

# Metadata directory on nvme1n1 (ext4)
if mountpoint -q "${BEEGFS_META_MOUNT}" 2>/dev/null; then
    echo "  Metadata mount: ${BEEGFS_META_MOUNT} ($(df -h ${BEEGFS_META_MOUNT} | tail -1 | awk '{print $1}'))"
    mkdir -p "${BEEGFS_META_DIR}"
    chown -R beegfs:beegfs "${BEEGFS_META_MOUNT}" 2>/dev/null || true
    echo "  Created: ${BEEGFS_META_DIR}"
else
    echo "  WARNING: ${BEEGFS_META_MOUNT} not mounted. Format nvme1n1 first:"
    echo "    mkfs.ext4 -F /dev/nvme1n1 && mount /dev/nvme1n1 ${BEEGFS_META_MOUNT}"
fi

# Storage directories (slaves only)
for disk in /data/disk1 /data/disk2; do
    if mountpoint -q "${disk}" 2>/dev/null; then
        echo "  Storage mount: ${disk} ($(df -h ${disk} | tail -1 | awk '{print $1}'))"
        chown -R beegfs:beegfs "${disk}" 2>/dev/null || true
    fi
done

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
