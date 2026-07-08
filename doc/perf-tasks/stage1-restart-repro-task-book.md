# 任务书 · 阶段1-前置 — BeeGFS 服务重启对单流写性能的可复现性实验（多次重启 + 快照对照）

> 执行方：GLM（新会话 / 新服务商，**无历史上下文**，本任务书自包含）
> 派发方：规划 agent
> 依据：`results/20260707-stage1-baseline-recheck/README.md`（复测结论）
> 日期：2026-07-07
> 优先级：P0（阻塞 stage1 全部调优，必须先解决基线是否可信的问题）

---

## 0. 背景（新会话必读，建立完整上下文）

### 0.1 这是什么项目
在一个 **4 节点 BeeGFS 7.3.2 并行文件系统集群**上做性能调优与基线复核。**重要：该 BeeGFS 集群是纯测试集群，不承载任何生产业务**（生产业务跑在同机的 WekaIO 上，与 BeeGFS 无关）。因此 **BeeGFS 服务可以自由多次重启，无需等业务低峰窗口。**

### 0.2 集群拓扑
| 节点 | 内网 IP | 角色 | 磁盘 |
|------|---------|------|------|
| client (157) | 10.20.1.157 | mgmtd + meta + client（同机跑 K8s + WekaIO 业务，但业务与 BeeGFS 独立）| nvme1n1 ext4 → metadata |
| slave1 (150) | 10.20.1.150 | meta + 2 storage targets | nvme1n1 ext4(meta) + nvme2n1/nvme3n1 XFS(storage) |
| slave2 (151) | 10.20.1.151 | meta + 2 storage targets | 同上 |
| slave3 (152) | 10.20.1.152 | meta + 2 storage targets | 同上 |

- 镜像：metadata 2 buddy groups + storage 3 buddy groups；Stripe = Buddy Mirror, chunk=1M, numtargets=3。
- **数据面 = 100GbE RDMA/RoCE**（`connUseRDMA=true`，Mellanox mlx5_0/mlx5_1）。**RDMA 流量不进 `/proc/net/dev`**，要看 `/sys/class/infiniband/mlx5_*/ports/*/counters/` 或 `ibstat`。

### 0.3 为什么要做这个实验（核心问题）

先前建立的 v2 健康基线里，**单流 seqwrite = 835 MiB/s（clat 263µs, clat min 200µs）**，并被当作 stage1 调优的锚点与"slave 调优 +78%"结论的依据。

但 2026-07-07 的独立复测（`results/20260707-stage1-baseline-recheck/`）发现：

| 测量时刻 | 事件 | seqwrite | clat min |
|------|------|:---:|:---:|
| 07-06 18:44 | v2 基线测试 | **835** | 200µs |
| **07-06 20:23** | **BeeGFS 服务重启** | - | - |
| 07-07 11:47 | 对照实验 untuned | 466/469 | ~400µs |
| 07-07 12:48/13:01 | 复测 R1/R2 | 479/479 | 400µs |
| 07-07 14:05 | 规划 agent 空闲态实测（WekaIO RDMA 流量=0） | 508 | 403µs |

关键事实：
1. **v2=835 是 07-06 20:23 服务重启之前的唯一一次测量**，之后所有测量（多个不同时刻、含 WekaIO 业务空闲时）都稳定在 466-512，clat min 稳定翻倍到 400µs。
2. 已排除：slave 参数漂移、RDMA 降速/错误、slave NVMe 变慢、CPU 绑核、dirty_ratio（对 direct=1 无效）、**WekaIO 业务争抢（空闲态实测仍 508）**。
3. **未解决**：为什么重启前能 835（200µs），重启后稳定掉到 ~490（400µs）。835 目前是 **n=1、无当时快照、事后不可复现** 的孤例。

### 0.4 本实验要回答什么
用**多次"重启 → 立即测 → 采全套快照"**的循环，把"835 是否可复现"从一次性事件变成有统计意义的结论，并**每次都采集重启前后的完整状态快照**，以便在任何一次跳回高值时能立刻拿到两态对照来定位差异。

