# 任务书 · 阶段1 — 单流写延迟优化（单变量矩阵）

> 执行方：GLM（新会话 / 新服务商，**无历史上下文**，本任务书自包含）
> 派发方：规划 agent
> 依据：`doc/perf-analysis/02-stage0-review-and-revised-plan.md` §七 + `results/20260708-lock-rdma-iface/`
> 注：原 01/02 分析文档已合并为 `doc/perf-analysis/01-beegfs-perf-tuning.md`（本任务书内容不变，作历史归档）。
> 日期：2026-07-08
> 优先级：P1（阶段0 与基线定案已完成，本任务是首个真正的调优阶段）

---

## 0. 背景（新会话必读，建立完整上下文）

### 0.1 这是什么项目
在一个 **4 节点 BeeGFS 7.3.2 并行文件系统集群**上做性能调优。集群与另一套 JuiceFS+Ceph 方案做对比。目标是找出瓶颈并在**不影响已有业务**的前提下提升性能。

### 0.2 集群拓扑
| 节点 | 内网 IP | 角色 | 磁盘 |
|------|---------|------|------|
| client (157) | 10.20.1.157 | mgmtd + meta + client（**同机还跑 K8s + WekaIO 业务**）| nvme1n1 ext4 → metadata |
| slave1 (150) | 10.20.1.150 | meta + 2 storage targets | nvme1n1 ext4(meta) + nvme2n1/nvme3n1 XFS(storage) |
| slave2 (151) | 10.20.1.151 | 同 slave1 | 同上 |
| slave3 (152) | 10.20.1.152 | 同 slave1 | 同上 |

- 镜像：metadata 2 buddy groups + storage 3 buddy groups；Stripe = Buddy Mirror, chunk=1M, numtargets=3。
- **数据面 = 100GbE RDMA/RoCE**（`connUseRDMA=true`，Mellanox mlx5_0/mlx5_1）。**注意：RDMA 流量不进 `/proc/net/dev`**，要看 `/sys/class/infiniband/mlx5_*/ports/*/counters/` 或 `ibstat`。
- 限速对比走独立网卡 `eno12409` + `tc tbf 1gbit`（本任务用不到）。

### 0.3 阶段0 + 基线定案已确立的事实（作为你的起点）
1. **当前单流写基线 = ~900 MiB/s（RDMA 锁定态）**，冷态 direct=1 bs=256K fsync，clat_min ~215µs、clat avg ~275µs、IOPS ~3600。这是**本任务的优化对象与对照锚点**。来源：`results/20260708-lock-rdma-iface/`（5/5 重启验证）。其余冷态不限速值（MiB/s）：seqread(单流)=1585；multi-seqwrite(16)=8214；randwrite(128)=6138；layout(128,4M)=10240。
2. **⚠️ 关键前提：数据面必须走 RDMA。** 曾发生过 `connInterfacesFile` 为空 → client 自动选接口 → 掉到 10GbE TCP 网卡（eno12409, 10.114.1.x），单流写腰斩到 ~479、clat_min 翻倍到 ~400µs。现已锁定 `connInterfacesFile = /etc/beegfs/connInterfacesFile.conf`（内容 `enp139s0f0np0`+`enp139s0f1np1`）强制走 RDMA。**每次测试前必做"RDMA 哨兵检查"（见 §2A）。**
3. **slave 端系统调优已生效并固定为基线**（THP=always、read_ahead=4096 等，见 `skills/beegfs-baseline-config.md`）。注意：**dirty_ratio 对 `--direct=1` 单流写无效**（已实证），不是有效调优项。
4. **157 保持系统默认，不调**（保护 K8s+WekaIO 业务）。

### 0.4 ⚠️ 调优安全红线（**最重要，违反会影响生产业务**）
100GbE Mellanox 网卡与 WekaIO **物理共用**（同一 RDMA verbs 设备上同时挂着 beegfs 和 wekanode 进程）。因此：

| 可以动 | 禁止动 |
|--------|--------|
| ✅ BeeGFS `.conf` 应用层参数（connRDMABuf*、tuneNumWorkers） | ❌ 网卡/驱动全局参数（MTU、mlxconfig、queue、中断亲和、PFC） |
| ✅ slave（150/151/152）内核参数（dirty_ratio 等） | ❌ 157 的任何内核参数 |
| ✅ 子目录 stripe（`--setpattern`，不动根目录） | ❌ RoCE QoS（`connRDMATypeOfService`、DSCP）——与 WekaIO 共享 |

