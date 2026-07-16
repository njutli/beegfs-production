#!/bin/bash
set -uo pipefail
# ============================================================
# Stage3 口径A — 对齐 JuiceFS 口径的全量冷态基线测试
# 参数来源: stage3-aligned-retest-task-book.md §3.2
# 执行顺序: 1-8, 11-12 (layout依赖项) → 9-10 (需重部署, 另行执行)
# ============================================================

ROUND_TAG="stage3-aligned-nolimit"
TS="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="/tmp/beegfs-test/results/${ROUND_TAG}-${TS}"
BW_LOG_DIR="/tmp/beegfs-bw"
LOG="${RESULTS_DIR}/summary.md"
MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/seq_dir"
TEST_DIR="${MNT}/test_dir"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}"
log(){ echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }

log "# Stage3 口径A (不限速 100GbE RDMA) ${TS}"
log "# fio: seqread/mseqread 180s, seqwrite/mseqwrite bs=4M, rand 180s ×3, bw_log"
log "# 顺序: 1-8,11-12 (layout依赖), 9-10另行重部署"

# --- helpers ---
drop_all_caches(){
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 2; done; sleep 2; }
bwget(){ local f=$1 k=$(echo "$2" | tr 'A-Z' 'a-z'); grep -oP "${k}: bw=\K[0-9.]+" "$f" | head -1; }

# --- deploy sampler ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLER_SRC="${SCRIPT_DIR}/lib/ib-iostat-sampler.sh"
if [ ! -f "$SAMPLER_SRC" ]; then
    log "# WARN: ib-iostat-sampler.sh not found, skipping IB/iostat sampling"
    SAMPLER_SRC=""
fi
if [ -n "$SAMPLER_SRC" ]; then
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "cat > /tmp/ib-iostat-sampler.sh && chmod +x /tmp/ib-iostat-sampler.sh" < "$SAMPLER_SRC"
    done
    log "# sampler deployed to 3 slaves"
fi
start_samplers(){
    [ -z "$SAMPLER_SRC" ] && return
    local tag="$1"
    for ip in "${SLAVES[@]}"; do
        local h; h=$(echo "$ip" | awk -F. '{print $4}')
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "rm -f /tmp/ib-stop; nohup bash /tmp/ib-iostat-sampler.sh /tmp/samples-${tag}-${h} 600 >/dev/null 2>&1 &" 2>/dev/null
    done
}
stop_samplers(){
    [ -z "$SAMPLER_SRC" ] && return
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "touch /tmp/ib-stop; sleep 1; pkill -f ib-iostat-sampler 2>/dev/null; true" 2>/dev/null
    done
}
collect_samplers(){
    [ -z "$SAMPLER_SRC" ] && return
    local tag="$1"
    for ip in "${SLAVES[@]}"; do
        local h; h=$(echo "$ip" | awk -F. '{print $4}')
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/samples-${tag}-${h}.ib" "${RESULTS_DIR}/${tag}/ib-${tag}-slave${h}.ib" 2>/dev/null || true
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/samples-${tag}-${h}.iostat" "${RESULTS_DIR}/${tag}/iostat-${tag}-slave${h}.txt" 2>/dev/null || true
    done
}

run_item(){
    local name="$1" rw="$2" nj="$3" fsync="$4" bs="$5" runtime="$6" tag="$7"
    local of_dir="${RESULTS_DIR}/${tag}"
    local of="${of_dir}/fio-${name}.txt"
    mkdir -p "$of_dir"
    # move bw_log files for this tag
    rm -f "${BW_LOG_DIR}/${tag}"_bw.*.log 2>/dev/null
    drop_all_caches
    start_samplers "$tag"
    sleep 2
    log "## ${name}: rw=${rw} bs=${bs} nj=${nj} fsync=${fsync} runtime=${runtime} direct=1"
    local args="--name=${name} --directory=${SEQ_DIR}/ --rw=${rw} --refill_buffers --bs=${bs} --size=4G"
    [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
    [ "$fsync" = "1" ] && args="$args --end_fsync=1"
    [ -n "$runtime" ] && args="$args --time_based --runtime=${runtime}"
    args="$args --direct=1 --ioengine=psync --iodepth=1"
    args="$args --write_bw_log=${BW_LOG_DIR}/${tag} --log_avg_msec=1000"
    fio $args > "$of" 2>&1
    local rd wr
    rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
    log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA}"
    sleep 3
    stop_samplers
    collect_samplers "$tag"
    # save bw_log
    cp ${BW_LOG_DIR}/${tag}_bw.*.log "${of_dir}/" 2>/dev/null || true
    wait_fio
}

