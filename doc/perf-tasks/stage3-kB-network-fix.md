# 口径B 切网问题与解决记录

> 日期：2026-07-15
> 关联：stage3-aligned-retest-task-book.md §2.3 口径B切换

## 问题现象

口径B（千兆限速 TCP）切换后，BeeGFS client 挂载成功但写入完全挂起：
- `echo hello > /mnt/beegfs/test.txt` 超时不返回
- `ls /mnt/beegfs/` 也超时
- fio 哨兵运行 10+ 分钟不完成（1G 写入正常应 ~20s）
- 内核模块 stuck 导致 `umount /mnt/beegfs` 也挂起

## 根因（3 层）

### 1. connInterfacesFile 设置为空（主因）

`deploy-beegfs.sh` 不设置 `connInterfacesFile` 参数，conf 文件中该值为空：
```
connInterfacesFile            =
```
虽然 `/etc/beegfs/connInterfacesFile.conf` 文件存在且内容正确（eno12409），但 conf 不指向它，BeeGFS 用 auto-select 选择了错误接口（可能选了 100GbE RDMA 接口但 connUseRDMA=false 导致 TCP 连不上）。

**修复**：在所有节点的所有 .conf 文件末尾 append：
```
connInterfacesFile = /etc/beegfs/connInterfacesFile.conf
```

### 2. sysMgmtdHost 在错误网段

`deploy-beegfs.sh` 设置 `sysMgmtdHost = 10.20.1.157`（管理网 eno12399）。当 `connInterfacesFile = eno12409` 时，BeeGFS 强制只走 eno12409，但 mgmtd 的 IP 10.20.1.157 不在 eno12409 网段（10.114.1.0/24），client 连不上 mgmtd → mount 失败。

**修复**：在所有 .conf 文件中改 `sysMgmtdHost = 10.114.1.157`（eno12409 网段 IP）。

### 3. rootcause-enter-kB.sh 的 sed 未匹配注释行

原脚本用 `sed -i 's/^connUseRDMA.*/.../'` 替换，但 conf 中 `connUseRDMA` 是注释行（`# connUseRDMA = true`），sed 不匹配。

**修复**：用 `echo 'connUseRDMA = false' | sudo tee -a` append 到 conf 末尾（BeeGFS 最后一次 uncommented 设置生效）。

### 4. fio stuck 导致内核模块阻塞

fio 哨兵在数据面不通时 stuck 在 D 状态（uninterruptible sleep），`timeout` 无法 kill，`umount` 也挂起。

**修复**：`sudo kill -9 $(pgrep -x fio)` → `sudo umount -l /mnt/beegfs`（lazy umount）→ 重启 client。

## 正确的口径B切换流程（总结）

1. **conf 修改**（4 节点，所有 .conf 文件）：
   - append `connUseRDMA = false`
   - append `connInterfacesFile = /etc/beegfs/connInterfacesFile.conf`
   - 改 `sysMgmtdHost = 10.114.1.157`（sed 替换）
2. **connInterfacesFile.conf 内容**：`eno12409`
3. **tc tbf**（4 节点）：`tc qdisc replace dev eno12409 root tbf rate 1gbit burst 32kbit latency 400ms`
4. **清重启**全部 BeeGFS 服务（stop all → start mgmtd → meta → storage → helperd → client）
5. **三重验证**：beegfs-net (TCP 10.114.1.x) + tc qdisc show (tbf 1Gbit) + fio sentinel (bw≤118)

## 测后恢复

- `tc qdisc del dev eno12409 root`（4 节点）
- conf 恢复：connUseRDMA=true + connInterfacesFile 恢复 enp139s0f0np0/f1np1 + sysMgmtdHost 恢复 10.20.1.157
- 清重启全部服务 + RDMA 哨兵复查（clat_min<250µs）
