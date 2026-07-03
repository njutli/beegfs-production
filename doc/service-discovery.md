# BeeGFS 集群服务发现与注册机制

整理自 2026-07-02 工程讨论记录。

## 问题

客户端（client）如何知道集群中的元数据（meta）节点和存储（storage）节点在哪里？

## 答案

### 1. 客户端视角

客户端只配置一个参数：`/etc/beegfs/beegfs-client.conf` 中的 `sysMgmtdHost = 10.20.1.157`。

启动时客户端：

1. 连接 mgmtd（10.20.1.157）
2. 从 mgmtd 获取完整的集群拓扑（所有 meta 和 storage 节点的地址、端口、状态）
3. 将这些信息**缓存在内存中**

后续的读写操作直接与对应的 meta/storage 节点通信，不再经过 mgmtd。

### 2. mgmtd 视角

mgmtd 的信息来源于各节点的**主动注册**：

- **meta 节点**：启动时读 `beegfs-meta.conf` 中的 `sysMgmtdHost`，向 mgmtd 注册自己（IP、端口、node ID）
- **storage 节点**：通过 `beegfs-setup-storage -m <mgmtd_ip>` 时指定的 mgmtd 地址，启动时注册

注册信息持久化存储在 mgmtd 的 SQLite 数据库中：`/var/lib/beegfs/mgmtd.sqlite`。

### 3. 心跳保活

各节点定期向 mgmtd 发送心跳。如果某节点超过 `node-offline-timeout`（默认 180s）没有心跳，mgmtd 标记其为 offline。

## mgmtd 故障影响

| 场景 | 影响 |
|------|------|
| client 已挂载，mgmtd 宕机 | 已有读写不受影响（拓扑已缓存） |
| 新 client 挂载时 mgmtd 宕机 | 无法挂载（获取不到拓扑） |
| 集群扩缩容时 mgmtd 宕机 | 变更无法生效 |
| mgmtd 恢复 | 各节点重新注册，恢复正常 |

## 类比

mgmtd 相当于集群的"注册中心"或"通讯录"——只在挂载和节点变更时需要，正常读写时数据面不依赖它。
