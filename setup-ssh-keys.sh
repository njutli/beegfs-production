#!/bin/bash
set -euo pipefail

# ============================================================
# SSH Key Setup for BeeGFS Production Deployment
#
# 从 WSL 通过 HK ECS 跳板分发 SSH 密钥到所有服务器。
#
# 流程:
#   1. 本地生成密钥
#   2. 通过 HK ECS 跳板 ssh-copy-id 到 client (157)
#   3. 在 client 上生成密钥，再分发给 slaves (150-152)
#
# Usage: bash setup-ssh-keys.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

LOCAL_KEY="${SSH_KEY}"

echo "========================================"
echo "SSH Key Setup for BeeGFS Deployment"
echo "========================================"
echo ""

# ============================================================
# Step 1: Generate local SSH key if missing
# ============================================================

if [ -f "${LOCAL_KEY}" ]; then
    echo "[skip] Local SSH key already exists: ${LOCAL_KEY}"
else
    echo ">>> Generating ED25519 key pair locally..."
    ssh-keygen -t ed25519 -f "${LOCAL_KEY}" -N "" -C "beegfs-deploy-$(date +%Y%m%d)"
fi

echo ""

# ============================================================
# Step 2: Copy local key to client (157) via HK ECS
# ============================================================

echo "========================================"
echo ">>> Step 2: Copying key to client ${CLIENT_SERVER} (${CLIENT_EXT}:${CLIENT_PORT})"
echo "========================================"

# Step 2a: Copy local public key to HK ECS
sshpass -p "${HK_ECS_PASSWORD}" ssh-copy-id -i "${LOCAL_KEY}.pub" \
    ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" || {
    echo "ERROR: ssh-copy-id to HK ECS failed."
    exit 1
}

# Step 2b: Copy HK ECS → client (157)
sshpass -p "${HK_ECS_PASSWORD}" ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
    "sshpass -p '${SSH_PASSWORD}' ssh-copy-id -i '${SSH_KEY}.pub' \
        ${SSH_OPTS} -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}'" || {
    echo "ERROR: ssh-copy-id to client failed."
    exit 1
}
echo "   Key installed on client ${CLIENT_SERVER}."
echo ""

# ============================================================
# Step 3: On client, generate key (if missing) and copy to slaves
# ============================================================

for ip in "${SLAVE_SERVERS[@]}"; do
    echo "========================================"
    echo ">>> Step 3: Copying key to ${SSH_USER}@${ip} (via client jump)"
    echo "========================================"
    ssh_to_client "
        if [ ! -f '${SSH_KEY}' ]; then
            ssh-keygen -t ed25519 -f '${SSH_KEY}' -N '' -C 'beegfs-deploy-\$(date +%Y%m%d)'
        fi
        sshpass -p '${SSH_PASSWORD}' ssh-copy-id -i '${SSH_KEY}.pub' \
            ${SSH_OPTS} '${SSH_USER}@${ip}'
    " || {
        echo "ERROR: ssh-copy-id failed for ${ip}."
        exit 1
    }
    echo "   Key installed on ${ip}."
    echo ""
done

# ============================================================
# Step 4: Verify
# ============================================================

echo "========================================"
echo "Verifying SSH access..."
echo "========================================"

all_ok=true

echo -n "  ${SSH_USER}@${CLIENT_SERVER} (via jump): "
if ssh_to_client "echo OK" 2>/dev/null; then
    echo "OK"
else
    echo "FAILED"
    all_ok=false
fi

for ip in "${SLAVE_SERVERS[@]}"; do
    echo -n "  ${SSH_USER}@${ip} (via client jump): "
    if ssh_to_slave "${ip}" "echo OK" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        all_ok=false
    fi
done

echo ""
if ${all_ok}; then
    echo "All servers accessible without password."
    echo ""
    echo "Next: bash prepare-all-servers.sh"
else
    echo "Some servers still require a password."
    exit 1
fi
