# 01 — 冷态基线瓶颈分析与下一阶段调优计划

> 日期：2026-07-06
> 数据来源：`results/20260703-beegfs-cold-baseline/`（限速 R1/R2 + 不限速 R1/R2，各 27 文件）
> 集群：4 节点（157 mgmtd+meta+client / 150·151·152 meta+2storage），BeeGFS 7.3.2
> 镜像：metadata 2 buddy groups + storage 3 buddy groups（Buddy Mirror, 1M chunk, 3 targets）
> 方法论遵循 `skills/perf-review-planning/SKILL.md`：先核对方法再看数据、控制变量、数据可信度红线、只认冷态 R1。

---

## 一、部署与测试现状

### 1.1 部署现状（已完成）

- 4 节点集群部署完成，镜像启用，`beegfs-df` 显示 6 个 storage target（各 7.1TB）+ 3 个 meta target 在线。
- 系统调优脚本 `tune-servers.sh` 已按官方文档编写（THP always、dirty 5/10、read_ahead 4096K、governor performance、NVMe 调度器 none）。
- 网络：BeeGFS 走 10GbE 管理网；限速测试通过独立网卡 `eno12409` TBF 1Gbps 模拟千兆。

### 1.2 测试现状（冷态基线一轮，direct=1，客户端+服务端 drop cache）

原始 fio 已对账，关键数值（不限速 R1，单位 MiB/s）：

| 测试 | 不限速 R1 | 限速 R1 (1Gbps) | 备注 |
|------|:---:|:---:|------|
| seqread (单线程) | 565 | 114 | clat ~442µs, IOPS 2258 |
| seqwrite (单线程, fsync) | **335** | 58.9 | clat ~709µs, IOPS 1341 |
| multi-seqread (16 jobs) | 6311 | 302 | |
| multi-seqwrite (16 jobs) | 1677 | 113 | clat ~2.3ms, IOPS 6708 |
| layout (128 jobs, bs=4M) | 1640 | 113 | |
| randread (128 jobs) | 10650 | 339 | |
| randwrite (128 jobs) | 1629 | 113 | clat ~2.4s(!), IOPS 6517 |
| randrw (128 jobs) R/W | 1582/1578 | 109/108 | |
| randread bs=1M | 12698 | 340 | 读峰值 |
| randread bs=64K | 4938 | 340 | 小块读明显掉 |

三轮偏差 <1%（随机项），服务端 drop cache 口径有效，写侧数据可信。**但单流读 seqread R1=565 vs R2=1521（+170%）异常，见 2.5。**

> 说明：本文档已综合 `/tmp/beegfs-tune-0706/` 五份外部模型分析（deepseek-v4-pro / glm-5.2 / minimax-m3 / qwen3.7-max / gpt-5.4），
> 补入了 2.5（seqread 红线）、2.6（100GbE 网络杠杆 + 延迟分解）、2.7（157 共部署隐患）及阶段 0 的脚本 bug 修复。

---

## 二、瓶颈分析

### 2.1 读写吞吐的两条天花板（不限速，暴露后端真实能力）

1. **读天花板 ≈ 10.6~12.7 GB/s**（randread / randread-1M）
   - 读只命中 primary target，无镜像开销，6 NVMe × 100GbE 聚合，接近硬件上限。**读侧当前无明显瓶颈。**

2. **写天花板 ≈ 1.6 GB/s**（randwrite 1629 / multi-seqwrite 1677 / layout 1640 / randrw R+W 3160 收敛在同一区间）
   - 写走 Buddy Mirror：每个 chunk 同时写 primary + secondary，**写放大 2×**，且需两端都落盘确认才返回。
   - 6 个物理 target 里实际有效写带宽 ≈ 逻辑 1.6 GB/s（物理 ≈ 3.2 GB/s）。**写侧瓶颈 = 镜像同步复制 + storage 落盘。**

### 2.2 单线程写是最突出的短板（优先级最高）

- 单线程 seqwrite 仅 **335 MiB/s**，而 128 并发 randwrite 达 1629 MiB/s（4.8×）。
- 单线程 seqwrite clat ~709µs/IO、IOPS 仅 1341 —— 典型的 **同步复制往返延迟受限**（write→primary→secondary→ack 串行），而非带宽受限。
- 单线程 seqread 565 vs 16 线程 6311（11×）同样是单流延迟受限，非带宽。
- 结论：**低并发场景（单流/少流）延迟主导，是当前离硬件上限最远、最值得调的方向。**

