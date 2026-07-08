# 02 — 阶段0 复核结论与修正后调优计划（RDMA 现状 + 共用网卡约束）

> ⚠️ **2026-07-08 定案（读这条即可）**：单流写"835/479/900"之谜彻底查清——**479 = 数据面掉到 10GbE TCP 网卡（eno12409）；900 = 走 100GbE RDMA**。根因是 `connInterfacesFile` 曾被清空致 client 自动选接口小概率落 TCP。**已锁定 connInterfacesFile 只用 RDMA 网卡，5/5 重启 100% RDMA，单流写稳定 ~900（可保证基线）**。"slave 调优 +78%""835 基线"作废（实为 RDMA↔TCP 之差）。stage1 在 ~900 RDMA 锁定基线上正式推进。详见 §六与 `skills/beegfs-baseline-config.md` 第五节。
>
> 日期：2026-07-07（§六 2026-07-08 定案更新）
> 数据来源：`results/20260707-beegfs-cold-baseline-v2/`（不限速 + 限速各 1 轮）、`evidence/`（0.5-0.7 证据 + 对照实验）
> 前置：本文档修正 `01-bottleneck-and-tuning-plan.md` 中被阶段0 实测推翻的关键假设。01 作为历史记录保留，**以本文档为准**。
> 方法论：`skills/perf-review-planning/SKILL.md` — 结论均已对账原始 fio / 系统实测，未采信 summary 转写。

---

## 一、阶段0 复核结论（GLM 执行结果）

已逐项对账原始文件核验，8 个子任务全部完成，数据可信。同时发现 **两处推翻 01 计划核心假设** 的结论。

### 1.1 验证通过项

| 任务 | 核验 | 结论 |
|------|------|------|
| 0.1 meta 节点4 | env-snapshot:45-51 | 4 meta target 全 Online/Good，容量恢复 879.1GiB ✓ |
| 0.2 7.x 采集 | git diff + env 快照 | 去 `--mgmtd_node`，拓扑/mirrorgroups 采齐 ✓（仅 `getentryinfo` stripe 仍 `Stat failed`，待修） |
| 0.3 iopsget | git diff + summary | IOPS 全非 NA，对账一致 ✓ |
| 0.4 递归 bug | git diff | 内联 drop 逻辑 ✓ |
| 0.5 tune 核对 | tune-verify-*.txt | 3 slave 生效；**157 未调（保护业务）**；`nr_requests` 在 NVMe 从未生效（`Invalid argument` 被 `\|\| true` 吞掉） |
| 0.6 共部署 | fuser/ps 实测 | 见 1.3（有重大发现） |
| 0.7 seqread | 5 轮重跑 1489-1623 | 无法复现 565，倾向"首日冷启动"，偏差 9%<10% ✓（属"未复现"而非"证实"） |
| 0.8 基线 | 对账全部 raw fio | README 数值与原始一致 ✓ |

### 1.2 重大发现 A：BeeGFS 走 **100GbE RDMA/RoCE**，不是 10GbE TCP

**已在 157 独立实证**：`connUseRDMA=true`；`ibstat` 两端口 Active/Rate 100/LinkUp（Ethernet=RoCE）；randwrite 写 366GiB 而 `/proc/net/dev` TX 仅增 227MB（0.06%）—— 流量绕过 TCP 栈。

**影响**：**01 计划的 2.6 节（"100GbE 网络杠杆 + 单流写延迟分解 708µs≈60%是10GbE"）整段作废**。集群本就在 100GbE RDMA 上，不存在"切 100GbE"这个阶段。v2 单流写 clat 已是 263µs（RDMA），非 10GbE 的 708µs。

### 1.3 重大发现 B：100GbE Mellanox 网卡与 WekaIO **物理共用**（调优安全红线）

`fuser /dev/infiniband/uverbs0` 显示 **同一 RDMA verbs 设备上同时挂着 `beegfs-meta` 与十几个 `wekanode`**；网卡 `enp139s0f0np0=10.3.1.13`、`enp139s0f1np1=10.3.2.13` 是 WekaIO 的 RoCE 网。

BeeGFS 当前 RDMA 参数：`connRDMABufNum=70`、`connRDMABufSize=8192`、`connRDMATypeOfService=0`。

**调优安全边界**（贯穿后续所有阶段）：

