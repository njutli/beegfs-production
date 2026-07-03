#!/bin/bash
set -euo pipefail

# ============================================================
# 带宽限速脚本 — 将 100GbE 接口临时限速到 1Gbps
#
# 用于与千兆网卡环境做性能对比测试。
# 测试后用 "remove" 恢复原速。
#
# 用法: bash limit-bandwidth.sh [apply|remove|status]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# 限速目标：所有节点的 10GbE 接口 (BeeGFS 数据走 eno12399, 10.20.1.0/24)
# 限到 1Gbps 模拟千兆环境, 用于与千兆集群方案对比测试。
TARGET_IFACE="eno12399"
LIMIT_RATE="1gbit"
LIMIT_BURST="10mb"
LIMIT_LATENCY="100ms"

# 所有需要限速的节点
LIMIT_SERVERS=( "${CLIENT_SERVER}" "${SLAVE_SERVERS[@]}" )

_run_ssh() {
    local ip=$1; shift
    if [ "$ip" = "${CLIENT_SERVER}" ]; then
        ssh_to_client "$@"
    else
        ssh_to_slave "$ip" "$@"
    fi
}

apply_limit() {
    echo "========================================"
    echo "Applying 1Gbps bandwidth limit on ${TARGET_IFACE}"
    echo "========================================"

    for ip in "${LIMIT_SERVERS[@]}"; do
        echo ">>> ${ip}..."
        _run_ssh "${ip}" "
            echo 'Sunrise@801' | sudo -S bash -c '
                # Remove existing qdisc if any
                tc qdisc del dev ${TARGET_IFACE} root 2>/dev/null || true

                # Add TBF (Token Bucket Filter) to limit to 1Gbps
                tc qdisc add dev ${TARGET_IFACE} root tbf \
                    rate ${LIMIT_RATE} \
                    burst ${LIMIT_BURST} \
                    latency ${LIMIT_LATENCY}

                echo \"  Applied: ${LIMIT_RATE} on ${TARGET_IFACE}\"
                tc qdisc show dev ${TARGET_IFACE}
            '
        " 2>/dev/null
        echo ""
    done

    echo "========================================"
    echo "Bandwidth limit applied: 1Gbps on all nodes"
    echo "========================================"
    echo ""
    echo "To restore: bash limit-bandwidth.sh remove"
}

remove_limit() {
    echo "========================================"
    echo "Removing bandwidth limit from ${TARGET_IFACE}"
    echo "========================================"

    for ip in "${LIMIT_SERVERS[@]}"; do
        echo ">>> ${ip}..."
        _run_ssh "${ip}" "
            echo 'Sunrise@801' | sudo -S bash -c '
                tc qdisc del dev ${TARGET_IFACE} root 2>/dev/null || true
                echo \"  Removed limit from ${TARGET_IFACE}\"
                tc qdisc show dev ${TARGET_IFACE}
            '
        " 2>/dev/null
        echo ""
    done

    echo "========================================"
    echo "Bandwidth limit removed. Full 100Gbps restored."
    echo "========================================"
}

show_status() {
    echo "========================================"
    echo "Bandwidth limit status"
    echo "========================================"

    for ip in "${LIMIT_SERVERS[@]}"; do
        echo ">>> ${ip} ($(_run_ssh "${ip}" 'hostname' 2>/dev/null)):"
        _run_ssh "${ip}" "
            echo 'Sunrise@801' | sudo -S tc qdisc show dev ${TARGET_IFACE} 2>/dev/null
        " 2>/dev/null
        echo ""
    done
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
        echo "  apply   - Limit ${TARGET_IFACE} to 1Gbps on all nodes"
        echo "  remove  - Remove limit, restore full 100Gbps"
        echo "  status  - Show current qdisc status"
        ;;
esac
