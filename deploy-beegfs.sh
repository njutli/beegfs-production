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
# Official docs: https://doc.beegfs.io/7.3.2/
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
    echo ">>> Step 1: Installing BeeGFS ${BEEGFS_RELEASE_VERSION} packages..."

    # 仓库配置 (7.3.2 jammy, 下载 .list + 从 keyserver 获取 GPG key)
    local repo_setup
    repo_setup="if ! grep -q beegfs ${BEEGFS_REPO_LIST} 2>/dev/null; then
        sudo curl -fsSL -o ${BEEGFS_REPO_LIST} ${BEEGFS_REPO_URL}
        sudo sed -i 's|^deb |deb [trusted=yes] |' ${BEEGFS_REPO_LIST}
    fi
    sudo apt-get update -qq"

    # Slaves: meta + storage + utils (7.x: beegfs-utils 含 beegfs-ctl, 无 beegfs-tools)
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo "  >>> ${ip} (meta + storage)..."
        _run "${ip}" "
            set -e
            ${repo_setup}
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                beegfs-meta beegfs-storage beegfs-utils -qq
            echo '  Done: '\$(beegfs-ctl --version 2>&1 | head -1 || echo installed)
        "
    done

    # Client (157): mgmtd + meta + client + helperd + utils (7.x: beegfs-helperd 独立包, 无 beegfs-tools/libbeegfs-license)
    echo "  >>> ${CLIENT_SERVER} (mgmtd + meta + client)..."
    _run "${CLIENT_SERVER}" "
        set -e
        ${repo_setup}
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            beegfs-mgmtd \
            beegfs-meta beegfs-client beegfs-helperd beegfs-utils -qq
        echo '  Done: '\$(beegfs-ctl --version 2>&1 | head -1 || echo installed)
    "
    echo "  All packages installed."
}

# ============================================================
# Step 2: Configure TLS and Auth (disable for testing)
# ============================================================

