# 任务书 · 阶段2 补测 — 未达标项瓶颈坐实（按口径组织：口径 A 三测试 / 口径 B 三测试）

> 执行方：GLM（新会话 / 新服务商，**无历史上下文**，本任务书自包含）
> 派发方：规划 agent
> 依据：`results/20260708-stage2-dual-baseline/README.md`（口径 A/B 达标表 + §2.1/§3.1 未达标原因）
> 日期：2026-07-09
> 优先级：P2（补充实测证据，非阻塞；产出用于对领导汇报的「未达标项瓶颈非带宽/非配置」直接证据）

---

## 0. 背景（新会话必读）

### 0.1 项目
4 节点 BeeGFS 7.3.2 并行文件系统调优项目，与 JuiceFS+Ceph 做对比。目标：不影响已有业务前提下找瓶颈、提性能。

### 0.2 集群拓扑
| 节点 | 内网 IP | 角色 | eno12409（10GbE 独立 NIC） |
|------|---------|------|------|
| client (157) | 10.20.1.157 | mgmtd+meta+client（**同机跑 K8s+WekaIO 业务**）| 10.114.1.157 |
| slave1 (150) | 10.20.1.150 | meta + 2 storage（nvme2n1/nvme3n1 XFS）| 10.114.1.150 |
| slave2 (151) | 10.20.1.151 | 同 slave1 | 10.114.1.151 |
| slave3 (152) | 10.20.1.152 | 同 slave1 | 10.114.1.152 |

- 镜像：storage 3 buddy group，**根目录 stripe = Buddy Mirror, chunk=1M, numtargets=3**。
- 数据面 100GbE RDMA（Mellanox mlx5_0/mlx5_1，`connUseRDMA=true`）。**RDMA 流量不进 `/proc/net/dev`**，看 `/sys/class/infiniband/mlx5_*/ports/*/counters/`（port_xmit_data / port_rcv_data，单位 4B lane）或 `ibstat`。

### 0.3 stage2 已产出（本任务的起点）
`results/20260708-stage2-dual-baseline/README.md` 已产出双口径达标表。**未达标项目前的原因分析多为算术反推/引用，缺直接实测证据**，本任务逐项抓数据坐实：

**口径 A（100GbE RDMA 不限速，50% 线=6250 MiB/s）未达标 4 项：**
1. 单流 seqread 1516（12.1%）/ seqwrite 840（6.7%）—— 判定「延迟主导」（clat 165/260µs）
2. randwrite 128 = 6146（49.2%，**临界**）—— 判定「Buddy Mirror 2× 写放大 + NVMe 聚合上限」（**纯推断，无对照**）
3. randrw R/W = 4645/4641（37.1%）—— 判定「读写竞争后端」（定性）
4. randread-64K = 4766（38.1%）—— 判定「小块 per-IO 退化」（已有 64K/256K/1M sweep）

**口径 B（千兆限速，50% 线=59 MiB/s）未达标 1 项：**
5. 单流 seqwrite 53.3（45%）—— 判定「单流 QD1 + 镜像双写 + 千兆 RTT 延迟串行，链路未打满」

### 0.4 ⚠️ 安全红线（最重要，违反会影响生产业务）
100GbE Mellanox 网卡与 WekaIO **物理共用**（同一 RDMA verbs 设备）。
| 可以做 | 禁止做 |
|--------|--------|
| ✅ 只读采样：`sar -n DEV`、`iostat -x`、读 infiniband counters、`ibstat` | ❌ 在 100GbE RDMA 网卡上做任何限速/QoS/改配置 |
| ✅ **子目录** stripe（`--setpattern` 建非镜像子目录，不动根目录）| ❌ 改根目录 stripe / RoCE QoS（connRDMATypeOfService/PFC/DSCP，与 WekaIO 共享）|
| ✅ BeeGFS 应用层 `.conf` + `eno12409`（10GbE 隔离 NIC）tc tbf 限速 | ❌ 157 内核参数、100GbE 网卡/驱动全局（MTU/mlxconfig/queue/中断）|

