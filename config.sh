#!/bin/bash
# ============================================================
# BeeGFS Production Deployment Configuration (4 Machines)
#
# 架构说明 (官方最佳实践 + 镜像):
#   157 (mgmtd + meta + client):  nvme1n1(894G ext4) → metadata；mgmtd 用 SQLite
#   150 (meta + storage):    nvme1n1(894G ext4) → metadata
#                           nvme2n1(7T XFS) + nvme3n1(7T XFS) → 2 storage targets
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
# 官方文档: https://doc.beegfs.io/7.3.2/
# ============================================================

# --- Client + Metadata Server (157) ---
# 157 运行 client + metadata 服务 (用空闲的 nvme1n1)
# 不运行 storage 服务，不影响现有业务
CLIENT_SERVER="10.20.1.157"
CLIENT_EXT="203.156.3.194"
CLIENT_PORT="19891"

# --- Slave Servers (meta + storage) ---
SLAVE_SERVERS=(
  "10.20.1.150"  # meta + 2 storage
  "10.20.1.151"  # meta + 2 storage
  "10.20.1.152"  # meta + 2 storage
)

# All servers with metadata service (4 nodes, 偶数 for mirroring)
META_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# All servers
ALL_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

# --- BeeGFS Version ---
# 使用 BeeGFS 7.3.2 (镜像免费, 不需 license; 8.x 镜像需付费 license)
BEEGFS_MAJOR_VERSION="7"
BEEGFS_RELEASE_VERSION="7.3.2"

# --- BeeGFS Service Hosts ---
BEEGFS_MGMTD_HOST="10.20.1.157"
# 7.x: mgmtd 监听 8008 (BeeMsg), beegfs-ctl 通过 .conf 文件连 mgmtd (无 gRPC)
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

# Management: 7.x uses directory (beegfs-setup-mgmtd -p), not SQLite
# 用 /var/lib/beegfs/mgmtd 子目录, 避免与 /var/lib/beegfs/client (beegfs-client 包创建) 冲突
BEEGFS_MGMTD_DB="/var/lib/beegfs/mgmtd"

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
#
# 三层跳板 (WSL→HK→157→slave) 引号陷阱: 单层 base64 的 'echo X|base64 -d|bash'
# 在第二跳被 ssh 拼接时单引号剥离, 管道会在 157 上执行而非 slave 上 (命令跑错机器, 静默)。
# 解法: 双层 base64 —
#   1) slave 命令 → b64_slave
#   2) "157 上 ssh 到 slave 并 decode+exec" 整条 → b64_157
#   3) HK→157 用 ssh_to_client 的可靠单层模式传 b64_157; 157 decode 得到 cmd_157,
#      由 157 的 bash 执行 (cmd_157 内含对 slave 的 ssh, 单引号此时由 157 bash 正确解析)。
ssh_to_slave() {
    local ip=$1
    local cmd="$2"
    local b64_slave b64_157 cmd_157
    b64_slave=$(echo -n "$cmd" | base64 -w0)
    cmd_157="sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T ${SSH_USER}@${ip} 'echo ${b64_slave} | base64 -d | bash'"
    b64_157=$(echo -n "$cmd_157" | base64 -w0)
    sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh ${SSH_OPTS} -T -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ${b64_157} | base64 -d | bash'"
}

# 传文件到远程 (把文件内容 base64 编码进命令, 远程 decode 写入)
# 注意: 不能用 "cat > file" < localfile — ssh_to_* 的 base64 管道会占用 stdin, 导致传空文件(静默失败)。
# Usage: scp_to <src_local> <dest_ip> <dest_path>
scp_to() {
    local src=$1 ip=$2 dest=$3
    local b64
    b64=$(base64 -w0 "$src")
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "echo '${b64}' | base64 -d > '${dest}'"
    else
        ssh_to_slave "$ip" "echo '${b64}' | base64 -d > '${dest}'"
    fi
}

# --- Network ---
# BeeGFS 走默认路由 = 10GbE 管理网 (eno12399, 10.20.1.0/24)。
# 100GbE (enp139s0f0np0, 10.3.1.0/24) 不用于 BeeGFS 数据通道。
# 性能对比测试时用 limit-bandwidth.sh 把 10GbE 限速到 1Gbps 模拟千兆环境。
BEEGFS_CONN_INTERFACES=""
BEEGFS_CONN_INTERFACES_FILE="/etc/beegfs/conninf.conf"

# --- TLS & Authentication (7.x: connDisableAuthentication in .conf files) ---
# 7.x: 所有服务 (mgmtd/meta/storage/client) 用 .conf 文件, 设 connDisableAuthentication = true
# beegfs-ctl 读 /etc/beegfs/beegfs-ctl.conf 里的 sysMgmtdHost + connDisableAuthentication
BEEGFS_AUTH_DISABLE="true"

# --- Tuning (per official docs) ---
# Stripe pattern: buddymirror (7.x: --pattern=buddymirror)
BEEGFS_STRIPE_PATTERN="buddymirror"
BEEGFS_STRIPE_SIZE="1M"
# Stripe count = number of buddy groups = 3 (storage)
BEEGFS_STRIPE_COUNT="3"

# --- XFS Mount Options (per official storage tuning docs) ---
BEEGFS_XFS_MOUNT_OPTS="noatime,nodiratime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,allocsize=131072k"

# --- Repo (BeeGFS 7.3.2, Ubuntu 22.04 jammy) ---
BEEGFS_REPO_DIST="jammy"
BEEGFS_REPO_URL="https://www.beegfs.io/release/beegfs_${BEEGFS_RELEASE_VERSION}/dists/beegfs-${BEEGFS_REPO_DIST}.list"
BEEGFS_REPO_KEYRING="/usr/share/keyrings/beegfs.gpg"
BEEGFS_REPO_LIST="/etc/apt/sources.list.d/beegfs.list"

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
