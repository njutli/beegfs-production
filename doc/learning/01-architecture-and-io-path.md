# BeeGFS 架构与 I/O 路径学习笔记

> 基于 2026-07-03 在 4 节点生产集群上的实际操作和源码分析。
> 版本：BeeGFS 7.3.2，Ubuntu 22.04，内核 5.15.0-170

---

## 一、架构全景

```
                          ┌─────────────────────┐
                          │   Client (内核模块)    │
                          │   /mnt/beegfs        │
                          │   157                │
                          └──────┬──────┬───────┘
                                 │      │
                    ┌────────────┘      └──────────────┐
                    ▼                                  ▼
          ┌─────────────────┐              ┌──────────────────────┐
          │  Management      │              │  Metadata Server ×4  │
          │  (mgmtd)         │              │  157[ID:1] 150[ID:2] │
          │  157, port 8008  │              │  151[ID:3] 152[ID:4] │
          └─────────────────┘              │  镜像: G1={2,3}       │
                    │                       │        G2={1,4}       │
                    │ 注册/心跳              └──────────────────────┘
                    ▼
          ┌──────────────────────┐
          │  Storage Server ×3   │
          │  150[ID:101] tgt×2   │
          │  151[ID:102] tgt×2   │
          │  152[ID:103] tgt×2   │
          │  镜像: 3 buddy groups│
          │  G101={1011,1021}    │
          │  G102={1012,1031}    │
          │  G103={1022,1032}    │
          └──────────────────────┘
```

### 1.1 四大组件

| 组件 | 数量 | 作用 | 类比 |
|------|------|------|------|
| **mgmtd** | 1 (157) | 集群注册中心，维护节点/target/镜像拓扑 | DNS + 服务注册 |
| **meta server** | 4 (157/150/151/152) | 文件元数据：目录树、inode、stripe 布局 | 文件系统的目录结构 |
| **storage server** | 3 (150/151/152) | 存储实际文件数据块 | 硬盘 |
| **client** | 1 (157) | 内核模块，POSIX 接口，用户无感知 | NFS client |

---

## 二、实际操作验证

### 2.1 创建文件并查看元数据

```bash
echo 'Hello BeeGFS!' > /mnt/beegfs/learn/hello.txt
dd if=/dev/urandom of=/mnt/beegfs/learn/random.bin bs=1M count=10
# 输出: 10485760 bytes (10 MB) copied, 353 MB/s

sudo beegfs-ctl --getentryinfo /mnt/beegfs/learn/hello.txt
```

输出：
```
Entry type: file
EntryID: 1-6A4760D4-1           ← 文件在全局命名空间中的唯一 ID
Metadata buddy group: 2          ← 元数据存在 buddy group 2 (节点 1 和 4)
Current primary metadata node: oneasia-c1-cpu-node10 [ID: 1]
Stripe pattern details:
+ Type: Buddy Mirror
+ Chunksize: 1M
+ Number of storage targets: desired: 3; actual: 3
+ Storage mirror buddy groups:  ← 数据分片到 3 个镜像组
  + 102  (target 1012 ↔ 1031)
  + 103  (target 1022 ↔ 1032)
  + 101  (target 1011 ↔ 1021)
```

### 2.2 根目录 stripe 配置

```bash
sudo beegfs-ctl --getentryinfo /mnt/beegfs
```

输出：
```
Entry type: directory
EntryID: root
Metadata buddy group: 2
Current primary metadata node: oneasia-c1-cpu-node10 [ID: 1]
Stripe pattern details:
+ Type: Buddy Mirror
+ Chunksize: 1M
+ Number of storage targets: desired: 3
```

### 2.3 子目录独立 stripe 配置

```bash
mkdir /mnt/beegfs/learn/smallfiles
sudo beegfs-ctl --setpattern --pattern=buddymirror --numtargets=3 --chunksize=128k /mnt/beegfs/learn/smallfiles
```

