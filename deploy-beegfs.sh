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

# Run a command on a remote server.
# motd is printed on every connection; the actual command output
# comes after it. Both stdout and stderr are returned as-is.
_run() {
    local ip=$1; shift
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "$@"
    else
        ssh_to_slave "$ip" "$@"
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

    # 仓库配置片段 (统一用 config.sh 变量, Ubuntu 22.04 jammy)
    local repo_setup
    repo_setup="if ! grep -q beegfs ${BEEGFS_REPO_LIST} 2>/dev/null; then
        sudo rm -f ${BEEGFS_REPO_LIST}
        curl -fsSL ${BEEGFS_REPO_KEY_URL} | sudo gpg --batch --no-tty --dearmor -o ${BEEGFS_REPO_KEYRING}
        echo 'deb [arch=amd64 signed-by=${BEEGFS_REPO_KEYRING}] https://www.beegfs.io/release/beegfs_${BEEGFS_MAJOR_VERSION} ${BEEGFS_REPO_DIST} non-free' | sudo tee ${BEEGFS_REPO_LIST} >/dev/null
    fi
    sudo apt-get update -qq"

    # Slaves: meta + storage + tools (无 mgmtd, 无 client — slave 不当客户端, 避免多余的内核模块编译)
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo "  >>> ${ip} (meta + storage)..."
        _run "${ip}" "
            set -e
            ${repo_setup}
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                beegfs-meta beegfs-storage beegfs-tools beegfs-utils -qq
            echo '  Done: '\$(beegfs --help 2>&1 | head -1 || echo installed)
        "
    done

    # Client (157): mgmtd + meta + client + tools + license
    echo "  >>> ${CLIENT_SERVER} (mgmtd + meta + client)..."
    _run "${CLIENT_SERVER}" "
        set -e
        ${repo_setup}
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            beegfs-mgmtd libbeegfs-license \
            beegfs-meta beegfs-client beegfs-tools beegfs-utils -qq
        echo '  Done: '\$(beegfs --help 2>&1 | head -1 || echo installed)
    "
    echo "  All packages installed."
}

# ============================================================
# Step 2: Configure TLS and Auth (disable for testing)
# ============================================================

