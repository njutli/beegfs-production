#!/bin/bash
# IB + iostat sampler for BeeGFS rootcause NIC-utilization tests.
# Runs on each storage slave. Samples infiniband counters + iostat every 1s.
# Stops when /tmp/ib-stop appears, or after MAX_ITERS seconds.
#
# Usage: ib-iostat-sampler.sh <output_prefix> [max_iters]
#   Produces <output_prefix>.ib (infiniband counters, cumulative + timestamp)
#           <output_prefix>.iostat (iostat -x 1)
set -u
OUT_PREFIX="${1:?usage: $0 <output_prefix> [max_iters]}"
MAX_ITERS="${2:-600}"
IB_OUT="${OUT_PREFIX}.ib"
IOSTAT_OUT="${OUT_PREFIX}.iostat"

echo "# start epoch=$(date +%s) $(date)" > "$IB_OUT"

# iostat in background; self-terminates after MAX_ITERS or when killed
iostat -x 1 "$MAX_ITERS" > "$IOSTAT_OUT" 2>&1 &
IOSTAT_PID=$!

i=0
while [ "$i" -lt "$MAX_ITERS" ]; do
    [ -f /tmp/ib-stop ] && break
    TS=$(date +%s)
    LINE="${TS}"
    for p in /sys/class/infiniband/mlx5_*/ports/*/counters; do
        DEV=$(echo "$p" | grep -oP 'mlx5_\d+')
        XMIT=$(cat "$p/port_xmit_data" 2>/dev/null || echo NA)
        RCV=$(cat "$p/port_rcv_data" 2>/dev/null || echo NA)
        LINE="${LINE} ${DEV}_xmit=${XMIT} ${DEV}_rcv=${RCV}"
    done
    echo "$LINE" >> "$IB_OUT"
    i=$((i + 1))
    sleep 1
done
echo "# stop epoch=$(date +%s) $(date) iters=${i}" >> "$IB_OUT"
kill "$IOSTAT_PID" 2>/dev/null || true
