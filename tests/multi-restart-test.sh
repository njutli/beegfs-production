#!/bin/bash
# ============================================================
# multi-restart-test.sh — 多次重启测试，每次采快照 + seqwrite
#
# 用法: bash tests/multi-restart-test.sh <num_restarts> [output_dir]
#   num_restarts: 重启次数 (默认 8)
#   output_dir:   结果目录
#
# 每轮: 重启全部服务 → 等 mount → 采快照 → drop_caches → seqwrite
# 不改任何配置参数, 只重启。每次重启方式一致。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUM_RESTARTS="${1:-8}"
OUT_DIR="${2:-${SCRIPT_DIR}/../results/20260707-restart-repro/multi-restart}"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/seq_restart_test"
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

    log "  [restart] 157 meta + mgmtd..."
    echo 'Sunrise@801' | sudo -S systemctl restart beegfs-meta beegfs-mgmtd 2>&1
    sleep 30

    log "  [restart] client..."
    echo 'Sunrise@801' | sudo -S systemctl restart beegfs-client 2>&1
    sleep 10

    # 如果 mount 没就绪, 重试一次
    if ! mountpoint -q "$MNT" 2>/dev/null; then
        log "  [restart] mount 未就绪, 重试 client..."
        echo 'Sunrise@801' | sudo -S systemctl restart beegfs-client 2>&1
        sleep 30
    fi

    # 等 mount 就绪
    local deadline=$(( $(date +%s) + 180 ))
    while [ $(date +%s) -lt $deadline ]; do
        if mountpoint -q "$MNT" 2>/dev/null; then
            log "  [restart] mount OK ✓"
            # 等 target 全 Good
            local td=$(( $(date +%s) + 60 ))
            while [ $(date +%s) -lt $td ]; do
                local good
                good=$(echo 'Sunrise@801' | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null | grep -c Good || true)
                if [ "$good" -ge 6 ] 2>/dev/null; then
                    log "  [restart] ${good} targets Good ✓"
                    return 0
                fi
                sleep 3
            done
            log "  [restart] mount OK 但 target 未全 Good"
            return 0
        fi
        sleep 3
    done
    log "  [restart] mount FAILED after 180s"
    return 1
}

# ============================================================

log "============================================================"
log "多次重启测试 — 每次采快照 + seqwrite"
log "起始: $(date)"
log "次数: ${NUM_RESTARTS}"
log "============================================================"
log ""
log "| 轮次 | bw (MiB/s) | clat_min (µs) | 状态 | 快照 |"
log "|------|:----------:|:------------:|:----:|:----:|"

for i in $(seq 1 "$NUM_RESTARTS"); do
    log ""
    log "### Restart ${i} / ${NUM_RESTARTS} — $(date)"

    if ! restart_beegfs; then
        log "| ${i} | ERROR | ERROR | mount失败 | 跳过 |"
        continue
    fi

    # 采快照
    log "  采快照..."
    bash "${SCRIPT_DIR}/restart-repro-snapshot.sh" "restart${i}" "$OUT_DIR" >/dev/null 2>&1

    # drop + seqwrite
    log "  seqwrite..."
    drop_all_caches
    mkdir -p "$SEQ_DIR"
    of="${OUT_DIR}/restart${i}-seqwrite.txt"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
    rm -rf "$SEQ_DIR"/*

    bw=$(bwget "$of")
    clat=$(clatminget "$of")

    # 判定状态
    state="900态"
    if [ "$bw" != "NA" ] && [ "$bw" -lt 600 ] 2>/dev/null; then
        state="479态 ★"
    fi

    log "  bw=${bw} MiB/s, clat_min=${clat}µs → ${state}"
    log "| ${i} | ${bw} | ${clat} | ${state} | ✓ |"
done

log ""
log "============================================================"
log "完成: $(date)"
log "============================================================"
