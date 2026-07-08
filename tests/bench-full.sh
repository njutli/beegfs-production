#!/bin/bash
set -uo pipefail

# ============================================================
# BeeGFS Full Performance Test
#
# Comprehensive benchmark modeled on the JuiceFS production
# full-bs256k test suite. Tests sequential and random I/O
# at various block sizes and concurrency levels.
#
# Test matrix (aligned with JuiceFS+Ceph cold-cache0 baseline):
#   Sequential:
#     - seqread (single, bs=256K)
#     - seqwrite (single, bs=256K)
#     - multi-seqread (16 jobs, bs=256K)
#     - multi-seqwrite (16 jobs, bs=256K)
#   Layout:
#     - 128 jobs x 1G = 128G, bs=4M
#   Random (3 rounds):
#     - randread (bs=256K, 128 jobs, 60s)
#     - randwrite (bs=256K, 128 jobs, 60s)
#     - randrw (bs=256K, 128 jobs, 60s)
#   Block size sweep:
#     - randread at bs=64K, 256K, 1M (3 rounds each)
#
# Usage: bench-full.sh <tag> <mode> [extra_fio_opts...]
#   tag:  cold-r1 / warm-r1 / etc.
#   mode: cold / warm
#
# Example:
#   bash tests/bench-full.sh cold-r1 cold
#   bash tests/bench-full.sh warm-r1 warm
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROJECT_DIR}/config.sh"

TAG="${1:?usage: $0 tag mode [extra_opts]}"
MODE="${2:?mode: cold or warm}"
shift 2
EXTRA_OPTS="$*"

MNT="${BEEGFS_MOUNT_POINT}"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
TS="$(date +%Y%m%d-%H%M%S)"

if [ "${MODE}" = "cold" ]; then
    DO_DROP=1
    FIO_EXTRA="--direct=1"
elif [ "${MODE}" = "warm" ]; then
    DO_DROP=0
    FIO_EXTRA=""
else
    echo "mode must be cold or warm"
    exit 1
fi

OUTDIR="${PROJECT_DIR}/results/full-${TAG}-${TS}"
OUT="${OUTDIR}/summary.md"
mkdir -p "${OUTDIR}"

log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "BeeGFS Full Performance Test — ${TAG} ${TS}"
log "============================================================"
log "## 口径:"
log "  mode=${MODE}, extra_opts=${EXTRA_OPTS}"
log "  seq: 1次; rand: 3轮; bs-sweep: 3轮"
log ""

# --- Environment snapshot ---
{
    echo "### date: $(date)"
    echo "### hostname: $(hostname)"
    echo "### uname: $(uname -a)"
    echo "### memory"
    free -h
    echo "### beegfs version"
    beegfs-ctl --version 2>&1 | head -1
    echo "### fio version"
    fio --version 2>&1
    echo "### mount"
    mount | grep beegfs
    echo "### df"
    df -h "${MNT}"
    echo "### beegfs storage info"
    beegfs-df 2>&1 || true
    echo "### beegfs nodes (meta)"
    sudo beegfs-ctl --listnodes --nodetype=meta 2>&1 || true
    echo "### beegfs nodes (storage)"
    sudo beegfs-ctl --listnodes --nodetype=storage 2>&1 || true
    echo "### beegfs targets (meta state)"
    sudo beegfs-ctl --listtargets --state --nodetype=meta 2>&1 || true
    echo "### beegfs targets (storage state)"
    sudo beegfs-ctl --listtargets --state --nodetype=storage 2>&1 || true
    echo "### beegfs mirror groups (meta)"
    sudo beegfs-ctl --listmirrorgroups --nodetype=meta 2>&1 || true
    echo "### beegfs mirror groups (storage)"
    sudo beegfs-ctl --listmirrorgroups --nodetype=storage 2>&1 || true
    echo "### stripe pattern"
    sudo beegfs-ctl --getentryinfo --entry="${MNT}" 2>&1 || true
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "  env snapshot -> ${OUTDIR}/env-snapshot.txt"

wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){
    local raw
    raw=$(grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1)
    if [ -z "$raw" ]; then
        raw=$(grep -oP "$2: bw=\K[0-9.]+(?=GiB/s)" "$1" | head -1)
        [ -n "$raw" ] && raw=$(awk "BEGIN {printf \"%.0f\", $raw * 1024}")
    fi
    echo "${raw:-NA}"
}
iopsget(){ local k=$(echo "$2" | tr 'A-Z' 'a-z'); grep -oP "${k}: IOPS=\K[0-9.]+[km]?" "$1" | head -1 || true; }

drop_caches() {
    if [ "${DO_DROP}" = "1" ]; then
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    fi
}

# 清客户端 + 全部 storage server 的 page cache
# 避免 storage 端 XFS page cache 让读测试命中缓存
drop_all_caches() {
    if [ "${DO_DROP}" != "1" ]; then return; fi
    echo -n "  [drop_caches] client..."
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    echo -n " OK; slaves..."
    for ip in ${SLAVE_SERVERS[*]}; do
        echo -n " ${ip}"
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
    echo " OK"
}

