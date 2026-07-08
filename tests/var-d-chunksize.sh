#!/bin/bash
# ============================================================
# var-d-chunksize.sh — 变量 D: chunksize 单变量测试
#
# 测试值: 512K / 1M(基线) / 2M / 4M, 每值 ≥2 轮 seqwrite
# 用 beegfs-ctl --setpattern 设子目录 stripe (不动根目录)
# 无需重启服务
# 每值流程: 建子目录+设pattern → RDMA哨兵 → drop_caches → ≥2轮seqwrite → 删子目录
#
# 用法: 在 157 上运行
#   bash /tmp/var-d-chunksize.sh
# ============================================================
set -uo pipefail

OUT_DIR="/tmp/stage1-chunksize"
mkdir -p "$OUT_DIR"

MNT="/mnt/beegfs"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# chunksize 值: "显示名 beegfs-ctl参数"
TEST_VALS="512K 512k 1M 1m 2M 2m 4M 4m"
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
log "变量 D: chunksize 单变量测试"
log "起始: $(date)"
log "测试值: 512K / 1M(基线) / 2M / 4M"
log "每值轮数: ${ROUNDS}"
log "无需重启服务 (子目录 setpattern)"
log "============================================================"
log ""

# RDMA 哨兵 (初始检查)
log "### 初始 RDMA 哨兵检查"
check_rdma
log ""

log "| Chunk | 轮次 | bw (MiB/s) | clat_min (µs) | RDMA | 时间 |"
log "|-------|:----:|:----------:|:------------:|:----:|------|"

# 解析 TEST_VALS: 每次取 (display_name, ctl_arg) 对
set -- $TEST_VALS
while [ $# -ge 2 ]; do
    display="$1"
    ctl_arg="$2"
    shift 2

    dir="${MNT}/cs_test_${display}"
    log ""
    log "### Chunk=${display} — $(date)"

    # 建子目录 + 设 pattern (setpattern 需目录已存在)
    mkdir -p "$dir"
    log "  [setpattern] chunksize=${ctl_arg}..."
    echo "${SSH_PASS}" | sudo -S beegfs-ctl --setpattern \
        --pattern=buddymirror --numtargets=3 --chunksize="${ctl_arg}" \
        "$dir" 2>&1 | tee -a "$SUMMARY"

    # 验证 pattern
    echo "${SSH_PASS}" | sudo -S beegfs-ctl --getentryinfo --entryinfo "$dir" 2>&1 | grep -E "chunksize|numtargets|pattern" | tee -a "$SUMMARY" || true

    # RDMA 哨兵
    check_rdma

    # 每轮: drop_caches + seqwrite
    for r in $(seq 1 "$ROUNDS"); do
        drop_all_caches
        of="${OUT_DIR}/chunk${display}-r${r}-seqwrite.txt"
        fio --name=seqwrite --directory="$dir" --rw=write --bs=256K --size=4G \
            --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
        rm -rf "${dir}"/*
        bw=$(bwget "$of")
        clat=$(clatminget "$of")
        log "  r${r}: bw=${bw}, clat_min=${clat}µs"
        log "| ${display} | r${r} | ${bw} | ${clat} | ✓ | $(date) |"
    done

    # 删子目录
    echo "${SSH_PASS}" | sudo -S rm -rf "$dir" 2>/dev/null
done

log ""
log "============================================================"
log "完成: $(date)"
log "结果目录(157): ${OUT_DIR}"
log "============================================================"
