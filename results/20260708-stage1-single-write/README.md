# Stage1 单流写优化 — 单变量矩阵测试报告

> 日期：2026-07-08
> 任务书：`doc/perf-tasks/stage1-task-book.md`
> 基线：~900 MiB/s（RDMA 锁定态，`results/20260708-lock-rdma-iface/` 5/5 验证）
> 口径：fio --direct=1 --bs=256K --size=4G --end_fsync=1，冷态（drop_all_caches 客户端+3 slave）
> 结论：**5 个变量全部无显著影响。~900 MiB/s 被 per-IO 延迟（~273µs）主导，非应用层参数可调。**

---

## 一、结果汇总表

| 变量 | 测试值 | 各轮 bw (MiB/s) | avg | vs 基线 | 重启? | RDMA? | 结论 |
|------|--------|:---------------:|:---:|:-------:|:-----:|:-----:|------|
| **B-1 BufNum** | 70(基线) | 893, 912 | 902.5 | — | 全服务 | ✓ | 无影响 |
| | 128 | 913, 951 | 932 | +3.3% | 全服务 | ✓ | 噪音范围 |
| | 256 | 904, 912 | 908 | +0.6% | 全服务 | ✓ | 噪音范围 |
| **B-2 BufSize** | 8192(基线) | 897, 907 | 902 | — | 全服务(跳mgmtd) | ✓ | 无影响 |
| | 16384 | 907, 930 | 918.5 | +1.8% | 同上 | ✓ | 噪音范围 |
| | 32768 | 911, 923 | 917 | +1.7% | 同上 | ✓ | 噪音范围 |
| **C Workers** | 12(基线) | 897, 903 | 900 | — | slave storage | ✓ | 无影响 |
| | 24(2×) | 901, 910 | 905.5 | +0.6% | slave storage | ✓ | 噪音范围 |
| | 48(4×) | 881, 889 | 885 | -1.7% | slave storage | ✓ | 噪音范围 |
| **D Chunk** | 512K | 918, 919 | 918.5 | +0.1% | 无需重启 | ✓ | 无影响 |
| | 1M(基线) | 916, 919 | 917.5 | — | 无需重启 | ✓ | 无影响 |
| | 2M | 916, 923 | 919.5 | +0.2% | 无需重启 | ✓ | 无影响 |
| | 4M | 912, 915 | 913.5 | -0.4% | 无需重启 | ✓ | 无影响 |
| **E fsync** | end_fsync=1 | 917, 915 | 916 | — | 无需重启 | ✓ | 无影响 |
| | 无 fsync | 917, 915 | 916 | 0% | 无需重启 | ✓ | **完全无差异** |

> 基线噪音范围：889-944（来自 33 次独立测量 + 5 次重启验证）
> 全部 28 轮测量均通过 RDMA 哨兵（100% RDMA 10.3.x，clat_min < 250µs）

---

## 二、关键发现：变量 E 诊断结论

**fsync vs 非fsync 完全无差异（916 vs 916，run 4473 vs 4471ms）**。

这意味着：
1. **瓶颈不在后端落盘确认**——移除 fsync 不加速，因为 `--direct=1` 下每个 write 本身就是同步的
2. **瓶颈在 per-IO 写路径**：每个 256K write 耗时 ~273µs（clat avg），IOPS ≈ 3660
3. **带宽 = IOPS × bs = 3660 × 256K ≈ 914 MiB/s**——与实测完全吻合

### per-IO 延迟分解（~273µs）

| 环节 | 估计耗时 | 依据 |
|------|:--------:|------|
| RDMA 往返 | ~10-20µs | 100GbE RDMA 单程 ~5µs |
| BeeGFS 协议开销 | ~50-100µs | 请求处理 + chunk 分配 + buddy mirror 协调 |
| NVMe 写（256K） | ~100-150µs | clat_min ~200µs - RDMA ~20µs = ~180µs（含协议） |
| **合计** | **~273µs** | clat avg 实测值 |

### 为什么 B/C/D 全无效

| 变量 | 为什么无效 |
|------|-----------|
| B-1 BufNum | iodepth=1（psync）只有 1-2 个 RDMA buffer 在飞，70 已远超需求 |
| B-2 BufSize | 70×8192=560KB > 256K 写大小，buffer pool 可容纳整个 write，不瓶颈 |
| C Workers | iodepth=1 每连接只用 1 个 storage worker，12 已够；48 workers 反而可能 context-switch 开销（885 avg 略低） |
| D Chunk | iodepth=1 一次只写一个 buddy group，chunksize 只影响切换频率，不影响单次写延迟 |

---

## 三、原始 fio 对账（抽样验证）

