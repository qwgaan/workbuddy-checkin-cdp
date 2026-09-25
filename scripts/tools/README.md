# asar 分析工具（只读）

用于在客户端升级后**重新定位**签到链路（通道名、处理器、preload 暴露名）。
全部为只读脚本，**不修改客户端任何文件**。

## 目标文件

`<WorkBuddy 安装目录>\resources\app.asar`

路径按以下优先级自动解析（无需改代码）：

1. 命令行 `--asar <路径>`
2. 环境变量 `WB_ASAR`
3. 常见安装位置：`%LOCALAPPDATA%\Programs\WorkBuddy\resources\app.asar` 等

解析不到会直接报错并提示，不会静默失败。

## 运行环境

Node 22+（仅用内置模块，零第三方依赖）。

> ⚠️ Git Bash 会把以 `/` 开头的参数当成 Windows 路径改写，运行前先 `export MSYS_NO_PATHCONV=1`。

## 1. 按关键词反查命中文件

```bash
export MSYS_NO_PATHCONV=1
node scripts/tools/asar_scan.js "claimDailyCheckin" "CLAIM_DAILY_CHECKIN"
```

输出每个关键词命中的 asar 内文件路径（含大小与绝对偏移）。

## 2. 列出目录下文件

```bash
node scripts/tools/asar_list.js "/main/"
```

## 3. 提取关键词上下文

```bash
# 用法: asar_extract.js <asar内路径> <关键词> [上下文半径] [最多命中数]
node scripts/tools/asar_extract.js "/main/contract.js" "CLAIM_DAILY_CHECKIN" 700 3
```

## 4. 列出 preload 暴露到渲染进程的全局名

```bash
node scripts/tools/asar_exposed.js "/preload/index.js"
```

> 寻找入口时优先看是否有 `__wbInvoke`；这是通用 RPC 桥，业务通道复用 `wb:invoke`。
