#!/bin/bash
set -euo pipefail

# ============================================================
# SSH Key Setup for BeeGFS Production Deployment
#
# Generates SSH key pair on master and distributes to all
# slave servers for passwordless access.
#
# Run from the master server (via WSL jump host).
#
# Usage: bash setup-ssh-keys.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

KEY_FILE="${SSH_KEY}"

# ============================================================
# Step 1: Generate SSH key if missing
# ============================================================

echo "========================================"
echo "SSH Key Setup for BeeGFS Deployment"
echo "========================================"
echo ""

if [ -f "${KEY_FILE}" ]; then
    echo "[skip] SSH key already exists: ${KEY_FILE}"
else
    echo ">>> Generating ED25519 key pair..."
    ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "beegfs-deploy-$(date +%Y%m%d)"
    echo "   Created: ${KEY_FILE}"
    echo "   Created: ${KEY_FILE}.pub"
fi

echo ""
echo "Public key:"
cat "${KEY_FILE}.pub"
echo ""

# ============================================================
# Step 2: Copy key to slave servers
# ============================================================

for ip in "${SLAVE_SERVERS[@]}"; do
    echo "========================================"
    echo ">>> Copying SSH key to ${SSH_USER}@${ip}"
    echo "========================================"
    sshpass -p "${SSH_PASSWORD}" ssh-copy-id -i "${KEY_FILE}.pub" \
        -o StrictHostKeyChecking=no "${SSH_USER}@${ip}" || {
        echo ""
        echo "ERROR: ssh-copy-id failed for ${ip}."
        exit 1
    }
    echo "   Key installed on ${ip}."
    echo ""
done

# ============================================================
# Step 3: Verify
# ============================================================

echo "========================================"
echo "Verifying SSH access..."
echo "========================================"

all_ok=true
for ip in "${SLAVE_SERVERS[@]}"; do
    echo -n "  ${SSH_USER}@${ip}: "
    if ssh ${SSH_OPTS} -i "${KEY_FILE}" -o BatchMode=yes "${SSH_USER}@${ip}" "echo OK" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        all_ok=false
    fi
done

echo ""
if ${all_ok}; then
    echo "All slave servers accessible without password."
    echo ""
    echo "Next: bash prepare-all-servers.sh"
else
    echo "Some servers still require a password. Re-run this script or check manually."
    exit 1
fi
