# run-checkin.ps1 — 「Buddy 加油站」签到 · 计划任务入口（兜底调度）
#
# 定位：Windows 计划任务只负责"客户端没在调试模式下，就把条件补齐"，签到逻辑全在纯 Node 脚本里。
#
# 决策顺序（重要：本脚本【绝不杀进程】）：
#   1) 调试端口通        → 直接签到（最佳路径）
#   2) 不通 + 客户端在跑 → 说明是常规模式启动的，记「需手动签到」并提醒；不重启、不打断工作
#   3) 不通 + 客户端没跑 → 带 --remote-debugging-port 拉起客户端 → 等端口 → 签到（无会话可打断）
#   4) 拉起后仍无端口    → 记失败并提醒
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File run-checkin.ps1
#   powershell -ExecutionPolicy Bypass -File run-checkin.ps1 -DryRun          # 只探测不动作
#   powershell -ExecutionPolicy Bypass -File run-checkin.ps1 -NoLaunch        # 禁止拉起客户端
#   powershell -ExecutionPolicy Bypass -File run-checkin.ps1 -SptFile <路径>  # 失败提醒的 SPT 从文件读
#
# 端口解析顺序：-Port > 环境变量 WB_CDP_PORT > 默认 19222
# 路径均可自动探测（Node / WorkBuddy.exe / 项目根），也可用 -Node / -Exe / -Root 显式指定。
#
# 安全：本文件不含任何凭据。失败提醒的 SPT 由 Node 脚本在运行时获取
#       （--spt-file 指向的文件，或环境变量 WXPUSHER_SPT），不写死、不回显、不落盘。

param(
  [int]$Port = 0,
  [int]$WaitSeconds = 90,
  [string]$Root = '',
  [string]$Node = '',
  [string]$Exe = '',
  [string]$SptFile = '',
  [switch]$NoLaunch,
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
# Node 输出为 UTF-8：不设这两项会被 PS 5.1 按 GBK 解码成乱码
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# 关闭 Invoke-WebRequest 的进度噪声
$ProgressPreference = 'SilentlyContinue'

$DEFAULT_PORT = 19222
$LEGACY_PORT = 9222

# ---------- 自动探测：路径与端口（不依赖任何个人目录） ----------
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
    # 需要 Node 22+：脚本用内置 fetch / WebSocket，无第三方依赖
    try {
      & $c -e "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)" 2>$null
      if ($LASTEXITCODE -eq 0) { return $c }
    } catch { }
  }
  return $null
}

function Resolve-WbExe {
  param([string]$Explicit)
  if ($Explicit -and (Test-Path $Explicit)) { return $Explicit }
  if ($env:WB_EXE -and (Test-Path $env:WB_EXE)) { return $env:WB_EXE }
  # 最可靠：直接取运行中进程的可执行文件路径
  $p = Get-Process -Name 'WorkBuddy' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -and $p.Path) { return $p.Path }
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy\WorkBuddy.exe'),
    (Join-Path $env:ProgramFiles 'WorkBuddy\WorkBuddy.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'WorkBuddy\WorkBuddy.exe')
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  return $null
}

if ($Port -le 0) {
  $envPort = 0
  try { $envPort = [int]$env:WB_CDP_PORT } catch { $envPort = 0 }
  $Port = if ($envPort -gt 0) { $envPort } else { $DEFAULT_PORT }
}

# 端口候选：显式给了 -Port 就只认它；否则与 checkin-via-cdp.js 保持一致，
# 先试新默认端口，再容忍旧默认 9222（迁移期客户端还没带新参数重启时仍能签到）。
$ExplicitPort = $PSBoundParameters.ContainsKey('Port') -or -not [string]::IsNullOrWhiteSpace($env:WB_CDP_PORT)
$PortCandidates = if ($ExplicitPort) { @($Port) } else { @($Port, $LEGACY_PORT) }

if ([string]::IsNullOrWhiteSpace($Root)) {
  # 本脚本位于 <项目根>\scripts\ 下 → 上一级即项目根
  $Root = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
}
$Root = $Root.TrimEnd('\')

$Node = Resolve-NodeExe -Explicit $Node
$Exe  = Resolve-WbExe  -Explicit $Exe

$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'schedule.log'
$Checkin = Join-Path $Root 'scripts\checkin-via-cdp.js'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log([string]$msg) {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Write-Host "[$ts] $msg"
  try { Add-Content -Path $LogFile -Value "[$ts] $msg" -Encoding UTF8 } catch { }
}

# 按候选顺序探测，返回第一个开放的端口（0 = 都没开）
function Get-OpenDebugPort {
  foreach ($p in $PortCandidates) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/json/version" -TimeoutSec 3 -UseBasicParsing
      if ($r.StatusCode -eq 200) { return $p }
    } catch { }
  }
  return 0
}

