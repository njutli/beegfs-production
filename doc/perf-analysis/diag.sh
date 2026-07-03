#!/bin/bash
# ============================================================
# diag.sh — BeeGFS 逐层排查脚本
#
# 用法: sudo bash diag.sh
# 检查: 裸盘 → 网络 → BeeGFS 服务 → 端到端
# ============================================================

set -uo pipefail

BEEGFS_MNT="${BEEGFS_MOUNT_POINT:-/mnt/beegfs}"
BEEGFS_MGMTD="${BEEGFS_MGMTD_HOST:-10.20.1.157}"

echo "========================================"
echo "BeeGFS Diagnostic — $(hostname) $(date)"
echo "========================================"

# --- Layer 1: Disk ---
echo ""
echo "=== Layer 1: Disk ==="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | grep -E "disk|part" | grep -v loop
echo ""
echo "beegfs mounts:"
df -h /mnt/beegfs-meta /data/disk1 /data/disk2 2>/dev/null
echo ""
echo "NVMe devices:"
for dev in /dev/nvme*n1; do
    [ -b "$dev" ] || continue
    echo "  $dev:"
    sudo smartctl -i "$dev" 2>/dev/null | grep -E "Model Number|Total NVM Capacity|Temperature" | head -3
done
echo ""
echo "storage mounts (XFS):"
for d in /data/disk1 /data/disk2; do
    if mountpoint -q "$d" 2>/dev/null; then
        echo "  $d: $(findmnt -no SOURCE,FSTYPE,OPTIONS "$d")"
    else
        echo "  $d: NOT MOUNTED"
    fi
done

# --- Layer 2: Network ---
echo ""
echo "=== Layer 2: Network ==="
echo "Interfaces:"
ip -br addr show | grep -v "lo\|veth\|cali\|tunl\|br-\|docker"
echo ""
echo "Speeds:"
for iface in eno12399 enp139s0f0np0 eno12409 enp139s0f1np1; do
    [ -f "/sys/class/net/${iface}/speed" ] && echo "  ${iface}: $(cat /sys/class/net/${iface}/speed 2>/dev/null) Mb/s"
done
echo ""
echo "MTU:"
for iface in eno12399 enp139s0f0np0; do
    [ -f "/sys/class/net/${iface}/mtu" ] && echo "  ${iface}: $(cat /sys/class/net/${iface}/mtu)"
done
echo ""
echo "Ping cluster nodes:"
for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    ping -c 2 -W 1 "$ip" 2>&1 | tail -1
done

# --- Layer 3: BeeGFS Services ---
echo ""
echo "=== Layer 3: BeeGFS Services ==="
for svc in beegfs-mgmtd beegfs-meta beegfs-storage beegfs-client; do
    echo -n "  ${svc}: "
    sudo systemctl is-active "$svc" 2>/dev/null || echo "not installed"
done
echo ""
echo "BeeGFS nodes:"
# 8.x beegfs CLI 走 gRPC (端口 8010), TLS/auth 已禁用
export BEEGFS_MGMTD_ADDR=${BEEGFS_MGMTD}:8010 BEEGFS_TLS_DISABLE=true BEEGFS_AUTH_DISABLE=true
sudo -E beegfs node list 2>&1 || true
echo ""
echo "BeeGFS targets (state):"
sudo -E beegfs target list --state 2>&1 || true
echo ""
echo "BeeGFS mirror groups:"
sudo -E beegfs mirror list 2>&1 || true
echo ""
echo "BeeGFS health df:"
sudo -E beegfs health df 2>&1 || true

# --- Layer 4: End-to-End ---
echo ""
echo "=== Layer 4: End-to-End ==="
if mountpoint -q "${BEEGFS_MNT}" 2>/dev/null; then
    echo "  Mount: OK"
    df -h "${BEEGFS_MNT}"
    echo ""
    echo "  Quick write test:"
    dd if=/dev/zero of="${BEEGFS_MNT}/diag-test.bin" bs=1M count=100 oflag=direct 2>&1 | tail -1
    rm -f "${BEEGFS_MNT}/diag-test.bin"
else
    echo "  Mount: NOT MOUNTED"
fi

echo ""
echo "========================================"
echo "Diagnostic complete."
echo "========================================"
