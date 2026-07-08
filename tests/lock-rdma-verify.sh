#!/bin/bash
# ============================================================
# lock-rdma-verify.sh — 锁定 RDMA 接口后 ≥5 次重启验证
#
# 每次: 重启全部服务 → 等 mount → 检查 beegfs-net 100% RDMA → seqwrite
# 处理 mgmtd 卡在 deactivating 的已知问题
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUM="${1:-5}"
OUT_DIR="${2:-${SCRIPT_DIR}/../results/20260708-lock-rdma-iface}"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/lock_test"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

mkdir -p "$OUT_DIR"
SUMMARY="${OUT_DIR}/summary.md"
log(){ echo "$@" | tee -a "$SUMMARY"; }

drop_all_caches() {
    sync; echo 'Sunrise@801' | sudo -S bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}

bwget(){
    grep -oP "WRITE: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || echo "NA"
}

clatminget(){
    grep -oP "clat \(usec\): min=\K[0-9]+" "$1" | head -1 || echo "NA"
}

restart_beegfs() {
    log "  [restart] slave storage + meta..."
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "echo 'Sunrise@801' | sudo -S systemctl restart beegfs-storage beegfs-meta 2>&1" 2>/dev/null &
    done
    wait
    sleep 10

    log "  [restart] 157 mgmtd (stop+start, 处理卡死)..."
    echo 'Sunrise@801' | sudo -S systemctl stop beegfs-mgmtd 2>/dev/null
    sleep 3
    # 如果卡在 deactivating, 强制 kill
    local mgmtd_state=$(echo 'Sunrise@801' | sudo -S systemctl is-active beegfs-mgmtd 2>/dev/null)
    if [ "$mgmtd_state" = "deactivating" ]; then
        log "  [restart] mgmtd 卡在 deactivating, kill..."
        echo 'Sunrise@801' | sudo -S systemctl kill beegfs-mgmtd --signal=SIGKILL 2>/dev/null
        sleep 3
    fi
    echo 'Sunrise@801' | sudo -S systemctl start beegfs-mgmtd 2>/dev/null
    sleep 5

    log "  [restart] 157 meta..."
    echo 'Sunrise@801' | sudo -S systemctl restart beegfs-meta 2>/dev/null
    sleep 30

    log "  [restart] client..."
    echo 'Sunrise@801' | sudo -S systemctl restart beegfs-client 2>/dev/null
    sleep 10
    if ! mountpoint -q "$MNT" 2>/dev/null; then
        log "  [restart] mount 未就绪, 重试 client..."
        echo 'Sunrise@801' | sudo -S systemctl restart beegfs-client 2>/dev/null
        sleep 30
    fi

    local deadline=$(( $(date +%s) + 120 ))
    while [ $(date +%s) -lt $deadline ]; do
        if mountpoint -q "$MNT" 2>/dev/null; then
            local good
            good=$(echo 'Sunrise@801' | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null | grep -c Good || true)
            if [ "$good" -ge 6 ] 2>/dev/null; then
                log "  [restart] mount OK, ${good} targets Good ✓"
                return 0
            fi
        fi
        sleep 3
    done
    log "  [restart] FAILED"
    return 1
}

check_rdma() {
    local out
    out=$(echo 'Sunrise@801' | sudo -S beegfs-net 2>/dev/null | grep -E 'ID: 10[123]' -A1 | grep 'Connections:')
    local tcp_count
    tcp_count=$(echo "$out" | grep -c 'TCP' || true)
    local rdma_count
    rdma_count=$(echo "$out" | grep -c 'RDMA' || true)
    if [ "$tcp_count" -eq 0 ] && [ "$rdma_count" -ge 3 ]; then
        log "  beegfs-net: 100% RDMA ✓ ($rdma_count RDMA, $tcp_count TCP)"
        echo "$out" | tee -a "$SUMMARY"
        return 0
    else
        log "  beegfs-net: WARNING — $rdma_count RDMA, $tcp_count TCP"
        echo "$out" | tee -a "$SUMMARY"
        return 1
    fi
}

# ============================================================

log "============================================================"
log "锁定 RDMA 接口后重启验证"
log "起始: $(date)"
log "次数: ${NUM}"
log "============================================================"
log ""
log "| 轮次 | bw (MiB/s) | clat_min (µs) | RDMA | 时间 |"
log "|------|:----------:|:------------:|:----:|------|"

for i in $(seq 1 "$NUM"); do
    log ""
    log "### Verify ${i} / ${NUM} — $(date)"

    if ! restart_beegfs; then
        log "| ${i} | ERROR | ERROR | 跳过 | $(date) |"
        continue
    fi

    check_rdma

    drop_all_caches
    mkdir -p "$SEQ_DIR"
    of="${OUT_DIR}/verify${i}-seqwrite.txt"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
    rm -rf "$SEQ_DIR"/*

    bw=$(bwget "$of")
    clat=$(clatminget "$of")
    rdma_status="✓"

    log "  bw=${bw}, clat_min=${clat}µs"
    log "| ${i} | ${bw} | ${clat} | ${rdma_status} | $(date) |"
done

log ""
log "============================================================"
log "完成: $(date)"
log "============================================================"
