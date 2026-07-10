# Stage1 2A — v2 基线复测报告

> 日期：2026-07-07
> 目的：在做任何 stage1 调优前，独立复测 v2 基线，确认稳定可复现
> 结论：**v2 seqwrite=835 不可复现，对照实验归因需修正，当前 seqwrite 真实基线 ≈ 479-512 MiB/s**

---

## 一、复测结果 vs v2 基线

### 不限速冷态（direct=1，drop 客户端+3 slave），2 轮

| 测试 | v2 (07-06) | R1 (07-07) | R2 (07-07) | R1 偏差 | R2 偏差 | 判定 |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| seqread(单流) | 1585 | 1484 | 1468 | -6.4% | -7.4% | ✓ ±10%内 |
| **seqwrite(单流)** | **835** | **479** | **479** | **-43%** | **-43%** | **✗ 严重偏离** |
| multi-seqread(16) | 6874 | 6885 | 6900 | +0.2% | +0.4% | ✓ |
| multi-seqwrite(16) | 8214 | 7406 | 7201 | -9.8% | -12.4% | ✗ R2超±10% |
| layout(128,4M) | 10240 | 10097 | 10025 | -1.4% | -2.1% | ✓ |
| randread(128) | 8227 | 9230 | 9220 | +12% | +12% | ✗ 超±5% |
| randwrite(128) | 6138 | 6062 | 6034 | -1.2% | -1.7% | ✓ |
| randrw R/W | 4602 | 4500 | 4517 | -2.2% | -1.8% | ✓ |
| randread-64K | 4789 | 5326 | 4915 | +11% | +2.6% | 波动大 |
| randread-1M | 8807 | 10547 | 10547 | +20% | +20% | ✗ 偏高 |

**seqwrite 两轮完全一致（479=479），clat avg 也一致（484.78 vs 485.14µs）**，可复现性极高。

### seqwrite 原始 fio 对账

| 指标 | v2 (07-06 18:44) | R1 (07-07 12:48) | R2 (07-07 13:01) |
|------|:---:|:---:|:---:|
| bw | 835 MiB/s | 479 MiB/s | 479 MiB/s |
| clat avg | 262.73µs | 484.78µs | 485.14µs |
| clat min | 200µs | 398µs | 401µs |
| clat max | 1504µs | 1208µs | 1151µs |
| run | 4908ms | 8547ms | 8552ms |

**clat min 从 200µs 翻倍到 400µs** — 每个单 IO 的固有路径延迟翻倍。

---

## 二、排查过程

### 2.1 已排除项