**总原则：只做只读采样 + 子目录级对照 + eno12409 隔离 NIC 限速；不动根 stripe、不动 157 内核、不动 100GbE 网卡/RoCE QoS。** 建的非镜像子目录用完删除，不影响根目录数据与业务。BeeGFS 是纯测试集群，服务可自由重启；重启后须等 target 全 Online/Good 再测。

---

## 1. 访问方式
项目目录在 157：`/home/sunrise/beegfs-production`（测试执行目录 `/tmp/beegfs-test`）
```bash
# WSL → 泰国 client 157
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
# 157 → slave（两级跳）
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 '<command>'"
```
- 用户 `sunrise` / 密码 `Sunrise@801`；sudo：`echo 'Sunrise@801' | sudo -S <cmd>`
- 规范：`skills/beegfs-node-conventions.md`、`skills/TESTING-GUIDE.md`、`skills/beegfs-baseline-config.md`。
- 测试口径统一：冷态 `--direct=1` + 每项前 client + 全部 3 storage server drop page cache。fio 参数照 stage2 各项（对账 `results/20260708-stage2-dual-baseline/*/commands.sh`）。每项 ≥2 轮，只认冷态一致轮，全部对账原始 fio `bw=`/`clat` 行。

---

## 2. 口径 A —— 100GbE RDMA 不限速（50% 线=6250 MiB/s）

RDMA 锁定态（`connInterfacesFile=/etc/beegfs/connInterfacesFile.conf`、`connUseRDMA=true`）。**每项测前做 RDMA 哨兵**：`beegfs-net | grep -A1 "ID: 10[123]"` 3 storage 全 RDMA（10.3.x:8003），快测 clat_min<250µs。口径 A 三个测试（A / B / C）全部在此态下完成，不需切换网络。

RDMA 速率采样通用脚本思路（每秒读 counters 差分 ×4B 得 bytes/s，RDMA 流量不进 `/proc/net/dev`）：
```bash
# 每 1s 采一次，记录时间戳，跑满整个 fio 时长
for p in /sys/class/infiniband/mlx5_*/ports/*/counters; do cat $p/port_xmit_data $p/port_rcv_data; done
# 若差分不便可用 perfquery / ibstat 周期采样；工具与版本记录清楚
```

### 2.A 测试 A — 单流项 NIC 利用率（坐实项① 单流 seqread/seqwrite 延迟主导）
论点：单流 QD1 下 100GbE 远没被打满 → 瓶颈是 per-IO 延迟串行，不是带宽。
- fio 跑单流 seqread（再单流 seqwrite）**整个过程**，并发在 3 个 slave 采样 infiniband counters 求速率，同时 `iostat -x 1` 抓 NVMe。
- 对照：同场景各跑一次 **multi-seqread/seqwrite（16 线程）**（已知 6311+/7731，≥50%），抓同样 counters。
- 期望证据：单流时 100GbE 实际速率 ≈ 1516/840 MiB/s（远 < 12500，利用率 ~6–12%）；multi 逼近后端上限 → 单流没用满链路，差异来自并发度/延迟。

### 2.B 测试 B — 写放大对照（坐实项② randwrite 49.2% + 项③ randrw 37.1%）
论点：randwrite/randrw 未达标是 **Buddy Mirror 2× 写放大 + NVMe 聚合上限**，非网络。用非镜像子目录对照量化。
1. **建非镜像对照子目录（不动根 stripe）**：先 `beegfs-ctl --getentryinfo` 记录根 pattern，再建 RAID0 子目录：
   ```bash
   beegfs-ctl --setpattern --pattern=raid0 --chunksize=1m --numtargets=6 /mnt/beegfs/nomirror-test
   beegfs-ctl --getentryinfo /mnt/beegfs/nomirror-test   # 确认 pattern=RAID0
   ```
   （命令/挂载点以实际为准；numtargets 设为全部 storage target 数以对齐聚合能力，记录清楚。**只在此子目录建，根目录 Buddy Mirror 不动。**）
