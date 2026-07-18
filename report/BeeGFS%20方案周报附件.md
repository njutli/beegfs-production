# BeeGFS 存储方案性能测试与调优 — 周报附件

> 周期：2026-07-10 ~ 2026-07-15（35 次提交，6678 个结果文件，331MB 原始数据）
> 集群：4 节点 BeeGFS 7.3.2（157 client+mgmtd+meta / 150·151·152 meta+2storage）
> 关联文档：[演进报告](report/BeeGFS%20方案性能调优演进报告.md) · [简报](report/BeeGFS%20方案性能测试与分析简报.md) · [调优主文档](doc/perf-analysis/01-beegfs-perf-tuning.md) · [Stage3 汇总](results/stage3-summary.md)

---

## 一、本周工作概述

本周在 4 节点物理集群上完成了 BeeGFS 并行文件系统的**从零部署 → 性能调优 → 对齐 JuiceFS 口径的方案对比基线**全链路工作，共经历 4 个阶段（stage0-3），累计 100+ 轮 fio 测试，所有结论均有原始 fio 输出 + 交叉验证数据（IB counters / iostat / sar）支撑。

### 工作量统计

| 维度 | 数量 |
|------|------|
| Git 提交 | 35 次 |
| 测试轮次 | 100+ 轮 fio |
| 原始数据文件 | 6678 个（331MB） |
| 测试脚本 | 31 个 |
| 分析文档 | 14 份 |
| 调优参数穷举 | 5 变量 × 28 轮（单流写应用层穷举） |
| 双口径测试矩阵 | 12 项 × 2 口径 = 24 组 |
| 部署/清理脚本 | 全量 deploy/clean/prepare/tune/limit-bandwidth 五件套 |

---

## 二、阶段划分与核心成果

### Stage 0：环境部署与脚本工程（7/10）

**工作内容**：从零搭建 BeeGFS 7.3.2 集群（4 节点、Buddy Mirror、6 × 7TB NVMe），编写全量部署/清理/调优/限速脚本。

**核心成果**：
- 一键部署脚本 `deploy-beegfs.sh`（支持 status/install/deploy/mount/unmount/test/verify 7 个子命令）
- 一键清理脚本 `clean-beegfs.sh`（dry-run + --yes + --purge 三档，保守清理 157 / 彻底清理 slaves）
- 三层 SSH 跳板框架（WSL → HK ECS → 157 → slaves），用 base64 编码解决多层引号嵌套问题
- 限速脚本 `limit-bandwidth.sh`（eno12409 独立 10GbE 网卡 + tc tbf 1Gbps，不影响 100GbE RDMA 业务网）
- 确立三条安全红线：不动 157 内核参数 / 不动 100GbE 网卡驱动 RoCE QoS / 不动根目录 stripe

**价值**：将 4 节点集群的部署从手工操作变为可重复的一键流程，后续每次重部署/清理仅需 1 条命令。

### Stage 1：单流写调优与 RDMA 接口锁定（7/10-7/11）

**工作内容**：排查单流写基线在 479 与 900 两个值间反复的异常，定位根因，穷举应用层参数。

**核心成果**：
- **"479 之谜"彻底查清**：33 次重启测量 + 日志根因分析，定位为 `connInterfacesFile` 被清空 → client 自动选接口 → 小概率落 10GbE TCP。锁定 RDMA 接口后 5/5 次重启 100% 走 RDMA，单流写固定 ~900 MiB/s。
- **单流写应用层穷举（5 变量 28 轮）**：connRDMABufNum/BufSize、tuneNumWorkers、chunksize、fsync 全部在噪音范围（±3%）无正收益。结论：单流写被 per-IO 延迟（clat ~273µs）主导，~900 是物理天花板。
- **决定性证据**：移除 fsync 仍 916 vs 916 → `--direct=1` 下每个 write 本身同步，瓶颈在写路径不在后端落盘。

**价值**：用穷举证据坐实"单流写不可调优"，避免后续在无效方向上浪费资源。

### Stage 2：双口径基线 + 未达标项瓶颈坐实（7/11-7/14）

**工作内容**：建立 100GbE RDMA 不限速 + 千兆限速双口径全量基线，对 6 项未达标项逐项抓直接实测证据。

**核心成果**：

**口径A（100GbE RDMA 不限速）基线**：

