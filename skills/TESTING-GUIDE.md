# BeeGFS 性能测试指导 Skill

> 目的：保证测试数据可靠、可追溯、可复现。
> 创建：2026-06-29
> 背景：BeeGFS 集群部署后的性能调优，需确保测试方法论正确。

---

## 一、测试前检查清单

### 1.1 集群健康检查（必须）

每次启动测试脚本前，手动确认：

```bash
# 所有服务必须 active (157 上同时运行 mgmtd+meta+helperd+client)
sudo systemctl status beegfs-mgmtd beegfs-meta beegfs-storage beegfs-client --no-pager

# 7.x beegfs-ctl 读 /etc/beegfs/beegfs-client.conf (sysMgmtdHost + connDisableAuthentication)
# 无需环境变量, 直接执行

# 节点在线
sudo beegfs-ctl --listnodes

# Storage targets 全部在线 (状态 GOOD)
sudo beegfs-ctl --listtargets --state

# Buddy groups (镜像)
sudo beegfs-ctl --listmirrorgroups --nodetype=meta
sudo beegfs-ctl --listmirrorgroups --nodetype=storage

# 容量
sudo beegfs-df
```

如果有服务非 active 或 target 离线，**不要开始测试**。先修复问题。

### 1.2 磁盘空间检查

```bash
df -h /data              # 确认有足够空间（layout 需要 128G+）
df -h /mnt/beegfs        # 客户端挂载点
```

### 1.3 网络检查

```bash
cat /sys/class/net/eno12399/mtu   # 确认 MTU
ip link show eno12399             # 确认链路状态 up

# 确认所有节点互通
for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    ping -c 2 "$ip"
done
```

### 1.4 fio 残留检查

```bash
pgrep -x fio && echo "WARNING: fio still running" || echo "OK: no fio"
```

---

## 二、测试中的健康检查（自动）

### 2.1 健康检查库

所有测试脚本 **必须** source 健康检查库：

```bash
source tests/lib/beegfs-health-check.sh
```

### 2.2 检查点位置

| 检查点 | 位置 | 说明 |
|--------|------|------|
| 测试开始前 | 环境快照之后 | 确认初始状态 OK |
| 每个 fio 命令前 | run_seq/run_rand 函数内 | 防止集群异常时继续跑 |
| layout 写完后 | layout 完成后 | 检查写后状态 |
| 测试结束后 | 收尾前 | 记录终态 |

### 2.3 检查行为

- `check_beegfs_health`：服务非 active 时等待最多 120s，超时则 **abort 整个测试**
- `check_beegfs_health_quick`：只检查不等待，用于快速状态记录

---

## 三、Layout 后的 Cooldown

### 3.1 问题

128G layout 写入会产生大量元数据更新和 chunk 分配。

### 3.2 规避方法

layout 写完后，**不要立即开始随机测试**，等待系统稳定：

```bash
log "## Layout cooldown: 等待 60s"
sleep 60
check_beegfs_health "after layout cooldown"
```

---

## 四、测试口径规范

### 4.1 冷态基线

- `--direct=1`（绕过页缓存）
- 每项跑前 `echo 3 > /proc/sys/vm/drop_caches`
- 随机项 3 轮取均值
- 用于瓶颈定位和基线

### 4.2 暖态基线

- 不 drop caches
- 不加 `--direct=1`（buffered I/O）
- 顺序项各 1 次；随机项 3 轮看收敛趋势
- 代表重复访问场景上限

### 4.3 数据记录要求

每项 fio 测试必须保存：
- fio 完整原始输出
- 挂载参数（BeeGFS stripe pattern）
- 日期时间
- 集群状态（节点数、target 数）

---

## 五、测试中遇到的问题及处理方法

### 5.1 BeeGFS 服务 down

**现象**：`systemctl status` 显示 inactive/failed

**处理**：
```bash
sudo systemctl restart beegfs-meta beegfs-storage
sleep 5
sudo systemctl status beegfs-meta beegfs-storage
```

### 5.2 Client mount 失败

**现象**：mountpoint 检查失败

**处理**：
```bash
sudo systemctl restart beegfs-client
sleep 5
mountpoint -q /mnt/beegfs && echo "OK" || echo "FAILED"
```

### 5.3 fio 进程残留

**现象**：fio 进程未正常退出

**处理**：
```bash
sudo kill -9 $(pgrep -x fio)
sleep 2
# 确认无残留后再启动下一个 fio
pgrep -x fio || echo "clean"
```

### 5.4 磁盘空间不足

**现象**：layout 或随机测试写入失败

