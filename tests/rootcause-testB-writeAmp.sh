#!/bin/bash
set -uo pipefail
# ============================================================
# 测试B-口径A: 写放大对照 (Buddy Mirror vs RAID0 非镜像子目录)
#   论点: randwrite/randrw 未达标 = Buddy Mirror 2× 写放大 + NVMe 聚合,
#         非网络. 用非镜像子目录对照量化.
#
# 镜像根 (/mnt/beegfs/test_dir, Buddy Mirror) vs
# 非镜像子目录 (/mnt/beegfs/nomirror-test, RAID0/chunk1M/numtargets=6)
# randwrite(128,256K,60s) + randrw(128,256K,60s), 各 2 轮, iostat 抓 6 NVMe.
# fio 参数同 bench-full.sh run_rand. 测后删 nomirror-test.
# ============================================================
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
MNT=/mnt/beegfs
MIRROR_DIR="${MNT}/test_dir"
NOMIRROR_DIR="${MNT}/nomirror-test"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="/tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testB-writeAmp-${TS}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUTDIR"
LOG="${OUTDIR}/summary.md"
log(){ echo "$@" | tee -a "$LOG"; }

log "# 测试B-写放大对照 ${TS}"
log "# 镜像(Buddy Mirror) vs 非镜像(RAID0), randwrite+randrw 各2轮"

# --- deploy sampler to 3 slaves ---
for ip in "${SLAVES[@]}"; do
    sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "cat > /tmp/ib-iostat-sampler.sh && chmod +x /tmp/ib-iostat-sampler.sh" < "${SCRIPT_DIR}/lib/ib-iostat-sampler.sh"
done

# --- record root stripe (Buddy Mirror evidence) + create nomirror subdir ---
{
    echo "### date: $(date)"
    echo "### root getentryinfo (Buddy Mirror)"
    sudo beegfs-ctl --getentryinfo --entry="${MNT}" 2>&1
    echo "### nomirror-test getentryinfo (before setpattern)"
    sudo beegfs-ctl --getentryinfo --entry="${NOMIRROR_DIR}" 2>&1
} > "${OUTDIR}/stripe-evidence.txt" 2>&1

mkdir -p "${NOMIRROR_DIR}"
sudo beegfs-ctl --setpattern --pattern=raid0 --chunksize=1m --numtargets=6 "${NOMIRROR_DIR}" 2>&1 | tee -a "${OUTDIR}/stripe-evidence.txt"
echo "### nomirror-test getentryinfo (after setpattern, confirm RAID0)" >> "${OUTDIR}/stripe-evidence.txt"
sudo beegfs-ctl --getentryinfo --entry="${NOMIRROR_DIR}" 2>&1 | tee -a "${OUTDIR}/stripe-evidence.txt"
log "# nomirror-test created: RAID0/chunk1M/numtargets=6"

