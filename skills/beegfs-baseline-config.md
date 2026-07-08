---
name: beegfs-baseline-config
description: 使用于任何 BeeGFS 生产集群的性能测试、调优对照、基线复核、回归验证场景。本 skill 固化 2026-07-07 确立的官方基线配置（slave 端系统调优 + RDMA + 镜像 stripe）、基线测试方法（冷态 direct=1 + 客户端与服务端 drop cache）与当前最优值（v2 健康基线）。任何"这个数正常吗 / 该和什么比 / 基线配置是什么 / 怎么复现基线"的问题都应先读本 skill。触发词：基线, baseline, 调优对照, 最优值, 基线配置, 基线测试, 回归, v2, 控制变量对照锚点。
---

# BeeGFS 基线配置与基线测试方法 skill

> ⚠️ **2026-07-08 定案（读这条即可，取代 07-07 的中间结论）**：单流写"835 vs 479"之谜已彻底查清——**479 = BeeGFS 数据面掉到 10GbE TCP 网卡（eno12409, 10.114.1.x）；900 = 走 100GbE RDMA（10.3.x）**。根因：`connInterfacesFile` 曾被清空导致 client 自动选接口，小概率落到 TCP。**已锁定 `connInterfacesFile` 只用 RDMA 网卡（见第一节 1.5），5/5 次重启 100% 走 RDMA，seqwrite 稳定 889-909（clat_min ~215µs）。当前单流写基线 = ~900 MiB/s，可保证、可复现。** 原"slave 调优 +78%"作废（实为 TCP↔RDMA 之差，非调优）；dirty_ratio 对 `--direct=1` 无效。详见第五节。
> **stage1 单流写应用层调优已收官**（`results/20260708-stage1-single-write/`，28 轮 B/C/D/E 全无正收益，per-IO ~273µs 延迟主导）。**考核目标已重定义为"有效带宽 ≥ 网卡线速 50%"，双口径（100GbE RDMA + eno12409 千兆限速）见 §1.6。**
>
> 确立日期：2026-07-08（原 07-07 v2 基线的 seqwrite 已由本次定案取代为 900/RDMA 锁定态）
> 本 skill 是后续所有调优实验的**对照锚点**。任何新测试的数值都应与"当前最优值"表比对，任何调优改动都应在本基线配置之上做单变量变更。

---

## 一、基线配置（固定，勿随意改）

### 1.1 集群与网络
- 4 节点 BeeGFS 7.3.2：157(mgmtd+meta+client) / 150·151·152(meta + 2 storage targets)
- 镜像：metadata 2 buddy groups + storage 3 buddy groups
- Stripe：**Buddy Mirror, chunksize=1M, numtargets=3**（根目录 setpattern）
- **数据通道 = 100GbE RDMA/RoCE**（`connUseRDMA=true`，Mellanox mlx5_0/mlx5_1，Rate 100）
  - ⚠️ **该网卡与 WekaIO 业务物理共用**（同一 uverbs 设备）。见第四节安全红线。
- 限速对比：走独立网卡 `eno12409` + `tc tbf rate 1gbit` 模拟千兆（不影响 RDMA 数据面）

### 1.2 系统调优（**仅 3 个 slave 生效；157 保持默认，保护业务**）

> ⚠️ 原表注"slave 端调优对单流写 +78%"已作废（见顶部与第五节）——该收益实为服务重启所致。slave 调优对单流写的真实收益**未定**（dirty_ratio 对 direct write 无效已实证）；对并发大块写 layout 仅 +2.5%。下表仅作为**当前基线配置的记录**，不代表已验证的收益。

