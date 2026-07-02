#!/bin/bash
set -euo pipefail

# ============================================================
# BeeGFS Cluster Deployment (4 Physical Servers, with Mirroring)
#
# Architecture:
#   157 (mgmtd + meta + client): nvme1n1(ext4) → metadata, local mgmtd
#   150 (meta + storage):    nvme1n1(ext4) + 2×XFS
#   151 (meta + storage):    nvme1n1(ext4) + 2×XFS
#   152 (meta + storage):    nvme1n1(ext4) + 2×XFS
#
# Mirroring:
#   Metadata: 2 buddy groups (4 meta nodes)
#   Storage:  3 buddy groups (6 targets)
#
# Official docs: https://doc.beegfs.io/latest/
#
# Usage: bash deploy-beegfs.sh [status|install|deploy|mount|unmount|test|all]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# --- Helpers ---

# Run a command on a remote server, stripping motd from stdout.
# motd is sent to stderr with sshpass + ssh -T; stderr is discarded,
# only the actual command output (stdout) is returned.
_run() {
    local ip=$1; shift
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "$@" 2>/dev/null
    else
        ssh_to_slave "$ip" "$@" 2>/dev/null
    fi
}

wait_ssh() {
    local ip=$1 max=60
    echo -n ">>> Waiting for SSH on ${ip}..."
    local sv
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        sv=ssh_to_client
    else
        sv="ssh_to_slave $ip"
    fi
    for i in $(seq 1 ${max}); do
        if $sv "echo ok" 2>/dev/null 1>&2; then echo " ready!"; return 0; fi
        sleep 2; echo -n "."
    done
    echo " timeout!"; return 1
}

_scp_to() {
    local src=$1 ip=$2 dest=$3
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "cat > '$dest'" < "$src"
    else
        ssh_to_slave "$ip" "cat > '$dest'" < "$src"
    fi
}

# ============================================================
# Step 0: Pre-flight checks
# ============================================================

preflight() {
    echo "========================================"
    echo "BeeGFS Deployment Pre-flight Checks"
    echo "========================================"
    echo "Client+Meta+MGM (157): ${CLIENT_SERVER} (mgmtd + meta + client)"
    echo "Slaves (meta+storage): ${SLAVE_SERVERS[*]}"
    echo "Mirroring: enabled (metadata + storage)"
    echo ""

    for ip in "${ALL_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        if wait_ssh "${ip}" >/dev/null 2>&1; then
            _run "${ip}" "
                source /etc/os-release 2>/dev/null
                echo -n \"\${PRETTY_NAME:-unknown} | \"
                echo -n \"CPU: \$(nproc) | \"
                echo \"Mem: \$(free -h | awk '/^Mem:/{print \$2}')\"
            "
        else
            echo "UNREACHABLE"
            return 1
        fi
    done

    # Check disk layout on slaves
    echo ""
    echo ">>> Disk layout check:"
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo "  ${ip}:"
        _run "${ip}" "
            echo '    nvme1n1 (meta): '\$(mount | grep nvme1n1 | awk '{print \$3}' || echo 'NOT MOUNTED')
            echo '    disk1 (storage): '\$(mount | grep disk1 | awk '{print \$3}' || echo 'NOT MOUNTED')
            echo '    disk2 (storage): '\$(mount | grep disk2 | awk '{print \$3}' || echo 'NOT MOUNTED')
        " 2>/dev/null
    done
    echo ""
}

# ============================================================
# Step 1: Install BeeGFS packages
# ============================================================

