# 任务书 · 阶段3 — 对齐 JuiceFS 测试口径的重测（双口径全量冷态基线）

> 执行方：GLM（新会话，本任务书自包含）
> 派发方：规划 agent
> 依据：`demo/production/prod-deploy/doc/perf-tasks/01-full-cold-baseline.md` + `demo/production/prod-deploy/skills/test-commands-reference.md`
> 日期：2026-07-14
> 优先级：P1（现有数据无法与 JuiceFS 方案直接对比，需对齐口径后重测）
> 前置：BeeGFS 集群需重新部署（已被 `clean-beegfs.sh --yes --purge` 清理），使用 `deploy-beegfs.sh deploy` 重新部署

---

## 0. 背景（新会话必读）

### 0.1 为什么需要重测

BeeGFS 之前已完成完整的性能测试（stage1-stage2，100+ 轮次），数据存放在 `results/20260708-stage2-dual-baseline/` 和 `results/20260709-stage2-unmet-rootcause/`，报告见 `report/` 目录。**但这些数据无法与 JuiceFS 方案的测试数据直接对比**，因为两者的 fio 测试参数存在 3 项致命差异：

| 差异 | BeeGFS 现有数据 | JuiceFS 任务书 | 后果 |
|------|----------------|---------------|------|
| **seqwrite 块大小** | `bs=256K` | `bs=4M` | 同名 "seqwrite" 测的是不同负载，4M 块写吞吐远高于 256K，直接比就是拿不同项目比 |
| **顺序读时长** | `--size=4G`（跑完即止，~2.7s） | `--time_based --runtime=180`（180s） | BeeGFS 顺序读只跑 2.7 秒，瞬态占比极高；JuiceFS 跑 180 秒稳态主导。数据口径完全不同 |
| **无 bw_log** | 仅 fio 报告的 `bw=` 平均值 | `--write_bw_log --log_avg_msec=1000` → 截开头 1/4 → 取稳态中位数 | JuiceFS 任务书红线要求**只认稳态中位数不认平均**（fio 平均会被客户端缓冲暂态拉高 7-8%，写类可超网卡线速），BeeGFS 无 bw_log 无法回溯算中位数 |

此外还有 2 项重要差异：
- 随机测试时长 60s（BeeGFS）vs 180s（JuiceFS），60s 偏短但 3 轮设计能抓 outlier
- randwrite/randrw 只跑了 analysis 版（复用 layout 覆写），缺少 JuiceFS 验收口径版（fresh volume + `--create_on_open=1`）

**结论**：必须按 JuiceFS 任务书的 fio 参数对 BeeGFS 重测一遍，才能做方案间横向对比。

### 0.2 参数来源

本任务书的所有 fio 参数**逐项对齐**以下文件，不自行发明参数：
- **测试项与参数**：`demo/production/prod-deploy/skills/test-commands-reference.md` §一测试项总表 + §四/§五/§六 各项完整命令
- **稳态中位数方法**：同上 §八（bw_log 采集 + 截尾取中位数 + 红线规则）
- **数据采集规范**：同上 §九（5 类文件：fio 原始输出 + bw_log + NIC + 进程 CPU + commands.sh）
- **测试方法论**：`demo/production/prod-deploy/skills/TESTING-GUIDE.md`（缓冲暂态/可靠性判据/命令记录规范）

与 JuiceFS 不同的部分（因架构差异，非方法学差异）：
| 项 | JuiceFS | BeeGFS | 原因 |
|----|---------|--------|------|
| 缓存清理 | drop 客户端 cache | drop 客户端 + 3 slaves page cache | BeeGFS storage 用 server page cache，需一并清 |
| 后端清理 | compact cooldown（RocksDB） | 60s sleep | BeeGFS 无 RocksDB compaction 问题 |
| 内部计数器 | `juicefs stats`（object GET/PUT） | IB counters + iostat | BeeGFS 无等效内部计数器，用 IB/iostat 交叉验证 |
| 预读开关 | `--max-readahead 0`（A/B 对照） | 无（read_ahead 触 157 红线） | BeeGFS read_ahead 在 157 内核参数，红线不动 |

### 0.3 集群拓扑