**处理**：
```bash
# 清理测试数据
rm -rf /mnt/beegfs/test_dir /mnt/beegfs/seq_dir
# 检查空间
df -h /data
```

### 5.5 干净重启顺序（helperd 必须先于 client）

**现象**：手动/干净重启后 client mount 报 "Operation canceled"，反复 failed。

**根因**：client 经 beegfs-helperd 做日志/解析（`logType=helperd`），helperd 未起时 client 无法 mount。

**处理**：按顺序启动，helperd 在 client 之前：
```bash
# 顺序：mgmtd → meta → storage → helperd → client
sudo systemctl start beegfs-mgmtd; sleep 3
sudo systemctl start beegfs-meta beegfs-storage; sleep 5
sudo systemctl start beegfs-helperd; sleep 2   # 必须先于 client
sudo systemctl start beegfs-client
```
（来源：`results/20260709-stage2-unmet-rootcause/` §8.2）

### 5.6 不完整重启导致镜像复制路由失真

**现象**：切限速口径（eno12409 TCP）后单流 seqwrite 明显偏高（如 96.8 而非预期 ~53），数据失真。

**根因**：`mgmtd force-kill` 造成不完整重启时，storage 间镜像复制残留旧连接，未走 eno12409。

**处理**：干净重启（`pkill beegfs` → mgmtd → meta+storage → helperd → client）后复制正确走 eno12409，seqwrite 回到 53.0（匹配历史）。切换网络口径后务必确认复制路径正确再采数据。
（来源：`results/20260709-stage2-unmet-rootcause/` §8.3）

### 5.7 pkill 自杀陷阱

**现象**：`pkill -f beegfs` 意外杀掉正在执行的 shell。

**根因**：`-f` 匹配整条命令行，会命中命令行含 "beegfs" 的 shell 自身。

**处理**：用 `pkill beegfs`（匹配进程名，不含 `-f`）。

### 5.8 getentryinfo 语法

**现象**：`beegfs-ctl --getentryinfo --entry=<path>` 报 "Stat failed"。

**根因**：`--getentryinfo` 用**位置参数**，非 `--entry=`。

**处理**：
```bash
beegfs-ctl --getentryinfo <path>     # 正确（位置参数）
```
（注：`bench-full.sh` env-snapshot 有同一 bug，待修复。）

---

## 六、测试结果可靠性判断标准

| 条件 | 判定 |
|------|------|
| 所有 BeeGFS 服务全程 active | 数据可靠 |
| 服务中途 down 但自动恢复 | 该项标记为 "recovered"，仅供参考 |
| 服务中途 down 且超时 abort | 数据不可靠，需要重测 |
| fio 结果明显偏低 | 检查集群状态，重测 |
| 暖态 3 轮不收敛（变化 >10%） | 说明环境不稳定，需要排查 |
| 冷态 r2/r3 比 r1 明显高 | 可能有缓存预热效应，只认 r1 |

---

## 七、测试命令记录规范（必须遵守）

### 7.1 要求

每个测试结果目录 **必须** 包含一个 `commands.sh` 文件，记录：

1. 所有 fio 测试的完整命令（含所有参数）
2. 环境特殊操作（如 drop_caches）
3. 日期和测试标签

### 7.2 格式

```bash
#!/bin/bash
# 完整命令记录：<测试名称>
# 日期：<日期>

# ---- 顺序测试 ----
fio --name=seqread ...

# ---- 随机测试 ----
fio --name=randread ...
```

---

## 八、文件命名规范

### 8.1 summary 文件

测试结果摘要文件使用 `summary.md`。

### 8.2 完整文件列表

每个测试结果目录应包含：

| 文件 | 说明 |
|------|------|
| `summary.md` | 测试结果摘要（Markdown） |
| `commands.sh` | 所有完整命令记录 |
| `env-snapshot.txt` | 环境快照 |
| `layout.txt` | 布局阶段输出 |
| `seqread.txt` / `seqwrite.txt` | 顺序测试原始输出 |
| `randread-r1.txt` ... | 随机测试各轮输出 |
| `status-after.txt` | 测试后集群状态 |

---

## 九、生产环境部署建议

1. BeeGFS metadata 和 storage 分离到不同物理设备（metadata 用 nvme1n1）
2. 数据通信走 10GbE 管理网 (eno12399)；100GbE 接口不用于 BeeGFS
3. 启用 metadata + storage buddy 镜像，跨节点冗余（任一节点宕机数据可访问）
4. stripe pattern = buddymirror, --numtargets = buddy group 数 (3)
5. 监控：服务状态 / target 在线 / 容量 / 网络带宽
