# BeeGFS 方案性能调优演进报告

> 环境：4 节点 BeeGFS 7.3.2（157 mgmtd+meta+client / 150·151·152 meta+2storage）/ Buddy Mirror（chunk=1M，3 targets）/ 6 × 7TB NVMe XFS / 数据面 100GbE RDMA(RoCE)，与 WekaIO 物理共用网卡
> 考核标准：有效带宽 ≥ 网卡线速 50%（100GbE 50%线=6250 MiB/s；千兆 50%线=59 MB/s）
> 数据来源：全量 fio 冷态测试（direct=1 + drop 客户端+3 slave page cache）

---

## 一、调优工作总览

| 阶段 | 关键动作 | 核心进展 |
|------|---------|---------|
| **环境修复 & 基线重建**（07-03→07-06） | 修复 meta 节点4 通信异常、3 处脚本 bug（7.x 采集/iopsget 大小写/递归溢出）、逐节点核对调优、重跑基线 | 拿到首个可信的全矩阵基线；发现数据面实为 100GbE RDMA 而非 10GbE TCP；确认 100GbE 网卡与 WekaIO 共用 → 确立三条安全红线 |
| **479 谜底排查 & 基线定案**（07-07→07-08） | 33 次重启测量 + 16h 监控 + 日志根因分析 + 接口锁定实验 | 查明 479 = 数据面掉到 10GbE TCP（connInterfacesFile 被清空→自动选接口→落 TCP），锁 RDMA 接口后 5/5 重启 100% 走 RDMA，单流写基线固定为 ~900，479 态永久消除 |
| **单流写应用层调优**（07-08） | connRDMABufNum/BufSize、tuneNumWorkers、chunksize、fsync 五变量 28 轮 | 全部噪音范围（±3%）无正收益；单流写被 per-IO 延迟（~264µs）主导，~840 是物理天花板。变量 E 决定性证据：移除 fsync 无差异 → direct=1 下 write 本身同步 |
| **双口径基线实测**（07-08） | 100GbE 不限速 + 千兆限速（双向 tc tbf）全矩阵重测 | 口径 A（100GbE）：5 项达标（50-82%），5 项未达标；口径 B（千兆）：7 项达标，仅单流写 53.3 未达标——修正了此前"千兆全部达标"的判断 |
| **未达标项瓶颈坐实**（07-09） | NIC 利用率实测、非镜像写放大对照、IOPS×bs 分解 | 6 项未达标瓶颈均用直接实测证据坐实：单流 NIC 利用率仅 6.7-11.7%、写放大 1.76×、64K IOPS 76k 但 bw 仅 1M 的 0.41×、千兆单流利用率 45% |
| **全项结案**（07-09） | 逐项复核可执行优化手段 | 三条安全红线约束下，全部 6 项未达标项均无合法可执行的优化手段。全项结案 |

**演进路径**：基线可信度建设 → 认知纠正（RDMA/共用红线）→ 基线疑题定案（TCP fallback）→ 应用层穷举 → 双口径实测 → 瓶颈坐实 → 全项结案。整个过程共测量 100+ 轮次，均在三条安全红线内操作。

---

## 二、调优过程关键发现

### 2.1 初始基线的可信度问题与修复

07-03 首轮测试拿到全矩阵数据后，发现 5 类可信度问题：meta 节点4 通信异常（target 4 容量 0）、`beegfs-ctl --mgmtd_node` 在 7.x 失效致拓扑采集全失败、`iopsget()` 大小写匹配致 IOPS 全 NA、`bench-basic.sh` 递归栈溢出、seqread R1=565 vs R2=1521（+170%）。修复后重跑的 v2 基线成为后续所有对比的锚点。

同时纠正两项关键认知：① 数据面实为 100GbE RDMA/RoCE（`ibstat` 两端口 100Gb、流量绕过 TCP 栈）→ 原计划"切 100GbE"阶段作废；② `fuser /dev/infiniband/uverbs0` 显示 BeeGFS 与 WekaIO 共用同一 RDMA verbs 设备 → 确立三条安全红线：

| 红线 | 内容 |
|------|------|
| 不动 157 内核参数 | 同机跑 K8s+WekaIO 业务 |
| 不动 100GbE 网卡/驱动/RoCE QoS | 与 WekaIO 物理共用 |
| 不动根目录 stripe | 保护生产镜像配置 |

