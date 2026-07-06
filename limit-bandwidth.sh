#!/bin/bash
set -euo pipefail

# ============================================================
# BeeGFS 带宽限速脚本 — 千兆网卡环境模拟
#
# 策略:
#   1. 用 connInterfacesFile 强制 BeeGFS 走独立网卡 eno12409
#   2. 在该网卡上加 TBF qdisc 限速 1Gbps
#   3. 不影响 157 上的 K8s 业务 (K8s 走 eno12399 + tunl0)
#
# apply:  配置 connInterfacesFile + TBF 1Gbps + 重启服务
# remove: 恢复 connInterfacesFile 默认 + 删除 TBF + 重启服务
# status: 检查各节点限速状态
#
# 用法: bash limit-bandwidth.sh [apply|remove|status]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET_IFACE="eno12409"
CONN_CONF="/etc/beegfs/connInf.conf"
LIMIT_RATE="1gbit"
LIMIT_BURST="32kb"
LIMIT_LATENCY="50ms"

_run() {
    local ip=$1 cmd=$2
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "${cmd}"
    else
        ssh_to_slave "${ip}" "${cmd}"
    fi
}

apply_limit() {
    echo "========================================"
    echo "BeeGFS 带宽限速 — 1Gbps 千兆环境模拟"
    echo "网卡: ${TARGET_IFACE} | 其他流量不受影响"
    echo "========================================"
    echo ""

    # ---- 157 (client + mgmtd + meta + helperd) ----
    echo ">>> ${CLIENT_SERVER} (157: mgmtd+meta+client+helperd)"
    _run "${CLIENT_SERVER}" "
        set -e
        # 1. 创建 connInf.conf
        echo '${TARGET_IFACE}' | sudo tee ${CONN_CONF} >/dev/null

        # 2. 配置各服务使用 connInf.conf
        for conf in beegfs-client.conf beegfs-meta.conf beegfs-mgmtd.conf beegfs-helperd.conf; do
            sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(connInterfacesFile\)[[:space:]]*=.*|\1            = ${CONN_CONF}|' /etc/beegfs/\$conf
        done

        # 3. TBF 限速
        sudo tc qdisc del dev ${TARGET_IFACE} root 2>/dev/null || true
        sudo tc qdisc add dev ${TARGET_IFACE} root tbf rate ${LIMIT_RATE} burst ${LIMIT_BURST} latency ${LIMIT_LATENCY}
        echo '  TBF ${LIMIT_RATE} on ${TARGET_IFACE}'

        # 4. 重启服务 (逐个处理, 避免 mgmtd deactivating 卡死)
        for svc in beegfs-client beegfs-helperd beegfs-meta beegfs-mgmtd; do
            echo -n \"  restarting \${svc}...\"
            sudo timeout 45 systemctl stop \"\${svc}\" 2>/dev/null || {
                sudo systemctl kill -s SIGKILL \"\${svc}\" 2>/dev/null || true
                sleep 2
            }
            sudo systemctl reset-failed \"\${svc}\" 2>/dev/null || true
            sudo systemctl start \"\${svc}\" 2>/dev/null || true
            sleep 2
            if sudo systemctl is-active --quiet \"\${svc}\" 2>/dev/null; then
                echo ' OK'
            else
                echo ' FAIL (will retry in final check)'
            fi
        done
        sleep 5

        # 最终检查
        echo ''
        ok=0
        for svc in beegfs-mgmtd beegfs-meta beegfs-helperd beegfs-client; do
            if sudo systemctl is-active --quiet \"\${svc}\" 2>/dev/null; then
                echo \"  \${svc}: active\"
                ok=\$((ok+1))
            else
                echo \"  \${svc}: FAILED\"
            fi
        done
        if mountpoint -q ${BEEGFS_MOUNT_POINT} 2>/dev/null; then
            echo '  mount: OK'
        else
            echo '  mount: NOT mounted'
        fi
        [ \"\$ok\" -eq 4 ] || { echo 'ERROR: not all services active'; exit 1; }
    "

    # ---- Slaves (150-152: meta + storage) ----
    for ip in "${SLAVE_SERVERS[@]}"; do
        echo ""
        echo ">>> ${ip} (slave: meta+storage)"
        _run "${ip}" "
            set -e
            echo '${TARGET_IFACE}' | sudo tee ${CONN_CONF} >/dev/null

            for conf in beegfs-meta.conf beegfs-storage.conf; do
                sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*\(connInterfacesFile\)[[:space:]]*=.*|\1            = ${CONN_CONF}|' /etc/beegfs/\$conf
            done

            sudo tc qdisc del dev ${TARGET_IFACE} root 2>/dev/null || true
            sudo tc qdisc add dev ${TARGET_IFACE} root tbf rate ${LIMIT_RATE} burst ${LIMIT_BURST} latency ${LIMIT_LATENCY}
            echo '  TBF ${LIMIT_RATE} on ${TARGET_IFACE}'

            for svc in beegfs-storage beegfs-meta; do
                echo -n \"  restarting \${svc}...\"
                sudo timeout 30 systemctl stop \"\${svc}\" 2>/dev/null || true
                sudo systemctl reset-failed \"\${svc}\" 2>/dev/null || true
                sudo systemctl start \"\${svc}\" 2>/dev/null || true
                sleep 2
                sudo systemctl is-active --quiet \"\${svc}\" 2>/dev/null && echo ' OK' || echo ' FAIL'
            done
        "
    done

    echo ""
    echo "========================================"
    echo "限速已应用: 所有节点 ${TARGET_IFACE} → 1Gbps"
    echo "K8s 业务不受影响 (走 eno12399 + tunl0)"
    echo "========================================"
}

