# 任务书 · 阶段0 — 修复环境/脚本与采集，重建可信基线

> 执行方：GLM
> 派发方：规划 agent（依据 `doc/perf-analysis/01-bottleneck-and-tuning-plan.md` 阶段 0）
> 日期：2026-07-06
> 优先级：**P0（阻塞项，后续所有调优阶段依赖本任务完成）**
> 环境规范：见 `skills/beegfs-node-conventions.md`、测试纪律见 `skills/TESTING-GUIDE.md`、长测监控见 `skills/LONG-RUNNING-TEST-SKILL.md`

---

## 0. 背景与目标

2026-07-03 冷态基线（`results/20260703-beegfs-cold-baseline/`）虽已拿到数据，但存在若干**环境/脚本/采集**缺陷，使其不能作为后续单变量调优的对比锚点。本任务的目标是：**清除全部红线，产出一套「全健康 + 采集完整 + 可复现」的冷态基线**。

**验收总纲**（全部满足才算完成）：
- 4 个 meta target + 6 个 storage target 全部状态 GOOD
- env 快照能完整采到 nodes / targets / mirrorgroups / stripe / mount 信息（无 `Invalid argument`）
- 重跑基线 summary.md 里随机项 IOPS 字段非 NA，且与原始 fio 对账一致
- 随机项三轮偏差 <1%；单流 seqread R1/R2 偏差 <10%
- 全部证据文件留档（见第 8 节）

---

## 1. 环境与访问信息

| 属性 | 值 |
|------|-----|
| 项目目录（157 上） | `/home/sunrise/beegfs-production` |
| client / mgmtd / meta(ID1) | 10.20.1.157（公网 203.156.3.194:19891） |
| slave1 meta(ID2)+storage(101) | 10.20.1.150 |
| slave2 meta(ID3)+storage(102) | 10.20.1.151 |
| slave3 meta(ID4)+storage(103) | 10.20.1.152 |
| SSH | user `sunrise` / pass `Sunrise@801`（`-o StrictHostKeyChecking=no`） |
| sudo | `echo 'Sunrise@801' | sudo -S <cmd>`（若已配 NOPASSWD 则免） |
| 挂载点 | `/mnt/beegfs`；meta 盘 `/mnt/beegfs-meta`；storage `/data/disk1`、`/data/disk2` |
| mgmtd | 10.20.1.157:8008 |

SSH 示例（WSL → client → slave 两级跳，见 node-conventions）：
```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 \
  "sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no sunrise@10.20.1.152 '<command>'"
```

---

## 2. 任务 0.1 — 修复 meta 节点 4（152）通信错误

**现象**：`env-snapshot.txt` 显示 `[ERROR from beegfs-meta beegfs-slave3 [ID: 4]: Communication error]`，meta target 4 容量 `0.0GiB`。152 是 metadata buddy group 2 的 primary，冗余不完整。

**步骤**：
1. 在 152 上查服务与日志：
   ```bash
   echo 'Sunrise@801' | sudo -S systemctl status beegfs-meta --no-pager
   echo 'Sunrise@801' | sudo -S journalctl -u beegfs-meta -n 100 --no-pager
   ```
2. 检查 152 的 meta 存储目录与挂载：`df -h /mnt/beegfs-meta`；确认 `beegfs-meta.conf` 的 `sysMgmtdHost=10.20.1.157`、`storeMetaDirectory` 正常、目录权限正确。
3. 检查 152 → mgmtd(157:8008) 网络连通：`ping -c3 10.20.1.157`、`nc -zv 10.20.1.157 8008`。
4. 若服务未起或注册失效：`sudo systemctl restart beegfs-meta`，等待重注册；必要时按 service-discovery 机制重新注册。
5. 复核：
   ```bash
   sudo beegfs-ctl --listnodes --nodetype=meta
   sudo beegfs-ctl --listtargets --state --nodetype=meta
   sudo beegfs-df
   ```

**验收**：`beegfs-df` 4 个 meta target 全部在线、target 4 容量恢复 ~879GiB、状态 GOOD，无 Communication error。

---

## 3. 任务 0.2 — 修正测试脚本的 7.x `beegfs-ctl` 采集命令

**现象**：`bench-full.sh`、`bench-basic.sh`、`diag.sh` 用 `--mgmtd_node=...`，7.x 报 `Invalid argument: --mgmtd_node`，env 快照 nodes/targets/stripe 采集全部失败。

**根因**：7.x `beegfs-ctl` 从 `/etc/beegfs/beegfs-client.conf`（`sysMgmtdHost`）自动定位 mgmtd，不接受 `--mgmtd_node`。