| 层级 | 例子 | 是否可动 |
|------|------|---------|
| BeeGFS 应用层缓冲 | `connRDMABufNum` / `connRDMABufSize` | ✅ 可调（只吃 BeeGFS 侧内存 = BufSize×BufNum×2 per conn），但需重启 BeeGFS 服务，157 上 meta/client 重启有短暂中断 → **业务低峰操作** |
| RoCE QoS/优先级 | `connRDMATypeOfService`(ToS/DSCP)、PFC | ⚠️ 中高风险 — 与 WekaIO 共享 RoCE，可能挤占其带宽/优先级 → **默认不动** |
| 网卡/驱动全局 | MTU、`mlxconfig`、queue、中断亲和、PFC | ❌ 禁止 — WekaIO 立即受影响 |
| 157 内核参数 | THP/dirty_ratio/read_ahead | ❌ 保持不动（K8s+WekaIO 在跑，0.5 已确认 157 不调） |

### 1.4 重大发现 C：seqwrite/layout 收益归因修正（对照实验）

> ⚠️ **本小节的 seqwrite +78% 结论已于 2026-07-07 晚被推翻，见 §六。** layout +2.5% 仍成立。以下保留为历史记录。

`evidence/control-experiment.md`（回退 3 slave 调优、157/RDMA 不变的单变量实验，内部一致性 0.4-0.6%）：

| 测试 | v2(slave调优) | 对照(未调优) | slave 调优真实收益 |
|------|:---:|:---:|:---:|
| seqwrite(单流) | 835 | 466/469 | **+78%**（可确认，单变量） |
| layout(128并发大块) | 10240 | 9964/10004 | **+2.5%**（几乎无收益） |

结论：
- **单流写：slave 调优 +78% 真实有效**（主因推断 `dirty_ratio 20→10`，storage 端更早落盘）。335→835 里 +78% 归 slave 调优，剩余 +42%（335→466）归 07-03 首日单轮未复核（不可控）。
- **并发大块写：slave 调优仅 +2.5%**。07-03 layout 1640 → v2 ~10000 的跳变 **不是调优带来的**——未调优对照组也有 9964。
  - 注：GLM 归因为 `--openfiles 100→128`，但 layout 的 fio 命令本身不含 `--openfiles`（该参数只在随机测试）。更准确说法：07-03 layout（79.9s/128GiB 异常慢、单轮无复核）是首日污染值，v2 才是真实水平。**不影响规划结论：并发大块写调优空间极小，瓶颈不在内核参数。**

---

## 二、修正后的瓶颈认知（v2 健康基线）

v2 不限速关键值（RDMA 100GbE，已对账 raw）：

| 测试 | v2 | 说明 |
|------|:---:|------|
| seqread(单流) | 1585 | clat 157µs |
| seqwrite(单流,fsync) | 835 | clat 263µs，IOPS 3338 |
| multi-seqread(16) | 6874 | |
| multi-seqwrite(16) | 8214 | |
| layout(128,4M) | 10240 | |
| randread(128) | 8227 | 三轮 0.08% |
| randwrite(128) | 6138 | 三轮 3.1%，IOPS 24.6k，slat 5.2ms |
| randrw R/W | 4602/4599 | |
| randread-64K | 4789 | 小块仍偏低 |
| randread-1M | 8807 | |

**修正后的瓶颈排序**：

1. **单流写 835 MiB/s 仍是最突出短板**（vs 并发写 6138，7.3×）。RDMA 下 clat 263µs：写路径 = client→primary→secondary（RDMA 双写同步）+ 2× NVMe 落盘 ack 串行。延迟主导，非带宽。**这是离上限最远、且已证明可调（slave dirty_ratio 已吃到 +78%）的方向。**
2. **写天花板 ≈ 6 GB/s**（randwrite/randrw 收敛）。RDMA 下不再是 10GbE 限制；瓶颈转为 **Buddy Mirror 2× 写放大 + NVMe 落盘**。物理写 ≈ 12 GB/s，接近 6 NVMe 聚合。
3. **小块随机读退化**：randread-64K 4789 vs 256K 8227 vs 1M 8807，per-IO 固定开销占比高。
4. **读天花板 ~8.2 GB/s**（256K）/ 8.8（1M）：v2 比 07-03 的 10650 低，因 v2 真冷态（清了服务端 XFS 缓存），非退化。读侧无明显瓶颈。

---

## 三、修正后的调优计划

> 总原则（不变）：**不影响已有业务**（157 内核参数不动、网卡/驱动/RoCE QoS 不动、BeeGFS 服务重启限业务低峰）；一次一个变量；对账原始 fio；只认冷态 R1；改动前后留原始日志。
> 排期依据：**去掉"切 100GbE"阶段（已是 RDMA）**；单流写为首要战场；RDMA 调优限定在 BeeGFS 应用层缓冲。

