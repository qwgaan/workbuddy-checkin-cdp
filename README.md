# WorkBuddy 每日签到（CDP 路线）

> 通过调试协议在渲染进程里调用客户端自身的内部 RPC，等价于点击「Buddy加油站 → 签到领积分」。
> **不读取令牌、不解密、不伪造设备指纹** —— 鉴权全部由客户端自己完成。
>
> 纯 Node（≥22）+ PowerShell，**零第三方依赖**。

---

## 一句话原理

客户端「签到领积分」按钮的最终落点，是渲染进程里的一句：

```js
window.__wbInvoke('auth:claimDailyCheckin')
```

只要能通过 CDP 在渲染进程里执行这段 JS，就能完成签到 —— 不受窗口焦点、DPI、界面改版影响，
RDP 断开或锁屏时依然有效。

⚠️ **铁律：Electron 只能在启动时带 `--remote-debugging-port`，运行中无法附加调试器。**
所以"触发那一刻客户端是否以调试模式运行"决定了成败 —— 这是调度选型的真正约束。

---

## 目录结构

```
.
├── README.md
├── LICENSE                       # MIT
├── .gitignore
├── .gitattributes                # 统一换行符（.sh 强制 LF，否则 Git Bash 报 bad interpreter）
├── docs/
│   ├── 01-评估报告.md            # 证据链 + 三条路线可行性论证
│   ├── 02-实施方案.md            # 分阶段计划 + 验证标准
│   ├── 03-隐私与安全自查.md       # 分享前的脱敏清单（可复用）
│   ├── phase1-report.example.md  # 验证报告格式示例（脱敏）
│   └── phase1-report.md          # 本机实际报告（已 .gitignore）
├── scripts/
│   ├── checkin-via-cdp.js        # 签到主体（纯 Node，零依赖）
│   ├── run-checkin.ps1           # 定时任务入口（兜底调度，【绝不杀进程】）
│   ├── setup-automation.ps1      # 环境配置：默认带参启动 + 创建计划任务
│   ├── probe-cdp.js              # 端口与 target 探针
│   ├── restart-for-debug.ps1     # 引导：退出→带参重启→验证→写报告（⚠️ 会中断会话）
│   └── tools/                    # asar 只读分析工具（客户端升级后重新定位通道用）
├── tests/
│   ├── stub.js                   # mock CDP（拦截 fetch / WebSocket）
│   └── run-tests.sh              # 受控测试：27 项断言，不接触真实客户端
├── 签到历史.example.md            # 签到记录模板（真实记录已 .gitignore）
└── logs/README.md                # 运行期日志说明（日志本身已 .gitignore）
```

---

## 一、前置：让客户端带调试端口启动

**默认端口 19222**（避开 CentBrowser / Chrome / Edge 等常用的 9222，防止撞车）。

先确认旧进程干净（客户端有单实例锁，残留会让带参启动被忽略），再启动：

```powershell
& "<WorkBuddy 安装目录>\WorkBuddy.exe" --remote-debugging-port=19222
```

验证端口：

```bash
curl -s http://127.0.0.1:19222/json/version    # 返回含 webSocketDebuggerUrl 的 JSON 即成功
```

⚠️ **该参数只在本次启动有效**。用普通快捷方式或开机自启启动，端口就不存在。

**一劳永逸**：跑一次 `scripts/setup-automation.ps1`，把带参启动设成默认
（改 `HKCU\...\Run` 自启项 + 桌面/开始菜单两个快捷方式）。

---

## 二、日常使用

```bash
# 签到一次（幂等：已签到会直接返回「今日已签到」）
node scripts/checkin-via-cdp.js

# 只读查状态，不签到
node scripts/checkin-via-cdp.js --probe

# 指定端口 / 用环境变量
node scripts/checkin-via-cdp.js --port 19222
WB_CDP_PORT=19222 node scripts/checkin-via-cdp.js
```

计划任务入口（推荐：自动补齐前置条件，**绝不杀进程**）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run-checkin.ps1
powershell -ExecutionPolicy Bypass -File scripts/run-checkin.ps1 -DryRun     # 只探测
powershell -ExecutionPolicy Bypass -File scripts/run-checkin.ps1 -NoLaunch   # 禁止拉起客户端
```

**退出码**：`0` 成功/已签到 ｜ `2` 端口或 target 不可用 ｜ `3` 未登录 ｜ `4` 接口报错。

### 端口回退策略

- 未显式指定端口时：先试 **19222**，不通再试 **9222**（平滑迁移用），并打印提示；
- **显式** `--port` 时只认指定端口，**不**回退；
- 匹配 target 时要求 URL 含 `workbuddy`/`codebuddy`，因此即使 9222 被浏览器占用，也不会误连过去。

---

## 三、自动执行

两种调度器都**不能单独解决**"客户端没开调试端口"这件事，区别只在失败姿态：

| 触发时客户端状态 | WorkBuddy 原生自动化 | Windows 计划任务 |
|------------------|----------------------|------------------|
| 调试模式运行中 | ✅ 成功 | ✅ 成功 |
| 常规模式运行中 | ❌ 拿不到端口 | ⚠️ 要么杀进程重启（打断工作），要么放过当天 |
| 客户端未运行 | ✖️ 不会触发（调度器跑在客户端里） | ✅ 可自行带参拉起客户端 |

**推荐组合**：先跑 `setup-automation.ps1` 让前置条件恒成立，再用任一种调度器。

`run-checkin.ps1` 的决策顺序（**任何情况下都不杀进程**）：

```
探测 19222 ──通──▶ 直接签到
    │
    └─不通─┬─ 客户端在运行（常规模式）─▶ 记「需手动签到」+ 提醒，不动它
           └─ 客户端未运行 ────────────▶ 带 --remote-debugging-port 拉起 → 等端口 → 签到