| 节点 | 内网 IP | 角色 | 磁盘 |
|------|---------|------|------|
| client (157) | 10.20.1.157 | mgmtd + meta + client（同机跑 K8s + WekaIO） | nvme1n1 ext4 → metadata |
| slave1 (150) | 10.20.1.150 | meta + 2 storage | nvme1n1 ext4(meta) + nvme2n1/nvme3n1 XFS(storage) |
| slave2 (151) | 10.20.1.151 | 同 slave1 | 同上 |
| slave3 (152) | 10.20.1.152 | 同 slave1 | 同上 |

- 镜像：Buddy Mirror，chunk=1M，numtargets=3
- 数据面（口径A）：100GbE RDMA/RoCE，`connUseRDMA=true`
- 数据面（口径B）：10GbE TCP，`connUseRDMA=false`，eno12409 + tc tbf 1Gbps

### 0.4 安全红线（不变）

| 可以动 | 禁止动 |
|--------|--------|
| BeeGFS `.conf` 应用层参数 | 157 内核参数（THP/dirty/read_ahead） |
| slave 内核参数 | 100GbE 网卡/驱动/RoCE QoS（与 WekaIO 物理共用） |
| eno12409 上的 tc tbf 限速 | md0 / /mnt/data01-04 / /opt/weka / /weka |
| 子目录 stripe（测后删除） | 根目录 stripe |

---

## 1. 测试矩阵

### 1.1 双口径

| 口径 | 网络 | 线速 | 50% 线 | 验收 |
|------|------|------|--------|------|
| A（不限速） | 100GbE RDMA | 12500 MiB/s | 6250 MiB/s | ≥6250 达标 |
| B（千兆限速） | eno12409 TBF 1Gbps | ~118 MiB/s | 59 MiB/s | ≥59 达标 |

> 口径 A 的 6250 线对 BeeGFS 单客户端单挂载几乎到不了（单流受 per-IO 延迟限制）。口径 A 看**趋势 + 放大倍数**（fio ≤ NIC ≤ 磁盘），不按 6250 判"全不达标"。
> 口径 B 多流项 >100% 属正常：3 slave 各走 1gbit，聚合上限 ≈ 354 MiB/s。

### 1.2 测试项总表

> 所有项的 fio 参数**逐项对齐** `test-commands-reference.md`，改动只有目录路径和 `--write_bw_log` 前缀。

| # | 测试项 | fio --rw | bs | numjobs | runtime | REPEAT | 验收 | 参数来源 |
|---|--------|----------|-----|---------|---------|--------|------|---------|
| 1 | seqread | `read` | 256k | 1 | 180s | 1 | ≥ACCEPT | §4.1 |
| 2 | seqwrite(fsync) | `write` | **4M** | 1 | — | 1 | ≥ACCEPT | §4.2 |
| 3 | mseqread | `read` | 256k | 16 | 180s | 1 | ≥ACCEPT | §4.4 |
| 4 | mseqwrite | `write` | **4M** | 16 | — | 1 | ≥ACCEPT | §4.5 |
| 5 | layout | `write` | 4M | 128 | — | 1 | — | §5 |
| 6 | randread | `randread` | 256k | 128 | 180s | 3 | ≥ACCEPT | §6.1 |
| 7 | randwrite(analysis) | `randwrite` | 256k | 128 | 180s | 3 | ≥ACCEPT | §6.4 |
| 8 | randrw(analysis) | `randrw` | 256k | 128 | 180s | 3 | R/W≥ACCEPT | §6.4 |
| 9 | randwrite(验收) | `randwrite` | 256k | 128 | 180s | 3 | ≥ACCEPT | §6.2 |
| 10 | randrw(验收) | `randrw` | 256k | 128 | 180s | 3 | R/W≥ACCEPT | §6.3 |
| 11 | randread-64K | `randread` | 64k | 128 | 180s | 3 | — | §6.1 改 bs |
| 12 | randread-1M | `randread` | 1M | 128 | 180s | 3 | — | §6.1 改 bs |

> **与原 BeeGFS 测试的关键变化**（标 **bold**）：
> - seqwrite/mseqwrite：`bs` 从 256K 改为 **4M**
> - seqread/mseqread：加 `--time_based --runtime=180`（原为 `--size=4G` 跑完即止）
> - 所有项：加 `--write_bw_log --log_avg_msec=1000`（原无 bw_log）
> - randread/randwrite/randrw：`--runtime` 从 60 改为 **180**
> - 新增 randwrite/randrw **验收口径**（fresh dir + `--create_on_open=1`，原只有 analysis 版）
> - bs sweep：`--runtime` 从 60 改为 **180**

---

## 2. 固定配置

