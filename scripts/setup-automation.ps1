# setup-automation.ps1 — 把「带调试端口启动」设为默认，并建立兜底计划任务
#
# 做四件事（幂等，可重复运行）：
#   1) 检查失败提醒凭据是否已就绪（只判断存在性，本脚本不含、不会写入任何凭据）
#   2) HKCU Run 自启项追加 --remote-debugging-port=19222（开机自启即带端口）
#   3) 桌面 + 开始菜单两个快捷方式追加同一参数（双击图标也带端口）
#   4) 创建/更新计划任务「Buddy加油站签到(CDP)」；并停用已失效的旧任务
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File setup-automation.ps1
#   powershell -ExecutionPolicy Bypass -File setup-automation.ps1 -DryRun
#   powershell -ExecutionPolicy Bypass -File setup-automation.ps1 -Revert   # 撤销本脚本的全部改动
#
# 注意：第 1 步需要管理员以外的普通用户权限即可；第 2、3、4 步用到 COM / 任务计划，
#       若在受限环境下被拦截，请在真实的用户会话里手动运行本脚本一次。
#
# 安全：SPT 等凭据一律不进本仓库。推荐把 SPT 放在仓库外的文件里（如
#       %USERPROFILE%\.wb-checkin\spt.txt），再用 -SptFile 交给签到脚本。

param(
  [int]$Port = 0,
  [int]$TaskHour = 8,
  [int]$TaskMinute = 55,
  [int]$TaskHour2 = 20,
  [int]$TaskMinute2 = 0,
  [string]$Root = '',
  [string]$Exe = '',
  [string]$SptFile = '',
  [string]$BackupDir = '',
  [switch]$DryRun,
  [switch]$Revert
)

$ErrorActionPreference = 'Continue'
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$DEFAULT_PORT = 19222

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
$Root = $Root.TrimEnd('\')

$Exe       = Resolve-WbExe -Explicit $Exe
$ArgFlag   = "--remote-debugging-port=$Port"
$RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName   = 'WorkBuddy.WorkBuddy'
$Shortcuts = @(
  "$env:USERPROFILE\Desktop\WorkBuddy.lnk",
  "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\WorkBuddy.lnk"
)
$TaskName  = 'Buddy加油站签到(CDP)'
$OldTask   = 'Buddy加油站每日签到'
$Runner    = Join-Path $Root 'scripts\run-checkin.ps1'
# 备份放在仓库外，避免把本机启动方式误带进版本控制
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
  $BackupDir = Join-Path $env:USERPROFILE '.wb-checkin\backup\launch-method'
}

$changes = @()

function Say([string]$msg) { Write-Host $msg; $script:changes += $msg }

Write-Host "=== setup-automation.ps1（DryRun=$DryRun, Revert=$Revert, Port=$Port）==="
Write-Host "Root=$Root"
Write-Host "Exe =$Exe"
Write-Host ""