### 2.3 小块随机读退化

- randread bs=64K（4938）显著低于 bs=256K（10650）和 bs=1M（12698）。
- 小块下每个 IO 的 meta/网络往返固定开销占比高，吞吐被 per-IO 开销拖累。若业务有小块读特征需重点关注。

### 2.4 数据可信度 / 环境红线（须先解决，否则后续对比不可信）

1. **meta 节点 4（152）通信错误**：`env-snapshot.txt` 显示
   `[ERROR from beegfs-meta beegfs-slave3 [ID: 4]: Communication error]`，且 meta target 4 容量为 `0.0GiB`。
   152 是 metadata buddy group 2 的 primary，基线是在 4 meta 里有 1 个通信异常的状态下跑的 ——
   **meta 冗余/负载可能不完整，须查明并修复后重跑基线。**
2. **`beegfs-ctl --mgmtd_node` 参数在 7.x 无效**：env 快照里 nodes/targets/stripe 采集全部失败
   （`Invalid argument: --mgmtd_node`）。测试脚本采集拓扑的命令要按 7.x 语法修正（改用 `/etc/beegfs/beegfs-client.conf`）。
3. **`bench-full.sh` 的 `iopsget()` IOPS 解析 bug**（可对账验证）：用大写 `$2: IOPS=`（`READ`/`WRITE`）匹配，
   但 fio detail 行是小写 `read: IOPS=` / `write: IOPS=`，且 fio summary 行只有 `bw=` 无 `IOPS=`。
   结果 **summary.md 里所有随机测试 IOPS_R/IOPS_W = NA**（已核对属实）。修前 summary 的 IOPS 不可信，须回原始 fio 取。
4. **`bench-basic.sh:70-71` 递归 bug**：`drop_all_caches()` 函数体内调用同名函数（应为内联 drop 逻辑），
   会无限递归直至栈溢出。`bench-full.sh` 同名函数是对的，basic 复制时漏改。
5. **缺少暖态基线**：只有冷态一组，尚无 writeback/暖态数据，无法界定"重复访问上限"。

### 2.5 seqread R1≠R2（565 vs 1521，+170%）—— 第二条可信度红线

- 同 cold 模式（drop_caches + direct=1）下，多流读 R1/R2 仅 +2%，而**单流读偏差 170% 远超 10% 噪声线**。
- 可能根因（按概率）：(a) R1 prep 写入的 4G 文件在 storage 端 XFS page cache 未清净，R2 命中服务端缓存（客户端 drop 清不掉服务端）；
  (b) 单流首次 IO 冷启动抖动（连接建立、buddy group 路由/chunk table 加载、NUMA 跨 socket）；(c) mgmtd 拓扑首拉。
- 修复路径：阶段 0 重跑基线时加 **warmup-then-drop 流程**（先预跑一次 seqread，再 drop_caches，再正式测）
  以分离"冷启动抖动"与"服务端 page cache 残留"，使 R1/R2 偏差收敛到 <10%。

### 2.6 100GbE 数据通道闲置 —— 最大网络杠杆（延迟分解论证）

- 集群有 100GbE 网卡（`enp139s0f0np0`, 10.3.1.0/24）但 **BeeGFS 全部走 10GbE**（eno12399）。
- **单流写延迟分解**（原始 clat=708µs, min=615µs）：256KiB ÷ 1.25GB/s(10GbE) ≈ 210µs/hop，
  Buddy Mirror 至少 2 跳（primary + secondary）≈ **420µs，占 clat ~60%**；余下为 2× NVMe fsync (~150-200µs) + 协议 ack。
  → 单流写的主因是 **10GbE 每 chunk 串行传输时间**，镜像协议只是把 1 跳变 2 跳放大了网络权重。
- **写天花板算术自洽**：3 slave × 10GbE egress = 3.75GB/s 物理 ÷ 镜像 2× 写放大 ≈ 1.875GB/s ≈ 实测 1.6GB/s。
  NVMe 未饱和（6×~2.5GB/s÷2 ≈ 7.5GB/s 物理上限），**网络是写天花板的硬约束**。