**总原则：只改 BeeGFS 应用层 / slave 端；不动 157 内核、不动网卡/驱动/RoCE QoS。BeeGFS 是纯测试集群（业务在独立 WekaIO 上），服务可自由重启，无需等业务低峰；但重启后必须等 target 全 Online/Good 且 RDMA 哨兵通过再测。**

---

## 1. 访问方式

项目目录在 157 上：`/home/sunrise/beegfs-production`

SSH（WSL → 泰国 client 157，经公网端口）：
```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
```
157 → slave（两级跳）：
```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 '<command>'"
```
- 用户 `sunrise` / 密码 `Sunrise@801`；sudo：`echo 'Sunrise@801' | sudo -S <cmd>`
- 详见 `skills/beegfs-node-conventions.md`；测试纪律见 `skills/TESTING-GUIDE.md`；长测监控见 `skills/LONG-RUNNING-TEST-SKILL.md`；基线定义见 `skills/beegfs-baseline-config.md`。

---

## 2. 任务目标

在 **~900 MiB/s（RDMA 锁定态）** 基线之上，用**单变量对照**逐个测试下列参数对**单流 seqwrite**的影响，找出能把 ~900 继续推高的项。每个变量独立测、其余保持基线、每项 ≥2 轮看一致性、全部对账原始 fio。

**测试口径（固定）**：
```
fio --name=seqwrite --directory=/mnt/beegfs/seq_dir --rw=write --bs=256K --size=4G \
    --direct=1 --end_fsync=1                # 单流写，冷态
# 每次测前：drop_all_caches（客户端 + 3 slave 都清 page cache）
```
可用 `tests/bench-full.sh` 只取 seqwrite 项，或独立 fio。

---

## 2A. 前置：每次测试前的 RDMA 哨兵检查（**必做，防止 479 陷阱**）

单流写基线 ~900 的前提是**数据面走 RDMA**。若 client 掉到 10GbE TCP，会稳定测到 ~479 而非 ~900——这不是调优结果，是网络路径错了。**每次 drop_caches 后、跑 fio 前，先做以下检查，任一不通过就停下修复/回报，不要采数据：**

```bash
# 1. 确认 connInterfacesFile 已锁 RDMA
grep connInterfacesFile /etc/beegfs/beegfs-client.conf    # 应为 = /etc/beegfs/connInterfacesFile.conf
# 2. 确认 client→3 storage 全走 RDMA 10.3.x（不得出现 TCP / 10.114.1.x）
beegfs-net | grep -A1 "ID: 10[123]"                        # 应全为 RDMA: N (10.3.x:8003)
# 3. 快测一发确认 clat_min < 250µs（TCP 态会是 ~400µs）
```

- 若发现走了 TCP：检查 `connInterfacesFile` 配置与 `/etc/beegfs/connInterfacesFile.conf` 是否存在（内容 `enp139s0f0np0`+`enp139s0f1np1`），修好后重启 client 再验。
- 每轮结果里记录当轮的 `beegfs-net` 连接类型与 clat_min，作为"数据在 RDMA 态采集"的证据。

---

## 3. 单变量矩阵（逐项执行，每项测完记录增量再进下一项）

> 每项：改参数 → 确认只改了目标变量 → **RDMA 哨兵检查（§2A）** → drop_all_caches → 跑 seqwrite ≥2 轮 → 记录 → **改回基线** → 下一项。

### 3.1 变量 A：~~slave 端 dirty_ratio 精调~~ **【取消】**
dirty_ratio 对 `--direct=1` 单流写无效（已实证 dirty=10 vs 20：512 vs 503，噪音范围）。**本变量取消，直接从变量 B 开始。**