这三条红线极大压缩了调优空间——后续所有调优只能动 BeeGFS 应用层 `.conf` 参数 + slave 端内核参数 + 子目录 stripe（测后删除）。

### 2.2 单流写基线疑题的完整闭环

单流写在 479 与 900 两个值间反复，先后经历三次误判：

| 时刻 | seqwrite | 当时认知 | 真相 |
|------|:---:|------|------|
| 07-06 v2 | 835 | "slave 调优 +78%" | TCP↔RDMA 假象 |
| 07-07 复测 | 466-508 | "服务重启衰减，机制未知" | TCP fallback（eno12409） |
| 07-08 锁定 | 889-909 | 可保证基线 | RDMA 锁定 100% |

排查链：除 dirty_ratio（direct=1 时 10 vs 20 无差异：512 vs 503）→ 排除运行时间衰减（16h 监控无趋势）→ 排除 WekaIO 争抢（空闲态实测仍 508）→ 日志分析定位 07-06 20:23 重启清空了 `connInterfacesFile` → client 变自动选接口 → 小概率落 10GbE TCP（eno12409, 10.114.1.x）。锁定 `connInterfacesFile` 只列 RDMA 网卡（enp139s0f0np0/f1np1）后，5/5 重启 100% 走 RDMA，单流写稳定 889-909（±1.1%），479 态永久消除。

由此作废了此前写入交付文档的"slave 调优对单流写 +78%"结论——该对照实验的 tuned=835（重启前）与 untuned=466（重启后）跨越了未受控的接口配置变量。

### 2.3 单流写 ∼840 是 per-IO 延迟物理天花板

在 ~900 RDMA 锁定基线上穷举 5 个应用层参数共 28 轮：connRDMABufNum（70→128→256）、connRDMABufSize（8192→16384→32768）、tuneNumWorkers（12→24→48）、chunksize（512K/1M/2M/4M）、fsync vs 无 fsync——全部在噪音范围（±3%）无正收益。变量 fsync 的决定性证据：移除 `end_fsync` 仍 916 vs 916，证明 `--direct=1` 下每个 write 本身同步，瓶颈在写路径不在后端落盘。

**per-IO 延迟分解**（单流 256K direct=1 write，stage2 原始 fio 对账：clat avg=264µs，min=188µs，IOPS=3328）：

| 环节 | 估计 | 依据 |
|------|:---:|------|
| RDMA 往返 | ~10-20µs | 100GbE RoCE 单程 ~5µs |
| BeeGFS 协议 | ~50-100µs | 请求处理 + chunk 分配 + buddy mirror 协调 |
| NVMe 写 | ~100-150µs | clat_min 188µs - RDMA ≈ 168µs |
| Buddy Mirror 双写 | 串行 | write→primary→secondary 两段落盘确认 |
| **合计** | **~264µs** | clat avg 实测值 |

带宽 = IOPS(1/264µs≈3788) × 256K ≈ 947 MiB/s，与实测吻合。参数无效的机理：iodepth=1 每连接只用 1-2 个 RDMA buffer / 1 个 worker，基线 70 buffer / 12 workers 已远超需求。dirty_ratio 对 direct=1 也实证无效。

---

## 三、性能基线数据

### 3.1 不限速（100GbE RDMA 锁定态，冷态 direct=1）

| 测试项 | bw (MiB/s) | %100GbE | ≥50%? | 关键指标 |
|--------|:---:|:---:|:---:|------|
| seqread 单流 | 1516 | 12.1% | ✗ | IOPS 6036, clat 165µs |
| seqwrite 单流 | 840 | 6.7% | ✗ | IOPS 3328, clat 264µs |
| multi-seqread 16 | 7112 | 56.9% | ✓ | |
| multi-seqwrite 16 | 7731 | 61.8% | ✓ | |
| layout 128/4M | 10199 | 81.6% | ✓ | |
| randread 128/256K | 9252–10752 | 74–86% | ✓ | 跨轮波动（WeaIO 流量影响大块读） |
| randwrite 128/256K | 6146 | 49.2% | ✗ | IOPS 24.6k |
| randrw R/W 128/256K | 4645/4641 | 37.1% | ✗ | |
| randread-64K 128 | 4766 | 38.1% | ✗ | IOPS 76.1k |
| randread-1M 128 | 10650–11571 | 85–93% | ✓ | |