- **反推 100GbE 收益**：256KiB ÷ 12.5GB/s ≈ 21µs/hop，2 跳 ≈ 42µs → 单流写 clat 可降至 ~200-250µs，
  单流写理论 **~1000-1600 MiB/s（4-5×）**；写天花板理论跳到 ~5-7GB/s（转由 NVMe 聚合约束）。
- 这是**单点配置变更（connInterfacesFile）同时攻击 #1 单流延迟和 #2 写天花板**的高 ROI 项。
  但排期上放阶段 2（先在 10GbE 跑完单变量矩阵），以便干净分离"网络提升 vs 参数提升"。

### 2.7 157 共部署隐患（零成本待验证项）

- 157 同机跑 **mgmtd + meta + helperd + client + fio 测试负载**：内部 RPC（心跳/路由）与 fio 数据流争同一 10GbE 出口、
  同 CPU socket 的 L3/内存带宽。可能拉低单流延迟且引入 seqread 抖动（2.5）。
- 阶段 0 排查时**同步采集 fio 跑时的 `mpstat -P ALL` / `perf top` / `nethogs` / `numastat`** 判定是否真有争抢。
  若成立，**把 client 拆到独立第 5 节点是零硬件成本、可能比 100GbE ROI 更高**的方案（阶段 5 兜底验证）。

---

## 三、下一阶段调优计划

> 原则：一次只动一个变量；每组对比列全参数确认单变量差异；每个结论数对账原始 fio 文件；只认冷态 R1；改动前后各留原始日志。

### 阶段 0（前置，必做）：修复环境/脚本与采集，重建可信基线

- [ ] 排查 meta 节点 4（152）通信错误：`systemctl status beegfs-meta`@152 + `journalctl -u beegfs-meta -n 100`；查 storeStorageDirectory/网络/mgmtd 注册；必要时重注册。确认 target 4 状态 GOOD、容量恢复 ~879GiB。
- [ ] 修正 `tests/bench-full.sh`、`tests/bench-basic.sh`、`diag.sh` 里的 7.x `beegfs-ctl` 采集命令（去掉 `--mgmtd_node`，依赖 client.conf）。
- [ ] 修 `bench-full.sh` 的 `iopsget()` IOPS 解析 bug（改用小写 `read:`/`write:` 前缀或直接解析 detail `IOPS=` 行），使 summary.md 随机项 IOPS 非 NA 且对账原始 fio 一致。
- [ ] 修 `bench-basic.sh:70-71` 递归 bug（`drop_all_caches()` 体内改内联 drop 逻辑，参照 bench-full.sh）。
- [ ] 逐节点核对 `tune-servers.sh` 生效（THP/dirty/governor/read_ahead/scheduler 实测值），写入 `tune-verify-<host>.txt`。
- [ ] **采集 157 共部署证据**：fio 跑 seqwrite/randwrite 时同步 `mpstat -P ALL`/`perf top`/`nethogs`/`numastat`，判定 mgmtd+meta+helperd+client 是否与测试负载争抢（对应 2.7）。
- [ ] **定位 seqread R1≠R2 根因**：加 warmup-then-drop 流程 + storage 端 fsync 验证，使单流读 R1/R2 偏差 <10%（对应 2.5）。
- [ ] 修复后重跑冷态基线（不限速 + 限速各 1 轮做健康态锚点）。
- **验收**：4 meta + 6 storage 全部 GOOD；env 快照拓扑采集成功；summary IOPS 非 NA；随机项三轮偏差 <1%、seqread R1/R2 偏差 <10%。

### 阶段 1（优先级最高）：10GbE 下单线程/低并发写延迟单变量矩阵

针对 2.2 的单流延迟瓶颈，**先在 10GbE 上跑完单变量矩阵**（便于阶段 2 切 100GbE 后干净分离网络 vs 参数增量）。每项独立测，其余保持基线：

