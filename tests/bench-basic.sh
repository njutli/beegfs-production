#!/bin/bash
set -uo pipefail

# ============================================================
# BeeGFS Basic Read/Write Test
#
# Quick functional + basic performance test to verify the
# cluster is working correctly after deployment.
#
# Tests:
#   1. Sequential write (1G, bs=1M)
#   2. Sequential read (1G, bs=1M)
#   3. Random read (1G, bs=4K, 60s)
#   4. Random write (1G, bs=4K, 60s)
#   5. Sequential write multi-job (4G, bs=1M, 4 jobs)
#   6. Sequential read multi-job (4G, bs=1M, 4 jobs)
#
# Usage: bash tests/bench-basic.sh [label]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROJECT_DIR}/config.sh"

LABEL="${1:-basic-$(date +%Y%m%d-%H%M%S)}"
MNT="${BEEGFS_MOUNT_POINT}"
DIR="${MNT}/bench-basic"
TS="$(date +%Y%m%d-%H%M%S)"

OUTDIR="${PROJECT_DIR}/results/basic-${LABEL}-${TS}"
OUT="${OUTDIR}/summary.md"
mkdir -p "${OUTDIR}"

log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "BeeGFS Basic Read/Write Test — ${LABEL} ${TS}"
log "============================================================"
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
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "  env snapshot -> ${OUTDIR}/env-snapshot.txt"

# --- Prepare ---
log "## Preparing test directory"
mkdir -p "${DIR}"
sync

# 清客户端 + 全部 storage server 的 page cache
drop_all_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in ${SLAVE_SERVERS[*]}; do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}

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

# --- Test 1: Sequential Write ---
log ""
log "## Test 1: Sequential Write (1G, bs=1M)"
OF="${OUTDIR}/seqwrite.txt"
fio --name=seqwrite --directory="${DIR}" --rw=write --bs=1M --size=1G \
    --refill_buffers --end_fsync=1 --group_reporting > "${OF}" 2>&1
WR=$(bwget "${OF}" WRITE)
log "  seqwrite: WRITE=${WR:-NA} MiB/s"
wait_fio

# --- Test 2: Sequential Read ---
log ""
log "## Test 2: Sequential Read (1G, bs=1M)"
OF="${OUTDIR}/seqread.txt"
drop_all_caches
fio --name=seqread --directory="${DIR}" --rw=read --bs=1M --size=1G \
    --refill_buffers --group_reporting > "${OF}" 2>&1
RD=$(bwget "${OF}" READ)
log "  seqread: READ=${RD:-NA} MiB/s"
wait_fio

# --- Test 3: Random Read ---
log ""
log "## Test 3: Random Read (bs=4K, 60s)"
OF="${OUTDIR}/randread.txt"
drop_all_caches
fio --name=randread --directory="${DIR}" --rw=randread --bs=4K --size=1G \
    --ioengine=libaio --iodepth=128 --numjobs=4 --direct=1 \
    --fallocate=none --group_reporting --time_based --runtime=60s > "${OF}" 2>&1
RD=$(bwget "${OF}" READ)
log "  randread: READ=${RD:-NA} MiB/s"
wait_fio

# --- Test 4: Random Write ---
log ""
log "## Test 4: Random Write (bs=4K, 60s)"
OF="${OUTDIR}/randwrite.txt"
fio --name=randwrite --directory="${DIR}" --rw=randwrite --bs=4K --size=1G \
    --ioengine=libaio --iodepth=128 --numjobs=4 --direct=1 \
    --fallocate=none --group_reporting --time_based --runtime=60s > "${OF}" 2>&1
WR=$(bwget "${OF}" WRITE)
log "  randwrite: WRITE=${WR:-NA} MiB/s"
wait_fio

# --- Test 5: Multi-job Sequential Write ---
log ""
log "## Test 5: Multi-job Sequential Write (4G, bs=1M, 4 jobs)"
OF="${OUTDIR}/multi-seqwrite.txt"
rm -rf "${DIR}"/*
fio --name=multi-seqwrite --directory="${DIR}" --rw=write --bs=1M --size=1G \
    --numjobs=4 --refill_buffers --end_fsync=1 --group_reporting > "${OF}" 2>&1
WR=$(bwget "${OF}" WRITE)
log "  multi-seqwrite: WRITE=${WR:-NA} MiB/s"
wait_fio

# --- Test 6: Multi-job Sequential Read ---
log ""
log "## Test 6: Multi-job Sequential Read (4G, bs=1M, 4 jobs)"
OF="${OUTDIR}/multi-seqread.txt"
drop_all_caches
fio --name=multi-seqread --directory="${DIR}" --rw=read --bs=1M --size=1G \
    --numjobs=4 --refill_buffers --group_reporting > "${OF}" 2>&1
RD=$(bwget "${OF}" READ)
log "  multi-seqread: READ=${RD:-NA} MiB/s"
wait_fio

# --- Cleanup ---
log ""
log "## Cleanup"
rm -rf "${DIR}"
log "  Test files removed."

# --- Commands record ---
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# BeeGFS Basic Test Commands: ${LABEL}

# Sequential write (1G, bs=1M)
fio --name=seqwrite --directory=${MNT}/bench-basic --rw=write --bs=1M --size=1G \
    --refill_buffers --end_fsync=1 --group_reporting

# Sequential read (1G, bs=1M)
fio --name=seqread --directory=${MNT}/bench-basic --rw=read --bs=1M --size=1G \
    --refill_buffers --group_reporting

# Random read (bs=4K, 60s)
fio --name=randread --directory=${MNT}/bench-basic --rw=randread --bs=4K --size=1G \
    --ioengine=libaio --iodepth=128 --numjobs=4 --direct=1 \
    --fallocate=none --group_reporting --time_based --runtime=60s

# Random write (bs=4K, 60s)
fio --name=randwrite --directory=${MNT}/bench-basic --rw=randwrite --bs=4K --size=1G \
    --ioengine=libaio --iodepth=128 --numjobs=4 --direct=1 \
    --fallocate=none --group_reporting --time_based --runtime=60s

# Multi-job sequential write (4G, bs=1M, 4 jobs)
fio --name=multi-seqwrite --directory=${MNT}/bench-basic --rw=write --bs=1M --size=1G \
    --numjobs=4 --refill_buffers --end_fsync=1 --group_reporting

# Multi-job sequential read (4G, bs=1M, 4 jobs)
fio --name=multi-seqread --directory=${MNT}/bench-basic --rw=read --bs=1M --size=1G \
    --numjobs=4 --refill_buffers --group_reporting
CMDEOF
chmod +x "${OUTDIR}/commands.sh"

log ""
log "DONE"
log "  Results: ${OUTDIR}"