# --- env + RDMA sentinel ---
{
    echo "### beegfs-net"
    beegfs-net 2>/dev/null
    echo "### targets state"
    sudo beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null
} > "${OUTDIR}/env-snapshot.txt" 2>&1
mkdir -p "${MIRROR_DIR}"
rm -f "${MIRROR_DIR}"/* 2>/dev/null
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
fio --name=sentinel --directory="${MIRROR_DIR}" --rw=write --refill_buffers --bs=256K --size=1G --direct=1 --end_fsync=1 > "${OUTDIR}/rdma-sentinel.txt" 2>&1
CLATMIN=$(grep -oP 'clat \(usec\): min=\K[0-9.]+' "${OUTDIR}/rdma-sentinel.txt" | head -1)
log "# RDMA sentinel clat_min=${CLATMIN}us"
rm -f "${MIRROR_DIR}"/* 2>/dev/null

drop_all_caches(){
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}
start_samplers(){
    local tag="$1"
    for ip in "${SLAVES[@]}"; do
        local h; h=$(echo "$ip" | awk -F. '{print $4}')
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "rm -f /tmp/ib-stop; nohup bash /tmp/ib-iostat-sampler.sh /tmp/samples-${tag}-${h} 600 </dev/null >/dev/null 2>&1 &"
    done
}
stop_samplers(){
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "touch /tmp/ib-stop; sleep 1; pkill -f ib-iostat-sampler 2>/dev/null; true" 2>/dev/null
    done
}
collect_samplers(){
    local tag="$1"
    for ip in "${SLAVES[@]}"; do
        local h; h=$(echo "$ip" | awk -F. '{print $4}')
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/samples-${tag}-${h}.iostat" "${OUTDIR}/iostat-${tag}-slave${h}.txt" 2>/dev/null || true
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/samples-${tag}-${h}.ib" "${OUTDIR}/ib-${tag}-slave${h}.ib" 2>/dev/null || true
    done
}

run_rand(){
    local name="$1" rw="$2" dir="$3" tag="$4"
    local of="${OUTDIR}/${name}.txt"
    drop_all_caches
    start_samplers "$tag"
    sleep 3
    echo "# ${name}: rw=${rw} bs=256K iodepth=128 numjobs=128 direct=1 runtime=60s dir=${dir}" > "$of"
    echo "# date: $(date)" >> "$of"
    fio --directory="${dir}" --name=storage_test --filesize=1G --size=1G \
        --bs=256K --rw="${rw}" --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --group_reporting \
        --time_based --runtime=60s >> "$of" 2>&1
    local rd wr
    rd=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$of" | head -1)
    [ -z "$rd" ] && rd=$(grep -oP 'READ: bw=\K[0-9.]+(?=GiB/s)' "$of" | head -1) && [ -n "$rd" ] && rd=$(awk "BEGIN{printf \"%.0f\", $rd*1024}")
    wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=MiB/s)' "$of" | head -1)
    [ -z "$wr" ] && wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=GiB/s)' "$of" | head -1) && [ -n "$wr" ] && wr=$(awk "BEGIN{printf \"%.0f\", $wr*1024}")
    local riops wiops
    riops=$(grep -oiP 'read: IOPS=\K[0-9.]+[km]?' "$of" | head -1)
    wiops=$(grep -oiP 'write: IOPS=\K[0-9.]+[km]?' "$of" | head -1)
    log "# ${name}: READ=${rd:-NA} WRITE=${wr:-NA} MiB/s IOPS_R=${riops:-NA} IOPS_W=${wiops:-NA}"
    sleep 3
    stop_samplers
    collect_samplers "$tag"
}

for round in 1 2; do
    log ""
    log "## Round ${round}"
    # mirror (Buddy Mirror) — clean files for fresh round
    rm -rf "${MIRROR_DIR}"/* 2>/dev/null
    run_rand "mirror-randwrite-r${round}" randwrite "${MIRROR_DIR}" "m-rw-r${round}"
    run_rand "mirror-randrw-r${round}"    randrw    "${MIRROR_DIR}" "m-rrw-r${round}"
    # nomirror (RAID0)
    rm -rf "${NOMIRROR_DIR}"/* 2>/dev/null
    run_rand "nomirror-randwrite-r${round}" randwrite "${NOMIRROR_DIR}" "nm-rw-r${round}"
    run_rand "nomirror-randrw-r${round}"    randrw    "${NOMIRROR_DIR}" "nm-rrw-r${round}"
done

# --- cleanup nomirror subdir ---
rm -rf "${NOMIRROR_DIR}"
log ""
log "# cleanup: nomirror-test removed; root stripe untouched"
{
    echo "### post-cleanup root getentryinfo (confirm Buddy Mirror intact)"
    sudo beegfs-ctl --getentryinfo --entry="${MNT}" 2>&1
    echo "### nomirror-test existence check (should be gone)"
    ls -la "${NOMIRROR_DIR}" 2>&1
} > "${OUTDIR}/cleanup-evidence.txt" 2>&1

# --- commands.sh ---
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# 测试B-写放大对照 ${TS}
# 镜像(/mnt/beegfs/test_dir, Buddy Mirror) vs 非镜像(/mnt/beegfs/nomirror-test, RAID0)
beegfs-ctl --setpattern --pattern=raid0 --chunksize=1m --numtargets=6 /mnt/beegfs/nomirror-test
beegfs-ctl --getentryinfo --entry=/mnt/beegfs/nomirror-test
# randwrite (128,256K,60s) on mirror:
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# randwrite on nomirror:
fio --directory=/mnt/beegfs/nomirror-test --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# randrw (128,256K,60s) on mirror:
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# randrw on nomirror:
fio --directory=/mnt/beegfs/nomirror-test --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# concurrent: iostat -x 1 on 3 slaves
rm -rf /mnt/beegfs/nomirror-test
CMDEOF
chmod +x "${OUTDIR}/commands.sh"
log "# DONE results: ${OUTDIR}"
