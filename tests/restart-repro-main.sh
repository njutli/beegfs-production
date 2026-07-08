#!/bin/bash
# ============================================================
# restart-repro-main.sh — BeeGFS 服务重启可复现性实验·主循环
#
# 用法: bash tests/restart-repro-main.sh <num_iterations> [output_dir]
#   num_iterations: 重启轮次 (默认 8)
#   output_dir:     结果目录 (默认 results/20260707-restart-repro)
#
# 每轮流程:
#   1. 采 before 快照 + seqwrite (bw_before)
#   2. 重启全部 BeeGFS 服务 (slave storage+meta → 157 meta+mgmtd → client)
#   3. 等 target 全 Online/Good (轮询 120s 超时)
#   4. 采 after 快照 + seqwrite (bw_after_t0)
#   5. 等 10 分钟 (让服务"变旧")
#   6. 再测 seqwrite (bw_after_t10)
#   7. 记录三元组 (bw_before, bw_after_t0, bw_after_t10)
#
# 不改任何配置参数, 只重启。每次重启方式一致 (单变量前提)。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUM_ITER="${1:-8}"
OUT_DIR="${2:-${SCRIPT_DIR}/../results/20260707-restart-repro}"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/seq_restart_test"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

mkdir -p "$OUT_DIR"
SUMMARY="${OUT_DIR}/summary.md"
log(){ echo "$@" | tee -a "$SUMMARY"; }

# --- helpers ---

drop_all_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}