| 排查项 | 方法 | 结果 |
|--------|------|------|
| slave 参数漂移 | 从 157 跳 SSH 检查 3 slave dirty_ratio/THP/read_ahead 等 | 全部基线值 ✓ |
| RDMA 链路降速 | cat /sys/class/infiniband/mlx5_*/ports/*/state,rate | 100Gb ACTIVE (4X EDR) ✓ |
| RDMA 错误 | port_xmit_discards, port_xmit_wait | 全 0 ✓ |
| slave NVMe 延迟 | iostat -x 1 2 on slave | w_await=0.18-0.21ms ✓ |
| 157 参数变化 | cat dirty_ratio/THP/vfs_cache | 157 默认值未变 ✓ |
| 限速残留 | tc qdisc show dev eno12409 | NO TBF ✓ |
| CPU 调度竞争 | 96 核, wekanode 亲和性 0,17-64,81-127; taskset -c 0-3 fio | 绑核后 504（无改善）✗ 排除 |

### 2.2 关键验证：dirty_ratio 对 --direct=1 无效

在当前状态（dirty_ratio=10）下单变量测试：

| 测试 | bw | clat avg | clat min |
|------|:---:|:---:|:---:|
| direct=1, dirty=10 | 512 MiB/s | 487µs | 397µs |
| buffered, dirty=10 | 710 MiB/s | 331µs | 5µs |
| **direct=1, dirty=20** | **503 MiB/s** | **495µs** | **403µs** |

**dirty_ratio 10 vs 20 对 --direct=1 几乎无差异（512 vs 503）** — 证实 dirty_ratio 对 direct write 无效。

### 2.3 关键发现：BeeGFS 服务重启时间线

| 时间 | 事件 | seqwrite |
|------|------|:---:|
| 07-06 18:44 | v2 基线测试 | 835 |
| **07-06 20:23** | **BeeGFS 服务重启**（157 meta+client, slave storage+meta 全部重启） | - |
| 07-07 11:47 | 对照实验 UNTUNED | 466/469 |
| 07-07 ~12:00 | restore-tuning 恢复 dirty_ratio=10 | - |
| 07-07 12:48 | R1 复测（TUNED） | 479 |
| 07-07 13:01 | R2 复测（TUNED） | 479 |

- **v2=835 是服务重启前的值**
- R1/R2=479 是服务重启后的值
- 对照实验 UNTUNED=466 也是重启后的值
- **479 ≈ 466（dirty_ratio=10 vs 20 无差异，因 direct write 不经过 page cache）**

---

## 三、对照实验结论修正

### 原结论（错误）

> slave 调优对单流写 +78%（466→835），主因 dirty_ratio 20→10

### 修正结论

对照实验的"v2 tuned=835"直接引用了 v2 基线数据（07-06 18:44，服务重启前），而"control untuned=466"是 07-07 11:47 跑的（服务重启后）。**两者之间有两个变量**：

1. dirty_ratio（10 vs 20）
2. BeeGFS 服务重启前 vs 后

经验证 dirty_ratio 对 --direct=1 无效（512 vs 503），**466 vs 835 的差异全部来自服务重启，不是 dirty_ratio**。

| 因素 | 原归因 | 修正归因 |
|------|--------|---------|
| seqwrite 466→835 (+78%) | dirty_ratio 20→10 | **BeeGFS 服务重启前后的状态差异**（具体原因待定） |
| layout 9964→10240 (+2.5%) | slave 调优 | 不变（layout 不受服务重启影响，R1/R2 layout=10097/10025 验证） |

---

## 四、当前未解决的问题

### 4.1 v2=835 的来源

v2 时（服务重启前）direct write clat=263µs，clat min=200µs。服务重启后 clat=485µs，clat min=400µs。clat min 翻倍来自 BeeGFS 协议层/RDMA 传输层，但：

- RDMA 无错误、无降速
- slave NVMe 延迟正常（200µs）
- CPU 调度不是因素（绑核无效）
- dirty_ratio 不是因素（10 vs 20 无差异）

**clat 增量 ≈ 200µs 的具体来源待定**。可能是：
- 服务重启后 RDMA 连接重建，走了次优路径
- BeeGFS storage 服务的运行时状态变化（内存分配、连接池等）
- 服务运行时间对 RDMA buffer 回收效率的影响

### 4.2 读项偏高

randread +12%、randread-1M +20%。可能因为 WekaIO 的持续 RDMA 流量预热了 PCIe/RDMA 路径，降低了读延迟。读项偏高不影响写调优，但说明 v2 基线的读项也可能不可信。

---

## 五、对 stage1 的影响

### 5.1 不可继续 stage1 调优

seqwrite 基线不可信（v2=835 不可复现），当前真实值 479-512。在不可信基线上做单变量调优无法得出有效结论。

### 5.2 变量 A（dirty_ratio 精调）已无意义

经验证 dirty_ratio 对 --direct=1 seqwrite 无效。变量 A 可以取消。

### 5.3 建议的下一步

1. **在业务低峰重启 BeeGFS 服务，立即跑 seqwrite**：验证重启后是否能恢复 835。如果恢复，说明服务运行时间影响性能（可能是 RDMA 连接老化或内存碎片）。如果还是 479，说明 835 是不可复现的异常值。

2. **如果重启后恢复 835**：重新确立基线，每次调优测试前先重启服务确保一致状态。

3. **如果重启后仍是 479**：479 是当前真实基线。stage1 调优对象改为 connRDMABufNum/BufSize（变量 B）、tuneNumWorkers（变量 C）、chunksize（变量 D）—— 这些参数在 479 基线上做单变量对比。

4. **变量 A（dirty_ratio）取消**：direct write 不经过 page cache，dirty_ratio 无效。

---

## 六、文件清单

```
results/20260707-stage1-baseline-recheck/
├── README.md (本文件)
├── R1/                         ← 第 1 轮复测（07-07 12:48）
│   ├── summary.md
│   ├── seqwrite.txt            ← 原始 fio（bw=479, clat=485µs）
│   ├── commands.sh
│   ├── env-snapshot.txt
│   └── ... (全部 27 文件)
├── R2/                         ← 第 2 轮复测（07-07 13:01）
│   ├── summary.md
│   ├── seqwrite.txt            ← 原始 fio（bw=479, clat=485µs）
│   └── ... (全部 27 文件)
└── (排查验证数据见本报告第二节)
```

v2 基线参照：`results/20260707-beegfs-cold-baseline-v2/unlimited/full-v2-cold-unlimited-20260706-184425/`