### 2.1 环境变量

```bash
MNT="/mnt/beegfs"                              # BeeGFS 挂载点（157）
SEQ_DIR="${MNT}/seq_dir"                       # 顺序测试目录
TEST_DIR="${MNT}/test_dir"                     # 随机测试目录（= layout 目录）
BW_LOG_DIR="/tmp/beegfs-bw"                    # bw_log 输出目录
RESULTS_DIR="results/202607XX-stage3-aligned/" # 结果目录（测时填日期）
```

### 2.2 BeeGFS 配置（两口径共用）

- Stripe：Buddy Mirror，chunk=1M，numtargets=3（根目录已配，不变）
- `connDisableAuthentication = true`（不变）
- 冷态：`--direct=1` + `drop_all_caches`（客户端 + 3 slaves）每项跑前

### 2.3 口径切换

**口径 A（不限速，100GbE RDMA）**：
```bash
# 确认 connUseRDMA=true + connInterfacesFile 锁定 RDMA 网卡
grep connUseRDMA /etc/beegfs/beegfs-client.conf      # 应为 true
cat /etc/beegfs/connInterfacesFile.conf               # 应为 enp139s0f0np0 + enp139s0f1np1
# RDMA 哨兵检查（每轮跑前必做）：seqwrite clat_min < 250µs
fio --name=sentinel --directory="${SEQ_DIR}" --rw=write --refill_buffers \
    --bs=256K --size=1G --direct=1 --end_fsync=1 2>&1 | grep 'clat.*min='
```

**口径 B（千兆限速，10GbE TCP）**：
```bash
# 切换：connUseRDMA=false + connInterfacesFile 指向 eno12409 的 IP
#   —— 关键：BeeGFS 数据面必须真正经 eno12409，否则 tc 白限（数据仍走 100GbE，全部作废）
# 在 4 节点上 tc tbf 1gbit 双向限速
sudo tc qdisc add dev eno12409 root tbf rate 1gbit burst 32kbit latency 100ms
# 确认限速生效（3 项缺一不可）：
#   1) tc qdisc show dev eno12409 显示 tbf rate 1Gbit
#   2) beegfs-net（157）确认 client↔slave 连接走的是 eno12409 网段 IP、且为 TCP（非 RDMA）
#   3) sar -n DEV 1 抓 eno12409：跑 fio 期间该网卡有满额流量
# 红线：若 fio 单流 bw 远超 ~118 MiB/s（或多流聚合远超 ~354），说明数据没走 eno12409、限速未生效
#       → 该轮数据作废，切网重来（参照 JuiceFS 上轮 "TBF 加错网卡致千兆数据全废" 教训）
# 测完恢复：tc qdisc del dev eno12409 root 2>/dev/null; connUseRDMA=true; connInterfacesFile 恢复 RDMA
```

---

## 3. 测试步骤

### 3.1 前置准备

```bash
# 0. 重新部署 BeeGFS（已被清理）
bash deploy-beegfs.sh deploy

# 1. 验证部署
bash deploy-beegfs.sh verify    # 全部 PASS
bash deploy-beegfs.sh status    # 4 meta + 3 storage + 6 targets Good

# 2. 确认安全红线未触碰
# 157 上 weka-agent active + K8s 正常
```

### 3.2 口径 A（不限速）测试序列

> 每项跑前：`drop_all_caches`（sync + echo 3 > drop_caches on 157 + 3 slaves）
> 每项必采：fio 原始输出 + bw_log + NIC（IB counters for RDMA / sar for 口径B）+ iostat（3 slaves）+ commands.sh

