# BeeGFS 生产集群性能调优 — 基线、发现与计划

> 更新：2026-07-08
> 集群：4 节点 BeeGFS 7.3.2（157 mgmtd+meta+client / 150·151·152 meta+2storage）
> 镜像：metadata 2 buddy groups + storage 3 buddy groups（Buddy Mirror, chunk=1M, numtargets=3）
> 数据面：**100GbE RDMA/RoCE**（`connUseRDMA=true`，Mellanox mlx5）；限速对比走独立网卡 `eno12409` + `tc tbf 1gbit`
> 方法论：`skills/perf-review-planning/SKILL.md`（先核方法再看数据、单变量控制、只认冷态一致轮、结论对账原始 fio）
> 关联：基线配置锚点 `skills/beegfs-baseline-config.md`；任务书 `doc/perf-tasks/`；测试结果 `results/<日期>-*/`
>
> 本文档是 BeeGFS 调优的**单一现行文档**（合并原 01/02，删去所有已被推翻的中间结论，只留定案）。

---

## 一、调优基础 —— 冷态基线（对领导反馈的口径）

### 1.1 部署与测试口径

- 4 节点集群部署完成，镜像启用；4 meta target + 6 storage target（各 ~7.1TB）全部 Online/Good。
- slave（150/151/152）按官方文档做系统调优（THP=always、dirty 5/10、read_ahead 4096K、NVMe 调度 none 等，见 `skills/beegfs-baseline-config.md`）；**157 保持系统默认不调**（同机跑 K8s+WekaIO 生产业务，保护业务）。
- 测试口径（固定）：`fio --direct=1`（冷态）+ 每项测前 drop page cache（**客户端 + 全部 3 storage server**，客户端清不掉服务端 XFS 缓存）。顺序 bs=256K（单流 + 16 线程）；随机 128 jobs × iodepth=128 × 3 轮；layout 128 jobs × bs=4M。

### 1.2 冷态基线（对领导反馈的口径，双口径：不限速 + 千兆限速）

> 来源：`results/20260703-beegfs-cold-baseline/`（冷态一轮，direct=1，客户端+服务端 drop cache，均已对账原始 fio）。
> **这是最初对领导反馈的基准数据，作为调优工作的对比起点。**
> 双口径：**不限速**暴露后端真实能力；**千兆限速**（`eno12409` TBF 1Gbps）对齐 JuiceFS+Ceph 千兆场景（达标线 ≥59 MB/s）。

| 测试 | 不限速 (MiB/s) | 千兆限速 1Gbps (MiB/s) | 备注 |
|------|:---:|:---:|------|
| seqread（单线程） | 565 | 114 | clat ~442µs, IOPS 2258 |
| seqwrite（单线程, fsync） | **335** | 58.9 | clat ~709µs, IOPS 1341 |
| multi-seqread（16 jobs） | 6311 | 302 | |
| multi-seqwrite（16 jobs） | 1677 | 113 | clat ~2.3ms, IOPS 6708 |
| layout（128 jobs, bs=4M） | 1640 | 113 | |
| randread（128 jobs） | 10650 | 339 | |
| randwrite（128 jobs） | 1629 | 113 | clat ~2.4s(!), IOPS 6517 |
| randrw R/W（128 jobs） | 1582/1578 | 109/108 | |
| randread bs=1M | 12698 | 340 | 读峰值 |
| randread bs=64K | 4938 | 340 | 小块读明显掉 |

> ⚠️ 该批数据的可信度局限（后续测试中发现，见 §二）：单流写两轮离散（335 vs 483）、layout 单轮污染、单流读离群（565 vs 1521）；且当时误判数据面走 10GbE（实为 100GbE RDMA，见 §2.3）。这些不改变"作为汇报起点"的地位，但精确逐项对比时须结合 §二的修正认知。

### 1.3 当前实测参照（RDMA 锁定态可信基线，不限速，MiB/s）

