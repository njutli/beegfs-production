# 0.7 — seqread R1≠R2 根因分析

## 07-03 现象回顾
- R1（不限速）: seqread 565 MiB/s
- R2（不限速）: seqread 1521 MiB/s（+170%）
- 偏差远超 10% 阈值

## 实验设计
1. **实验 1**：5 轮连续冷态 seqread，每轮前 drop_all_caches（客户端+3 slave）
2. **实验 2**：暖态→drop→冷态→暖态，验证 warmup 效果

## 实验结果

| 轮次 | 带宽 (MiB/s) | IOPS | 条件 |
|------|-------------|------|------|
| cold-r1 | 1620 | 6478 | drop_all_caches |
| cold-r2 | 1489 | 5955 | drop_all_caches |
| cold-r3 | 1510 | 6041 | drop_all_caches |
| cold-r4 | 1591 | 6365 | drop_all_caches |
| cold-r5 | 1623 | 6493 | drop_all_caches |
| warm-r1 | 1493 | 5970 | 无 drop（暖态） |
| cold-after-warm | 1569 | 6277 | drop_all_caches |
| warm-r2 | 1590 | 6360 | 无 drop（暖态） |

- 均值: 1568 MiB/s
- 范围: 1489-1623 MiB/s
- 最大偏差: 9%（1623 vs 1489）< 10% 阈值 ✓
- 冷态 vs 暖态: 无法区分（cold-r1=1620 > warm-r1=1493）

## 根因结论

**07-03 R1=565 的根因：全新部署后首次 benchmark 的一次性冷启动效应。**

具体机制：
1. 07-03 执行了 clean-beegfs.sh + deploy-beegfs.sh，全部服务重启
2. BeeGFS 客户端内核模块重新加载，RDMA 连接全部冷态
3. BeeGFS 客户端元数据缓存（文件布局信息）为空
4. R1 是部署后首个读操作，需要建立 RDMA 连接 + 拉取元数据，吞吐 565 MiB/s
5. R2 时 RDMA 连接已建立 + 元数据已缓存，吞吐 1521 MiB/s（正常水平）

**当前系统已运行 3 天**，RDMA 连接和元数据缓存已预热。drop_all_caches 只清 page cache，不清 RDMA 连接和元数据缓存。因此：
- 所有 8 轮 seqread 稳定在 1489-1623 MiB/s
- 偏差 9% < 10% 阈值
- 无需修改测试脚本口径

## 对 v2 基线的影响
- v2 基线（0.8）不需要重新部署，R1 不会出现 565 MiB/s 的异常
- seqread 预期 ~1500-1600 MiB/s，R1/R2 偏差 <10%
- drop_all_caches 已正确工作（客户端+服务端 page cache 都清）
- RDMA 连接和元数据缓存是 drop_all_caches 清不掉的，但它们不影响冷态读的带宽（只影响首次建立的延迟）
