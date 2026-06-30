#!/bin/bash
set -euo pipefail

# ============================================================
# BeeGFS Cluster Deployment (4 Physical Servers)
#
#   Master (10.20.1.157): mgmtd + meta + storage + client
#   Slave1 (10.20.1.150): meta + storage
#   Slave2 (10.20.1.151): meta + storage
#   Slave3 (10.20.1.152): meta + storage
#
# All servers use user 'sunrise'. Root commands use sudo.
#
# Usage: bash deploy-beegfs.sh [status|install|deploy|mount|unmount|test|all]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# --- Helpers ---

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

# ============================================================
# Step 0: Pre-flight checks
# ============================================================

preflight() {
    echo "========================================"
    echo "BeeGFS Deployment Pre-flight Checks"
    echo "========================================"
    echo "Client (IO only): ${CLIENT_SERVER}"
    echo "Slaves (services): ${SLAVE_SERVERS[*]}"
    echo ""

    # Check client server
    echo -n "  ${CLIENT_SERVER} (client): "
    if wait_ssh "${CLIENT_SERVER}" >/dev/null 2>&1; then
        ssh_srv "${CLIENT_SERVER}" "
            source /etc/os-release 2>/dev/null
            echo -n \"\${PRETTY_NAME:-unknown} | \"
            echo -n \"CPU: \$(nproc) | \"
            echo \"Mem: \$(free -h | awk '/^Mem:/{print \$2}')\"
        "
    else
        echo "UNREACHABLE"
        return 1
    fi

    # Check slave servers
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        if wait_ssh "${ip}" >/dev/null 2>&1; then
            ssh_srv "${ip}" "
                source /etc/os-release 2>/dev/null
                echo -n \"\${PRETTY_NAME:-unknown} | \"
                echo -n \"CPU: \$(nproc) | \"
                echo \"Mem: \$(free -h | awk '/^Mem:/{print \$2}')\"
            "
            # Check sudo
            if ssh_srv "${ip}" "sudo -n true" 2>/dev/null; then
                echo "    sudo: passwordless OK"
            else
                echo "    sudo: REQUIRES PASSWORD — run prepare-servers.sh first"
                return 1
            fi
        else
            echo "UNREACHABLE"
            return 1
        fi
    done
    echo ""
    echo "All servers reachable."
}

# ============================================================
# Step 1: Install BeeGFS packages on all servers
# ============================================================

install_packages() {
    echo ""
    echo ">>> Step 1: Installing BeeGFS packages on slaves..."

    # Only install on slaves, not on client (157)
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo "  >>> ${ip}..."
        ssh_srv "${ip}" "
        set -e

        # Add BeeGFS repository
        if [ ! -f /etc/apt/sources.list.d/beegfs.list ]; then
            echo '  Adding BeeGFS repo...'
            sudo wget -q -O /etc/apt/sources.list.d/beegfs.list \\
                '${BEEGFS_REPO_URL}' || {
                echo '  ERROR: failed to download repo list'
                exit 1
            }
            sudo wget -q -O /tmp/beegfs-gpg.asc '${BEEGFS_REPO_KEY}' || {
                echo '  ERROR: failed to download GPG key'
                exit 1
            }
            sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/beegfs.gpg /tmp/beegfs-gpg.asc 2>/dev/null || true
            rm -f /tmp/beegfs-gpg.asc
        fi

        sudo apt-get update -qq 2>/dev/null || true

        # Install BeeGFS packages
        # - beegfs-mgmtd: management service (master only, but harmless elsewhere)
        # - beegfs-meta: metadata service
        # - beegfs-storage: storage service
        # - beegfs-client: FUSE client (master only, but harmless elsewhere)
        # - beegfs-utils: CLI tools
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            beegfs-mgmtd beegfs-meta beegfs-storage beegfs-client beegfs-utils \
            >/dev/null 2>&1 || {
            echo '  ERROR: beegfs package install failed'
            exit 1
        }

        echo '  Done: $(beegfs-ctl --version 2>/dev/null | head -1)'
    "
done
    echo "  All packages installed."
}

# ============================================================
# Step 2: Configure and start mgmtd on slave1 (10.20.1.150)
# ============================================================