子目录 smallfiles 的元数据：
```
EntryID: 3-6A4760D4-1
Metadata buddy group: 1              ← 注意：和第 2.1 的文件不在同一个 meta buddy group！
Current primary metadata node: beegfs-slave1 [ID: 2]
Chunksize: 128K                      ← 子目录覆盖了根目录的 1M
```

### 2.4 `stat` 看文件在客户端视角

```bash
stat /mnt/beegfs/learn/random.bin
```

输出：
```
Device: 39h/57d    Inode: 2325704681231163360
Size: 10485760     IO Block: 524288    ← BeeGFS client 上报的块大小
```

`Inode` 是一个巨大的数字（2.3×10^18），说明 BeeGFS 使用了虚拟 inode 编号，不是传统文件系统的整数 inode。

---

## 三、I/O 路径详解

### 3.1 文件创建（`echo "hello" > /mnt/beegfs/learn/hello.txt`）

```
用户进程
  │ write() syscall
  ▼
VFS (虚拟文件系统层)
  │ 路由到 BeeGFS 内核模块
  ▼
BeeGFS Client (beegfs.ko)
  │
  ├─[1] 查目录 learn 的元数据   ──────► meta server (取决于 learn/ 的 meta buddy group)
  │        ← 返回 learn 目录的 inode 信息
  │
  ├─[2] 创建 hello.txt 的 inode  ──► meta server (同一个 buddy group 的 primary)
  │        ← 返回 EntryID: 1-6A4760D4-1
  │
  ├─[3] 写入文件数据 (61 bytes)  ──► storage server 的一个 buddy group
  │        ← 写入确认
  │
  └─[4] 更新文件元数据 (size=61)  ──► meta server
           ← 确认

◄── 返回用户进程
```

**关键点**：
1. **创建文件 = 两次 meta 操作 + 一次 storage 操作**
2. meta 操作和 storage 操作可以并行到不同节点
3. 元数据是同步写入的（确保一致性），数据可以批量化

### 3.2 文件读取路径

```
用户: read() syscall
      │
      ▼
VFS ──► BeeGFS Client
            │
            ├─[1] 查 hello.txt 的元数据
            │     ├─ Client 本地缓存命中? → 直接返回
            │     └─ 缓存未命中 → 查 meta server
            │        ← 返回: EntryID, stripe 布局, 数据所在的 buddy group
            │
            ├─[2] 读数据
            │     └─ 直连 storage server 的 primary target
            │        读取 mirror buddy group 101 的 target 1011
            │        (primary 故障时自动切到 secondary target 1021)
            │
            ◄── 返回数据
```

**关键点**：
- Client → meta 和 Client → storage 是两段独立的网络连接
- 读数据 **不经过 mgmtd**——mgmtd 只在初始挂载和拓扑变更时参与
- meta 信息有 **client 端缓存**，减少重复查询

### 3.3 mgmtd 的角色：仅在挂载时

```
Client mount 过程:
  1. 读 /etc/beegfs/beegfs-client.conf → 得到 sysMgmtdHost=10.20.1.157
  2. 连接 mgmtd (端口 8008, BeeMsg 协议)
  3. mgmtd 返回全部集群拓扑:
     - 4 个 meta 节点 (IP + Port)
     - 3 个 storage 节点 (IP + Port)
     - 6 个 storage target (ID + 路径)
     - 5 个 buddy group (镜像关系)
  4. Client 缓存这些信息，之后绕过 mgmtd 直接与 meta/storage 通信
```

**mgmtd 宕机**不影响已有 client 的读写——这和 NFS server 完全不同。

### 3.4 大文件 striping（以 10MB random.bin 为例）

```
random.bin (10MB, chunksize=1M, numtargets=3)

Chunk 0  (0-1MB)   → buddy group 102 → target 1012 (150-disk2) / mirror 1031 (152-disk1)
Chunk 1  (1-2MB)   → buddy group 103 → target 1022 (151-disk2) / mirror 1032 (152-disk2)
Chunk 2  (2-3MB)   → buddy group 101 → target 1011 (150-disk1) / mirror 1021 (151-disk1)
Chunk 3  (3-4MB)   → buddy group 102 → 循环...
Chunk 4  (4-5MB)   → buddy group 103
...
```

