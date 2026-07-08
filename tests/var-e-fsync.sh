#!/bin/bash
# ============================================================
# var-e-fsync.sh — 变量 E: fsync vs 非fsync 对照诊断
#
# 拆分"后端落盘确认瓶颈"与"客户端聚合瓶颈"
# --end_fsync=1: 写完所有数据后调 fsync 等落盘确认
# 无 --end_fsync: 写完即返回, 数据可能未落盘
# 对比两者带宽差异 → 判断瓶颈在后端(NVMe sync)还是前端(网络/聚合)
#
# 用法: 在 157 上运行
#   bash /tmp/var-e-fsync.sh
# ============================================================
set -uo pipefail

OUT_DIR="/tmp/stage1-fsync"
mkdir -p "$OUT_DIR"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/e_fsync_test"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
ROUNDS=2

SUMMARY="${OUT_DIR}/summary.md"
> "$SUMMARY"
log(){ echo "$@" | tee -a "$SUMMARY"; }

drop_all_caches() {
    sync
    echo "${SSH_PASS}" | sudo -S bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}

check_rdma() {
    local out
    out=$(echo "${SSH_PASS}" | sudo -S beegfs-net 2>/dev/null | grep -E 'ID: 10[123]' -A1 | grep 'Connections:')
    local tcp_count=$(echo "$out" | grep -c 'TCP' || true)
    local rdma_count=$(echo "$out" | grep -c 'RDMA' || true)
    if [ "$tcp_count" -eq 0 ] && [ "$rdma_count" -ge 3 ]; then
        log "  beegfs-net: 100% RDMA ✓"
        return 0
    else
        log "  beegfs-net: WARNING — ${rdma_count} RDMA, ${tcp_count} TCP"
        return 1
    fi
}

bwget(){ grep -oP "WRITE: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || echo "NA"; }
clatminget(){ grep -oP "clat \(usec\): min=\K[0-9]+" "$1" | head -1 || echo "NA"; }

# ============================================================
# 主逻辑
# ============================================================
log "============================================================"
log "变量 E: fsync vs 非fsync 对照诊断"
log "起始: $(date)"
log "每值轮数: ${ROUNDS}"
log "============================================================"
log ""

# RDMA 哨兵
log "### 初始 RDMA 哨兵检查"
check_rdma
log ""

log "| Mode | 轮次 | bw (MiB/s) | clat_min (µs) | run (ms) | RDMA |"
log "|------|:----:|:----------:|:------------:|:--------:|:----:|"

mkdir -p "$SEQ_DIR"

# fsync=1 (基线口径)
for r in $(seq 1 "$ROUNDS"); do
    drop_all_caches
    of="${OUT_DIR}/fsync-r${r}-seqwrite.txt"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
    rm -rf "${SEQ_DIR}"/*
    bw=$(bwget "$of")
    clat=$(clatminget "$of")
    runms=$(grep -oP "run=\K[0-9]+" "$of" | head -1)
    log "  fsync r${r}: bw=${bw}, clat_min=${clat}µs, run=${runms}ms"
    log "| fsync | r${r} | ${bw} | ${clat} | ${runms} | ✓ |"
done

# no-fsync
for r in $(seq 1 "$ROUNDS"); do
    drop_all_caches
    of="${OUT_DIR}/nofsync-r${r}-seqwrite.txt"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --group_reporting > "$of" 2>&1
    rm -rf "${SEQ_DIR}"/*
    bw=$(bwget "$of")
    clat=$(clatminget "$of")
    runms=$(grep -oP "run=\K[0-9]+" "$of" | head -1)
    log "  nofsync r${r}: bw=${bw}, clat_min=${clat}µs, run=${runms}ms"
    log "| nofsync | r${r} | ${bw} | ${clat} | ${runms} | ✓ |"
done

# 清理
rm -rf "$SEQ_DIR"

log ""
log "============================================================"
log "完成: $(date)"
log "结果目录(157): ${OUT_DIR}"
log "============================================================"