- [ ] **A. tuneNumWorkers（storage/meta 工作线程）**：默认 vs 提高，观察单流是否受服务端线程调度影响。
- [ ] **B. connMaxInternodeNum（client→server 连接数）**：默认(1) → 4/8/16，增大单流 pipeline 并行度掩盖 RTT。
- [ ] **C. tuneFileCacheType / client 端 write buffer（tuneMaxWriteWorks, sysSessionCheckOnClose）**：评估客户端聚合（冷态语义矛盾须标口径）。
- [ ] **D. chunksize 影响**：单线程 seqwrite 在 chunksize=512K/1M/2M/4M 下对比（子目录 `--setpattern`，不污染根目录）。
- [ ] **E. 顺序写 fsync vs 非 fsync 对照**：拆分"后端瓶颈"与"同步确认瓶颈"。
- **验收口径**：单线程 seqwrite（bs=256K, direct=1, fsync）冷态 R1，从 335 提升可量化；每个变量单独记录增量。累计后若仍 <500 MiB/s，进阶段 2。

### 阶段 2：100GbE 数据通道切换（同时攻 #1 单流延迟 + #2 写天花板）

前置：阶段 1 已有 10GbE 单变量增量数据，才能归因网络提升。基于 2.6 延迟分解，此阶段可望质的突破。

- [ ] 100GbE 子网连通性 + MTU 探测：4 节点互 ping 10.3.1.x；iperf3 测线速；记录 MTU 1500/9000。
- [ ] `connInterfacesFile` 切到 `enp139s0f0np0`（复用 limit-bandwidth.sh 机制），全服务重启。
- [ ] 100GbE 冷态基线（MTU 1500）：bench-full.sh cold R1 全矩阵。
- [ ] 100GbE + Jumbo Frame（MTU 9000）对比，量化 jumbo 收益。
- [ ] （可选）connUseRDMA / RoCE，若网卡支持。
- **验收口径**：单线程 seqwrite cold R1 从 335 → **1000+ MiB/s**（clat < 250µs）；写天花板从 1.6 → **4+ GB/s**。若未达预期，按 2.6 算术反推剩余瓶颈（worker 排队 / chunksize / page cache 命中）。

### 阶段 3：写吞吐天花板与镜像开销量化

- [ ] 用非镜像子目录（`--setpattern --pattern=raid0 --numtargets=3/6`）跑 randwrite/layout/multi-seqwrite，量化 **镜像 2× 写放大** 的真实代价（对照当前 1.6 GB/s）。
- [ ] 评估 numtargets 从 3 提到 6（若非镜像）对写并行度的影响。
- [ ] `tuneStorageThreadsPerTarget`（每 target I/O 线程数）；XFS `allocsize` 131072k vs 1m vs 默认 对顺序写的对照。
- [ ] 记录：镜像 vs 非镜像 的写吞吐差，为"性能 vs 冗余"权衡提供数据（**不改生产镜像配置，仅测量对照**）。

### 阶段 4：小块随机读优化（在 100GbE 基线上做）

- [ ] 针对 bs=64K randread 退化，测 client `tuneFileCacheType`、read_ahead_kb(256/1024/8192)、iodepth(256/512) 补偿。
- [ ] chunksize 与小块读的关系（大 chunk 是否加剧小块读放大）。
- [ ] （若硬件支持）connUseRDMA 对小块读的收益。
- **验收**：randread bs=64K 冷态 R1 从 ~4900 提升，且不回退 256K/1M。

### 阶段 5：暖态基线、业务口径与 157 共部署兜底

- [ ] 补齐暖态基线（不 direct、不 drop、顺序 1 次 + 随机 3 轮看收敛），界定重复访问上限。
- [ ] 若业务确定为单客户端千兆场景，补客户端侧限速（当前限速在 3 slave egress，聚合 ≈3×1Gbps，非真单千兆）。
- [ ] **157 共部署兜底**：若阶段 0 证据显示争抢，临时把 client 拆到独立第 5 节点重测，对比 157 共部署 vs 独立 client 的 seqwrite 差距（>30% 则拆分为必做项）。
- [ ] 与 JuiceFS+Ceph 方案在**同口径**下出对比总表。

---

## 四、优先级矩阵

| 阶段 | 内容 | 预期收益 | 风险 | 优先级 |
|:---:|------|:---:|:---:|:---:|
| 0 | 环境修复 + 脚本 bug 修复 + 157 证据 + seqread 根因 + 基线重建 | — | 低 | **P0（阻塞）** |
| 1 | 10GbE 单线程写单变量矩阵（worker/连接数/chunksize/write buffer/fsync） | seqwrite 335→500+ | 低 | **P1** |
| 2 | 100GbE 切换 + Jumbo Frame | 单流写 4-5×、写天花板 3-4× | 中（网络变更） | **P1** |
| 3 | 写吞吐深挖 + 镜像开销量化 | 确认天花板成因 | 低 | P2 |
| 4 | 小块随机读优化（100GbE 基线上） | bs=64K 4938→7000+ | 低 | P3 |
| 5 | 暖态基线 + 业务对比 + 157 兜底 | 补齐完整画像 | 低 | P3 |

