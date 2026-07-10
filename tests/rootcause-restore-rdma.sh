#!/bin/bash
set -uo pipefail
# ============================================================
# 口径B收尾: 恢复 RDMA 锁定态 (与 enter-kB 逆操作)
#   1. tc qdisc del eno12409 (4 节点)
#   2. connInterfacesFile.conf -> enp139s0f0np0/f1np1 (4 节点)
#   3. connUseRDMA=true (4 节点)
#   4. 重启 BeeGFS
#   5. 等 target Online/Good
#   6. RDMA 哨兵: beegfs-net 全 RDMA(10.3.x) + clat_min<250us
# ============================================================
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHU=sunrise
SSHP=Sunrise@801
SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="/tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/kB-restore-${TS}"
mkdir -p "$OUTDIR"
LOG="${OUTDIR}/restore.log"
log(){ echo "$@" | tee -a "$LOG"; }
log "# 口径B收尾(恢复RDMA) ${TS}"

ssh_slave(){ local ip="$1"; shift; sshpass -p "$SSHP" ssh $SSHO "${SSHU}@${ip}" "$@"; }

# --- 1. tc del (4 nodes) ---
log "## 1. tc qdisc del eno12409 (4 nodes)"
echo $SSHP | sudo -S tc qdisc del dev eno12409 root 2>/dev/null || true
log "# 157 tc: $(echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null | grep tbf || echo clean)"
for ip in "${SLAVES[@]}"; do
    ssh_slave "$ip" "echo $SSHP | sudo -S tc qdisc del dev eno12409 root 2>/dev/null; true"
    log "# ${ip} tc: $(ssh_slave "$ip" "echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null | grep tbf || echo clean")"
done

# --- 2+3. restore connInterfacesFile + connUseRDMA=true ---
log "## 2. connInterfacesFile -> enp139s0f0np0/f1np1"
log "## 3. connUseRDMA=true (4 nodes)"
printf 'enp139s0f0np0\nenp139s0f1np1\n' | sudo tee /etc/beegfs/connInterfacesFile.conf >/dev/null
sudo sed -i 's/^connUseRDMA.*/connUseRDMA                  = true/' /etc/beegfs/beegfs-client.conf 2>/dev/null || true
log "# 157: connUseRDMA=$(grep connUseRDMA /etc/beegfs/beegfs-client.conf | tail -1) connIF=$(cat /etc/beegfs/connInterfacesFile.conf | tr '\n' ',')"
for ip in "${SLAVES[@]}"; do
    ssh_slave "$ip" "printf 'enp139s0f0np0\nenp139s0f1np1\n' | sudo tee /etc/beegfs/connInterfacesFile.conf >/dev/null; echo $SSHP | sudo -S sed -i 's/^connUseRDMA.*/connUseRDMA                  = true/' /etc/beegfs/beegfs-storage.conf /etc/beegfs/beegfs-meta.conf 2>/dev/null; true"
    log "# ${ip}: connUseRDMA=$(ssh_slave "$ip" 'grep -h connUseRDMA /etc/beegfs/beegfs-storage.conf | tail -1') connIF=$(ssh_slave "$ip" 'cat /etc/beegfs/connInterfacesFile.conf | tr \"\\n\" \",\"')"
done

# --- 4. restart ---
log "## 4. restart BeeGFS"
echo $SSHP | sudo -S timeout 30 systemctl restart beegfs-mgmtd 2>/dev/null || {
    log "# mgmtd timeout, force"
    echo $SSHP | sudo -S systemctl stop beegfs-mgmtd 2>/dev/null
    echo $SSHP | sudo -S pkill -9 -f beegfs-mgmtd 2>/dev/null
    sleep 2; echo $SSHP | sudo -S systemctl start beegfs-mgmtd 2>/dev/null
}
sleep 5
echo $SSHP | sudo -S systemctl restart beegfs-meta 2>/dev/null || true
for ip in "${SLAVES[@]}"; do
    ssh_slave "$ip" "echo $SSHP | sudo -S systemctl restart beegfs-meta beegfs-storage 2>/dev/null; true"
done
sleep 5
echo $SSHP | sudo -S systemctl restart beegfs-client 2>/dev/null || true
sleep 10

# --- 5. wait targets ---
log "## 5. wait targets Online/Good"
for i in $(seq 1 30); do
    STATES=$(echo $SSHP | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null | awk '{print $2}' | sort -u | grep -v '^$' | tr '\n' ',')
    log "# t=${i}0s: ${STATES}"
    echo "$STATES" | grep -qvE 'Offline|Initializing|NeedsResync|Unknown' && echo "$STATES" | grep -q 'Good' && { log "# all Good"; break; }
    sleep 10
done

# --- 6. RDMA sentinel ---
log "## 6. RDMA sentinel"
{
    echo "### beegfs-net (expect RDMA 10.3.x)"
    beegfs-net 2>/dev/null
    echo "### targets"
    echo $SSHP | sudo -S beegfs-ctl --listtargets --state --nodetype=storage 2>/dev/null
    echo "### connUseRDMA / connInterfacesFile"
    grep connUseRDMA /etc/beegfs/beegfs-client.conf | tail -1
    cat /etc/beegfs/connInterfacesFile.conf
    echo "### tc (expect clean)"
    echo $SSHP | sudo -S tc qdisc show dev eno12409 2>/dev/null
} > "${OUTDIR}/restore-evidence.txt" 2>&1
mkdir -p /mnt/beegfs/seq_dir
rm -f /mnt/beegfs/seq_dir/*
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
fio --name=sentinel --directory=/mnt/beegfs/seq_dir --rw=write --refill_buffers --bs=256K --size=1G --direct=1 --end_fsync=1 > "${OUTDIR}/rdma-sentinel.txt" 2>&1
CLATMIN=$(grep -oP 'clat \(usec\): min=\K[0-9.]+' "${OUTDIR}/rdma-sentinel.txt" | head -1)
BW=$(grep -oP 'WRITE: bw=\K[0-9.]+' "${OUTDIR}/rdma-sentinel.txt" | head -1)
log "# RDMA恢复哨兵: seqwrite bw=${BW}MiB/s clat_min=${CLATMIN}us (<250us => RDMA OK)"
rm -f /mnt/beegfs/seq_dir/*
log "# DONE. RDMA 锁定态已恢复. evidence: ${OUTDIR}/restore-evidence.txt"