# ---------- 0) 凭据检查（只判断存在性，绝不读取或输出值） ----------
$sptFileOk = $SptFile -and (Test-Path $SptFile)
$sptEnvOk  = -not [string]::IsNullOrWhiteSpace($env:WXPUSHER_SPT)
$sptUserOk = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('WXPUSHER_SPT', 'User'))
if ($sptFileOk -or $sptEnvOk -or $sptUserOk) {
  Say "OK   失败提醒凭据已就绪（来源：$(if ($sptFileOk) { 'SPT 文件' } elseif ($sptEnvOk) { '进程环境变量' } else { '用户级环境变量' })）→ 签到失败时会发微信提醒。"
} else {
  Say "WARN 未检测到 WxPusher SPT → 签到失败时不会发微信提醒（签到本身不受影响）。"
  Say "     二选一（都不要把值写进本仓库的任何文件）："
  Say "     A) 推荐：把 SPT 存到仓库外的文件，例如 %USERPROFILE%\.wb-checkin\spt.txt，"
  Say "        再运行 run-checkin.ps1 -SptFile `"%USERPROFILE%\.wb-checkin\spt.txt`""
  Say "     B) 设为用户级环境变量：[Environment]::SetEnvironmentVariable('WXPUSHER_SPT','<你的SPT>','User')"
  Say "     注意：用户级环境变量只对『之后新启动』的进程生效，客户端需重启一次才读得到。"
}

# ---------- 1) HKCU Run 自启项 ----------
$curRun = $null
try { $curRun = (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction Stop).$RunName } catch { }

if ($Revert) {
  if ($curRun -and $curRun -match '--remote-debugging-port') {
    if ($DryRun) {
      Say "DRY  将把自启项恢复为不带参数（原值：$curRun）"
    } else {
      # 恢复成纯 exe 路径（从原值里剥掉调试参数，保留用户自己的路径）
      $orig = ($curRun -replace '\s*--remote-debugging-port=\d+', '').Trim()
      Set-ItemProperty -Path $RunKey -Name $RunName -Value $orig
      Say "REV  自启项已恢复为不带参数：$orig"
    }
  } else {
    Say "OK   自启项本来就带参数或不存在，无需恢复。（当前：$curRun）"
  }
} else {
  if ($curRun -and $curRun -match '--remote-debugging-port') {
    if ($curRun -match "--remote-debugging-port=$Port\b") {
      Say "OK   自启项已带调试端口：$curRun"
    } else {
      $newRun = ($curRun -replace '\s*--remote-debugging-port=\d+', '').Trim() + ' ' + $ArgFlag
      if ($DryRun) {
        Say "DRY  将把自启项端口更新为 $Port：$newRun"
      } else {
        Set-ItemProperty -Path $RunKey -Name $RunName -Value $newRun
        Say "SET  自启项端口已更新：$newRun"
      }
    }
  } elseif (-not $curRun) {
    Say "WARN 自启项 '$RunName' 不存在，跳过（未自动新增，避免改变你的开机行为）。"
  } elseif (-not $Exe) {
    Say "ERR  未找到 WorkBuddy.exe，无法改写自启项。请用 -Exe <路径> 指定。"
  } else {
    $newRun = '"' + $Exe + '" ' + $ArgFlag
    if ($DryRun) {
      Say "DRY  将把自启项改为：$newRun"
    } else {
      Set-ItemProperty -Path $RunKey -Name $RunName -Value $newRun
      Say "SET  自启项已改为：$newRun"
    }
  }
}

# ---------- 2) 两个快捷方式 ----------
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
try {
  $ws = New-Object -ComObject WScript.Shell
} catch {
  Say "ERR  无法创建 WScript.Shell（COM 被拦截）：$($_.Exception.Message)"
  Say "     请在你自己的用户会话里手动运行本脚本，或手工改快捷方式属性。"
  $ws = $null
}

if ($ws) {
  $idx = 0
  $tags = @('desktop', 'startmenu')
  foreach ($lnk in $Shortcuts) {
    $tag = if ($idx -lt $tags.Count) { $tags[$idx] } else { "extra$idx" }
    $idx++
    if (-not (Test-Path $lnk)) { Say "WARN 快捷方式不存在，跳过：$lnk"; continue }
    try {
      # 先备份原文件（不删除任何东西）——两个快捷方式同名，备份名加位置后缀避免互相覆盖
      $bak = Join-Path $BackupDir ("WorkBuddy.$tag.lnk.bak")
      if (-not (Test-Path $bak)) { Copy-Item $lnk $bak -Force }

      $sc = $ws.CreateShortcut($lnk)
      $curArgs = [string]$sc.Arguments
      if ($Revert) {
        if ($curArgs -match '--remote-debugging-port') {
          if ($DryRun) {
            Say "DRY  将清除参数：$lnk（原参数：$curArgs）"
          } else {
            $sc.Arguments = ($curArgs -replace '\s*--remote-debugging-port=\d+', '').Trim()
            $sc.Save()
            Say "REV  已清除调试参数：$lnk（现参数：$($sc.Arguments)）"
          }
        } else {
          Say "OK   快捷方式本来就没参数：$lnk"
        }
      } else {
        if ($curArgs -match "--remote-debugging-port=$Port\b") {
          Say "OK   快捷方式已带调试端口 $Port：$lnk（$curArgs）"
        } else {
          $base = ($curArgs -replace '\s*--remote-debugging-port=\d+', '').Trim()
          $newArgs = ($base + ' ' + $ArgFlag).Trim()
          if ($DryRun) {
            Say "DRY  将把快捷方式参数改为：$newArgs  ($lnk)"
          } else {
            $sc.Arguments = $newArgs
            $sc.Save()
            Say "SET  快捷方式参数已更新：$lnk（$newArgs）"
          }
        }
      }
    } catch {
      Say "ERR  处理快捷方式失败：$lnk — $($_.Exception.Message)"
    }
  }
  try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) } catch { }
}

# ---------- 3) 计划任务 ----------
function Get-TaskSafe([string]$name) {
  try { return Get-ScheduledTask -TaskName $name -ErrorAction Stop } catch { return $null }
}

if ($Revert) {
  $t = Get-TaskSafe $TaskName
  if ($t) {
    if ($DryRun) {
      Say "DRY  将删除计划任务：$TaskName"
    } else {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
      Say "REV  计划任务已删除：$TaskName"
    }
  } else {
    Say "OK   计划任务不存在，无需删除：$TaskName"
  }
  $ot = Get-TaskSafe $OldTask
  if ($ot -and $ot.State -eq 'Disabled') {
    if (-not $DryRun) { Enable-ScheduledTask -TaskName $OldTask | Out-Null; Say "REV  旧任务已恢复启用：$OldTask" }
    else { Say "DRY  将恢复启用旧任务：$OldTask" }
  }
} else {
  if (-not (Test-Path $Runner)) {
    Say "ERR  找不到入口脚本：$Runner → 跳过计划任务创建。"
  } else {
    try {
      # 端口与 SPT 文件在任务参数里显式指定才写入：
      # 未显式指定时不写 -Port，让 run-checkin.ps1 / checkin-via-cdp.js 用它们自己的
      # 候选逻辑（19222 → 9222 回退），这样迁移期客户端还在旧端口时也能签到。
      $runnerArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $Runner + '"'
      if ($PSBoundParameters.ContainsKey('Port')) { $runnerArgs += ' -Port ' + $Port }
      if ($SptFile) { $runnerArgs += ' -SptFile "' + $SptFile + '"' }
      $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $runnerArgs
      $triggers = @(
        (New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($TaskHour).AddMinutes($TaskMinute))),
        (New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($TaskHour2).AddMinutes($TaskMinute2)))
      )
      $principal = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Limited
      # StartWhenAvailable：错过时间点后尽快补跑
      $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

      if ($DryRun) {
        Say ("DRY  将创建计划任务：$TaskName，每日 {0:00}:{1:00} / {2:00}:{3:00}，动作：powershell {4}" -f $TaskHour, $TaskMinute, $TaskHour2, $TaskMinute2, $runnerArgs)
      } else {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
          -Principal $principal -Settings $settings -Force | Out-Null
        Say ("SET  计划任务已就绪：$TaskName（每日 {0:00}:{1:00} / {2:00}:{3:00}，Port=$Port）" -f $TaskHour, $TaskMinute, $TaskHour2, $TaskMinute2)
      }
    } catch {
      Say "ERR  创建计划任务失败：$($_.Exception.Message)"
      Say "     可改用管理员 PowerShell 执行，或手工在『任务计划程序』里新建："
      Say "     程序: powershell.exe  参数: $runnerArgs"
    }
  }

  $ot = Get-TaskSafe $OldTask
  if ($ot -and $ot.State -ne 'Disabled') {
    if ($DryRun) {
      Say "DRY  将停用已失效的旧任务：$OldTask"
    } else {
      try {
        Disable-ScheduledTask -TaskName $OldTask | Out-Null
        Say "SET  已停用旧任务（保留未删除，可随时恢复）：$OldTask"
      } catch {
        Say "ERR  停用旧任务失败：$($_.Exception.Message)"
      }
    }
  } else {
    Say "OK   旧任务已停用或不存在：$OldTask"
  }
}

# ---------- 4) 汇总 ----------
Write-Host ""
Write-Host "=== 改动汇总 ==="
foreach ($c in $changes) { Write-Host $c }
Write-Host ""
Write-Host "验证："
Write-Host "  1) 退出并重新启动客户端（用改过的快捷方式或开机自启）"
Write-Host "  2) curl -s http://127.0.0.1:$Port/json/version"
Write-Host "  3) powershell -ExecutionPolicy Bypass -File `"$Runner`" -DryRun"
Write-Host ""
Write-Host "回滚：powershell -ExecutionPolicy Bypass -File setup-automation.ps1 -Revert"
Write-Host "备份：$BackupDir"