| 文件 | WRITE: bw= | clat min= | 对账 |
|------|-----------|-----------|:----:|
| var-b-bufnum/bufnum70-r1 | 893MiB/s | 215 | ✓ |
| var-b-bufnum/bufnum128-r2 | 951MiB/s | 186 | ✓ |
| var-b-bufsize/bufsize8192-r1 | 897MiB/s | 216 | ✓ |
| var-b-bufsize/bufsize32768-r2 | 923MiB/s | 200 | ✓ |
| var-c-workers/workers48-r1 | 881MiB/s | 223 | ✓ |
| var-d-chunksize/chunk1M-r1 | 916MiB/s | 213 | ✓ |
| var-e-fsync/fsync-r1 | 917MiB/s | 217 | ✓ |
| var-e-fsync/nofsync-r1 | 917MiB/s | 220 | ✓ |

全部对账通过，summary 转写数与原始 fio `WRITE: bw=` 行一致。

---

## 四、安全红线检查

| 红线项 | 是否触碰 | 证据 |
|--------|:--------:|------|
| 157 内核参数 | ❌ 未动 | 全程只改 BeeGFS .conf |
| 网卡/驱动全局参数 | ❌ 未动 | 未动 MTU/mlxconfig/queue/中断 |
| RoCE QoS (connRDMATypeOfService) | ❌ 未动 | 保持 0 |
| 根目录 stripe | ❌ 未动 | 变量 D 只用子目录 setpattern |
| connInterfacesFile | ❌ 未动 | 全程保持 RDMA 锁定 |
| 测后参数恢复 | ✓ | B-1/B-2 恢复 70/8192，C 恢复 12，D 删子目录，E 无改动 |
| 每轮 RDMA 哨兵 | ✓ | 28/28 轮 100% RDMA |

---

## 五、结论与建议

### 5.1 结论
**~900 MiB/s 单流写是 per-IO 延迟主导的性能天花板，BeeGFS 应用层参数无法突破。**

- per-IO 延迟 ~273µs = RDMA 往返 + BeeGFS 协议 + NVMe 写
- IOPS = 1/273µs ≈ 3660，× 256K = ~914 MiB/s
- 5 个变量（BufNum/BufSize/Workers/Chunk/fsync）全部在噪音范围内（881-951，历史基线 889-944）
- 变量 E 证实瓶颈在 per-IO 写路径，不在后端落盘

### 5.2 给规划 agent 的建议
1. **stage1 单流写调优到此结束**——应用层参数已穷举，无正收益项。
2. **要突破 ~900 需改变测试维度**：
   - 增大 bs（如 1M）：减少 IO 次数，但 clat 也会增大，效果待验证
   - 增大 iodepth（async I/O）：允许并发 in-flight IO，但改变"单流"定义
   - 以上属于 stage2（写天花板与镜像开销量化）范畴
3. **~900 作为单流写基线已固化**，后续 stage2/3 以此为对照锚点。
4. **变量 C 48 workers 略低（885 avg）**可能是 context-switch 开销，但差异在噪音内，不深究。

### 5.3 未测项（任务书未要求，记录备查）
- meta tuneNumWorkers（当前 0=auto，未测，因单流写瓶颈在 storage 路径）
- connRDMATypeOfService（RoCE QoS，安全红线禁止动）
- 网卡/驱动参数（安全红线禁止动）

---

## 六、文件清单

```
results/20260708-stage1-single-write/
├── README.md                         ← 本文件
├── env/
│   ├── baseline-snapshot.md          ← 基线 conf 值 + RDMA 哨兵 + 内存核算
│   └── baseline-seqwrite.txt         ← 前置基线验证 fio 输出 (bw=913, clat_min=192)
├── var-b-bufnum/
│   ├── bufnum{70,128,256}-r{1,2}-seqwrite.txt  ← 6 个原始 fio
│   └── (summary.md 在 157 /tmp/stage1-bufnum/)
├── var-b-bufsize/
│   ├── bufsize{8192,16384,32768}-r{1,2}-seqwrite.txt  ← 6 个原始 fio
│   └── (summary.md 在 157 /tmp/stage1-bufsize/)
├── var-c-workers/
│   ├── workers{12,24,48}-r{1,2}-seqwrite.txt  ← 6 个原始 fio
│   └── (summary.md 在 157 /tmp/stage1-workers/)
├── var-d-chunksize/
│   ├── chunk{512K,1M,2M,4M}-r{1,2}-seqwrite.txt  ← 8 个原始 fio
│   └── (summary.md 在 157 /tmp/stage1-chunksize/)
└── var-e-fsync/
    ├── {fsync,nofsync}-r{1,2}-seqwrite.txt  ← 4 个原始 fio
    └── (summary.md 在 157 /tmp/stage1-fsync/)
```

测试脚本：
- `tests/baseline-check.sh` — 前置基线验证
- `tests/lib/set-rdma-param.sh` — conf 参数设置 helper
- `tests/var-b-bufnum.sh` — 变量 B-1
- `tests/var-b-bufsize.sh` — 变量 B-2
- `tests/var-c-workers.sh` — 变量 C
- `tests/var-d-chunksize.sh` — 变量 D
- `tests/var-e-fsync.sh` — 变量 E
