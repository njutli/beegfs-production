# BeeGFS 方案性能测试 — 周报附件

> 周期：2026-07-14 ~ 2026-07-18
> 仓库：https://github.com/njutli/beegfs-production

---

## 本周工作内容

### 1. 对齐 JuiceFS 口径的双口径全量重测（Stage3）

本周核心工作。此前 BeeGFS 测试参数与 JuiceFS 方案存在 3 项致命差异（seqwrite 块大小 256K vs 4M、顺序读时长 2.7s vs 180s、无 bw_log 稳态中位数），导致两方案数据无法直接对比。本周用完全对齐的参数重测了双口径全量矩阵。

**测试规模**：2 口径 × 12 项 × 3 轮 = 72 组 fio 测试，产出 5997 个原始数据文件（331MB）。

**口径A（100GbE RDMA 不限速）关键结果**：

| 测试项 | 带宽 (MiB/s) | 达标? |
|--------|:---:|:---:|
| seqwrite (4M) | 1906 | ✗ (延迟主导) |
| mseqwrite (4M,16j) | 11314 | ✓ |
| randread (128j) | 9045 | ✓ |
| randwrite (128j) | 6505 | ✗ (镜像2×写放大) |

**口径B（千兆限速）关键结果**：

| 测试项 | 带宽 (MiB/s) | 达标? |
|--------|:---:|:---:|
| seqread | 104 | ✓ |
| randread (128j) | 341 | ✓ |
| randwrite (128j) | 112 | ✓ |

### 2. 关键发现：BeeGFS 无 FUSE 缓冲虚高

BeeGFS 是内核模块（非 FUSE），`--direct=1` 真正绕过所有客户端缓冲，fio 平均与稳态中位数差异 ≤3.5%。而 JuiceFS 因 FUSE 用户态缓冲，fio 平均被拉高 7-8%，必须用 bw_log 稳态中位数才可信。这一发现确保两方案横向对比时口径一致。

### 3. 口径B 千兆切网问题排查

口径B 切换时遇到 3 个配置问题（connInterfacesFile 空值 / sysMgmtdHost 网段 / sed 未匹配注释行），导致数据面不通、写入挂起。逐一排查修复并记录了解决方案文档。

### 4. 口径B 限速模型验证

针对">100% 线速"的质疑，分析确认 tc tbf 只限 egress（出向），读带宽 = 3 个 slave 各千兆之和 ≈ 340 MiB/s，写带宽 = 157 单口千兆 ≈ 113 MiB/s，与实测精确吻合。与 JuiceFS 完全同口径，数据有效。

### 5. 报告文档更新

- 更新调优主文档 `doc/perf-analysis/01-beegfs-perf-tuning.md`，新增 Stage3 对齐口径小节
- 更新汇总报告 `results/stage3-summary.md`
- 新增口径B 切网问题记录 `doc/perf-tasks/stage3-kB-network-fix.md`

---

## 产出物

| 类别 | 数量 | 说明 |
|------|------|------|
| 原始数据 | 5997 个文件（331MB） | 口径A 2999 + 口径B 2998（fio 输出 + bw_log + IB counters + iostat） |
| 测试脚本 | 5 个 | stage3-kA.sh / item9 / item10 / median.py + 口径B 变体 |
| 文档 | 3 份更新 | 调优主文档 + 汇总报告 + 切网修复记录 |
| Git 提交 | 3 次 | c6ffb59 / 0cab197 / 3d321f5 |

---

## 价值

本周产出的对齐口径基线数据可直接用于 BeeGFS 与 JuiceFS 两方案的横向对比。关键发现"BeeGFS 无 FUSE 缓冲虚高"为对比数据的可信度提供了方法学保障。口径B 切网问题的排查记录为后续切换提供了可复用的操作指南。
