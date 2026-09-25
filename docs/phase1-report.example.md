# Phase 1 验证报告（脱敏示例）

> 本文件是**示例**，展示 `scripts/restart-for-debug.ps1` 生成报告的格式。
> 你本机实际跑出来的报告会写到 `docs/phase1-report.md`（该文件已被 `.gitignore` 排除，不会进版本控制）。

> 生成时间：<yyyy-MM-dd HH:mm:ss>
> 客户端：WorkBuddy <版本号> ｜ 调试端口：19222 ｜ 引导结果：**调试端口可用**

## 结论速览

| 验证项 | 结果 |
|--------|------|
| 1. 调试端口是否可用 | ✅ 通过 |
| 2. 能否命中渲染进程 target | ✅ 通过 |
| 3. RPC 桥 __wbInvoke 是否可用 | ✅ 通过 |
| 4. 签到执行 | ✅ 已执行 |

## 验证项 1/2 · 探针输出

```text
=== WorkBuddy CDP 探针 ===
扫描端口: 19222

[端口 19222] ✅ 调试端口已开放
  Browser : Chrome/<版本>
  WS      : ws://127.0.0.1:19222/devtools/browser/<redacted-uuid>
  Targets : 1 个，其中 page 1 个
  ▶ 主界面 target
    title : WorkBuddy
    url   : file:///<WorkBuddy 安装目录>/resources/app.asar/renderer/index.html
    ws    : ws://127.0.0.1:19222/devtools/page/<redacted-uuid>

=== 结论 ===
✅ 通过：端口 19222 可用，可进入验证项 3（调用 __wbInvoke）。
   下一步：node scripts/checkin-via-cdp.js --probe --port 19222
```

> 注：URL 里的 query（`?accountSnapshot=...`）含 uid / 昵称等个人标识，
> 脚本与探针都已**默认剥离**，不会写进任何日志或报告。

## 验证项 3 · 只读查询签到状态

```text
▶ 端口 19222 ｜ 目标: WorkBuddy file:///<WorkBuddy 安装目录>/resources/app.asar/renderer/index.html
  getCheckinStatus -> {"active":true,"today_checked_in":false,"streak_days":"<redacted>","checkin_dates":"<redacted>","total_credits":"<redacted>",...}
=== 探针模式（未执行签到） ===
```

> 注：报告生成时会把 `checkin_dates` / `total_credits` 等个人活动数据替换为 `<redacted>`，
> 只保留验证所需的 `active` / `today_checked_in` 等布尔与状态字段。

## 签到执行输出

```text
▶ 端口 19222 ｜ 目标: WorkBuddy file:///<WorkBuddy 安装目录>/resources/app.asar/renderer/index.html
  getCheckinStatus -> {"active":true,"today_checked_in":false,...}
  claimDailyCheckin -> {"credit":100,"streak_days":"<redacted>","is_streak_day":false}
✅ 签到成功 — 领取100积分，连续<redacted>天
```

## 后续

- ✅ 方案成立。可把 `node scripts/checkin-via-cdp.js` 接入定时调度。
- ⚠️ 调试端口仅在本次带参数启动期间有效；客户端下次常规启动后需重新带参数。
  用 `scripts/setup-automation.ps1` 可把带参启动设为默认，一劳永逸。

## 完整日志

- `logs/phase1.log`
- `logs/checkin.log`
