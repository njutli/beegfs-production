# 锁定 RDMA 接口报告

> 日期：2026-07-08
> 任务书：`doc/perf-tasks/stage1-lock-rdma-iface-task-book.md`
> 结论：**479 根因 = TCP fallback 确认。锁定 connInterfacesFile 后 5/5 次重启 100% RDMA，seqwrite 稳定 889-909。900 成为可保证的稳定基线。**

---

## 一、任务 A：独立复核根因

### 1.1 证据链验证

| # | 证据 | 验证方法 | 结果 |
|---|------|---------|------|
| 1 | 07-06 20:23 低态日志 | `grep "Connected: beegfs-storage" beegfs-client.log.old-1` | `Connected: beegfs-storage@10.114.1.150:8003 (protocol: TCP)` ×3 → **走 TCP** |
| 1b | 配置改动日志 | `journalctl --since 07-06 20:20 --until 20:30` | `sed -i 's\|^connInterfacesFile.*=.*|connInterfacesFile =|'` → **清空配置** |
| 2 | 当前配置 | `grep connInterfacesFile *.conf` + `ls connInf.conf` | `connInterfacesFile =` (空) + `connInf.conf not exist` → **自动选接口** |
| 3 | 当前 beegfs-net | `beegfs-net \| grep "ID: 10[123]"` | 3 storage 全 `RDMA: 2 (10.3.2.x:8003)` → **当前走 RDMA** |
| 4 | 网卡 IP 归属 | `ip -o -4 addr` | `eno12409=10.114.1.x(TCP)`, `enp139s0f1np1=10.3.2.x(RDMA)` |
| 5 | eno12409 带宽 | `ethtool eno12409` | `Speed: 10000Mb/s` (10GbE) → **解释 479 ≠ 1Gbps 的 ~113** |

### 1.2 07-06 20:23 低态日志片段

```
Jul06 20:23:28 Usable NICs: enp139s0f1np1(RDMA) enp139s0f0np0(RDMA) ... eno12409(TCP) ...
Jul06 20:23:28 Connected: beegfs-storage@10.114.1.150:8003 (protocol: TCP)  ← TCP!
Jul06 20:23:28 Connected: beegfs-storage@10.114.1.151:8003 (protocol: TCP)
Jul06 20:23:28 Connected: beegfs-storage@10.114.1.152:8003 (protocol: TCP)
```

### 1.3 复核结论

**完全同意根因分析**：
- **479 = TCP fallback**：connInterfacesFile 被清空后 client 自动选接口，07-06 20:23 那次选中了 eno12409（10GbE TCP），走 10.114.1.x TCP 连接
- **900 = RDMA**：33 次重启全部自动选中 RDMA（10.3.2.x 或 10.3.1.x）
- **空配置选路不确定**：大概率选 RDMA，小概率落 TCP
- **eno12409 是 10GbE**（不是 1Gbps），TCP 走 10GbE 单流 ≈ 479 MiB/s，clat_min ≈ 400µs（TCP 栈开销 200µs + NVMe 200µs）

---

## 二、任务 B：锁定 RDMA 接口

### 2.1 配置改动

**备份路径**：
- 157: `/etc/beegfs/beegfs-client.conf.bak-1783484178`, `/etc/beegfs/beegfs-meta.conf.bak-1783484178`
- slave: `/etc/beegfs/beegfs-{storage,meta}.conf.bak-*` (各节点)

**新增文件** `/etc/beegfs/connInterfacesFile.conf`（157 + 3 slave，内容相同）：
```
enp139s0f0np0
enp139s0f1np1
```

**修改的 .conf**（157 client.conf + meta.conf; slave storage.conf + meta.conf）：
```diff
-connInterfacesFile            =
+connInterfacesFile            = /etc/beegfs/connInterfacesFile.conf
```

单变量：只改 connInterfacesFile 一项，未动其他参数。

### 2.2 锁定前后对比

| 指标 | 锁定前（空配置） | 锁定后 |
|------|:---:|:---:|
| connInterfacesFile | 空（自动选接口） | `/etc/beegfs/connInterfacesFile.conf` |
| beegfs-net storage 连接 | RDMA（大概率）/ TCP（小概率） | **100% RDMA** |
| client log Connected | 不确定 | **100% RDMA (10.3.1.x)** |
| seqwrite 典型值 | 479-944（不确定） | **889-909（稳定）** |
| clat_min | 200-400µs（不确定） | **212-223µs（稳定）** |

### 2.3 5 次重启一致性验证

每次重启后检查 beegfs-net + 测 seqwrite：

| 轮次 | bw (MiB/s) | clat_min (µs) | beegfs-net | 时间 |
|:---:|:---:|:---:|:---:|------|
| 1 | 889 | 223 | 100% RDMA ✓ | 11:28 |
| 2 | 897 | 217 | 100% RDMA ✓ | 11:32 |
| 3 | 904 | 212 | 100% RDMA ✓ | 11:36 |
| 4 | 898 | 214 | 100% RDMA ✓ | 11:40 |
| 5 | 909 | 217 | 100% RDMA ✓ | 11:45 |

统计：
- 均值: 899 MiB/s
- 范围: 889-909 (±1.1%)
- clat_min: 212-223µs
- RDMA 一致性: **5/5 = 100%**

### 2.4 WekaIO 不受影响

| 指标 | 锁定前 | 锁定后 |
|------|--------|--------|
| wekanode 进程数 | 17 | 17 |
| wekanode CPU | 102-103% ×16 | 102-103% ×16 |
| RDMA 速率（空闲态） | 0 MiB/s | 0 MiB/s |

WekaIO 服务正常运行，不受 connInterfacesFile 改动影响（BeeGFS 本就与 WekaIO 共用 RDMA 卡，锁定接口不新增网卡层改动）。

---

## 三、给规划 agent 的结论

1. **900 是可保证的稳定基线**：锁定 connInterfacesFile 后，5/5 次重启 100% 走 RDMA，seqwrite 稳定 889-909（±1.1%），479 态被永久消除。
2. **建议固化进基线配置**：`connInterfacesFile = /etc/beegfs/connInterfacesFile.conf`（内容：`enp139s0f0np0` + `enp139s0f1np1`）应写入 `skills/beegfs-baseline-config.md`。
3. **stage1 可在 900 基线上推进**：变量 A（dirty_ratio）取消（对 direct=1 无效），变量 B/C/D 可继续。
4. **回滚方法**：恢复 `.conf` 备份（`connInterfacesFile =` 空值）+ 删 `connInterfacesFile.conf` + 重启服务。

---

## 四、文件清单

```
results/20260708-lock-rdma-iface/
├── summary.md              ← 5 轮验证汇总表
├── main.log                ← 验证日志（含 beegfs-net 输出）
├── verify{1..5}-seqwrite.txt  ← 5 轮原始 fio 输出
└── README.md (本文件)
```