deploy_mgmtmtd() {
    echo ""
    echo ">>> Step 2: Deploying BeeGFS management service on ${BEEGFS_MGMTD_HOST}..."

    ssh_srv "${BEEGFS_MGMTD_HOST}" "
        set -e

        # Configure mgmtd
        sudo sed -i 's|^storeMgmtdDirectory.*|storeMgmtdDirectory=${BEEGFS_MGMTD_DIR}|' \
            /etc/beegfs/beegfs-mgmtd.conf 2>/dev/null || true

        # Ensure directory exists and is owned by beegfs
        sudo mkdir -p ${BEEGFS_MGMTD_DIR}
        sudo chown -R beegfs:beegfs ${BEEGFS_DATA_ROOT}

        # Stop if already running
        sudo systemctl stop beegfs-mgmtd 2>/dev/null || true

        # Run the setup helper if available
        if [ -x /opt/beegfs/sbin/beegfs-setup-mgmtd ]; then
            sudo /opt/beegfs/sbin/beegfs-setup-mgmtd -p ${BEEGFS_MGMTD_DIR} || true
        fi

        # Start mgmtd
        sudo systemctl enable beegfs-mgmtd
        sudo systemctl start beegfs-mgmtd

        sleep 3
        if sudo systemctl is-active --quiet beegfs-mgmtd; then
            echo '  mgmtd: RUNNING'
        else
            echo '  mgmtd: FAILED to start'
            sudo journalctl -u beegfs-mgmtd --no-pager | tail -20
            exit 1
        fi
    "
}

# ============================================================
# Step 3: Configure and start metadata services
# ============================================================