### 3.2 变量 B：connRDMABufNum / connRDMABufSize（BeeGFS 应用层，需重启服务）
- 当前基线：`connRDMABufNum=70`、`connRDMABufSize=8192`（在 `/etc/beegfs/beegfs-client.conf` 和 `beegfs-meta.conf`）。
- 测试值（单变量，先动 BufNum 再动 BufSize）：BufNum = 70 / 128 / 256；BufSize = 8192 / 16384 / 32768。
- **内存核算**：RAM = BufSize×BufNum×2 per connection，改前估算总占用，别把 157/slave 内存吃爆。
- 改法：编辑对应 `.conf` → **重启 BeeGFS 服务**（`sudo systemctl restart beegfs-meta beegfs-storage beegfs-client`，client 重启需重编译内核模块，可能 60-120s，别误判卡死）。
- ⚠️ 重启后**必做 RDMA 哨兵检查（§2A）**——重启是 TCP fallback 最可能发生的时机。只改 BeeGFS `.conf`，**不动网卡**。
- 测完**改回基线值并重启恢复**。

### 3.3 变量 C：tuneNumWorkers（storage / meta 工作线程，需重启对应服务）
- 在 `beegfs-storage.conf` / `beegfs-meta.conf`，默认值查当前 conf。
- 测试值：默认 / 2× / 4×。观察单流写是否受服务端线程调度影响。
- 改后重启对应服务（重启后做 RDMA 哨兵检查）。

### 3.4 变量 D：chunksize（子目录 setpattern，不动根目录，无需重启）
- 建测试子目录，对该子目录设不同 chunk：
  ```bash
  sudo beegfs-ctl --setpattern --pattern=buddymirror --numtargets=3 --chunksize=512k /mnt/beegfs/cs_test_512k
  ```
- 测试值：512K / 1M(基线) / 2M / 4M。在各子目录跑 seqwrite。
- **不改根目录 stripe**，测完删子目录即可。

### 3.5 变量 E：fsync vs 非 fsync 对照
- 同口径跑 `--end_fsync=1` vs 去掉，拆分"后端落盘确认瓶颈"与"客户端聚合瓶颈"。
- 纯诊断项，帮助判断 3.1-3.4 的收益来自哪一环。

---

## 4. 结果留存

- 结果落 `results/20260708-stage1-single-write/`（或按日期），每个变量一个子目录，保留：原始 fio 输出、`commands.sh`、env 快照、每轮值、**当轮 beegfs-net 连接类型（RDMA 证据）**。
- 产出一份 `README.md` 汇总表：变量 | 测试值 | seqwrite 各轮 | vs 基线~900 增量 | 走 RDMA? | 是否重启服务 | 结论。
- **每个结论数对账原始 fio 的 `WRITE: bw=` 和 `clat` 行**（不要只写 summary 转写的数）。

---

## 5. 验收标准

- [ ] **每轮测试前 RDMA 哨兵检查通过（走 RDMA 10.3.x、clat_min<250µs），并留证据**
- [ ] 变量 B/C/D/E 各自完成 ≥2 轮、单变量、对账 raw（变量 A 已取消）
- [ ] 找出对单流 seqwrite 有正收益的变量并量化增量（vs ~900 基线）；无收益的明确排除
- [ ] 全程未改动：157 内核参数、网卡/驱动/RoCE QoS、根目录 stripe、connInterfacesFile（安全红线）
- [ ] 每次重启后 RDMA 哨兵通过、target 全 Good 再测；测后参数恢复基线
- [ ] 汇总 README 产出，数值可追溯到原始 fio

---

## 6. 交付与提交规范

1. **脚本/文档改动，提交推送前必须先向用户展示 diff 并获确认**（`skills/doc-publish-rule.md`），不得私自 `git commit`/`git push`。
2. 完成后回传汇总 README 给规划 agent，用于据此判断是否进入阶段2（写天花板与镜像开销量化）。
3. 若过程中发现新的可信度问题或与基线冲突的数据，先停下报告，不要在污染数据上继续。

---

## 7. 快速自检清单（GLM 每次改参数前问自己）
- 这个参数属于"可以动"那一列吗？（BeeGFS 应用层 / slave 内核 / 子目录 stripe）
- 我是不是只改了一个变量？其余是否仍是基线？
- **我做 RDMA 哨兵检查了吗？beegfs-net 是不是全 RDMA 10.3.x、clat_min<250µs？**（否则测到的是 479 TCP 态，无效）
- 需要重启 BeeGFS 服务吗？重启后 target 全 Good 且 RDMA 哨兵通过了吗？（纯测试集群，重启无需低峰，但要等就绪）
- 测完我会把它改回基线吗？
- 我的结论数能对上原始 fio 的 `WRITE: bw=` 行吗？
