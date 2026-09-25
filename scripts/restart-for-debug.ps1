# restart-for-debug.ps1 — Phase 1 验证引导脚本
#
# 作用：退出 WorkBuddy → 以调试端口重启 → 自动完成 Phase 1 三项验证 → 写报告。
#
# 为什么要"脱离会话"运行：
#   本 Agent 会话本身是 WorkBuddy 的子进程（main → daemon → sidecar → codebuddy --serve），
#   杀掉客户端会连带结束当前会话。因此本脚本设计为独立进程运行，
#   延迟数秒后自行完成"退出 → 重启 → 验证 → 落盘报告"全流程。
#
# 手动运行（脚本位置即项目位置，无需改路径）：
#   powershell -ExecutionPolicy Bypass -File "<项目根>\scripts\restart-for-debug.ps1"
# 仅预览不执行：
#   powershell -ExecutionPolicy Bypass -File "<项目根>\scripts\restart-for-debug.ps1" -DryRun
#
# ⚠️ 注意：本脚本会强制结束客户端进程，会中断当前正在运行的会话（含正在执行的自动化）。
#          它是 Phase 1 的一次性引导工具；日常自动签到请用 run-checkin.ps1（不杀进程）。
#          若要长期免重启，请用 setup-automation.ps1 把「带调试端口启动」设为默认。

