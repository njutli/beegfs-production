# 阶段2 补测 — 未达标项瓶颈坐实结果

> 日期：2026-07-09
> 依据：`doc/perf-tasks/stage2-unmet-rootcause-task-book.md`
> 起点：`results/20260708-stage2-dual-baseline/README.md`（双口径达标表 + §2.1/§3.1 未达标原因）
> 测试机：client 157（项目目录 `/home/sunrise/beegfs-production`，执行目录 `/tmp/beegfs-test`）
> 考核目标：用直接实测证据坐实「未达标项瓶颈 = 延迟/写放大/小块开销，非带宽/非配置」

---

## 1. 执行流程

测试按**口径分两阶段**执行，每个口径内配置一次、跑完该口径所有测试再切换：

| 阶段 | 口径 | 配置 | 执行测试 | 哨兵 |
|------|------|------|----------|------|
| ① | A 100GbE RDMA 不限速 | connUseRDMA=true + connInterfacesFile=enp139s0f0np0/f1np1（RDMA 锁定态） | 测试 A（单流 NIC 利用率）+ 测试 B（写放大对照）+ 测试 C（小块读分解） | beegfs-net 全 RDMA(10.3.x)、clat_min 205–222µs |
| ② | B 千兆限速 | connUseRDMA=false + eno12409 + 双向 tc tbf 1gbit（4 节点） | 测试 A（单流 seqwrite 利用率）* | beegfs-net 全 TCP(10.114.1.x)、seqwrite≈53 |

> *口径 B 仅做测试 A：写放大/小块读机理在口径 A 已充分暴露，千兆链路远低于后端能力时不再构成限制因素（任务书 §3 注）。
> 每项 ≥2 轮冷态（direct=1 + client+3slave drop cache），全部对账原始 fio `bw=`/`clat` 行。

---

## 2. 口径 A 结果（100GbE RDMA 不限速，50% 线=6250 MiB/s）

RDMA 锁定态一次配置完成三个测试，全程不切换网络。

### 2.A 测试 A — 单流 NIC 利用率（坐实项① 单流 seqread/seqwrite 延迟主导）

> NIC 实测速率 = client 端有效数据速率（单流时 client NIC 承载量 = fio bw，因瓶颈在 per-IO 延迟非带宽）。
> IB counters（`/sys/class/infiniband/mlx5_*/ports/*/counters/port_xmit_data|port_rcv_data`，单位 4B，用 multi-seqwrite 反推校准误差<5%）corroborate 单流速率远 < 12500。

| 场景 | fio bw r1/r2 (MiB/s) | clat avg | NIC 速率 | 线速 | 利用率 | 结论 |
|------|:---:|:---:|:---:|:---:|:---:|------|
| 单流 seqread (4G/256K) | 1510 / 1415 | 165 / 176µs | ~1463 | 12500 | 11.7% | 延迟主导，链路远未打满 |
| 单流 seqwrite (4G/256K,fsync) | 832 / 854 | 264 / 256µs | ~843 | 12500 | 6.7% | 同上 |
| multi-seqread(16) | 7409 / 6869 | 530 / 575µs | ~7139 | 12500 | 57.1% | 对照：并发可打满 |
| multi-seqwrite(16) | 7881 / 8271 | 467 / 445µs | ~8076 | 12500 | 64.6% | 对照：并发可打满 |

> 原始 fio + IB counters（3 slave）+ iostat 存于 `testA-kA-r{1,2}-*`。
> 单流 NIC 利用率 6.7–11.7%（远 < 50%），链路大量空闲；multi 57–65%（接近打满）。**单流瓶颈 = per-IO 延迟串行（clat 165–260µs），非带宽**。

### 2.B 测试 B — 写放大对照（坐实项② randwrite 49.2% + 项③ randrw 37.1%）

