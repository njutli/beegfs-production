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

本应得到 `hello`，但前面有 30+ 行 motd。脚本如果用 `grep hello` 是可以的，但从人眼阅读或自动分析时，motd 会严重干扰。

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

输出中 `HELLO_WORLD` 被淹没在 motd 中。

## 根因分析

sshpass 连接的 SSH 会话：
1. 第一层：`sshpass ssh root@HK_ECS` → HK ECS 的 motd 出现在 stderr
2. 第二层：`sshpass ssh -T sunrise@CLIENT` → 泰国 client 的 motd 混杂

虽然用了 `-T`（禁用 PTY 分配），但 sshpass 自身的工作机制导致第一层的 motd 被打印。

## 当前方案

不丢弃 stderr，保留完整输出。脚本（`_run` 函数）和 AI 在分析结果时自动识别并忽略 motd 内容，只关注实际命令的输出来判断成功或失败。这样既避免了静默错误，也能获取到真实的命令结果。

## 判断规则

执行远程命令时，按以下方式提取有效结果：

1. motd 固定内容特征：
   - `Welcome to Ubuntu ...`
   - `* Documentation: ...`
   - `System information as of ...`
   - `System load: ...`
   - `*** System restart required ***`
   - 以 `*` 开头的行
   - `New release ...` / `Run 'do-release-upgrade' ...`
   - `Expanded Security Maintenance ...`
   - `bash: warning: setlocale: ...`

2. 过滤这些行后，剩余内容即为实际命令输出。
3. 命令输出中的 `active` / `inactive` / `failed` / 行数统计 / 错误信息等关键词用于判断结果。

## 测试验证

```bash
source config.sh
ssh_to_client "echo OK"
# 输出将包含 motd + "OK"，需要过滤后判断
```