function Test-ClientRunning {
  $p = @(Get-Process -Name 'WorkBuddy' -ErrorAction SilentlyContinue)
  return ($p.Count -gt 0)
}

$script:LastExit = 0

function Invoke-Checkin {
  if (-not $Node) {
    Write-Log "❌ 未找到可用的 Node 运行时（需 Node 22+）。请用 -Node <路径> 指定，或设置环境变量 WB_NODE。"
    $script:LastExit = 4
    return
  }
  if (-not (Test-Path $Checkin)) {
    Write-Log "❌ 找不到签到脚本：$Checkin"
    $script:LastExit = 4
    return
  }
  $nodeArgs = @($Checkin)
  # 只在显式指定端口时把端口钉死；否则交给 JS 自己按候选列表选（并做严格 target 校验）
  if ($ExplicitPort) { $nodeArgs += @('--port', "$Port") }
  # SPT 只从仓库外的文件读取；文件不存在就静默跳过推送，不影响签到
  if ($SptFile -and (Test-Path $SptFile)) { $nodeArgs += @('--spt-file', $SptFile) }
  $out = (& $Node @nodeArgs 2>&1 | Out-String)
  $script:LastExit = $LASTEXITCODE
  $keep = @($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  Write-Log "签到结果：$($keep -join ' / ')"
  Write-Log "Node 退出码：$script:LastExit"
}

Write-Log "=== 签到触发（Port=$Port, 候选=$($PortCandidates -join '/'), Wait=${WaitSeconds}s, NoLaunch=$NoLaunch, DryRun=$DryRun）==="
Write-Log "路径解析：Node=$Node ｜ Exe=$Exe ｜ Root=$Root"

$openPort = Get-OpenDebugPort

if ($DryRun) {
  Write-Log "DRY-RUN：调试端口 = $(if ($openPort) { "$openPort 已开放" } else { '候选端口均未开放' })；客户端进程 = $(if (Test-ClientRunning) { '在运行' } else { '未运行' })"
  Write-Log "DRY-RUN 结束，未做任何变更。"
  exit 0
}

# ---------- 1) 端口已开：直接签到 ----------
if ($openPort) {
  Write-Log "调试端口 $openPort 已开放 → 直接签到。"
  Invoke-Checkin
  exit $script:LastExit
}

Write-Log "候选调试端口（$($PortCandidates -join ' / ')）均未开放。"

# ---------- 2) 客户端在跑但没开端口：不杀进程，只记录 + 提醒 ----------
if (Test-ClientRunning) {
  Write-Log "客户端正在运行但未开调试端口（常规模式启动）→ 不做杀进程/重启操作，交由 Node 脚本记录失败并提醒。"
  Write-Log "如需自动签到：请以 --remote-debugging-port=$Port 启动客户端，或把带参启动设为默认（见 setup-automation.ps1）。"
  Invoke-Checkin
  exit $script:LastExit
}

# ---------- 3) 客户端没跑：带参拉起 ----------
if ($NoLaunch) {
  Write-Log "客户端未运行，且指定了 -NoLaunch → 不拉起，交由 Node 脚本记录失败。"
  Invoke-Checkin
  exit $script:LastExit
}

if (-not $Exe) {
  Write-Log "❌ 未找到 WorkBuddy.exe（可用 -Exe <路径> 指定，或设置环境变量 WB_EXE）→ 无法拉起客户端。"
  Invoke-Checkin
  exit $script:LastExit
}

Write-Log "客户端未运行 → 带参拉起：$Exe --remote-debugging-port=$Port"
try {
  Start-Process -FilePath $Exe -ArgumentList "--remote-debugging-port=$Port" | Out-Null
  Write-Log "已发起启动，等待调试端口就绪（最多 ${WaitSeconds}s）..."
} catch {
  Write-Log "❌ 启动失败：$($_.Exception.Message)"
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$portOk = $false
while ((Get-Date) -lt $deadline) {
  if ((Get-OpenDebugPort) -gt 0) { $portOk = $true; break }
  Start-Sleep -Seconds 2
}

if ($portOk) {
  Write-Log "✅ 调试端口 $Port 已就绪。"
  # 界面加载留一点时间，保证存在可用的 page target
  Start-Sleep -Seconds 5
} else {
  Write-Log "⚠️ 等待 ${WaitSeconds}s 后调试端口仍未就绪，仍尝试签到以留下可诊断的记录。"
}

# ---------- 4) 签到 ----------
Invoke-Checkin

Write-Log "=== 签到结束（退出码 $script:LastExit）==="
exit $script:LastExit
