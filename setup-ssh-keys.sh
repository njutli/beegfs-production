#!/bin/bash
set -euo pipefail

# ============================================================
# SSH Key Setup for BeeGFS Production Deployment
#
# 从 WSL 通过 HK ECS 跳板分发 SSH 密钥到所有服务器。
#
# 流程:
#   1. WSL 密钥 -> HK ECS 跳板机
#   2. HK ECS -> client (157)
#   3. client (157) 上生成密钥 -> slaves (150-152)
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
# Step 2: Copy local key to HK ECS (if not already done)
# ============================================================

echo "========================================"
echo ">>> Step 2: Copying key to HK ECS jump (${HK_ECS})"
echo "========================================"

if ssh -o BatchMode=yes -o ConnectTimeout=5 "${HK_ECS_USER}@${HK_ECS}" "echo ok" 2>/dev/null; then
    echo "  [skip] Already configured."
else
    sshpass -p "${HK_ECS_PASSWORD}" ssh-copy-id -f -i "${LOCAL_KEY}.pub" \
        ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}"
    echo "  Key installed on HK ECS."
fi
echo ""

# ============================================================
# Step 3: Copy local key to client (157) via HK ECS
# ============================================================

echo "========================================"
echo ">>> Step 3: Copying key to client ${CLIENT_SERVER} (${CLIENT_EXT}:${CLIENT_PORT})"
echo "========================================"

# Check if already configured
if ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
    "ssh -o BatchMode=yes -o ConnectTimeout=5 -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo ok'" 2>/dev/null; then
    echo "  [skip] Already configured."
else
    # Copy local pub key to HK ECS, then ssh-copy-id to client
    ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" "cat > /tmp/beegfs-client-pubkey.pub" < "${LOCAL_KEY}.pub"
    ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "sshpass -p '${SSH_PASSWORD}' ssh-copy-id -f -i /tmp/beegfs-client-pubkey.pub \
            ${SSH_OPTS} -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' && \
         rm -f /tmp/beegfs-client-pubkey.pub"
    echo "  Key installed on client ${CLIENT_SERVER}."
fi
echo ""

# ============================================================
# Step 4: On client, generate key and copy to slaves
# ============================================================

echo "========================================"
echo ">>> Step 4: Setup keys from client to slaves"
echo "========================================"

for ip in "${SLAVE_SERVERS[@]}"; do
    echo "--- ${ip} ---"

    # Check if slave is already reachable from client via key
    if ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "ssh ${SSH_OPTS} -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' \
            'ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_OPTS} ${SSH_USER}@${ip} \"echo ok\"'" 2>/dev/null; then
        echo "  [skip] Already configured."
        continue
    fi

    # Generate key on client if not exists, then ssh-copy-id to slave
    ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "ssh ${SSH_OPTS} -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' \
            'if [ ! -f ~/.ssh/id_ed25519 ]; then
               ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N \"\" -C beegfs-deploy-\$(date +%Y%m%d) >/dev/null 2>&1
             fi
             sshpass -p \"${SSH_PASSWORD}\" ssh-copy-id -f ${SSH_OPTS} ${SSH_USER}@${ip} 2>&1 | tail -1'"
    echo "  Key installed on ${ip}."
done

# ============================================================
# Step 5: Verify
# ============================================================

echo ""
echo "========================================"
echo "Verifying SSH access..."
echo "========================================"

all_ok=true

echo -n "  ${SSH_USER}@${CLIENT_SERVER}: "
if ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
    "ssh -o BatchMode=yes ${SSH_OPTS} -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' 'echo OK'" 2>/dev/null; then
    echo "OK"
else
    echo "FAILED"
    all_ok=false
fi

for ip in "${SLAVE_SERVERS[@]}"; do
    echo -n "  ${SSH_USER}@${ip}: "
    if ssh ${SSH_OPTS} "${HK_ECS_USER}@${HK_ECS}" \
        "ssh -o BatchMode=yes ${SSH_OPTS} -p '${CLIENT_PORT}' '${SSH_USER}@${CLIENT_EXT}' \
            'ssh -o BatchMode=yes ${SSH_OPTS} ${SSH_USER}@${ip} \"echo OK\"'" 2>/dev/null; then
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
