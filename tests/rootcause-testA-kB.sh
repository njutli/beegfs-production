#!/bin/bash
set -uo pipefail
# ============================================================
# 测试A-口径B: 单流 seqwrite + multi-seqwrite(16) 期间抓
#   eno12409 sar -n DEV 1 (4 节点), 坐实"单流链路未打满, multi 打满"
#
# 口径B态: connUseRDMA=false + eno12409 + 双向 tc tbf 1gbit.
# fio: size=1G/256K/direct=1/end_fsync=1; multi=16.
# 测后须用 rootcause-restore-rdma.sh 恢复 RDMA!
# ============================================================
ROUND="${1:?usage: $0 <round>}"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
MNT=/mnt/beegfs
SEQ_DIR="${MNT}/seq_dir"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="/tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kB-r${ROUND}-${TS}"
mkdir -p "$OUTDIR"
LOG="${OUTDIR}/summary.md"
log(){ echo "$@" | tee -a "$LOG"; }

log "# 测试A-口径B round=${ROUND} ${TS}"
log "# 论点: 单流 QD1 + 镜像双写 + 千兆 RTT 延迟串行, 链路未打满"
log "# fio: 1G/256K/direct=1/end_fsync=1; multi=16; 对照 multi vs 单流"

# --- env + evidence ---
{
    echo "### date: $(date)"
    echo "### beegfs-net (expect TCP 10.114.1.x)"
    beegfs-net 2>/dev/null
    echo "### connUseRDMA / connInterfacesFile"
    grep connUseRDMA /etc/beegfs/beegfs-client.conf | grep -v '#'
    cat /etc/beegfs/connInterfacesFile.conf
    echo "### tc qdisc (4 nodes)"
    echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null | grep tbf
    for ip in "${SLAVES[@]}"; do
        echo -n "${ip}: "
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null | grep tbf || echo MISSING"
    done
    echo "### targets"
    echo $SSHP | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "# env snapshot -> env-snapshot.txt"

drop_all_caches(){
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}
start_sars(){
    local tag="$1"
    # 157 local sar
    nohup sar -n DEV 1 600 </dev/null > "${OUTDIR}/sar-157-${tag}.raw" 2>&1 &
    # slaves sar
    for ip in "${SLAVES[@]}"; do
        local h; h=$(echo "$ip" | awk -F. '{print $4}')
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "rm -f /tmp/sar-stop; nohup sar -n DEV 1 600 </dev/null > /tmp/sar-${h}-${tag}.raw 2>&1 &"
    done
}
stop_sars(){
    echo $SSHP | sudo -S pkill -x sar 2>/dev/null || true
    for ip in "${SLAVES[@]}"; do
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "echo $SSHP | sudo -S pkill -x sar 2>/dev/null; true" 2>/dev/null
    done
}
collect_sars(){
    local tag="$1"
    grep eno12409 "${OUTDIR}/sar-157-${tag}.raw" 2>/dev/null > "${OUTDIR}/sar-157-${tag}.txt" || true
    rm -f "${OUTDIR}/sar-157-${tag}.raw"
    for ip in "${SLAVES[@]}"; do
        local h; h=$(echo "$ip" | awk -F. '{print $4}')
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/sar-${h}-${tag}.raw" "${OUTDIR}/sar-slave${h}-${tag}.raw" 2>/dev/null || true
        grep eno12409 "${OUTDIR}/sar-slave${h}-${tag}.raw" 2>/dev/null > "${OUTDIR}/sar-slave${h}-${tag}.txt" || true
        rm -f "${OUTDIR}/sar-slave${h}-${tag}.raw"
    done
}

run_item(){
    local name="$1" rw="$2" nj="$3" tag="$4"
    local of="${OUTDIR}/${name}.txt"
    mkdir -p "$SEQ_DIR"; rm -f "$SEQ_DIR"/*
    drop_all_caches
    start_sars "$tag"
    sleep 3
    echo "# ${name}: rw=${rw} bs=256K size=1G numjobs=${nj} direct=1 end_fsync=1" > "$of"
    echo "# date: $(date)" >> "$of"
    local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=256K --size=1G"
    [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
    args="$args --direct=1 --end_fsync=1"
    echo "# cmd: fio $args" >> "$of"
    fio $args >> "$of" 2>&1
    local wr; wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=MiB/s)' "$of" | head -1)
    [ -z "$wr" ] && wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=GiB/s)' "$of" | head -1) && [ -n "$wr" ] && wr=$(awk "BEGIN{printf \"%.0f\", $wr*1024}")
    local clatmin; clatmin=$(grep -oP 'clat \(usec\): min=\K[0-9.]+' "$of" | head -1)
    local clatavg; clatavg=$(grep -oP 'clat \(usec\):.*avg=\K[0-9.]+' "$of" | head -1)
    log "# ${name}: WRITE=${wr:-NA} MiB/s clat_min=${clatmin:-NA}us clat_avg=${clatavg:-NA}us"
    sleep 3
    stop_sars
    collect_sars "$tag"
    rm -f "$SEQ_DIR"/*
}

run_item "seqwrite"       write 1  "seqwrite"
run_item "multi-seqwrite" write 16 "mseqwrite"

# --- commands.sh ---
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# 测试A-口径B round=${ROUND} ${TS}
SEQ_DIR=${MNT}/seq_dir
fio --name=seqwrite --directory=\$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=1G --direct=1 --end_fsync=1
fio --name=multi-seqwrite --directory=\$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=1G --numjobs=16 --group_reporting --direct=1 --end_fsync=1
# concurrent sar -n DEV 1 on 4 nodes eno12409
CMDEOF
chmod +x "${OUTDIR}/commands.sh"
log "# DONE results: ${OUTDIR}"
