#!/bin/bash
set -euo pipefail

# ============================================================
# clean-beegfs.sh — 把集群恢复到未部署 BeeGFS 的干净状态
#
# 157 (client + mgmtd + meta): 保守清理, 只动 BeeGFS 路径, 绝不碰业务
#   红线 (不触碰): /mnt/data01-04 /mnt/container /opt/weka /weka
#                  /var/lib/kubelet /var/lib/docker md0 K8s/docker 服务
# slaves (150-152): 彻底清理 (无业务)
#
# 保留: beegfs 包 + /etc/beegfs (重部署复用); 只清服务 + 数据 + mgmtd 目录
# 删 mgmtd 目录 = 集群拓扑记录全清, 重部署即全新集群
#
# 用法: bash clean-beegfs.sh              # dry-run, 只显示将执行的操作
#       bash clean-beegfs.sh --yes        # 实际执行
#       bash clean-beegfs.sh --yes --purge # 执行 + 卸载包 (用于版本切换)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

DRYRUN=1
PURGE=0
for arg in "$@"; do
    [ "$arg" = "--yes" ] && DRYRUN=0
    [ "$arg" = "--purge" ] && PURGE=1
done

# 在指定节点执行命令 (dry-run 时只打印)
run_on() {
    local ip=$1 cmd=$2
    if [ "${DRYRUN}" -eq 1 ]; then
        echo "  [DRY] ${ip}> ${cmd}"
    else
        if [ "${ip}" = "${CLIENT_SERVER}" ]; then
            ssh_to_client "${cmd}"
        else
            ssh_to_slave "${ip}" "${cmd}"
        fi
    fi
}

echo "========================================"
echo "BeeGFS 清理 (DRY_RUN=${DRYRUN}, PURGE=${PURGE})"
echo "========================================"

# ------------------------------------------------------------
# 157 (client + mgmtd + meta) — 保守清理
# ------------------------------------------------------------
echo ""
echo ">>> ${CLIENT_SERVER} (157: client+mgmtd+meta) 保守清理 — 只动 BeeGFS"
# 按依赖顺序逐服务停止: client → helperd → meta → mgmtd (mgmtd 最后, 其他服务依赖它)
# 每服务 timeout 30s, 超时后重试一次, 再超时则退出让人排查
run_on "${CLIENT_SERVER}" "
for svc in beegfs-client beegfs-helperd beegfs-meta beegfs-mgmtd; do
    echo \"  [157] stopping \$svc (attempt 1)...\"
    sudo timeout 30 systemctl stop \"\$svc\" 2>/dev/null || true
    if sudo systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
        echo \"  [157] \$svc still active, retry (attempt 2)...\"
        sleep 5
        sudo timeout 30 systemctl stop \"\$svc\" 2>/dev/null || true
        if sudo systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
            echo \"  [157] ERROR: \$svc still active after 2 attempts. Check: sudo journalctl -u \$svc --no-pager -n 30\"
            echo \"  [157] Aborting — resolve the issue manually before re-running.\"
            exit 1
        fi
    fi
    echo \"  [157] \$svc: stopped\"
done
"
run_on "${CLIENT_SERVER}" "sudo systemctl disable beegfs-client beegfs-helperd beegfs-meta beegfs-mgmtd 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo systemctl reset-failed beegfs-client beegfs-helperd beegfs-meta beegfs-mgmtd 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo umount ${BEEGFS_MOUNT_POINT} 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo rm -rf ${BEEGFS_META_DIR}"              # /mnt/beegfs-meta/beegfs_meta (nvme1n1, BeeGFS 专用)
run_on "${CLIENT_SERVER}" "sudo rm -rf ${BEEGFS_MGMTD_DB}/*"            # /var/lib/beegfs/mgmtd/* (拓扑数据, 重部署重建)
run_on "${CLIENT_SERVER}" "sudo rm -rf ${BEEGFS_MOUNT_POINT}"          # 空挂载点目录
echo "  [157 红线] 未触碰: /mnt/data01-04 /mnt/container /opt/weka /weka /var/lib/kubelet /var/lib/docker md0 K8s/docker"

# ------------------------------------------------------------
# slaves (150-152) — 彻底清理
# ------------------------------------------------------------
for ip in "${SLAVE_SERVERS[@]}"; do
    echo ""
    echo ">>> ${ip} (slave) 彻底清理"
    # 按依赖顺序: storage → meta (meta 依赖 mgmtd, 157 的 mgmtd 已先停)
    run_on "${ip}" "
for svc in beegfs-storage beegfs-meta; do
    echo \"  [${ip}] stopping \$svc (attempt 1)...\"
    sudo timeout 30 systemctl stop \"\$svc\" 2>/dev/null || true
    if sudo systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
        echo \"  [${ip}] \$svc still active, retry (attempt 2)...\"
        sleep 5
        sudo timeout 30 systemctl stop \"\$svc\" 2>/dev/null || true
        if sudo systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
            echo \"  [${ip}] ERROR: \$svc still active after 2 attempts. Check: sudo journalctl -u \$svc --no-pager -n 30\"
            echo \"  [${ip}] Aborting — resolve the issue manually before re-running.\"
            exit 1
        fi
    fi
    echo \"  [${ip}] \$svc: stopped\"
done
"
    run_on "${ip}" "sudo systemctl disable beegfs-storage beegfs-meta 2>/dev/null || true"
    run_on "${ip}" "sudo systemctl reset-failed beegfs-storage beegfs-meta 2>/dev/null || true"
    run_on "${ip}" "sudo rm -rf ${BEEGFS_META_DIR}"                     # meta 数据 (整个目录删除)
    run_on "${ip}" "sudo bash -c 'find ${BEEGFS_STORAGE_DIR_SLAVE_1} -mindepth 1 -delete; find ${BEEGFS_STORAGE_DIR_SLAVE_2} -mindepth 1 -delete'"  # target format + 数据 (含隐藏文件, 700权限需root glob)
    run_on "${ip}" "sudo rm -rf ${BEEGFS_MGMTD_DB}/* 2>/dev/null || true"
done

# ------------------------------------------------------------
# --purge: 卸载所有 beegfs 包 + 删 /etc/beegfs (用于版本切换)
# ------------------------------------------------------------
if [ "${PURGE}" -eq 1 ]; then
    echo ""
    echo ">>> --purge: 卸载所有 BeeGFS 包 + 删除 /etc/beegfs"
    for ip in "${ALL_SERVERS[@]}"; do
        run_on "${ip}" "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y 'beegfs-*' 'libbeegfs-*' 2>/dev/null || true"
        run_on "${ip}" "sudo rm -rf /etc/beegfs"
        run_on "${ip}" "sudo rm -f ${BEEGFS_REPO_LIST}"
    done
fi

echo ""
echo "========================================"
if [ "${DRYRUN}" -eq 1 ]; then
    echo "DRY RUN 完成 (未实际执行)"
    echo "确认无误后执行: bash clean-beegfs.sh --yes"
    [ "${PURGE}" -eq 1 ] && echo "  (含 --purge: 卸载包)"
else
    echo "清理完成. mgmtd 目录已清 = 重部署即全新集群"
    if [ "${PURGE}" -eq 1 ]; then
        echo "包已卸载, /etc/beegfs 已删, 仓库已删 — 可安装新版本"
    else
        echo "保留: beegfs 包 + /etc/beegfs (重部署复用)"
        echo "如需彻底卸载包: bash clean-beegfs.sh --yes --purge"
    fi
fi
echo "========================================"
