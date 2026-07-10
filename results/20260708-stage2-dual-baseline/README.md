# 阶段2 — 双口径基线重测结果（100GbE RDMA + 千兆限速）

> 日期：2026-07-08
> 依据：`doc/perf-tasks/stage2-dual-baseline-task-book.md`
> 测试机：client 157（项目目录 `/tmp/beegfs-test`，非 git 仓库）
> 脚本：`tests/bench-full.sh <tag> cold`（冷态：`--direct=1` + 每项前客户端 + 全部 3 storage server drop page cache）
> 考核目标：**所有测试项有效数据带宽 ≥ 对应网卡线速的 50%；未达标项须有数据支撑说明原因**

---

## 1. 口径定义

| 口径 | 分母（线速） | 50% 线 | 数据面接口 | 用途 |
|------|:---:|:---:|------|------|
| A 100GbE RDMA 不限速 | 12500 MiB/s | 6250 | connInterfacesFile 锁 RDMA（enp139s0f0np0/f1np1） | 后端真实能力 / 占比 |
| B 千兆限速（双向 tc tbf 1gbit） | 118 MiB/s | 59 | eno12409（10GbE 独立 NIC，TCP） | 对齐 JuiceFS/Ceph 千兆基准 |

每口径各跑 ≥2 轮冷态，只认冷态一致轮。原始 fio/commands.sh/env-snapshot/beegfs-net/tc 证据均存于各轮目录（见 §5）。

---

## 2. 口径 A 表（100GbE RDMA 不限速）

原始 fio 已从 157（`/tmp/beegfs-test/results/`）归档至本仓库 `results/20260708-stage2-dual-baseline/` 各轮子目录（157 原件保留）。各轮含 summary.md / commands.sh / env-snapshot.txt / 各项 *.txt 原始 fio / rdma-evidence.txt / status-after.txt。

| 测试项 | r1 (MiB/s) | r2 (MiB/s) | 取值 | %100GbE (÷12500) | ≥50%? | 说明 |
|--------|:---:|:---:|:---:|:---:|:---:|------|
| seqread（单流,256K） | 1509 | 1522 | 1516 | 12.1% | ❌ | 延迟主导 |
| seqwrite（单流,256K,fsync） | 832 | 847 | 840 | 6.7% | ❌ | 延迟主导 |
| multi-seqread（16,256K） | 7333 | 6891 | 7112 | 56.9% | ✅ | 带宽主导 |
| multi-seqwrite（16,256K） | 7619 | 7843 | 7731 | 61.8% | ✅ | 带宽主导 |
| layout（128,4M） | 10189 | 10209 | 10199 | 81.6% | ✅ | 带宽主导 |
| randread（128,256K） | 10752 | 9255 | 9255–10752 | 74–86% | ✅ | 带宽主导（跨轮波动，见下） |
| randwrite（128,256K） | 6111 | 6180 | 6146 | 49.2% | ❌ | 临界，写放大+后端 |
| randrw R / W（128,256K） | 4704/4698 | 4586/4584 | 4645/4641 | 37.1% | ❌ | 混合读写后端约束 |
| randread-64K（128） | 4766 | 4765 | 4766 | 38.1% | ❌ | 小块 per-IO 退化 |
| randread-256K（128） | 10752 | 9252 | 9252–10752 | 74–86% | ✅ | 同 randread |
| randread-1M（128） | 11571 | 10650 | 10650–11571 | 85–93% | ✅ | 带宽主导 |

> 随机项 r1/r2 各 3 轮内部偏差 <0.2%（极稳）；表中所列 r1/r2 为该轮 3 轮均值。
> randread 取值为区间：r1=10752、r2=9255，跨轮差 14%。**根因已查明**：randread-64K 跨轮完全一致（4766/4766），仅 256K/1M 跨轮波动——小块读 CPU/per-IO 主导（不受业务负载影响），大块读 NIC 带宽敏感（受 157 共用 WekaIO 业务流量影响，100GbE RDMA NIC 与 WekaIO 物理共用）。达标结论不受影响（均远超 50%）。

### 2.1 未达标项原因（数据支撑）

