#!/bin/bash
# ============================================================
# restart-repro-snapshot.sh — BeeGFS 重启可复现性实验·快照采集
#
# 用法: bash tests/restart-repro-snapshot.sh <label> <output_dir>
#   label:      如 iter1-before-restart / iter1-after-restart
#   output_dir: 快照文件输出目录
#
# 采集内容（157 客户端 + 3 slave 全套状态）:
#   157:  date/uptime/free, RDMA 速率(5s 增量), ibstat, RDMA 错误计数,
#         beegfs-net 连接, BeeGFS 服务运行时长, /proc/buddyinfo, meminfo THP
#   slave: uptime/free, BeeGFS 服务运行时长, beegfs-net 连接,
#         iostat w_await(NVMe), /proc/buddyinfo, meminfo THP,
#         beegfs-storage 线程数
# ============================================================
set -uo pipefail

LABEL="${1:?usage: $0 <label> <output_dir>}"
OUT_DIR="${2:?usage: $0 <label> <output_dir>}"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

OUT="${OUT_DIR}/${LABEL}-snapshot.txt"
mkdir -p "$OUT_DIR"

log(){ echo "$@" | tee -a "$OUT"; }

log "############################################################"
log "# Snapshot: ${LABEL}"
log "# Date: $(date)"
log "############################################################"
log ""

# ============================================================
# 157 (client) 侧快照
# ============================================================
log "======================================================"
log "=== 157 (client) ==="
log "======================================================"
log ""

log "--- date / uptime / load ---"
log "$(date)"
log "$(uptime)"
log ""

log "--- free -g ---"
log "$(free -g)"
log ""

log "--- ibstat (port state/rate) ---"
ibstat 2>/dev/null | tee -a "$OUT"
log ""

log "--- RDMA error counters (mlx5_0 + mlx5_1) ---"
for dev in mlx5_0 mlx5_1; do
    for port in 1; do
        base="/sys/class/infiniband/${dev}/ports/${port}/counters"
        log "  ${dev} port ${port}:"
        for c in port_xmit_discards port_xmit_wait port_rcv_errors port_xmit_retransmits; do
            val=$(cat "${base}/${c}" 2>/dev/null || echo "N/A")
            log "    ${c}: ${val}"
        done
    done
done
log ""

log "--- RDMA data rate (5s delta, mlx5_1) ---"
rcv1=$(cat /sys/class/infiniband/mlx5_1/ports/1/counters/port_rcv_data 2>/dev/null || echo 0)
xmt1=$(cat /sys/class/infiniband/mlx5_1/ports/1/counters/port_xmit_data 2>/dev/null || echo 0)
sleep 5
rcv2=$(cat /sys/class/infiniband/mlx5_1/ports/1/counters/port_rcv_data 2>/dev/null || echo 0)
xmt2=$(cat /sys/class/infiniband/mlx5_1/ports/1/counters/port_xmit_data 2>/dev/null || echo 0)
rcv_delta=$(( (rcv2 - rcv1) / 5 ))
xmt_delta=$(( (xmt2 - xmt1) / 5 ))
rcv_mibs=$(( rcv_delta / 1048576 ))
xmt_mibs=$(( xmt_delta / 1048576 ))
log "  port_rcv_data: ${rcv1} -> ${rcv2} (delta ${rcv_delta} B/s = ${rcv_mibs} MiB/s)"
log "  port_xmit_data: ${xmt1} -> ${xmt2} (delta ${xmt_delta} B/s = ${xmt_mibs} MiB/s)"
log "  (WekaIO RDMA 流量旁证: 若 rcv+xmt > 0 说明 WekaIO 在跑)"
log ""

log "--- beegfs-net (client 连接到 servers) ---"
echo 'Sunrise@801' | sudo -S beegfs-net 2>/dev/null | tee -a "$OUT" || log "  (beegfs-net unavailable)"
log ""

log "--- BeeGFS 服务运行时长 (157) ---"
for svc in beegfs-mgmtd beegfs-meta beegfs-helperd beegfs-client; do
    ts=$(systemctl show "${svc}" -p ActiveEnterTimestamp --value 2>/dev/null)
    active=$(systemctl show "${svc}" -p ActiveState --value 2>/dev/null)
    log "  ${svc}: ${active} since ${ts}"
done
log ""

log "--- /proc/buddyinfo (内存碎片, 157) ---"
cat /proc/buddyinfo 2>/dev/null | head -20 | tee -a "$OUT"
log ""

log "--- meminfo THP (157) ---"
grep -E 'AnonHugePages|HugePages|Hugepagesize' /proc/meminfo 2>/dev/null | tee -a "$OUT"
log ""

# ============================================================
# 3 slave 侧快照
# ============================================================
for ip in $SLAVE_IPS; do
    log "======================================================"
    log "=== slave ${ip} ==="
    log "======================================================"
    log ""

    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "sunrise@${ip}" "
        echo '--- date / uptime / load ---'
        date
        uptime
        echo ''
        echo '--- free -g ---'
        free -g
        echo ''
        echo '--- BeeGFS 服务运行时长 ---'
        for svc in beegfs-storage beegfs-meta; do
            ts=\$(systemctl show \${svc} -p ActiveEnterTimestamp --value 2>/dev/null)
            active=\$(systemctl show \${svc} -p ActiveState --value 2>/dev/null)
            echo \"  \${svc}: \${active} since \${ts}\"
        done
        echo ''
        echo '--- beegfs-net (storage 侧连接) ---'
        echo 'Sunrise@801' | sudo -S beegfs-net 2>/dev/null | head -40
        echo ''
        echo '--- iostat NVMe (1s x2, 取第二采样) ---'
        echo 'Sunrise@801' | sudo -S iostat -x 1 2 2>/dev/null | grep -E 'Device|nvme2n1|nvme3n1'
        echo ''
        echo '--- beegfs-storage 线程数 ---'
        pid=\$(pgrep -x beegfs-storage 2>/dev/null | head -1)
        if [ -n \"\${pid}\" ]; then
            grep Threads /proc/\${pid}/status 2>/dev/null
        else
            echo '  (beegfs-storage process not found)'
        fi
        echo ''
        echo '--- /proc/buddyinfo (内存碎片) ---'
        cat /proc/buddyinfo 2>/dev/null | head -10
        echo ''
        echo '--- meminfo THP ---'
        grep -E 'AnonHugePages|HugePages' /proc/meminfo 2>/dev/null
    " 2>/dev/null | tee -a "$OUT" || log "  (SSH to ${ip} failed)"
    log ""
done

log "======================================================"
log "# Snapshot complete: ${LABEL}"
log "# File: ${OUT}"
log "======================================================"