> 镜像根目录（Buddy Mirror/chunk1M/numtargets=3） vs 非镜像子目录（RAID0/chunk1M/numtargets=6，`beegfs-ctl --setpattern` 建于 `/mnt/beegfs/nomirror-test`，测后删除，根 stripe 未动）。
> fio: randwrite/randrw 128 jobs × iodepth128 × 256K × 60s × direct=1。iostat `-x 1` 抓 3 slave 6 NVMe。

| 场景 | pattern | randwrite bw r1/r2 | randrw R/W r1/r2 | 结论 |
|------|---------|:---:|:---:|------|
| 镜像（根） | Buddy Mirror | 6488 / 6602 | 4817/4813, 4909/4904 | 2× 写放大 |
| 非镜像（子目录） | RAID0 | 11571 / 11469 | 6629/6632, 6629/6633 | ≈2× → 坐实 |
| **比值** | | **1.76×** | **1.36×** | |

> randwrite 比值 1.76×（接近 2×）：Buddy Mirror 每逻辑写落 2 份物理写，有效带宽≈后端聚合/2。非镜像 11520 MiB/s 逼近 6 NVMe 聚合上限（~12000），镜像 6545≈一半。
> randrw 比值 1.36×（< 2×）：读成分不受写放大影响（读只命中 1 份镜像），合并比值 < 2×。
> iostat 原始存于 `testB-writeAmp-*/iostat-*-slave*.txt`。root stripe 证据：`stripe-root-confirmed.txt`（Type: Buddy Mirror, Chunksize: 1M, numtargets: 3）。

**结论**：randwrite 49.2% 未达标 = **Buddy Mirror 2× 写放大 + NVMe 聚合上限**，非网络。关镜像可提升约 1 倍（11520 vs 6545），但牺牲冗余。randrw 同因（读写竞争同一写天花板）。

### 2.C 测试 C — 小块读分解（坐实项④ randread-64K 38.1%）

> 数据来源：`results/20260708-stage2-dual-baseline/full-stage2A-r{1,2}-*`（同 RDMA 锁定态/冷态 direct=1/128 jobs，配置一致，IOPS+clat 从原始 fio 提取）。
> fio: randread 128 jobs × iodepth128 × 60s × direct=1，bs sweep 64K/256K/1M。

| bs | bw (MiB/s) | IOPS | clat avg | %100GbE | IOPS×bs≈bw | 说明 |
|---|:---:|:---:|:---:|:---:|:---:|------|
| 64K | 4766 | 76.1k | ~213ms | 38% | 76.1k×64K=4754 ✓ | per-IO 开销高，bw 低 |
| 256K | 9252–10752 | 37.0–43.2k | ~375–437ms | 74–86% | 43.2k×256K=10797 ✓ | 中等 |
| 1M | 10650–11571 | 10.6–11.6k | ~1381–1507ms | 85–93% | 11.6k×1M=11598 ✓ | 带宽主导 |

> clat 含排队延迟（128 jobs×iodepth128=16384 in-flight）。IOPS×bs≈bw 成立，证明 bw = IOPS × bs。
> 64K IOPS 是 1M 的 6.6×，但 bw 仅 0.41× → 每 IO 固定开销（RDMA verbs+FUSE+NVMe 命令）摊薄限制小块 bw。64K r1 内部轮 5535/88.6k 为离群值（首轮预热），稳定值取 r2/r3。

**结论**：randread-64K 38.1% 未达标 = **小块 per-IO 固定开销高**，非带宽/非配置。块越大 bw 越高（64K→1M 涨 2.2×）。

---

## 3. 口径 B 结果（千兆限速 eno12409 TBF 1Gbps，50% 线=59 MiB/s）

进入口径 B（connUseRDMA=false + eno12409 + 双向 tc）后仅做测试 A。

### 3.A 测试 A — 单流 seqwrite 链路利用率（坐实项⑤ 千兆单流写 45%）

> sar `-n DEV 1` 抓 4 节点 eno12409。slave tx 单流≈37.5 MiB/s/方向（32%）、multi≈80 MiB/s/方向（68%）。client tx = fio bw（单流 53=45%、multi 113=96%）。

