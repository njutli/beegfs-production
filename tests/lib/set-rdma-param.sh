#!/bin/bash
# ============================================================
# set-rdma-param.sh — 在当前节点设置 BeeGFS RDMA 参数
# 用法: set-rdma-param.sh <param> <value> <conf_file>...
# 例如: set-rdma-param.sh connRDMABufNum 128 beegfs-client.conf beegfs-meta.conf
#
# 若 conf 中已有该 param（非注释行）→ sed 替换
# 若无 → 追加到 conf 末尾
# ============================================================
set -uo pipefail

PARAM="$1"
VAL="$2"
shift 2
PW="${SUDO_PW:-Sunrise@801}"

for conf in "$@"; do
    file="/etc/beegfs/${conf}"
    if [ ! -f "$file" ]; then
        echo "  SKIP: ${conf} not found on $(hostname)"
        continue
    fi
    if grep -q "^${PARAM}[[:space:]]*=" "$file" 2>/dev/null; then
        echo "${PW}" | sudo -S sed -i "s|^${PARAM}.*|${PARAM} = ${VAL}|" "$file" 2>/dev/null
    else
        echo "${PW}" | sudo -S bash -c "echo '${PARAM} = ${VAL}' >> '${file}'" 2>/dev/null
    fi
    cur=$(grep "^${PARAM}" "$file" 2>/dev/null | head -1)
    echo "  $(hostname) ${conf}: ${cur}"
done
