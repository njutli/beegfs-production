#!/bin/bash
set -uo pipefail
# ============================================================
# 口径B进入: 切换数据面到 eno12409 (10GbE TCP, 千兆限速)
#   1. 备份 conf (4 节点)
#   2. connUseRDMA=false (4 节点)
#   3. connInterfacesFile.conf -> eno12409 (4 节点)
#   4. 双向 tc tbf 1gbit (157 + 3 slaves eno12409 egress)
#   5. 重启 BeeGFS (mgmtd→meta→storage→client)
#   6. 等 target Online/Good
#   7. 哨兵: beegfs-net 全 TCP(10.114.1.x) + seqwrite≈53
#
# 测后须用 rootcause-restore-rdma.sh 恢复 RDMA 锁定态!
# ============================================================
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
TS="$(date +%Y%m%d-%H%M%S)"
BAK="/etc/beegfs/backup-kB-${TS}"
OUTDIR="/tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/kB-enter-${TS}"
mkdir -p "$OUTDIR"
LOG="${OUTDIR}/enter.log"
log(){ echo "$@" | tee -a "$LOG"; }
log "# 口径B进入 ${TS}"

ssh_slave(){ local ip="$1"; shift; sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "$@"; }
sudo_slave(){ local ip="$1"; shift; sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "echo $SSHP | sudo -S $* 2>/dev/null"; }

# --- 1. backup conf (4 nodes) ---
log "## 1. backup conf"
for node in 157-host "${SLAVES[@]}"; do
    ip="${node#157-host}"
    [ "$node" = "157-host" ] && ip="localhost"
    if [ "$node" = "157-host" ]; then
        sudo mkdir -p "$BAK"
        sudo cp -a /etc/beegfs/*.conf /etc/beegfs/connInterfacesFile.conf "$BAK/" 2>/dev/null || true
    else
        ssh_slave "$ip" "echo $SSHP | sudo -S mkdir -p $BAK 2>/dev/null; echo $SSHP | sudo -S cp -a /etc/beegfs/*.conf /etc/beegfs/connInterfacesFile.conf $BAK/ 2>/dev/null; true"
    fi
done
log "# backup -> ${BAK} (4 nodes)"

# --- 2+3. connUseRDMA=false + connInterfacesFile=eno12409 (4 nodes) ---
log "## 2. connUseRDMA=false (4 nodes)"
log "## 3. connInterfacesFile.conf -> eno12409 (4 nodes)"
# 157
sudo sed -i 's/^connUseRDMA.*/connUseRDMA                  = false/' /etc/beegfs/beegfs-client.conf 2>/dev/null || true
echo 'eno12409' | sudo tee /etc/beegfs/connInterfacesFile.conf >/dev/null
log "# 157 done: $(grep connUseRDMA /etc/beegfs/beegfs-client.conf | tail -1) | connIF=$(cat /etc/beegfs/connInterfacesFile.conf)"
# slaves
for ip in "${SLAVES[@]}"; do
    ssh_slave "$ip" "echo $SSHP | sudo -S sed -i 's/^connUseRDMA.*/connUseRDMA                  = false/' /etc/beegfs/beegfs-storage.conf /etc/beegfs/beegfs-meta.conf 2>/dev/null; echo eno12409 | sudo tee /etc/beegfs/connInterfacesFile.conf >/dev/null; true"
    log "# ${ip}: connUseRDMA=$(ssh_slave "$ip" 'grep -h connUseRDMA /etc/beegfs/beegfs-storage.conf | tail -1') connIF=$(ssh_slave "$ip" 'cat /etc/beegfs/connInterfacesFile.conf')"
done

# --- 4. tc tbf 1gbit on eno12409 (4 nodes) ---
log "## 4. tc tbf 1gbit on eno12409 (bidirectional, 4 nodes)"
TC_CMD="tc qdisc replace dev eno12409 root tbf rate 1gbit burst 32kbit latency 400ms"
echo $SSHP | sudo -S $TC_CMD 2>/dev/null
log "# 157 tc: $(echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null | grep tbf || echo MISSING)"
for ip in "${SLAVES[@]}"; do
    ssh_slave "$ip" "echo $SSHP | sudo -S $TC_CMD 2>/dev/null; true"
    log "# ${ip} tc: $(ssh_slave "$ip" "echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null | grep tbf || echo MISSING")"
done

# --- 5. restart BeeGFS ---
log "## 5. restart BeeGFS"
log "# 157 mgmtd..."
echo $SSHP | sudo -S timeout 30 systemctl restart beegfs-mgmtd 2>/dev/null || {
    log "# mgmtd restart timeout, force kill + start"
    echo $SSHP | sudo -S systemctl stop beegfs-mgmtd 2>/dev/null
    echo $SSHP | sudo -S pkill -9 -f beegfs-mgmtd 2>/dev/null
    sleep 2
    echo $SSHP | sudo -S systemctl start beegfs-mgmtd 2>/dev/null
}
sleep 5
log "# 157 meta + slaves meta+storage..."
echo $SSHP | sudo -S systemctl restart beegfs-meta 2>/dev/null || true
for ip in "${SLAVES[@]}"; do
    ssh_slave "$ip" "echo $SSHP | sudo -S systemctl restart beegfs-meta beegfs-storage 2>/dev/null; true"
done
sleep 5
log "# 157 client..."
echo $SSHP | sudo -S systemctl restart beegfs-client 2>/dev/null || true
sleep 10

# --- 6. wait for targets Online/Good ---
log "## 6. wait targets Online/Good"
for i in $(seq 1 30); do
    STATES=$(echo $SSHP | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null | awk '{print $2}' | sort -u | grep -v '^$' | tr '\n' ',')
    log "# t=${i}0s targets states: ${STATES}"
    echo "$STATES" | grep -qvE 'Offline|Initializing|NeedsResync|Unknown' && echo "$STATES" | grep -q 'Good' && { log "# all Good"; break; }
    sleep 10
done

# --- 7. sentinel ---
log "## 7. sentinel: beegfs-net + seqwrite"
{
    echo "### beegfs-net (expect TCP 10.114.1.x)"
    beegfs-net 2>/dev/null
    echo "### targets state"
    echo $SSHP | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null
    echo "### connUseRDMA / connInterfacesFile"
    grep connUseRDMA /etc/beegfs/beegfs-client.conf | tail -1
    cat /etc/beegfs/connInterfacesFile.conf
    echo "### tc qdisc"
    echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null
} > "${OUTDIR}/kB-evidence.txt" 2>&1

mkdir -p /mnt/beegfs/seq_dir
rm -f /mnt/beegfs/seq_dir/*
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
fio --name=sentinel --directory=/mnt/beegfs/seq_dir --rw=write --refill_buffers --bs=256K --size=1G --direct=1 --end_fsync=1 > "${OUTDIR}/kB-sentinel.txt" 2>&1
BW=$(grep -oP 'WRITE: bw=\K[0-9.]+' "${OUTDIR}/kB-sentinel.txt" | head -1)
CLATMIN=$(grep -oP 'clat \(usec\): min=\K[0-9.]+' "${OUTDIR}/kB-sentinel.txt" | head -1)
log "# 口径B哨兵: seqwrite bw=${BW}MiB/s clat_min=${CLATMIN}us (expect ~53, clat high>>250us TCP)"
rm -f /mnt/beegfs/seq_dir/*
log ""
log "# DONE. 数据面已切 eno12409 TCP+tc. 测后必须恢复 RDMA!"
log "# evidence: ${OUTDIR}/kB-evidence.txt"