**改法**：去掉所有 `--mgmtd_node="${BEEGFS_MGMTD_HOST}"`，其余参数保留。具体位置：
- `tests/bench-full.sh:92-97`（listnodes meta/storage、listtargets、getentryinfo 四处）
- `tests/bench-basic.sh:57-60`（listnodes meta/storage、listtargets 三处）
- `doc/perf-analysis/diag.sh`：确认第 72-83 行的 `--listnodes` / `--listtargets --state` / `--listmirrorgroups` 不带 `--mgmtd_node`（当前看似已不带，逐条核对）

**建议同时补采**（env 快照增强，便于后续对比）：
```bash
sudo beegfs-ctl --listnodes --nodetype=meta
sudo beegfs-ctl --listnodes --nodetype=storage
sudo beegfs-ctl --listtargets --state --nodetype=storage
sudo beegfs-ctl --listmirrorgroups --nodetype=meta
sudo beegfs-ctl --listmirrorgroups --nodetype=storage
sudo beegfs-ctl --getentryinfo /mnt/beegfs
```

**验收**：手动跑上述命令无 `Invalid argument`；重跑后 env-snapshot.txt 拓扑段完整。

---

## 4. 任务 0.3 — 修复 `bench-full.sh` 的 IOPS 解析 bug

**现象**：`summary.md` 里所有随机测试 `IOPS_R=NA IOPS_W=NA`。

**根因**（`tests/bench-full.sh:111`）：
```bash
iopsget(){ grep -oP "$2: IOPS=\K[0-9]+" "$1" | head -1 || true; }
```
调用时传入 `READ`/`WRITE`（大写），但 fio detail 行是小写 `read: IOPS=` / `write: IOPS=`；fio summary 行只有 `bw=` 无 `IOPS=`。故大写永远匹配不到。

**改法**（二选一，推荐 A）：
- **A**：`iopsget()` 内把参数转小写再匹配 detail 行：
  ```bash
  iopsget(){ local k=$(echo "$2" | tr 'A-Z' 'a-z'); grep -oP "${k}: IOPS=\K[0-9.]+[km]?" "$1" | head -1 || true; }
  ```
  注意 fio IOPS 可能带 `k`/`M` 后缀（如 `IOPS=42.7k`），保留后缀原样记录或换算，**换算逻辑须在 summary 里标注**。
- **B**：直接解析 detail 行的 `IOPS=` 字段，不依赖大小写前缀。

**同时**：核对 `bwget()`（`bench-full.sh:102-110`）对 summary 行 `READ: bw=` / `WRITE: bw=` 的大写匹配仍正确（bw 走 summary 大写行，勿改错）。

**验收**：重跑基线后 summary 随机项 IOPS_R/IOPS_W 非 NA；抽查 2-3 项与原始 fio 的 `read: IOPS=` / `write: IOPS=` 行对账一致。

---

## 5. 任务 0.4 — 修复 `bench-basic.sh` 递归 bug

**现象/根因**（`tests/bench-basic.sh:70-76`）：`drop_all_caches()` 函数体内第 71 行调用自身 `drop_all_caches`，无限递归直至栈溢出（正确实现应内联 drop 逻辑，参照 `bench-full.sh:122-133`）。

**改法**：把第 71 行替换为客户端 drop 逻辑：
```bash
drop_all_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    for ip in ${SLAVE_SERVERS[*]}; do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${ip}" \
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1" 2>/dev/null || true
    done
}
```

**验收**：`bash tests/bench-basic.sh smoke` 能正常跑完不栈溢出（仅需确认脚本可运行，不作为基线数据）。

---

## 6. 任务 0.5 — 逐节点核对系统调优生效

对 157/150/151/152 四节点分别核对 `tune-servers.sh` 是否真的生效，逐项 cat 实测值：
```bash
cat /sys/kernel/mm/transparent_hugepage/enabled          # 期望 [always]
cat /proc/sys/vm/dirty_background_ratio                    # 期望 5
cat /proc/sys/vm/dirty_ratio                               # 期望 10
cat /sys/block/nvme2n1/queue/read_ahead_kb                 # 期望 4096
cat /sys/block/nvme2n1/queue/scheduler                     # NVMe 期望 [none]
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # 期望 performance
```
未生效则在该节点执行 `sudo bash /tmp/tune-servers.sh`（先 `scp` 过去）后复核。

**验收**：4 节点全部一致，输出写入 `results/<新基线目录>/evidence/tune-verify-<host>.txt`。

---

## 7. 任务 0.6 — 采集 157 共部署证据

在跑冷态基线的 **seqwrite（单流）** 和 **randwrite（128 并发）** 期间，于 157 上同步采集资源争抢证据（判断 mgmtd+meta+helperd+client 是否与 fio 争 CPU/网络/内存）：
```bash
# fio 跑时并行采集 ~30s
mpstat -P ALL 2 15 > evidence/157-mpstat-<test>.txt
nethogs -t -c 30 eno12399 > evidence/157-nethogs-<test>.txt 2>/dev/null   # 或 iftop/sar
numastat -m > evidence/157-numastat-<test>.txt
top -bn3 -o %CPU | head -40 > evidence/157-top-<test>.txt
```
（若 `nethogs`/`mpstat` 未装：`sudo apt-get install -y sysstat nethogs`，或用 `sar -n DEV`/`/proc/net/dev` 前后差值替代。）

