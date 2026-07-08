#!/bin/bash
# ============================================================
# var-c-workers.sh — 变量 C: tuneNumWorkers (storage) 单变量测试
#
# 测试值: 12(基线) / 24(2×) / 48(4×), 每值 ≥2 轮 seqwrite
# 只改 slave storage.conf 的 tuneNumWorkers
# 只重启 slave beegfs-storage (不重启 157 mgmtd/meta/client, 快)
# client 会自动重连 storage, 等 targets Good + RDMA 哨兵通过再测
#
# 用法: 在 157 上运行 (需先 scp set-rdma-param.sh 到 /tmp/)
#   bash /tmp/var-c-workers.sh
# ============================================================
set -uo pipefail

OUT_DIR="/tmp/stage1-workers"
mkdir -p "$OUT_DIR"
HELPER="/tmp/set-rdma-param.sh"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/c_workers_test"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

PARAM="tuneNumWorkers"
TEST_VALS="12 24 48"
ROUNDS=2

SUMMARY="${OUT_DIR}/summary.md"
> "$SUMMARY"
log(){ echo "$@" | tee -a "$SUMMARY"; }

# ============================================================
# 函数
# ============================================================

change_workers_slaves() {
    local val=$1
    log "  [conf] 设置 ${PARAM}=${val} on 3 slaves (storage.conf only)..."
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "bash ${HELPER} ${PARAM} ${val} beegfs-storage.conf" 2>/dev/null \
            | tee -a "$SUMMARY"
    done
}

restart_storage() {
    log "  [restart] slave beegfs-storage (3 节点并行)..."
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "echo '${SSH_PASS}' | sudo -S systemctl restart beegfs-storage 2>&1" 2>/dev/null &
    done
    wait
    sleep 10

    # 等 targets 全 Good (client 自动重连, 不需要重启 client)
    log "  [restart] 等 targets Good + client 重连..."
    local deadline=$(( $(date +%s) + 120 ))
    while [ $(date +%s) -lt $deadline ]; do
        local good
        good=$(echo "${SSH_PASS}" | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null | grep -c Good || true)
        if [ "$good" -ge 6 ] 2>/dev/null; then
            log "  [restart] ${good} targets Good ✓"
            return 0
        fi
        sleep 5
    done
    log "  [restart] FAILED — targets 未就绪"
    return 1
}

check_rdma() {
    local out
    out=$(echo "${SSH_PASS}" | sudo -S beegfs-net 2>/dev/null | grep -E 'ID: 10[123]' -A1 | grep 'Connections:')
    local tcp_count=$(echo "$out" | grep -c 'TCP' || true)
    local rdma_count=$(echo "$out" | grep -c 'RDMA' || true)
    if [ "$tcp_count" -eq 0 ] && [ "$rdma_count" -ge 3 ]; then
        log "  beegfs-net: 100% RDMA ✓ (${rdma_count} RDMA, ${tcp_count} TCP)"
        echo "$out" | tee -a "$SUMMARY"
        return 0
    else
        log "  beegfs-net: WARNING — ${rdma_count} RDMA, ${tcp_count} TCP"
        echo "$out" | tee -a "$SUMMARY"
        return 1
    fi
}

drop_all_caches() {
    sync
    echo "${SSH_PASS}" | sudo -S bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}

bwget(){ grep -oP "WRITE: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || echo "NA"; }
clatminget(){ grep -oP "clat \(usec\): min=\K[0-9]+" "$1" | head -1 || echo "NA"; }

run_seqwrite() {
    local outfile=$1
    mkdir -p "$SEQ_DIR"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --direct=1 --end_fsync=1 --group_reporting > "$outfile" 2>&1
    rm -rf "$SEQ_DIR"/*
}

# ============================================================
# 主逻辑
# ============================================================
log "============================================================"
log "变量 C: tuneNumWorkers (storage) 单变量测试"
log "起始: $(date)"
log "测试值: ${TEST_VALS}"
log "每值轮数: ${ROUNDS}"
log "只改 slave storage.conf + 只重启 beegfs-storage"
log "============================================================"
log ""

log "| Workers | 轮次 | bw (MiB/s) | clat_min (µs) | RDMA | 时间 |"
log "|---------|:----:|:----------:|:------------:|:----:|------|"

for val in $TEST_VALS; do
    log ""
    log "### Workers=${val} — $(date)"

    change_workers_slaves "$val"

    if ! restart_storage; then
        log "| ${val} | - | ERROR | ERROR | 跳过 | $(date) |"
        continue
    fi

    if ! check_rdma; then
        log "| ${val} | - | SKIP | SKIP | TCP! | $(date) |"
        continue
    fi

    for r in $(seq 1 "$ROUNDS"); do
        drop_all_caches
        of="${OUT_DIR}/workers${val}-r${r}-seqwrite.txt"
        run_seqwrite "$of"
        bw=$(bwget "$of")
        clat=$(clatminget "$of")
        log "  r${r}: bw=${bw}, clat_min=${clat}µs"
        log "| ${val} | r${r} | ${bw} | ${clat} | ✓ | $(date) |"
    done
done

# 恢复基线
log ""
log "### 恢复基线 (Workers=12) — $(date)"
change_workers_slaves "12"
if restart_storage; then
    check_rdma
    log "  基线恢复 ✓"
else
    log "  WARNING: 恢复后重启失败"
fi

log ""
log "============================================================"
log "完成: $(date)"
log "结果目录(157): ${OUT_DIR}"
log "============================================================"