configure_tls_auth() {
    echo ""
    echo ">>> Step 2: Configuring Auth (disable for testing)..."
    echo "    All .conf: connDisableAuthentication = true"

    for ip in "${ALL_SERVERS[@]}"; do
        echo "  >>> ${ip}..."
        _run "${ip}" "
            for conf in beegfs-mgmtd.conf beegfs-meta.conf beegfs-storage.conf beegfs-client.conf beegfs-helperd.conf; do
                f=/etc/beegfs/\$conf
                if [ -f \"\$f\" ]; then
                    sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(connDisableAuthentication\)[[:space:]]*=.*|\1    = true|' \"\$f\"
                fi
            done
        "
    done

    # 157: beegfs-ctl 读 beegfs-client.conf 的 sysMgmtdHost, 需提前配置
    _run "${CLIENT_SERVER}" "
        [ -f /etc/beegfs/beegfs-client.conf ] && sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(sysMgmtdHost\)[[:space:]]*=.*|\1                 = ${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-client.conf
    "
    echo "  Auth disabled (testing mode)."
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

        # 7.x: beegfs-setup-mgmtd -p <dir> (directory-based, not SQLite)
        if [ ! -f ${BEEGFS_MGMTD_DB}/format ]; then
            sudo mkdir -p ${BEEGFS_MGMTD_DB}
            sudo /opt/beegfs/sbin/beegfs-setup-mgmtd -p ${BEEGFS_MGMTD_DB}
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
                    -m ${BEEGFS_MGMTD_HOST} || { echo '  ERROR: beegfs-setup-meta failed on '${ip}; exit 1; }
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

    # 7.x: beegfs-ctl 通过 /etc/beegfs/beegfs-ctl.conf 连 mgmtd (无需 gRPC/env vars)
    # 官方约束: root 属主所在的 buddy group, root 属主必须是 primary
    # 7.x: --mirrormd 要求 client 未挂载, 故 setup_mirroring 在 deploy_client 之前
    # root 属主 = 第一个注册的 meta = 157 (ID=1), 无需 entry info 检测
    local root_owner="${META_NODE_ID_157}"
    echo "  root 属主 = meta:${root_owner} (按部署顺序推断 = 157)"

    # Group 1: {150=ID2, 151=ID3}; Group 2: {152=ID4, 157=ID1}
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

    # 7.x: beegfs-ctl --addmirrorgroup (replaces 8.x beegfs mirror create)
    echo "  Creating metadata buddy groups..."
    _run "${BEEGFS_MGMTD_HOST}" "
        sudo beegfs-ctl --addmirrorgroup --nodetype=meta --primary=${g1pri} --secondary=${g1sec} --groupid=1 \
            || echo '  (meta group 1: may already exist)'
        sudo beegfs-ctl --addmirrorgroup --nodetype=meta --primary=${g2pri} --secondary=${g2sec} --groupid=2 \
            || echo '  (meta group 2: may already exist)'
    "

    # --- Storage buddy groups ---
    echo "  Creating storage buddy groups..."
    _run "${BEEGFS_MGMTD_HOST}" "
        sudo beegfs-ctl --addmirrorgroup --nodetype=storage --primary=${STORAGE_TARGET_ID_150_1} --secondary=${STORAGE_TARGET_ID_151_1} --groupid=101 \
            || echo '  (storage group 1: may already exist)'
        sudo beegfs-ctl --addmirrorgroup --nodetype=storage --primary=${STORAGE_TARGET_ID_150_2} --secondary=${STORAGE_TARGET_ID_152_1} --groupid=102 \
            || echo '  (storage group 2: may already exist)'
        sudo beegfs-ctl --addmirrorgroup --nodetype=storage --primary=${STORAGE_TARGET_ID_151_2} --secondary=${STORAGE_TARGET_ID_152_2} --groupid=103 \
            || echo '  (storage group 3: may already exist)'
    "

    # --- 启用元数据镜像 (7.x: beegfs-ctl --mirrormd, 要求 client 未挂载) ---
    echo "  Enabling metadata mirroring (beegfs-ctl --mirrormd)..."
    _run "${BEEGFS_MGMTD_HOST}" "
        for i in 1 2 3; do
            if sudo beegfs-ctl --mirrormd 2>&1; then
                echo '  Metadata mirroring enabled.'
                exit 0
            fi
            if [ \$i -lt 3 ]; then
                echo \"  --mirrormd attempt \$i failed, retry in 5s...\"
                sleep 5
            fi
        done
        echo '  ERROR: beegfs-ctl --mirrormd failed after 3 attempts'
        exit 1
    "

    # 官方要求: --mirrormd 后重启所有 meta 服务
    echo "  Restarting meta services on all nodes..."
    for ip in "${META_SERVERS[@]}"; do
        _run "${ip}" "sudo systemctl restart beegfs-meta && sleep 2 && sudo systemctl is-active --quiet beegfs-meta && echo '  '${ip}' meta: restarted' || echo '  '${ip}' meta: FAILED'"
    done

    # --- 验证 buddy groups ---
    # 注意: stripe pattern (setpattern) 在 deploy_client 之后执行 (需 mount 存在)
    echo ""
    echo "  Verifying buddy groups..."
    local verify
    verify=$(_run "${BEEGFS_MGMTD_HOST}" "sudo beegfs-ctl --listmirrorgroups --nodetype=meta 2>&1; echo '---'; sudo beegfs-ctl --listmirrorgroups --nodetype=storage 2>&1")
    echo "${verify}" | sed 's/^/    /'

    local missing=0
    for gid in 1 2 101 102 103; do
        if ! echo "${verify}" | grep -q "ID: ${gid}\b\|GroupID:.*${gid}\|=>  ${gid}\b"; then
            echo "  [CHECK] buddy groupID ${gid} — verify manually"
        fi
    done
    echo "  Buddy groups created (verify output above)."
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

        # 配置 client mgmtd host (.conf; 处理注释行)
        if [ -f /etc/beegfs/beegfs-client.conf ]; then
            sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(sysMgmtdHost\)[[:space:]]*=.*|\1                 = ${BEEGFS_MGMTD_HOST}|' /etc/beegfs/beegfs-client.conf
        fi

        # 挂载点配置 (beegfs-mounts.conf: 挂载点 + 对应配置文件)
        echo '${BEEGFS_MOUNT_POINT} /etc/beegfs/beegfs-client.conf' | sudo tee /etc/beegfs/beegfs-mounts.conf >/dev/null

        # 7.3.2 内核模块兼容补丁 (5.15 kernel: MIN/MAX 宏冲突 + sa_data[] 不完整类型)
        src_common=/opt/beegfs/src/client/client_module_7/source/common/Common.h
        src_nic=/opt/beegfs/src/client/client_module_7/source/common/net/sock/NetworkInterfaceCard.c
        if [ -f \"\${src_common}\" ] && ! grep -q 'undef MIN' \"\${src_common}\" 2>/dev/null; then
            sudo sed -i '39i#undef MIN\n#undef MAX' \"\${src_common}\"
            echo '  Patched Common.h (MIN/MAX redefinition)'
        fi
        if [ -f \"\${src_nic}\" ] && grep -q 'sizeof.ifr.ifr_hwaddr.sa_data.' \"\${src_nic}\" 2>/dev/null; then
            sudo sed -i 's|sizeof(ifr.ifr_hwaddr.sa_data)|IFHWADDRLEN|g' \"\${src_nic}\"
            sudo sed -i 's|min(IFHWADDRLEN, (size_t) dev->addr_len)|min_t(size_t, IFHWADDRLEN, (size_t) dev->addr_len)|g' \"\${src_nic}\"
            echo '  Patched NetworkInterfaceCard.c (sizeof sa_data)'
        fi

        sudo systemctl stop beegfs-client 2>/dev/null || true
        sudo umount ${BEEGFS_MOUNT_POINT} 2>/dev/null || true

        # 7.x: beegfs-helperd 必须在 beegfs-client 之前启动
        sudo systemctl enable beegfs-helperd
        sudo systemctl start beegfs-helperd

        sudo systemctl enable beegfs-client
        sudo systemctl start beegfs-client
        sleep 10

        if mountpoint -q ${BEEGFS_MOUNT_POINT} 2>/dev/null; then
            echo '  client: MOUNTED'
            df -h ${BEEGFS_MOUNT_POINT}
        else
            echo '  client: FAILED to mount'
            sudo journalctl -u beegfs-client --no-pager | tail -20
            exit 1
        fi

        # 根目录 stripe pattern = buddymirror (需 mount 存在后执行)
        sudo beegfs-ctl --setpattern --pattern=${BEEGFS_STRIPE_PATTERN} \
            --numtargets=${BEEGFS_STRIPE_COUNT} --chunksize=${BEEGFS_STRIPE_SIZE} \
            ${BEEGFS_MOUNT_POINT} 2>&1 || echo '  (setpattern: may need manual run)'
        echo '  Root stripe pattern: '${BEEGFS_STRIPE_PATTERN}', numtargets='${BEEGFS_STRIPE_COUNT}', chunk='${BEEGFS_STRIPE_SIZE}
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

    # 预期服务映射: 157=mgmtd+meta+helperd+client, slaves=meta+storage
    _status_services() {
        local ip=$1 role=$2
        local svcs
        if [ "${role}" = "client" ]; then
            svcs="beegfs-mgmtd beegfs-meta beegfs-helperd beegfs-client"
        else
            svcs="beegfs-meta beegfs-storage"
        fi
        echo ">>> ${ip} ($(_run "${ip}" 'hostname' 2>/dev/null | tail -1 || echo "${ip}"))"
        _run "${ip}" "
            for svc in ${svcs}; do
                echo -n '  '\${svc}': '
                sudo systemctl is-active \${svc} 2>/dev/null || echo 'inactive'
            done
        "
        echo ""
    }

    _status_services "${CLIENT_SERVER}" client
    for ip in "${SLAVE_SERVERS[@]}"; do
        _status_services "${ip}" slave
    done

    echo ">>> Cluster info:"
    _run "${BEEGFS_MGMTD_HOST}" "
        echo '  Nodes (meta):'
        sudo beegfs-ctl --listnodes --nodetype=meta 2>&1
        echo '  Nodes (storage):'
        sudo beegfs-ctl --listnodes --nodetype=storage 2>&1
        echo ''
        echo '  Targets (state):'
        sudo beegfs-ctl --listtargets --state 2>&1
        echo ''
        echo '  Buddy groups (meta):'
        sudo beegfs-ctl --listmirrorgroups --nodetype=meta 2>&1
        echo '  Buddy groups (storage):'
        sudo beegfs-ctl --listmirrorgroups --nodetype=storage 2>&1
        echo ''
        echo '  Health df:'
        sudo beegfs-df 2>&1
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
    local rc=0 ip svc

    # [1] 关键服务 active (157: mgmtd+meta+helperd+client; slaves: meta+storage)
    echo ">>> [1/4] 服务状态..."
    _verify_svc() {
        local ip=$1 svc=$2
        if _run "${ip}" "sudo systemctl is-active --quiet ${svc}" 2>/dev/null; then
            echo "  OK   ${ip} ${svc}"
        else
            echo "  FAIL ${ip} ${svc} not active"; rc=1
        fi
    }
    _verify_svc "${CLIENT_SERVER}" beegfs-mgmtd
    _verify_svc "${CLIENT_SERVER}" beegfs-meta
    _verify_svc "${CLIENT_SERVER}" beegfs-helperd
    _verify_svc "${CLIENT_SERVER}" beegfs-client
    for ip in "${SLAVE_SERVERS[@]}"; do
        _verify_svc "${ip}" beegfs-meta
        _verify_svc "${ip}" beegfs-storage
    done

    # [2] 节点注册 (4 meta + 3 storage)
    echo ">>> [2/4] 节点注册..."
    local nodes n_meta n_storage
    n_meta=$(_run "${BEEGFS_MGMTD_HOST}" "sudo beegfs-ctl --listnodes --nodetype=meta 2>&1" | grep -cE '\[ID:' || true)
    n_storage=$(_run "${BEEGFS_MGMTD_HOST}" "sudo beegfs-ctl --listnodes --nodetype=storage 2>&1" | grep -cE '\[ID:' || true)
    echo "  meta: ${n_meta} (expect 4)  storage: ${n_storage} (expect 3)"
    [ "${n_meta}" -ge 4 ] || { echo "  FAIL meta count"; rc=1; }
    [ "${n_storage}" -ge 3 ] || { echo "  FAIL storage count"; rc=1; }

    # [3] storage targets (6 个, 状态 GOOD)
    echo ">>> [3/4] Storage targets (期望 6, 状态 GOOD)..."
    local targets n_tgt n_good
    targets=$(_run "${BEEGFS_MGMTD_HOST}" "sudo beegfs-ctl --listtargets --state 2>&1")
    echo "${targets}" | sed 's/^/    /'
    n_tgt=$(echo "${targets}" | grep -ciE '^\s+[0-9]+\s' || true)
    n_good=$(echo "${targets}" | grep -ciE '^\s+[0-9]+\s+.*Good' || true)
    echo "  storage targets GOOD: ${n_good} (expect >= 6)"
    [ "${n_good}" -ge 6 ] || { echo "  FAIL storage target count < 6 (storage 盘是否已准备?)"; rc=1; }

    # [4] buddy groups (5 个) + client mount
    echo ">>> [4/4] Buddy groups (期望 5) + client mount..."
    local mlist n_grp
    mlist=$(_run "${BEEGFS_MGMTD_HOST}" "sudo beegfs-ctl --listmirrorgroups --nodetype=meta 2>&1; echo '---'; sudo beegfs-ctl --listmirrorgroups --nodetype=storage 2>&1")
    n_grp=$(echo "${mlist}" | grep -cE '^\s+[0-9]+\s+[0-9]+\s+[0-9]+\s*$' || true)
    echo "  buddy groups: ${n_grp} (expect >= 5)"
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
sudo systemctl restart beegfs-helperd && \
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
        sudo beegfs-ctl --getentryinfo ${BEEGFS_MOUNT_POINT}/ 2>/dev/null || true
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
        setup_mirroring
        deploy_client
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
        setup_mirroring
        deploy_client
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