deploy_meta() {
    echo ""
    echo ">>> Step 3: Deploying BeeGFS metadata services on all servers..."

    for ip in "${ALL_SERVERS[@]}"; do
        echo "  >>> ${ip}..."
        ssh_srv "${ip}" "
            set -e

            # Configure meta to connect to mgmtd
            sudo sed -i 's|^storeMetaDirectory.*|storeMetaDirectory=${BEEGFS_META_DIR}|' \
                /etc/beegfs/beegfs-meta.conf 2>/dev/null || true
            sudo sed -i 's|^sysMgmtdHost.*|sysMgmtdHost=${BEEGFS_MGMTD_HOST}|' \
                /etc/beegfs/beegfs-meta.conf 2>/dev/null || true

            # Ensure directory
            sudo mkdir -p ${BEEGFS_META_DIR}
            sudo chown -R beegfs:beegfs ${BEEGFS_DATA_ROOT}

            # Stop if running
            sudo systemctl stop beegfs-meta 2>/dev/null || true

            # Setup meta service (only if not already initialized)
            if [ -x /opt/beegfs/sbin/beegfs-setup-meta ]; then
                if [ ! -f ${BEEGFS_META_DIR}/format ]; then
                    sudo /opt/beegfs/sbin/beegfs-setup-meta \
                        -p ${BEEGFS_META_DIR} \
                        -s ${ip##*.} \
                        -m ${BEEGFS_MGMTD_HOST} || true
                fi
            fi

            # Start meta
            sudo systemctl enable beegfs-meta
            sudo systemctl start beegfs-meta

            sleep 2
            if sudo systemctl is-active --quiet beegfs-meta; then
                echo '  meta: RUNNING'
            else
                echo '  meta: FAILED'
                sudo journalctl -u beegfs-meta --no-pager | tail -10
            fi
        "
    done
}

# ============================================================
# Step 4: Configure and start storage services
# ============================================================

deploy_storage() {
    echo ""
    echo ">>> Step 4: Deploying BeeGFS storage services..."
    echo "  Master: 1 storage target (RAID0)"
    echo "  Slaves: 2 storage targets each (独立NVMe)"

    # --- Master: single storage target (RAID0) ---
    echo ""
    echo "  >>> Deploying on master (${CLIENT_SERVER})..."
    ssh_srv "${CLIENT_SERVER}" "
        set -e

        # Configure storage (single path for RAID0)
        STORAGE_DIR='${BEEGFS_STORAGE_DIR_MASTER}'
        sudo sed -i 's|^storeStorageDirectory.*|storeStorageDirectory='\${STORAGE_DIR}'|' \
            /etc/beegfs/beegfs-storage.conf 2>/dev/null || true
        sudo sed -i 's|^sysMgmtdHost.*|sysMgmtdHost=${BEEGFS_MGMTD_HOST}|' \
            /etc/beegfs/beegfs-storage.conf 2>/dev/null || true

        # Ensure directory
        sudo mkdir -p \${STORAGE_DIR}
        sudo chown -R beegfs:beegfs /data/beegfs 2>/dev/null || true

        # Stop if running
        sudo systemctl stop beegfs-storage 2>/dev/null || true

        # Setup storage service
        if [ -x /opt/beegfs/sbin/beegfs-setup-storage ]; then
            if [ ! -f \${STORAGE_DIR}/format ]; then
                sudo /opt/beegfs/sbin/beegfs-setup-storage \
                    -p \${STORAGE_DIR} \
                    -s 157 \
                    -m ${BEEGFS_MGMTD_HOST} || true
            fi
        fi

        sudo systemctl enable beegfs-storage
        sudo systemctl start beegfs-storage

        sleep 2
        if sudo systemctl is-active --quiet beegfs-storage; then
            echo '  master storage: RUNNING'
        else
            echo '  master storage: FAILED'
            sudo journalctl -u beegfs-storage --no-pager | tail -10
        fi
    "

    # --- Slaves: two storage targets each ---
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo ""
        echo "  >>> Deploying on slave (${ip})... (2 targets)"

        # Target 1: /data/disk1
        ssh_srv "${ip}" "
            set -e

            STORAGE_DIR='${BEEGFS_STORAGE_DIR_SLAVE_1}'
            sudo sed -i 's|^storeStorageDirectory.*|storeStorageDirectory='\${STORAGE_DIR}'|' \
                /etc/beegfs/beegfs-storage.conf 2>/dev/null || true
            sudo sed -i 's|^sysMgmtdHost.*|sysMgmtdHost=${BEEGFS_MGMTD_HOST}|' \
                /etc/beegfs/beegfs-storage.conf 2>/dev/null || true

            sudo mkdir -p \${STORAGE_DIR}
            sudo chown -R beegfs:beegfs /data/disk1 2>/dev/null || true
            sudo chown -R beegfs:beegfs /data/disk2 2>/dev/null || true

            sudo systemctl stop beegfs-storage 2>/dev/null || true

            # First target: use node ID based on last byte of IP
            if [ ! -f \${STORAGE_DIR}/format ]; then
                sudo /opt/beegfs/sbin/beegfs-setup-storage \
                    -p \${STORAGE_DIR} \
                    -s \$(echo ${ip} | cut -d. -f4)01 \
                    -m ${BEEGFS_MGMTD_HOST} || true
            fi

            sudo systemctl enable beegfs-storage
            sudo systemctl start beegfs-storage
            sleep 3
        "

        # Target 2: /data/disk2 (需要第二个 beegfs-storage 服务)
        ssh_srv "${ip}" "
            set -e

            STORAGE_DIR='${BEEGFS_STORAGE_DIR_SLAVE_2}'

            # Create a second storage service config
            sudo cp /etc/beegfs/beegfs-storage.conf /etc/beegfs/beegfs-storage2.conf
            sudo sed -i 's|beegfs-storage|beegfs-storage2|g' /etc/beegfs/beegfs-storage2.conf
            sudo sed -i 's|^storeStorageDirectory.*|storeStorageDirectory='\${STORAGE_DIR}'|' /etc/beegfs/beegfs-storage2.conf
            sudo sed -i 's|^sysMgmtdHost.*|sysMgmtdHost=${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-storage2.conf

            # Use a different node ID (last byte + 02)
            NODE_ID=\$(echo ${ip} | cut -d. -f4)02

            # Create systemd service for second target
            sudo cp /lib/systemd/system/beegfs-storage.service /etc/systemd/system/beegfs-storage2.service
            sudo sed -i 's|beegfs-storage.service|beegfs-storage2.service|g' /etc/systemd/system/beegfs-storage2.service
            sudo sed -i 's|/etc/beegfs/beegfs-storage.conf|/etc/beegfs/beegfs-storage2.conf|g' /etc/systemd/system/beegfs-storage2.service
            sudo systemctl daemon-reload

            # Setup second target
            if [ ! -f \${STORAGE_DIR}/format ]; then
                sudo /opt/beegfs/sbin/beegfs-setup-storage \
                    -p \${STORAGE_DIR} \
                    -s \${NODE_ID} \
                    -c /etc/beegfs/beegfs-storage2.conf \
                    -m ${BEEGFS_MGMTD_HOST} || true
            fi

            sudo systemctl enable beegfs-storage2
            sudo systemctl start beegfs-storage2
            sleep 2

            if sudo systemctl is-active --quiet beegfs-storage2; then
                echo '  slave '\${ip}' storage2: RUNNING'
            else
                echo '  slave '\${ip}' storage2: FAILED'
            fi
        "

        # Verify both targets are running
        ssh_srv "${ip}" "
            echo '  storage targets:'
            sudo systemctl is-active beegfs-storage beegfs-storage2 | sed 's/^/    /'
        "
    done
}

# ============================================================
# Step 5: Configure and start client on master
# ============================================================

deploy_client() {
    echo ""
    echo ">>> Step 5: Deploying BeeGFS client on master..."

    ssh_srv "${CLIENT_SERVER}" "
        set -e

        # Configure client
        sudo sed -i 's|^sysMgmtdHost.*|sysMgmtdHost=${BEEGFS_MGMTD_HOST}|' \
            /etc/beegfs/beegfs-client.conf 2>/dev/null || true

        # Set mount point
        sudo mkdir -p ${BEEGFS_MOUNT_POINT}
        sudo chown \$(whoami):\$(whoami) ${BEEGFS_MOUNT_POINT}

        # Optional: set stripe pattern in beegfs-client.conf
        sudo sed -i 's|^tunePattern.*|tunePattern=${BEEGFS_STRIPE_PATTERN}|' \
            /etc/beegfs/beegfs-client.conf 2>/dev/null || true

        # Stop if running
        sudo systemctl stop beegfs-client 2>/dev/null || true
        sudo umount ${BEEGFS_MOUNT_POINT} 2>/dev/null || true

        # Start client (this mounts the filesystem)
        sudo systemctl enable beegfs-client
        sudo systemctl start beegfs-client

        sleep 5
        if mountpoint -q ${BEEGFS_MOUNT_POINT} 2>/dev/null; then
            echo '  client: MOUNTED'
            df -h ${BEEGFS_MOUNT_POINT}
        else
            echo '  client: FAILED to mount'
            sudo journalctl -u beegfs-client --no-pager | tail -20
            exit 1
        fi
    "
}

# ============================================================
# Status
# ============================================================

do_status() {
    echo "========================================"
    echo "BeeGFS Cluster Status"
    echo "========================================"
    echo ""

    for ip in "${ALL_SERVERS[@]}"; do
        echo ">>> ${ip} ($(ssh_srv "${ip}" 'hostname' 2>/dev/null))"
        ssh_srv "${ip}" "
            echo '  mgmtd:   '\$(sudo systemctl is-active beegfs-mgmtd 2>/dev/null || echo 'not installed')
            echo '  meta:    '\$(sudo systemctl is-active beegfs-meta 2>/dev/null || echo 'not installed')
            echo '  storage: '\$(sudo systemctl is-active beegfs-storage 2>/dev/null || echo 'not installed')
            echo '  client:  '\$(sudo systemctl is-active beegfs-client 2>/dev/null || echo 'not installed')
        " 2>/dev/null
        echo ""
    done

    # Show cluster info from master
    echo ">>> Cluster nodes:"
    ssh_srv "${CLIENT_SERVER}" "
        sudo beegfs-ctl --listnodes --nodetype=meta --mgmtd_node=${BEEGFS_MGMTD_HOST} 2>/dev/null || true
        echo ''
        sudo beegfs-ctl --listnodes --nodetype=storage --mgmtd_node=${BEEGFS_MGMTD_HOST} 2>/dev/null || true
        echo ''
        sudo beegfs-ctl --listtargets --nodetype=storage --mgmtd_node=${BEEGFS_MGMTD_HOST} 2>/dev/null || true
    " 2>/dev/null

    echo ""
    echo ">>> Client mount:"
    if ssh_srv "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        ssh_srv "${CLIENT_SERVER}" "df -h ${BEEGFS_MOUNT_POINT}" 2>/dev/null
    else
        echo "  Not mounted"
    fi
}

# ============================================================
# Mount / Unmount
# ============================================================

do_mount() {
    echo ">>> Mounting BeeGFS on master..."
    ssh_srv "${CLIENT_SERVER}" "
        sudo mkdir -p ${BEEGFS_MOUNT_POINT}
        sudo systemctl restart beegfs-client
        sleep 3
        if mountpoint -q ${BEEGFS_MOUNT_POINT}; then
            echo '  Mounted!'
            df -h ${BEEGFS_MOUNT_POINT}
        else
            echo '  ERROR: mount failed'
            sudo journalctl -u beegfs-client --no-pager | tail -10
            exit 1
        fi
    "
}

do_unmount() {
    echo ">>> Unmounting BeeGFS on master..."
    ssh_srv "${CLIENT_SERVER}" "
        sudo systemctl stop beegfs-client 2>/dev/null || true
        sudo umount ${BEEGFS_MOUNT_POINT} 2>/dev/null || true
        echo '  Unmounted.'
    "
}

# ============================================================
# Smoke Test
# ============================================================

do_test() {
    echo "========================================"
    echo "BeeGFS Smoke Test"
    echo "========================================"

    if ! ssh_srv "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        do_mount
    fi

    ssh_srv "${CLIENT_SERVER}" "
        echo ''
        echo '>>> Write test...'
        echo 'BeeGFS production test - '\$(date) > ${BEEGFS_MOUNT_POINT}/hello.txt
        dd if=/dev/urandom of=${BEEGFS_MOUNT_POINT}/random.bin bs=1M count=100 2>&1 | tail -1

        echo ''
        echo '>>> Read verification...'
        grep -q 'production test' ${BEEGFS_MOUNT_POINT}/hello.txt && echo '  PASS: Text file' || echo '  FAIL: Text file'
        SIZE=\$(stat -c%s ${BEEGFS_MOUNT_POINT}/random.bin)
        [ \"\${SIZE}\" -eq 104857600 ] && echo '  PASS: Binary (100MB)' || echo '  FAIL: Binary size=\${SIZE}'

        echo ''
        echo '>>> Storage info:'
        beegfs-df 2>/dev/null || true

        echo ''
        echo '>>> Cleanup...'
        rm -f ${BEEGFS_MOUNT_POINT}/hello.txt ${BEEGFS_MOUNT_POINT}/random.bin
        echo '  Done.'
    "
}

# ============================================================
# Main
# ============================================================

ACTION="${1:-status}"

case "${ACTION}" in
    status)
        do_status
        ;;
    install)
        preflight
        install_packages
        ;;
    deploy)
        preflight
        install_packages
        deploy_mgmtmtd
        deploy_meta
        deploy_storage
        deploy_client
        echo ""
        echo "========================================"
        echo "BeeGFS Deployment Complete!"
        echo "========================================"
        do_status
        ;;
    mount)
        do_mount
        ;;
    unmount)
        do_unmount
        ;;
    test)
        do_test
        ;;
    all)
        preflight
        install_packages
        deploy_mgmtmtd
        deploy_meta
        deploy_storage
        deploy_client
        echo ""
        echo "========================================"
        echo "BeeGFS Deployment Complete!"
        echo "========================================"
        do_status
        do_test
        ;;
    *)
        echo "Usage: bash deploy-beegfs.sh [status|install|deploy|mount|unmount|test|all]"
        echo ""
        echo "  status   - Show cluster status"
        echo "  install  - Install BeeGFS packages"
        echo "  deploy   - Full deployment (install + configure + start all services)"
        echo "  mount    - Mount filesystem on master"
        echo "  unmount  - Unmount filesystem"
        echo "  test     - Run smoke test"
        echo "  all      - Deploy + test"
        ;;
esac
