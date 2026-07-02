# motd 淹没 stdout 复现与解决

## 问题描述

通过多级 SSH 跳板远程执行命令时，服务器的 `/etc/motd` 登录提示信息会混杂在命令的标准输出（stdout）中，导致无法判断实际命令的执行结果。

例如 `ssh_to_client "echo hello"` 的输出：

```
Welcome to Ubuntu 22.04.5 LTS (GNU/Linux 5.15.0-170-generic x86_64)
...
*** System restart required ***
hello
```

本应得到 `hello`，但前面有 30+ 行 motd。脚本如果用 `grep hello` 是可以的，但从人眼阅读或 `$(...)` 捕获结果时，motd 会严重干扰。

## 复现条件

| 条件 | 原因 |
|------|------|
| sshpass + SSH | sshpass 分配 PTY，触发 motd 打印 |
| 多级跳板 | 每层 SSH 都会打印 motd，嵌套后 stdout 和 stderr 混杂 |
| 被控服务器有 motd | Ubuntu 默认启用了动态 motd（`/etc/update-motd.d/`） |
| SSH 非 BatchMode | `-T` 参数只能抑制部分输出，motd 仍会出现在 stdout |

最小复现命令：

```bash
source config.sh && ssh_to_client "echo HELLO_WORLD"
```

输出中 `HELLO_WORLD` 被淹没在 motd 中，无法直接通过 `$(...)` 捕获。

## 根因分析

sshpass 连接的 SSH 会话：
1. 第一层：`sshpass ssh root@HK_ECS` → HK ECS 的 motd 出现在 stderr
2. 第二层：`sshpass ssh -T sunrise@CLIENT` → 泰国 client 的 motd 混杂

虽然用了 `-T`（禁用 PTY 分配），但 sshpass 自身的工作机制导致第一层的 motd 被打印。

## 解决方案

### 方案 A：丢弃 stderr（已采用）

将 `_run` 函数的 stderr 重定向到 `/dev/null`：

```bash
_run() {
    local ip=$1; shift
    if [ "$ip" = "CLIENT_SERVER" ]; then
        ssh_to_client "$@" 2>/dev/null
    else
        ssh_to_slave "$ip" "$@" 2>/dev/null
    fi
}
```

**代价**：真正的错误信息（如 `Permission denied`）也会被丢弃。需要在关键检查点使用 `_run_verbose`（保留 stderr）。

### 方案 B：`test -t 0` 包装

在远程命令前加 `test -t 0 && ...` 跳过 motd 相关的 shell 初始化：

```bash
ssh_to_client "test -t 0 && echo HELLO || echo HELLO"
```

### 方案 C：禁用远程 motd

在被控服务器上通过 `touch ~/.hushlogin` 抑制 MOTD 显示：

```bash
ssh_to_client "touch ~/.hushlogin"
# 对 slave 同理
```

但会影响到人工 SSH 登录时的信息展示。

## 当前工程采用的方案

`deploy-beegfs.sh` 和 `prepare-all-servers.sh` 中的 `_run` 函数使用方案 A（丢弃 stderr），同时提供 `_run_verbose` 函数用于调试时获取完整输出。

所有脚本的远程调用已改为：

- 常规命令：`_run <ip> "command"`（stderr 丢弃，只取 stdout）
- 检查/调试：直接用手动 SSH 命令或脚本中的特定 echo 输出
- client 157 上的 motd 已通过 `touch ~/.hushlogin` 抑制
- slave 的 motd 因是交互式登录也会打印，但通过区分 stdout/stderr 后不影响关键判断

## 测试验证

执行以下命令验证 motd 是否已被抑制：

```bash
source config.sh
# 应该只输出 "OK"，没有 motd
ssh_to_client "echo OK" 2>/dev/null
# 或用新版 _run（deploy-beegfs.sh 中使用）
# 如果仍有 motd，说明问题未完全解决
```
