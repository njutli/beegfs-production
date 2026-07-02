#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Client (157):   mgmtd + meta + client 环境
# Slaves (150-152): BeeGFS 服务环境 (meta + storage)
#
# 从 WSL 通过 HK ECS 跳板执行。
#
# Usage: bash prepare-all-servers.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

wait_ssh() {
    local ip=$1 max=60
    echo -n ">>> Waiting for SSH on ${ip}..."
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        for i in $(seq 1 ${max}); do
            if ssh_to_client "echo ok" 2>/dev/null; then echo " ready!"; return 0; fi
            sleep 2; echo -n "."
        done
    else
        for i in $(seq 1 ${max}); do
            if ssh_to_slave "$ip" "echo ok" 2>/dev/null; then echo " ready!"; return 0; fi
            sleep 2; echo -n "."
        done
    fi
    echo " timeout!"; return 1
}

# --- Client server (157) - prepare mgmtd + meta + client ---
echo "========================================"
echo "Preparing client server (${CLIENT_SERVER})"
echo "========================================"
echo ""

ssh_to_client "
    set -e
    if ! command -v beegfs-ctl &>/dev/null; then
        sudo wget -q -O /etc/apt/sources.list.d/beegfs.list '${BEEGFS_REPO_URL}'
        sudo wget -q -O /tmp/beegfs-gpg.asc '${BEEGFS_REPO_KEY}'
        sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/beegfs.gpg /tmp/beegfs-gpg.asc 2>/dev/null
        rm -f /tmp/beegfs-gpg.asc
        sudo apt-get update -qq 2>/dev/null
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y beegfs-mgmtd beegfs-meta beegfs-client beegfs-utils >/dev/null 2>&1
    fi
    echo '  Client (mgmtd+meta+client) packages ready'
"
echo ""

# --- Slaves (150-152) ---
echo "========================================"
echo "Preparing slave servers (${SLAVE_SERVERS[*]})"
echo "========================================"
echo ""

for ip in "${SLAVE_SERVERS[@]}"; do
    echo ">>> ${ip}"
    wait_ssh "${ip}" || { echo "ERROR: Cannot SSH to ${ip}."; exit 1; }

    # Copy prepare-servers.sh via client jump
    ssh_to_client "cat > /tmp/prepare-servers.sh" < "${SCRIPT_DIR}/prepare-servers.sh"
    ssh_to_slave "${ip}" "sudo bash /tmp/prepare-servers.sh"
    echo ""
done

echo "========================================"
echo "All servers prepared."
echo ""
echo "Next: bash deploy-beegfs.sh"
echo "========================================"
