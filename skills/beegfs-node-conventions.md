---
name: beegfs-node-conventions
description: Use for ALL tasks involving file operations, cluster operations, or testing on the BeeGFS production environment. Defines the default remote host (client 10.20.1.157 via jump 203.156.3.194:19891), SSH credentials, and base working directory. Use ONLY when operating on the BeeGFS storage cluster environment.
---

# BeeGFS 生产环境操作规范

## 默认操作目标

**所有文件相关的操作** 默认在 **客户端服务器（157）** 上进行，除非有特殊说明。

| 属性       | 值                                   |
| ---------- | ------------------------------------ |
| 主机名     | oneasia-c1-cpu-node10 (client)       |
| 内网 IP    | 10.20.1.157                          |
| 公网 IP    | 203.156.3.194                        |
| SSH 端口   | 19891                                |
| 用户名     | sunrise                              |
| 密码       | Sunrise@801                          |
| 基础目录   | /home/sunrise/beegfs-production      |

### 从服务器

| 角色   | 内网 IP       | 用户名   | 密码          |
| ------ | ------------- | -------- | ------------- |
| slave1 | 10.20.1.150   | sunrise  | Sunrise@801   |
| slave2 | 10.20.1.151   | sunrise  | Sunrise@801   |
| slave3 | 10.20.1.152   | sunrise  | Sunrise@801   |

### 架构说明

- **Client (157)**: mgmtd + meta + client 服务 (用 nvme1n1, ext4)
- **Slave1 (150)**: meta + 2 storage targets
- **Slave2-3 (151-152)**: meta + 2 storage targets each
- **镜像**: metadata 2 buddy groups + storage 3 buddy groups
- **总计**: 4 metadata nodes + 6 storage targets

## 磁盘环境

| 机器 | 设备 | 容量 | 文件系统 | 用途 |
|------|------|------|---------|------|
| 157 | nvme1n1 | 894GB | ext4 | metadata (/mnt/beegfs-meta) |
| 150-152 | nvme1n1 | 894GB | ext4 | metadata (/mnt/beegfs-meta) |
| 150-152 | nvme2n1 | 7TB | XFS | storage (/data/disk1) |
| 150-152 | nvme3n1 | 7TB | XFS | storage (/data/disk2) |

## SSH 连接方式

### 从 WSL 连接客户端

```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
```

### 从客户端连接从服务器

```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 "<command>"
```

### 两级跳转（WSL → client → slave）

```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 '<command>'"
```

## 网络

| 接口             | 速率     | 网段          | 用途                       |
| ---------------- | -------- | ------------- | -------------------------- |
| eno12399         | 10 GbE   | 10.20.1.0/24  | 管理网络 + **BeeGFS 数据通道** |
| enp139s0f0np0    | 100 GbE  | 10.3.1.0/24   | 高速网络, 不用于 BeeGFS     |

## 文件操作规范

1. **所有文件路径** 默认相对于 `/home/sunrise/beegfs-production/`（客户端上的该目录）。
2. 读写文件、创建目录、编辑脚本等操作都在客户端上执行。
3. 除非用户明确指定本地路径或其他远程主机，否则一律使用客户端。

## 调优说明 (per 官方文档)

| 项目 | BeeGFS 官方建议 | 注意 |
|------|----------------|------|
| THP | **always** (启用) | 与 Ceph 项目相反 |
| IO 调度器 | deadline(sd*)/none(NVMe) | NVMe 内核强制 none |
| XFS 挂载 | noatime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,allocsize=131072k | 官方推荐 |
| dirty_ratio | 5/10 | 官方生产建议 |

## 目录结构

```
/home/sunrise/beegfs-production/
├── README.md
├── config.sh
├── setup-ssh-keys.sh
├── prepare-servers.sh
├── prepare-all-servers.sh
├── deploy-beegfs.sh
├── tune-servers.sh
├── tests/
│   ├── lib/
│   ├── bench-basic.sh
│   └── bench-full.sh
├── doc/
│   └── perf-analysis/
├── results/
├── skills/
└── log/
```

## 执行命令的注意事项

1. 使用 `sshpass` 时始终添加 `-o StrictHostKeyChecking=no`。
2. 远程命令中的路径应使用绝对路径。
3. 长时间运行的命令应加 `timeout` 或使用 `nohup` 后台运行。
4. sudo 需要密码：`echo 'Sunrise@801' | sudo -S <command>`（prepare-servers.sh 配置 NOPASSWD 后则不需要）。
