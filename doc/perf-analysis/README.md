# BeeGFS 性能分析

本目录存放 BeeGFS 集群的性能调优过程文档，参考 JuiceFS+Ceph 项目的 perf-analysis 结构。

## 文档规划

| 文件 | 内容 |
|------|------|
| `01-measured-data.md` | 初始部署后的基线测量数据 |
| `02-bottleneck-analysis.md` | 瓶颈分析（网络/磁盘/CPU/FUSE） |
| `03-tuning-progress.md` | 调优进展总览 |
| `04-next-steps.md` | 后续调优方向 |
| `README.md` | 本文件 |

## 环境概况

**重要**: 157 只做客户端，不部署任何 BeeGFS 服务。

- **集群拓扑**：
  - Client (10.20.1.157): 仅 FUSE 客户端挂载点
  - Slave1 (10.20.1.150): mgmtd + meta + 2 storage targets
  - Slave2-3 (10.20.1.151-152): meta + 2 storage targets each
- **Storage Targets**: 6 个
- **存储**：
  - Slaves: 各 2×7TB 独立 NVMe → 各 2 targets
- **网络**：10 GbE 管理网络 (eno12399) + 100 GbE 高速网络 (enp139s0f0np0)
- **CPU**：96-128 cores per node, Intel Xeon Platinum 8462Y+
- **内存**：1TB per node
- **OS**：Ubuntu 22.04.5 LTS, kernel 5.15.0-170

## 参考基线（JuiceFS+Ceph 项目）

JuiceFS + Ceph EC 4+2 (3 nodes, HDD-backed) 的 cold-r1 基线：
- seqread: 77.7 MiB/s
- seqwrite: 50.8 MiB/s
- multi-seqread (16 jobs): 110 MiB/s
- multi-seqwrite (16 jobs): 41.5 MiB/s
- randread (bs=256K): 33.6 MiB/s
- randwrite (bs=256K): 29.0 MiB/s
- randrw (bs=256K): 15.1/14.7 MiB/s

BeeGFS + NVMe + 100GbE 网络，预期性能应显著高于此基线。

## 磁盘配置说明

| 机器 | 磁盘配置 | Storage Targets |
|------|----------|-----------------|
| client (157) | 不动任何配置 | - |
| slave1 | 2×7TB 独立 NVMe | 2 |
| slave2 | 2×7TB 独立 NVMe | 2 |
| slave3 | 2×7TB 独立 NVMe | 2 |
