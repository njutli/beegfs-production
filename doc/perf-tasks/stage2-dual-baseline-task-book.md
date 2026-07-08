# 任务书 · 阶段2 — 双口径基线重测（100GbE RDMA + 千兆限速，统一 50% 线速考核）

> 执行方：GLM（新会话 / 新服务商，**无历史上下文**，本任务书自包含）
> 派发方：规划 agent
> 依据：`doc/perf-analysis/01-beegfs-perf-tuning.md` §二/§三 + `results/20260708-stage1-single-write/`（stage1 单流写收官）
> 日期：2026-07-08
> 优先级：P1（stage1 单流写应用层调优已穷举无收益，转入统一口径基线建设）

---

## 0. 背景（新会话必读，建立完整上下文）

### 0.1 这是什么项目
在一个 **4 节点 BeeGFS 7.3.2 并行文件系统集群**上做性能调优，与另一套 JuiceFS+Ceph 方案做对比。目标是找出瓶颈并在**不影响已有业务**前提下提升性能。

### 0.2 集群拓扑
| 节点 | 内网 IP | 角色 | 磁盘 |
|------|---------|------|------|
| client (157) | 10.20.1.157 | mgmtd + meta + client（**同机还跑 K8s + WekaIO 业务**）| nvme1n1 ext4 → metadata |
| slave1 (150) | 10.20.1.150 | meta + 2 storage targets | nvme1n1 ext4(meta) + nvme2n1/nvme3n1 XFS(storage) |
| slave2 (151) | 10.20.1.151 | 同 slave1 | 同上 |
| slave3 (152) | 10.20.1.152 | 同 slave1 | 同上 |

- 镜像：metadata 2 buddy groups + storage 3 buddy groups；Stripe = Buddy Mirror, chunk=1M, numtargets=3。
- **数据面 = 100GbE RDMA/RoCE**（`connUseRDMA=true`，Mellanox mlx5_0/mlx5_1）。RDMA 流量不进 `/proc/net/dev`，看 `/sys/class/infiniband/mlx5_*/ports/*/counters/` 或 `ibstat`。

### 0.3 已确立的事实（作为你的起点）
1. **stage1 单流写应用层调优已收官**：`results/20260708-stage1-single-write/` 跑完 connRDMABufNum/BufSize、tuneNumWorkers、chunksize、fsync 五变量共 28 轮，**全部在噪音范围（±3%）无正收益**。单流写被 per-IO 延迟（clat avg ~273µs）主导，~900 MiB/s 是物理天花板，非应用层可调。**本任务不再调单流写参数。**
2. **数据面必须走 RDMA**（不限速口径）。曾发生 `connInterfacesFile` 为空 → client 自动选接口掉到 10GbE TCP（eno12409, 10.114.1.x）→ 单流写腰斩 ~479、clat_min 翻倍。现已锁定 `connInterfacesFile = /etc/beegfs/connInterfacesFile.conf`（内容 `enp139s0f0np0`+`enp139s0f1np1`）强制走 RDMA。**不限速口径每次测前必做 RDMA 哨兵检查（§2A）。**
3. slave 端系统调优已固定为基线（THP=always、read_ahead=4096 等，见 `skills/beegfs-baseline-config.md`）。157 保持系统默认不调（保护业务）。

### 0.4 ⚠️ 调优/测试安全红线（**最重要，违反会影响生产业务**）
100GbE Mellanox 网卡与 WekaIO **物理共用**（同一 RDMA verbs 设备）。

| 可以动 | 禁止动 |
|--------|--------|
| ✅ BeeGFS `.conf` 应用层参数 | ❌ 网卡/驱动全局参数（MTU、mlxconfig、queue、中断、PFC） |
| ✅ slave 内核参数 | ❌ 157 的任何内核参数 |
| ✅ 子目录 stripe（`--setpattern`） | ❌ RoCE QoS（`connRDMATypeOfService`、DSCP）——与 WekaIO 共享 |
| ✅ **`eno12409`（10GbE 独立网卡）上的 `tc tbf` 限速** | ❌ 在 100GbE RDMA 网卡上做任何限速/QoS |

