# ============================================================
# beegfs-health-check.sh — BeeGFS cluster health check library
# ============================================================
# Usage: source this file in test scripts, then call:
#
#   source tests/lib/beegfs-health-check.sh
#   check_beegfs_health "before seqread"
#   fio ...
#
# Behavior:
#   - Checks BeeGFS service status and cluster health
#   - If services are down or cluster unhealthy:
#     - Prints warning and current status
#     - Polls up to WAIT_SEC seconds (default 120s)
#     - Aborts test on timeout
#   - If healthy, continues normally
# ============================================================

BEEGFS_MGMTD_HOST="${BEEGFS_MGMTD_HOST:-10.20.1.157}"
BEEGFS_MOUNT_POINT="${BEEGFS_MOUNT_POINT:-/mnt/beegfs}"

check_beegfs_health() {
    local label="${1:-unknown}"
    local wait_sec=${BEEGFS_HEALTH_WAIT_SEC:-120}
    local poll_interval=15
    local elapsed=0

    # Check if mount is still active
    if ! mountpoint -q "${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        echo "  [health-check] FATAL: ${BEEGFS_MOUNT_POINT} not mounted — ${label}"
        echo "  [health-check] Attempting remount..."
        sudo systemctl restart beegfs-client 2>/dev/null || true
        sleep 5
        if ! mountpoint -q "${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
            echo "  [health-check] Remount failed. ABORTING TEST"
            exit 1
        fi
        echo "  [health-check] Remounted OK"
    fi

    # Check BeeGFS services locally
    local svc
    for svc in beegfs-meta beegfs-storage; do
        if ! sudo systemctl is-active --quiet "${svc}" 2>/dev/null; then
            echo "  [health-check] WARN: ${svc} not running — ${label}"
            echo "  [health-check] Attempting restart..."
            sudo systemctl restart "${svc}" 2>/dev/null || true
            sleep 5
            if ! sudo systemctl is-active --quiet "${svc}" 2>/dev/null; then
                echo "  [health-check] ${svc} restart failed. ABORTING TEST"
                exit 1
            fi
        fi
    done

    # Quick beegfs-checkfs (non-blocking, fast)
    local health_ok=true
    if command -v beegfs-checkfs &>/dev/null; then
        if ! timeout 30 beegfs-checkfs -c /etc/beegfs/beegfs-client.conf 2>/dev/null | grep -q "all fine"; then
            health_ok=false
        fi
    fi

    if ${health_ok}; then
        echo "  [health-check] OK — ${label}"
        return 0
    fi

    # Unhealthy — wait for recovery
    echo "  [health-check] WARN: cluster health check failed — ${label}"
    echo "  [health-check] Waiting up to ${wait_sec}s for recovery..."

    while [ "${elapsed}" -lt "${wait_sec}" ]; do
        sleep "${poll_interval}"
        elapsed=$((elapsed + poll_interval))
        if timeout 30 beegfs-checkfs -c /etc/beegfs/beegfs-client.conf 2>/dev/null | grep -q "all fine"; then
            echo "  [health-check] RECOVERED after ${elapsed}s — ${label}"
            return 0
        fi
        echo "  [health-check] still unhealthy after ${elapsed}s..."
    done

    echo "  [health-check] FATAL: still unhealthy after ${wait_sec}s — ABORTING TEST"
    exit 1
}

check_beegfs_health_quick() {
    local label="${1:-unknown}"

    if ! mountpoint -q "${BEEGFS_MOUNT_POINT}" 2>/dev/null; then
        echo "  [health-check] WARN: mount lost — ${label}"
        return 1
    fi

    for svc in beegfs-meta beegfs-storage; do
        if ! sudo systemctl is-active --quiet "${svc}" 2>/dev/null; then
            echo "  [health-check] WARN: ${svc} down — ${label}"
            return 1
        fi
    done

    echo "  [health-check] OK — ${label}"
    return 0
}
