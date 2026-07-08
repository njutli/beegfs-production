# 任务书 · 阶段1-前置②  479 低态根因确认 + 锁定 RDMA 接口

> 执行方：GLM（新会话 / 新服务商，**无历史上下文**，本任务书自包含）
> 派发方：规划 agent
> 依据：`results/20260707-restart-repro/README.md`（33 次测量证明 479 不可复现）+ 规划 agent 的日志根因分析（本文档第三节）
> 日期：2026-07-08
> 优先级：P0（决定 stage1 基线是否可信、可复现）

---

## 0. 背景（新会话必读）

### 0.1 项目
在一个 **4 节点 BeeGFS 7.3.2 集群**（纯测试集群，业务跑在同机独立的 WekaIO 上，与 BeeGFS 无关）上做性能调优。目标：找瓶颈、在不影响 WekaIO 业务前提下提升性能。

### 0.2 拓扑与网络（本任务核心是网络接口，务必看清）
| 节点 | 角色 |
|------|------|
| 157 (oneasia-c1-cpu-node10) | mgmtd + meta + client（同机跑 WekaIO 业务）|
| slave1/2/3 (150/151/152) | meta + 2 storage targets 各 |

**157 的三块相关网卡（`ip -o -4 addr` 实测）：**
| 网卡 | IP 网段 | 类型 | 用途 |
|------|---------|------|------|
| `enp139s0f0np0` / `enp139s0f1np1` | **10.3.2.x** | **100GbE RDMA/RoCE** | ✅ BeeGFS 数据面应走这里（与 WekaIO 物理共用同一 verbs 设备）|
| `eno12409` | **10.114.1.x** | 普通 TCP（千兆级）| ❌ 不是给 BeeGFS 数据面的（曾用于 1Gbps 限速对比实验）|
| `eno12399` | 10.20.1.x | 普通 TCP（管理网）| 管理/SSH |

**每个 storage 节点在 mgmtd 注册了 6 个接口**（`beegfs-ctl --listnodes --nodetype=storage --details` 实测）：
```
Interfaces: enp139s0f1np1(RDMA) enp139s0f0np0(RDMA) eno12409(TCP) eno12399(TCP) enp139s0f1np1(TCP) enp139s0f0np0(TCP)
```
即：同一批网卡既注册了 RDMA 也注册了 TCP，client 建连时会在这些接口里挑一个。

### 0.3 问题历史
| 时刻 | 事件 | seqwrite | clat_min |
|------|------|:---:|:---:|
| 07-06 18:44 | v2 基线（重启前）| 835 | 200µs |
| 07-06 20:23 | BeeGFS 服务重启（伴随一次配置改动，见第三节）| - | - |
| 07-07 11:47~14:05 | 多次测量 | 466/479/508 | ~400µs（**低态**）|
| 07-07 16:23 起 | 重启后 33 次测量（16h 监控 + 8 次独立重启）| **887-944** | ~200µs（**高态**）|

复测报告（`results/20260707-restart-repro/`）已用 33 次测量证明：**479 低态在之后从未复现，高态稳定 ~900**。但**没抓到 479 态的快照**，当时无法解释 479 成因。本任务补上这个根因。

---

## 1. 访问方式

项目目录在 157：`/home/sunrise/beegfs-production`
```bash
sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -p 19891 sunrise@203.156.3.194 "<command>"
# 157 → slave: 内层再 ssh sunrise@10.20.1.150/151/152
# sudo: echo 'Sunrise@801' | sudo -S <cmd>
```
详见 `skills/beegfs-node-conventions.md`、`skills/TESTING-GUIDE.md`、`skills/beegfs-baseline-config.md`。

---

## 2. 安全红线
BeeGFS 服务可自由重启（纯测试集群）。但：
| 可做 | 禁止 |
|------|------|
| ✅ 改 BeeGFS `.conf` 应用层参数（含 connInterfacesFile）| ❌ 动网卡/驱动全局参数（MTU、mlxconfig、queue、中断亲和、PFC）|
| ✅ 重启 BeeGFS 服务、重挂 client | ❌ 动 157 内核参数 |
| ✅ 读取任何状态/日志 | ❌ 动 RoCE QoS（connRDMATypeOfService、DSCP）——与 WekaIO 共享 |

⚠️ `connInterfacesFile` 指定的是**本机对外用哪块网卡**，只影响 BeeGFS 自己选路，不改网卡本身配置——属应用层，安全。但**改前先确认指定的 RDMA 网卡就是 WekaIO 也在用的那块共用卡**（是的，enp139s0f0np0/np1），BeeGFS 走 RDMA 本就与 WekaIO 共用，属既有状态，不新增风险。

---