### 阶段 0：已完成 ✓
环境/脚本修复 + 可信基线 v2 建立。遗留小项：修 `getentryinfo` stripe 采集（`Stat failed`）；`nr_requests` 从 tune-servers.sh 移除或改对 NVMe 有效的项（当前静默失败）。

### 阶段 1（最高优先）：单流写延迟优化 —— 在 ~900 RDMA 锁定基线上做单变量矩阵

目标：单流 seqwrite 从 **~900（RDMA 锁定态，见 §七）** 继续提升；全部为 BeeGFS 应用层/slave 端参数，**不碰 157、不碰网卡**。前置：`connInterfacesFile` 已锁 RDMA（否则数据会掉到 10GbE TCP=479）；每次测前用 `beegfs-net` 确认走 RDMA、clat_min<250µs。

- [x] ~~A. slave 端 dirty_ratio 精调~~ **取消**：dirty_ratio 对 `--direct=1` 单流写无效（实测 512 vs 503）。
- [ ] **B. connRDMABufNum / connRDMABufSize**（client + meta + storage .conf）：当前 70×8192。增大缓冲提升单流 pipeline。**注意**：RAM=BufSize×BufNum×2/conn，需估算内存；改后重启 BeeGFS 服务；**只改 BeeGFS，不动网卡**。
- [ ] **C. tuneNumWorkers（storage/meta 工作线程）**：默认→提高，看单流是否受服务端线程调度影响。
- [ ] **D. chunksize**：子目录 `--setpattern` 测 512K/1M/2M/4M 对单流写的影响（不污染根目录）。
- [ ] **E. fsync vs 非 fsync 对照**：拆分"后端瓶颈"与"同步确认瓶颈"。
- **验收**：单流 seqwrite cold R1 逐变量记录增量；对账 raw fio 的 `WRITE: bw=` / `clat`。

### 阶段 2：写天花板与镜像开销量化

- [ ] 非镜像子目录（`--setpattern --pattern=raid0 --numtargets=3/6`）跑 randwrite/layout/multi-seqwrite，量化 Buddy Mirror 2× 写放大真实代价（对照 ~6 GB/s）。
- [ ] `tuneStorageThreadsPerTarget`；XFS `allocsize` 131072k vs 1m vs 默认 对照。
- [ ] **不改生产镜像配置，仅测量对照**，为"性能 vs 冗余"提供数据。

### 阶段 3：小块随机读优化

- [ ] client `tuneFileCacheType`、read_ahead_kb（slave 侧 256/1024/8192）、iodepth（256/512）对 randread-64K 的影响。
- [ ] chunksize 与小块读关系。
- [ ] （可选，谨慎）`connRDMABufSize` 对小块的影响 —— 仍属 BeeGFS 应用层，不动网卡。
- **验收**：randread-64K cold R1 从 ~4789 提升，且不回退 256K/1M。

### 阶段 4：暖态基线与业务口径

- [ ] 暖态基线（不 direct、不 drop、顺序 1 次 + 随机 3 轮）界定重复访问上限。
- [ ] 单客户端千兆场景：现限速在 3 slave egress（聚合 ≈3×1Gbps），非真单千兆；补客户端侧限速。
- [ ] 同口径 vs JuiceFS+Ceph 终版对比。

### 阶段 5（可选，需业务窗口）：157 共部署 / 独立 client
0.6 已证当前负载下 157 共部署非瓶颈（BeeGFS 服务测试期间 0% CPU）。仅当阶段1-4 后单流写仍受限、且怀疑 157 争抢时，才在业务窗口验证独立 client。**默认不做。**

---

## 四、被本文档修正/作废的 01 计划条目

| 01 条目 | 处理 |
|---------|------|
| 1.1 "网络走 10GbE" | ❌ 作废 → 实为 100GbE RDMA/RoCE |
| 2.6 "100GbE 网络杠杆 + 708µs 延迟分解" | ❌ 整段作废（前提错误） |
| 原阶段2 "100GbE 切换" | ❌ 删除（已是 RDMA） |
| 2.2 "单流写 335 延迟受限" | ✅ 保留，数值更新为 835/clat263µs；已证 slave 调优可提 +78% |
| 2.7 "157 共部署隐患" | ✅ 已验证：当前非瓶颈，降为阶段5 可选 |
| 新增 | ⚠️ 共用网卡 = RDMA 调优安全红线（1.3） |

---

## 五、留存与执行要求（不变）

