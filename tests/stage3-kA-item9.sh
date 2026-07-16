#!/bin/bash
set -uo pipefail
# Stage3 口径A item 9: randwrite 验收口径 ×3 (fresh dir + create_on_open)
# 前置: 已重部署 BeeGFS (空卷), connInterfacesFile 已设置
RESULTS_DIR="/tmp/beegfs-test/results/stage3-aligned-nolimit-20260715-155122"
BW_LOG_DIR="/tmp/beegfs-bw"
LOG="${RESULTS_DIR}/summary.md"
MNT="/mnt/beegfs"
TEST_DIR="${MNT}/test_dir"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
log(){ echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }

drop_all_caches(){
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 2; done; sleep 2; }

log ""
log "=== randwrite 验收口径 (fresh dir + create_on_open) ×3 ==="
for i in 1 2 3; do
    rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
    drop_all_caches
    mkdir -p "${RESULTS_DIR}/randwrite-fresh-r${i}"
    rm -f "${BW_LOG_DIR}/randwrite-fresh-r${i}"_bw.*.log 2>/dev/null
    log "## randwrite-fresh r${i}: rw=randwrite bs=256k 128job create_on_open 180s direct=1"
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --nrfiles=100 --filesize=1G --size=1G \
        --bs=256k --rw=randwrite \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/randwrite-fresh-r${i}" --log_avg_msec=1000 \
        > "${RESULTS_DIR}/randwrite-fresh-r${i}/fio-randwrite-fresh-r${i}.txt" 2>&1
    local_wr=$(grep -oP 'WRITE: bw=\K[0-9.]+' "${RESULTS_DIR}/randwrite-fresh-r${i}/fio-randwrite-fresh-r${i}.txt" | head -1)
    log "  randwrite-fresh r${i}: WRITE=${local_wr:-NA}"
    cp ${BW_LOG_DIR}/randwrite-fresh-r${i}_bw.*.log "${RESULTS_DIR}/randwrite-fresh-r${i}/" 2>/dev/null || true
    wait_fio
    sleep 10
done
rm -rf "${TEST_DIR}"
log "# randwrite 验收 done"
