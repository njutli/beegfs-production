#!/bin/bash
# ============================================================
# BeeGFS Production Deployment Configuration (4 Machines)
#
#   1 × Master (mgmtd + meta + storage + client)
#   3 × Slaves (meta + storage)
#
# Edit this file with your actual server IPs before running.
# ============================================================

# --- Master Server ---
# This machine runs management service, one metadata target,
# one storage target, and the BeeGFS client.
MASTER_SERVER="10.20.1.157"
MASTER_EXT="203.156.3.194"
MASTER_PORT="19891"

# --- Slave Servers ---
# Each runs one metadata target + one storage target.
SLAVE_SERVERS=(
  "10.20.1.150"
  "10.20.1.151"
  "10.20.1.152"
)

# All servers in one list (master + slaves)
ALL_SERVERS=( "${MASTER_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- BeeGFS Service Configuration ---
BEEGFS_MGMTD_HOST="${MASTER_SERVER}"
BEEGFS_MGMTD_PORT="8008"
BEEGFS_META_PORT="8005"
BEEGFS_STORAGE_PORT="8003"
BEEGFS_CLIENT_PORT="8004"

BEEGFS_SYSMGMTD_HOST="${MASTER_SERVER}"
BEEGFS_SYSMGMTD_PORT="8008"

# --- Storage Paths ---
# Use the existing RAID0 mounted at /data on each server.
# BeeGFS stores data under these directories.
BEEGFS_DATA_ROOT="/data/beegfs"
BEEGFS_MGMTD_DIR="${BEEGFS_DATA_ROOT}/mgmtd"
BEEGFS_META_DIR="${BEEGFS_DATA_ROOT}/meta"
BEEGFS_STORAGE_DIR="${BEEGFS_DATA_ROOT}/storage"

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
BEEGFS_STRIPE_COUNT="4"

# --- Repo ---
BEEGFS_REPO_URL="https://www.beegfs.io/release/beegfs_7.4/dists/beegfs-deb11.list"
BEEGFS_REPO_KEY="https://www.beegfs.io/release/beegfs_7.4/gpg/DEB-GPG-KEY-beegfs_7.4.asc"