**验收**：产出 seqwrite、randwrite 两组证据文件；在交付说明里给出结论：157 上 BeeGFS 服务进程 CPU/网络占用是否显著（作为阶段 5 是否拆独立 client 的依据），**本任务只采集与判断，不做拆分**。

---

## 8. 任务 0.7 — 定位 seqread R1≠R2 根因并修复口径

**现象**：不限速冷态 seqread R1=565 vs R2=1521（+170%），而多流读 R1/R2 仅 +2%。

**步骤**：
1. 独立复现：连续跑 2 次单流 seqread（每次前都执行 `drop_all_caches` 清客户端+全部 storage 端缓存），对比 R1/R2。
2. 加 **warmup-then-drop** 流程验证：先预跑一次 seqread（预热），再 `drop_all_caches`，再正式测 —— 观察偏差是否收敛，以区分「冷启动抖动」与「服务端 page cache 残留」。
3. 若怀疑服务端 XFS 缓存未清：在 3 个 slave 上确认 `drop_caches` 已执行、`sync` 完成；必要时 prep 写入后加显式 `sync` + 等待。
4. 记录根因（连接冷启动 / NUMA / 服务端缓存残留 / mgmtd 拓扑首拉）到交付说明。

**验收**：单流 seqread R1/R2 偏差 <10%，根因文档化；如需改脚本口径（如 seq 项也跑多轮），一并提交但**先说明再改**。

---

## 9. 任务 0.8 — 重跑健康态冷态基线

**前置**：0.1–0.7 全部完成且验收通过。

**执行**（用 `tests/bench-full.sh`，遵循 `TESTING-GUIDE.md` 测前检查 + `LONG-RUNNING-TEST-SKILL.md` 监控）：
1. 测前检查：全服务 active、`beegfs-ctl --listtargets --state` 全 GOOD、无 fio 残留、磁盘空间足（layout 需 128G+）。
2. 清数据 + 清客户端与全部 storage 端缓存。
3. **不限速 冷态 1 轮** → 结果目录。
4. 清数据清缓存。
5. **限速 冷态 1 轮**（`bash limit-bandwidth.sh apply`；测后 `remove`；每次唤醒确认 `tc qdisc show dev eno12409 | grep tbf` 限速仍在）。
6. 全程按长测 skill 定时唤醒检查健康，异常则 abort 排查。

**结果落盘**：`results/<日期>-beegfs-cold-baseline-v2/`（建议命名 `20260707-...`），保留每轮 summary + 原始 fio + env 快照 + commands.sh + status-after，外加本任务的 `evidence/` 目录。

**验收**：4 meta + 6 storage 全 GOOD；env 拓扑采集完整；summary IOPS 非 NA；随机项三轮偏差 <1%；seqread R1/R2 偏差 <10%。

---

## 10. 交付要求

1. 所有脚本改动（0.2/0.3/0.4，以及可能的 0.7 口径调整）**提交前先向用户展示 diff 说明，经确认再 commit/push**（`skills/doc-publish-rule.md`）。
2. 数据结论必须对账原始 fio：带宽取 summary 的 `READ: bw=` / `WRITE: bw=`；IOPS 取 detail 的小写 `read: IOPS=` / `write: IOPS=`；写延迟分析记 `slat`/`clat`。
3. 随机读/写若超千兆线速（~124 MB/s）必标口径（缓存命中 / 后端 / 饱和延迟）。
4. 完成后产出一份**交付说明**（可写入新基线目录的 `README.md`），列：各任务完成状态、meta 修复过程、脚本改动清单、157 共部署结论、seqread 根因、新基线关键数值表、与 2026-07-03 旧基线的对比。
5. 交付说明回传规划 agent，用于据此推进阶段 1。

---

## 11. 完成检查清单（GLM 自检）

- [ ] 0.1 meta target 4 恢复 GOOD、容量正常
- [ ] 0.2 三个脚本去掉 `--mgmtd_node`，env 拓扑采集无 Invalid argument
- [ ] 0.3 `iopsget()` 修复，summary IOPS 非 NA 且对账一致
- [ ] 0.4 `bench-basic.sh` 递归 bug 修复，脚本可跑
- [ ] 0.5 4 节点 tune 生效核对，evidence 留档
- [ ] 0.6 157 共部署证据采集（seqwrite + randwrite），给出结论
- [ ] 0.7 seqread R1/R2 偏差 <10%，根因文档化
- [ ] 0.8 健康态冷态基线重跑（不限速 + 限速各 1 轮），全部验收通过
- [ ] 脚本改动经用户确认后提交
- [ ] 交付说明产出并回传