> 后续重建的可信基线（`results/20260707-beegfs-cold-baseline-v2/` + `results/20260708-lock-rdma-iface/`，均对账原始 fio）。与 1.2 并非同口径直接可比（详见 §二的认知修正），列此作为当前后端真实水平的参照。千兆限速侧的完整双口径重测见 §三 stage2。

| 测试项 | 不限速 | 关键延迟 / 说明 |
|--------|:---:|------|
| seqread（单流） | 1585 | clat ~157µs |
| seqwrite（单流, fsync） | **~900** | clat avg ~273µs, IOPS ~3600（RDMA 锁定态） |
| multi-seqread（16 jobs） | 6311 | |
| multi-seqwrite（16 jobs） | 8214 | |
| layout（128 jobs, bs=4M） | 10240 | 写峰值 |
| randread（128 jobs） | 8227 | 三轮偏差 0.08% |
| randwrite（128 jobs） | 6138 | 三轮偏差 3.1%，IOPS ~24.6k |
| randrw R/W（128 jobs） | 4602/4599 | |
| randread bs=64K | ~4900 | 小块读明显偏低 |
| randread bs=1M | 8807 | 读峰值 |

---

## 二、近期调优工作的新发现

### 2.1 【定案】单流写"835/479/900"之谜 = 网络接口选择（RDMA vs 10GbE TCP）

排查中单流写在 479 与 900 两个值间反复，一度误判为"slave 调优 +78%"或"服务重启衰减"。经 33 次重启测量（`results/20260707-restart-repro/`）+ 接口锁定实验（`results/20260708-lock-rdma-iface/`，均对账原始 fio）**彻底查清**：

| 状态 | seqwrite | clat_min | 数据面走哪 |
|------|:---:|:---:|------|
| 低态 | 466-508 | ~400µs | **10GbE TCP（eno12409, 10.114.1.x）** |
| 高态（自动选中） | 887-944 | ~200µs | RDMA（10.3.x） |
| **RDMA 锁定态（定案）** | **889-909** | ~215µs | **RDMA 100%（5/5 重启验证）** |

- **479 = BeeGFS 数据面掉到了 10GbE 普通 TCP 网卡**（非 100GbE RDMA），TCP 栈开销使 clat_min 翻倍。**900 = 走 100GbE RDMA。**
- **根因**：某次服务重启把 `connInterfacesFile` 清空 → client 自动选接口 → 空配置下大概率选 RDMA、小概率落 TCP。证据：低态日志 `Connected: beegfs-storage@10.114.1.150:8003 (protocol: TCP)`。
- **修复并定案**：锁定 `connInterfacesFile` 只用 RDMA 网卡（`enp139s0f0np0`/`enp139s0f1np1`，157 + 3 slave 均设），5/5 次重启 100% 走 RDMA。**479 态永久消除，单流写基线固定为 ~900 MiB/s（可保证、可复现）。**
- **作废的旧结论**：①"slave 调优对单流写 +78%（466→835）"——实为 TCP↔RDMA 的网络路径之差，对照实验碰巧一组走 TCP、一组走 RDMA；②"835/479 为单流写基线"。
- 详见 `skills/beegfs-baseline-config.md` 第五节及 §1.5（接口锁定操作）。

### 2.2 【定案】单流写 ~900 是 per-IO 延迟天花板，应用层参数无法突破

在 ~900 RDMA 锁定基线上跑完单变量矩阵（`results/20260708-stage1-single-write/`，28 轮全对账、100% RDMA 哨兵通过）：

| 变量 | 取值 | vs 基线 | 结论 |
|------|------|:---:|------|
| connRDMABufNum | 70→128→256 | +0.6~3.3% | 噪音范围 |
| connRDMABufSize | 8192→16384→32768 | +1.7~1.8% | 噪音范围 |
| tuneNumWorkers | 12→24→48 | -1.7~+0.6% | 噪音范围 |
| chunksize | 512K/1M/2M/4M | ±0.4% | 无影响 |
| fsync vs 无fsync | — | 0% | **完全无差异** |

