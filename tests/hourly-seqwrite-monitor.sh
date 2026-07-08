#!/bin/bash
# ============================================================
# hourly-seqwrite-monitor.sh — 每小时采快照 + seqwrite，验证衰减假说
#
# 用法: bash tests/hourly-seqwrite-monitor.sh <output_dir> [num_hours]
#   output_dir:  结果目录
#   num_hours:   测试次数 (默认 16, 覆盖 15h 衰减窗口)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:?usage: $0 <output_dir> [num_hours]}"
NUM_HOURS="${2:-16}"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/seq_dirty_test"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

mkdir -p "$OUT_DIR"
SUMMARY="${OUT_DIR}/hourly-summary.md"
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

log "============================================================"
log "每小时 seqwrite 监控 — 验证衰减假说"
log "起始: $(date)"
log "重启时间: $(echo 'Sunrise@801' | sudo -S systemctl show beegfs-client -p ActiveEnterTimestamp --value 2>/dev/null)"
log "间隔: 3600s (1h), 次数: ${NUM_HOURS}"
log "============================================================"
log ""
log "| 小时 | bw (MiB/s) | clat_min (µs) | 时间 |"
log "|------|:----------:|:------------:|------|"

for h in $(seq 1 "$NUM_HOURS"); do
    if [ "$h" -gt 1 ]; then
        echo "[$(date)] sleeping 3600s until next measurement..."
        sleep 3600
    fi

    ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    label="hourly-h${h}"
    echo "[$(date)] === Hour ${h}/${NUM_HOURS} ==="

    # 采快照
    bash "${SCRIPT_DIR}/restart-repro-snapshot.sh" "$label" "$OUT_DIR" >/dev/null 2>&1

    # drop + fio
    drop_all_caches
    mkdir -p "$SEQ_DIR"
    of="${OUT_DIR}/${label}-seqwrite.txt"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
    rm -rf "$SEQ_DIR"/*

    bw=$(bwget "$of")
    clat=$(clatminget "$of")
    log "| ${h} | ${bw} | ${clat} | ${ts} |"

    # 如果连续 3 次低于 600, 可以提前结束
    if [ "$h" -ge 3 ] && [ "$bw" != "NA" ]; then
        if [ "$bw" -lt 600 ] 2>/dev/null; then
            prev1=$(bwget "${OUT_DIR}/hourly-h$((h-1))-seqwrite.txt" 2>/dev/null)
            prev2=$(bwget "${OUT_DIR}/hourly-h$((h-2))-seqwrite.txt" 2>/dev/null)
            if [ "${prev1:-NA}" != "NA" ] && [ "${prev2:-NA}" != "NA" ]; then
                if [ "$prev1" -lt 600 ] 2>/dev/null && [ "$prev2" -lt 600 ] 2>/dev/null; then
                    log ""
                    log "*** 连续 3 次低于 600 MiB/s, 衰减确认, 提前结束 ***"
                    break
                fi
            fi
        fi
    fi
done

log ""
log "============================================================"
log "监控结束: $(date)"
log "============================================================"