2. **对照测试**：在镜像根目录与非镜像子目录分别跑同参 randwrite（128 jobs × iodepth128 × 256K）与 randrw，各 ≥2 轮；同时 `iostat -x 1` 抓 3 slave 的 6 个 storage NVMe（nvme2n1/nvme3n1 × 3）的 w/s、wMB/s、%util。
   - 期望：非镜像 randwrite bw ≈ 镜像 ~2×（逼近后端聚合上限）→ 坐实「2× 写放大」，并回答「关镜像可提升约 1 倍，但牺牲冗余，非生产可接受」；镜像态 NVMe %util 接近饱和 → 后端是瓶颈非网络。randrw 同理佐证「读写竞争同一写天花板」。
3. **收尾**：`rm -rf /mnt/beegfs/nomirror-test`，确认根目录数据与 stripe 未受影响。

### 2.C 测试 C — 小块读退化分解（坐实项④ randread-64K 38.1%）
现有 sweep（64K=4766 / 256K=9252–10752 / 1M=10650–11571）已示 bw 随块增大而升，本测补 per-IO 开销证据：
- randread bs sweep（64K/256K/1M，128 jobs）时抓 fio 的 **IOPS 与 clat**（对账原始）：小块 IOPS 高但 bw 低 → 每 IO 固定开销（RDMA verbs+FUSE+NVMe 命令）摊薄限制小块 bw。
- （可选，仅 slave 端）对 **150/151/152** 的 read_ahead_kb 做 256/1024/8192 对照观察小块读是否改善（**不动 157**，属 skill 允许的 slave 内核参数）；若做，改后须恢复基线 4096 并记录。
- 期望证据：给出 64K/256K/1M 的 IOPS×bs=bw 分解表，说明小块 bw 低源于 per-IO 固定开销，块越大预取越有效。

---

## 3. 口径 B —— 千兆限速（eno12409 TBF 1Gbps，50% 线=59 MiB/s）

### 3.0 进入口径 B（照 stage2 README §5 已验证做法）
1. 备份 connInterfacesFile 与 beegfs-*.conf。
2. 4 节点设 `connUseRDMA=false`（否则 TCP 会回退到 100GbE 网卡，非 eno12409）。
3. connInterfacesFile 指向 eno12409。
4. **双向** tc tbf：157 + 3 slaves 的 eno12409 egress 都加（仅 slave 侧会失真到 170）：
   ```bash
   sudo tc qdisc add dev eno12409 root tbf rate 1gbit burst 32kbit latency 400ms
   tc qdisc show dev eno12409 | grep tbf   # 确认
   ```
5. 重启 BeeGFS，等 target 全 Online/Good；哨兵 `beegfs-net` 全 TCP（10.114.1.x）、单流 seqwrite≈53 确认口径。

### 3.A 测试 A — 单流 seqwrite 链路利用率（坐实项⑤ 千兆单流写 45%）
论点：单流 QD1 + 镜像双写 + 千兆 RTT 延迟串行，链路未打满。
- fio 单流 seqwrite 整个过程，在 **4 节点** eno12409 上 `sar -n DEV 1` 抓 tx bytes/s。
- 对照：同链路跑 multi-seqwrite（16），已知达 113（≈打满 118）。
- 期望证据：单流 tx 均值 ≈ 55MB/s（利用率<50%，有空闲间隙）；multi tx ≈ 118（打满）→ 同链路有余量，单流没用满。
- 附 clat 分解：单 IO 4665µs 中纯千兆传输 256K÷118MB/s≈2.1ms（占~45%），余 ~2.5ms 为镜像双写+协议往返。

> **口径 B 说明**：千兆口径下仅单流 seqwrite 未达标（其余项均 ≥59，见 stage2 README §3）。写放大（测试 B）与小块读（测试 C）的机理在口径 A 已充分暴露，千兆链路带宽远低于后端能力时这两类瓶颈不再是限制因素，故**口径 B 只做测试 A**；如需在千兆口径复核 B/C 可作为可选项，非必须。