三种可能结论（实验设计保证一定收敛到其一）：
- **A. 从不复现 835**：所有重启后测量都在 ~490 → 835 判定为不可复现异常值，作废；**~490 是真实基线**，stage1 在 490 上推进。
- **B. 每次重启后都短暂回高、随运行时间衰减**：说明是"服务运行时长 / RDMA 连接老化 / 内存碎片"效应 → 定位到具体机制，可能需要"每次测前重启"作为基线方法。
- **C. 偶发回高（非每次）**：835 是低概率状态 → 记录复现条件，仍以 ~490 为可靠基线。

---

## 1. 访问方式

项目目录在 157 上：`/home/sunrise/beegfs-production`

SSH（→ 泰国 client 157，经公网端口）：
```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
```
157 → slave（两级跳）：
```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 '<command>'"
```
- 用户 `sunrise` / 密码 `Sunrise@801`；sudo：`echo 'Sunrise@801' | sudo -S <cmd>`
- 详见 `skills/beegfs-node-conventions.md`、`skills/TESTING-GUIDE.md`、`skills/beegfs-baseline-config.md`。

---

## 2. 安全红线（务必遵守）

BeeGFS 服务本身可自由重启（纯测试集群）。但物理网卡与 WekaIO **共用同一 RDMA verbs 设备**，所以：

| 可以做 | 禁止做 |
|--------|--------|
| ✅ 重启 BeeGFS 服务（mgmtd/meta/storage/client），任意次数 | ❌ 动网卡/驱动全局参数（MTU、mlxconfig、queue、中断亲和、PFC） |
| ✅ 读取任何状态/计数器（只读快照） | ❌ 动 157 的任何内核参数 |
| ✅ 在 slave（150/151/152）改内核参数（本实验不需要） | ❌ 动 RoCE QoS（`connRDMATypeOfService`、DSCP）——与 WekaIO 共享 |
| | ❌ 修改任何 BeeGFS `.conf`（本实验保持基线配置不变，只重启不改参数） |

**本实验不改任何配置参数，只做"重启 + 测 + 采快照"。保持当前基线配置全程不变，这是单变量前提。**

---

## 3. 实验步骤

### 3.1 测试口径（固定，全程一致）

```bash
# 单流写，冷态 direct=1
D=/mnt/beegfs/seq_restart_test
mkdir -p $D
fio --name=seqwrite --directory=$D --rw=write --bs=256K --size=4G \
    --direct=1 --end_fsync=1 --group_reporting
rm -rf $D
```
- 每次 fio 前：drop caches（**客户端 157 + 3 个 slave 全部** `sync; echo 3 > /proc/sys/vm/drop_caches`）。
- 记录：`WRITE: bw=`、`write: IOPS=`、`clat (usec): min/avg/max`、`run=`。

### 3.2 快照采集脚本（重启前、重启后各跑一次）

对每一轮，在 **fio 测试的同时或紧邻** 采集下列全套快照（**这是本实验最重要的产出，v2 当时缺的就是这个**）。建议写成一个脚本 `tests/restart-repro-snapshot.sh <label>`，采集：

**157（客户端）侧：**
- `date`、`uptime`（load）、`free -g`
- 数据面 RDMA 速率：连续两次读 `/sys/class/infiniband/mlx5_1/ports/1/counters/{port_rcv_data,port_xmit_data}` 间隔 5s 算增量（判断 WekaIO 当时是否在跑）→ 记 MiB/s
- `ibstat` 两端口 state/rate
- RDMA 错误计数：`port_xmit_discards`、`port_xmit_wait`、`port_rcv_errors`
- BeeGFS client 连接状态：`beegfs-net`（列出到各 storage/meta 的连接类型与数量，确认走 RDMA）
- BeeGFS 服务运行时长：`systemctl show beegfs-* -p ActiveEnterTimestamp`（记录服务已运行多久）

**每个 slave（150/151/152）侧：**
- `uptime`、`free -g`
- storage 服务运行时长：`systemctl show beegfs-storage beegfs-meta -p ActiveEnterTimestamp`
- `beegfs-net`（storage 侧看到的连接）
- NVMe 延迟基线：`iostat -x 1 2` 取 nvme2n1/nvme3n1 的 `w_await`
- storage 服务 worker/连接：`cat /proc/<beegfs-storage-pid>/status` 里 `Threads`；`beegfs-ctl --serverstats`（若可用）
- 内存碎片指标：`cat /proc/buddyinfo`、`grep -E 'AnonHugePages|HugePages' /proc/meminfo`

