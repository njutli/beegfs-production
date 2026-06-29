---
name: bench-beegfs
description: Use when running, reading, or modifying bench-full.sh or bench-basic.sh. Covers test flow, env vars, mode flags (cold/warm), block size sweep, layout, random test rounds, and health check requirements for BeeGFS performance testing. Trigger on: bench-beegfs, bench-full, bench-basic, BeeGFS benchmark, performance test, 全量测试.
---

# bench-full.sh / bench-basic.sh

位于 `tests/` 目录。BeeGFS 性能测试脚本。

## 调用方式

### 基本测试
```bash
bash tests/bench-basic.sh <label>
# 例: bash tests/bench-basic.sh post-deploy
```

### 全量测试
```bash
bash tests/bench-full.sh <tag> <mode> [extra_fio_opts...]
# 例: bash tests/bench-full.sh cold-r1 cold
# 例: bash tests/bench-full.sh warm-r1 warm
```

必须从 `/home/sunrise/beegfs-production` 目录执行（在主服务器上）。

## 全量测试参数

| 参数 | 说明 |
|------|------|
| `tag` | 测试标签，如 `cold-r1`、`warm-r1`、`bs-sweep` |
| `mode` | `cold` = drop_caches + direct=1；`warm` = 不 drop + buffered |
| `extra_fio_opts` | 透传给 fio 的额外参数 |

## 全量测试流程

| Step | 内容 | 预计时间 |
|------|------|---------|
| 1 | 环境快照（beegfs 版本、节点、targets、stripe pattern） | <1min |
| 2 | 顺序测试：seqread/seqwrite/multi-seqread/multi-seqwrite (bs=1M) | ~5min |
| 3 | 布局：128 jobs × 1G = 128G，bs=1M | ~10-20min |
| 4 | Cooldown：60s 等待写入稳定 | 1min |
| 5 | 随机测试：randread/randwrite/randrw × 3轮 (bs=4K, 128 jobs, 60s) | ~9min |
| 6 | Block size sweep：randread at 64K/256K/1M × 3轮 | ~9min |
| 7 | 生成 commands.sh + 清理 | <1min |

## 测试口径

### 冷态（cold）
- `--direct=1`（绕过页缓存）
- 每项跑前 `echo 3 > /proc/sys/vm/drop_caches`
- 随机项 3 轮取均值
- 用于瓶颈定位和基线

### 暖态（warm）
- 不 drop caches
- 不加 `--direct=1`（buffered I/O）
- 代表重复访问场景上限

## 健康检查

测试脚本应 source 健康检查库：
```bash
source tests/lib/beegfs-health-check.sh
```

在关键检查点调用 `check_beegfs_health`：
- 测试开始前
- layout 写完后
- 每轮随机测试前
- 测试结束后

## 结果文件

每个测试结果目录包含：

| 文件 | 说明 |
|------|------|
| `summary.md` | 测试结果摘要 |
| `commands.sh` | 完整命令记录（可复现） |
| `env-snapshot.txt` | 环境快照 |
| `layout.txt` | 布局阶段 fio 输出 |
| `seqread.txt` / `seqwrite.txt` | 顺序测试原始输出 |
| `randread-r1.txt` ... `randread-r3.txt` | 随机测试各轮输出 |
| `randread-64K-r1.txt` ... | block size sweep 输出 |
| `status-after.txt` | 测试后集群状态 |

## 注意事项

1. BeeGFS 使用 RAID0 stripe pattern（无冗余），数据安全靠底层 RAID0
2. layout 阶段会产生 128G 数据，确保 /data 有足够空间
3. 随机测试 128 jobs × 128 iodepth = 高并发，可能触发 fio 残留问题（参考 TESTING-GUIDE.md）
4. 测试前确认所有 BeeGFS 服务正常运行
5. 不要在 /dev/md0 空间不足时跑 layout（128G）
