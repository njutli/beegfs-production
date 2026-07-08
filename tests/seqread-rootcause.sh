#!/bin/bash
# 0.7 seqread R1≠R2 root cause analysis
# 5 consecutive cold seqread tests with drop_all_caches before each
# Plus a warmup-then-drop experiment

set -uo pipefail
MNT="/mnt/beegfs"
DIR="${MNT}/seqread-rootcause"
RESULT_DIR="/tmp/seqread-rc"
SLAVE_IPS="10.20.1.150 10.20.1.151 10.20.1.152"
SSH_PASS="Sunrise@801"

mkdir -p "$DIR" "$RESULT_DIR"

drop_all_caches() {
    echo -n "  [drop] client+slaves..."
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in $SLAVE_IPS; do
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "sunrise@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
    echo " OK"
}

run_seqread() {
    local label="$1"
    local of="$RESULT_DIR/${label}.txt"
    echo "--- ${label} ---"
    fio --name="${label}" --directory="$DIR" --rw=read --bs=256K --size=4G \
        --refill_buffers --direct=1 --group_reporting > "$of" 2>&1
    local bw iops
    bw=$(grep -oP "READ: bw=\K[0-9.]+(?=MiB/s)" "$of" | head -1)
    [ -z "$bw" ] && bw=$(grep -oP "READ: bw=\K[0-9.]+(?=GiB/s)" "$of" | head -1) && [ -n "$bw" ] && bw=$(awk "BEGIN {printf \"%.0f\", $bw * 1024}")
    iops=$(grep -oP "read: IOPS=\K[0-9.]+" "$of" | head -1)
    local clat
    clat=$(grep -oP "clat \(usec\): min=\K[0-9]+" "$of" | head -1)
    echo "  bw=${bw:-NA} MiB/s  IOPS=${iops:-NA}  clat_min=${clat:-NA}us"
    echo ""
}

# === Step 1: Prepare test file ===
echo "===== Preparing 4G test file (bs=256K, direct=1) ====="
fio --name=prep --directory="$DIR" --rw=write --bs=256K --size=4G \
    --refill_buffers --direct=1 --end_fsync=1 >/dev/null 2>&1
sync
echo "Prep done."
echo ""

# === Experiment 1: 5 consecutive cold seqread ===
echo "===== Experiment 1: 5 consecutive cold seqread (drop_all_caches before each) ====="
echo ""
for i in 1 2 3 4 5; do
    drop_all_caches
    run_seqread "cold-r${i}"
    sleep 3
done

# === Experiment 2: warmup-then-drop ===
echo "===== Experiment 2: warmup-then-drop ====="
echo ""
echo "--- Warmup run (warm-r1, NO drop before — but after cold-r5) ---"
run_seqread "warm-r1"
sleep 3

echo "--- Cold after warmup (cold-after-warm, drop_all_caches) ---"
drop_all_caches
run_seqread "cold-after-warm"
sleep 3

echo "--- Warm again (warm-r2, NO drop) ---"
run_seqread "warm-r2"

# === Summary ===
echo ""
echo "===== SUMMARY ====="
echo "label                bw(MiB/s)    IOPS"
echo "---------------------------------------"
for label in cold-r1 cold-r2 cold-r3 cold-r4 cold-r5 warm-r1 cold-after-warm warm-r2; do
    of="$RESULT_DIR/${label}.txt"
    bw=$(grep -oP "READ: bw=\K[0-9.]+(?=MiB/s)" "$of" | head -1)
    [ -z "$bw" ] && bw=$(grep -oP "READ: bw=\K[0-9.]+(?=GiB/s)" "$of" | head -1) && [ -n "$bw" ] && bw=$(awk "BEGIN {printf \"%.0f\", $bw * 1024}")
    iops=$(grep -oP "read: IOPS=\K[0-9.]+" "$of" | head -1)
    printf "%-20s %10s   %s\n" "$label" "${bw:-NA}" "${iops:-NA}"
done

# === Cleanup ===
rm -rf "$DIR"
echo ""
echo "===== Cleanup done ====="
