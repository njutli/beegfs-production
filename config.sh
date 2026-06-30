#!/bin/bash
# ============================================================
# BeeGFS Production Deployment Configuration (4 Machines)
#
# 架构说明:
#   - 157: 只做 Client (mount point)，不部署任何服务
#   - 150: mgmtd + meta + 2 storage targets
#   - 151: meta + 2 storage targets  
#   - 152: meta + 2 storage targets
#
# 磁盘规划:
#   - 157: 不动任何配置，只做客户端
#   - 150-152: 各 2×7TB 独立NVMe → 6 storage targets
#
# Edit this file with your actual server IPs before running.
# ============================================================

# --- Client Server (只做客户端，不部署服务) ---
# 157 不部署任何 BeeGFS 服务，只作为客户端挂载点
CLIENT_SERVER="10.20.1.157"
CLIENT_EXT="203.156.3.194"
CLIENT_PORT="19891"

# --- Slave Servers (部署 mgmtd + meta + storage) ---
# 150: mgmtd + meta + 2 storage targets
# 151: meta + 2 storage targets
# 152: meta + 2 storage targets
SLAVE_SERVERS=(
  "10.20.1.150"  # mgmtd + meta + storage
  "10.20.1.151"  # meta + storage
  "10.20.1.152"  # meta + storage
)

# All servers (client + slaves)
ALL_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- BeeGFS Service Hosts ---
# Management service runs on slave1 (10.20.1.150)
BEEGFS_MGMTD_HOST="10.20.1.150"
BEEGFS_MGMTD_PORT="8008"

# Metadata service runs on all slaves
BEEGFS_META_PORT="8005"
BEEGFS_STORAGE_PORT="8003"
BEEGFS_CLIENT_PORT="8004"

# --- Storage Paths (Slaves only) ---
# Slaves: two storage paths (独立NVMe)
BEEGFS_DATA_ROOT="/data/beegfs"

# Storage directories on slaves
BEEGFS_STORAGE_DIR_SLAVE_1="/data/disk1"
BEEGFS_STORAGE_DIR_SLAVE_2="/data/disk2"

# Metadata and mgmtd paths (on slaves)
BEEGFS_MGMTD_DIR="${BEEGFS_DATA_ROOT}/mgmtd"
BEEGFS_META_DIR="${BEEGFS_DATA_ROOT}/meta"

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
BEEGFS_STRIPE_PATTERN="raid0"
BEEGFS_STRIPE_SIZE="512K"
# Stripe count: 6 storage targets on slaves
BEEGFS_STRIPE_COUNT="6"

# --- Repo ---
BEEGFS_REPO_URL="https://www.beegfs.io/release/beegfs_7.4/dists/beegfs-deb11.list"
BEEGFS_REPO_KEY="https://www.beegfs.io/release/beegfs_7.4/gpg/DEB-GPG-KEY-beegfs_7.4.asc"

# --- Client-only mode ---
# 157 只做客户端，不部署任何服务
CLIENT_ONLY="yes"
