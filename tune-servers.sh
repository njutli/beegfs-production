#!/bin/bash
set -euo pipefail

# ============================================================
# Performance Tuning for BeeGFS (run AFTER deployment)
#
# Tuning: swap, THP, sysctl, I/O scheduler, fd limits
# Most changes take effect immediately; fd limits may need
# service restart.
#
# Usage: sudo bash tune-servers.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "========================================"
echo "Performance Tuning — BeeGFS"
echo "Host: $(hostname)"
echo "========================================"

# ============================================================
# 1. Disable swap
# ============================================================

echo ""
echo ">>> Disabling swap..."
echo "    Why: BeeGFS metadata and storage services use memory heavily."
echo "    Swap causes latency spikes that hurt distributed performance."
echo ""

if swapon --show | grep -q '^/'; then
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
    echo "  Swap disabled."
else
    echo "  Swap already disabled."
fi

# ============================================================
# 2. Disable Transparent Huge Pages
# ============================================================

echo ""
echo ">>> Disabling Transparent Huge Pages..."
echo "    Why: THP compaction stalls user-space for hundreds of ms,"
echo "    deadly for latency-sensitive distributed storage."
echo ""

cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable disable-thp
systemctl start disable-thp

# ============================================================
# 3. Sysctl tuning
# ============================================================

echo ""
echo ">>> Sysctl tuning..."

cat > /etc/sysctl.d/99-beegfs.conf <<'EOF'
# Network — increase connection backlog and reduce TIME_WAIT
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 16384

# Increase network buffer sizes for high throughput
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 67392 134217728

# Virtual memory — minimise swap, keep writes in memory
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# File descriptors
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1
echo "  Done."

# ============================================================
# 4. I/O scheduler — none for NVMe
# ============================================================

echo ""
echo ">>> Setting I/O scheduler to none (best for NVMe)..."

for disk in /sys/block/nvme*/queue/scheduler; do
    if [ -f "${disk}" ]; then
        echo "none" > "${disk}" 2>/dev/null || true
    fi
done

for disk in /sys/block/sd*/queue/scheduler; do
    if [ -f "${disk}" ]; then
        if grep -q '\[none\]' "${disk}" 2>/dev/null; then
            :
        else
            echo "none" > "${disk}" 2>/dev/null || true
        fi
    fi
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
    if [ -f "${gov}" ]; then
        echo "performance" > "${gov}" 2>/dev/null || true
    fi
done
echo "  Done."

echo ""
echo "========================================"
echo "Tuning complete."
echo "========================================"
echo ""
echo "Swap, THP, sysctl, I/O scheduler, CPU governor: immediate effect"
echo "File descriptor limits: restart BeeGFS services to apply:"
echo "  sudo systemctl restart beegfs-mgmtd beegfs-meta beegfs-storage beegfs-client"