10 个 chunk 轮转分布在 3 个 buddy group 上，每个 group 内 primary 和 secondary 各存一份完整副本。

---

## 四、镜像（Mirroring）机制

### 4.1 Meta 镜像

```
buddy group 1: node 2 (150) ↔ node 3 (151)
buddy group 2: node 1 (157) ↔ node 4 (152)

每个目录/文件的元数据由它的 buddy group 的 primary 节点负责:
  / (root)       → group 2, primary=157
  /learn/        → group 2, primary=157      (继承 root)
  /learn/hello   → group 2, primary=157
  /learn/smallfiles/ → group 1, primary=150  (新建目录, mgmtd 分配)
  /learn/smallfiles/small-1.txt → group 1, primary=150
```

**故障切换**：如果 primary 157 宕机，group 2 的 secondary 152 自动晋升为 primary。

### 4.2 Storage 镜像

```
buddy group 101: target 1011(150) ↔ target 1021(151)
buddy group 102: target 1012(150) ↔ target 1031(152)
buddy group 103: target 1022(151) ↔ target 1032(152)

写入: 同时写 primary 和 secondary，两者都确认才返回成功
读取: 优先从 primary 读，primary 不可用时从 secondary 读
```

**Node-1 (150) 宕机影响**：
- group 101 的 secondary (151) 接替 → 数据可读
- group 102 的 secondary (152) 接替 → 数据可读
- 全集群无数据丢失

---

## 五、性能特征

### 5.1 实测数据

| 操作 | 吞吐 | 说明 |
|------|------|------|
| 顺序写 (dd 10MB) | 353 MB/s | 写同时需要镜像复制到 secondary |
| 顺序读 | ~434 MB/s (之前 smoke test) | 只读 primary，无镜像开销 |
| 元数据操作 (mkdir/creat) | 毫秒级 | meta server 本地 ext4，很快 |

### 5.2 为什么写入比读取慢

写入路径：
```
Client → primary storage target ─┐
                                 ├─ 两个 target 都确认才返回
Client → secondary storage target┘
Client → meta server (更新文件大小/时间戳)
```

读取路径：
```
Client → primary storage target (单跳, 直接返回)
(meta 信息已缓存, 不需要查询)
```

镜像写入的额外开销 = 网络往返到 secondary + 等待 secondary 落盘确认。

---

## 六、与传统文件系统的对比

| 特性 | 传统 FS (ext4/XFS) | BeeGFS |
|------|-------------------|--------|
| 元数据 | 本地磁盘上的 inode 表 | 分布在 4 台 meta server |
| 数据 | 本地块设备 | 分布在 3 台 storage server × 2 targets |
| 故障域 | 单盘 | 跨节点：任一节点宕机不影响 |
| 扩容 | 加盘 | 加节点/target，在线 |
| 并发 | 受限于本地磁盘 IOPS | 多 target 并行，线性扩展 |
| inode 编号 | `ls -i` 显示整数 | 虚拟大整数，不是真实 inode |

---

## 七、总结：一个 write() 系统调用的完整旅程

```
echo "hello" > /mnt/beegfs/learn/hello.txt

1. VFS 收到 write()
2. BeeGFS client 查本地缓存: /mnt/beegfs/learn/ 的 inode 已缓存
3. hello.txt 不存在 → client 请求 mgmtd 分配新的 EntryID
4. mgmtd 分配 EntryID: 1-6A4760D4-1，分配 meta buddy group: 2
5. client 同时做两件事:
   a. → meta server 157 (group 2 primary): 创建 inode, 记录 stripe 布局
   b. → storage target 1012 (group 102 primary) + target 1031 (mirror): 写入 61 bytes
6. meta 和 storage 都确认 → write() 返回成功
7. 未来任何 client 访问 hello.txt: 查 meta server 157 → 读 storage target 1012 → 完成
```

**全程 mgmtd 只参与第 3-4 步的 EntryID 分配，后续读写完全不经过 mgmtd。**
