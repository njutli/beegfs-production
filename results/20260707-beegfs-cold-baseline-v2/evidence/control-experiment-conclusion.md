# 对照实验 — seqwrite/layout 归因验证

> ⚠️ **2026-07-07 晚更正（务必先读）**：本实验关于 **seqwrite "slave 调优 +78%" 的结论无效**。原因：本实验的 "v2 tuned=835" 直接引用了 07-06 18:44（**BeeGFS 服务重启前**）的数据，而 "untuned=466" 是 07-07 11:47（**07-06 20:23 服务重启后**）跑的，`revert-tuning.sh` 只回退 runtime 参数、不重启服务——所以两组之间混入了"服务重启"这个未受控变量。已实测 dirty_ratio 对 `--direct=1` 无效（512 vs 503），**466→835 的差异来自服务重启，不是 slave 调优**。详见 `results/20260707-stage1-baseline-recheck/README.md`。
> **layout +2.5% 结论仍成立**（layout 不受服务重启影响）。以下正文保留为历史记录。

---

> 日期: 2026-07-07
> 目的: 隔离 slave 调优对 seqwrite 和 layout 的真实收益
> 方法: 单变量实验，仅回退 3 个 slave 的调优参数到默认值，157 保持不动，重跑 seqwrite + layout

## 实验设计

- **v2 基线**（已调优）: slave THP=always, dirty=5/10, read_ahead=4096, max_sectors=256
- **对照组**（未调优）: slave THP=madvise, dirty=20/10, read_ahead=128/256, max_sectors=1024/1280（与 157 默认一致）
- 157 在两组中均未调优（共部署常量）
- RDMA 在两组中均启用（connUseRDMA=true，07-03 即已配置）
- `--openfiles=128` 在两组中一致（v2 已修复，与 07-03 的 100 不同）
- 每项测 2 轮取一致性

### 修正：nr_requests 从未生效
检查发现 `nr_requests=4096` 在 NVMe 上报 `Invalid argument`，tune-servers.sh 的 `|| true` 吞掉了错误。v2 调优真实生效的参数为：THP、dirty_ratio、read_ahead_kb、max_sectors_kb、vfs_cache_pressure、min_free_kbytes、zone_reclaim_mode。对照组回退了这些参数，与 v2 构成正确的单变量对比。

## 实验结果

| 测试 | v2 (slave 调优) | 对照 (slave 未调优) | 调优收益 |
|------|----------------|-------------------|---------|
| seqwrite r1 | 835 MiB/s | 466 MiB/s | +79% |
| seqwrite r2 | 835 MiB/s | 469 MiB/s | +78% |
| layout r1 | 10240 MiB/s | 9964 MiB/s | +2.8% |
| layout r2 | 10240 MiB/s | 10004 MiB/s | +2.4% |

对照实验内部一致性极佳（seqwrite 466/469 偏差 0.6%，layout 9964/10004 偏差 0.4%）。

## 归因修正

### seqwrite: +150%（07-03 的 335 → v2 的 835）拆解

| 因素 | 贡献 | 证据 |
|------|------|------|
| slave 调优 | **+78%**（466→835）| 本对照实验，单变量 |
| 07-03 首日冷启动/未稳定 | 剩余 +42%（335→466）| 07-03 seqwrite 仅 1 轮无复核，部署当日跑 |

主要贡献参数推断: `dirty_ratio 20→10`（客户端 writeback 更早落盘到 BeeGFS 后端，减少堆积）。注意：这是 BeeGFS 客户端在 157 上的 dirty_ratio——但 157 未调优（dirty=20），所以收益来自 **slave 端** dirty_ratio=10 让 storage server 更快接收落盘数据。read_ahead 对写无影响，THP 对单流写影响小。

### layout: +524%（07-03 的 1640 → v2 的 10240）拆解

| 因素 | 贡献 | 证据 |
|------|------|------|
| slave 调优 | **+2.5%**（9964→10240）| 本对照实验，单变量 |
| `--openfiles 100→128` | **+507%**（1640→9964）| 07-03 有 28 个 job 排队等 fd，128 并发写被打包到 100 fd 严重拖慢聚合带宽 |

**README 之前归因"slave 调优 + RDMA"是错误的。** RDMA 在 07-03 就已启用（randread 10650 MiB/s 可证），不是新变量。layout 大幅提升的真正原因是 `--openfiles` 修复。

## 结论

1. **seqwrite +150% 的归因修正**: slave 调优贡献 +78%（可确认，单变量），剩余 +42% 来自 07-03 首日未稳定（不可控因素，07-03 无 R2 复核）
2. **layout +524% 的归因修正**: 几乎全部来自 `--openfiles 100→128` 修复（+507%），slave 调优仅 +2.5%
3. **slave 调优对单流写有显著收益**（dirty_ratio），对 128 并发大块写几乎无收益（瓶颈在 fd 调度而非内核参数）

## 对阶段 1 的启示

- 调优收益因负载类型而异：单流小块写 > 并发大块写
- `--openfiles` 这类测试参数缺陷会制造假性能问题，必须对齐口径
- 后续调优应先做单变量对照，再下归因结论

## 实验脚本
- tests/revert-tuning.sh — 回退 slave 调优（仅 runtime 参数，不重启服务）
- tests/restore-tuning.sh — 恢复 slave 调优
- tests/control-experiment.sh — 对照测试（seqwrite x2 + layout x2）