install_packages() {
    echo ""
    echo ">>> Step 1: Installing BeeGFS ${BEEGFS_MAJOR_VERSION}.x packages..."

    # Slaves: meta + storage + client + tools (no mgmtd)
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo "  >>> ${ip} (meta + storage)..."
        _run "${ip}" "
            set -e
            if [ ! -f /etc/apt/sources.list.d/beegfs.list ]; then
                sudo rm -f /etc/apt/sources.list.d/beegfs.list /usr/share/keyrings/beegfs.gpg
                curl -fsSL 'https://www.beegfs.io/release/beegfs_8.3/gpg/GPG-KEY-beegfs' | sudo gpg --batch --no-tty --dearmor -o /usr/share/keyrings/beegfs.gpg 2>/dev/null
                echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/beegfs.gpg] https://www.beegfs.io/release/beegfs_8.3 jammy non-free' | sudo tee /etc/apt/sources.list.d/beegfs.list >/dev/null
            fi
            sudo apt-get update -qq 2>/dev/null
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                beegfs-meta beegfs-storage beegfs-client beegfs-tools beegfs-utils \
                -qq 2>/dev/null
            echo '  Done: \$(beegfs-ctl --version 2>/dev/null | head -1 || echo installed)'
        "
    done

    # Client (157): mgmtd + meta + client + tools
    echo "  >>> ${CLIENT_SERVER} (mgmtd + meta + client)..."
    _run "${CLIENT_SERVER}" "
        set -e
        if [ ! -f /etc/apt/sources.list.d/beegfs.list ]; then
            sudo rm -f /etc/apt/sources.list.d/beegfs.list /usr/share/keyrings/beegfs.gpg
            curl -fsSL 'https://www.beegfs.io/release/beegfs_8.3/gpg/GPG-KEY-beegfs' | sudo gpg --batch --no-tty --dearmor -o /usr/share/keyrings/beegfs.gpg 2>/dev/null
            echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/beegfs.gpg] https://www.beegfs.io/release/beegfs_8.3 jammy non-free' | sudo tee /etc/apt/sources.list.d/beegfs.list >/dev/null
        fi
        sudo apt-get update -qq 2>/dev/null
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            beegfs-mgmtd libbeegfs-license \
            beegfs-meta beegfs-client beegfs-tools beegfs-utils \
            -qq 2>/dev/null
        echo '  Done: \$(beegfs-ctl --version 2>/dev/null | head -1 || echo installed)'
    "
    echo "  All packages installed."
}

# ============================================================
# Step 2: Configure TLS and Auth (disable for testing)
# ============================================================

configure_tls_auth() {
    echo ""
    echo ">>> Step 2: Configuring TLS and Auth..."
    echo "    BeeGFS 8.x uses .conf files. Setting connDisableAuthentication = true for all services."

    for ip in "${ALL_SERVERS[@]}"; do
        echo "  >>> ${ip}..."
        # mgmtd uses .toml format with auth-disable/tls-disable
        _run "${ip}" "
            if [ -f /etc/beegfs/beegfs-mgmtd.toml ]; then
                sudo sed -i 's|^# auth-disable = false|auth-disable = true|' /etc/beegfs/beegfs-mgmtd.toml 2>/dev/null || true
                sudo sed -i 's|^# tls-disable = false|tls-disable = true|' /etc/beegfs/beegfs-mgmtd.toml 2>/dev/null || true
            fi
        " 2>/dev/null
        # meta/storage/client use .conf format with connDisableAuthentication
        for conf in beegfs-meta.conf beegfs-storage.conf beegfs-client.conf; do
            _run "${ip}" "
                if [ -f /etc/beegfs/${conf} ]; then
                    sudo sed -i 's|^connDisableAuthentication[[:space:]]*=[[:space:]]*false|connDisableAuthentication    = true|' /etc/beegfs/${conf}
                fi
            " 2>/dev/null
        done
    done
    echo "  TLS and Auth disabled (testing mode)."
}

# ============================================================
# Step 3: Deploy mgmtd on client (157)
# ============================================================

deploy_mgmtmtd() {
    echo ""
    echo ">>> Step 3: Deploying management service on ${BEEGFS_MGMTD_HOST}..."

    _run "${BEEGFS_MGMTD_HOST}" "
        set -e
        sudo systemctl stop beegfs-mgmtd 2>/dev/null || true

        # 8.x: mgmtd uses SQLite database, init with --init
        if [ -x /opt/beegfs/sbin/beegfs-mgmtd ]; then
            if [ ! -f ${BEEGFS_MGMTD_DB} ]; then
                sudo mkdir -p /var/lib/beegfs
                sudo /opt/beegfs/sbin/beegfs-mgmtd --init
            fi
        elif [ -x /opt/beegfs/sbin/beegfs-setup-mgmtd ]; then
            # 7.x fallback
            if [ ! -f /data/beegfs/mgmtd/format ]; then
                sudo mkdir -p /data/beegfs/mgmtd
                sudo /opt/beegfs/sbin/beegfs-setup-mgmtd -p /data/beegfs/mgmtd || true
            fi
        fi

        sudo systemctl enable beegfs-mgmtd
        sudo systemctl start beegfs-mgmtd
        sleep 3

        if sudo systemctl is-active --quiet beegfs-mgmtd; then
            echo '  mgmtd: RUNNING'
        else
            echo '  mgmtd: FAILED'
            sudo journalctl -u beegfs-mgmtd --no-pager | tail -20
            exit 1
        fi
    "
}