### 3.Z 收尾（**必做**）
1. 4 节点 `sudo tc qdisc del dev eno12409 root`，确认无 tbf。
2. 恢复 connInterfacesFile + `connUseRDMA=true`（RDMA 锁定），照 skill §1.5。
3. 重启 BeeGFS，等 target 全 Online/Good。
4. RDMA 哨兵：`beegfs-net` 全 RDMA（10.3.x）、单流 seqwrite clat_min<250µs，留证据。

---

## 4. 产出（核心交付）
在 `results/20260709-stage2-unmet-rootcause/` 产出 `README.md`：

### 4.1 单流链路利用率表（口径 A 测试 A + 口径 B 测试 A）
| 场景 | 口径 | fio bw (MiB/s) | fio clat avg | NIC 实测速率 | 线速 | 利用率 | 结论 |
|------|---|:---:|:---:|:---:|:---:|:---:|---|
| 单流 seqread | A 100GbE | 1516 | ~165µs | | 12500 | | 延迟主导，未打满 |
| 单流 seqwrite | A 100GbE | 840 | ~260µs | | 12500 | | 同上 |
| multi-seqwrite(16) | A 100GbE | 7731 | | | 12500 | | 对照：可打满 |
| 单流 seqwrite | B 千兆 | 53 | ~4665µs | | 118 | | 延迟串行，未打满 |
| multi-seqwrite(16) | B 千兆 | 113 | | | 118 | | 对照：打满 |

### 4.2 写放大对照表（口径 A 测试 B）
| 场景 | 根/子目录 pattern | randwrite bw | randrw R/W | NVMe %util | 结论 |
|------|---|:---:|:---:|:---:|---|
| 镜像（根） | Buddy Mirror | ~6146 | ~4645/4641 | | 2× 写放大 |
| 非镜像（子目录） | RAID0 | ? | ? | | 若≈2× → 坐实 |

### 4.3 小块读分解表（口径 A 测试 C）
| bs | bw (MiB/s) | IOPS | clat | %100GbE | 说明 |
（含可选 read_ahead 对照）

### 4.4 结论与证据留存
- 每项给出「瓶颈=延迟/写放大/小块开销，非带宽/非配置」的数据结论。
- 保留：原始 fio（含 `bw=`/`clat`）、sar/iostat/infiniband-counters 原始采样、commands.sh、setpattern getentryinfo、tc/beegfs-net 证据（口径 B）、收尾恢复证据。全部对账原始文件。

---

## 5. 验收标准
- [ ] 口径 A 测试 A：单流 read/write ≥2 轮，fio 与 100GbE counters 同步；multi 对照齐全；给出利用率数字
- [ ] 口径 A 测试 B：镜像 vs 非镜像子目录 randwrite/randrw 各 ≥2 轮 + NVMe iostat；非镜像子目录测后删除
- [ ] 口径 A 测试 C：64K/256K/1M IOPS×bw 分解表（可选 slave read_ahead 对照，改后恢复 4096）
- [ ] 口径 B 测试 A：单流 seqwrite ≥2 轮，fio 与 eno12409 sar 同步；multi 对照；给出利用率数字
- [ ] 三张表 + 结论产出，全部数值对账原始文件
- [ ] **收尾：口径 B tc 清除、connInterfacesFile/connUseRDMA 恢复 RDMA 锁定、非镜像子目录删除、服务重启、哨兵通过并留证据**
- [ ] 全程未动：157 内核、100GbE 网卡/驱动/RoCE QoS、**根目录 stripe**（安全红线）

---

## 6. 交付与提交规范
1. 脚本/文档改动提交推送前必须先向用户展示 diff 并获确认（`skills/doc-publish-rule.md`），不得私自 `git commit`/`git push`。
2. 完成后回传三张表给规划 agent，据此把实证补入 `doc/perf-analysis/01-beegfs-perf-tuning.md` 与 stage2 README §2.1/§3.1，并据写放大对照结论确定 stage3 优先级。
3. 过程中若发现与既有基线冲突或可信度问题，先停下报告，不在污染数据上继续。
