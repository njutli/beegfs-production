# Stage3 口径A 结果 (100GbE RDMA, 冷态 direct=1)

> 日期: 2026-07-15 | fio 3.28 | bw_log 稳态中位数 (截尾1/4)

## 关键发现
BeeGFS fio 平均 ≈ 稳态中位数（差异 <3%），因为 BeeGFS 是内核模块(非 FUSE)，--direct=1 真正绕过所有客户端缓冲。与 JuiceFS (fio 平均被缓冲拉高 7-8%) 不同，BeeGFS 的 fio 平均值可信。

## 测试结果

| 测试项 | fio平均 R | fio平均 W | 稳态中位 R | 稳态中位 W | ≥6250? |
|--------|:---:|:---:|:---:|:---:|:---:|
| seqread (256k,1j,180s) | 1605 | — | 1644 | — | ✗ |
| seqwrite (4M,1j,fsync) | — | 1908 | — | 1906 | ✗ |
| mseqread (256k,16j,180s) | 7562 | — | 7565 | — | ✓ |
| mseqwrite (4M,16j,fsync) | — | 11264 | — | 11314 | ✓ |
| layout (128j,4M) | — | 10342 | — | 10199 | ✓ |
| randread r1 (256k,128j) | 9040 | — | 9045 | — | ✓ |
| randwrite-analysis r1 | — | 6510 | — | 6505 | ✗ (98%) |
| randrw-analysis r1 | 4859 | 4856 | 4853 | 4836 | ✗ |
| randread-64K r1 | 4798 | — | 4759 | — | ✗ |
| randread-1M r1 | 9792 | — | 9796 | — | ✓ |
| randwrite-fresh r1 (验收) | — | 6614 | — | 6795 | ✗ (99%) |
| randrw-fresh r1 R/W (验收) | 2487 | 4183 | 2573 | 4279 | R✗ W✗ |

### randrw 详细 (R/W/合计)

| 测试项 | 读 (MiB/s) | 写 (MiB/s) | 读写合计 (MiB/s) |
|--------|:---:|:---:|:---:|
| randrw-analysis r1 | 4853 | 4836 | 9689 |
| randrw-analysis r2 | 4765 | 4756 | 9521 |
| randrw-analysis r3 | 4844 | 4852 | 9696 |
| randrw-fresh r1 | 2573 | 4279 | 6852 |
| randrw-fresh r2 | 2610 | 4331 | 6941 |
| randrw-fresh r3 | 2650 | 4409 | 7059 |

> randrw 验收版 R<W：高并发下写走客户端缓冲先排空，读须真等后端返回。合计更能反映总吞吐。

## 多轮一致性 (randread 稳态中位数)
| 轮次 | randread-256K | randwrite-analysis | randread-64K | randread-1M |
|------|:---:|:---:|:---:|:---:|
| r1 | 9045 | 6505 | 4759 | 9796 |
| r2 | 9044 | 6488 | 4720 | 9794 |
| r3 | 9040 | 6584 | 4740 | 9803 |
| 极差 | 0.06% | 1.5% | 0.8% | 0.09% |