| 测试项 | 带宽 (MiB/s) | %线速 | 达标? |
|--------|:---:|:---:|:---:|
| multi-seqwrite 16 | 7731 | 61.8% | ✓ |
| layout 128/4M | 10199 | 81.6% | ✓ |
| randread 128 | 9252-10752 | 74-86% | ✓ |
| randwrite 128 | 6146 | 49.2% | ✗ (临界) |
| seqwrite 单流 | 840 | 6.7% | ✗ (延迟天花板) |

**6 项未达标项瓶颈坐实**（均有直接实测证据）：

| 未达标项 | 根因 | 关键证据 |
|----------|------|---------|
| 单流 seqread/seqwrite | per-IO 延迟主导 | NIC 利用率仅 6.7-11.7%（IB counters 实测） |
| randwrite 49.2% | Buddy Mirror 2× 写放大 | 非镜像对照 11520 vs 镜像 6545 = 1.76× |
| randrw 37.1% | 派生于 randwrite | 无独立手段 |
| randread-64K 38.1% | 小块 per-IO 固定开销 | IOPS 76k 但 bw 仅 4766（1M 的 0.41×） |
| 千兆单流 seqwrite 45% | QD1 串行 + 镜像双写 | NIC 利用率 45%（sar 实测） |

**价值**：全部 6 项未达标项均用直接实测证据坐实根因（非带宽不足、非配置错误），在三条安全红线约束下无合法优化手段，**全项结案**。

### Stage 3：对齐 JuiceFS 口径的双口径重测（7/14-7/15）

**工作内容**：为与 JuiceFS+Ceph 方案横向对比，用完全对齐的 fio 参数（bs=4M 写、180s runtime、bw_log 稳态中位数、3 轮取 r1）重测双口径全量矩阵。

**核心成果**：

| 测试项 | 口径A (RDMA) | 口径B (千兆) | stage2 旧值 | 差异说明 |
|--------|:---:|:---:|:---:|------|
| seqread | 1644 | 104.2 | 1516 / 104 | 180s 稳态 vs 2.7s 瞬态 |
| **seqwrite (4M)** | **1906** | **64.0** | 832 / 53.3 | bs 256K→4M，+129% / +20% |
| randread | 9045 | 341.6 | 9252 / 339 | ~0% |
| randwrite | 6505 | 111.6 | 6146 / 111 | +6% / ~0% |
| randrw R/W | 4853/4836 | 105/106 | 4645/4641 / 108/107 | +4% / ~0% |

**关键发现**：
- **BeeGFS fio 平均 ≈ 稳态中位数（差异 ≤3.5%）**：BeeGFS 是内核模块（非 FUSE），`--direct=1` 真正绕过所有客户端缓冲。与 JuiceFS（FUSE 缓冲拉高 7-8%）形成对比——BeeGFS 的 fio 平均值可信。
- **seqwrite bs=4M vs 256K**：口径A 832→1906（+129%），4M 大块写效率远高于 256K。此为口径差异非性能变化。
- **口径B 限速模型**：tbf 只限 egress，读 = 3 slave 各千兆之和 ≈ 340，写 = 157 单口千兆 ≈ 113。与 JuiceFS 完全同口径，直接可比。

**口径B 切网问题排查**（3 个坑，均已记录修复方案）：
1. `connInterfacesFile` 在 conf 中为空值（deploy 脚本不设置此参数）
2. `sysMgmtdHost` 需改为 eno12409 网段 IP
3. rootcause-enter-kB.sh 的 sed 未匹配注释行

**价值**：产出与 JuiceFS 参数完全对齐的双口径基线数据，可直接做方案间横向对比。

---

## 三、工程产出物清单

### 脚本（31 个）

| 脚本 | 说明 |
|------|------|
| `deploy-beegfs.sh` | 一键部署（7 子命令，含 verify 强校验） |
| `clean-beegfs.sh` | 一键清理（dry-run/--yes/--purge 三档） |
| `prepare-all-servers.sh` / `prepare-servers.sh` | 磁盘初始化（XFS/ext4 挂载 + fstab） |
| `tune-servers.sh` | 服务端内核调优（THP/dirty/read_ahead/NVMe 调度） |
| `limit-bandwidth.sh` | 千兆限速切换（tc tbf + 网络切换） |
| `setup-ssh-keys.sh` | 三层跳板 SSH 密钥分发 |
| `tests/bench-full.sh` | 全量性能测试（stage2 口径） |
| `tests/stage3-kA.sh` / `stage3-kA-item9.sh` / `stage3-kA-item10.sh` | 对齐口径测试脚本（stage3） |
| `tests/stage3-median.py` | 稳态中位数计算（bw_log 截尾取中位数） |
| `tests/rootcause-*.sh` × 6 | 瓶颈坐实测试脚本（NIC 利用率/写放大/IOPS 分解/口径B 切网/恢复） |
| `tests/var-*.sh` × 5 | 单变量调优脚本（bufnum/bufsize/workers/chunksize/fsync） |
| `tests/lib/ib-iostat-sampler.sh` | IB counters + iostat 采样器 |

