#!/bin/bash
# ============================================================
# BeeGFS Production Deployment Configuration (4 Machines)
#
#   1 × Master (mgmtd + meta + storage + client) — 1 storage target (RAID0)
#   3 × Slaves (meta + storage) — 2 storage targets each (独立NVMe)
#
# 磁盘规划:
#   Master: /dev/md0 (2×7TB NVMe RAID0) → /data/beegfs/storage
#   Slaves: /dev/nvme2n1 + /dev/nvme3n1 (各7TB独立) → /data/disk1 + /data/disk2
#
# Edit this file with your actual server IPs before running.
# ============================================================

# --- Master Server ---
# This machine runs management service, one metadata target,
# one storage target, and the BeeGFS client.
# Note: Master uses RAID0 (md0), cannot be split due to weka dependency.
MASTER_SERVER="10.20.1.157"
MASTER_EXT="203.156.3.194"
MASTER_PORT="19891"

# --- Slave Servers ---
# Each runs one metadata target + TWO storage targets (独立NVMe).
SLAVE_SERVERS=(
  "10.20.1.150"
  "10.20.1.151"
  "10.20.1.152"
)

# All servers in one list (master + slaves)
ALL_SERVERS=( "${MASTER_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- Storage Targets Configuration ---
# Master uses RAID0, Slaves use independent NVMe
# Define storage paths for each server type
BEEGFS_DATA_ROOT="/data/beegfs"

# Master: single storage path (RAID0)
BEEGFS_STORAGE_DIR_MASTER="${BEEGFS_DATA_ROOT}/storage"

# Slaves: two storage paths (独立NVMe)
BEEGFS_STORAGE_DIR_SLAVE_1="/data/disk1"
BEEGFS_STORAGE_DIR_SLAVE_2="/data/disk2"

# Metadata and mgmtd paths (same on all servers)
BEEGFS_MGMTD_DIR="${BEEGFS_DATA_ROOT}/mgmtd"
BEEGFS_META_DIR="${BEEGFS_DATA_ROOT}/meta"

# --- BeeGFS Service Configuration ---
BEEGFS_MGMTD_HOST="${MASTER_SERVER}"
BEEGFS_MGMTD_PORT="8008"
BEEGFS_META_PORT="8005"
BEEGFS_STORAGE_PORT="8003"
BEEGFS_CLIENT_PORT="8004"

BEEGFS_SYSMGMTD_HOST="${MASTER_SERVER}"
BEEGFS_SYSMGMTD_PORT="8008"

# Optional: use the spare NVMe (nvme1n1) for a dedicated metadata target
# Set to "yes" to format nvme1n1 and mount it as a separate metadata volume
USE_SPARE_NVME_FOR_META="no"
SPARE_NVME_DEV="/dev/nvme1n1"
SPARE_NVME_MOUNT="/mnt/beegfs-meta"

# --- BeeGFS Version ---
# Ubuntu 22.04 ships BeeGFS 7.x from the beegfs apt repo.
# Set to "yes" to install latest from beegfs.org repo instead.
USE_BEEGFS_REPO="yes"

# --- Client Mount ---
BEEGFS_MOUNT_POINT="/mnt/beegfs"
BEEGFS_CLIENT_CONF="/etc/beegfs/beegfs-client.conf"

# --- SSH Configuration ---
SSH_USER="sunrise"
SSH_PASSWORD="Sunrise@801"
SSH_KEY="${HOME}/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# --- Network ---
# BeeGFS connInterfacesFile — which NICs to use for data transfer.
# Leave empty to use default routing. To use the 100G network:
#   BEEGFS_CONN_INTERFACES="enp139s0f0np0"
BEEGFS_CONN_INTERFACES=""
BEEGFS_CONN_INTERFACES_FILE="/etc/beegfs/conninf.conf"

# --- Tuning ---
# Stripe pattern: RAID0 (default), random, RAID10
# RAID0 = maximum throughput, no redundancy
BEEGFS_STRIPE_PATTERN="raid0"
BEEGFS_STRIPE_SIZE="512K"
# Stripe count: Master (1) + Slaves (3×2=6) = 7 storage targets
# Note: Master only has 1 target due to RAID0, but we can stripe across 7 targets
BEEGFS_STRIPE_COUNT="7"

# --- Repo ---
BEEGFS_REPO_URL="https://www.beegfs.io/release/beegfs_7.4/dists/beegfs-deb11.list"
BEEGFS_REPO_KEY="https://www.beegfs.io/release/beegfs_7.4/gpg/DEB-GPG-KEY-beegfs_7.4.asc"
