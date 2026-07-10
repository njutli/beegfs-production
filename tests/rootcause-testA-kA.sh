#!/bin/bash
set -uo pipefail
# ============================================================
# 测试A-口径A: 单流 + multi seqread/seqwrite 期间抓 100GbE RDMA
#   NIC 利用率 (infiniband counters) + iostat，坐实"延迟主导链路未打满"
#
# 复用 bench-full.sh run_seq 的 fio 参数 (4G/256K/direct=1, multi=16).
# 每项 fio 全程在 3 slave 并发跑 ib-iostat-sampler.sh.
#
# Usage: rootcause-testA-kA.sh <round>
#   round: 1 / 2 ...
# ============================================================
ROUND="${1:?usage: $0 <round>}"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
MNT=/mnt/beegfs
SEQ_DIR="${MNT}/seq_dir"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="/tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kA-r${ROUND}-${TS}"
mkdir -p "$OUTDIR"
LOG="${OUTDIR}/summary.md"
log(){ echo "$@" | tee -a "$LOG"; }

log "# 测试A-口径A round=${ROUND} ${TS}"
log "# 论点: 单流 QD1 下 100GbE 远没打满 -> 瓶颈=per-IO 延迟串行非带宽"
log "# fio: 4G/256K/direct=1; multi=16; 对照 multi vs 单流"

# --- deploy sampler to 3 slaves ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for ip in "${SLAVES[@]}"; do
    sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "cat > /tmp/ib-iostat-sampler.sh && chmod +x /tmp/ib-iostat-sampler.sh" < "${SCRIPT_DIR}/lib/ib-iostat-sampler.sh"
done
log "# sampler deployed to 3 slaves"

# --- env snapshot + RDMA evidence ---
{
    echo "### date: $(date)"
    echo "### hostname: $(hostname)"
    echo "### beegfs-net (RDMA locked evidence)"
    beegfs-net 2>/dev/null
    echo "### connUseRDMA / connInterfacesFile"
    grep -h connUseRDMA /etc/beegfs/beegfs-client.conf /etc/beegfs/beegfs-storage.conf 2>/dev/null | sort -u
    grep -h connInterfacesFile /etc/beegfs/beegfs-client.conf /etc/beegfs/beegfs-storage.conf 2>/dev/null | sort -u
    echo "### connInterfacesFile.conf"
    cat /etc/beegfs/connInterfacesFile.conf 2>/dev/null
    echo "### targets state"
    sudo beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null
    echo "### root stripe"
    sudo beegfs-ctl --getentryinfo --entry="${MNT}" 2>&1
    echo "### services"
    systemctl is-active beegfs-mgmtd beegfs-meta beegfs-client 2>/dev/null
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "# env snapshot -> ${OUTDIR}/env-snapshot.txt"

# --- RDMA sentinel (clat_min < 250us) ---
mkdir -p "$SEQ_DIR"
rm -f "$SEQ_DIR"/* 2>/dev/null
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
SENT="${OUTDIR}/rdma-sentinel.txt"
fio --name=sentinel --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=1G --direct=1 --end_fsync=1 > "$SENT" 2>&1
CLATMIN=$(grep -oP 'clat \(usec\): min=\K[0-9.]+' "$SENT" | head -1)
log "# RDMA sentinel: seqwrite clat_min=${CLATMIN}us (<250us => RDMA OK)"
rm -f "$SEQ_DIR"/* 2>/dev/null

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
        sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "rm -f /tmp/ib-stop; nohup bash /tmp/ib-iostat-sampler.sh /tmp/samples-${tag}-${h} 600 >/dev/null 2>&1 &"
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
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/samples-${tag}-${h}.ib" "${OUTDIR}/ib-${tag}-slave${h}.ib" 2>/dev/null || true
        sshpass -p "$SSHP" scp $SSHO "${SSHU}@${ip}:/tmp/samples-${tag}-${h}.iostat" "${OUTDIR}/iostat-${tag}-slave${h}.txt" 2>/dev/null || true
    done
}

# --- helper to run one fio item with concurrent sampling ---
run_item(){
    local name="$1" rw="$2" nj="$3" fsync="$4" tag="$5"
    local of="${OUTDIR}/${name}.txt"
    drop_all_caches
    start_samplers "$tag"
    sleep 3   # let samplers capture pre-state baseline
    echo "# ${name}: rw=${rw} bs=256K size=4G numjobs=${nj} fsync=${fsync} direct=1" > "$of"
    echo "# date: $(date)" >> "$of"
    local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=256K --size=4G"
    [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
    [ "$fsync" = "1" ] && args="$args --end_fsync=1"
    args="$args --direct=1"
    echo "# cmd: fio $args" >> "$of"
    fio $args >> "$of" 2>&1
    local rd wr
    rd=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$of" | head -1)
    [ -z "$rd" ] && rd=$(grep -oP 'READ: bw=\K[0-9.]+(?=GiB/s)' "$of" | head -1) && [ -n "$rd" ] && rd=$(awk "BEGIN{printf \"%.0f\", $rd*1024}")
    wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=MiB/s)' "$of" | head -1)
    [ -z "$wr" ] && wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=GiB/s)' "$of" | head -1) && [ -n "$wr" ] && wr=$(awk "BEGIN{printf \"%.0f\", $wr*1024}")
    local clatmin; clatmin=$(grep -oP 'clat \(usec\): min=\K[0-9.]+' "$of" | head -1)
    local clatavg; clatavg=$(grep -oP 'clat \(usec\):.*avg=\K[0-9.]+' "$of" | head -1)
    log "# ${name}: READ=${rd:-NA} WRITE=${wr:-NA} MiB/s clat_min=${clatmin:-NA}us clat_avg=${clatavg:-NA}us"
    sleep 3   # capture trailing
    stop_samplers
    collect_samplers "$tag"
}

# --- prep 4G seq file for seqread ---
log ""
log "## prep: write 4G seq file"
drop_all_caches
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G --direct=1 >/dev/null 2>&1
while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2
log "# prep done"

# --- 4 items, each with concurrent IB+iostat sampling ---
log ""
log "## 测试项 (每项 fio 全程抓 3 slave IB counters + iostat)"
run_item "seqread"        read  1  0 "seqread"
run_item "seqwrite"       write 1  1 "seqwrite"
run_item "multi-seqread"  read  16 0 "mseqread"
run_item "multi-seqwrite" write 16 1 "mseqwrite"

# --- cleanup ---
rm -rf "$SEQ_DIR"/*
log ""
log "# cleanup: seq_dir removed"
log "# DONE results: ${OUTDIR}"

# --- commands.sh record ---
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# 测试A-口径A round=${ROUND} ${TS}
# fio params (match bench-full.sh run_seq, cold direct=1)
SEQ_DIR=${MNT}/seq_dir
fio --name=prep --directory=\$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --direct=1
fio --name=seqread --directory=\$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G --direct=1
fio --name=seqwrite --directory=\$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --direct=1 --end_fsync=1
fio --name=multi-seqread --directory=\$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --direct=1
fio --name=multi-seqwrite --directory=\$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --direct=1 --end_fsync=1
# concurrent sampling on 3 slaves: bash /tmp/ib-iostat-sampler.sh <prefix> 600
#   infiniband counters: /sys/class/infiniband/mlx5_*/ports/*/counters/port_xmit_data|port_rcv_data (unit=4B)
#   iostat -x 1 600
CMDEOF
chmod +x "${OUTDIR}/commands.sh"
log "# commands.sh recorded"
