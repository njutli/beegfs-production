#!/bin/bash
set -euo pipefail

# ============================================================
# Performance Tuning for BeeGFS (per official docs)
#
# Official doc: https://doc.beegfs.io/7.3.2/advanced_topics/storage_tuning.html
#
# Key differences from Ceph/TiKV tuning:
#   - THP: ENABLE (always) — BeeGFS recommends, opposite of Ceph
#   - IO scheduler: deadline (not none)
#   - dirty_ratio: 5/20 (per official docs)
#
# Usage: sudo bash tune-servers.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "========================================"
echo "Performance Tuning — BeeGFS (per official docs)"
echo "Host: $(hostname)"
echo "========================================"

# ============================================================
# 1. Swap — disable
# ============================================================

echo ""
echo ">>> Disabling swap..."
if swapon --show | grep -q '^/'; then
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
    echo "  Swap disabled."
else
    echo "  Swap already disabled."
fi

# ============================================================
# 2. THP — ENABLE (opposite of Ceph!)
# ============================================================

echo ""
echo ">>> Enabling Transparent Huge Pages (per BeeGFS docs)..."
echo "    Note: BeeGFS recommends THP=always, opposite of Ceph/TiKV"

cat > /etc/systemd/system/enable-thp.service <<'EOF'
[Unit]
Description=Enable Transparent Huge Pages (BeeGFS)

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo always > /sys/kernel/mm/transparent_hugepage/enabled && echo always > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Remove old disable-thp service if exists
systemctl disable disable-thp 2>/dev/null || true
rm -f /etc/systemd/system/disable-thp.service

systemctl daemon-reload
systemctl enable enable-thp
systemctl start enable-thp

# Apply immediately
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo always > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "  THP enabled (always)."

# ============================================================
# 3. Sysctl tuning (per official storage tuning docs)
# ============================================================

echo ""
echo ">>> Sysctl tuning (per official docs)..."

cat > /etc/sysctl.d/99-beegfs.conf <<'EOF'
# === Per BeeGFS official storage tuning docs ===

# Virtual memory (per official storage tuning docs: 生产环境 5/10)
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 262144
vm.zone_reclaim_mode = 1

# Network
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 16384
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 67392 134217728

# File descriptors
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1
echo "  Done."

# ============================================================
# 4. IO Scheduler (per 官方 storage tuning 文档)
#    官方建议 deadline; 但 NVMe 内核强制 'none' (NVMe 无需 IO 调度),
#    故只对 sd* 设为 deadline, NVMe 保持 none。本环境全 NVMe, 实际为 none。
# ============================================================

echo ""
echo ">>> Setting IO scheduler: deadline for sd*, none for NVMe (kernel default)..."

for disk in /sys/block/nvme*/queue/scheduler; do
    if [ -f "${disk}" ]; then
        # NVMe kernel doesn't support changing scheduler; verify it's 'none'
        current=$(cat "${disk}" 2>/dev/null || echo "")
        echo "  ${disk}: ${current} (NVMe, kept as-is)"
    fi
done

for disk in /sys/block/sd*/queue/scheduler; do
    if [ -f "${disk}" ]; then
        echo "deadline" > "${disk}" 2>/dev/null || true
    fi
done

# Increase request queue and read-ahead (per official docs)
for dev in /sys/block/nvme* /sys/block/sd*; do
    [ -d "${dev}" ] || continue
    devname=$(basename "${dev}")
    [ "${devname}" = "nvme0n1" ] && continue  # skip system disk
    echo 4096 > "${dev}/queue/nr_requests" 2>/dev/null || true
    echo 4096 > "${dev}/queue/read_ahead_kb" 2>/dev/null || true
    echo 256 > "${dev}/queue/max_sectors_kb" 2>/dev/null || true
done
echo "  Done."

# ============================================================
# 5. File descriptor limits
# ============================================================

echo ""
echo ">>> Setting file descriptor limits..."
cat > /etc/security/limits.d/99-beegfs.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF
echo "  Done."

# ============================================================
# 6. CPU governor — performance
# ============================================================

echo ""
echo ">>> Setting CPU governor to performance..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "${gov}" ] && echo "performance" > "${gov}" 2>/dev/null || true
done
echo "  Done."

# ============================================================
# 7. rc.local for non-persistent settings
# ============================================================

echo ""
echo ">>> Creating rc.local for non-persistent settings..."

cat > /etc/rc.local <<'EOF'
#!/bin/bash
# BeeGFS non-persistent tuning (per official docs)

# THP
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo always > /sys/kernel/mm/transparent_hugepage/defrag

# VM settings (per official: 生产 5/10)
echo 5 > /proc/sys/vm/dirty_background_ratio
echo 10 > /proc/sys/vm/dirty_ratio
echo 50 > /proc/sys/vm/vfs_cache_pressure
echo 262144 > /proc/sys/vm/min_free_kbytes
echo 1 > /proc/sys/vm/zone_reclaim_mode

# IO scheduler: sd* 用 deadline (官方推荐); NVMe 内核强制 none, 不写调度器
for dev in /sys/block/sd*; do
    [ -d "${dev}" ] || continue
    echo deadline > "${dev}/queue/scheduler" 2>/dev/null || true
done
# queue / read_ahead / max_sectors: 所有数据盘 (NVMe + sd, 跳过系统盘 nvme0n1)
for dev in /sys/block/nvme* /sys/block/sd*; do
    [ -d "${dev}" ] || continue
    devname=$(basename "${dev}")
    [ "${devname}" = "nvme0n1" ] && continue
    echo 4096 > "${dev}/queue/nr_requests" 2>/dev/null || true
    echo 4096 > "${dev}/queue/read_ahead_kb" 2>/dev/null || true
    echo 256 > "${dev}/queue/max_sectors_kb" 2>/dev/null || true
done

# CPU governor
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "${gov}" ] && echo "performance" > "${gov}" 2>/dev/null || true
done

exit 0
EOF
chmod +x /etc/rc.local
systemctl enable rc-local 2>/dev/null || true
echo "  rc.local created."

echo ""
echo "========================================"
echo "Tuning complete (per official BeeGFS docs)."
echo "========================================"
echo ""
echo "Changes applied:"
echo "  - THP: always (BeeGFS 推荐, 与 Ceph 相反)"
echo "  - IO scheduler: deadline(sd*) / none(NVMe, 内核强制)"
echo "  - dirty_ratio: 5/10 (per 官方生产建议)"
echo "  - read_ahead: 4096KB"
echo "  - CPU governor: performance"
echo ""
echo "Restart BeeGFS services to apply fd limits:"
echo "  sudo systemctl restart beegfs-meta beegfs-storage beegfs-client"