## 3. 规划 agent 的根因分析（请你独立复核，见第 4 节）

### 3.1 分析过程
复测报告说"479 不可复现、原因未知"。规划 agent 沿"低态可能是连接回退 TCP / 非最优 RDMA 路径"的假设，查了 **07-06 20:23 那次重启的日志**（`/var/log/beegfs-client.log.old-1`，`journalctl`）与现有高态快照的 `beegfs-net`，得到：

**证据 1 — 07-06 20:23 重启伴随一次配置改动**（`journalctl` 实录）：
```
20:23:26  sed -i 's|^connInterfacesFile.*=.*|connInterfacesFile            =|'   # 把 connInterfacesFile 清空
          （对 client/meta/mgmtd/helperd 四个 .conf）
20:23:26  rm -f /etc/beegfs/connInf.conf                                          # 删除接口指定文件
20:23:28  systemctl restart beegfs-client ...
```

**证据 2 — 低态起点日志显示 client 连到了 TCP 网段**（`beegfs-client.log.old-1`，20:23:28）：
```
Usable NICs: enp139s0f1np1(RDMA) enp139s0f0np0(RDMA) ... eno12409(TCP) ...
Connected: beegfs-storage@10.114.1.150:8003 (protocol: TCP)   ← 走 eno12409 (10.114.1.x) TCP！
Connected: beegfs-storage@10.114.1.151:8003 (protocol: TCP)
Connected: beegfs-storage@10.114.1.152:8003 (protocol: TCP)
```

**证据 3 — 高态快照 client 连的是 RDMA 网段**（`multi-restart/restart{1,4,8}-snapshot.txt` 与 `current-state/hourly-h{1,16}-snapshot.txt`，33 次一致）：
```
storage_nodes → beegfs-slave1 [ID: 101]
   Connections: RDMA: 2 (10.3.2.6:8003);   ← 走 enp139s0f1np1 (10.3.2.x) RDMA
```

### 3.2 结论
- **479 低态 = BeeGFS 数据面走了 `10.114.1.x` 的普通 TCP 网卡（eno12409），没走 100GbE RDMA。** 这解释了 clat_min 200→400µs 翻倍、带宽 900→479 腰斩。
- **触发原因**：07-06 20:23 那次把 `connInterfacesFile` 清空 + 删 `connInf.conf`，使 client 变成**自动选接口**；那一次恰好选中了 TCP 网段。
- **为什么之后 33 次又都走 RDMA**：配置至今仍是空的（`connInterfacesFile=` 空、`connInf.conf` 不存在，已实测），但 33 次重启全部自动选中了 RDMA(10.3.2.6)。**即：空配置下接口选择不确定——大概率选 RDMA(900)，小概率落 TCP(479)。**
- **因此："479 不可复现"应修正为"479 是自动选接口落到 TCP 的小概率事件，可解释、可预防，非玄学偶发"。900 目前是"恰好选中 RDMA"，不是"已锁定保证"。**

### 3.3 建议动作
**不去复现 479，而是显式锁定 RDMA 接口**，消除不确定性：在 client（及 meta）用 `connInterfacesFile` 只列 RDMA 网卡（`enp139s0f0np0`、`enp139s0f1np1`），使数据面永远走 10.3.2.x RDMA。这样 900 成为**可保证的稳定基线**，479 态被永久消除。

---

## 4. 任务 A：独立复核根因（先做，不改配置）

请你**独立验证** 3.1 的证据链，确认或反驳 3.2 的结论：

1. 读 07-06 20:23 重启的日志，确认 client 当时连的是 `10.114.1.x TCP` 还是 `10.3.2.x RDMA`：
   ```bash
   sudo grep -E "Connected: beegfs-storage|Usable NICs" /var/log/beegfs-client.log.old-1
   sudo journalctl --since "2026-07-06 20:20" --until "2026-07-06 20:30" | grep -iE "connInterfacesFile|connInf"
   ```
2. 确认当前配置状态：`grep connInterfacesFile /etc/beegfs/beegfs-client.conf /etc/beegfs/beegfs-meta.conf`（应为空）；`ls /etc/beegfs/connInf.conf`（应不存在）。
3. 确认当前 client 走 RDMA：`beegfs-net | grep -A1 "ID: 101"`（应为 `RDMA: 2 (10.3.2.6:8003)`）。
4. 核对网卡 IP 归属：`ip -o -4 addr | grep -E "10.3.2|10.114.1"`（确认 10.114.1.x=eno12409 TCP，10.3.2.x=enp139s0f1np1 RDMA）。
5. **给出你的判断**：是否同意"479=TCP fallback、900=RDMA、空配置下选路不确定"？若不同意，给出你的证据与替代解释。