run_seq() {
    local name="$1" rw="$2" nj="$3" fsync="$4" bs="${5:-256K}"
    local of="${OUTDIR}/${name}.txt"
    drop_all_caches
    echo "# ${name}: rw=${rw} bs=${bs} size=4G numjobs=${nj} fsync=${fsync}" > "$of"
    echo "# mode: ${MODE}, extra: ${EXTRA_OPTS}" >> "$of"
    echo "# date: $(date)" >> "$of"
    local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=${bs} --size=4G"
    [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
    [ "$fsync" = "1" ] && args="$args --end_fsync=1"
    args="$args ${FIO_EXTRA} ${EXTRA_OPTS}"
    fio $args >> "$of" 2>&1
    local rd wr
    rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
    log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA} MiB/s"
    wait_fio
}

run_rand() {
    local name="$1" rw="$2" round="$3" bs="${4:-256K}"
    local of="${OUTDIR}/${name}-r${round}.txt"
    drop_all_caches
    echo "# ${name} round ${round}: rw=${rw} bs=${bs} iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
    echo "# mode: ${MODE}, extra: ${EXTRA_OPTS}" >> "$of"
    echo "# date: $(date)" >> "$of"
    fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
        --bs="$bs" --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --group_reporting \
        --time_based --runtime=60s ${EXTRA_OPTS} >> "$of" 2>&1
    local rd wr
    rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
    local riops wiops
    riops=$(iopsget "$of" READ); wiops=$(iopsget "$of" WRITE)
    log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA} MiB/s IOPS_R=${riops:-NA} IOPS_W=${wiops:-NA}"
    wait_fio
}

# ============================================================
# Sequential Tests
# ============================================================

log ""
log "## 顺序测试 (bs=256K)"
mkdir -p "$SEQ_DIR"

log "### seqread prep (write 4G)"
rm -rf "$SEQ_DIR"/*
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G \
    ${FIO_EXTRA} >/dev/null 2>&1
wait_fio

run_seq "seqread" read 1 0 "256K"
run_seq "seqwrite" write 1 1 "256K"
run_seq "multi-seqread" read 16 0 "256K"
run_seq "multi-seqwrite" write 16 1 "256K"
rm -rf "$SEQ_DIR"

# ============================================================
# Layout (128 jobs x 1G = 128G, bs=4M)
# ============================================================

log ""
log "## 布局 (128 jobs x 1G = 128G, bs=4M)"
rm -rf "$DIR"/*
mkdir -p "$DIR"
echo "# layout: 128 jobs x 1G, bs=4M, rw=write, end_fsync=1" > "${OUTDIR}/layout.txt"
echo "# date: $(date)" >> "${OUTDIR}/layout.txt"
fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 \
    ${FIO_EXTRA} >> "${OUTDIR}/layout.txt" 2>&1
lw=$(bwget "${OUTDIR}/layout.txt" WRITE)
log "  layout: WRITE=${lw:-NA} MiB/s"
wait_fio

# Cooldown after layout
log ""
log "## Layout cooldown (60s)..."
sleep 60

# ============================================================
# Random Tests (3 rounds, bs=256K)
# ============================================================

log ""
log "## 随机测试 (3轮, bs=256K)"
for i in 1 2 3; do
    log "### Round ${i}"
    run_rand "randread" randread "$i" "256K"
    run_rand "randwrite" randwrite "$i" "256K"
    run_rand "randrw" randrw "$i" "256K"
done

# ============================================================
# Block Size Sweep (randread, 3 rounds each)
# ============================================================

log ""
log "## Block Size Sweep (randread, 3 rounds)"
for bs in 64K 256K 1M; do
    log "### bs=${bs}"
    for i in 1 2 3; do
        run_rand "randread-${bs}" randread "$i" "$bs"
    done
done

# ============================================================
# Cleanup + record
# ============================================================

log ""
log "## Cleanup"
rm -rf "$DIR"
log "  Test files removed."

# Cluster status after
{
    echo "### date: $(date)"
    echo "### beegfs services"
    sudo systemctl status beegfs-meta beegfs-storage beegfs-client --no-pager 2>&1 | grep -E "Active:|●"
} > "${OUTDIR}/status-after.txt" 2>&1

# Commands record
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# BeeGFS Full Test Commands: ${TAG}
# Mode: ${MODE}

# Sequential tests (bs=256K)
fio --name=prep --directory=${MNT}/seq_dir --rw=write --bs=256K --size=4G ${FIO_EXTRA}
fio --name=seqread --directory=${MNT}/seq_dir --rw=read --bs=256K --size=4G ${FIO_EXTRA}
fio --name=seqwrite --directory=${MNT}/seq_dir --rw=write --bs=256K --size=4G --end_fsync=1 ${FIO_EXTRA}
fio --name=multi-seqread --directory=${MNT}/seq_dir --rw=read --bs=256K --size=4G --numjobs=16 --group_reporting ${FIO_EXTRA}
fio --name=multi-seqwrite --directory=${MNT}/seq_dir --rw=write --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1 ${FIO_EXTRA}

# Layout (128 jobs x 1G, bs=4M)
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 ${FIO_EXTRA}

# Random tests (bs=256K, 3 rounds, 60s each)
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256K --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s

# Block size sweep (randread, bs=64K/256K/1M)
for bs in 64K 256K 1M; do
  fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
      --bs=\${bs} --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
done
CMDEOF
chmod +x "${OUTDIR}/commands.sh"

log ""
log "DONE"
log "  Results: ${OUTDIR}"
log "  commands.sh generated"
