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
#   - Create BeeGFS directories on /data
#
# Usage: sudo bash prepare-servers.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "========================================"
echo "BeeGFS Server Preparation"
echo "Host: $(hostname)"
echo "========================================"

# ============================================================
# 1. Time synchronisation (critical for distributed systems)
# ============================================================

echo ""
echo ">>> Time synchronisation..."

apt-get update -qq || echo "  (apt update had errors, continuing)"

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
# 2. Grant NOPASSWD sudo to sunrise
# ============================================================

echo ""
echo ">>> Granting passwordless sudo to ${SUDO_USER:-sunrise}..."
SUDO_USER="${SUDO_USER:-sunrise}"
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
    curl wget tar gzip build-essential \
    htop iotop iftop sysstat fio \
    >/dev/null 2>&1 || echo "  (some packages unavailable, continuing)"

echo "  Packages installed."

# ============================================================
# 4. Firewall — open BeeGFS ports
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
    echo "  No firewall detected. Ports needed: TCP 8003, 8004, 8005, 8008"
fi

# ============================================================
# 5. Create BeeGFS directories
# ============================================================

echo ""
echo ">>> Creating BeeGFS directories..."

BEEGFS_DATA_ROOT="/data/beegfs"

# Detect disk configuration
if mountpoint -q /data 2>/dev/null; then
    # Master: RAID0 mounted at /data
    echo "  Detected: /data is mounted (RAID0 on master)"
    mkdir -p "${BEEGFS_DATA_ROOT}/mgmtd"
    mkdir -p "${BEEGFS_DATA_ROOT}/meta"
    mkdir -p "${BEEGFS_DATA_ROOT}/storage"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${BEEGFS_DATA_ROOT}" 2>/dev/null || true
    echo "  Created: ${BEEGFS_DATA_ROOT}/{mgmtd,meta,storage}"
elif [ -d /data/disk1 ] && [ -d /data/disk2 ]; then
    # Slaves: independent NVMe at /data/disk1 and /data/disk2
    echo "  Detected: /data/disk1 and /data/disk2 (独立NVMe on slaves)"
    mkdir -p "${BEEGFS_DATA_ROOT}/mgmtd"
    mkdir -p "${BEEGFS_DATA_ROOT}/meta"
    mkdir -p /data/disk1
    mkdir -p /data/disk2
    chown -R "${SUDO_USER}:${SUDO_USER}" /data/disk1 /data/disk2 2>/dev/null || true
    chown -R "${SUDO_USER}:${SUDO_USER}" "${BEEGFS_DATA_ROOT}" 2>/dev/null || true
    echo "  Created: ${BEEGFS_DATA_ROOT}/{mgmtd,meta} + /data/disk1 + /data/disk2"
else
    # Fallback: create standard directories
    echo "  WARNING: Unknown disk configuration, using default layout"
    mkdir -p "${BEEGFS_DATA_ROOT}/mgmtd"
    mkdir -p "${BEEGFS_DATA_ROOT}/meta"
    mkdir -p "${BEEGFS_DATA_ROOT}/storage"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${BEEGFS_DATA_ROOT}" 2>/dev/null || true
fi

echo ""
echo ">>> Directories created:"
ls -ld /data/*/ 2>/dev/null || true

# ============================================================
# 6. Set hostname alias for BeeGFS (optional)
# ============================================================

echo ""
echo ">>> Hostname: $(hostname)"
echo "  BeeGFS uses hostnames for node identification."
echo "  Ensure all servers can resolve each other by hostname."

echo ""
echo "========================================"
echo "Server preparation complete!"
echo "========================================"