> 目的：如果某次重启后 seqwrite 跳回 ~835，我们就能 diff "835 态快照" vs "490 态快照"，定位到底是连接数、worker、内存碎片、服务运行时长还是别的。

### 3.3 主循环（≥8 次重启迭代）

对 `i = 1..8`（至少 8 次，越多统计越可靠）：

```
1. 采快照（label=iter{i}-before-restart），并测一次 seqwrite（记 bw_before）
2. 重启 BeeGFS 全部服务：
   - 3 个 slave：sudo systemctl restart beegfs-storage beegfs-meta
   - 157：sudo systemctl restart beegfs-meta beegfs-mgmtd；重挂 client（beegfs-client）
   - 等待所有 target 回到 Online/Good（beegfs-ctl --listtargets --state --nodetype=storage/meta，7.x 不带 --mgmtd_node），轮询直到全 GOOD 或超时 120s
3. 立即采快照（label=iter{i}-after-restart），并立即测一次 seqwrite（记 bw_after_t0）
4. 等待 10 分钟（让服务"变旧"），再测一次 seqwrite（记 bw_after_t10）
5. 记录本轮三元组：(bw_before, bw_after_t0, bw_after_t10) 及对应 clat min
```

> 重启顺序建议：先重启 slave 的 storage+meta，等其就绪，再重启 157 的 meta+mgmtd，最后重挂 client。若不确定顺序，按 `README.md` / `config.sh` 里的启动顺序来。**每次重启方式必须一致**（这是单变量前提，重启方式本身不能变）。

### 3.4 关键判读

- 若某轮 `bw_after_t0` ≈ 835（clat min ≈ 200µs）→ **命中！** 立刻保全该轮 before/after 两套快照，重点 diff：
  - 服务运行时长（after 必然是刚重启=0）
  - beegfs-net 连接数/类型是否不同
  - buddyinfo 内存碎片是否不同
  - worker 线程数是否不同
- 观察 `bw_after_t0` vs `bw_after_t10`：若 t0 高、t10 衰减 → 支持"运行时长/连接老化"假说（结论 B）。
- 若 8 轮 `bw_after_t0` 全部在 460-520 → 支持"835 不可复现"（结论 A）。

---

## 4. 交付物

结果落 `results/20260707-restart-repro/`，包含：

1. `README.md` 汇总，含核心结果表：

   | 轮次 | bw_before | bw_after_t0 | bw_after_t10 | clat_min_after_t0 | 是否命中~835 |
   |------|:---:|:---:|:---:|:---:|:---:|
   | 1 | ... | ... | ... | ... | 否 |
   | ... | | | | | |

2. 每轮 before/after 的完整快照文件（`iter{i}-{before,after}-snapshot.txt`）。
3. 所有 seqwrite 原始 fio 输出。
4. **明确的结论判定（A / B / C）**，并回答：
   - 835 是否可复现？复现概率（命中次数/总轮次）？
   - 若复现，835 态 vs 490 态的快照差异是什么（尽量定位到具体机制）？
   - **给规划 agent 的建议**：stage1 应以哪个数为基线（835 还是 ~490）？是否需要把"每次测前重启服务"写进基线方法？

---

## 5. 验收标准

- [ ] ≥8 轮"重启→立即测→10分钟后再测"循环完成，每轮 before/after 全套快照齐全
- [ ] 每次重启方式一致、配置参数全程未变（单变量）
- [ ] 全部 seqwrite 对账原始 fio（bw / clat min）
- [ ] 若命中 835，保全该轮两态快照并给出差异分析
- [ ] 产出明确的 A/B/C 结论与基线建议

---

## 6. 注意事项

- **不要修改任何配置参数**，只重启。任何参数变更都会破坏单变量前提。
- 重启后务必等所有 target 回 Online/Good 再测，否则测到降级态数据无效。
- 每次测前 drop cache（客户端 + 3 slave），保证冷态口径。
- WekaIO 业务与 BeeGFS 独立，但仍**顺带在快照里记录数据面 RDMA 速率**，用于旁证"业务负载不是变量"（已在空闲态验证过一次，多轮采集进一步确认）。
- 遇到异常（target 起不来、client 挂不上）先停下来采集现场、回报规划 agent，不要强行继续。