```

> **为什么不杀进程重启**：自动化会话本身就是客户端的子进程，杀客户端会把自己一起杀掉。

---

## 四、失败提醒（可选）

失败时可经 WxPusher 推送到微信。**仓库内不含任何凭据**，SPT 只在运行时注入，三选一按优先级：

| 优先级 | 方式 | 用法 |
|--------|------|------|
| 1 | `--spt-file <路径>` | SPT 存仓库外的文件，如 `%USERPROFILE%\.wb-checkin\spt.txt`，任务参数里引用 |
| 2 | 环境变量 `WXPUSHER_SPT` | 进程级或用户级均可（用户级需重启客户端才生效） |

取不到就静默跳过推送，**不影响签到本身**。

```bash
# A) 文件方式（推荐）
echo <你的SPT> > "%USERPROFILE%\.wb-checkin\spt.txt"
node scripts/checkin-via-cdp.js --spt-file "%USERPROFILE%\.wb-checkin\spt.txt"

# B) 环境变量方式
setx WXPUSHER_SPT "<你的SPT>"        # 用户级
node scripts/checkin-via-cdp.js
```

当日同一类失败原因只推一次（守卫文件 `logs/push-guard.json`），避免多点补签时刷屏。`--no-push` 可临时关闭。

---

## 五、测试

不接触真实客户端、不联网、不需要登录：

```bash
bash tests/run-tests.sh
WB_NODE="/path/to/node22" bash tests/run-tests.sh    # 指定 Node
```

用 mock CDP 驱动真实脚本，覆盖 24 项断言：端口不可用、端口回退、显式端口不回退、
提醒去重、`--no-push`、`--spt-file`、签到成功（含积分字段）、今日已签到、
桥接入口缺失、未登录、探针只读、SPT 不回显不落盘、URL query 已脱敏。

---

## 六、安全与隐私

- 仅操作**自己账号**，仅调**腾讯官方接口**，不批量、不刷分。
- 调试端口仅绑 `127.0.0.1`，外网不可达。
- 脚本**完全不读取**令牌与 `X-Device-Token`，不存在落盘与外传路径。
- **凭据零入库**：SPT 只从 `--spt-file` 或环境变量读，日志与历史记录里都不回显。
- **个人标识已剥离**：target URL 里的 query（`?accountSnapshot=...`，含 uid / 昵称）在打印前就被截掉；
  报告生成时还会把调试 UUID、签到活动明细替换为 `<redacted>`。
- **以下文件已在 `.gitignore` 中排除**：`logs/`、`签到历史.md`、`docs/phase1-report.md`、`spt.txt`、`tests/_sandbox/`。
- ⚠️ **端口常开的代价（知情项）**：本机任意进程都能通过 CDP 在客户端渲染进程里执行任意 JS，
  等价于拿到客户端的全部内部能力。仅建议单用户自用机器开启。
- 本项目**不修改客户端任何文件**，停止调度 + 恢复常规启动方式即可完全回退。

---

## 七、客户端升级后的维护

RPC 通道名或 preload 暴露名可能随版本变化。用 `scripts/tools/` 下的 asar 只读分析工具
按关键词（`claimDailyCheckin` / `CLAIM_DAILY_CHECKIN`）重新定位通道，替换脚本常量即可，
方案结构不变。脚本在 `__wbInvoke` 缺失时会明确报「桥接入口不可用」，不会静默失败。

```bash
export MSYS_NO_PATHCONV=1   # Git Bash 下必须
node scripts/tools/asar_scan.js "claimDailyCheckin" "CLAIM_DAILY_CHECKIN"
```

asar 路径自动解析（`--asar <路径>` > `WB_ASAR` 环境变量 > 常见安装位置），无需改代码。

---

## 八、可移植性说明

脚本不依赖任何个人目录：

| 需要的东西 | 解析顺序 |
|------------|----------|
| Node 运行时 | `-Node` 参数 > `WB_NODE` 环境变量 > PATH 上的 `node` > WorkBuddy 托管运行时 > 常见安装位置（要求 ≥22） |
| WorkBuddy.exe | `-Exe` 参数 > `WB_EXE` 环境变量 > 运行中进程的路径 > 常见安装位置 |
| 项目根目录 | `-Root` 参数 > 脚本自身位置推导 |
| 调试端口 | `-Port` / `--port` > `WB_CDP_PORT` 环境变量 > 19222 |
| app.asar | `--asar` > `WB_ASAR` > 常见安装位置 |

---

## 九、免责声明

本工具仅供**本人在自己账号上**做每日签到自动化，属于对本地客户端调试接口的使用。
使用前请自行确认符合 WorkBuddy 用户协议；使用者自行承担风险。

**安全提示**：调试端口一旦开放，**本机上任何进程**都能通过 CDP 在客户端渲染进程里执行任意 JS，
等价于拿到客户端的全部内部能力。端口只绑 `127.0.0.1`，外部网络无法访问，但本机上的其他程序可以。
请自行权衡"省事"与"暴露面"的取舍。

---

## 十、许可

[MIT License](LICENSE) © 2026 qwgaan

可以自由使用、修改、分发（含商用），保留版权声明即可。