# ============================================================
# Step 4: Deploy metadata services (4 nodes: 157, 150, 151, 152)
# ============================================================

deploy_meta() {
    echo ""
    echo ">>> Step 4: Deploying metadata services (4 nodes)..."

    # 157 (client + meta)
    echo "  >>> ${CLIENT_SERVER} (meta, ID=${META_NODE_ID_157})..."
    _run "${CLIENT_SERVER}" "
        set -e
        sudo mkdir -p ${BEEGFS_META_DIR}
        sudo chown -R beegfs:beegfs /mnt/beegfs-meta 2>/dev/null || true

        sudo systemctl stop beegfs-meta 2>/dev/null || true

        if [ ! -f ${BEEGFS_META_DIR}/format ]; then
            sudo /opt/beegfs/sbin/beegfs-setup-meta \
                -p ${BEEGFS_META_DIR} \
                -s ${META_NODE_ID_157} \
                -m ${BEEGFS_MGMTD_HOST} || true
        fi

        # Configure mgmtd host (BeeGFS 8.x .conf format: "sysMgmtdHost                 =")
        for f in /etc/beegfs/beegfs-meta.conf; do
            [ -f \"\${f}\" ] && sudo sed -i 's|^sysMgmtdHost[[:space:]]*=.*|sysMgmtdHost                 = ${BEEGFS_MGMTD_HOST}|' \"\${f}\"
        done

        sudo systemctl enable beegfs-meta
        sudo systemctl start beegfs-meta
        sleep 2
        sudo systemctl is-active --quiet beegfs-meta && echo '  meta: RUNNING' || echo '  meta: FAILED'
    "

    # Slaves (150, 151, 152)
    local ids=( "${META_NODE_ID_150}" "${META_NODE_ID_151}" "${META_NODE_ID_152}" )
    for i in "${!SLAVE_SERVERS[@]}"; do
        ip="${SLAVE_SERVERS[$i]}"
        id="${ids[$i]}"
        echo "  >>> ${ip} (meta, ID=${id})..."
        _run "${ip}" "
            set -e
            sudo mkdir -p ${BEEGFS_META_DIR}
            sudo chown -R beegfs:beegfs /mnt/beegfs-meta 2>/dev/null || true

            sudo systemctl stop beegfs-meta 2>/dev/null || true

            if [ ! -f ${BEEGFS_META_DIR}/format ]; then
                sudo /opt/beegfs/sbin/beegfs-setup-meta \
                    -p ${BEEGFS_META_DIR} \
                    -s ${id} \
                    -m ${BEEGFS_MGMTD_HOST} || true
            fi

            for f in /etc/beegfs/beegfs-meta.conf; do
                [ -f \"\${f}\" ] && sudo sed -i 's|^sysMgmtdHost[[:space:]]*=.*|sysMgmtdHost                 = ${BEEGFS_MGMTD_HOST}|' \"\${f}\"
            done

            sudo systemctl enable beegfs-meta
            sudo systemctl start beegfs-meta
            sleep 2
            sudo systemctl is-active --quiet beegfs-meta && echo '  meta: RUNNING' || echo '  meta: FAILED'
        "
    done
}

# ============================================================
# Step 5: Deploy storage services (3 slaves, 2 targets each)
# ============================================================

deploy_storage() {
    echo ""
    echo ">>> Step 5: Deploying storage services (3 slaves, 6 targets)..."

    # Slave 150 (service 101, targets 1011, 1012)
    deploy_storage_target "10.20.1.150" "${STORAGE_SVC_ID_150}" "${STORAGE_TARGET_ID_150_1}" "${BEEGFS_STORAGE_DIR_SLAVE_1}"
    deploy_storage_target "10.20.1.150" "${STORAGE_SVC_ID_150}" "${STORAGE_TARGET_ID_150_2}" "${BEEGFS_STORAGE_DIR_SLAVE_2}"

    # Slave 151 (service 102, targets 1021, 1022)
    deploy_storage_target "10.20.1.151" "${STORAGE_SVC_ID_151}" "${STORAGE_TARGET_ID_151_1}" "${BEEGFS_STORAGE_DIR_SLAVE_1}"
    deploy_storage_target "10.20.1.151" "${STORAGE_SVC_ID_151}" "${STORAGE_TARGET_ID_151_2}" "${BEEGFS_STORAGE_DIR_SLAVE_2}"

    # Slave 152 (service 103, targets 1031, 1032)
    deploy_storage_target "10.20.1.152" "${STORAGE_SVC_ID_152}" "${STORAGE_TARGET_ID_152_1}" "${BEEGFS_STORAGE_DIR_SLAVE_1}"
    deploy_storage_target "10.20.1.152" "${STORAGE_SVC_ID_152}" "${STORAGE_TARGET_ID_152_2}" "${BEEGFS_STORAGE_DIR_SLAVE_2}"
}

deploy_storage_target() {
    local ip=$1 svc_id=$2 target_id=$3 dir=$4
    echo "  >>> ${ip} target ${target_id} (${dir})..."

    # First target uses beegfs-storage service, second uses beegfs-storage2
    local svc_name="beegfs-storage"
    local conf_file="/etc/beegfs/beegfs-storage.conf"
    local setup_flag=""

    if [ "${target_id: -1}" = "2" ]; then
        # Second target on same server
        svc_name="beegfs-storage2"
        conf_file="/etc/beegfs/beegfs-storage2.conf"

        # Create second service config
        _run "${ip}" "
            sudo cp /etc/beegfs/beegfs-storage.conf ${conf_file} 2>/dev/null || true
            sudo cp /lib/systemd/system/beegfs-storage.service /etc/systemd/system/${svc_name}.service 2>/dev/null || true
            sudo sed -i 's|beegfs-storage.service|${svc_name}.service|g' /etc/systemd/system/${svc_name}.service 2>/dev/null || true
            sudo sed -i 's|/etc/beegfs/beegfs-storage.conf|${conf_file}|g' /etc/systemd/system/${svc_name}.service 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true
        "
        setup_flag="-c ${conf_file}"
    fi

    _run "${ip}" "
        set -e
        sudo mkdir -p ${dir}
        sudo chown -R beegfs:beegfs ${dir} 2>/dev/null || true

        sudo systemctl stop ${svc_name} 2>/dev/null || true

        # Setup storage target
        if [ ! -f ${dir}/format ]; then
            if [ -n \"${setup_flag}\" ]; then
                sudo /opt/beegfs/sbin/beegfs-setup-storage \
                    -p ${dir} -s ${svc_id} -i ${target_id} \
                    ${setup_flag} -m ${BEEGFS_MGMTD_HOST} || true
            else
                sudo /opt/beegfs/sbin/beegfs-setup-storage \
                    -p ${dir} -s ${svc_id} -i ${target_id} \
                    -m ${BEEGFS_MGMTD_HOST} || true
            fi
        fi

        # Configure mgmtd host (BeeGFS 8.x .conf format)
        for f in ${conf_file}; do
            [ -f \"\${f}\" ] && sudo sed -i 's|^sysMgmtdHost[[:space:]]*=.*|sysMgmtdHost                 = ${BEEGFS_MGMTD_HOST}|' \"\${f}\"
        done

        sudo systemctl enable ${svc_name}
        sudo systemctl start ${svc_name}
        sleep 2
        sudo systemctl is-active --quiet ${svc_name} && echo '  ${svc_name}: RUNNING' || echo '  ${svc_name}: FAILED'
    "
}

# ============================================================
# Step 6: Configure mirror buddy groups
# ============================================================

setup_mirroring() {
    echo ""
    echo ">>> Step 6: Setting up mirror buddy groups..."

    # Wait for all nodes to register
    echo "  Waiting for nodes to register (15s)..."
    sleep 15

    # Metadata buddy groups
    # Group 1: meta:2 (150) + meta:3 (151)
    # Group 2: meta:4 (152) + meta:1 (157)
    echo "  Creating metadata buddy groups..."
    _run "${BEEGFS_MGMTD_HOST}" "
        # Check if beegfs mirror command exists (8.x)
        if command -v beegfs &>/dev/null; then
            # 8.x syntax
            sudo beegfs mirror create --node-type=meta --num-id=1 \
                --primary=meta:${META_NODE_ID_150} --secondary=meta:${META_NODE_ID_151} \
                m150m151 2>/dev/null || true
            sudo beegfs mirror create --node-type=meta --num-id=2 \
                --primary=meta:${META_NODE_ID_152} --secondary=meta:${META_NODE_ID_157} \
                m152m157 2>/dev/null || true
        elif command -v beegfs-ctl &>/dev/null; then
            # 7.x syntax
            sudo beegfs-ctl --addmirrbuddy --nodetype=meta --primary=${META_NODE_ID_150} \
                --secondary=${META_NODE_ID_151} --groupid=1 2>/dev/null || true
            sudo beegfs-ctl --addmirrbuddy --nodetype=meta --primary=${META_NODE_ID_152} \
                --secondary=${META_NODE_ID_157} --groupid=2 2>/dev/null || true
        fi
        echo '  Metadata buddy groups created.'
    "

    # Storage buddy groups
    # Group 1: target 1011 (150-disk1) + target 1021 (151-disk1)
    # Group 2: target 1012 (150-disk2) + target 1031 (152-disk1)
    # Group 3: target 1022 (151-disk2) + target 1032 (152-disk2)
    echo "  Creating storage buddy groups..."
    _run "${BEEGFS_MGMTD_HOST}" "
        if command -v beegfs &>/dev/null; then
            # 8.x syntax
            sudo beegfs mirror create --node-type=storage --num-id=1 \
                --primary=storage:${STORAGE_TARGET_ID_150_1} \
                --secondary=storage:${STORAGE_TARGET_ID_151_1} \
                s150s151 2>/dev/null || true
            sudo beegfs mirror create --node-type=storage --num-id=2 \
                --primary=storage:${STORAGE_TARGET_ID_150_2} \
                --secondary=storage:${STORAGE_TARGET_ID_152_1} \
                s150s152 2>/dev/null || true
            sudo beegfs mirror create --node-type=storage --num-id=3 \
                --primary=storage:${STORAGE_TARGET_ID_151_2} \
                --secondary=storage:${STORAGE_TARGET_ID_152_2} \
                s151s152 2>/dev/null || true
        elif command -v beegfs-ctl &>/dev/null; then
            # 7.x syntax
            sudo beegfs-ctl --addmirrbuddy --nodetype=storage \
                --primary=${STORAGE_TARGET_ID_150_1} --secondary=${STORAGE_TARGET_ID_151_1} \
                --groupid=1 2>/dev/null || true
            sudo beegfs-ctl --addmirrbuddy --nodetype=storage \
                --primary=${STORAGE_TARGET_ID_150_2} --secondary=${STORAGE_TARGET_ID_152_1} \
                --groupid=2 2>/dev/null || true
            sudo beegfs-ctl --addmirrbuddy --nodetype=storage \
                --primary=${STORAGE_TARGET_ID_151_2} --secondary=${STORAGE_TARGET_ID_152_2} \
                --groupid=3 2>/dev/null || true
        fi
        echo '  Storage buddy groups created.'
    "

    # Enable mirroring on root directory
    echo "  Enabling mirroring on root directory..."
    _run "${BEEGFS_MGMTD_HOST}" "
        if command -v beegfs &>/dev/null; then
            # 8.x: init metadata mirroring
            sudo beegfs mirror init 2>/dev/null || true
            # Set stripe pattern to mirrored
            sudo beegfs entry set --pattern=mirrored --num-targets=3 --chunk-size=1MiB \
                ${BEEGFS_MOUNT_POINT} 2>/dev/null || true
        elif command -v beegfs-ctl &>/dev/null; then
            # 7.x
            sudo beegfs-ctl --setmirrormode --root 2>/dev/null || true
            sudo beegfs-ctl --setpattern --pattern=mirrored --numtargets=3 --chunksize=1M \
                ${BEEGFS_MOUNT_POINT} 2>/dev/null || true
        fi
        echo '  Mirroring enabled.'
    "

    # Show buddy groups
    echo ""
    echo "  Buddy groups:"
    _run "${BEEGFS_MGMTD_HOST}" "
        if command -v beegfs &>/dev/null; then
            sudo beegfs mirror list 2>/dev/null || true
        elif command -v beegfs-ctl &>/dev/null; then
            sudo beegfs-ctl --listmirrbuddies --nodetype=meta 2>/dev/null || true
            sudo beegfs-ctl --listmirrbuddies --nodetype=storage 2>/dev/null || true
        fi
    " 2>/dev/null
}

# ============================================================
# Step 7: Deploy client on 157
# ============================================================

deploy_client() {
    echo ""
    echo ">>> Step 7: Deploying client on ${CLIENT_SERVER}..."

    _run "${CLIENT_SERVER}" "
        set -e
        sudo mkdir -p ${BEEGFS_MOUNT_POINT}
        sudo chown \$(whoami):\$(whoami) ${BEEGFS_MOUNT_POINT} 2>/dev/null || true

        # Configure client (BeeGFS 8.x .conf format)
        for f in /etc/beegfs/beegfs-client.conf; do
            [ -f \"\${f}\" ] && sudo sed -i 's|^sysMgmtHost[[:space:]]*=.*|sysMgmtHost = ${BEEGFS_MGMTD_HOST}|' \"\${f}\"
            [ -f \"\${f}\" ] && sudo sed -i 's|^sysMgmtdHost[[:space:]]*=.*|sysMgmtdHost                 = ${BEEGFS_MGMTD_HOST}|' \"\${f}\"
        done

        # Set mount point in mounts.conf
        echo '${BEEGFS_MOUNT_POINT} /etc/beegfs/beegfs-client.conf' | sudo tee /etc/beegfs/beegfs-mounts.conf >/dev/null

        sudo systemctl stop beegfs-client 2>/dev/null || true
        sudo umount ${BEEGFS_MOUNT_POINT} 2>/dev/null || true

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
        echo ">>> ${ip} ($(_run "${ip}" 'hostname' 2>/dev/null))"
        _run "${ip}" "
            for svc in beegfs-mgmtd beegfs-meta beegfs-storage beegfs-storage2 beegfs-client; do
                echo -n '  '\${svc}': '
                sudo systemctl is-active \${svc} 2>/dev/null || echo 'not installed'
            done
        " 2>/dev/null
        echo ""
    done

    echo ">>> Cluster info:"
    _run "${BEEGFS_MGMTD_HOST}" "
        if command -v beegfs &>/dev/null; then
            echo '  Nodes:'
            sudo beegfs node list 2>/dev/null || true
            echo ''
            echo '  Targets:'
            sudo beegfs target list 2>/dev/null || true
            echo ''
            echo '  Buddy groups:'
            sudo beegfs mirror list 2>/dev/null || true
            echo ''
            echo '  Health:'
            sudo beegfs health df 2>/dev/null || true
        elif command -v beegfs-ctl &>/dev/null; then
            echo '  Nodes:'
            sudo beegfs-ctl --listnodes 2>/dev/null || true
            echo ''
            echo '  Targets:'
            sudo beegfs-ctl --listtargets --nodetype=storage 2>/dev/null || true
        fi
    " 2>/dev/null

    echo ""
    echo ">>> Client mount:"
    if _run "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        _run "${CLIENT_SERVER}" "df -h ${BEEGFS_MOUNT_POINT}" 2>/dev/null
    else
        echo "  Not mounted"
    fi
}

# ============================================================
# Mount / Unmount
# ============================================================

do_mount() {
    echo ">>> Mounting BeeGFS on ${CLIENT_SERVER}..."
    _run "${CLIENT_SERVER}" "
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
    echo ">>> Unmounting BeeGFS on ${CLIENT_SERVER}..."
    _run "${CLIENT_SERVER}" "
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

    if ! _run "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        do_mount
    fi

    _run "${CLIENT_SERVER}" "
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
        if command -v beegfs &>/dev/null; then
            beegfs entry info ${BEEGFS_MOUNT_POINT}/ 2>/dev/null || true
        fi

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
        configure_tls_auth
        ;;
    deploy)
        preflight
        install_packages
        configure_tls_auth
        deploy_mgmtmtd
        deploy_meta
        deploy_storage
        deploy_client
        setup_mirroring
        echo ""
        echo "========================================"
        echo "BeeGFS Deployment Complete (with Mirroring)!"
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
        configure_tls_auth
        deploy_mgmtmtd
        deploy_meta
        deploy_storage
        deploy_client
        setup_mirroring
        echo ""
        echo "========================================"
        echo "BeeGFS Deployment Complete (with Mirroring)!"
        echo "========================================"
        do_status
        do_test
        ;;
    *)
        echo "Usage: bash deploy-beegfs.sh [status|install|deploy|mount|unmount|test|all]"
        echo ""
        echo "  status   - Show cluster status"
        echo "  install  - Install packages + TLS/auth config"
        echo "  deploy   - Full deployment with mirroring"
        echo "  mount    - Mount filesystem on client"
        echo "  unmount  - Unmount filesystem"
        echo "  test     - Run smoke test"
        echo "  all      - Deploy + test"
        ;;
esac