> ⚠️ 若你发现规划 agent 的分析有误（例如低态其实也走 RDMA、或触发原因另有其因），**以你的实测为准，停下来回报，不要继续任务 B**。

---

## 5. 任务 B：锁定 RDMA 接口并验证（复核通过后再做）

### 5.1 备份与改配置
1. 备份：`cp /etc/beegfs/beegfs-client.conf{,.bak-$(date +%s)}`（meta 同理）。
2. 创建接口文件（**只列 RDMA 网卡**，157 上）：
   ```
   /etc/beegfs/connInterfacesFile.conf 内容：
   enp139s0f0np0
   enp139s0f1np1
   ```
   > 注意：`connInterfacesFile` 列的是**本机（157）对外网卡名**，不是 IP。client 用它选出口网卡，从而只走 RDMA 网段连 storage。若 meta/storage 侧也需锁定，同理在各 slave 上建同名文件列其 RDMA 网卡（先确认 slave 上 RDMA 网卡名，可能同为 enp139s0f0np0/np1）。
3. 在 client.conf（及 meta.conf）设：`connInterfacesFile = /etc/beegfs/connInterfacesFile.conf`
4. 重启 client（及相关服务），等 mount 就绪 + 所有 target Online/Good。

### 5.2 验证（关键）
1. `beegfs-net | grep -A1 "ID: 10[123]"` → 3 个 storage 必须全是 `RDMA: N (10.3.2.x:8003)`，**不得出现任何 10.114.1.x 或 TCP**。
2. `beegfs-client.log` 里 `Connected: beegfs-storage@...` 必须是 10.3.2.x RDMA。
3. **反复重启 ≥5 次**，每次都验证走 RDMA（锁定后应 100% 走 RDMA，不再有落 TCP 的可能）。
4. 每次重启后测 seqwrite（口径见 5.3），确认稳定 ~900、clat_min ~200µs。

### 5.3 测试口径（固定）
```bash
D=/mnt/beegfs/lock_test; mkdir -p $D
# 测前 drop caches: 客户端 157 + 3 slave 全部 sync; echo 3 > /proc/sys/vm/drop_caches
fio --name=seqwrite --directory=$D --rw=write --bs=256K --size=4G --direct=1 --end_fsync=1 --group_reporting
rm -rf $D
```
记录 `WRITE: bw=`、`write: IOPS=`、`clat (usec): min/avg`。

### 5.4 附加确认（不影响 WekaIO）
锁定 RDMA 接口前后，各采一次数据面 RDMA 速率快照，确认 WekaIO 业务不受影响（BeeGFS 本就与其共用 RDMA 卡，锁定接口不新增网卡层改动）：
```bash
C=/sys/class/infiniband/mlx5_1/ports/1/counters
r1=$(cat $C/port_xmit_data); sleep 5; r2=$(cat $C/port_xmit_data)
echo "RDMA xmit: $(( (r2-r1)*4/5/1024/1024 )) MiB/s"
```

---

## 6. 交付物（落 `results/20260708-lock-rdma-iface/`）

1. `README.md`，含：
   - **任务 A 复核结论**：是否同意根因（479=TCP fallback / 900=RDMA / 空配置选路不确定），附你的实测证据。
   - 07-06 20:23 低态日志片段（Connected TCP 10.114.1.x）。
   - 锁定接口前后对比表：`beegfs-net` 连接类型、seqwrite bw/clat_min。
   - ≥5 次重启后走 RDMA 的一致性验证。
2. 改动的配置文件 diff + 备份路径。
3. **给规划 agent 的结论**：锁定后 900 是否成为稳定可保证基线？是否建议把 `connInterfacesFile 锁 RDMA` 固化进基线配置（`skills/beegfs-baseline-config.md`）？stage1 可否在 900 基线上推进？

---

## 7. 验收标准
- [ ] 任务 A：独立复核根因，明确同意/反驳并附证据
- [ ] 任务 B：connInterfacesFile 锁定 RDMA 网卡，client→storage 100% 走 10.3.2.x RDMA
- [ ] ≥5 次重启后连接类型与 seqwrite 均稳定（走 RDMA、~900、clat_min ~200µs）
- [ ] 确认锁定不影响 WekaIO（RDMA 速率快照对照）
- [ ] 全部 seqwrite 对账原始 fio；配置改动有备份可回滚

## 8. 注意事项
- 改配置前必须备份，保证可一键回滚。
- 若锁定后出现 mount 失败/target 降级，先回滚配置、采集现场、回报规划 agent。
- 本任务只改 `connInterfacesFile` 一项（单变量），不要同时改其他参数。
- 若任务 A 复核推翻了根因，立即停止并回报，不要盲目锁接口。
