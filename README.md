# BeeGFS Storage Cluster — Production (4 Machines)

## 架构

```
                         BeeGFS Client
                    (FUSE mount, on master node)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         Management      Metadata        Storage
         (mgmtd)         (meta)          (storage)
        ┌────────┐    ┌────────┐    ┌──────────────┐
        │ Master │    │ Master │    │ Master(1 tgt)│
        │        │    │ + 3    │    │ + slaves(6 tg)│
        │        │    │ slaves │    │ (独立NVMe)   │
        └────────┘    └────────┘    └──────────────┘
         10.20.1.157   157/150/151/152  1+6 targets
```

| 机器 | 内网 IP | 角色 | 硬件 |
|------|---------|------|------|
| master | 10.20.1.157 | mgmtd + meta + **1 storage** + client | 96C/1TB RAM, 2×7TB NVMe RAID0 → 1 target, 1×894GB NVMe (空闲) |
| slave1 | 10.20.1.150 | meta + **2 storage** | 128C/1TB RAM, 2×7TB 独立NVMe → 2 targets, 1×894GB NVMe (空闲) |
| slave2 | 10.20.1.151 | meta + **2 storage** | 128C/1TB RAM, 2×7TB 独立NVMe → 2 targets, 1×894GB NVMe (空闲) |
| slave3 | 10.20.1.152 | meta + **2 storage** | 128C/1TB RAM, 2×7TB 独立NVMe → 2 targets, 1×894GB NVMe (空闲) |

**总计**: 1 + 6 = 7 个 storage targets

所有机器统一使用 **sunrise** 用户，特权操作用 `sudo`。
主服务器通过公网 203.156.3.194:19891 SSH 跳转，从服务器通过内网 10.20.1.x 互访。

## 磁盘规划

| 机器 | 设备 | 容量 | 用途 | Target数 |
|------|------|------|------|----------|
| master | `/dev/md0` (2×NVMe RAID0) | 14TB | /data/beegfs/storage | 1 |
| master | `/dev/nvme1n1` | 894GB | 空闲 (可选做metadata) | - |
| slave1-3 | `/dev/nvme2n1` | 7TB | /data/disk1 | 1 |
| slave1-3 | `/dev/nvme3n1` | 7TB | /data/disk2 | 1 |
| slave1-3 | `/dev/nvme1n1` | 894GB | 空闲 (可选做metadata) | - |

**设计说明**:
- Master 因运行 weka 系统，RAID0 无法拆除，用单 target
- Slaves 已拆除 RAID0，每台 2 个独立 NVMe，各部署 2 个 storage target
- 总共 7 个 target，BeeGFS stripe count 设为 7
- nvme1n1 (894GB) 空闲，可后续用于独立的 metadata target

## 网络

| 接口 | 速率 | 用途 |
|------|------|------|
| `eno12399` | 10 GbE | 管理网络 (10.20.1.0/24)，BeeGFS 通信 |
| `enp139s0f0np0` | 100 GbE | 高速网络 (10.3.1.0/24)，可选用于 BeeGFS 数据通道 |

## 快速开始

```bash
# 1. 准备所有服务器 (如已有RAID0需先拆)
bash prepare-all-servers.sh

# 2. 部署 BeeGFS 集群
bash deploy-beegfs.sh

# 3. 挂载并测试
bash deploy-beegfs.sh mount
bash deploy-beegfs.sh test

# 4. 基本读写测试
bash tests/bench-basic.sh

# 5. 全量性能测试
bash tests/bench-full.sh cold-r1 cold
```

## 目录结构

```
beegfs-production/
├── README.md
├── config.sh                  # 全局配置
├── setup-ssh-keys.sh          # SSH 密钥配置
├── prepare-servers.sh         # 单机初始化
├── prepare-all-servers.sh     # 批量初始化
├── deploy-beegfs.sh           # BeeGFS 部署
├── tune-servers.sh            # 系统调优
├── tests/                     # 测试脚本
│   ├── lib/
│   │   └── beegfs-health-check.sh
│   ├── bench-basic.sh         # 基本读写测试
│   └── bench-full.sh          # 全量性能测试
├── doc/                       # 文档
│   └── perf-analysis/         # 性能分析
├── results/                   # 测试结果
├── skills/                    # 规范文档
└── log/                       # 日志
```
