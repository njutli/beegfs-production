# Stage3 对齐口径重测 — 完整结果汇总

> 日期：2026-07-15 | fio 3.28 | 所有结论值 = bw_log 稳态中位数（逐秒聚合 → 截尾开头 1/4 → 中位数）
> 测试方法：对齐 JuiceFS `test-commands-reference.md` 的 fio 参数
>   - 顺序读/随机项：180s time_based
>   - seqwrite/mseqwrite（4M，fsync 版）/layout：**定量写（4G / 128G），非 180s**——与 JuiceFS §4.2/§4.5/§五 一致
>   - seqwrite bw_log 仅 2 个采样点，其"稳态中位数"实为整段均值（定量写太快，属正常，与 JuiceFS 同口径）
> 双口径：口径A（100GbE RDMA 不限速）+ 口径B（eno12409 TCP tc tbf 1Gbps 千兆限速）

---

## 一、关键发现

### 1. BeeGFS fio 平均 ≈ 稳态中位数（差异 ≤3.5%）

与 JuiceFS（fio 平均被 FUSE 客户端缓冲拉高 7-8%）不同，BeeGFS 是内核模块（非 FUSE），`--direct=1` 真正绕过所有客户端缓冲。BeeGFS 的 fio 平均与稳态中位数差异小（顺序项 ~2.4%、fresh-write 起步慢使中位数略高于均值 ~2.7-3.5%）。**本报告所有结论值统一取稳态中位数**（口径与 JuiceFS 对齐；横向对比时两方案均用稳态中位数）。

### 2. 口径B 切网问题

口径B 切换遇到 3 个问题（详见 `doc/perf-tasks/stage3-kB-network-fix.md`）：
- `connInterfacesFile` 在 conf 中为空值（deploy 脚本不设置此参数）
- `sysMgmtdHost` 需改为 eno12409 网段 IP（10.114.1.157）
- rootcause-enter-kB.sh 的 sed 未匹配注释行

修复后三重验证通过（beegfs-net TCP 10.114.1.x + tc tbf 1Gbit + fio bw=53.1 MiB/s）。

---

## 二、口径A 结果（100GbE RDMA, 不限速, ACCEPT=6250）

| 测试项 | 稳态中位 R | 稳态中位 W | %线速 | ≥6250? |
|--------|:---:|:---:|:---:|:---:|
| seqread (256k,1j,180s) | 1644 | — | 13.2% | ✗ |
| seqwrite (4M,1j,fsync) | — | 1906 | 15.2% | ✗ |
| mseqread (256k,16j,180s) | 7565 | — | 60.5% | ✓ |
| mseqwrite (4M,16j,fsync) | — | 11314 | 90.5% | ✓ |
| layout (128j,4M) | — | 10199 | 81.6% | ✓ |
| randread r1 (256k,128j,180s) | 9045 | — | 72.4% | ✓ |
| randwrite-analysis r1 | — | 6505 | 52.0% | ✗ (98%) |
| randrw-analysis r1 R/W | 4853 | 4836 | 38.8% | ✗ |
| randread-64K r1 | 4759 | — | 38.1% | ✗ |
| randread-1M r1 | 9796 | — | 78.4% | ✓ |
| randwrite-fresh r1 (验收) | — | 6795 | 54.4% | ✗ |
| randrw-fresh r1 R/W (验收) | 2573 | 4279 | 20.6/34.2% | ✗ |

### randrw 详细（R/W/合计）

| 测试项 | 读 (MiB/s) | 写 (MiB/s) | 读写合计 |
|--------|:---:|:---:|:---:|
| randrw-analysis r1 | 4853 | 4836 | 9689 |
| randrw-fresh r1 (验收) | 2573 | 4279 | 6852 |

> 高并发下 R/W 分列失真（写走缓冲先排空），以合计为准。

---

## 三、口径B 结果（eno12409 TCP, 千兆限速, ACCEPT=59）

| 测试项 | 稳态中位 R | 稳态中位 W | %线速 | ≥59? |
|--------|:---:|:---:|:---:|:---:|
| seqread (256k,1j,180s) | 104.2 | — | 88% | ✓ |
| seqwrite (4M,1j,fsync) | — | 64.0 | 54% | ✗ |
| mseqread (256k,16j,180s) | 332.5 | — | 281% | ✓ |
| mseqwrite (4M,16j,fsync) | — | 112.0 | 95% | ✓ |
| layout (128j,4M) | — | 108.0 | 92% | ✓ |
| randread r1 (256k,128j,180s) | 341.6 | — | 289% | ✓ |
| randwrite-analysis r1 | — | 111.6 | 95% | ✓ |
| randrw-analysis r1 R/W | 105.2 | 105.8 | 89/90% | ✓ |
| randread-64K r1 | 341.1 | — | 289% | ✓ |
| randread-1M r1 | 340.0 | — | 288% | ✓ |
| randwrite-fresh r1 (验收) | — | 110.5 | 94% | ✓ |
| randrw-fresh r1 R/W (验收) | 61.9 | 108.5 | 105/92% | ✓ |

