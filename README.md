# BeeGFS Storage Cluster — Production (4 Machines)

## 什么是 BeeGFS？

[BeeGFS](https://www.beegfs.io/) 是一个开源的并行文件系统，专为高性能计算（HPC）场景设计。被全球 TOP500 超算广泛采用。

### 主要特性

- **并行架构**: 元数据与存储分离，支持横向扩展
- **高性能**: 支持 stripe 条带化，高并发 I/O，InfiniBand/100GbE 网络
- **简单部署**: 无需复杂配置，类 NFS 的使用体验
- **客户端支持**: Linux 内核模块客户端，无需 FUSE
- **数据镜像**: 基于 buddy group 的元数据和存储镜像，节点级冗余

### 官方文档

- 架构: https://doc.beegfs.io/latest/architecture/overview.html
- 快速开始: https://doc.beegfs.io/latest/quick_start_guide/quick_start_guide.html
- 镜像: https://doc.beegfs.io/latest/advanced_topics/mirroring.html
- 存储调优: https://doc.beegfs.io/latest/advanced_topics/storage_tuning.html
- 条带化: https://doc.beegfs.io/latest/advanced_topics/striping.html

## 架构

```
                     BeeGFS Client (157)
                   (mgmtd + FUSE mount + meta)
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
       Management      Metadata      Storage
       (mgmtd)         (meta×4)      (storage×6)
       ┌────────┐   ┌─────────┐   ┌────────────┐
       │  (157) │   │157/150  │   │Slave1(2 tgt)│
       │        │   │151/152  │   │Slave2(2 tgt)│
       │        │   │ (镜像)  │   │Slave3(2 tgt)│
       └────────┘   └─────────┘   │  (镜像)    │
                                  └────────────┘
```

**重要说明**: 157 运行 mgmtd + client + metadata 服务（用空闲的 nvme1n1），不运行 storage 服务。mgmtd 放在 157 而非 slave，确保任意 storage 节点宕机不影响管理面。

| 机器 | 内网 IP | 角色 | 磁盘 |
|------|---------|------|------|
| client | 10.20.1.157 | **mgmtd** + client + meta | nvme1n1(894G ext4) → metadata |
| slave1 | 10.20.1.150 | meta + 2 storage | nvme1n1(ext4) + nvme2n1(XFS) + nvme3n1(XFS) |
| slave2 | 10.20.1.151 | meta + 2 storage | 同上 |
| slave3 | 10.20.1.152 | meta + 2 storage | 同上 |

## 服务分布

| 服务 | 157(client) | 150(slave1) | 151(slave2) | 152(slave3) |
|------|:-----------:|:-----------:|:-----------:|:-----------:|
| **mgmtd** | ✅ | - | - | - |
| **meta** | ✅ | ✅ | ✅ | ✅ |
| **storage (2 targets)** | - | ✅ | ✅ | ✅ |

## 镜像配置 (Buddy Groups)

### Metadata 镜像 (2 groups)

| Buddy Group | Primary | Secondary |
|-------------|---------|-----------|
| 1 | 150-meta | 151-meta |
| 2 | 152-meta | 157-meta |

### Storage 镜像 (3 groups)

| Buddy Group | Primary | Secondary |
|-------------|---------|-----------|
| 1 | 150-disk1 | 151-disk1 |
| 2 | 150-disk2 | 152-disk1 |
| 3 | 151-disk2 | 152-disk2 |

**故障容忍**: 任一节点宕机，数据仍可访问（从 buddy group 的另一个节点读取）。

## 磁盘规划

| 机器 | 设备 | 容量 | 文件系统 | 用途 |
|------|------|------|---------|------|
| client (157) | nvme1n1 | 894GB | ext4 | metadata (/mnt/beegfs-meta) |
| slave1-3 | nvme1n1 | 894GB | ext4 | metadata (/mnt/beegfs-meta) |
| slave1-3 | nvme2n1 | 7TB | XFS | storage target 1 (/data/disk1) |
| slave1-3 | nvme3n1 | 7TB | XFS | storage target 2 (/data/disk2) |

**官方推荐**:
- Storage: XFS (官方推荐，高吞吐)
- Metadata: ext4 (官方推荐，支持 xattr)
- 独立磁盘隔离 metadata 和 storage I/O

## 网络

| 接口 | 速率 | 用途 |
|------|------|------|
| `eno12399` | 10 GbE | 管理网络 (10.20.1.0/24)，**BeeGFS 数据通道** |
| `enp139s0f0np0` | 100 GbE | 高速网络 (10.3.1.0/24)，不用于 BeeGFS |

性能对比测试时用 `limit-bandwidth.sh` 把 `eno12399` 限速到 1Gbps 模拟千兆环境。

## 调优 (per 官方文档)

| 项目 | 官方建议 | 说明 |
|------|---------|------|
| THP | **always** (启用) | 与 Ceph 相反，BeeGFS 推荐 |
| IO 调度器 | deadline(sd*)/none(NVMe) | NVMe 内核强制 none, 全 NVMe 环境实际为 none |
| dirty_ratio | 5/10 | 官方生产建议 |
| read_ahead | 4096KB | 官方推荐 |
| XFS 挂载 | noatime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,allocsize=131072k | 官方推荐 |
| CPU governor | performance | 禁用节能 |

## 快速开始

> 从 WSL 通过跳板机执行。SSH 路径：WSL → HK ECS(190.92.233.189) → 泰国 client(203.156.3.194:19891) → 内网 slaves

```bash
# 0. 前置：首次需建立 WSL → HK ECS 跳板机的免密登录
sshpass -p 'Sunrise@801' ssh-copy-id -o StrictHostKeyChecking=no root@190.92.233.189

# 1. SSH 密钥分发（分发到 client 157 和所有 slave）
bash setup-ssh-keys.sh

# 2. 准备所有服务器
bash prepare-all-servers.sh

# 3. 部署 BeeGFS 集群 (含镜像)
bash deploy-beegfs.sh deploy

# 4. 挂载并测试
bash deploy-beegfs.sh mount
bash deploy-beegfs.sh test

# 5. 调优 (per 官方文档)
# 需要将 tune-servers.sh 传到每台 slave 上以 root 执行。
# 例如 slave 150:
#   scp_to tune-servers.sh 10.20.1.150 /tmp/tune-servers.sh
#   ssh_to_slave 10.20.1.150 "sudo bash /tmp/tune-servers.sh"

# 6. 基本读写测试
bash tests/bench-basic.sh

# 7. 全量性能测试
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
├── deploy-beegfs.sh           # BeeGFS 部署 (含镜像)
├── clean-beegfs.sh            # 清理 (恢复未部署状态, 157 保守不碰业务)
├── tune-servers.sh            # 系统调优 (per 官方文档)
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
