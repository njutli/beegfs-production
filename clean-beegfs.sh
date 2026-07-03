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
# 保留: beegfs 包 + /etc/beegfs (重部署复用); 只清服务 + 数据 + mgmtd 拓扑库
# 删 mgmtd.sqlite = 集群拓扑记录全清, 重部署即全新集群
#
# 用法: bash clean-beegfs.sh          # dry-run, 只显示将执行的操作
#       bash clean-beegfs.sh --yes    # 实际执行
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

DRYRUN=1
[ "${1:-}" = "--yes" ] && DRYRUN=0

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
echo "BeeGFS 清理 (DRY_RUN=${DRYRUN})"
echo "========================================"

# ------------------------------------------------------------
# 157 (client + mgmtd + meta) — 保守清理
# ------------------------------------------------------------
echo ""
echo ">>> ${CLIENT_SERVER} (157: client+mgmtd+meta) 保守清理 — 只动 BeeGFS"
run_on "${CLIENT_SERVER}" "sudo systemctl stop beegfs-client beegfs-meta beegfs-mgmtd 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo systemctl disable beegfs-client beegfs-meta beegfs-mgmtd 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo systemctl reset-failed beegfs-client beegfs-meta beegfs-mgmtd 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo umount ${BEEGFS_MOUNT_POINT} 2>/dev/null || true"
run_on "${CLIENT_SERVER}" "sudo rm -rf ${BEEGFS_META_DIR}"              # /mnt/beegfs-meta/beegfs_meta (nvme1n1, BeeGFS 专用)
run_on "${CLIENT_SERVER}" "sudo rm -f ${BEEGFS_MGMTD_DB}*"              # /var/lib/beegfs/mgmtd.sqlite* (拓扑库, 重部署重建)
run_on "${CLIENT_SERVER}" "sudo rm -rf ${BEEGFS_MOUNT_POINT}"          # 空挂载点目录
echo "  [157 红线] 未触碰: /mnt/data01-04 /mnt/container /opt/weka /weka /var/lib/kubelet /var/lib/docker md0 K8s/docker"

# ------------------------------------------------------------
# slaves (150-152) — 彻底清理
# ------------------------------------------------------------
for ip in "${SLAVE_SERVERS[@]}"; do
    echo ""
    echo ">>> ${ip} (slave) 彻底清理"
    run_on "${ip}" "sudo systemctl stop beegfs-client beegfs-storage beegfs-meta 2>/dev/null || true"
    run_on "${ip}" "sudo systemctl disable beegfs-client beegfs-storage beegfs-meta 2>/dev/null || true"
    run_on "${ip}" "sudo systemctl reset-failed beegfs-client beegfs-storage beegfs-meta 2>/dev/null || true"
    run_on "${ip}" "sudo rm -rf ${BEEGFS_META_DIR}"                     # meta 数据
    run_on "${ip}" "sudo rm -rf ${BEEGFS_STORAGE_DIR_SLAVE_1}/* ${BEEGFS_STORAGE_DIR_SLAVE_2}/*"  # target format + 数据
    run_on "${ip}" "sudo rm -f ${BEEGFS_MGMTD_DB}* 2>/dev/null || true"
done

echo ""
echo "========================================"
if [ "${DRYRUN}" -eq 1 ]; then
    echo "DRY RUN 完成 (未实际执行)"
    echo "确认无误后执行: bash clean-beegfs.sh --yes"
else
    echo "清理完成. mgmtd 拓扑库已删 = 重部署即全新集群"
    echo "保留: beegfs 包 + /etc/beegfs (重部署复用)"
    echo "如需彻底卸载包: 各节点 sudo apt purge 'beegfs-*' 'libbeegfs-*' && sudo rm -rf /etc/beegfs"
fi
echo "========================================"
