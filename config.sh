#!/bin/bash
# ============================================================
# BeeGFS Production Deployment Configuration (4 Machines)
#
# 架构说明 (官方最佳实践 + 镜像):
#   157 (client + meta):     nvme1n1(894G ext4) → metadata
#   150 (mgmtd + meta + storage):  nvme1n1(894G ext4) → metadata
#                                  nvme2n1(7T XFS) + nvme3n1(7T XFS) → 2 storage
#   151 (meta + storage):    同 150
#   152 (meta + storage):    同 150
#
# 镜像配置 (Buddy Groups):
#   Metadata: 2 groups (4 meta servers, 偶数才能镜像)
#     Group 1: 150-meta + 151-meta
#     Group 2: 152-meta + 157-meta
#   Storage: 3 groups (6 targets, 跨节点配对)
#     Group 1: 150-disk1 + 151-disk1
#     Group 2: 150-disk2 + 152-disk1
#     Group 3: 151-disk2 + 152-disk2
#
# 官方文档: https://doc.beegfs.io/latest/
# ============================================================

# --- Client + Metadata Server (157) ---
# 157 运行 client + metadata 服务 (用空闲的 nvme1n1)
# 不运行 storage 服务，不影响现有业务
CLIENT_SERVER="10.20.1.157"
CLIENT_EXT="203.156.3.194"
CLIENT_PORT="19891"

# --- Slave Servers (mgmtd + meta + storage) ---
SLAVE_SERVERS=(
  "10.20.1.150"  # mgmtd + meta + 2 storage
  "10.20.1.151"  # meta + 2 storage
  "10.20.1.152"  # meta + 2 storage
)

# All servers with metadata service (4 nodes, 偶数 for mirroring)
META_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# All servers
ALL_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- BeeGFS Version ---
# 使用 BeeGFS 8.x (官方最新)
BEEGFS_MAJOR_VERSION="8"

# --- BeeGFS Service Hosts ---
BEEGFS_MGMTD_HOST="10.20.1.157"
BEEGFS_MGMTD_PORT="8008"
BEEGFS_META_PORT="8005"
BEEGFS_STORAGE_PORT="8003"
BEEGFS_CLIENT_PORT="8004"

# --- Storage Paths (Slaves only) ---
# Storage: XFS on independent NVMe (官方推荐 XFS)
BEEGFS_STORAGE_DIR_SLAVE_1="/data/disk1"
BEEGFS_STORAGE_DIR_SLAVE_2="/data/disk2"

# Metadata: ext4 on dedicated nvme1n1 (官方推荐 ext4 for metadata)
BEEGFS_META_DIR="/mnt/beegfs-meta/beegfs_meta"

# Management: SQLite database (8.x uses SQLite, not directory)
BEEGFS_MGMTD_DB="/var/lib/beegfs/mgmtd.sqlite"

# --- Client Mount ---
BEEGFS_MOUNT_POINT="/mnt/beegfs"
BEEGFS_CLIENT_CONF="/etc/beegfs/beegfs-client.conf"

# --- SSH Configuration ---
SSH_USER="sunrise"
SSH_PASSWORD="Sunrise@801"
SSH_KEY="${HOME}/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# --- Jump Hosts ---
# HK ECS jump host (WSL → HK → TH)
HK_ECS="190.92.233.189"
HK_ECS_USER="root"
HK_ECS_PASSWORD="Sunrise@801"

# SSH to client (157) via HK ECS jump
# Usage: ssh_to_client <command_string>
# The command is base64-encoded to avoid quoting issues with nested sshpass/ssh.
ssh_to_client() {
    local cmd="$1"
    local encoded
    encoded=$(echo -n "$cmd" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ${encoded} | base64 -d | bash'"
}

# SSH to slave via HK ECS → client(157) jump
# Usage: ssh_to_slave <ip> <command_string>
ssh_to_slave() {
    local ip=$1
    local cmd="$2"
    local encoded
    encoded=$(echo -n "$cmd" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' \
            sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T ${SSH_USER}@${ip} 'echo ${encoded} | base64 -d | bash'"
}

# Copy file to remote server via jump
# Usage: scp_to_server <src_local> <dest_ip> <dest_path>
# 自动判断目标: CLIENT_SERVER 走一级跳板，slave 走两级跳板
scp_to_server() {
    local src=$1 ip=$2 dest=$3
    local base64_src
    base64_src=$(base64 -w0 "$src")
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "cat > '$dest'" < "$src"
    else
        ssh_to_slave "$ip" "cat > '$dest'" < "$src"
    fi
}

# --- Network ---
# BeeGFS connInterfacesFile — which NICs to use for data transfer.
# Leave empty to use default routing. To use the 100G network:
#   BEEGFS_CONN_INTERFACES="enp139s0f0np0"
BEEGFS_CONN_INTERFACES=""
BEEGFS_CONN_INTERFACES_FILE="/etc/beegfs/conninf.conf"

# --- TLS & Authentication (8.x required, can disable for testing) ---
BEEGFS_TLS_DISABLE="true"
BEEGFS_AUTH_DISABLE="true"

# --- Tuning (per official docs) ---
# Stripe pattern: mirrored (启用 buddy group 镜像)
BEEGFS_STRIPE_PATTERN="mirrored"
BEEGFS_STRIPE_SIZE="1MiB"
# Stripe count = number of buddy groups = 3 (storage)
BEEGFS_STRIPE_COUNT="3"

# --- XFS Mount Options (per official storage tuning docs) ---
BEEGFS_XFS_MOUNT_OPTS="noatime,nodiratime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,allocsize=131072k"

# --- Repo (BeeGFS 8.x) ---
BEEGFS_REPO_URL="https://www.beegfs.io/release/beegfs_${BEEGFS_MAJOR_VERSION}/dists/beegfs-deb11.list"
BEEGFS_REPO_KEY="https://www.beegfs.io/release/beegfs_${BEEGFS_MAJOR_VERSION}/gpg/DEB-GPG-KEY-beegfs_${BEEGFS_MAJOR_VERSION}.asc"

# --- Node IDs (for setup commands) ---
# Metadata node IDs
META_NODE_ID_157="1"
META_NODE_ID_150="2"
META_NODE_ID_151="3"
META_NODE_ID_152="4"

# Storage service/target IDs
STORAGE_SVC_ID_150="101"
STORAGE_TARGET_ID_150_1="1011"
STORAGE_TARGET_ID_150_2="1012"
STORAGE_SVC_ID_151="102"
STORAGE_TARGET_ID_151_1="1021"
STORAGE_TARGET_ID_151_2="1022"
STORAGE_SVC_ID_152="103"
STORAGE_TARGET_ID_152_1="1031"
STORAGE_TARGET_ID_152_2="1032"