configure_tls_auth() {
    echo ""
    echo ">>> Step 2: Configuring TLS and Auth (disable for testing)..."
    echo "    mgmtd.toml: tls-disable/auth-disable = true"
    echo "    meta/storage/client .conf: connDisableAuthentication = true"

    for ip in "${ALL_SERVERS[@]}"; do
        echo "  >>> ${ip}..."
        # 一次 SSH 处理 mgmtd.toml + 三个 .conf, 不再逐个 _run (省跳板往返, 不吞错误)
        _run "${ip}" "
            if [ -f /etc/beegfs/beegfs-mgmtd.toml ]; then
                sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(auth-disable\)[[:space:]]*=.*|\1 = true|' /etc/beegfs/beegfs-mgmtd.toml
                sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(tls-disable\)[[:space:]]*=.*|\1 = true|' /etc/beegfs/beegfs-mgmtd.toml
            fi
            for conf in beegfs-meta.conf beegfs-storage.conf beegfs-client.conf; do
                f=/etc/beegfs/\$conf
                if [ -f \"\$f\" ]; then
                    sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(connDisableAuthentication\)[[:space:]]*=.*|\1    = true|' \"\$f\"
                fi
            done
        "
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
                -m ${BEEGFS_MGMTD_HOST} || { echo '  ERROR: beegfs-setup-meta failed on 157'; exit 1; }
        fi

        # Configure mgmtd host (8.x .conf; 处理注释行)
        [ -f /etc/beegfs/beegfs-meta.conf ] && sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(sysMgmtdHost\)[[:space:]]*=.*|\1                 = ${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-meta.conf

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
                    -m ${BEEGFS_MGMTD_HOST} || { echo "  ERROR: beegfs-setup-meta failed on ${ip}"; exit 1; }
            fi

            [ -f /etc/beegfs/beegfs-meta.conf ] && sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(sysMgmtdHost\)[[:space:]]*=.*|\1                 = ${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-meta.conf

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
    echo ">>> Step 5: Deploying storage services (3 slaves, 2 targets each)..."

    # 单 daemon 多 target (per 官方 quick-start): 每台 slave 一个 beegfs-storage 服务,
    # 服务 2 个 target。target1 注册 service(-m), target2 追加(同 -s, 不传 -m)。
    deploy_storage_node "10.20.1.150" "${STORAGE_SVC_ID_150}" "${STORAGE_TARGET_ID_150_1}" "${STORAGE_TARGET_ID_150_2}"
    deploy_storage_node "10.20.1.151" "${STORAGE_SVC_ID_151}" "${STORAGE_TARGET_ID_151_1}" "${STORAGE_TARGET_ID_151_2}"
    deploy_storage_node "10.20.1.152" "${STORAGE_SVC_ID_152}" "${STORAGE_TARGET_ID_152_1}" "${STORAGE_TARGET_ID_152_2}"
}

deploy_storage_node() {
    local ip=$1 svc=$2 tid1=$3 tid2=$4
    echo "  >>> ${ip} (svc=${svc}, targets=${tid1},${tid2})..."

    _run "${ip}" "
        set -e

        # 前置: 两块 storage 盘必须已挂载为 XFS (prepare-servers.sh 负责)
        # 否则拒绝部署, 避免在系统盘上误建 target
        for d in ${BEEGFS_STORAGE_DIR_SLAVE_1} ${BEEGFS_STORAGE_DIR_SLAVE_2}; do
            if ! mountpoint -q \"\$d\"; then
                echo '  ERROR: '\$d' 未挂载。请先运行 prepare-servers.sh 准备 XFS 盘。'
                exit 1
            fi
            fstype=\$(stat -f -c '%T' \"\$d\" 2>/dev/null | tr 'A-Z' 'a-z' || echo unknown)
            if [ \"\$fstype\" != 'xfs' ]; then
                echo '  ERROR: '\$d' 不是 XFS (实际: '\$fstype')。请先格式化为 XFS。'
                exit 1
            fi
        done

        sudo chown -R beegfs:beegfs ${BEEGFS_STORAGE_DIR_SLAVE_1} ${BEEGFS_STORAGE_DIR_SLAVE_2} 2>/dev/null || true
        sudo systemctl stop beegfs-storage 2>/dev/null || true

        # 确保 mgmtd host 配置 (target2 setup 无 -m, 需从 conf 读)
        sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(sysMgmtdHost\)[[:space:]]*=.*|\1                 = ${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-storage.conf

        # target 1: 首次注册 service 到 mgmtd (per 官方 quick-start)
        if [ ! -f ${BEEGFS_STORAGE_DIR_SLAVE_1}/format ]; then
            sudo /opt/beegfs/sbin/beegfs-setup-storage \
                -p ${BEEGFS_STORAGE_DIR_SLAVE_1} -s ${svc} -i ${tid1} -m ${BEEGFS_MGMTD_HOST} \
                || { echo '  ERROR: beegfs-setup-storage target ${tid1} failed'; exit 1; }
        fi

        # target 2: 同 service 追加 target (同 -s, 不传 -m, per 官方文档)
        if [ ! -f ${BEEGFS_STORAGE_DIR_SLAVE_2}/format ]; then
            sudo /opt/beegfs/sbin/beegfs-setup-storage \
                -p ${BEEGFS_STORAGE_DIR_SLAVE_2} -s ${svc} -i ${tid2} \
                || { echo '  ERROR: beegfs-setup-storage target ${tid2} failed'; exit 1; }
        fi

        sudo systemctl enable beegfs-storage
        sudo systemctl start beegfs-storage
        sleep 2
        sudo systemctl is-active --quiet beegfs-storage && echo '  beegfs-storage: RUNNING' \
            || { echo '  beegfs-storage: FAILED'; sudo journalctl -u beegfs-storage --no-pager | tail -20; exit 1; }
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

    # beegfs CLI (8.x) 走 gRPC 连 mgmtd, 必须设置环境变量, 否则连不上 (问题1根因)
    local cli_env; cli_env="$(beegfs_cli_env)"

    # --- Metadata buddy groups ---
    # 官方约束: root 属主所在的 buddy group, root 属主必须是 primary (否则无法镜像 root inode)
    # 自动识别 root 属主 (client 已挂载, deploy_client 在本步之前); 失败则按部署顺序推断=第一个注册的 meta
    echo "  Detecting root inode owner..."
    local root_owner
    root_owner=$(_run "${CLIENT_SERVER}" "${cli_env}; sudo -E beegfs entry info ${BEEGFS_MOUNT_POINT}/ --retro --verbose 2>/dev/null | grep -oP 'Current primary metadata node:.*\[ID: \K[0-9]+' | head -1" 2>/dev/null | tail -1)
    if [ -z "${root_owner}" ]; then
        root_owner="${META_NODE_ID_157}"
        echo "  (entry info 未取到, 按部署顺序推断 root 属主 = meta:${root_owner}, 即 157)"
    else
        echo "  root 属主 = meta:${root_owner}"
    fi

    # Group 1: {150=ID2, 151=ID3}; Group 2: {152=ID4, 157=ID1}
    # root 属主所在 group 的 primary = root 属主; 另一 group 用默认 primary
    local g1pri g1sec g2pri g2sec
    if [ "${root_owner}" = "${META_NODE_ID_150}" ] || [ "${root_owner}" = "${META_NODE_ID_151}" ]; then
        g1pri="${root_owner}"
        [ "${root_owner}" = "${META_NODE_ID_150}" ] && g1sec="${META_NODE_ID_151}" || g1sec="${META_NODE_ID_150}"
        g2pri="${META_NODE_ID_152}"; g2sec="${META_NODE_ID_157}"
    else
        g2pri="${root_owner}"
        [ "${root_owner}" = "${META_NODE_ID_152}" ] && g2sec="${META_NODE_ID_157}" || g2sec="${META_NODE_ID_152}"
        g1pri="${META_NODE_ID_150}"; g1sec="${META_NODE_ID_151}"
    fi
    echo "  meta group1: primary=meta:${g1pri} secondary=meta:${g1sec}"
    echo "  meta group2: primary=meta:${g2pri} secondary=meta:${g2sec}"

    echo "  Creating metadata buddy groups..."
    _run "${BEEGFS_MGMTD_HOST}" "
        ${cli_env}
        sudo -E beegfs mirror create --node-type=meta --num-id=1 \
            --primary=meta:${g1pri} --secondary=meta:${g1sec} m150m151 \
            || echo '  (meta group 1: may already exist)'
        sudo -E beegfs mirror create --node-type=meta --num-id=2 \
            --primary=meta:${g2pri} --secondary=meta:${g2sec} m152m157 \
            || echo '  (meta group 2: may already exist)'
    "

    # --- Storage buddy groups ---
    # Group 1: 1011(150-disk1) + 1021(151-disk1)
    # Group 2: 1012(150-disk2) + 1031(152-disk1)
    # Group 3: 1022(151-disk2) + 1032(152-disk2)
    echo "  Creating storage buddy groups..."
    _run "${BEEGFS_MGMTD_HOST}" "
        ${cli_env}
        sudo -E beegfs mirror create --node-type=storage --num-id=1 \
            --primary=storage:${STORAGE_TARGET_ID_150_1} --secondary=storage:${STORAGE_TARGET_ID_151_1} s150s151 \
            || echo '  (storage group 1: may already exist)'
        sudo -E beegfs mirror create --node-type=storage --num-id=2 \
            --primary=storage:${STORAGE_TARGET_ID_150_2} --secondary=storage:${STORAGE_TARGET_ID_152_1} s150s152 \
            || echo '  (storage group 2: may already exist)'
        sudo -E beegfs mirror create --node-type=storage --num-id=3 \
            --primary=storage:${STORAGE_TARGET_ID_151_2} --secondary=storage:${STORAGE_TARGET_ID_152_2} s151s152 \
            || echo '  (storage group 3: may already exist)'
    "

    # --- 启用元数据镜像 ---
    echo "  Enabling metadata mirroring (beegfs mirror init)..."
    _run "${BEEGFS_MGMTD_HOST}" "
        ${cli_env}
        sudo -E beegfs mirror init || { echo '  ERROR: beegfs mirror init failed'; exit 1; }
        echo '  Metadata mirroring initialized.'
    "

    # --- 根目录 stripe pattern = mirrored (用 config 变量, 问题12) ---
    echo "  Setting root stripe pattern to mirrored..."
    _run "${BEEGFS_MGMTD_HOST}" "
        ${cli_env}
        sudo -E beegfs entry set --pattern=${BEEGFS_STRIPE_PATTERN} \
            --num-targets=${BEEGFS_STRIPE_COUNT} --chunk-size=${BEEGFS_STRIPE_SIZE} \
            ${BEEGFS_MOUNT_POINT} \
            || { echo '  ERROR: set root stripe pattern failed'; exit 1; }
        echo '  Root stripe pattern: '${BEEGFS_STRIPE_PATTERN}', num-targets='${BEEGFS_STRIPE_COUNT}', chunk='${BEEGFS_STRIPE_SIZE}
    "

    # --- 验证 buddy groups 确实建立 (不再静默) ---
    echo ""
    echo "  Verifying buddy groups..."
    local verify
    verify=$(_run "${BEEGFS_MGMTD_HOST}" "${cli_env}; sudo -E beegfs mirror list 2>&1")
    echo "${verify}" | sed 's/^/    /'

    local missing=0 alias
    for alias in m150m151 m152m157 s150s151 s150s152 s151s152; do
        if ! echo "${verify}" | grep -q "${alias}"; then
            echo "  [MISSING] buddy group: ${alias}"
            missing=$((missing+1))
        fi
    done
    if [ "${missing}" -ne 0 ]; then
        echo "  ERROR: ${missing} buddy group(s) missing — mirroring NOT fully enabled"
        return 1
    fi
    echo "  All 5 buddy groups present."
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

        # 配置 client mgmtd host (8.x .conf; 处理注释行)
        if [ -f /etc/beegfs/beegfs-client.conf ]; then
            sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(sysMgmtdHost\)[[:space:]]*=.*|\1                 = ${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-client.conf
        fi

        # 挂载点配置 (beegfs-mounts.conf: 挂载点 + 对应配置文件)
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

    local cli_env; cli_env="$(beegfs_cli_env)"

    for ip in "${ALL_SERVERS[@]}"; do
        echo ">>> ${ip} ($(_run "${ip}" 'hostname' 2>/dev/null | tail -1 || echo "${ip}"))"
        _run "${ip}" "
            for svc in beegfs-mgmtd beegfs-meta beegfs-storage beegfs-client; do
                echo -n '  '\${svc}': '
                sudo systemctl is-active \${svc} 2>/dev/null || echo 'not installed'
            done
        "
        echo ""
    done

    echo ">>> Cluster info:"
    _run "${BEEGFS_MGMTD_HOST}" "
        ${cli_env}
        echo '  Nodes:'
        sudo -E beegfs node list 2>&1
        echo ''
        echo '  Targets (state):'
        sudo -E beegfs target list --state 2>&1
        echo ''
        echo '  Buddy groups:'
        sudo -E beegfs mirror list 2>&1
        echo ''
        echo '  Health df:'
        sudo -E beegfs health df 2>&1
    "

    echo ""
    echo ">>> Client mount:"
    if _run "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        _run "${CLIENT_SERVER}" "df -h ${BEEGFS_MOUNT_POINT}"
    else
        echo "  Not mounted"
    fi
}

# ============================================================
# Verify (部署后强校验, 失败则退出 — 避免静默成功)
# ============================================================

verify_deployment() {
    echo ""
    echo "========================================"
    echo "BeeGFS Deployment Verification"
    echo "========================================"
    local cli_env; cli_env="$(beegfs_cli_env)"
    local rc=0 ip svc

    # [1] 关键服务 active (client: mgmtd+meta+client; slave: meta+storage)
    echo ">>> [1/4] 服务状态..."
    for ip in "${ALL_SERVERS[@]}"; do
        for svc in beegfs-mgmtd beegfs-meta beegfs-storage beegfs-client; do
            [ "${ip}" != "${CLIENT_SERVER}" ] && { [ "${svc}" = "beegfs-mgmtd" ] || [ "${svc}" = "beegfs-client" ]; } && continue
            [ "${ip}" = "${CLIENT_SERVER}" ] && [ "${svc}" = "beegfs-storage" ] && continue
            if _run "${ip}" "sudo systemctl is-active --quiet ${svc}" 2>/dev/null; then
                echo "  OK   ${ip} ${svc}"
            else
                echo "  FAIL ${ip} ${svc} not active"; rc=1
            fi
        done
    done

    # [2] 节点注册 (4 meta + 3 storage)
    echo ">>> [2/4] 节点注册..."
    local nodes n_meta n_storage
    nodes=$(_run "${BEEGFS_MGMTD_HOST}" "${cli_env}; sudo -E beegfs node list 2>&1")
    n_meta=$(echo "${nodes}" | grep -c '^m:' || true)
    n_storage=$(echo "${nodes}" | grep -c '^s:' || true)
    echo "  meta: ${n_meta} (expect 4)  storage: ${n_storage} (expect 3)"
    [ "${n_meta}" -eq 4 ] || { echo "  FAIL meta count"; rc=1; }
    [ "${n_storage}" -eq 3 ] || { echo "  FAIL storage count"; rc=1; }

    # [3] storage targets (6 个, 状态 GOOD)
    echo ">>> [3/4] Storage targets (期望 6, 状态 GOOD)..."
    local targets n_tgt n_good
    targets=$(_run "${BEEGFS_MGMTD_HOST}" "${cli_env}; sudo -E beegfs target list --state 2>&1")
    echo "${targets}" | sed 's/^/    /'
    n_tgt=$(echo "${targets}" | grep -c '^s:' || true)
    n_good=$(echo "${targets}" | grep -ciE 'good' || true)
    echo "  storage targets: ${n_tgt} (expect 6), GOOD: ${n_good}"
    [ "${n_tgt}" -ge 6 ] || { echo "  FAIL storage target count < 6 (storage 盘是否已准备?)"; rc=1; }

    # [4] buddy groups (5 个 alias) + client mount
    echo ">>> [4/4] Buddy groups (期望 5) + client mount..."
    local mlist n_grp a
    mlist=$(_run "${BEEGFS_MGMTD_HOST}" "${cli_env}; sudo -E beegfs mirror list 2>&1")
    n_grp=0
    for a in m150m151 m152m157 s150s151 s150s152 s151s152; do
        echo "${mlist}" | grep -q "$a" && n_grp=$((n_grp+1))
    done
    echo "  buddy groups: ${n_grp} (expect 5)"
    [ "${n_grp}" -ge 5 ] || { echo "  FAIL buddy group count < 5 (镜像未完全建立)"; rc=1; }
    if _run "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        echo "  OK   client mounted"
    else
        echo "  FAIL client not mounted"; rc=1
    fi

    echo ""
    if [ "${rc}" -eq 0 ]; then
        echo "  RESULT: PASS — 部署验证通过"
    else
        echo "  RESULT: FAIL — 部署验证未通过 (见上方 FAIL 项)"
    fi
    return ${rc}
}

# ============================================================
# Mount / Unmount
# ============================================================

do_mount() {
    echo ">>> Mounting BeeGFS on ${CLIENT_SERVER}..."
    _run "${CLIENT_SERVER}" "\
sudo systemctl restart beegfs-client && \
sleep 3 && \
mountpoint -q ${BEEGFS_MOUNT_POINT} && \
echo '  Mounted!' || \
echo '  ERROR: mount failed'"
}

do_unmount() {
    echo ">>> Unmounting BeeGFS on ${CLIENT_SERVER}..."
    _run "${CLIENT_SERVER}" "\
sudo systemctl stop beegfs-client && \
sleep 2 && \
mountpoint -q ${BEEGFS_MOUNT_POINT} && \
echo '  WARNING: still mounted' || \
echo '  Unmounted.'"
}

# ============================================================
# Smoke Test
# ============================================================

do_test() {
    echo "========================================"
    echo "BeeGFS Smoke Test"
    echo "========================================"

    local cli_env; cli_env="$(beegfs_cli_env)"

    if ! _run "${CLIENT_SERVER}" "mountpoint -q ${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        do_mount
    fi

    _run "${CLIENT_SERVER}" "
        echo '>>> Write test...'
        if echo 'BeeGFS production test - '\$(date) > ${BEEGFS_MOUNT_POINT}/hello.txt \
           && dd if=/dev/urandom of=${BEEGFS_MOUNT_POINT}/random.bin bs=1M count=100 2>&1 | tail -1; then
            :
        else
            echo '  FAIL: write'; rm -f ${BEEGFS_MOUNT_POINT}/hello.txt ${BEEGFS_MOUNT_POINT}/random.bin; exit 1
        fi
        echo '>>> Read verification...'
        if grep -q 'production test' ${BEEGFS_MOUNT_POINT}/hello.txt; then
            echo '  PASS: Text file'
        else
            echo '  FAIL: Text file'; rm -f ${BEEGFS_MOUNT_POINT}/hello.txt ${BEEGFS_MOUNT_POINT}/random.bin; exit 1
        fi
        SIZE=\$(stat -c%s ${BEEGFS_MOUNT_POINT}/random.bin)
        if [ \"\${SIZE}\" -eq 104857600 ]; then
            echo '  PASS: Binary (100MB)'
        else
            echo '  FAIL: Binary size='\${SIZE}; rm -f ${BEEGFS_MOUNT_POINT}/hello.txt ${BEEGFS_MOUNT_POINT}/random.bin; exit 1
        fi
        echo '>>> Storage info:'
        ${cli_env}; sudo -E beegfs entry info ${BEEGFS_MOUNT_POINT}/ 2>/dev/null || true
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
        verify_deployment || { echo "  部署验证失败, 请检查上方输出"; exit 1; }
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
    verify)
        verify_deployment
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
        verify_deployment || { echo "  部署验证失败, 请检查上方输出"; exit 1; }
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
        echo "  verify   - Verify deployment (services/nodes/targets/mirrors)"
        echo "  all      - Deploy + test"
        ;;
esac
