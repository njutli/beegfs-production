# Stage1 单流写优化 — 环境快照（基线态）
# 日期：2026-07-08
# 采集时机：stage1 前置准备，确认基线态 RDMA 锁定 + 服务正常

## 一、connInterfacesFile 锁定状态（4 节点）

### 157 (client + meta)
```
client.conf: connInterfacesFile = /etc/beegfs/connInterfacesFile.conf
meta.conf:   connInterfacesFile = /etc/beegfs/connInterfacesFile.conf
connInterfacesFile.conf:
  enp139s0f0np0
  enp139s0f1np1
```

### slave 150/151/152 (storage + meta)
```
storage.conf: connInterfacesFile = /etc/beegfs/connInterfacesFile.conf
meta.conf:    connInterfacesFile = /etc/beegfs/connInterfacesFile.conf
connInterfacesFile.conf:
  enp139s0f0np0
  enp139s0f1np1
```

## 二、RDMA 参数基线值

| 参数 | client (157) | meta (157) | storage (slaves) | meta (slaves) |
|------|:---:|:---:|:---:|:---:|
| connUseRDMA | true | - | - | - |
| connRDMABufNum | 70 (显式) | 未设(默认70) | 未设(默认70) | 未设(默认70) |
| connRDMABufSize | 8192 (显式) | 未设(默认8192) | 未设(默认8192) | 未设(默认8192) |
| connRDMATypeOfService | 0 | - | - | - |

注：BeeGFS 7.x 默认 connRDMABufNum=70, connRDMABufSize=8192。
client.conf 显式设为默认值，其余节点用默认。
变量 B 测试时需在 client.conf + meta.conf + storage.conf 显式设置测试值。

## 三、tuneNumWorkers 基线值

| 节点 | tuneNumWorkers | 含义 |
|------|:---:|------|
| client (157) | 未设 | 默认 |
| meta (157) | 0 | auto (= 2× 默认) |
| storage (150/151/152) | 12 | 显式 |
| meta (150/151/152) | 0 | auto |

变量 C 测试值：storage 12(基线)/24(2×)/48(4×)；meta 0(auto)/...

## 四、RDMA 哨兵检查结果

```
beegfs-net:
  Connections: RDMA: 2 (10.3.1.6:8003)   ← storage 150
  Connections: RDMA: 2 (10.3.1.7:8003)   ← storage 151
  Connections: RDMA: 2 (10.3.1.8:8003)   ← storage 152
  TCP count: 0
  RDMA count: 3
  → 100% RDMA ✓
```

## 五、targets 状态

```
TargetID     Reachability  Consistency   NodeID
========     ============  ===========   ======
    1011           Online         Good      101
    1012           Online         Good      101
    1021           Online         Good      102
    1022           Online         Good      102
    1031           Online         Good      103
    1032           Online         Good      103
→ 6/6 Online/Good ✓
```

## 六、服务状态

```
beegfs-mgmtd: active
beegfs-meta:  active
beegfs-client: active
```

## 七、内存核算（变量 B 预估）

RAM per connection = BufSize × BufNum × 2

| 配置 | per-conn RAM | client 连接数(估) | client 总 RAM |
|------|:---:|:---:|:---:|
| 70 × 8192 (基线) | 1.12 MB | ~6 (3 storage + 3 meta) | ~6.7 MB |
| 128 × 8192 | 2.10 MB | ~6 | ~12.6 MB |
| 256 × 8192 | 4.19 MB | ~6 | ~25.2 MB |
| 70 × 16384 | 2.29 MB | ~6 | ~13.7 MB |
| 70 × 32768 | 4.58 MB | ~6 | ~27.5 MB |
| 256 × 32768 | 16.77 MB | ~6 | ~100.6 MB |

注：BeeGFS 注释 "connRDMABufSize shouldn't be higher than a few kbytes"，
32768 可能过大。先测 16384，32768 谨慎测。
157 内存充足（96核机器），slaves 也充足，不会吃爆。