```bash
# === 顺序测试 ===

# prep：写 4G 顺序读数据源（用 4M 块写，对齐 JuiceFS prep）
mkdir -p "${SEQ_DIR}"
fio --name=prep --directory="${SEQ_DIR}/" --rw=write --bs=4M --size=4G --direct=1 >/dev/null 2>&1

# 1. seqread（bs=256k, 1 job, 180s）
#    参数来源：test-commands-reference.md §4.1
drop_all_caches
fio --name=seqread --directory="${SEQ_DIR}/" \
    --rw=read --refill_buffers --bs=256k --size=4G \
    --direct=1 --ioengine=psync --iodepth=1 \
    --time_based --runtime=180 \
    --write_bw_log="${BW_LOG_DIR}/seqread" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS_DIR}/seqread/fio-seqread.txt"

# 2. seqwrite（bs=4M, 1 job, fsync）
#    参数来源：test-commands-reference.md §4.2
rm -rf "${SEQ_DIR}"; mkdir -p "${SEQ_DIR}"
fio --name=seqwrite --directory="${SEQ_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${BW_LOG_DIR}/seqwrite" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS_DIR}/seqwrite/fio-seqwrite.txt"

# 3. mseqread（bs=256k, 16 job, 180s）
#    参数来源：test-commands-reference.md §4.4
#    prep：16 job 各写 4G
rm -rf "${SEQ_DIR}"; mkdir -p "${SEQ_DIR}"
fio --name=prep --directory="${SEQ_DIR}/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
drop_all_caches
fio --name=mseqread --directory="${SEQ_DIR}/" \
    --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting \
    --direct=1 --ioengine=psync --iodepth=1 \
    --time_based --runtime=180 \
    --write_bw_log="${BW_LOG_DIR}/mseqread" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS_DIR}/mseqread/fio-mseqread.txt"

# 4. mseqwrite（bs=4M, 16 job, fsync）
#    参数来源：test-commands-reference.md §4.5
rm -rf "${SEQ_DIR}"; mkdir -p "${SEQ_DIR}"
fio --name=mseqwrite --directory="${SEQ_DIR}/" \
    --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${BW_LOG_DIR}/mseqwrite" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS_DIR}/mseqwrite/fio-mseqwrite.txt"
rm -rf "${SEQ_DIR}"

# === layout（预铺 128G 数据）===

# 5. layout（128 job × 1G, bs=4M）
#    参数来源：test-commands-reference.md §5
rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
fio --directory="${TEST_DIR}" \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1 \
    --write_bw_log="${BW_LOG_DIR}/layout" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS_DIR}/layout/fio-layout.txt"

# layout 后 cooldown（60s，BeeGFS 无 compact 需求）
sleep 60

# === 随机测试 ===

# 6. randread（复用 layout, bs=256k, 128 job, 180s, ×3）
#    参数来源：test-commands-reference.md §6.1
for i in 1 2 3; do
    drop_all_caches
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --filesize=1G --size=1G \
        --bs=256k --rw=randread \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/randread-r${i}" --log_avg_msec=1000 \
        2>&1 | tee "${RESULTS_DIR}/randread-r${i}/fio-randread-r${i}.txt"
    sleep 10
done

# 7. randwrite analysis（复用 layout, bs=256k, 128 job, 180s, ×3）
#    参数来源：test-commands-reference.md §6.4
for i in 1 2 3; do
    drop_all_caches
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --filesize=1G --size=1G \
        --bs=256k --rw=randwrite \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=100 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/randwrite-analysis-r${i}" --log_avg_msec=1000 \
        2>&1 | tee "${RESULTS_DIR}/randwrite-analysis-r${i}/fio-randwrite-analysis-r${i}.txt"
    sleep 10
done

# 8. randrw analysis（复用 layout, bs=256k, 128 job, 180s, ×3）
#    参数来源：test-commands-reference.md §6.4
for i in 1 2 3; do
    drop_all_caches
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --filesize=1G --size=1G \
        --bs=256k --rw=randrw \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=100 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/randrw-analysis-r${i}" --log_avg_msec=1000 \
        2>&1 | tee "${RESULTS_DIR}/randrw-analysis-r${i}/fio-randrw-analysis-r${i}.txt"
    sleep 10
done

# 9. randwrite 验收口径（fresh volume + create_on_open, bs=256k, 128 job, 180s, ×3）
#    参数来源：test-commands-reference.md §6.2
#    ⚠️ 空卷语义对齐（问题4）：JuiceFS 验收口径 = destroy→format→mount 的真空卷。
#       BeeGFS 仅 rm -rf 子目录 ≠ 真空卷（storage target 上旧 chunk 未回收，占盘/占分配表）。
#       为严格对齐，**本组（第 9、10 项）开跑前整体重部署一次 BeeGFS**，让 storage 回到空盘：
#         bash clean-beegfs.sh --yes --purge      # 清空 storage target（真空卷）
#         bash deploy-beegfs.sh deploy            # 重新部署
#         bash deploy-beegfs.sh verify            # 全 PASS
#       重部署后需重配根目录 stripe（Buddy Mirror/chunk=1M/numtargets=3）。
#       重部署只做一次（第 9、10 项共用这个空卷起点）；组内每轮仍 rm -rf + drop_all_caches。
#    注意：重部署会清掉前面第 1-8 项复用的 layout；第 9、10 项本就是 fresh 语义，不依赖旧 layout。
for i in 1 2 3; do
    rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
    drop_all_caches
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --nrfiles=100 --filesize=1G --size=1G \
        --bs=256k --rw=randwrite \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/randwrite-fresh-r${i}" --log_avg_msec=1000 \
        2>&1 | tee "${RESULTS_DIR}/randwrite-fresh-r${i}/fio-randwrite-fresh-r${i}.txt"
    sleep 10
done

# 10. randrw 验收口径（fresh volume + create_on_open, bs=256k, 128 job, 180s, ×3）
#     参数来源：test-commands-reference.md §6.3
#     ⚠️ 空卷语义对齐（问题4）：第 9 项 randwrite 已把卷写满，本项须重新回到空卷。
#        本组开跑前再整体重部署一次（与第 9 项同样的 clean --purge + deploy + verify + 重配 stripe），
#        保证 randrw 验收也是真空卷起点。组内每轮仍 rm -rf + drop_all_caches。
for i in 1 2 3; do
    rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
    drop_all_caches
    fio --directory="${TEST_DIR}" \
        --name=storage_test \
        --nrfiles=100 --filesize=1G --size=1G \
        --bs=256k --rw=randrw \
        --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="${BW_LOG_DIR}/randrw-fresh-r${i}" --log_avg_msec=1000 \
        2>&1 | tee "${RESULTS_DIR}/randrw-fresh-r${i}/fio-randrw-fresh-r${i}.txt"
    sleep 10
done

# 11-12. bs sweep: randread at 64K / 1M（复用 layout, 180s, ×3 each）
#       参数来源：test-commands-reference.md §6.1 改 bs
for bs in 64k 1M; do
    for i in 1 2 3; do
        drop_all_caches
        fio --directory="${TEST_DIR}" \
            --name=storage_test \
            --filesize=1G --size=1G \
            --bs=${bs} --rw=randread \
            --ioengine=libaio --iodepth=128 --numjobs=128 \
            --direct=1 --fallocate=none \
            --group_reporting --time_based --runtime=180 \
            --write_bw_log="${BW_LOG_DIR}/randread-${bs}-r${i}" --log_avg_msec=1000 \
            2>&1 | tee "${RESULTS_DIR}/randread-${bs}-r${i}/fio-randread-${bs}-r${i}.txt"
        sleep 10
    done
done

# 清理
rm -rf "${TEST_DIR}" "${SEQ_DIR}"
```