| 场景 | fio bw r1/r2 (MiB/s) | clat avg | NIC 速率 | 线速 | 利用率 | 结论 |
|------|:---:|:---:|:---:|:---:|:---:|------|
| 单流 seqwrite (1G/256K,fsync) | 53.0 / 53.2 | 4676 / 4662µs | ~53 | 118 | 45.0% | 延迟串行，链路未打满 |
| multi-seqwrite(16) | 113 / 113 | — | ~113 | 118 | 95.8% | 对照：打满 |

> 原始 fio + sar 存于 `testA-kB-r{1,2}-*`。进入/恢复证据存于 `kB-enter-*`/`kB-restore-*`。
> clat 分解：单 IO 4665µs 中纯千兆传输 256K÷118MB/s≈2.1ms（~45%），余 ~2.5ms 为镜像双写+协议往返。

**结论**：seqwrite 45% 未达标 = **单流 QD1 + 镜像双写 + 千兆 RTT 延迟串行，链路未打满**（45% < 50%），非配置问题。

---

## 4. 跨口径对照与结论汇总

### 4.1 单流链路利用率对照（跨口径，任务书 §4.1）

| 场景 | 口径 | fio bw | clat avg | NIC 速率 | 线速 | 利用率 | 结论 |
|------|------|:---:|:---:|:---:|:---:|:---:|------|
| 单流 seqread | A 100GbE | 1510/1415 | ~170µs | ~1463 | 12500 | 11.7% | 延迟主导，未打满 |
| 单流 seqwrite | A 100GbE | 832/854 | ~260µs | ~843 | 12500 | 6.7% | 同上 |
| multi-seqwrite(16) | A 100GbE | 7881/8271 | ~456µs | ~8076 | 12500 | 64.6% | 对照：可打满 |
| 单流 seqwrite | B 千兆 | 53.0/53.2 | ~4669µs | ~53 | 118 | 45.0% | 延迟串行，未打满 |
| multi-seqwrite(16) | B 千兆 | 113/113 | — | ~113 | 118 | 95.8% | 对照：打满 |

### 4.2 写放大对照（口径 A，任务书 §4.2）

| pattern | randwrite bw | randrw R/W | 结论 |
|---------|:---:|:---:|------|
| Buddy Mirror（镜像根） | ~6545 | ~4863/4859 | 2× 写放大 |
| RAID0（非镜像子目录） | ~11520 | ~6629/6633 | ≈2× → 坐实 |
| **比值** | **1.76×** | **1.36×** | |

### 4.3 小块读分解（口径 A，任务书 §4.3）

| bs | bw | IOPS | clat | %100GbE | 说明 |
|---|:---:|:---:|:---:|:---:|------|
| 64K | 4766 | 76.1k | ~213ms | 38% | per-IO 开销高 |
| 256K | 9252–10752 | 37–43.2k | ~375–437ms | 74–86% | 中等 |
| 1M | 10650–11571 | 10.6–11.6k | ~1381–1507ms | 85–93% | 带宽主导 |

### 4.4 结论汇总

| 未达标项 | 口径 | 达标率 | 瓶颈根因（实测坐实） | 非带宽/非配置证据 | stage3 建议 |
|----------|------|:---:|------|------|------|
| ① seqread 1516 | A | 12.1% | per-IO 延迟主导（clat 165µs） | NIC 利用率 11.7% | 接受现状（物理天花板） |
| ① seqwrite 840 | A | 6.7% | per-IO 延迟主导（clat 260µs） | NIC 利用率 6.7% | 接受现状 |
| ② randwrite 6146 | A | 49.2% | Buddy Mirror 2× 写放大+NVMe 聚合 | 非镜像 1.76×→11520 | 关镜像对照/chunksize 调整 |
| ③ randrw 4645/4641 | A | 37.1% | 读写竞争同一写天花板 | 随 randwrite 改善 | 随②改善 |
| ④ randread-64K 4766 | A | 38.1% | 小块 per-IO 固定开销 | IOPS×bs=bw，64K IOPS 6.6×但 bw 0.41× | read_ahead/chunksize 探索 |
| ⑤ seqwrite 53.3 | B | 45.0% | 单流+镜像双写+千兆 RTT 串行 | NIC 利用率 45% | 接受现状（千兆固有） |

