#!/bin/bash
set -uo pipefail

# ============================================================
# BeeGFS Full Performance Test
#
# Comprehensive benchmark modeled on the JuiceFS production
# full-bs256k test suite. Tests sequential and random I/O
# at various block sizes and concurrency levels.
#
# Test matrix:
#   Sequential:
#     - seqread (single, bs=1M)
#     - seqwrite (single, bs=1M)
#     - multi-seqread (16 jobs, bs=1M)
#     - multi-seqwrite (16 jobs, bs=1M)
#   Layout:
#     - 128 jobs x 1G, bs=1M (128G total write)
#   Random (3 rounds):
#     - randread (bs=4K, 128 jobs, 60s)
#     - randwrite (bs=4K, 128 jobs, 60s)
#     - randrw (bs=4K, 128 jobs, 60s)
#   Block size sweep:
#     - randread at bs=4K, 64K, 256K, 1M (3 rounds each)
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
    echo "### beegfs nodes"
    sudo beegfs-ctl --listnodes --nodetype=meta --mgmtd_node="${BEEGFS_MGMTD_HOST}" 2>&1 || true
    sudo beegfs-ctl --listnodes --nodetype=storage --mgmtd_node="${BEEGFS_MGMTD_HOST}" 2>&1 || true
    echo "### beegfs targets"
    sudo beegfs-ctl --listtargets --nodetype=storage --mgmtd_node="${BEEGFS_MGMTD_HOST}" 2>&1 || true
    echo "### stripe pattern"
    sudo beegfs-ctl --getentryinfo --entry="${MNT}" --mgmtd_node="${BEEGFS_MGMTD_HOST}" 2>&1 || true
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "  env snapshot -> ${OUTDIR}/env-snapshot.txt"

wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || true; }
iopsget(){ grep -oP "$2: IOPS=\K[0-9]+" "$1" | head -1 || true; }

drop_caches() {
    if [ "${DO_DROP}" = "1" ]; then
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    fi
}

run_seq() {
    local name="$1" rw="$2" nj="$3" fsync="$4" bs="${5:-1M}"
    local of="${OUTDIR}/${name}.txt"
    drop_caches
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
    local name="$1" rw="$2" round="$3" bs="${4:-4K}"
    local of="${OUTDIR}/${name}-r${round}.txt"
    drop_caches
    echo "# ${name} round ${round}: rw=${rw} bs=${bs} iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
    echo "# mode: ${MODE}, extra: ${EXTRA_OPTS}" >> "$of"
    echo "# date: $(date)" >> "$of"
    fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
        --bs="$bs" --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=100 --group_reporting \
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
log "## 顺序测试 (bs=1M)"
mkdir -p "$SEQ_DIR"

log "### seqread prep (write 4G)"
rm -rf "$SEQ_DIR"/*
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=1M --size=4G \
    ${FIO_EXTRA} >/dev/null 2>&1
wait_fio

run_seq "seqread" read 1 0
run_seq "seqwrite" write 1 1
run_seq "multi-seqread" read 16 0
run_seq "multi-seqwrite" write 16 1
rm -rf "$SEQ_DIR"

# ============================================================
# Layout (128 jobs x 1G = 128G, bs=1M)
# ============================================================

log ""
log "## 布局 (128 jobs x 1G = 128G, bs=1M)"
rm -rf "$DIR"/*
mkdir -p "$DIR"
echo "# layout: 128 jobs x 1G, bs=1M, rw=write, end_fsync=1" > "${OUTDIR}/layout.txt"
echo "# date: $(date)" >> "${OUTDIR}/layout.txt"
fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G --bs=1M \
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
# Random Tests (3 rounds, bs=4K)
# ============================================================

log ""
log "## 随机测试 (3轮, bs=4K)"
for i in 1 2 3; do
    log "### Round ${i}"
    run_rand "randread" randread "$i" "4K"
    run_rand "randwrite" randwrite "$i" "4K"
    run_rand "randrw" randrw "$i" "4K"
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

# Sequential tests (bs=1M)
fio --name=prep --directory=${MNT}/seq_dir --rw=write --bs=1M --size=4G ${FIO_EXTRA}
fio --name=seqread --directory=${MNT}/seq_dir --rw=read --bs=1M --size=4G ${FIO_EXTRA}
fio --name=seqwrite --directory=${MNT}/seq_dir --rw=write --bs=1M --size=4G --end_fsync=1 ${FIO_EXTRA}
fio --name=multi-seqread --directory=${MNT}/seq_dir --rw=read --bs=1M --size=4G --numjobs=16 --group_reporting ${FIO_EXTRA}
fio --name=multi-seqwrite --directory=${MNT}/seq_dir --rw=write --bs=1M --size=4G --numjobs=16 --group_reporting --end_fsync=1 ${FIO_EXTRA}

# Layout (128 jobs x 1G, bs=1M)
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G --bs=1M \
    --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 ${FIO_EXTRA}

# Random tests (bs=4K, 3 rounds, 60s each)
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=4K --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=4K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=${MNT}/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=4K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
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