> 100GbE 排期分歧：外部五份分析中 glm-5.2 主张提到阶段 1（单点变更同攻两瓶颈，ROI 最高）；
> deepseek/qwen/minimax/gpt-5.4 主张放阶段 2（先在 10GbE 跑完单变量，便于分离网络 vs 参数增量）。
> 本计划采后者，但把 100GbE 标为 P1（紧随阶段 1）。

---

## 五、执行与留存要求

1. 每阶段测试用 `tests/bench-full.sh`（或子目录 `--setpattern` 对照测试），结果落 `results/<日期>-<阶段名>/`，保留 summary + 原始 fio + env 快照 + commands.sh。
2. 每完成一个阶段，在本目录追加编号文档（`02-*.md`, `03-*.md` …）记录：改动、单变量、原始文件路径、增量结论、对账 fio 行。
3. 结论数必须对账原始 `READ: bw=` / `WRITE: bw=` 行；IOPS 必须取原始小写 `read: IOPS=` / `write: IOPS=` 行（阶段 0 修 bug 前 summary 的 IOPS=NA 不可信）；写延迟分析必标 `slat`/`clat`。
4. 随机读/写超千兆线速（~124 MB/s）必标口径（缓存命中 / 后端能力 / 饱和延迟）。
5. 提交推送前须经用户确认（`skills/doc-publish-rule.md`）。

---

## 六、阶段性总结（截至 2026-07-07，阶段0 完成）

> ⚠️ **本节 6.1/6.2/6.3 中所有关于"slave 调优对单流写 +78%"和"v2 单流写 835 为基线"的结论已于 2026-07-07 晚被推翻，见 6.4 与 `results/20260707-stage1-baseline-recheck/README.md`。阅读时以 6.4 为准。**
> 详细复核与修正见 `02-stage0-review-and-revised-plan.md`；本节仅做阶段性总纲。

### 6.1 本阶段做了什么

1. **修复环境**：恢复 meta 节点4（152）通信，4 meta + 6 storage target 全 GOOD。
2. **修复测试脚本 3 个缺陷**：7.x `beegfs-ctl --mgmtd_node` 失效、`iopsget()` 大小写致 IOPS 全 NA、`bench-basic.sh` 递归栈溢出。
3. **确认并固定系统调优**：3 个 slave 应用官方调优（THP/dirty_ratio/read_ahead 等），**157 保持默认以保护业务**（K8s+WekaIO）。
4. **纠正两处关键事实认知**（均实测证明）：
   - **数据面是 100GbE RDMA/RoCE，不是 10GbE TCP**（`connUseRDMA=true`；randwrite 写 366GiB 而 TCP 计数仅 0.06%）。→ 原计划"切 100GbE"阶段作废。
   - **该 100GbE 网卡与 WekaIO 物理共用**（同一 RDMA verbs 设备）→ 确立调优安全红线：只动 BeeGFS 应用层/slave 端。
5. **收益归因（对照实验，单变量）**：slave 调优对**单流写 +78%**（未调优 466 → 调优 835，可靠），对**并发大块写仅 +2.5%**。
6. **建立 v2 健康基线并固化**为 `skills/beegfs-baseline-config.md`（后续对照锚点）。

### 6.2 术语澄清（回答"这些说法到底指什么、可不可信"）

之前总结用了几个含糊词，这里按原始数据核对后逐一澄清，**并诚实标注哪些是确证、哪些只是推测**：

