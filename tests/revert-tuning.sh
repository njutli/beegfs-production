#!/bin/bash
# Revert slave tuning to defaults (match 157 untuned state)
# Only runtime params — NO service restart, NO business impact
set -uo pipefail

echo "=== Reverting tuning on $(hostname) ==="

# THP: always -> madvise (default)
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# VM: revert to defaults
echo 10 > /proc/sys/vm/dirty_background_ratio
echo 20 > /proc/sys/vm/dirty_ratio
echo 100 > /proc/sys/vm/vfs_cache_pressure
echo 129996 > /proc/sys/vm/min_free_kbytes
echo 0 > /proc/sys/vm/zone_reclaim_mode

# Block devices: revert read_ahead/nr_requests/max_sectors
# nvme0n1/nvme1n1: ra=256, maxsec=1280 (observed on 157)
# nvme2n1/nvme3n1: ra=128, maxsec=1024 (observed on 157)
# nr_requests: 1023 (observed on 157)
for dev in /sys/block/nvme*; do
    [ -d "$dev" ] || continue
    devname=$(basename "$dev")
    [ "$devname" = "nvme0n1" ] && { echo 256 > "$dev/queue/read_ahead_kb" 2>/dev/null || true; echo 1280 > "$dev/queue/max_sectors_kb" 2>/dev/null || true; }
    [ "$devname" = "nvme1n1" ] && { echo 256 > "$dev/queue/read_ahead_kb" 2>/dev/null || true; echo 1280 > "$dev/queue/max_sectors_kb" 2>/dev/null || true; }
    [ "$devname" = "nvme2n1" ] && { echo 128 > "$dev/queue/read_ahead_kb" 2>/dev/null || true; echo 1024 > "$dev/queue/max_sectors_kb" 2>/dev/null || true; }
    [ "$devname" = "nvme3n1" ] && { echo 128 > "$dev/queue/read_ahead_kb" 2>/dev/null || true; echo 1024 > "$dev/queue/max_sectors_kb" 2>/dev/null || true; }
    echo 1023 > "$dev/queue/nr_requests" 2>/dev/null || true
done

echo "=== Reverted. Verify: ==="
echo "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "dirty_bg: $(cat /proc/sys/vm/dirty_background_ratio) dirty: $(cat /proc/sys/vm/dirty_ratio)"
for d in /sys/block/nvme*; do [ -d "$d" ] && echo "$(basename $d): ra=$(cat $d/queue/read_ahead_kb) nr=$(cat $d/queue/nr_requests) maxsec=$(cat $d/queue/max_sectors_kb)"; done