**总原则：只改 BeeGFS 应用层 / slave 端；不动 157 内核、不动 100GbE 网卡/驱动/RoCE QoS。** 千兆限速只在 `eno12409`（10GbE，与 WekaIO 的 100GbE RDMA 设备物理隔离）上用 `tc tbf`，**不影响业务**。BeeGFS 是纯测试集群，服务可自由重启；重启后须等 target 全 Online/Good 再测。

---

## 1. 本任务要解决的问题

先前用 100GbE RDMA 替代 10GbE TCP，使单流写绝对带宽翻倍（479→900），但**占网卡线速比例反而下降**（10GbE 下 ~38% → 100GbE 下 ~7%）。为避免盲目追绝对带宽误导判断，**目标口径统一重定义为**：

> **所有测试项的有效数据带宽 ≥ 对应网卡线速的 50%。达不到的项必须有数据支撑说明原因（延迟主导 / 缓存 / 后端约束），而非仅报绝对值。**

本任务：在 RDMA 锁定态下重跑全矩阵，产出**两套口径的统一基线表**，作为对领导汇报的口径基准，并标出每项是否达 50%、未达标项的原因。

---

## 2. 访问方式

项目目录在 157：`/home/sunrise/beegfs-production`

```bash
# WSL → 泰国 client 157
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
# 157 → slave（两级跳）
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 '<command>'"
```
- 用户 `sunrise` / 密码 `Sunrise@801`；sudo：`echo 'Sunrise@801' | sudo -S <cmd>`
- 规范：`skills/beegfs-node-conventions.md`（节点）、`skills/TESTING-GUIDE.md`（测试纪律）、`skills/beegfs-baseline-config.md`（基线定义/接口锁定）。

---

## 3. 测试口径（两套，都要跑）

统一用 `tests/bench-full.sh <tag> cold` 冷态口径（`--direct=1` + 每项前客户端 + 全部 3 storage server drop page cache）。测试项固定：seqwrite/seqread（单流 + 16 线程）、layout（128 jobs × 4M）、randwrite/randread（128 jobs × iodepth128）、randread bs sweep 64K/256K/1M。每项 ≥2 轮，只认冷态一致轮。

### 3.1 口径 A：100GbE RDMA 不限速（分母 = 12500 MiB/s，50% 线 = 6250 MiB/s）
- **前提：connInterfacesFile 锁定 RDMA（基线态）**，每项测前做 RDMA 哨兵检查（§2A）。
- 目的：暴露后端真实能力，量化各项占 100GbE 线速比例。

### 3.2 口径 B：千兆限速（eno12409 TBF 1Gbps，分母 ≈ 118 MiB/s，50% 线 = 59 MiB/s）
- 目的：对齐 JuiceFS/Ceph 千兆业务基准（该报告达标线 ≥59 MB/s），贴近实际业务场景。
- **限速施加在 `eno12409`（10GbE 独立网卡），绝不在 100GbE RDMA 网卡上限速。**
  ```bash
  # 施加（在 3 个 storage slave 的 eno12409 egress 上）
  sudo tc qdisc add dev eno12409 root tbf rate 1gbit burst 32kbit latency 400ms
  # 确认
  tc qdisc show dev eno12409 | grep tbf
  # 测完清除
  sudo tc qdisc del dev eno12409 root
  ```
- **⚠️ 口径切换关键**：限速口径下数据面要走 eno12409（10GbE），因此需**临时把 connInterfacesFile 指向 eno12409 对应接口**（或临时置空让其走 TCP），测完**务必恢复 RDMA 锁定**。此切换步骤照 `skills/beegfs-baseline-config.md` §1.5 的备份/恢复流程，改完重启 BeeGFS 服务。记录当轮 `beegfs-net` 连接类型证明确实走了 eno12409/TCP。
  > 沿用历史做法：限速对比本就走 eno12409 + tc tbf（见 skill），与 WekaIO 物理隔离，不影响业务。

---

## 2A. RDMA 哨兵检查（口径 A 每次测试前必做，防 479 陷阱）