| 参数 | slave (150/151/152) 基线值 | 157（业务节点，不调） |
|------|:---:|:---:|
| THP | `always` | `madvise`（默认） |
| THP defrag | `always` | `madvise` |
| vm.dirty_background_ratio | 5 | 10 |
| vm.dirty_ratio | 10 ⚠️（对 direct=1 单流写无效，见第五节）| 20 |
| vm.vfs_cache_pressure | 50 | 100 |
| vm.min_free_kbytes | 262144 | 129996 |
| vm.zone_reclaim_mode | 1 | 0 |
| read_ahead_kb (nvme1/2/3) | 4096 | 256/128 |
| max_sectors_kb (数据盘) | 256 | 1024/1280 |
| IO scheduler (NVMe) | none（内核强制） | none |
| fd-limit | 1000000 | 1048576 |

> 已知无效项：`nr_requests=4096` 在 NVMe 报 `Invalid argument`（被 `tune-servers.sh` 的 `|| true` 吞掉），**从未生效**，NVMe 实际 nr=1023。CPU governor 该环境 `N/A`。

### 1.3 BeeGFS RDMA 参数（client + meta，基线值）
- `connUseRDMA = true`
- `connRDMABufNum = 70`
- `connRDMABufSize = 8192`
- `connRDMATypeOfService = 0`
- 内存占用 = `BufSize × BufNum × 2` per connection

### 1.4 应用方式
- slave 调优：`tune-servers.sh`（scp 到各 slave，`sudo bash` 执行）
- 回退/恢复（对照实验用）：`tests/revert-tuning.sh` / `tests/restore-tuning.sh`（仅 runtime 参数，不重启服务）

### 1.5 网络接口锁定（**关键，必须固定，否则单流写会不定期掉到 479**）

157 有多块网卡：`enp139s0f0np0`/`enp139s0f1np1`=100GbE RDMA(10.3.x)，`eno12409`=10GbE TCP(10.114.1.x)，`eno12399`=管理网(10.20.1.x)。storage 节点在 mgmtd 同时注册了 RDMA 与 TCP 接口。

**若 `connInterfacesFile` 为空，client 自动选接口——大概率选 RDMA(900)，但小概率落到 eno12409 的 10GbE TCP → 单流写掉到 ~479、clat_min 翻倍到 400µs（07-06 20:23 曾发生）。**

**基线固定**（157 + 3 slave 均设，`results/20260708-lock-rdma-iface/` 验证 5/5 重启 100% RDMA）：
- 新增 `/etc/beegfs/connInterfacesFile.conf`，内容两行：`enp139s0f0np0` 和 `enp139s0f1np1`
- client.conf + meta.conf（slave 的 storage.conf + meta.conf）设 `connInterfacesFile = /etc/beegfs/connInterfacesFile.conf`
- 回滚：恢复 `.conf` 备份（值置空）+ 删该文件 + 重启服务

### 1.6 双口径考核目标（**2026-07-08 决策，取代"追绝对带宽"**）

**目标：所有测试项有效数据带宽 ≥ 对应网卡线速的 50%。未达标项须有数据支撑说明原因（延迟主导/缓存/后端约束），不只报绝对值。**

背景：100GbE RDMA 替代 10GbE TCP 后单流写绝对值翻倍（479→900）但占线速比反降（38%→7%），因单流写延迟主导（clat ~273µs），换快网卡只缩 ~15µs RDMA 往返、分母涨 10×。故不追绝对带宽，改看占比。

| 口径 | 分母（线速） | 50% 线 | 数据面接口 | 用途 |
|------|:---:|:---:|------|------|
| A 100GbE RDMA 不限速 | 12500 MiB/s | 6250 | connInterfacesFile 锁 RDMA | 后端真实能力/占比 |
| B 千兆限速 | ~118 MiB/s | 59 | **eno12409 + tc tbf 1gbit** | 对齐 JuiceFS/Ceph 千兆基准 |

**口径 B 的接口切换（限速测试时）**：限速施加在 `eno12409`（10GbE 独立网卡，与 WekaIO 100GbE RDMA 物理隔离，不影响业务），数据面须走该网卡，因此**临时改 connInterfacesFile**（指向 eno12409 或置空走 TCP）→ 重启服务 → 测 → **测完务必恢复 §1.5 的 RDMA 锁定**。绝不在 100GbE RDMA 网卡上限速/QoS。任务书见 `doc/perf-tasks/stage2-dual-baseline-task-book.md`。