1. 每阶段结果落 `results/<日期>-<阶段名>/`，保留 summary + 原始 fio + env 快照 + commands.sh。
2. 结论对账 raw：带宽取 `READ:/WRITE: bw=`；IOPS 取小写 `read:/write: IOPS=`；写延迟记 slat/clat。
3. **任何改动前明确：只改 BeeGFS 应用层/slave 端，不动 157 内核、不动网卡/驱动/RoCE QoS；BeeGFS 服务重启限业务低峰。**
4. 脚本/文档改动提交推送前经用户确认（`skills/doc-publish-rule.md`）。

---

## 六、【2026-07-07 晚 · 复测推翻】v2=835 与 slave 调优 +78% 作废

阶段1 前置复测（`results/20260707-stage1-baseline-recheck/`）独立重跑 v2 基线，**单流 seqwrite 无法复现 835**：

| 测量时刻 | 事件 | seqwrite | clat min |
|------|------|:---:|:---:|
| 07-06 18:44 | v2 基线（本文档全篇依据） | 835 | 200µs |
| **07-06 20:23** | **BeeGFS 服务重启** | - | - |
| 07-07 11:47 | 对照实验 untuned | 466/469 | ~400µs |
| 07-07 12:48/13:01 | 复测 R1/R2 | 479/479 | 400µs |
| 07-07 14:05 | 空闲态实测（WekaIO RDMA 流量=0） | 508 | 403µs |

**排除业务争抢**：空闲态（RDMA 流量=0）仍 508，与繁忙时段 479 同量级；两轮 479=479 完全一致、clat min 稳定翻倍 → 确定性状态变化，非争抢。根因指向 **07-06 20:23 的服务重启**。

**修正**：
- ❌ **撤回 §1.4 / §三 阶段1 的"slave 调优对单流写 +78%"**：对照实验的 tuned=835（重启前）与 untuned=466（重启后）跨越了服务重启这个未受控变量；dirty_ratio 对 `--direct=1` 已实测无效（512 vs 503）。466→835 来自服务重启，非调优。
- ❌ **撤回"v2 单流写 835 为基线"**：835 是 n=1、无快照、不可复现孤例。当前真实单流写基线 ≈ **479-512**。
- ✅ layout +2.5%、100GbE RDMA、共用网卡红线、写天花板/小块读瓶颈等其余结论不受影响。
- ⚠️ **变量 A（dirty_ratio 精调）取消**：direct write 不经 page cache，dirty_ratio 无效。

**阻塞与下一步**：单流写"重启前 835 / 重启后 490"的机制未定。BeeGFS 为**纯测试集群、可自由多次重启**，已派发 `doc/perf-tasks/stage1-restart-repro-task-book.md`（≥8 次"重启→立即测→10min 后再测"+ 每轮重启前后全套快照）判定 835 是否可复现并定位机制。在其出结论前 **stage1 单变量调优（B/C/D/E）暂缓**，基线暂以 ~490 计。

---

## 七、【2026-07-08 定案】谜底 = 网络接口（RDMA vs 10GbE TCP），基线闭环

`results/20260707-restart-repro/`（33 次测量排除衰减/dirty_ratio）+ `results/20260708-lock-rdma-iface/`（接口锁定，均对账 raw fio）查清：

| 状态 | seqwrite | clat_min | 走哪 |
|------|:---:|:---:|------|
| 低态（07-07）| 466-508 | ~400µs | **10GbE TCP eno12409(10.114.1.x)** |
| 高态（33 次）| 887-944 | ~200µs | RDMA（自动选中）|
| **RDMA 锁定（07-08）** | **889-909** | ~215µs | **RDMA 100%（5/5 重启）** |

- **479 = 数据面掉到 10GbE TCP**（非 RDMA）；**900 = 走 100GbE RDMA**。
- 根因：07-06 20:23 清空 `connInterfacesFile` → 自动选接口 → 小概率落 TCP。证据：低态日志 `Connected: beegfs-storage@10.114.1.x:8003 (protocol: TCP)`。
- **修复定案**：锁定 `connInterfacesFile` 只用 RDMA 网卡（`enp139s0f0np0`/`enp139s0f1np1`，157+3 slave），已固化进 `skills/beegfs-baseline-config.md` §1.5。**单流写基线 = ~900 MiB/s（RDMA 锁定态）。**
- ❌ 作废：§六"根因指向服务重启（机制未定）"由本节取代；"slave 调优 +78%""835 基线"全部作废。
- ✅ 其余结论（layout +2.5%、100GbE RDMA、共用网卡红线、写天花板/小块读瓶颈）不变。
- **stage1 变量 A（dirty_ratio）取消**（对 direct=1 无效）；**stage1 在 ~900 RDMA 锁定基线上正式推进（变量 B/C/D）**。基线疑问已闭环。
