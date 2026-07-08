#!/bin/bash
# Control experiment: seqwrite + layout with UNTUNED slaves
# Run 2 rounds each for sanity check
set -uo pipefail

MNT="/mnt/beegfs"
SEQ_DIR="${MNT}/ctrl-seq"
LAYOUT_DIR="${MNT}/ctrl-layout"
RESULT_DIR="/tmp/ctrl-results"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"

mkdir -p "$RESULT_DIR"

drop_all_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in $SLAVE_IPS; do
        sshpass -p "Sunrise@801" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "sunrise@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}

bwget(){
    local raw
    raw=$(grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1)
    if [ -z "$raw" ]; then
        raw=$(grep -oP "$2: bw=\K[0-9.]+(?=GiB/s)" "$1" | head -1)
        [ -n "$raw" ] && raw=$(awk "BEGIN {printf \"%.0f\", $raw * 1024}")
    fi
    echo "${raw:-NA}"
}

echo "===== CONTROL EXPERIMENT: slaves UNTUNED ====="
echo "date: $(date)"
echo ""

# --- seqwrite: 2 rounds ---
echo "## seqwrite (single, bs=256K, 4G, direct=1)"
mkdir -p "$SEQ_DIR"
for i in 1 2; do
    drop_all_caches
    of="$RESULT_DIR/seqwrite-r${i}.txt"
    echo "--- seqwrite r${i} ---"
    fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --bs=256K --size=4G \
        --refill_buffers --direct=1 --end_fsync=1 --group_reporting > "$of" 2>&1
    bw=$(bwget "$of" WRITE)
    echo "  seqwrite r${i}: WRITE=${bw} MiB/s"
    rm -rf "$SEQ_DIR"/*
    sleep 5
done
rm -rf "$SEQ_DIR"

# --- layout: 2 rounds ---
echo ""
echo "## layout (128 jobs x 1G, bs=4M, direct=1)"
mkdir -p "$LAYOUT_DIR"
for i in 1 2; do
    drop_all_caches
    of="$RESULT_DIR/layout-r${i}.txt"
    echo "--- layout r${i} ---"
    fio --directory="$LAYOUT_DIR" --name=storage_test --filesize=1G --size=1G --bs=4M \
        --rw=write --numjobs=128 --fallocate=none --openfiles=128 --group_reporting \
        --end_fsync=1 --direct=1 > "$of" 2>&1
    bw=$(bwget "$of" WRITE)
    echo "  layout r${i}: WRITE=${bw} MiB/s"
    rm -rf "$LAYOUT_DIR"/*
    sleep 10
done
rm -rf "$LAYOUT_DIR"

echo ""
echo "===== SUMMARY ====="
echo "v2 tuned baseline:    seqwrite=835  layout=10240"
echo "control (untuned):"
for i in 1 2; do
    sw=$(bwget "$RESULT_DIR/seqwrite-r${i}.txt" WRITE)
    lay=$(bwget "$RESULT_DIR/layout-r${i}.txt" WRITE)
    echo "  r${i}: seqwrite=${sw}  layout=${lay}"
done
echo ""
echo "DONE: $(date)"