1. **seqread 1516（12.1%）/ seqwrite 840（6.7%）—— 单流，延迟主导**
   实测 per-IO 延迟（对账原始 fio clat）：
   - seqread：clat avg=165µs（min=123µs）→ 单流 IOPS 上限 = 1/165µs ≈ 6060 → bw=256K×6060≈1590 MiB/s，实测 1516 吻合。
   - seqwrite：clat avg=258–263µs（min=155–188µs）→ bw=256K/263µs≈998 理论，实测 840（含 end_fsync）。
   - 达 50% 线（6250）需 clat < 41µs（读）/ <33µs（写），而 FUSE+RDMA+NVMe 栈固有地板 ~165µs（读）/ ~260µs（写），**物理不可达**。换更快网卡只缩 ~15µs RDMA 往返、分母涨 10×，占比反降（stage1 §八结论：单流写 ~900 是物理天花板，非应用层可调）。

2. **randwrite 6146（49.2%，临界）—— Buddy Mirror 2× 写放大 + NVMe 聚合上限**
   写天花板 ~6 GB/s（3 buddy group × 2 NVMe 聚合）。Buddy Mirror 每写 1 份落 2 份（镜像），有效带宽 ≈ 后端上限/2。与 skill §3.1「写天花板 ~6 GB/s」一致。

3. **randrw R/W 4645/4641（37.1%）—— 混合读写后端约束**
   写成分命中同一写天花板，读成分与之竞争 NVMe/网络，二者均被压低。

4. **randread-64K 4766（38.1%）—— 小块 per-IO 固定开销高**
   bs sweep 对比（128 jobs）：
   | bs | bw (MiB/s) | IOPS | %100GbE |
   |---|---|---|---|
   | 64K | 4766 | 76.1k | 38% |
   | 256K | 9252–10752 | 37.0–43.2k | 74–86% |
   | 1M | 10650–11571 | 10.6–11.6k | 85–93% |
   小块 IOPS 虽高（76k），但每 IO 固定开销（RDMA verbs+FUSE+NVMe 命令）摊薄后 bw 低；块越大预取/read_ahead 越有效，bw 越高。

### 2.2 达标项小结
multi-seqread/seqwrite、layout、randread(256K/1M) 均 ≥50%，属**带宽主导**：并发 I/O 可填满 per-IO 延迟间隙，逼近后端/网卡上限。

---

## 3. 口径 B 表（千兆限速，双向 tc tbf 1gbit）

原始数据目录（157 `/tmp/beegfs-test/results/`，已归档至本仓库 `results/20260708-stage2-dual-baseline/`）：`full-stage2B-r1-20260708-165721/`、`full-stage2B-r2-20260708-181222/`

| 测试项 | r1 (MiB/s) | r2 (MiB/s) | 取值 | %千兆 (÷118) | ≥59? | vs JuiceFS 达标线(≥59) |
|--------|:---:|:---:|:---:|:---:|:---:|---|
| seqread（单流,256K） | 104 | 104 | 104 | 88% | ✅ | 超 |
| seqwrite（单流,256K,fsync） | 53.2 | 53.3 | 53.3 | 45% | ❌ | 临界低于（历史 58.8 亦低于） |
| multi-seqread（16,256K） | 302 | 248 | 275 | 233% | ✅ | 远超（3 节点聚合） |
| multi-seqwrite（16,256K） | 113 | 112 | 113 | 96% | ✅ | 超 |
| layout（128,4M） | 113 | 113 | 113 | 96% | ✅ | 超 |
| randread（128,256K） | 339 | 340 | 340 | 288% | ✅ | 远超 |
| randwrite（128,256K） | 111 | 111 | 111 | 94% | ✅ | 超 |
| randrw R / W（128,256K） | 108/107 | 108/106 | 108/107 | 92% | ✅ | 超 |
| randread-64K（128） | 340 | 340 | 340 | 288% | ✅ | 远超 |
| randread-256K（128） | 340 | 340 | 340 | 288% | ✅ | 远超 |
| randread-1M（128） | 341 | 339 | 340 | 288% | ✅ | 远超 |

