#!/bin/bash
# Collect 157 co-deployment evidence during fio workload
# Usage: bash collect-157-evidence.sh <test_type>
#   test_type: seqwrite | randwrite

set -uo pipefail

TEST="${1:?usage: $0 seqwrite|randwrite}"
MNT="/mnt/beegfs"
DIR="${MNT}/evidence-test"
RESULT_DIR="/tmp/evidence-157"

mkdir -p "$DIR" "$RESULT_DIR"

echo "===== TEST: ${TEST} ====="
echo "===== DATE: $(date) ====="
echo "===== HOST: $(hostname) ====="
echo ""

# --- Network before ---
echo "===== NETWORK BEFORE ====="
cat /proc/net/dev
echo ""

# --- CPU info ---
echo "===== CPU CORES ====="
nproc
echo "===== LOAD BEFORE ====="
cat /proc/loadavg
echo ""

# --- Start fio based on test type ---
if [ "$TEST" = "seqwrite" ]; then
    fio --name=ev-seqwrite --directory="$DIR" --rw=write --bs=256K --size=4G \
        --refill_buffers --direct=1 --time_based --runtime=60s \
        --group_reporting > "$RESULT_DIR/fio-${TEST}.txt" 2>&1 &
elif [ "$TEST" = "randwrite" ]; then
    fio --name=ev-randwrite --directory="$DIR" --rw=randwrite --bs=256K \
        --filesize=256M --size=256M --numjobs=128 --ioengine=libaio \
        --iodepth=128 --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=60s \
        > "$RESULT_DIR/fio-${TEST}.txt" 2>&1 &
else
    echo "Unknown test type: $TEST"
    exit 1
fi
FIO_PID=$!
echo "===== FIO STARTED (PID=$FIO_PID) ====="
echo ""

# --- Wait for fio to stabilize ---
sleep 10

# --- Top sample 1 ---
echo "===== TOP SAMPLE 1 (10s into fio) ====="
top -bn1 2>/dev/null | head -25
echo ""
sleep 10

# --- Top sample 2 ---
echo "===== TOP SAMPLE 2 (20s into fio) ====="
top -bn1 2>/dev/null | head -25
echo ""
sleep 10

# --- Top sample 3 ---
echo "===== TOP SAMPLE 3 (30s into fio) ====="
top -bn1 2>/dev/null | head -25
echo ""

# --- NUMA ---
echo "===== NUMASTAT ====="
numastat -m 2>/dev/null | head -30
echo ""

# --- PS: top CPU consumers ---
echo "===== PS TOP CPU (30s into fio) ====="
ps -eo pid,comm,%cpu,%mem,psr,cmd --sort=-%cpu 2>/dev/null | head -30
echo ""

# --- BeeGFS + fio processes ---
echo "===== BEEGFS + FIO PROCESSES ====="
ps -eo pid,comm,%cpu,%mem,cmd 2>/dev/null | grep -E "beegfs|fio|weka" | grep -v grep
echo ""

# --- Network after ---
echo "===== NETWORK AFTER (40s into fio) ====="
cat /proc/net/dev
echo ""

# --- Socket stats ---
echo "===== SS SUMMARY ====="
ss -s 2>/dev/null
echo ""

echo "===== SS BEEGFS CONNECTIONS ====="
ss -tnp 2>/dev/null | grep -E "8008|8005|8003|8004" | head -20
echo ""

# --- Wait for fio to finish ---
echo "===== WAITING FOR FIO TO FINISH ====="
wait $FIO_PID 2>/dev/null
echo "FIO exit code: $?"
echo ""

# --- Load after ---
echo "===== LOAD AFTER ====="
cat /proc/loadavg
echo ""

# --- FIO result ---
echo "===== FIO RESULT ====="
cat "$RESULT_DIR/fio-${TEST}.txt"
echo ""

# --- Cleanup ---
rm -rf "$DIR"
echo "===== CLEANUP DONE ====="
echo "===== END: $(date) ====="