---

## 二、基线测试方法（冷态口径，固定）

### 2.1 口径定义
- 脚本：`tests/bench-full.sh <tag> cold`
- 冷态：`--direct=1` + 每项前 `drop_all_caches`（**客户端 + 全部 3 个 storage server 都清 page cache**，客户端清不掉服务端 XFS 缓存）
- 顺序 bs=256K（单线程 + 16 线程）；随机 128 jobs × iodepth=128 × 60s × 3 轮；bs sweep 64K/256K/1M
- layout：128 jobs × 1G = 128G, bs=4M
- **`--openfiles=128`（必须 = numjobs，07-03 用 100 制造过假瓶颈）**

### 2.2 测前检查（见 `skills/TESTING-GUIDE.md`）
- 4 meta + 6 storage target 全 GOOD（`beegfs-ctl --listtargets --state --nodetype=meta/storage`，7.x **不带** `--mgmtd_node`）
- 无 fio 残留、磁盘空间足（layout 需 128G+）、mount 正常

### 2.3 数据可信度规则（见 `skills/perf-review-planning/SKILL.md`）
- 结论数对账原始 fio：带宽 `READ:/WRITE: bw=`；IOPS 小写 `read:/write: IOPS=`；写延迟 slat/clat
- 只认冷态 R1；随机项三轮偏差应 <1%（高吞吐写因 RDMA 完成波动可略高，如 randwrite 3.1%）
- **RDMA 流量不进 `/proc/net/dev`**（走 verbs），监控需 `/sys/class/infiniband/mlx5_*/ports/*/counters/` 或 `ibstat`
- 单流读首轮若异常低（如首日 565），多为部署后 RDMA 连接/元数据冷启动，非稳定值

---

## 三、当前最优值（v2 健康基线，冷态 direct=1，单位 MiB/s）

> 来源：`results/20260707-beegfs-cold-baseline-v2/unlimited/full-v2-cold-unlimited-20260706-184425/`，全部对账 raw。

| 测试 | 不限速(RDMA) | 限速(1Gbps TBF) | 关键延迟/IOPS |
|------|:---:|:---:|------|
| seqread(单流) | **1585** | 113 | clat 157µs |
| seqwrite(单流,fsync) | ~~835~~ → **~900**（RDMA 锁定态，889-909，clat_min ~215µs）| 58.8 | 见 1.5；**必须走 RDMA，走 10GbE TCP 则掉到 ~479** |
| multi-seqread(16) | **6874** | 302 | |
| multi-seqwrite(16) | **8214** | 113 | |
| layout(128,4M) | **10240** | 113 | IOPS 2566 |
| randread(128) | **8227** | 340 | 三轮 0.08%, IOPS 32.9k |
| randwrite(128) | **6138** | 112 | 三轮 3.1%, IOPS 24.6k, slat 5.2ms |
| randrw R/W | **4602/4599** | 110/108 | IOPS 18.4k/18.4k |
| randread-64K | **4789** | 340 | IOPS 76.6k（小块仍偏低）|
| randread-256K | **8227** | 340 | |
| randread-1M | **8807** | 339 | IOPS 8800 |

### 3.1 已知瓶颈排序（后续调优对象）
1. **单流写 ~900**（RDMA 锁定态；vs 并发写 6138，~6.8×）—— 延迟主导（clat ~275µs）。原"slave dirty_ratio +78%"作废（实为 RDMA↔TCP 之差）。仍是首要优化方向，stage1 在此基线上做单变量。
2. **写天花板 ~6 GB/s** —— Buddy Mirror 2× 写放大 + NVMe 落盘（非网络）
3. **小块随机读 randread-64K 4789** —— per-IO 固定开销高
4. 读天花板 ~8.2 GB/s，读侧无明显瓶颈

---