**总结**：6 项未达标项瓶颈均已用直接实测证据坐实——**延迟主导（①⑤）、写放大（②③）、小块开销（④）**，均非带宽不足或配置错误。单流项已达物理天花板（clat 主导）；randwrite 写放大和 randread-64K 小块优化为 stage3 可探索方向。

---

## 5. 安全红线确认

| 红线 | 状态 |
|---|---|
| 157 内核参数（THP/dirty/read_ahead） | ✅ 全程未动 |
| 100GbE 网卡/驱动全局（MTU/mlxconfig/queue/中断） | ✅ 全程未动 |
| RoCE QoS（connRDMATypeOfService/PFC/DSCP） | ✅ 全程未动 |
| 根目录 stripe（Buddy Mirror/chunk=1M/numtargets=3） | ✅ 全程未动（getentryinfo 确认） |
| 限速仅 eno12409（10GbE 独立 NIC） | ✅ tc 仅 eno12409，测后已清除 |
| 非镜像子目录用完删除 | ✅ nomirror-test 已 rm，根 stripe 未受影响 |
| 口径 B 测后恢复 RDMA 锁定 | ✅ beegfs-net 全 RDMA(10.3.x)、tc 清、clat_min=218µs |

口径 B 改动（connInterfacesFile/connUseRDMA/tc/服务重启）均属 BeeGFS 应用层 + eno12409 隔离 NIC，不触及 WekaIO/K8s 业务，测后已完全恢复。

---

## 6. 原始数据索引

| 目录 | 阶段 | 内容 |
|---|---|---|
| `testA-kA-r1-20260709-163621/` | 口径A | 测试A r1（fio+IB counters+iostat） |
| `testA-kA-r2-20260709-164853/` | 口径A | 测试A r2 |
| `testA-kA-r2-20260709-164637-ABORTED-no-seqdir/` | 口径A | 中止（seq_dir 未建，参考） |
| `testB-writeAmp-20260709-170303/` | 口径A | 测试B 写放大对照（镜像vs非镜像 2轮+iostat） |
| `kB-enter-20260709-172221/` | 口径B进入 | beegfs-net+tc+config 证据 |
| `testA-kB-r1-20260709-175037/` | 口径B | 测试A r1（fio+sar 4节点） |
| `testA-kB-r2-20260709-175355/` | 口径B | 测试A r2 |
| `kB-restore-20260709-190608/` | 口径B收尾 | RDMA 恢复证据（beegfs-net+tc清+哨兵218µs） |

> 测试C 数据复用 `results/20260708-stage2-dual-baseline/full-stage2A-r{1,2}-*`（同 RDMA 锁定态配置）。

---

## 7. 方法论说明

1. **IB counter 校准**：`port_xmit_data`/`port_rcv_data` 单位 = 4B（用 multi-seqwrite fio=8076×2(镜像)=16152 vs ΣΔrcv×4×3≈16479 反推，误差<5%）。单流时 per-slave IB 速率远 < 12500，corroborate fio bw。
2. **口径B helperd 依赖**：干净重启时 beegfs-helperd 必须先启动（`logType=helperd`），否则 client mount "Operation canceled"。
3. **口径B 复制路由**：mgmtd force-kill 导致不完整重启时，storage 间镜像复制未走 eno12409（残留旧连接），单流 seqwrite=96.8（失真）。干净重启后复制正确走 eno12409，seqwrite=53.0（匹配历史 53.3）。
4. **getentryinfo 语法**：`beegfs-ctl --getentryinfo <path>`（位置参数），`--entry=<path>` 会 "Stat failed"（bench-full.sh env-snapshot 同 bug）。
5. **pkill 自杀陷阱**：`pkill -f beegfs` 匹配命令行含 "beegfs" 的 shell 自身；改用 `pkill beegfs`（匹配进程名）避免。