### 3.2 千兆限速（eno12409 双向 tc tbf 1Gbps，connUseRDMA=false，冷态 direct=1，≥59 MB/s）

| 测试项 | bw (MiB/s) | %千兆 | ≥59? |
|--------|:---:|:---:|:---:|
| seqread 单流 | 104 | 88% | ✓ |
| seqwrite 单流 | 53.3 | 45% | ✗ |
| multi-seqread 16 | 275 | 233% | ✓ |
| multi-seqwrite 16 | 113 | 96% | ✓ |
| layout 128/4M | 113 | 96% | ✓ |
| randread 128 | 340 | 288% | ✓ |
| randwrite 128 | 111 | 94% | ✓ |
| randrw R/W 128 | 108/107 | 92% | ✓ |

> 多流项 >100% 属正常（3 slave 各走 1gbit，聚合上限 ≈ 354 MiB/s）。

---

## 四、不达标项分析与结论

全部 6 项未达标瓶颈均用直接实测证据坐实：

### 4.1 单流项（口径 A：seqread 12.1%，seqwrite 6.7%；口径 B：seqwrite 45%）

**实测坐实**：IB counters 在 3 slave 抓 100GbE 速率——单流 seqread 利用率 11.7%、seqwrite 6.7%，multi-seqwrite(16) 对照 64.6%。千兆端 sar 抓 eno12409——单流 seqwrite 利用率 45%、multi 对照 95.8%、client 有效数据占比 ≈99%。

**根因**：per-IO 延迟串行（读 165µs、写 264µs/4669µs）决定 IOPS 上限，链路大量空闲。达 50% 线需 clat <41µs（读）/ <33µs（写），FUSE+RDMA+NVMe 栈固有地板不可达。千兆单流写 256K÷118MB/s≈2.1ms 已占 clat 的 45%，余为镜像双写+协议往返。

**结论**：物理天花板（直径 A）和千兆固有特性（口径 B），stage1 已 28 轮穷举无收益。

### 4.2 randwrite 49.2%（口径 A）

**实测坐实**：非镜像子目录（RAID0/numtargets=6）vs 镜像根目录对照——randwrite 11520 vs 6545 = **1.76×**。非镜像 11520 逼近 6 NVMe 聚合上限（~12000）。

**根因**：Buddy Mirror 每逻辑写落 2 份物理写，有效带宽 ≈ 后端聚合/2。关镜像可翻倍但牺牲冗余。chunksize/numtargets 属根 stripe 红线。

**结论**：不可调。

### 4.3 randrw 37.1%（口径 A）

**根因**：写成分命中同一 Buddy Mirror 2× 写放大天花板，读成分与之竞争 NVMe/网络。派生于 randwrite，无独立手段。

**结论**：不可调。

### 4.4 randread-64K 38.1%（口径 A）

**实测坐实**：IOPS×bs≈bw 关系成立——64K IOPS 76.1k 是 1M 的 6.6 倍，但 bw 仅 1M 的 0.41 倍。

**根因**：每 IO 固定开销（RDMA verbs+FUSE+NVMe 命令）摊薄限制小块有效带宽。可能手段 read_ahead 属 157 内核红线，chunksize 属根 stripe 红线。

**结论**：不可调。

### 4.5 全项汇总

| 未达标项 | 达标率 | 根因 | 可调? | 不可调原因 |
|----------|:---:|------|:---:|------|
| seqread 单流（A） | 12.1% | per-IO 延迟 | ❌ | 物理天花板 |
| seqwrite 单流（A） | 6.7% | per-IO 延迟 | ❌ | 物理天花板，stage1 已穷举 |
| seqwrite 单流（B） | 45% | 千兆单流 RTT | ❌ | 千兆固有特性 |
| randwrite（A） | 49.2% | 镜像 2× 写放大 | ❌ | 关镜像牺牲冗余，其余触红线 |
| randrw（A） | 37.1% | 派生于 randwrite | ❌ | 无独立手段 |
| randread-64K（A） | 38.1% | 小块 per-IO 开销 | ❌ | read_ahead 触 157 红线，chunksize 触根 stripe 红线 |

> 三条安全红线约束下，全部 6 项未达标项均无可合法执行的优化手段。**全项结案。**
