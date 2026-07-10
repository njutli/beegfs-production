# 0.6 — 157 共部署证据结论

## 环境概况
- **CPU**: 96 核，基线负载 ~17（WekaIO 16 个 wekanode 进程各 ~102% = 16 核）
- **内存**: 1TB，基线 used 109GB，available 885GB
- **BeeGFS 服务**: mgmtd + meta + helperd，基线全部 0% CPU
- **网络**: BeeGFS 使用 **RDMA (RoCE)** 走 100GbE Mellanox mlx5_0/mlx5_1，不走 TCP 栈

## seqwrite（单流，bs=256K，direct=1，60s time_based）

| 指标 | 值 |
|------|-----|
| fio 吞吐 | 839 MiB/s（49.1GiB/60s） |
| fio CPU | ~30% 单核（2 个 fio 进程: 20% + 10%） |
| fio 内存 | ~0% (6.5MB RES) |
| BeeGFS 服务 CPU | mgmtd/meta/helperd 全部 0% |
| WekaIO CPU | 不变（16 wekanode 各 ~102%） |
| 系统负载 | 16.76 → 16.72（无增长） |
| 内存 | 109GB → 109GB（无增长） |
| clat | avg 261μs（稳定） |

## randwrite（128 并发，bs=256K，direct=1，60s time_based）

| 指标 | 值 |
|------|-----|
| fio 吞吐 | 6236 MiB/s（366GiB/60s，24.9k IOPS） |
| fio CPU | 128 进程各 ~62% = ~79 核（sys=61.4%） |
| fio 内存 | ~0% (40MB RES per job) |
| BeeGFS 服务 CPU | mgmtd/meta/helperd 全部 0% |
| WekaIO CPU | 不变（16 wekanode 各 ~102%） |
| 系统负载 | 16.52 → 90.45（96 核内，fio 结束后回落） |
| 系统空闲 | 86.8% → 26.7%（fio 释放后恢复） |
| 内存 | 115GB → 115GB（增 4GB，可忽略） |
| clat | avg 647ms（高并发排队正常） |
| slat | avg 5.1ms |

## 网络流量异常说明

fio 写入 366GiB 但 /proc/net/dev 各接口 TX 计数器仅增 ~227MB（0.06%）。原因：
- **connUseRDMA = true**（客户端配置）
- **mlx5_0 + mlx5_1**（Mellanox ConnectX RDMA 卡）
- 存储节点注册 `enp139s0f1np1(RDMA)` + `enp139s0f0np0(RDMA)`
- RDMA 流量不走 TCP 栈，不记入 /proc/net/dev
- 需查 `/sys/class/infiniband/mlx5_*/ports/*/counters/` 才能看到 RDMA 流量

## 结论

**157 共部署不是瓶颈**：
1. BeeGFS 服务（mgmtd + meta + helperd）在 seqwrite 和 randwrite 期间均为 0% CPU，不与 fio 竞争资源
2. 96 核 CPU 充裕：seqwrite 用 0.3 核，randwrite 用 79 核，WekaIO 16 核不变，仍有余量
3. 1TB 内存充裕：两轮测试内存变化 <5GB
4. **无需拆独立 client 节点**（至少当前负载下不需要）
5. WekaIO 业务在两轮 fio 测试期间 CPU/内存无变化，未受影响

## 对后续阶段的建议
- 157 共部署可作为阶段 5（拆独立 client）的基线对比，当前不需要拆分
- RDMA 是 BeeGFS 默认数据通道（100GbE），限速方案用 connInterfacesFile 强制 TCP+TBF 才有效
- /proc/net/dev 不能用于监控 BeeGFS RDMA 流量，需用 ibstat/rdma 工具
