---
name: beegfs-node-conventions
description: Use for ALL tasks involving file operations, cluster operations, or testing on the BeeGFS production environment. Defines the default remote host (master 10.20.1.157 via jump 203.156.3.194:19891), SSH credentials, and base working directory. Use ONLY when operating on the BeeGFS storage cluster environment.
---

# BeeGFS 生产环境操作规范

## 默认操作目标

**所有文件相关的操作** 默认在 **主服务器（master）** 上进行，除非有特殊说明。

| 属性       | 值                                   |
| ---------- | ------------------------------------ |
| 主机名     | oneasia-c1-cpu-node10 (master)       |
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

## SSH 连接方式

### 从 WSL 连接主服务器

```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
```

文件传输：

```bash
sshpass -p 'Sunrise@801' scp -o StrictHostKeyChecking=no -P 19891 <local_file> sunrise@203.156.3.194:/home/sunrise/beegfs-production/<path>
```

### 从主服务器连接从服务器

```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 "<command>"
```

### 两级跳转（WSL → master → slave）

```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.150 '<command>'"
```

## 磁盘环境

| 设备         | 容量    | 用途                                   |
| ------------ | ------- | -------------------------------------- |
| /dev/md0     | 14TB    | 2×NVMe RAID0，已挂载 /data，BeeGFS 数据 |
| /dev/nvme1n1 | 894GB   | 空闲裸盘，可用于 metadata target        |
| /dev/nvme0n1 | 894GB   | 系统盘（/ 和 /boot/efi）                |

## 网络

| 接口             | 速率     | 网段          | 用途           |
| ---------------- | -------- | ------------- | -------------- |
| eno12399         | 10 GbE   | 10.20.1.0/24  | 管理网络       |
| enp139s0f0np0    | 100 GbE  | 10.3.1.0/24   | 高速数据网络   |

## 文件操作规范

1. **所有文件路径** 默认相对于 `/home/sunrise/beegfs-production/`（主服务器上的该目录）。
2. 读写文件、创建目录、编辑脚本等操作都在主服务器上执行。
3. 除非用户明确指定本地路径或其他远程主机，否则一律使用主服务器。
4. 集群相关的测试也基于主服务器执行（主服务器也是客户端）。

## 文档编号规范

当用户提起**文档编号**（如"文档01"、"文档10"等）时，默认指向 `/home/sunrise/beegfs-production/doc/perf-analysis/` 目录下对应的 `.md` 文件。

例如：
- "文档01" → `doc/perf-analysis/01-measured-data.md`

## 集群测试规范

- 测试脚本位于 `/home/sunrise/beegfs-production/tests/` 目录。
- 测试结果存放在 `/home/sunrise/beegfs-production/results/` 目录。
- 部署脚本位于根目录（如 `deploy-beegfs.sh`）。
- 配置文件位于 `config.sh`。
- 日志文件位于 `/home/sunrise/beegfs-production/log/` 目录。

## 目录结构概览

```
/home/sunrise/beegfs-production/
├── README.md                  # 项目说明
├── config.sh                  # 环境配置
├── setup-ssh-keys.sh          # SSH 密钥配置
├── prepare-servers.sh         # 单机初始化
├── prepare-all-servers.sh     # 批量初始化
├── deploy-beegfs.sh           # BeeGFS 部署
├── tune-servers.sh            # 系统调优
├── tests/                     # 测试脚本
│   ├── lib/                   # 测试库
│   ├── bench-basic.sh         # 基本读写测试
│   └── bench-full.sh          # 全量性能测试
├── doc/                       # 文档
│   └── perf-analysis/         # 性能分析
├── results/                   # 测试结果
├── skills/                    # 规范文档
└── log/                       # 日志
```

## 执行命令的注意事项

1. 使用 `sshpass` 时始终添加 `-o StrictHostKeyChecking=no` 避免主机密钥确认提示。
2. 远程命令中的路径应使用绝对路径。
3. 需要交互式操作的命令应避免直接通过 SSH 执行，改用非交互式替代方案。
4. 长时间运行的命令应加 `timeout` 或使用 `nohup` 后台运行。
5. sudo 需要密码：`echo 'Sunrise@801' | sudo -S <command>`（prepare-servers.sh 配置 NOPASSWD 后则不需要）。