- **根因**：单流写被 per-IO 延迟（clat avg ~273µs）主导。带宽 = IOPS(1/273µs≈3660) × 256K ≈ 914 MiB/s，与实测吻合。延迟 ≈ RDMA 往返 + BeeGFS 协议 + Buddy Mirror 双写 + NVMe 落盘。
- **变量 fsync 的决定性证据**：移除 `end_fsync` 仍 916 vs 916 → `--direct=1` 下每个 write 本身同步，瓶颈在写路径、不在后端落盘确认。
- **结论**：**单流写应用层调优到此结束，无正收益项。** dirty_ratio 对 `--direct=1` 也已实证无效（512 vs 503）。

### 2.3 数据面是 100GbE RDMA，且与 WekaIO 物理共用网卡（安全红线）

- **数据面本就是 100GbE RDMA/RoCE**（`ibstat` 两端口 100/LinkUp；randwrite 写 366GiB 而 `/proc/net/dev` TX 仅增 0.06% → 流量绕过 TCP 栈）。故不存在"切 100GbE"这个动作。
- **100GbE Mellanox 网卡与 WekaIO 物理共用**（`fuser /dev/infiniband/uverbs0` 显示同一 RDMA verbs 设备上同时挂着 `beegfs-meta` 与十几个 `wekanode`）。由此确立贯穿所有调优的**安全红线**：

| 可以动 | 禁止动 |
|--------|--------|
| ✅ BeeGFS `.conf` 应用层参数（connRDMABuf*、tuneNumWorkers） | ❌ 网卡/驱动全局参数（MTU、mlxconfig、queue、中断、PFC） |
| ✅ slave（150/151/152）内核参数 | ❌ 157 的任何内核参数 |
| ✅ 子目录 stripe（`--setpattern`，不动根目录） | ❌ RoCE QoS（`connRDMATypeOfService`、DSCP）——与 WekaIO 共享 |
| ✅ `eno12409`（10GbE 独立网卡）上的 `tc tbf` 限速 | ❌ 在 100GbE RDMA 网卡上做任何限速/QoS |

> BeeGFS 是纯测试集群（业务在独立 WekaIO 上），服务可自由重启；但重启后必须等 target 全 Online/Good 且 RDMA 哨兵通过再测。

### 2.4 【决策】考核目标：从"绝对带宽"转向"有效带宽 ≥ 网卡线速 50%"

先前用 100GbE RDMA 替代 10GbE TCP 使单流写绝对值翻倍（479→900），但**占网卡线速的比例反而下降**（10GbE 下 479/1250≈38% → 100GbE 下 900/12500≈7.2%）。原因即 §2.2：单流写延迟主导，换更快网卡只缩短 per-IO 延迟里 ~15µs 的 RDMA 往返，分母（线速）却涨 10 倍，占比必降。**盲目追绝对带宽会误导对后端真实效率的判断。**

> **新考核目标（统一口径）**：所有测试项的有效数据带宽 ≥ 对应网卡线速的 50%。达不到 50% 的项（如单流读写、小块读），必须有数据支撑说明原因（延迟主导 / 缓存 / 后端约束），而非仅报绝对值。

**双口径**（均在 RDMA 锁定态之上）：

| 口径 | 分母（线速） | 50% 线 | 用途 |
|------|:---:|:---:|------|
| 100GbE RDMA 不限速 | 12500 MiB/s | 6250 | 暴露后端真实能力，量化各项占线速比例 |
| 千兆限速（eno12409 TBF 1Gbps） | ~118 MiB/s | 59 | 对齐 JuiceFS/Ceph 千兆业务基准（≥59 MB/s） |

**当前各项对 100GbE 线速的占比**（v2 冷态不限速）：