不限速口径基线的前提是数据面走 RDMA。**每次 drop_caches 后、跑 fio 前检查，任一不通过就停下修复/回报，不要采数据：**
```bash
grep connInterfacesFile /etc/beegfs/beegfs-client.conf        # 应 = /etc/beegfs/connInterfacesFile.conf
beegfs-net | grep -A1 "ID: 10[123]"                           # 应全 RDMA (10.3.x:8003)，无 TCP/10.114.1.x
# 快测一发确认 clat_min < 250µs（TCP 态 ~400µs）
```
每轮记录 beegfs-net 连接类型与 clat_min 作为"数据在 RDMA 态采集"的证据。

---

## 4. 产出（核心交付）

在 `results/20260708-stage2-dual-baseline/`（或按实际日期）产出统一基线表 `README.md`：

### 4.1 口径 A 表（100GbE RDMA 不限速）
| 测试项 | 各轮 MiB/s | 取值 | %100GbE(÷12500) | ≥50%? | 未达标原因（数据支撑） |
|--------|-----------|:---:|:---:|:---:|------|

- 未达标项必须给数据支撑，例如：
  - **单流 seqwrite/seqread**：引 clat avg（~273µs 写）→ IOPS 上限 → 带宽 = IOPS×bs 算术，说明延迟主导、换网卡无法提升占比（对齐 stage1 §八结论）。
  - **randwrite 128**：Buddy Mirror 2× 写放大 + NVMe 聚合上限。
  - **randread 64K**：小块读退化，附 64K/256K/1M sweep 对比说明预取/read_ahead 影响。

### 4.2 口径 B 表（千兆限速）
| 测试项 | 各轮 MiB/s | 取值 | %千兆(÷118) | ≥50%(≥59)? | vs JuiceFS 基准 |

### 4.3 每项数据对账原始 fio 的 `WRITE:/READ: bw=` 与 `clat` 行（不要只写 summary 转写值）。保留：原始 fio、`commands.sh`、env 快照、每轮 beegfs-net 连接类型、tc qdisc 状态（口径 B）。

---

## 5. 验收标准
- [ ] 口径 A（RDMA 不限速）与口径 B（eno12409 千兆限速）两套全矩阵各 ≥2 轮完成，只认冷态一致轮
- [ ] 口径 A 每轮 RDMA 哨兵通过并留证据；口径 B 每轮确认走 eno12409、tc tbf 生效
- [ ] 两套 50% 达标表产出，未达标项均有数据支撑说明原因
- [ ] **口径 B 测完 connInterfacesFile 恢复 RDMA 锁定、tc qdisc 清除、服务重启后哨兵通过**
- [ ] 全程未动：157 内核、100GbE 网卡/驱动/RoCE QoS、根目录 stripe（安全红线）
- [ ] 所有数值可追溯到原始 fio

---

## 6. 交付与提交规范
1. **脚本/文档改动，提交推送前必须先向用户展示 diff 并获确认**（`skills/doc-publish-rule.md`），不得私自 `git commit`/`git push`。
2. 完成后回传两套基线表给规划 agent，用于据此判断 stage3（聚焦未达标带宽主导项：randwrite 写放大 / 小块读退化）的优先级。
3. 过程中若发现与既有基线冲突或可信度问题，先停下报告，不在污染数据上继续。

---

## 7. 快速自检清单（每次改配置前问自己）
- 现在是口径 A 还是 B？connInterfacesFile 指向对了吗？（A=RDMA 锁定 / B=eno12409）
- 口径 A：beegfs-net 全 RDMA 10.3.x、clat_min<250µs 吗？
- 口径 B：tc tbf 施加在 **eno12409**（不是 100GbE 网卡）吗？tc qdisc show 确认了吗？
- 我有没有在 100GbE RDMA 网卡上做任何限速/QoS？（绝对禁止）
- 每项数值能对上原始 fio 的 `bw=` 行吗？
- 口径 B 全部测完，我恢复 RDMA 锁定 + 清除 tc + 重启验证哨兵了吗？