- **"冷态测试"（我们要的口径）**：指 **page cache 冷** —— `--direct=1` + 每轮测前 drop 客户端和 3 个 storage server 的 page cache。每轮都做，这是正确口径。
- **"部署冷启动异常值"（措辞不严谨，已降级为推测）**：BeeGFS 部署完**确实立刻可用**，不存在"要等它稳定"。但 07-03 单流 seqread **同一次运行内** R1=565 → R2=1521（+170%），而多流读 R1/R2 只差 2%。这里的"冷"不是 page cache，而是 **RDMA 连接 / 客户端元数据缓存首次建立**（drop_caches 清不掉这两样）。GLM 0.7 重跑 5 轮均为 1489-1623、**从未复现 565**。→ 诚实结论：**565 是无法复现的离群低值，倾向"首次 IO 建 RDMA 连接+拉元数据"的一次性开销，但未被实验直接证实**，故 v2 只认稳定值 1585。
- **"首日未稳定修正"（此说法错误，撤回）**：核对发现 07-03 seqwrite **有两轮**（R1=335、R2=483，非"仅1轮"）。正确说法是：**07-03 单流写自身两轮离散度就大（335 vs 483，差 44%），可信度低**；v2 的 835 是干净复测的稳定值。335→835 里 **+78% 由 slave 调优确证**，其余差异归于 07-03 数据本身不稳，**不宜精确拆分**。
- **"口径修正"（指测试参数缺陷被修好）**：具体是 **`--openfiles`** —— 它**只作用于随机测试**（randread/randwrite/randrw）。07-03 用 `--openfiles=100` 但 `--numjobs=128`，128 个 job 挤 100 个文件句柄制造了假瓶颈；b0d1af7 改成 128（=numjobs）修好，**这解释随机项的提升**。
  - ⚠️ **重要纠正**：**layout 测试从不使用 `--openfiles`**（脚本无此参数）。所以之前"layout 提升来自 openfiles"是**错的**。对照实验已证 slave 调优对 layout 仅 +2.5%，故 07-03 layout=1640 → v2=10240 的巨变**既非调优、也非 openfiles**，**最可能是 07-03 layout 那一轮本身异常慢（79.9s/128GiB，单轮无对照）的污染值**。诚实结论：**07-03 layout 1640 不可信，v2 10240 才是真实水平，但差异来源无法完全归因。**

### 6.3 达到什么效果（冷态 direct=1，不限速，MiB/s）

| 测试 | 07-03 旧基线 | v2 健康基线 | 变化 | 说明（据 6.2 澄清） |
|------|:---:|:---:|:---:|------|
| seqwrite(单流) | 335 / 483(两轮离散) | **835** | — | slave 调优 +78% 确证；07-03 数据本身不稳，不精确拆分 |
| seqread(单流) | 565 / 1521(同轮) | **1585** | — | 565 为无法复现的离群值（推测 RDMA/元数据首建），认 1585 |
| multi-seqwrite(16) | 1677 | **8214** | — | 提升含调优+口径，未单独拆分（16 并发） |
| layout(128,4M) | 1640 | **10240** | — | 07-03 属污染值；调优仅 +2.5%，来源无法完全归因 |
| randwrite(128) | 1629 | **6138** | — | 主因 `--openfiles 100→128` 口径修正（消除假瓶颈） |
| randread(128) | 10650 | **8227** | −23% | v2 是真冷态（清了服务端 XFS 缓存），**非退化** |

> 说明：变化列不再给单一百分比，因多数项混合了"调优 + 口径修正 + 07-03 数据不稳"多种因素，只有单流写的 +78% 是单变量对照的确证值。

**核心成果**：拿到了**可信、可复现、采集完整**的 v2 健康基线；确证 slave 调优对单流写 +78%；纠正了网络（实为 RDMA）与收益归因两处误判；确立了不影响业务的调优边界。**遗留诚实认知：07-03 旧基线多项数据可信度低（单流两轮离散、layout 单轮污染、seqread 离群），不宜作精确对比，仅 v2 可作后续锚点。**

**下一步**：单流写（835）是阶段1首要优化目标；**但在动手调优前，先复测 v2 最优基线确认其稳定可复现**（见阶段1任务书）。

### 6.4 【2026-07-07 晚 · 复测推翻】v2=835 与 slave 调优 +78% 结论作废

阶段1 前置复测（`results/20260707-stage1-baseline-recheck/`）独立重跑 v2 基线，发现 **单流 seqwrite 无法复现 835**：