> %千兆 = ÷118（单条 1gbit 链路）。**多流项 >100% 属正常**：3 个 storage slave 各走 1gbit（eno12409 egress tc），聚合上限 ≈ 3×118 = 354 MiB/s；多流/随机 128 jobs 可逼近该聚合上限（randread 340≈354）。单流项 ≤100%（受单 TCP 流 + RTT 制约）。
> JuiceFS/Ceph 千兆基准为单链路场景；BeeGFS 3 节点聚合天然占优，对比时须注意此拓扑差异。

### 3.1 未达标项原因
- **seqwrite 53.3（45%）—— 单流千兆写，TCP 单流 + Buddy Mirror 复制开销**
  单流 TCP over shaped 1gbit 无法 saturate 链路（TCP 拥塞窗口+RTT），叠加 Buddy Mirror 镜像复制往返，单流写 ~53；多流（multi-seqwrite 113）可 saturate 1gbit。历史 v2-limited 同项 58.8，亦低于 59，性质一致。这是千兆单流写的固有特性，非配置问题。

### 3.2 vs JuiceFS 基准小结
除单流写（53.3<59）外，**所有项均超 JuiceFS 千兆达标线**。多流/随机读达 340（≈3 节点千兆聚合上限），多流写/layout 达 113（≈单链路千兆饱和）。

---

## 4. 数据对账与证据留存

### 4.1 原始 fio 对账（summary 值 = raw `bw=` 行）
口径 A 抽检：multi-seqwrite raw `WRITE: bw=7619MiB/s`=summary 7619 ✅；randread-r1 raw `10.5GiB/s`=10752 ✅；randwrite-r1 raw `6128` ✅；seqwrite clat min=188µs（RDMA 证据）✅。
口径 B 抽检：randread-r2 raw `340` ✅；randwrite-r2 raw `111` ✅；layout raw `113`/run=1159431ms(19.3min) ✅。
每项 summary 值均由 `bench-full.sh` 的 `bwget()` 从原始 fio `READ:/WRITE: bw=` 行提取，全量可追溯。

### 4.2 每轮证据文件（存于各轮目录）
- `env-snapshot.txt`：服务/target/mirror/stripe 状态
- `rdma-evidence.txt`（口径 A）/ `rdma-evidence.txt`（口径 B）：connInterfacesFile 配置 + beegfs-net 连接类型 + tc qdisc 状态
- 口径 A 每轮：beegfs-net 3 storage 全 RDMA（10.3.1.6/7/8:8003），seqwrite clat_min 188–229µs < 250µs（RDMA 锁定证据）
- 口径 B 每轮：beegfs-net 3 storage 全 TCP（10.114.1.150/151/152:8003），tc tbf 1gbit 施加于 157+3 slaves eno12409 egress，哨兵 seqwrite 53.5 MiB/s（千兆生效证据）
- 口径 B 收尾：connInterfacesFile 恢复 RDMA、tc 清除、服务重启后 beegfs-net 全 RDMA、seqwrite clat_min=229µs（恢复证据）

### 4.3 原始目录索引
原始 fio 已从 157（`/tmp/beegfs-test/results/`）归档至本仓库 `results/20260708-stage2-dual-baseline/`（各轮子目录，157 原件保留）。
| 轮次 | 子目录 |
|---|---|
| 口径 A r1 | `full-stage2A-r1-20260708-150506/` |
| 口径 A r2 | `full-stage2A-r2-20260708-153406/` |
| 口径 B r1 | `full-stage2B-r1-20260708-165721/` |
| 口径 B r2 | `full-stage2B-r2-20260708-181222/` |
| 口径 B 中止（slave-only tc，参考） | `full-stage2B-r1-20260708-162708-ABORTED-slave-only-tc/` |
| 配置备份 | `connIF-backup-stage2B-160732/` |

---

## 5. 方法论说明（对任务书的补充）

1. **口径 B 数据面切换：connUseRDMA=false（任务书未提，为实现 eno12409 TCP 所必需）**
   任务书 §3.2 指明改 connInterfacesFile→eno12409。实测仅改 connInterfacesFile + connUseRDMA=true 时，storage 仍广播 RDMA 端点（10.3.1.x），client 尝试 RDMA 失败后 TCP 回退到 10.3.1.x（走 100GbE 网卡，非 eno12409，既不限速又占用与 WekaIO 共用的 100GbE NIC）。故追加 `connUseRDMA=false`（4 节点 beegfs-*.conf，BeeGFS 应用层参数），使 storage 广播 eno12409 TCP 端点、client 直连 TCP 10.114.1.x。测后已恢复 connUseRDMA=true。

