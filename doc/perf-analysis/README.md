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

**架构**: 4 节点，启用 metadata + storage 镜像

- **Client (10.20.1.157)**: mgmtd + meta + client (nvme1n1 ext4)
- **Slave1 (10.20.1.150)**: meta + 2 storage (nvme1n1 + 2×XFS)
- **Slave2-3 (10.20.1.151-152)**: meta + 2 storage (同上)

**镜像配置**:
- Metadata: 2 buddy groups (4 meta nodes)
- Storage: 3 buddy groups (6 targets)

**磁盘**:
- Metadata: nvme1n1 (894GB, ext4) — 独立盘，I/O 隔离
- Storage: nvme2n1 + nvme3n1 (各 7TB, XFS) — 独立盘

**网络**: 10 GbE (eno12399) + 100 GbE (enp139s0f0np0)

**调优 (per 官方文档)**:
- THP: always (启用，与 Ceph 相反)
- IO 调度器: deadline
- XFS 挂载: noatime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,allocsize=131072k
- dirty_ratio: 5/20

## 参考基线（JuiceFS+Ceph 项目）

JuiceFS + Ceph EC 4+2 (3 nodes, HDD-backed) 的 cold-r1 基线：
- seqread: 77.7 MiB/s
- seqwrite: 50.8 MiB/s
- multi-seqread (16 jobs): 110 MiB/s
- multi-seqwrite (16 jobs): 41.5 MiB/s
- randread (bs=256K): 33.6 MiB/s
- randwrite (bs=256K): 29.0 MiB/s
- randrw (bs=256K): 15.1/14.7 MiB/s

BeeGFS + NVMe + 100GbE + 镜像，预期性能应显著高于此基线。

## 官方文档参考

- 架构: https://doc.beegfs.io/latest/architecture/overview.html
- 镜像: https://doc.beegfs.io/latest/advanced_topics/mirroring.html
- 存储调优: https://doc.beegfs.io/latest/advanced_topics/storage_tuning.html
- 条带化: https://doc.beegfs.io/latest/advanced_topics/striping.html
