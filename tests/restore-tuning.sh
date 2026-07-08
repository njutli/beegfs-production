#!/bin/bash
# Restore slave tuning (back to BeeGFS optimized state)
set -uo pipefail

echo "=== Restoring tuning on $(hostname) ==="

echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo always > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

echo 5 > /proc/sys/vm/dirty_background_ratio
echo 10 > /proc/sys/vm/dirty_ratio
echo 50 > /proc/sys/vm/vfs_cache_pressure
echo 262144 > /proc/sys/vm/min_free_kbytes
echo 1 > /proc/sys/vm/zone_reclaim_mode

for dev in /sys/block/nvme*; do
    [ -d "$dev" ] || continue
    devname=$(basename "$dev")
    [ "$devname" = "nvme0n1" ] && continue
    echo 4096 > "$dev/queue/nr_requests" 2>/dev/null || true
    echo 4096 > "$dev/queue/read_ahead_kb" 2>/dev/null || true
    echo 256 > "$dev/queue/max_sectors_kb" 2>/dev/null || true
done

echo "=== Restored. Verify: ==="
echo "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "dirty_bg: $(cat /proc/sys/vm/dirty_background_ratio) dirty: $(cat /proc/sys/vm/dirty_ratio)"
for d in /sys/block/nvme*; do [ -d "$d" ] && echo "$(basename $d): ra=$(cat $d/queue/read_ahead_kb) nr=$(cat $d/queue/nr_requests) maxsec=$(cat $d/queue/max_sectors_kb)"; done