| 测试项 | MiB/s | %100GbE | ≥50%? | 性质 |
|------|:---:|:---:|:---:|------|
| seqwrite 单流 | 900 | 7.2% | ✗ | 延迟主导（§2.2 已证，不可调） |
| seqread 单流 | 1585 | 12.7% | ✗ | 延迟主导 |
| multi-seqwrite 16 | 8214 | 65.7% | ✓ | 达标 |
| multi-seqread 16 | 6311 | 50.5% | ✓ | 勉强达标 |
| layout 128/4M | 10240 | 81.9% | ✓ | 达标 |
| randwrite 128 | 6138 | 49.1% | ✗ | 逼近，镜像 2× 写放大约束 |
| randread 128 | 8227 | 65.8% | ✓ | 达标 |
| randread 64K | 4938 | 39.5% | ✗ | 小块读退化 |

**观察**：并发/大块项已达 50-82%；未达标集中在 ①延迟主导的单流项（物理天花板，§2.2 定论）②randwrite（镜像写放大）③小块读退化。

---

## 三、后续调优计划

> 原则（不变）：不影响业务（157 内核不动、100GbE 网卡/驱动/RoCE QoS 不动）；一次一个变量；对账原始 fio；只认冷态一致轮；改动前后留原始日志。提交推送前经用户确认（`skills/doc-publish-rule.md`）。

### 阶段1（已完成）

- **阶段0**：环境/脚本修复（meta 节点4 通信、7.x 采集、iopsget、递归 bug），可信 v2 基线建立。任务书 `doc/perf-tasks/stage0-task-book.md`。
- **阶段1（单流写）**：接口锁定定案（§2.1）+ 单变量矩阵穷举（§2.2），结论为单流写应用层调优无正收益。任务书 `doc/perf-tasks/stage1-task-book.md`（及 restart-repro / lock-rdma-iface 两份专项）。

### 阶段2（进行中）：双口径基线重测，建立统一汇报口径

- 任务书：`doc/perf-tasks/stage2-dual-baseline-task-book.md`。
- 在 RDMA 锁定态下重跑全矩阵，产出两套基线表：①100GbE RDMA 不限速占比表（÷12500，50% 线 6250）②千兆限速表（eno12409 TBF 1Gbps，÷118，对齐 JuiceFS ≥59MB）。
- 每项标注是否达 50%；未达标项给数据支撑（单流读写引 §2.2 per-IO 延迟分解；randwrite 引镜像 2× 写放大；小块读附 64K/256K/1M sweep）。
- ⚠️ 限速口径数据面走 eno12409，需临时改 connInterfacesFile，测完务必恢复 RDMA 锁定（步骤见 `skills/beegfs-baseline-config.md` §1.6）。

### 阶段3（规划）：聚焦未达标的带宽主导项

有真实优化空间的项（区别于延迟主导、物理天花板的单流项）：

- **randwrite（49% → 提升）**：非镜像子目录（`--setpattern --pattern=raid0 --numtargets=3/6`）对照量化 Buddy Mirror 2× 写放大真实代价；`tuneStorageThreadsPerTarget`、XFS `allocsize` 对照。**不改生产镜像配置，仅测量对照。**
- **小块读退化（randread 64K 39%）**：slave 侧 read_ahead_kb（256/1024/8192）、iodepth、chunksize 与小块读关系；仍限 BeeGFS 应用层 / slave 端，不动网卡。

### 阶段4（可选）：暖态基线与业务对比

- 补暖态基线（不 direct、不 drop）界定重复访问上限；同口径 vs JuiceFS+Ceph 终版对比。

### 不再作为可调优项（有数据支撑，写入汇报）

- **单流读/写**：延迟主导（§2.2），换网卡/调应用层参数均无法提升占比，物理天花板。以 per-IO 延迟分解作为"为什么达不到 50%"的说明。
- **157 共部署拆分**：0.6 已证当前负载下 157 共部署非瓶颈（BeeGFS 服务测试期间近 0% CPU）。默认不做。