### 3.3 口径 B（千兆限速）测试序列

1. 切换到口径 B（`connUseRDMA=false` + eno12409 + tc tbf 1gbit on 4 nodes）
2. 清重启全部 BeeGFS 服务（mgmtd → meta → storage → helperd → client）
3. 验证限速真生效（§2.3 三项确认）：`beegfs-net` 确认走 eno12409 网段 TCP、`sar -n DEV` 抓到 eno12409 满流量、fio 单流 bw ≤ ~118 MiB/s
   - **若 fio bw 远超 118（单流）/ 354（多流聚合），数据没走 eno12409，该轮作废，切网重来**
4. 跑与口径 A 完全相同的测试矩阵（§3.2 全部 12 项）
5. 测完恢复 RDMA：`connUseRDMA=true` + connInterfacesFile 恢复 + `tc qdisc del` + 清重启

> 口径 B 注意：千兆限速下多流项 >100% 属正常（3 slave 各走 1gbit，聚合 ≈ 354 MiB/s）。
> 口径 B 验收线 ACCEPT=59。

---

## 4. 数据采集与处理

### 4.1 每项必采（5 类文件）

| 文件 | 说明 | 来源 |
|------|------|------|
| `fio-<item>.txt` | fio 完整终端输出 | §9.1 |
| `<prefix>_bw.*.log` | 逐秒瞬时带宽（128 job → 128 个文件） | §9.2 |
| `ib-<item>-slave{150,151,152}.ib` 或 `sar-<item>.txt` | NIC 监控（口径A用IB counters，口径B用sar eno12409） | §9.3 适配 |
| `iostat-<item>-slave{150,151,152}.txt` | 3 slaves 磁盘活动 | 交叉验证 |
| `commands.sh` | 完整命令记录 | §11 |

