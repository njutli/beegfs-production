#!/bin/bash
# ============================================================
# baseline-check.sh — stage1 前置基线 seqwrite 验证
# 在 157 上运行：drop caches → RDMA 哨兵 → seqwrite → 提取结果
# ============================================================
set -uo pipefail

SSH_PASS="Sunrise@801"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SEQ_DIR="/mnt/beegfs/seq_dir"

echo "=== drop caches on 157 ==="
sync
echo "${SSH_PASS}" | sudo -S bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
echo "  157 caches dropped"

echo "=== drop caches on 3 slaves ==="
for ip in $SLAVE_IPS; do
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS "sunrise@${ip}" \
        "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    echo "  slave ${ip} caches dropped"
done

echo "=== RDMA 哨兵检查 ==="
echo "${SSH_PASS}" | sudo -S beegfs-net 2>/dev/null | grep -E 'ID: 10[123]' -A1 | grep 'Connections:'

echo "=== mkdir seq_dir ==="
mkdir -p "$SEQ_DIR"

echo "=== run baseline seqwrite ==="
fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
    --direct=1 --end_fsync=1 --group_reporting 2>&1 | tee /tmp/baseline-seqwrite.txt

echo "=== extract results ==="
BW=$(grep -oP "WRITE: bw=\K[0-9.]+(?=MiB/s)" /tmp/baseline-seqwrite.txt | head -1)
CLAT=$(grep -oP "clat \(usec\): min=\K[0-9]+" /tmp/baseline-seqwrite.txt | head -1)
echo "BASELINE: bw=${BW} MiB/s, clat_min=${CLAT} us"

if [ "${CLAT:-0}" -lt 250 ] 2>/dev/null; then
    echo "RDMA SENTINEL: PASS (clat_min < 250us) ✓"
else
    echo "RDMA SENTINEL: WARNING (clat_min >= 250us, may be TCP fallback)"
fi

rm -rf "$SEQ_DIR"/*
echo "=== done ==="