run_rand(){
    local name="$1" rw="$2" round="$3" bs="$4" tag="$5" extra="$6"
    local of_dir="${RESULTS_DIR}/${tag}"
    local of="${of_dir}/fio-${name}-r${round}.txt"
    mkdir -p "$of_dir"
    rm -f "${BW_LOG_DIR}/${tag}"_bw.*.log 2>/dev/null
    drop_all_caches
    start_samplers "$tag"
    sleep 2
    log "## ${name} r${round}: rw=${rw} bs=${bs} 128job iodepth=128 180s direct=1 ${extra}"
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --filesize=1G --size=1G \
        --bs=${bs} --rw=${rw} \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none ${extra} \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/${tag}" --log_avg_msec=1000 \
        > "$of" 2>&1
    local rd wr
    rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
    log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA}"
    sleep 3
    stop_samplers
    collect_samplers "$tag"
    cp ${BW_LOG_DIR}/${tag}_bw.*.log "${of_dir}/" 2>/dev/null || true
    wait_fio
}

# --- env snapshot ---
{
    echo "### date: $(date)"
    echo "### hostname: $(hostname)"
    echo "### fio: $(fio --version 2>&1)"
    echo "### beegfs-net:"
    beegfs-net 2>/dev/null
    echo "### connUseRDMA:"
    grep connUseRDMA /etc/beegfs/beegfs-client.conf 2>/dev/null
    echo "### connInterfacesFile:"
    cat /etc/beegfs/connInterfacesFile.conf 2>/dev/null
    echo "### targets:"
    sudo beegfs-ctl --listtargets --state 2>/dev/null
    echo "### root stripe:"
    sudo beegfs-ctl --getentryinfo ${MNT} 2>&1
} > "${RESULTS_DIR}/env-snapshot.txt" 2>&1
log "# env snapshot saved"

# ============================================================
# 顺序测试 (items 1-4)
# ============================================================
log ""
log "=== 顺序测试 ==="

# prep: write 4G for seqread (bs=4M, aligned with JuiceFS prep)
mkdir -p "${SEQ_DIR}"
log "## prep: write 4G seq data (bs=4M)"
fio --name=prep --directory="${SEQ_DIR}/" --rw=write --bs=4M --size=4G --direct=1 >/dev/null 2>&1
wait_fio
log "# prep done"

# 1. seqread (bs=256k, 1job, 180s)
run_item "seqread" read 1 0 "256k" "180" "seqread"

# 2. seqwrite (bs=4M, 1job, fsync)
rm -rf "${SEQ_DIR}"; mkdir -p "${SEQ_DIR}"
run_item "seqwrite" write 1 1 "4M" "" "seqwrite"

# 3. mseqread (bs=256k, 16job, 180s) — prep 16x4G first
rm -rf "${SEQ_DIR}"; mkdir -p "${SEQ_DIR}"
log "## prep: 16 job x 4G (bs=4M)"
fio --name=prep --directory="${SEQ_DIR}/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
wait_fio
run_item "mseqread" read 16 0 "256k" "180" "mseqread"

# 4. mseqwrite (bs=4M, 16job, fsync)
rm -rf "${SEQ_DIR}"; mkdir -p "${SEQ_DIR}"
run_item "mseqwrite" write 16 1 "4M" "" "mseqwrite"
rm -rf "${SEQ_DIR}"

# ============================================================
# layout (item 5) + cooldown
# ============================================================
log ""
log "=== layout ==="
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
mkdir -p "${RESULTS_DIR}/layout"
rm -f "${BW_LOG_DIR}/layout"_bw.*.log 2>/dev/null
drop_all_caches
start_samplers "layout"
sleep 2
log "## layout: 128job x 1G, bs=4M"
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1 \
    --write_bw_log="${BW_LOG_DIR}/layout" --log_avg_msec=1000 \
    > "${RESULTS_DIR}/layout/fio-layout.txt" 2>&1
local_lw=$(bwget "${RESULTS_DIR}/layout/fio-layout.txt" WRITE)
log "  layout: WRITE=${local_lw:-NA}"
sleep 3
stop_samplers
collect_samplers "layout"
cp ${BW_LOG_DIR}/layout_bw.*.log "${RESULTS_DIR}/layout/" 2>/dev/null || true
wait_fio
log "# layout done, cooldown 60s"
sleep 60

# ============================================================
# 随机测试 (items 6-8, 11-12) — 复用 layout
# ============================================================
log ""
log "=== 随机测试 ==="

# 6. randread ×3
for i in 1 2 3; do
    run_rand "randread" randread "$i" "256k" "randread-r${i}" ""
done

# 7. randwrite analysis ×3
for i in 1 2 3; do
    run_rand "randwrite-analysis" randwrite "$i" "256k" "randwrite-analysis-r${i}" "--openfiles=100"
done

# 8. randrw analysis ×3
for i in 1 2 3; do
    run_rand "randrw-analysis" randrw "$i" "256k" "randrw-analysis-r${i}" "--openfiles=100"
done

# 11. randread-64K ×3
for i in 1 2 3; do
    run_rand "randread-64K" randread "$i" "64k" "randread-64K-r${i}" ""
done

# 12. randread-1M ×3
for i in 1 2 3; do
    run_rand "randread-1M" randread "$i" "1M" "randread-1M-r${i}" ""
done

# cleanup
rm -rf "${TEST_DIR}" "${SEQ_DIR}"
log ""
log "# DONE (items 1-8, 11-12)"
log "# results: ${RESULTS_DIR}"
log "# NOTE: items 9-10 (验收口径) need redeploy, run separately"
