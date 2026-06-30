# BeeGFS Storage Cluster — Production (4 Machines)

## 什么是 BeeGFS？

[BeeGFS](https://www.beegfs.io/) 是一个开源的并行文件系统，专为高性能计算（HPC）场景设计。被全球 TOP500 超算广泛采用。

### 主要特性

- **并行架构**: 元数据与存储分离，支持横向扩展
- **高性能**: 支持 stripe 条带化，高并发 I/O，InfiniBand/100GbE 网络
- **简单部署**: 无需复杂配置，类 NFS 的使用体验
- **客户端支持**: Linux FUSE 客户端，无需内核模块

### 本项目架构

采用 3 台存储节点 + 1 台客户端的设计：

```
                    BeeGFS Client (157)
                 (FUSE mount, IO only)
                         │
           ┌─────────────┼─────────────┐
           ▼             ▼             ▼
      Management    Metadata      Storage
      (mgmtd)       (meta)        (storage)
      ┌────────┐  ┌────────┐   ┌──────────────┐
      │ Slave1 │  │ Slave1 │   │ Slave1(2 tgt)│
      │  150   │  │150/151 │   │ Slave2(2 tgt)│
      │        │  │  152   │   │ Slave3(2 tgt)│
      └────────┘  └────────┘   └──────────────┘
```

**重要说明**: 157 只做客户端，不部署任何 BeeGFS 服务。

| 机器 | 内网 IP | 角色 | 说明 |
|------|---------|------|------|
| client | 10.20.1.157 | **仅客户端** | 只挂载，不部署服务（运行其他业务） |
| slave1 | 10.20.1.150 | mgmtd + meta + 2 storage | |
| slave2 | 10.20.1.151 | meta + 2 storage | |
| slave3 | 10.20.1.152 | meta + 2 storage | |

**Storage Targets**: 6 个 (slaves 各 2 个)

所有机器统一使用 **sunrise** 用户，特权操作用 `sudo`。
客户端通过公网 203.156.3.194:19891 SSH 跳转，从服务器通过内网 10.20.1.x 互访。

## 磁盘规划

| 机器 | 设备 | 容量 | 用途 | Target数 |
|------|------|------|------|----------|
| client (157) | - | - | 不动任何配置 | - |
| slave1 | `/dev/nvme2n1` | 7TB | /data/disk1 | 1 |
| slave1 | `/dev/nvme3n1` | 7TB | /data/disk2 | 1 |
| slave2 | `/dev/nvme2n1` | 7TB | /data/disk1 | 1 |
| slave2 | `/dev/nvme3n1` | 7TB | /data/disk2 | 1 |
| slave3 | `/dev/nvme2n1` | 7TB | /data/disk1 | 1 |
| slave3 | `/dev/nvme3n1` | 7TB | /data/disk2 | 1 |

## 网络

| 接口 | 速率 | 用途 |
|------|------|------|
| `eno12399` | 10 GbE | 管理网络 (10.20.1.0/24)，BeeGFS 通信 |
| `enp139s0f0np0` | 100 GbE | 高速网络 (10.3.1.0/24)，可选用于 BeeGFS 数据通道 |

## 快速开始

```bash
# 1. 准备所有服务器 (client 只装客户端包，slaves 完整准备)
bash prepare-all-servers.sh

# 2. 部署 BeeGFS 集群 (mgmtd/meta/storage 在 slaves，client 只mount)
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
