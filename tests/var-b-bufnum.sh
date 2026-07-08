#!/bin/bash
# ============================================================
# var-b-bufnum.sh — 变量 B-1: connRDMABufNum 单变量测试
#
# 测试值: 70(基线) / 128 / 256, 每值 ≥2 轮 seqwrite
# 改动节点: 157(client.conf+meta.conf) + 3 slave(storage.conf+meta.conf)
# 每值流程: 改conf → 重启全服务 → RDMA哨兵 → drop_caches → ≥2轮seqwrite → 记录
# 最终: 恢复70 → 重启 → 验证
#
# 用法: 在 157 上运行 (需先 scp set-rdma-param.sh 到 /tmp/)
#   bash /tmp/var-b-bufnum.sh
# ============================================================
set -uo pipefail

OUT_DIR="/tmp/stage1-bufnum"
mkdir -p "$OUT_DIR"
HELPER="/tmp/set-rdma-param.sh"

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/b_bufnum_test"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

PARAM="connRDMABufNum"
TEST_VALS="70 128 256"
ROUNDS=2

SUMMARY="${OUT_DIR}/summary.md"
> "$SUMMARY"
log(){ echo "$@" | tee -a "$SUMMARY"; }

# ============================================================
# 函数
# ============================================================

change_param_all() {
    local val=$1
    log "  [conf] 设置 ${PARAM}=${val} on 157 (client+meta)..."
    bash "$HELPER" "$PARAM" "$val" beegfs-client.conf beegfs-meta.conf 2>&1 | tee -a "$SUMMARY"

    log "  [conf] 设置 ${PARAM}=${val} on 3 slaves (storage+meta)..."
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "bash ${HELPER} ${PARAM} ${val} beegfs-storage.conf beegfs-meta.conf" 2>/dev/null \
            | tee -a "$SUMMARY"
    done
}

restart_beegfs() {
    log "  [restart] slave storage + meta..."
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
            "echo '${SSH_PASS}' | sudo -S systemctl restart beegfs-storage beegfs-meta 2>&1" 2>/dev/null &
    done
    wait
    sleep 10

    log "  [restart] 157 mgmtd (stop+start, 处理卡死)..."
    echo "${SSH_PASS}" | sudo -S systemctl stop beegfs-mgmtd 2>/dev/null
    sleep 3
    local mgmtd_state=$(echo "${SSH_PASS}" | sudo -S systemctl is-active beegfs-mgmtd 2>/dev/null)
    if [ "$mgmtd_state" = "deactivating" ]; then
        log "  [restart] mgmtd 卡在 deactivating, kill..."
        echo "${SSH_PASS}" | sudo -S systemctl kill beegfs-mgmtd --signal=SIGKILL 2>/dev/null
        sleep 3
    fi
    echo "${SSH_PASS}" | sudo -S systemctl start beegfs-mgmtd 2>/dev/null
    sleep 5

    log "  [restart] 157 meta..."
    echo "${SSH_PASS}" | sudo -S systemctl restart beegfs-meta 2>/dev/null
    sleep 30

    log "  [restart] client (可能 60-120s 内核模块重编译)..."
    echo "${SSH_PASS}" | sudo -S systemctl restart beegfs-client 2>/dev/null
    sleep 15
    if ! mountpoint -q "$MNT" 2>/dev/null; then
        log "  [restart] mount 未就绪, 重试 client..."
        echo "${SSH_PASS}" | sudo -S systemctl restart beegfs-client 2>/dev/null
        sleep 30
    fi

    local deadline=$(( $(date +%s) + 180 ))
    while [ $(date +%s) -lt $deadline ]; do
        if mountpoint -q "$MNT" 2>/dev/null; then
            local good
            good=$(echo "${SSH_PASS}" | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null | grep -c Good || true)
            if [ "$good" -ge 6 ] 2>/dev/null; then
                log "  [restart] mount OK, ${good} targets Good ✓"
                return 0
            fi
        fi
        sleep 5
    done
    log "  [restart] FAILED — mount/targets 未就绪"
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
# 内存核算（改前检查）
# ============================================================
log "============================================================"
log "变量 B-1: connRDMABufNum 单变量测试"
log "起始: $(date)"
log "测试值: ${TEST_VALS}"
log "每值轮数: ${ROUNDS}"
log "============================================================"
log ""
log "## 内存核算 (RAM = BufSize × BufNum × 2 per connection)"
log "| BufNum | BufSize | per-conn RAM | 估~7 conn(157) |"
log "|--------|---------|:------------:|:--------------:|"
for v in $TEST_VALS; do
    ram_per=$(( v * 8192 * 2 ))
    ram_total=$(( ram_per * 7 ))
    log "| ${v} | 8192 | $(( ram_per / 1048576 )) MB | $(( ram_total / 1048576 )) MB |"
done
log ""

log "| BufNum | 轮次 | bw (MiB/s) | clat_min (µs) | RDMA | 时间 |"
log "|--------|:----:|:----------:|:------------:|:----:|------|"

# ============================================================
# 主循环
# ============================================================
for val in $TEST_VALS; do
    log ""
    log "### BufNum=${val} — $(date)"

    # 1. 改 conf
    change_param_all "$val"

    # 2. 重启
    if ! restart_beegfs; then
        log "| ${val} | - | ERROR | ERROR | 跳过 | $(date) |"
        continue
    fi

    # 3. RDMA 哨兵
    if ! check_rdma; then
        log "| ${val} | - | SKIP | SKIP | TCP! | $(date) |"
        continue
    fi

    # 4. 每轮: drop_caches + seqwrite
    for r in $(seq 1 "$ROUNDS"); do
        drop_all_caches
        of="${OUT_DIR}/bufnum${val}-r${r}-seqwrite.txt"
        run_seqwrite "$of"
        bw=$(bwget "$of")
        clat=$(clatminget "$of")
        log "  r${r}: bw=${bw}, clat_min=${clat}µs"
        log "| ${val} | r${r} | ${bw} | ${clat} | ✓ | $(date) |"
    done
done

# ============================================================
# 恢复基线
# ============================================================
log ""
log "### 恢复基线 (BufNum=70) — $(date)"
change_param_all "70"
if restart_beegfs; then
    check_rdma
    log "  基线恢复 ✓"
else
    log "  WARNING: 恢复后重启失败, 请手动检查"
fi

log ""
log "============================================================"
log "完成: $(date)"
log "结果目录(157): ${OUT_DIR}"
log "============================================================"
