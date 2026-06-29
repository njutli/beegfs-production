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
        │ Master │    │ Master │    │ Master       │
        │        │    │ + 3    │    │ + 3 slaves   │
        │        │    │ slaves │    │ (NVMe RAID0) │
        └────────┘    └────────┘    └──────────────┘
         10.20.1.157   157/150/151/152  157/150/151/152
```

| 机器 | 内网 IP | 角色 | 硬件 |
|------|---------|------|------|
| master | 10.20.1.157 | mgmtd + meta + storage + client | 96C/1TB RAM, 2×7TB NVMe RAID0 (/data), 1×894GB NVMe (空闲) |
| slave1 | 10.20.1.150 | meta + storage | 128C/1TB RAM, 2×7TB NVMe RAID0 (/data), 1×894GB NVMe (空闲) |
| slave2 | 10.20.1.151 | meta + storage | 128C/1TB RAM, 2×7TB NVMe RAID0 (/data), 1×894GB NVMe (空闲) |
| slave3 | 10.20.1.152 | meta + storage | 128C/1TB RAM, 2×7TB NVMe RAID0 (/data), 1×894GB NVMe (空闲) |

所有机器统一使用 **sunrise** 用户，特权操作用 `sudo`。
主服务器通过公网 203.156.3.194:19891 SSH 跳转，从服务器通过内网 10.20.1.x 互访。

## 磁盘规划

每台服务器有两类可用磁盘：

| 设备 | 容量 | 用途 |
|------|------|------|
| `/dev/md0` (2×NVMe RAID0) | 14TB | 已挂载在 `/data`，BeeGFS storage target 数据目录 |
| `/dev/nvme1n1` | 894GB | 空闲裸盘，可用于 metadata target 或额外 storage target |

**初始部署策略**：在 `/data` 上建立 BeeGFS 目录结构，不破坏现有 RAID0。
如需更高性能，后续可将 `nvme1n1` 格式化后用作独立的 metadata target。

## 网络

| 接口 | 速率 | 用途 |
|------|------|------|
| `eno12399` | 10 GbE | 管理网络 (10.20.1.0/24)，BeeGFS 通信 |
| `enp139s0f0np0` | 100 GbE | 高速网络 (10.3.1.0/24)，可选用于 BeeGFS 数据通道 |

## 快速开始

```bash
# 1. 准备所有服务器
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