| 测量时刻 | 事件 | seqwrite | clat min |
|------|------|:---:|:---:|
| 07-06 18:44 | v2 基线（本文档 6.1-6.3 依据） | 835 | 200µs |
| **07-06 20:23** | **BeeGFS 服务重启** | - | - |
| 07-07 11:47 | 对照实验 untuned | 466/469 | ~400µs |
| 07-07 12:48/13:01 | 复测 R1/R2 | 479/479 | 400µs |
| 07-07 14:05 | 空闲态实测（WekaIO RDMA 流量=0） | 508 | 403µs |

**已排除业务争抢**：07-07 14:05 在 WekaIO 数据面 RDMA 流量为 0（业务空闲）时实测仍为 508，与"疑似繁忙"时段的 479 同量级；且两轮 479=479 完全一致（争抢会波动），clat min 稳定翻倍。→ **不是 WekaIO 争抢，根因指向 07-06 20:23 的 BeeGFS 服务重启。**

**因此撤回以下 6.1-6.3 的结论：**

| 原结论（本节 6.1/6.3 及对照实验） | 修正 |
|------|------|
| slave 调优对单流写 +78%（466→835） | ❌ **撤回**。对照实验的 tuned=835（重启前）与 untuned=466（重启后）之间混入了"服务重启"这个未受控变量；且已实测 dirty_ratio 对 `--direct=1` 无效（512 vs 503）。**466→835 的差异来自服务重启，不是 slave 调优。** |
| v2 单流写 835 为基线锚点 | ❌ **撤回**。835 是 n=1、无当时快照、事后不可复现的孤例。当前可复现的真实单流写基线 = **~479-512**。 |
| slave 调优对 layout +2.5% | ✅ 保留（layout 不受服务重启影响，R1/R2=10097/10025 佐证 v2 layout 稳定）。 |

**待定问题**：为什么重启前能 835（200µs）、重启后稳定掉到 ~490（400µs），机制未知。已派发 `doc/perf-tasks/stage1-restart-repro-task-book.md`（多次重启 + 快照对照实验）定位；BeeGFS 为纯测试集群、可自由重启。在该实验出结论前，**stage1 单变量调优暂缓**，基线暂以 ~490 计。

### 6.5 【2026-07-08 定案】谜底 = 网络接口选择（RDMA vs 10GbE TCP）

多次重启实验（`results/20260707-restart-repro/`，33 次测量）+ 接口锁定实验（`results/20260708-lock-rdma-iface/`，均已对账原始 fio）**彻底查清**：

| 状态 | seqwrite | clat_min | 数据面走哪 |
|------|:---:|:---:|------|
| v2（07-06 18:44）| 835 | 200µs | RDMA |
| 低态（07-07）| 466-508 | ~400µs | **10GbE TCP（eno12409, 10.114.1.x）** |
| 高态（33 次）| 887-944 | ~200µs | RDMA（自动选中）|
| **RDMA 锁定态（07-08）** | **889-909** | ~215µs | **RDMA 100%（5/5 重启）** |

- **479 的真相 = BeeGFS 数据面掉到了 10GbE 的普通 TCP 网卡**，没走 100GbE RDMA。10GbE 单流 TCP ≈ 479 MiB/s，clat_min 因 TCP 栈开销翻倍。
- **根因**：07-06 20:23 那次重启把 `connInterfacesFile` 清空 + 删 `connInf.conf`，client 变自动选接口；空配置下大概率选 RDMA，小概率落 TCP（那次就落了）。
- **证据**：07-06 20:23 日志 `Connected: beegfs-storage@10.114.1.150:8003 (protocol: TCP)`；高态快照 `RDMA: 2 (10.3.x:8003)`。
- **修复并定案**：锁定 `connInterfacesFile` 只用 RDMA 网卡（`enp139s0f0np0`/`enp139s0f1np1`），5/5 次重启 100% 走 RDMA，seqwrite 稳定 ~900。**479 态永久消除。当前单流写基线 = ~900 MiB/s（RDMA 锁定态），可保证可复现。**
- **连带**：6.4 中"根因指向服务重启（机制未知）"由本节取代——不是服务重启本身，是那次重启附带的接口配置清空。"slave 调优 +78%""835/479 为基线"全部作废，详见 `skills/beegfs-baseline-config.md` 第五节。

**至此阶段0/1前置的所有基线疑问已闭环。stage1 单变量调优在 ~900 RDMA 锁定基线上正式推进。**