bwget(){
    local raw
    raw=$(grep -oP "WRITE: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1)
    if [ -z "$raw" ]; then
        raw=$(grep -oP "WRITE: bw=\K[0-9.]+(?=GiB/s)" "$1" | head -1)
        [ -n "$raw" ] && raw=$(awk "BEGIN {printf \"%.0f\", $raw * 1024}")
    fi
    echo "${raw:-NA}"
}

clatminget(){
    grep -oP "clat \(usec\): min=\K[0-9]+" "$1" | head -1 || echo "NA"
}

run_seqwrite() {
    local outfile="$1"
    mkdir -p "$SEQ_DIR"
    drop_all_caches
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --end_fsync=1 --group_reporting > "$outfile" 2>&1
    rm -rf "$SEQ_DIR"/*
}

restart_beegfs() {
    log "  [restart] 重启 slave storage + meta..."
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "echo 'Sunrise@801' | sudo -S systemctl restart beegfs-storage beegfs-meta 2>&1" 2>/dev/null &
    done
    wait
    sleep 10

    log "  [restart] 重启 157 meta + mgmtd..."
    echo 'Sunrise@801' | sudo -S systemctl restart beegfs-meta beegfs-mgmtd 2>&1
    sleep 15

    log "  [restart] 重挂 client..."
    echo 'Sunrise@801' | sudo -S systemctl restart beegfs-client 2>&1
    sleep 5

    log "  [restart] 等待 target 全 Online/Good..."
    local deadline=$(( $(date +%s) + 120 ))
    while [ $(date +%s) -lt $deadline ]; do
        local state total good
        state=$(echo 'Sunrise@801' | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null)
        total=$(echo "$state" | grep -cE 'Good' || true)
        total=${total:-0}
        good=$total
        if [ "$total" -gt 0 ] 2>/dev/null; then
            log "  [restart] 全 ${total} storage target Online/Good ✓"
            break
        fi
        sleep 3
    done

    local meta_state meta_good
    meta_state=$(echo 'Sunrise@801' | sudo -S beegfs-ctl --listtargets --state --nodetype=meta 2>/dev/null)
    meta_good=$(echo "$meta_state" | grep -cE 'Good' || true)
    meta_good=${meta_good:-0}
    log "  [restart] meta targets: ${meta_good} Good"

    log "  [restart] 等待 mountpoint 就绪..."
    local mnt_deadline=$(( $(date +%s) + 180 ))
    while [ $(date +%s) -lt $mnt_deadline ]; do
        if mountpoint -q "$MNT" 2>/dev/null; then
            log "  [restart] mount ${MNT} OK ✓"
            return 0
        fi
        sleep 3
    done
    log "  [restart] WARNING: mount ${MNT} not ready after 120s!"
    return 1
}

# ============================================================
# 主循环
# ============================================================

log "============================================================"
log "BeeGFS 重启可复现性实验"
log "日期: $(date)"
log "轮次: ${NUM_ITER}"
log "结果目录: ${OUT_DIR}"
log "============================================================"
log ""
log "| 轮次 | bw_before | bw_after_t0 | bw_after_t10 | clat_min_after_t0 | 命中~835 |"
log "|------|:---------:|:-----------:|:------------:|:-----------------:|:--------:|"

for i in $(seq 1 "$NUM_ITER"); do
    log ""
    log "### Iteration ${i} / ${NUM_ITER} — $(date)"

    # 1. before 快照 + seqwrite
    log "  [1/4] 采 before 快照 + seqwrite..."
    bash "${SCRIPT_DIR}/restart-repro-snapshot.sh" "iter${i}-before-restart" "${OUT_DIR}" >/dev/null 2>&1
    run_seqwrite "${OUT_DIR}/iter${i}-before-seqwrite.txt"
    bw_before=$(bwget "${OUT_DIR}/iter${i}-before-seqwrite.txt")
    log "  bw_before = ${bw_before} MiB/s"

    # 2. 重启全部服务
    log "  [2/4] 重启 BeeGFS 全部服务..."
    if ! restart_beegfs; then
        log "  [WARN] mount 未恢复, 尝试再次重启 client..."
        echo 'Sunrise@801' | sudo -S systemctl restart beegfs-client 2>&1
        sleep 30
        if ! mountpoint -q "$MNT" 2>/dev/null; then
            log "  [ERROR] mount 仍不可用, 跳过本轮 after 测试"
            log "| ${i} | ${bw_before} | ERROR | ERROR | ERROR | 跳过 |"
            continue
        fi
    fi

    # 3. after 快照 + seqwrite (t0)
    log "  [3/4] 采 after 快照 + seqwrite (t0)..."
    bash "${SCRIPT_DIR}/restart-repro-snapshot.sh" "iter${i}-after-restart" "${OUT_DIR}" >/dev/null 2>&1
    run_seqwrite "${OUT_DIR}/iter${i}-after-t0-seqwrite.txt"
    bw_after_t0=$(bwget "${OUT_DIR}/iter${i}-after-t0-seqwrite.txt")
    clat_min_t0=$(clatminget "${OUT_DIR}/iter${i}-after-t0-seqwrite.txt")
    log "  bw_after_t0 = ${bw_after_t0} MiB/s, clat_min = ${clat_min_t0}µs"

    # 4. 等 10 分钟, 再测 (t10)
    log "  [4/4] 等待 10 分钟..."
    sleep 600
    run_seqwrite "${OUT_DIR}/iter${i}-after-t10-seqwrite.txt"
    bw_after_t10=$(bwget "${OUT_DIR}/iter${i}-after-t10-seqwrite.txt")
    log "  bw_after_t10 = ${bw_after_t10} MiB/s"

    # 判定命中
    hit="否"
    if [ "$bw_after_t0" != "NA" ]; then
        if [ "$bw_after_t0" -ge 750 ] 2>/dev/null; then
            hit="是 ★"
        fi
    fi

    log "| ${i} | ${bw_before} | ${bw_after_t0} | ${bw_after_t10} | ${clat_min_t0} | ${hit} |"
done

log ""
log "============================================================"
log "实验完成: $(date)"
log "============================================================"
log ""
log "全部结果见: ${OUT_DIR}/"
log "每轮快照: iter{i}-{before,after}-snapshot.txt"
log "原始 fio: iter{i}-{before,after-t0,after-t10}-seqwrite.txt"
