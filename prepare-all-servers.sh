#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Client (157): 只准备客户端环境，不部署服务
# Slaves (150-152): 准备完整的 BeeGFS 服务环境
#
# Usage: bash prepare-all-servers.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

ssh_srv() {
    local ip=$1; shift
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" "$@"
}

scp_srv() {
    local ip=$1 local_file=$2 remote_path=$3
    scp ${SSH_OPTS} -i "${SSH_KEY}" "${local_file}" "${SSH_USER}@${ip}:${remote_path}"
}

wait_ssh() {
    local ip=$1 max=60
    echo -n ">>> Waiting for SSH on ${ip}..."
    for i in $(seq 1 ${max}); do
        if ssh_srv "${ip}" "echo ok" 2>/dev/null; then echo " ready!"; return 0; fi
        sleep 2; echo -n "."
    done
    echo " timeout!"; return 1
}

# --- Client server (157) - only prepare client packages ---
echo "========================================"
echo "Preparing client server (${CLIENT_SERVER})"
echo "========================================"
echo ""

# Install only client packages on 157, no service configuration
ssh_srv "${CLIENT_SERVER}" "
    set -e
    # Install beegfs-client only
    if ! command -v beegfs-ctl &>/dev/null; then
        sudo wget -q -O /etc/apt/sources.list.d/beegfs.list '${BEEGFS_REPO_URL}' || true
        sudo wget -q -O /tmp/beegfs-gpg.asc '${BEEGFS_REPO_KEY}' || true
        sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/beegfs.gpg /tmp/beegfs-gpg.asc 2>/dev/null || true
        rm -f /tmp/beegfs-gpg.asc
        sudo apt-get update -qq 2>/dev/null || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y beegfs-client beegfs-utils >/dev/null 2>&1 || true
    fi
    echo '  Client packages ready'
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

    scp_srv "${ip}" "${SCRIPT_DIR}/prepare-servers.sh" /tmp/prepare-servers.sh
    ssh_srv "${ip}" "sudo bash /tmp/prepare-servers.sh"
    echo ""
done

echo "========================================"
echo "All servers prepared."
echo ""
echo "Next: bash deploy-beegfs.sh"
echo "========================================"