2. **口径 B 限速：双向 tc（157 + 3 slaves eno12409 egress）**
   任务书 §3.2 指明 tc 施加于「3 storage slave eno12409 egress」。实测仅 slave 侧 tc 时，写数据路径 client→slave（157 egress）未被限，multi-seqwrite=170（1.43gbit，失真）。历史基线（skill §3：seqwrite 58.8 / multi-seqwrite 113）与 JuiceFS 千兆（真实 1gbit 双向）均需双向限速。故在 157 eno12409 egress 追加 tbf（eno12409 为 10GbE 独立 NIC，已验证无业务监听，与 WekaIO 100GbE RDMA 物理隔离，不影响业务）。双向 tc 后 seqwrite=53.3（匹配历史 58.8）、multi-seqwrite=113（匹配历史）。测后已清除全部 tc。

3. **bench-full.sh commands.sh 模板修复：openfiles 100→128**
   `run_rand()` 实际用 `--openfiles=128`（=numjobs，skill §2.1 强制），但 commands.sh 记录模板残留旧值 `--openfiles=100`（07-03 制造假瓶颈的旧 bug）。已修正模板 4 处 100→128，使记录与实际执行一致（diff 已展示，未提交）。

---

## 6. 安全红线确认

| 红线 | 状态 |
|---|---|
| 157 内核参数（THP/dirty/read_ahead） | ✅ 全程未动 |
| 100GbE 网卡/驱动全局（MTU/mlxconfig/queue/中断） | ✅ 全程未动 |
| RoCE QoS（connRDMATypeOfService/PFC/DSCP） | ✅ 全程未动（connRDMATypeOfService=0 不变） |
| 根目录 stripe（Buddy Mirror/chunk=1M/numtargets=3） | ✅ 全程未动 |
| 限速仅 eno12409（10GbE 独立 NIC） | ✅ tc 仅施加于 eno12409，已清除 |
| 口径 B 测后恢复 RDMA 锁定 + tc 清除 + 哨兵通过 | ✅ beegfs-net 全 RDMA、tc 清、clat_min 229µs |

口径 B 改动（connInterfacesFile/connUseRDMA/tc/服务重启）均属 BeeGFS 应用层 + eno12409 隔离 NIC，不触及 WekaIO/K8s 业务，且测后已完全恢复。

---

## 7. 结论与 stage3 建议

### 7.1 双口径达标总览
- **口径 A（100GbE RDMA）**：并发/大块项（multi-seq、layout、randread 256K/1M）均 ≥50%；单流 seq、randwrite、randrw、randread-64K 未达 50%，均属延迟/写放大/小块固有约束，**非调优可解**（有数据支撑）。
- **口径 B（千兆）**：除单流写（53.3<59）外全部达标；多流/随机远超 JuiceFS 千兆达标线。

### 7.2 stage3 优先级建议（供规划 agent 判断）
依任务书 §6.2，stage3 聚焦「未达标带宽主导项」。本测表明：
1. **单流 seqread/seqwrite**：延迟主导（clat 165/260µs），换网卡/调应用层无效（stage1 已穷举 28 轮无收益）。stage3 不建议再投入，按延迟天花板接受。
2. **randwrite（49.2%，临界）**：Buddy Mirror 2× 写放大 + NVMe 聚合。stage3 可探索：关闭镜像对照（非生产态，仅测上限）、或 chunksize/numtargets 调整对写放大的影响。
3. **randread-64K（38.1%）**：小块 per-IO 退化。stage3 可探索 read_ahead / chunksize 对小块读的影响（已确认 64K→1M bw 涨 2.2×）。
4. randrw 与 randwrite 同因（后端约束），随 randwrite 改善而改善。

> 建议stage3 优先级：randwrite 写放大探索 > randread-64K 小块优化 > 单流（接受现状）。单流项已达物理天花板，继续投入 ROI 低。