### 文档（14 份）

| 文档 | 说明 |
|------|------|
| `report/BeeGFS 方案性能调优演进报告.md` | 完整演进报告（向领导汇报版） |
| `report/BeeGFS 方案性能测试与分析简报.md` | 精简版简报（一页纸） |
| `doc/perf-analysis/01-beegfs-perf-tuning.md` | 调优主文档（单一现行文档，合并原 01/02） |
| `doc/perf-tasks/stage0~3-*-task-book.md` × 6 | 各阶段任务书（自包含，新会话可直接执行） |
| `doc/perf-tasks/stage3-kB-network-fix.md` | 口径B 切网问题与解决记录 |
| `results/stage3-summary.md` | Stage3 对齐口径重测完整汇总 |
| `results/20260708-stage2-dual-baseline/README.md` | Stage2 双口径基线 |
| `results/20260709-stage2-unmet-rootcause/README.md` | Stage2 瓶颈坐实 |
| `skills/LONG-RUNNING-TEST-SKILL.md` | 长时间测试监控方法论 |

### 原始数据（6678 个文件，331MB）

| 目录 | 说明 | 文件数 |
|------|------|:------:|
| `results/20260708-stage2-dual-baseline/` | stage2 双口径基线（5 轮 raw） | ~500 |
| `results/20260709-stage2-unmet-rootcause/` | stage2 瓶颈坐实（IB/iostat/写放大对照） | ~190 |
| `results/stage3-aligned-nolimit-20260715-155122/` | stage3 口径A 全量（bw_log + IB + iostat） | 2999 |
| `results/stage3-aligned-1gbit-20260715-191158/` | stage3 口径B 全量（bw_log + IB + iostat） | 2998 |

每项测试产出 5 类文件：fio 原始输出 + bw_log（逐秒瞬时带宽）+ IB counters + iostat（磁盘活动）+ summary.md（运行日志）。

---

## 四、核心结论

1. **单流写 ~900 MiB/s 是物理天花板**：per-IO 延迟（clat ~273µs）主导，5 变量 28 轮穷举无正收益，RDMA 往返 + BeeGFS 协议 + Buddy Mirror 双写 + NVMe 落盘的固有地板。

2. **6 项未达标项全项结案**：瓶颈均为延迟主导 / 写放大 / 小块开销（非带宽不足、非配置错误），在三条安全红线约束下无合法优化手段。

3. **BeeGFS 无 FUSE 缓冲虚高**：内核模块 + `--direct=1` 真绕缓冲，fio 平均 ≈ 稳态中位数（≤3.5%），与 JuiceFS FUSE 缓冲拉高 7-8% 形成对比。

4. **对齐口径基线已就绪**：双口径 12 项全量数据，参数与 JuiceFS 完全对齐（bs=4M 写、180s、bw_log、3 轮取 r1），可直接做方案间横向对比。

---

## 五、与 JuiceFS 方案对比要点

| 维度 | BeeGFS | JuiceFS+Ceph |
|------|--------|-------------|
| 客户端架构 | 内核模块 | FUSE 用户态 |
| --direct=1 效果 | 真绕缓冲（fio 平均≈中位数） | 绕不开 FUSE 缓冲（平均被拉高 7-8%） |
| 达标口径 | fio 平均或稳态中位数均可 | 必须用稳态中位数 |
| 测试参数 | 已对齐（bs=4M/180s/bw_log/3轮r1） | 已对齐 |
| 千兆限速模型 | tbf 限 egress，读=3×118≈340，写=1×118≈113 | 同口径（tbf 在 3 服务端，客户端不限速） |

两方案参数已完全对齐，横向对比时统一取稳态中位数。