## 四、调优安全红线（因网卡与 WekaIO 共用，**贯穿所有调优**）

| 层级 | 例子 | 可否动 |
|------|------|:---:|
| BeeGFS 应用层缓冲 | `connRDMABufNum/BufSize`、`tuneNumWorkers`、chunksize | ✅ 可调（只影响 BeeGFS），重启服务限**业务低峰** |
| slave 内核参数 | dirty_ratio、read_ahead（仅 150/151/152） | ✅ 可调（157 不动） |
| RoCE QoS | `connRDMATypeOfService`、PFC/DSCP | ⚠️ 与 WekaIO 共享，默认不动 |
| 网卡/驱动全局 | MTU、mlxconfig、queue、中断亲和 | ❌ 禁止（WekaIO 立即受影响） |
| 157 内核参数 | THP/dirty/read_ahead | ❌ 禁止（K8s+WekaIO 在跑） |

**总原则：只改 BeeGFS 应用层 / slave 端；不动 157 内核、不动网卡/驱动/RoCE QoS；BeeGFS 服务重启限业务低峰。**

---

## 五、单流写"835 / 479 / 900"之谜的完整定案（2026-07-08）

**BeeGFS 为纯测试集群（业务在独立的 WekaIO 上），可自由多次重启。**

### 5.1 排查时间线
| 时刻 | 事件 | seqwrite | clat_min | 走哪条网络 |
|------|------|:---:|:---:|------|
| 07-06 18:44 | v2 基线 | 835 | 200µs | RDMA |
| **07-06 20:23** | 重启 + **清空 connInterfacesFile** | - | - | - |
| 07-07 11:47~14:05 | 复测（低态）| 466-508 | ~400µs | **10GbE TCP（eno12409, 10.114.1.x）** |
| 07-07 16:23 起 | 33 次测量（16h+8 重启）| 887-944 | ~200µs | RDMA（自动选中）|
| 07-08 | **锁定 connInterfacesFile 只用 RDMA** | **889-909** | ~215µs | **RDMA（100%，5/5 重启）** |

### 5.2 定案根因（`results/20260707-restart-repro/` + `results/20260708-lock-rdma-iface/`）
- **479 = 数据面掉到 10GbE TCP 网卡**（eno12409/10.114.1.x），不是走 100GbE RDMA。10GbE 单流 TCP ≈ 479 MiB/s，clat_min 翻倍（TCP 栈 ~200µs + NVMe ~200µs）。
- **900 = 走 100GbE RDMA**（10.3.x）。
- **触发**：`connInterfacesFile` 被清空 → client 自动选接口 → 大概率 RDMA（33/34 次），07-06 20:23 那次小概率落到 TCP。
- **修复**：锁定 `connInterfacesFile` 只列 RDMA 网卡（见 1.5），479 态永久消除，900 成为可保证基线。

### 5.3 连带修正（已作废的旧结论）
- ❌ "slave 调优对单流写 +78%（466→835）"**作废**：466(TCP) vs 835(RDMA) 是网络路径之差，非 slave 调优。对照实验碰巧一组走 TCP 一组走 RDMA。
- ❌ "v2 单流写 835 / 复测 479 为基线"**均作废**：二者分别是 RDMA/TCP 两种路径的值。**当前唯一有效单流写基线 = ~900（RDMA 锁定态）**。
- ✅ layout +2.5%、dirty_ratio 对 direct=1 无效、100GbE RDMA、共用网卡红线等结论不变。

### 5.4 测试方法固化教训
1. **每次测前用 `beegfs-net` 确认 3 个 storage 全走 `RDMA (10.3.x)`**，且 seqwrite clat_min < 250µs——这是"高态哨兵检查"，防止在 TCP 态误采数据。
2. 记录各 BeeGFS 服务 ActiveEnterTimestamp（运行时长）。
3. 单变量对照实验必须保证两组处于相同网络路径 + 相同服务运行态，否则结论无效（+78% 就是反例）。