> BeeGFS 无 `juicefs stats` 等效物，用 IB counters（口径A）/ sar（口径B）+ iostat 替代，验证 fio ≤ NIC ≤ 磁盘。
> IB counters 采样方法见 `tests/lib/ib-iostat-sampler.sh`（已有）。
> pidstat 对 BeeGFS 不适用（BeeGFS 是内核模块不是用户态进程），跳过。

### 4.2 稳态中位数计算（达标值只认这个，不认 fio 平均）

> 参数来源：`test-commands-reference.md` §八

所有项用 `--write_bw_log --log_avg_msec=1000` 采集逐秒瞬时带宽，测后处理：

```bash
# 单 job 项（seqread/seqwrite, 1 个 bw_log 文件）：
python3 -c "
import statistics
vals = [float(l.split(',')[1]) for l in open('${BW_LOG_DIR}/seqread_bw.1.log')]
steady = vals[len(vals)//4:]  # 截掉开头 1/4 缓冲暂态
print(round(statistics.median(steady)/1024, 1), 'MB/s')
"

# 128 job 项（randread/randwrite/randrw, 128 个 bw_log 文件）：
# 按时间戳对齐求和所有 job 的逐秒带宽，按 data_direction 分读写，
# 截开头 1/4 后取中位数
python3 -c "
import glob, statistics
from collections import defaultdict
ts_dir = defaultdict(lambda: [0, 0])
for f in glob.glob('${BW_LOG_DIR}/randread-r1_bw.*.log'):
    for line in open(f):
        parts = line.strip().split(',')
        ts = int(parts[0])
        bw = float(parts[1])
        d = int(parts[2])  # 0=read, 1=write
        ts_dir[ts][d] += bw
read_vals = [v[0] for v in sorted(ts_dir.values())]
write_vals = [v[1] for v in sorted(ts_dir.values()) if v[1] > 0]
n = len(read_vals)
if read_vals:
    print('R:', round(statistics.median(read_vals[n//4:])/1024, 1), 'MB/s')
if write_vals:
    print('W:', round(statistics.median(write_vals[n//4:])/1024, 1), 'MB/s')
"
```

### 4.3 红线

- 任何 fio 平均 BW 超单客户端网卡线速（千兆≈124 / 100GbE≈12500 MiB/s）必是假象，**不认**，改取 bw_log 稳态中位数
- 达标判定只看**稳态中位数**，不看 fio 报告的 `bw=` 平均值
- **多轮（×3）达标轮口径与 JuiceFS 对齐**：冷态取 **r1** 为达标值（`01-full-cold-baseline.md` §三口径），r2/r3 仅作 outlier 交叉验证；另在 summary 标注三轮稳态中位数的 MAX/均值供参考，与 JuiceFS 横向对比时须同口径（均取 r1）

### 4.4 summary.md 格式

每组每口径一个 `summary.md`，除记录 fio 平均外，**必须另起一栏记稳态中位数**：

```markdown
## 测试项结果

| 测试项 | fio 平均 (MiB/s) | 稳态中位数 (MiB/s) | %线速 | ≥ACCEPT? |
|--------|:---:|:---:|:---:|:---:|
| seqread | XXX | XXX | XX% | ✓/✗ |
| seqwrite | XXX | XXX | XX% | ✓/✗ |
| ... | | | | |
```

### 4.5 randrw 数据必须列 读/写/合计 三项（对齐 JuiceFS 汇总口径）

> randrw 的测试参数（bs=256k、numjobs=128、iodepth=128）**来源于存储规格文档，严格保持不变**。
> 但汇总时须完整呈现，因为高并发下 R/W 分列会失真（见下方说明）。

randrw（第 8、10 项）在 summary 中**必须同时列出读、写、读写合计三列**：

```markdown
| 测试项 | randrw 读 (MiB/s) | randrw 写 (MiB/s) | 读写合计 (MiB/s) | ≥ACCEPT? |
|--------|:---:|:---:|:---:|:---:|
| randrw(analysis) | R | W | R+W | R/W 各判 |
| randrw(验收) | R | W | R+W | R/W 各判 |
```