remove_limit() {
    echo "========================================"
    echo "移除 BeeGFS 带宽限速"
    echo "========================================"
    echo ""

    # 157
    echo ">>> ${CLIENT_SERVER} (157)"
    _run "${CLIENT_SERVER}" "
        set -e
        sudo tc qdisc del dev ${TARGET_IFACE} root 2>/dev/null || true
        echo '  TBF removed'

        for conf in beegfs-client.conf beegfs-meta.conf beegfs-mgmtd.conf beegfs-helperd.conf; do
            sudo sed -i 's|^connInterfacesFile.*=.*|connInterfacesFile            =|' /etc/beegfs/\$conf
        done
        sudo rm -f ${CONN_CONF}

        for svc in beegfs-client beegfs-helperd beegfs-meta beegfs-mgmtd; do
            echo -n \"  restarting \${svc}...\"
            sudo timeout 45 systemctl stop \"\${svc}\" 2>/dev/null || {
                sudo systemctl kill -s SIGKILL \"\${svc}\" 2>/dev/null || true
                sleep 2
            }
            sudo systemctl reset-failed \"\${svc}\" 2>/dev/null || true
            sudo systemctl start \"\${svc}\" 2>/dev/null || true
            sleep 2
            echo ' OK'
        done
        sleep 5
        echo ''
        for svc in beegfs-mgmtd beegfs-meta beegfs-helperd beegfs-client; do
            echo -n \"  \${svc}: \"; sudo systemctl is-active \${svc} 2>/dev/null || echo 'inactive'
        done
        mountpoint -q ${BEEGFS_MOUNT_POINT} 2>/dev/null && echo '    mount: OK' || echo '    mount: NOT mounted'
    "

    for ip in "${SLAVE_SERVERS[@]}"; do
        echo ""
        echo ">>> ${ip}"
        _run "${ip}" "
            set -e
            sudo tc qdisc del dev ${TARGET_IFACE} root 2>/dev/null || true
            echo '  TBF removed'

            for conf in beegfs-meta.conf beegfs-storage.conf; do
                sudo sed -i 's|^connInterfacesFile.*=.*|connInterfacesFile            =|' /etc/beegfs/\$conf
            done
            sudo rm -f ${CONN_CONF}

            for svc in beegfs-storage beegfs-meta; do
                echo -n \"  restarting \${svc}...\"
                sudo timeout 30 systemctl stop \"\${svc}\" 2>/dev/null || true
                sudo systemctl reset-failed \"\${svc}\" 2>/dev/null || true
                sudo systemctl start \"\${svc}\" 2>/dev/null || true
                sleep 2
                echo ' OK'
            done
        "
    done

    echo ""
    echo "========================================"
    echo "限速已移除, BeeGFS 恢复默认多网卡自动选择"
    echo "========================================"
}

show_status() {
    echo "========================================"
    echo "BeeGFS 带宽限速状态"
    echo "========================================"

    for ip in "${ALL_SERVERS[@]}"; do
        echo ""
        echo ">>> ${ip} ($(_run "${ip}" 'hostname' 2>/dev/null | tail -1 || echo "${ip}"))"
        _run "${ip}" "
            echo -n '  ${TARGET_IFACE} TBF: '
            qdisc_out=\$(tc -s qdisc show dev ${TARGET_IFACE} 2>/dev/null)
            rate=\$(echo \"\$qdisc_out\" | grep -oP 'tbf.*rate \K[0-9A-Za-z]+' | head -1)
            if [ -z \"\$rate\" ]; then
                echo '未限速'
            else
                overlimits=\$(echo \"\$qdisc_out\" | grep -oP 'overlimits \K[0-9]+' | head -1)
                dropped=\$(echo \"\$qdisc_out\" | grep -oP 'dropped \K[0-9]+' | head -1)
                sent=\$(echo \"\$qdisc_out\" | grep -oP 'Sent \K[0-9]+ bytes' | head -1 || echo '0 bytes')
                echo \"rate=\${rate} overlimits=\${overlimits:-0} dropped=\${dropped:-0} sent=\${sent}\"
                if [ \"\${overlimits:-0}\" -eq 0 ]; then
                    echo '    (无流量通过, 打流后 overlimits>0 才表示限速生效)'
                fi
            fi

            echo -n '  connInterfacesFile: '
            val=\$(grep '^connInterfacesFile[[:space:]]*=' /etc/beegfs/beegfs-client.conf 2>/dev/null | grep -oP '= \K.*' | head -1)
            if [ -z \"\$val\" ]; then
                val=\$(grep '^connInterfacesFile[[:space:]]*=' /etc/beegfs/beegfs-meta.conf 2>/dev/null | grep -oP '= \K.*' | head -1)
            fi
            val=\"\${val## }\"
            if [ -z \"\$val\" ]; then
                echo '(default: multi-interface auto)'
            elif [ \"\$val\" = '${CONN_CONF}' ]; then
                if [ -f '${CONN_CONF}' ]; then
                    echo \"\${val} → \$(cat ${CONN_CONF})\"
                else
                    echo \"\${val} ← FILE MISSING\"
                fi
            else
                echo \"\${val}\"
            fi
        "
    done
    echo ""
}

ACTION="${1:-status}"

case "${ACTION}" in
    apply)
        apply_limit
        ;;
    remove)
        remove_limit
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: bash limit-bandwidth.sh [apply|remove|status]"
        echo ""
        echo "  apply   - 强制 BeeGFS 走 ${TARGET_IFACE} + TBF 1Gbps + 重启服务"
        echo "  remove  - 恢复多网卡默认 + 删除 TBF + 重启服务"
        echo "  status  - 检查各节点限速和配置状态"
        ;;
esac
