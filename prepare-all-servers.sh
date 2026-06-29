#!/bin/bash
set -euo pipefail

# ============================================================
# Prepare All Servers
#
# Runs prepare-servers.sh on the master (locally) and on
# all 3 slave servers (remotely via SSH).
#
# This script is designed to run ON the master server.
# If run from WSL, it first SSHes to the master and executes
# from there.
#
# Prerequisites: setup-ssh-keys.sh already completed
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

# --- Master (local machine) ---
echo "========================================"
echo "Preparing master server (local: ${MASTER_SERVER})"
echo "========================================"
echo ""

# Check if we're already on the master
if hostname -I 2>/dev/null | grep -q "${MASTER_SERVER}"; then
    sudo bash "${SCRIPT_DIR}/prepare-servers.sh"
else
    echo "Not on master. Copying scripts and running remotely..."
    scp_srv "${MASTER_SERVER}" "${SCRIPT_DIR}/prepare-servers.sh" /tmp/prepare-servers.sh
    scp_srv "${MASTER_SERVER}" "${SCRIPT_DIR}/config.sh" /tmp/beegfs-config.sh
    ssh_srv "${MASTER_SERVER}" "sudo bash /tmp/prepare-servers.sh"
fi
echo ""

# --- Slaves (remote machines) ---
echo "========================================"
echo "Preparing slave servers (remote)"
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
