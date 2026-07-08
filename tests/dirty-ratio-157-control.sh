#!/bin/bash
# ============================================================
# dirty-ratio-157-control.sh — 157 客户端 dirty_ratio 10 vs 20 单变量对照
#
# 目的: 验证 157 (客户端) dirty_ratio 是否影响 --direct=1 seqwrite
#       (BeeGFS tuneFileCacheType=buffered, --direct=1 仍走 buffered I/O)
#
# 实验:
#   Phase 1: 157 dirty_ratio=20 (默认), 3 轮 seqwrite
#   Phase 2: 157 dirty_ratio=10,        3 轮 seqwrite
#   Phase 3: 157 dirty_ratio=20 (改回), 3 轮 seqwrite (确认可逆)
#
# 单变量: 只改 157 dirty_ratio, slave 全程 dirty_ratio=10 不变
# 不重启服务, 只改 runtime 参数
# ============================================================
set -uo pipefail

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/seq_dirty_test"
RESULT_DIR="/tmp/beegfs-test/results/20260707-restart-repro/dirty-ratio-157-control"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

mkdir -p "$RESULT_DIR"
OUT="${RESULT_DIR}/summary.md"
log(){ echo "$@" | tee -a "$OUT"; }

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

set_157_dirty(){
    echo 'Sunrise@801' | sudo -S bash -c "echo $1 > /proc/sys/vm/dirty_ratio" 2>/dev/null
    local val=$(cat /proc/sys/vm/dirty_ratio)
    log "  157 dirty_ratio = ${val}"
}

run_phase() {
    local phase="$1" ratio="$2"
    log ""
    log "## Phase ${phase}: 157 dirty_ratio=${ratio} — $(date)"
    set_157_dirty "$ratio"
    mkdir -p "$SEQ_DIR"
    for i in 1 2 3; do
        drop_all_caches
        local of="${RESULT_DIR}/phase${phase}-r${i}.txt"
        fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
            --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
        local bw clat
        bw=$(bwget "$of")
        clat=$(clatminget "$of")
        log "  r${i}: WRITE=${bw} MiB/s, clat_min=${clat}µs"
        rm -rf "$SEQ_DIR"/*
        sleep 3
    done
    rm -rf "$SEQ_DIR"
}

# ============================================================

log "============================================================"
log "157 dirty_ratio 10 vs 20 单变量对照"
log "日期: $(date)"
log "口径: seqwrite, bs=256K, 4G, direct=1, end_fsync=1"
log "单变量: 只改 157 dirty_ratio, slave 全程 dirty_ratio=10"
log "============================================================"
log ""
log "--- 初始状态确认 ---"
log "  157 dirty_ratio: $(cat /proc/sys/vm/dirty_ratio)"
for ip in $SLAVE_IPS; do
    val=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" "cat /proc/sys/vm/dirty_ratio" 2>/dev/null)
    log "  slave ${ip} dirty_ratio: ${val}"
done
log ""

# Phase 1: dirty_ratio=20 (默认)
run_phase 1 20

# Phase 2: dirty_ratio=10
run_phase 2 10

# Phase 3: dirty_ratio=20 (改回, 确认可逆)
run_phase 3 20

# ============================================================
# 汇总
# ============================================================
log ""
log "============================================================"
log "## 汇总"
log ""
log "| Phase | 157 dirty_ratio | r1 (bw/clat_min) | r2 | r3 |"
log "|-------|:---------------:|:---:|:---:|:---:|"
for p in 1 2 3; do
    ratio=$(grep "157 dirty_ratio" "${RESULT_DIR}/summary.md" | sed -n "${p}p" | grep -oP '=\K[0-9]+')
    line="| ${p} | ${ratio} |"
    for i in 1 2 3; do
        bw=$(bwget "${RESULT_DIR}/phase${p}-r${i}.txt")
        clat=$(clatminget "${RESULT_DIR}/phase${p}-r${i}.txt")
        line="${line} ${bw}/${clat}µs |"
    done
    log "$line"
done
log ""
log "DONE: $(date)"