param(
  [int]$Port = 0,
  [int]$DelaySeconds = 8,
  [int]$BootTimeoutSeconds = 120,
  [string]$Root = '',
  [string]$Node = '',
  [string]$Exe = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ProgressPreference = 'SilentlyContinue'

$DEFAULT_PORT = 19222

function Resolve-NodeExe {
  param([string]$Explicit)
  $cands = @()
  if ($Explicit) { $cands += $Explicit }
  if ($env:WB_NODE) { $cands += $env:WB_NODE }
  # 优先用 WorkBuddy 自带的托管运行时（版本可控、与客户端同源）
  $managedRoot = Join-Path $env:USERPROFILE '.workbuddy\binaries\node\versions'
  if (Test-Path $managedRoot) {
    Get-ChildItem $managedRoot -Filter 'node.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending | ForEach-Object { $cands += $_.FullName }
  }
  $onPath = Get-Command node -ErrorAction SilentlyContinue
  if ($onPath) { $cands += $onPath.Source }
  $cands += @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe")
  foreach ($c in $cands) {
    if (-not $c) { continue }
    if (-not (Test-Path $c)) { continue }
    try {
      & $c -e "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)" 2>$null
      if ($LASTEXITCODE -eq 0) { return $c }
    } catch { }
  }
  return ''
}

function Resolve-WbExe {
  param([string]$Explicit)
  if ($Explicit -and (Test-Path $Explicit)) { return $Explicit }
  if ($env:WB_EXE -and (Test-Path $env:WB_EXE)) { return $env:WB_EXE }
  $p = Get-Process -Name 'WorkBuddy' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -and $p.Path) { return $p.Path }
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy\WorkBuddy.exe'),
    (Join-Path $env:ProgramFiles 'WorkBuddy\WorkBuddy.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'WorkBuddy\WorkBuddy.exe')
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  return ''
}

if ($Port -le 0) {
  $envPort = 0
  try { $envPort = [int]$env:WB_CDP_PORT } catch { $envPort = 0 }
  $Port = if ($envPort -gt 0) { $envPort } else { $DEFAULT_PORT }
}
if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
}
$Root      = $Root.TrimEnd('\')
$Node      = Resolve-NodeExe -Explicit $Node
$Exe       = Resolve-WbExe  -Explicit $Exe
$LogDir    = Join-Path $Root 'logs'
$LogFile   = Join-Path $LogDir 'phase1.log'
$ReportFile = Join-Path $Root 'docs\phase1-report.md'
$Probe     = Join-Path $Root 'scripts\probe-cdp.js'
$Checkin   = Join-Path $Root 'scripts\checkin-via-cdp.js'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Log([string]$msg) {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line = "[$ts] $msg"
  Write-Host $line
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# 报告脱敏：写进 docs/ 的内容不能带个人标识
#   - URL 的 query（含 accountSnapshot → uid / 昵称）
#   - target / browser 的调试 UUID
#   - 签到活动明细（历史日期、累计积分）
function Redact([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }
  $s = $s -replace '(file://[^\s?]*)\?[^\s]*', '$1?<redacted>'
  $s = $s -replace '"checkin_dates"\s*:\s*\[[^\]]*\]', '"checkin_dates":"<redacted>"'
  $s = $s -replace '"total_credits"\s*:\s*\d+', '"total_credits":"<redacted>"'
  $s = $s -replace '"week_progress"\s*:\s*\[[^\]]*\]', '"week_progress":"<redacted>"'
  $s = $s -replace '[0-9A-Fa-f]{32}', '<redacted-uuid>'
  $s = $s -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<redacted-uuid>'
  return $s
}

function Get-WbProcesses {
  Get-Process -Name 'WorkBuddy' -ErrorAction SilentlyContinue
}

Log "=== Phase 1 引导开始（Port=$Port, Delay=${DelaySeconds}s, DryRun=$DryRun）==="
Log "计划: 1) 优雅退出客户端 2) 以 --remote-debugging-port=$Port 重启 3) 三项验证 4) 写报告"

if ($DryRun) {
  $procs = Get-WbProcesses
  Log "DRY-RUN：当前 WorkBuddy 进程数 = $(@($procs).Count)"
  foreach ($p in @($procs)) { Log "  PID $($p.Id)  $($p.ProcessName)" }
  Log "DRY-RUN：将执行：Stop-Process 全部 → Start-Process `"$Exe`" --remote-debugging-port=$Port"
  Log "DRY-RUN 结束，未做任何变更。"
  exit 0
}

# ---------- 1. 延迟，让 Agent 的回复先发出去 ----------
Log "延迟 $DelaySeconds 秒后开始退出客户端（给会话留出结束时间）..."
Start-Sleep -Seconds $DelaySeconds

# ---------- 2. 优雅退出 ----------
$before = @(Get-WbProcesses).Count
Log "当前 WorkBuddy 进程数：$before"

try {
  Get-Process -Name 'WorkBuddy' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    ForEach-Object { $_.CloseMainWindow() | Out-Null }
  Log "已发送窗口关闭请求，等待 6 秒..."
  Start-Sleep -Seconds 6
} catch { Log "优雅关闭异常：$($_.Exception.Message)" }

$left = Get-WbProcesses
if (@($left).Count -gt 0) {
  Log "仍有 $(@($left).Count) 个进程，执行强制结束..."
  $left | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 等待完全退出（避免单实例锁导致带参数启动被忽略）
$deadline = (Get-Date).AddSeconds(30)
while ((Get-WbProcesses) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
$remain = @(Get-WbProcesses).Count
Log "退出完成，剩余进程数：$remain"
if ($remain -gt 0) {
  Log "⚠️ 仍有残留进程，带参数启动可能被单实例锁忽略。"
}

# ---------- 3. 带调试端口重启（尽早执行，确保客户端回到可用状态） ----------
Log "启动客户端：$Exe --remote-debugging-port=$Port"
try {
  Start-Process -FilePath $Exe -ArgumentList "--remote-debugging-port=$Port" | Out-Null
  Log "已发起启动。"
} catch {
  Log "❌ 启动失败：$($_.Exception.Message)"
}

# ---------- 4. 等待调试端口就绪 ----------
$portOk = $false
$bootDeadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
while ((Get-Date) -lt $bootDeadline) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -UseBasicParsing
    if ($r.StatusCode -eq 200) {
      $portOk = $true
      Log "✅ 调试端口 $Port 已就绪：$($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))"
      break
    }
  } catch {}
  Start-Sleep -Seconds 2
}
if (-not $portOk) { Log "❌ 等待 ${BootTimeoutSeconds}s 后调试端口仍未就绪。" }

# 界面加载留一点时间，保证存在可用的 page target
Start-Sleep -Seconds 6

# ---------- 5. 三项验证 ----------
$probeOut = ''
$statusOut = ''
$claimOut = ''

if ($portOk) {
  Log "--- 验证项 1/2：探针（调试端口 + target） ---"
  try {
    $probeOut = (& $Node $Probe "$Port" 2>&1 | Out-String)
    Log "探针输出：`n$probeOut"
  } catch { $probeOut = "探针执行异常：$($_.Exception.Message)"; Log $probeOut }

  Log "--- 验证项 3：桥接入口 + 只读查询签到状态 ---"
  try {
    $statusOut = (& $Node $Checkin '--probe' '--json' '--port' "$Port" 2>&1 | Out-String)
    Log "状态查询输出：`n$statusOut"
  } catch { $statusOut = "状态查询异常：$($_.Exception.Message)"; Log $statusOut }

  # 只读查询成功 → 真正执行签到（脚本自带先查后签，幂等）
  $bridgeOk = ($statusOut -like '*getCheckinStatus*') -and ($statusOut -notlike '*__wbInvoke*不可用*') -and ($statusOut -notlike '*未找到 __wbInvoke*')
  if ($bridgeOk) {
    Log "--- 可选：执行签到（幂等，已签到会直接返回） ---"
    try {
      $claimOut = (& $Node $Checkin '--json' '--port' "$Port" 2>&1 | Out-String)
      Log "签到输出：`n$claimOut"
    } catch { $claimOut = "签到执行异常：$($_.Exception.Message)"; Log $claimOut }
  } else {
    Log "跳过签到：桥接入口未确认可用。"
  }
}

# ---------- 6. 写报告 ----------
$verdict = if ($portOk) { '调试端口可用' } else { '调试端口不可用' }
$md = @()
$md += '# Phase 1 验证报告（已脱敏）'
$md += ''
$md += "> 生成时间：$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
$md += "> 调试端口：$Port ｜ 引导结果：**$verdict**"
$md += '>'
$md += '> 本文件含本机运行信息，已在脚本内脱敏（URL query / 调试 UUID / 签到活动明细）。'
$md += '> 它位于 `.gitignore` 排除列表中，不会进版本控制；格式示例见 `phase1-report.example.md`。'
$md += ''
$md += '## 结论速览'
$md += ''
$md += "| 验证项 | 结果 |"
$md += '|--------|------|'
$md += "| 1. 调试端口是否可用 | $(if ($portOk) { '✅ 通过' } else { '❌ 不通过' }) |"
$md += "| 2. 能否命中渲染进程 target | $(if ($probeOut -like '*主界面 target*') { '✅ 通过' } else { '❌ 未确认' }) |"
$md += "| 3. RPC 桥 `__wbInvoke` 是否可用 | $(if ($statusOut -like '*getCheckinStatus*') { '✅ 通过' } else { '❌ 未确认' }) |"
$md += "| 4. 签到执行 | $(if ($claimOut -match '签到成功|已签到') { '✅ 已执行' } else { '未执行/未确认' }) |"
$md += ''
$md += '## 验证项 1/2 · 探针输出'
$md += ''
$md += '```text'
$md += (Redact $probeOut.Trim())
$md += '```'
$md += ''
$md += '## 验证项 3 · 只读查询签到状态'
$md += ''
$md += '```text'
$md += (Redact $statusOut.Trim())
$md += '```'
$md += ''
if ($claimOut) {
  $md += '## 签到执行输出'
  $md += ''
  $md += '```text'
  $md += (Redact $claimOut.Trim())
  $md += '```'
  $md += ''
}
$md += '## 后续'
$md += ''
if ($portOk -and ($statusOut -like '*getCheckinStatus*')) {
  $md += '- ✅ 方案 A 成立。可直接进入 Phase 3：把 `node scripts/checkin-via-cdp.js` 接入 WorkBuddy 原生定时自动化。'
  $md += '- ⚠️ 注意：调试端口仅在本次带参数启动期间有效；客户端下次常规启动后需重新带参数。'
} else {
  $md += '- ❌ 方案 A 未通过，按 `docs/02-实施方案.md` 转保底路线（UIA/坐标点击）。'
}
$md += ''
$md += '## 完整日志'
$md += ''
$md += '- `logs/phase1.log`'
$md += '- `logs/checkin.log`'

try {
  Set-Content -Path $ReportFile -Value ($md -join "`r`n") -Encoding UTF8
  Log "报告已写入：$ReportFile"
} catch { Log "报告写入失败：$($_.Exception.Message)" }

Log "=== Phase 1 引导结束 ==="

# ---------- 7. 自清理：移除本次一次性引导任务 ----------
try {
  $t = Get-ScheduledTask -TaskName 'WB-Phase1-Bootstrap' -ErrorAction Stop
  Unregister-ScheduledTask -TaskName 'WB-Phase1-Bootstrap' -Confirm:$false -ErrorAction Stop
  Log "已移除一次性引导任务 WB-Phase1-Bootstrap"
} catch {
  Log "引导任务无需清理或清理失败（可忽略）：$($_.Exception.Message)"
}
