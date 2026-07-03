#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Client (157):   mgmtd + meta + client 系统环境
# Slaves (150-152): meta + storage 系统环境 (含 XFS 磁盘准备)
#
# 从 WSL 通过 HK ECS 跳板执行。BeeGFS 包安装留给 deploy-beegfs.sh。
#
# Usage: bash prepare-all-servers.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

wait_ssh() {
    local ip=$1 max=60
    echo -n ">>> Waiting for SSH on ${ip}..."
    for i in $(seq 1 ${max}); do
        if [ "$ip" = "${CLIENT_SERVER}" ]; then
            if ssh_to_client "echo ok" 2>/dev/null; then echo " ready!"; return 0; fi
        else
            if ssh_to_slave "$ip" "echo ok" 2>/dev/null; then echo " ready!"; return 0; fi
        fi
        sleep 2; echo -n "."
    done
    echo " timeout!"; return 1
}

echo "========================================"
echo "Preparing all servers (client + slaves)"
echo "========================================"
echo ""

# 统一: 把 prepare-servers.sh 传到每台机器并执行
# - client(157) 用 PREPARE_ROLE=client: 跳过 storage 磁盘, 开 mgmtd/meta/client 端口
# - slaves 默认 role=slave: 准备 XFS 磁盘, 开 meta/storage 端口
for ip in "${ALL_SERVERS[@]}"; do
    echo ">>> ${ip}"
    wait_ssh "${ip}" || { echo "ERROR: Cannot SSH to ${ip}."; exit 1; }

    scp_to "${SCRIPT_DIR}/prepare-servers.sh" "${ip}" "/tmp/prepare-servers.sh"

    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "sudo PREPARE_ROLE=client bash /tmp/prepare-servers.sh"
    else
        ssh_to_slave "$ip" "sudo bash /tmp/prepare-servers.sh"
    fi
    echo ""
done

echo "========================================"
echo "All servers prepared."
echo ""
echo "Next: bash deploy-beegfs.sh deploy"
echo "========================================"