> **判读说明（写入 summary + 报告）**：`numjobs=128 × iodepth=128` = 16384 并发在途 IO，
> 远超单客户端可消化的请求数，导致 fio 客户端侧队列积压（实测 clat 可达数千~数万秒、`>=2000ms` 占比高）。
> 此时 R/W **分列比例**主要反映 fio 混合队列的排队行为（写走客户端缓冲先排空、读须真等后端返回），
> **不完全代表存储真实读写能力**。因此：
> - **列出 R、W、合计三项**（合计更能反映总吞吐）；
> - 与 JuiceFS 横向对比时，读、写、合计**逐项对齐比较**，但重点看合计；
> - JuiceFS 汇总侧采用同一口径（`prod-deploy/doc/perf-analysis/01` §2.2 已记录同一现象），保证可比。

---

## 5. 结果落盘

### 5.1 目录命名

```
results/stage3-aligned-{nolimit|1gbit}-<YYYYMMDD-HHMMSS>/
```

### 5.2 目录结构

```
results/stage3-aligned-nolimit-202607XX/
├── summary.md                        # 结果汇总（含 fio 平均 + 稳态中位数）
├── commands.sh                       # 完整命令记录
├── env-snapshot.txt                  # 环境快照（含 RDMA 哨兵 / tc 状态 / beegfs-ctl 拓扑）
├── seqread/
│   ├── fio-seqread.txt               # fio 原始输出
│   ├── seqread_bw.1.log              # bw_log（1 个文件，单 job）
│   ├── ib-seqread-slave{150,151,152}.ib   # IB counters（口径A）
│   └── iostat-seqread-slave{150,151,152}.txt  # 磁盘活动
├── seqwrite/
│   └── ...
├── randread-r1/
│   ├── fio-randread-r1.txt
│   ├── randread-r1_bw.1.log ~ _bw.128.log   # 128 个文件
│   └── ...
└── ...
```

### 5.3 汇总

测完后更新 `report/BeeGFS 方案性能调优演进报告.md`，新增 §3.3 "对齐口径重测"小节，列出：
- fio 平均 vs 稳态中位数对比（验证缓冲暂态影响）
- 与原 stage2 数据的差异（bs=4M vs 256K 的 seqwrite 差异、180s vs 4G 的 seqread 差异）
- 与 JuiceFS 方案数据的横向对比表

---

## 6. 开跑前 checklist

- [ ] BeeGFS 已重新部署（`deploy-beegfs.sh deploy` + `verify` 全 PASS）
- [ ] RDMA 锁定确认（口径A）：`connInterfacesFile` = enp139s0f0np0 + enp139s0f1np1
- [ ] RDMA 哨兵通过：seqwrite clat_min < 250µs
- [ ] fio 版本 ≥ 3.28（支持 `--write_bw_log --log_avg_msec`）
- [ ] 所有 fio 命令均带 `--write_bw_log --log_avg_msec=1000`
- [ ] seqwrite/mseqwrite 用 `bs=4M`（不是 256K）
- [ ] seqread/mseqread 用 `--time_based --runtime=180`（不是 `--size=4G` 跑完即止）
- [ ] 随机项 `--runtime=180`（不是 60）
- [ ] 每项跑前 `drop_all_caches`（157 + 3 slaves）
- [ ] layout 后 60s cooldown
- [ ] **验收口径组（第 9、10 项）各自开跑前整体重部署 BeeGFS（clean --purge + deploy + verify + 重配根目录 stripe），对齐 JuiceFS 空卷语义（问题4）**
- [ ] **randrw（第 8、10 项）summary 列出 读/写/合计 三项，并注明高并发 R/W 分列失真、以合计为准（问题1）**
- [ ] 口径B：tc tbf 在 eno12409（不在 eno12399 管理网），beegfs-net 确认数据走 eno12409 TCP，sar 确认限速生效，fio 单流 bw ≤118（超则数据作废重来）
- [ ] 口径B测完恢复 RDMA + tc del + 清重启 + 哨兵复查
- [ ] 多轮项达标值取 r1（与 JuiceFS 对齐），summary 另标 MAX/均值

---

## 7. 预计耗时

| 口径 | 顺序项 | layout+cooldown | 随机项（12 组 × 3 轮 × 180s） | 验收组重部署×2 | 合计 |
|------|--------|----------------|-------------------------------|:---:|------|
| A | ~15min | ~5+1min | ~110min | ~20min | ~3h |
| B | ~15min | ~5+1min | ~110min | ~20min | ~3h |
| **合计** | | | | | **~6h** |

> 含口径切换（RDMA→TCP + tc + 清重启 + 测后恢复）约 30min。
> 验收口径组（第 9、10 项）各重部署一次对齐空卷语义（问题4），每口径 +2 次 ×~10min。
