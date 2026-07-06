# 长时间测试监控 Skill (BeeGFS 适配版)

> 目的：指导 AI 助手在长时间后台测试场景下，以"定时唤醒 + 状态驱动"的方式自主监控和推进任务。
> 创建：2026-07-03 | 适配自 tikv-node 原版，替换 Ceph 部分为 BeeGFS

---

## 一、核心机制

### 1.1 原理

AI 助手无法持续监听后台进程，只能在 bash 命令返回时被"唤醒"。
利用这一特性，用 `sleep N` 作为定时器：

1. 启动后台测试（`setsid bash bench-full.sh cold-r1 cold &`）
2. 调用 `sleep N`（阻塞，N 秒后返回）
3. sleep 返回 → AI 被唤醒 → SSH 到服务器收集状态
4. 分析当前进展，决定下一步：
   - 测试还在跑 → 再 `sleep N`
   - 测试跑完了 → 启动 todo list 下一项
   - 集群异常 → 排查处理
5. 循环直到 todo list 全部完成

### 1.2 与传统脚本自动化的区别

| | 传统脚本 | 本 Skill |
|--|---------|---------|
| 流程控制 | 写死在脚本里 | AI 根据实际状态动态决定 |
| 异常处理 | 脚本 try/catch，容易遗漏 | AI 分析处理，灵活应对 |
| 中间状态 | 脚本不关心，只看最终结果 | 每次唤醒都检查集群健康 |
| 用户插话 | 无法响应 | 用户 Ctrl+C 中断 sleep，消息立刻到达 |
| 出错恢复 | 脚本退出，从头重来 | AI 从当前状态继续，不返工 |

### 1.3 关键原则

- **脚本只负责 sleep，不负责收集信息** — 信息收集由 AI 被唤醒后自己做
- **每次唤醒都重新思考** — 不假设上次的状态还成立，从头检查
- **用户可随时插话** — Ctrl+C 中断当前 sleep，AI 立即响应
- **每次 sleep 前打印系统时间** — 便于追踪唤醒周期，排查时间线

---

## 二、Sleep 间隔规则

### 2.1 时段划分

| 时段 | sleep 间隔 | 理由 |
|------|-----------|------|
| 09:00 - 21:00（工作时间） | 600 秒（10 分钟） | 用户可能随时交互，较短间隔便于响应 |
| 21:00 - 次日 09:00（非工作时间） | 1800 秒（30 分钟） | 无人交互，减少不必要的唤醒 |

### 2.2 实现方式

AI 在调用 sleep 前先获取当前时间，根据时段选择间隔。

**无论哪种方式，sleep 前必须打印当前系统时间：**

```bash
date; sleep 600
```

---

## 三、每次唤醒的检查清单

### 3.1 BeeGFS 集群健康检查

```bash
# 服务状态
for ip in 10.20.1.157 10.20.1.150 10.20.1.151 10.20.1.152; do
    ssh sunrise@$ip "for svc in beegfs-mgmtd beegfs-meta beegfs-storage beegfs-helperd beegfs-client; do
        echo -n \"\$svc: \"; sudo systemctl is-active \$svc 2>/dev/null || echo '-'
    done"
done

# Storage targets 状态 (全部应为 Good)
sudo beegfs-ctl --listtargets --state

# 节点在线
sudo beegfs-ctl --listnodes --nodetype=meta
sudo beegfs-ctl --listnodes --nodetype=storage

# 磁盘使用
sudo beegfs-df
```

### 3.2 测试进程检查

```bash
# fio 进程数量 (0 = 测试结束)
pgrep -x fio | wc -l

# 测试进度 (summary.md 最后一行)
tail -3 results/full-cold-limit-r1-*/summary.md
```

### 3.3 分析逻辑

| 状态 | 判断 | 行动 |
|------|------|------|
| fio 进程在 + 集群 health OK | 正常运行 | 继续 sleep |
| fio 进程在 + 集群 health 非 OK | 异常 | 检查 target/nodes，判断是否影响测试 |
| fio 进程消失 + summary 有 "DONE" | 测试完成 | 更新 todo，启动下一项 |
| fio 进程消失 + summary 无 "DONE" | 异常退出 | 检查日志排查原因，修复后重启 |
| mount 丢失 | 集群异常 | systemctl restart beegfs-client，检查日志 |

---

## 四、Todo List 管理

### 4.1 实时更新

每次测试完成或状态变化时，立即更新 todo list：
- 测试完成 → 标记 completed
- 发现新问题 → 新增 todo 项
- 优先级变化 → 调整 priority

### 4.2 串行执行

长时间测试任务通常有依赖关系，必须串行执行：
- 同一时间只有一个测试在跑
- 当前测试完成且数据可靠后，才启动下一项
- 如果数据不可靠（两轮差异大），优先排查重测

### 4.3 优先级规则

- 集群健康修复 > 基线数据验证 > 新测试项
- 验证性测试（第二轮）优先于探索性测试（新参数对照）

---

## 五、清空测试数据和缓存的标准化操作

两轮测试之间必须执行：

```bash
# 1. 删除测试文件
rm -rf /mnt/beegfs/test_dir /mnt/beegfs/seq_dir

# 2. 清客户端缓存
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

# 3. 清全部 storage server 缓存
for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    ssh sunrise@$ip "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null"
done
```

---

## 六、BeeGFS 测试特有注意事项

1. **mgmtd deactivating 卡死**：`systemctl restart beegfs-mgmtd` 偶尔卡在 deactivating。先 `systemctl cancel <job_id>`，再 `systemctl start beegfs-mgmtd`。
2. **client 重启耗时长**：内核模块需要重编译，可能需要 60-120 秒，不要误判为卡死。
3. **bandwidth limit 状态**：每次唤醒检查 `tc qdisc show dev eno12409 | grep tbf` 确认限速还在。
4. **connInterfacesFile 状态**：检查该配置未被机房重启或其他因素清空。

---

## 七、完整工作流示例

```
1. 用户交代任务 + todo list
2. AI 启动第一个测试（setsid 后台）
3. AI 调用 sleep 600（工作时间）
4. sleep 返回，AI 被唤醒
5. AI SSH 检查：
   a. pgrep fio | wc -l                    → 测试进程数
   b. tail -5 results/*/summary.md         → 测试进度
   c. beegfs-ctl --listtargets --state     → 集群健康
6. 分析：测试还在跑，health OK → sleep 600
7. 重复 5-6 直到测试完成
8. 测试完成 → 更新 todo → 清数据清缓存 → 启动下一项 → sleep 600
9. 用户 Ctrl+C 插话 → AI 响应 → 继续监控
10. 所有 todo 完成 → 下载结果 → 汇总报告
```

---

## 八、适用场景

- BeeGFS 性能基线测试（冷态/暖态，多轮验证，限速/不限速对比）
- 任何需要在远端服务器上长时间运行、需要周期性检查的后台任务
- 需要根据中间结果决定下一步的测试流程