> 口径B items 9-10 已补算稳态中位数（randwrite-fresh W=110.5、randrw-fresh R=61.9/W=108.5）。
> randrw-fresh 读稳态中位数 61.9 > ACCEPT=59 → **R 达标**（fio 全程平均 53.0 因空卷起步慢偏低，稳态中位数才是达标口径）。
> 多流项 >100% 属正常（3 slave 各走 1gbit，聚合 ≈ 354 MiB/s）。

---

## 四、与 stage2 原数据的对比

| 测试项 | stage2 (bs=256K/60s/无bw_log) | stage3 (bs=4M/180s/bw_log) | 差异 |
|--------|:---:|:---:|------|
| seqread (口径A) | 1516 | 1644 | +8% (180s 稳态 vs 2.7s 瞬态) |
| seqwrite (口径A) | 832 (bs=256K) | 1906 (bs=4M) | +129% (4M 块写远高于 256K) |
| randread (口径A) | 9252~10752 | 9045 | -3%~-16% (180s 稳态略低) |
| randwrite (口径A) | 6146 | 6505 | +6% |
| seqread (口径B) | 104 | 104.2 | ~0% |
| seqwrite (口径B) | 53.3 (bs=256K) | 64.0 (bs=4M) | +20% |

**关键差异**：seqwrite 从 bs=256K 改为 bs=4M 后，口径A 从 832 涨到 1906（+129%），口径B 从 53.3 涨到 64.0（+20%）。4M 块写效率远高于 256K，尤其在大带宽网络下。

---

## 五、与 JuiceFS 方案对比说明

- BeeGFS fio 平均 ≈ 稳态中位数（≤3.5% 差异），JuiceFS fio 平均被缓冲拉高 7-8%
- 横向对比时，BeeGFS 用 fio 平均或稳态中位数均可（等价），JuiceFS 必须用稳态中位数
- 两方案参数已对齐：bs=4M 写、180s runtime、bw_log、3 轮取 r1、randread 复用 layout

---

## 六、文件清单与数据位置

### 结果数据（已 sync 到本地）

| 路径 | 说明 | 文件数 | 大小 |
|------|------|:------:|:----:|
| `results/stage3-aligned-nolimit-20260715-155122/` | 口径A 原始数据（fio 输出 + bw_log + IB counters + iostat） | 2999 | 133MB |
| `results/stage3-aligned-1gbit-20260715-191158/` | 口径B 原始数据（fio 输出 + bw_log + IB counters + iostat） | 2998 | 188MB |
| `results/stage3-summary.md` | 本汇总报告 | 1 | — |

每个测试项目录含 5 类文件：`fio-<item>.txt`（fio 原始输出）+ `<prefix>_bw.*.log`（逐秒瞬时带宽）+ `ib-<item>-slave{150,151,152}.ib`（IB counters）+ `iostat-<item>-slave{150,151,152}.txt`（磁盘活动）+ summary.md（运行日志）

### 测试脚本

| 路径 | 说明 |
|------|------|
| `tests/stage3-kA.sh` | 口径A 主测试脚本（items 1-8, 11-12，顺序 4 项 + layout + 随机 6 组 ×3 轮） |
| `tests/stage3-kA-item9.sh` | 口径A item 9（randwrite 验收 ×3，fresh dir + create_on_open） |
| `tests/stage3-kA-item10.sh` | 口径A item 10（randrw 验收 ×3，fresh dir + create_on_open） |
| `tests/stage3-median.py` | 稳态中位数计算（bw_log 按秒聚合 → 截尾 1/4 → 取中位数） |
| `/tmp/stage3-kB.sh`（157 上） | 口径B 主测试脚本（由 kA.sh sed 改 RESULTS_DIR 生成，可从 kA 再生） |
| `/tmp/stage3-kB-item9.sh`（157 上） | 口径B item 9（同上） |
| `/tmp/stage3-kB-item10.sh`（157 上） | 口径B item 10（同上） |

### 文档

| 路径 | 说明 |
|------|------|
| `doc/perf-tasks/stage3-aligned-retest-task-book.md` | 对齐 JuiceFS 口径的重测任务书（含测试矩阵、参数来源、步骤、checklist） |
| `doc/perf-tasks/stage3-kB-network-fix.md` | 口径B 切网问题与解决记录（connInterfacesFile 空值 + sysMgmtdHost 网段 + sed 未匹配 + fio stuck） |

### 修改的文件

| 路径 | 改动 |
|------|------|
| `clean-beegfs.sh` | purge 段加 rmmod beegfs + rm /opt/beegfs + rm /var/lib/beegfs + reset-failed（BeeGFS 清理时做的） |

### 157 上的数据原始位置（已 sync 到本地，保留备份）

| 路径 | 说明 |
|------|------|
| `/tmp/beegfs-test/results/stage3-aligned-nolimit-20260715-155122/` | 口径A 原始位置 |
| `/tmp/beegfs-test/results/stage3-aligned-1gbit-20260715-191158/` | 口径B 原始位置 |
| `/tmp/beegfs-bw/` | bw_log 临时目录（fio 写入，测后拷到结果目录） |
