#!/usr/bin/env bash
# run-tests.sh — 受控测试：用 mock CDP 驱动真实 checkin-via-cdp.js，逐场景断言
#
# 特点：不接触真实客户端、不联网、不需要登录；每个场景使用独立沙箱目录。
# 用法：  bash tests/run-tests.sh
#         WB_NODE="/path/to/node" bash tests/run-tests.sh    # 指定 Node 22+
#
# 注意：脚本只写文件，不做任何删除操作。

set -u

NODE="${WB_NODE:-node}"
if ! "$NODE" -e "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)" 2>/dev/null; then
  echo "✖ 需要 Node 22+（脚本用内置 fetch / WebSocket）。可用 WB_NODE 指定路径。"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/../scripts/checkin-via-cdp.js"
STUB="$ROOT/stub.js"
SANDBOX_ROOT="$ROOT/_sandbox"
RESULT="$ROOT/result.txt"

PASS=0
TOTAL=0
: > "$RESULT"

mk_sandbox() {
  local d="$SANDBOX_ROOT/$1"
  mkdir -p "$d/scripts" "$d/logs"
  cp "$SRC" "$d/scripts/checkin-via-cdp.js"
  printf '# Buddy 加油站每日签到记录（测试沙箱）\n\n| 日期 | 时间 | 结果 | 详情 |\n|------|------|------|------|\n' > "$d/签到历史.md"
  # 清空上一轮的运行期状态（只截断，不删除文件）
  : > "$d/logs/checkin.log"
  : > "$d/logs/push-guard.json"
}

check() {
  TOTAL=$((TOTAL + 1))
  local name="$1" ok="$2" extra="${3:-}"
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1))
    printf 'PASS | %s\n' "$name" >> "$RESULT"
  else
    printf 'FAIL | %s   <-- %s\n' "$name" "$extra" >> "$RESULT"
  fi
}

# run_case <沙箱名> <场景> <附加参数> <SPT环境变量值>
# 子进程输出落到全局 $LAST_OUT；调用方用 `run_case ...; CODE=$?` 取退出码。
# 注意：必须【直接调用】而非 $() 包裹——包起来会起子 shell，LAST_OUT 传不回来。
LAST_OUT=''
run_case() {
  local dir="$SANDBOX_ROOT/$1" scenario="$2" args="$3" spt="$4"
  LAST_OUT="$dir/child-output.txt"
  ( cd "$dir" && MOCK_SCENARIO="$scenario" WXPUSHER_SPT="$spt" \
    "$NODE" --require "$STUB" "$dir/scripts/checkin-via-cdp.js" $args ) > "$LAST_OUT" 2>&1
  return $?
}

last_row() {
  grep -E '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \|' "$1/签到历史.md" | tail -n 1
}

log_of() { echo "$SANDBOX_ROOT/$1/logs/checkin.log"; }

# ---------- S1/S2：端口不可用 ----------
mk_sandbox s1
run_case s1 port "" "SPT_MOCK"; CODE=$?
check "S1 端口不可用 → 退出码 2" "$([ "$CODE" = "2" ] && echo 1 || echo 0)" "code=$CODE"
ROW=$(last_row "$SANDBOX_ROOT/s1")
check "S1 历史行含失败原因" "$(echo "$ROW" | grep -q '失败' && echo "$ROW" | grep -q '调试端口' && echo 1 || echo 0)" "$ROW"
check "S1 触发一次微信提醒" "$(grep -q '提醒已发送(port)' "$(log_of s1)" && echo 1 || echo 0)" ""
check "S1 SPT 未回显、未落盘" "$(grep -q 'SPT_MOCK' "$LAST_OUT" "$SANDBOX_ROOT/s1/签到历史.md" "$(log_of s1)" && echo 0 || echo 1)" ""

run_case s1 port "" "SPT_MOCK"; CODE=$?
PC=$(grep -c '提醒已发送(port)' "$(log_of s1)")
check "S2 当日同因只推一次（不刷屏）" "$([ "$PC" = "1" ] && echo 1 || echo 0)" "已发送次数=$PC"
check "S2 出现去重日志" "$(grep -q '提醒跳过(当日已推送:port)' "$(log_of s1)" && echo 1 || echo 0)" ""

# ---------- S3：--no-push ----------
mk_sandbox s3
run_case s3 port "--no-push" "SPT_MOCK"; CODE=$?
check "S3 --no-push 不发提醒" "$(grep -q '提醒已发送' "$(log_of s3)" && echo 0 || echo 1)" "code=$CODE"

# ---------- S4：签到成功（credit 字段修复验证） ----------
mk_sandbox s4
run_case s4 notchecked "" "SPT_MOCK"; CODE=$?
BODY=$(cat "$LAST_OUT")
ROW=$(last_row "$SANDBOX_ROOT/s4")
check "S4 签到成功 → 退出码 0" "$([ "$CODE" = "0" ] && echo 1 || echo 0)" "code=$CODE"
check "S4 输出无 '?积分' 占位" "$(echo "$BODY" | grep -qE '[?？]积分' && echo 0 || echo 1)" "$(echo "$BODY" | tail -n 1)"
check "S4 历史行含真实积分" "$(echo "$ROW" | grep -q '领取100积分，连续10天' && echo 1 || echo 0)" "$ROW"

# ---------- S5：今日已签到（幂等） ----------
mk_sandbox s5
run_case s5 already "" ""; CODE=$?
ROW=$(last_row "$SANDBOX_ROOT/s5")
check "S5 已签到 → 退出码 0" "$([ "$CODE" = "0" ] && echo 1 || echo 0)" "code=$CODE"
check "S5 历史行为「已签到」" "$(echo "$ROW" | grep -q '已签到' && echo 1 || echo 0)" "$ROW"

# ---------- S6：桥接入口缺失 ----------
mk_sandbox s6
run_case s6 nobridge "" "SPT_MOCK"; CODE=$?
ROW=$(last_row "$SANDBOX_ROOT/s6")
check "S6 桥接缺失 → 退出码 4" "$([ "$CODE" = "4" ] && echo 1 || echo 0)" "code=$CODE"
check "S6 历史行提示桥接不可用" "$(echo "$ROW" | grep -q '桥接入口不可用' && echo 1 || echo 0)" "$ROW"

# ---------- S7：未登录 ----------
mk_sandbox s7
run_case s7 notlogin "" ""; CODE=$?
check "S7 未登录 → 退出码 3" "$([ "$CODE" = "3" ] && echo 1 || echo 0)" "code=$CODE"

# ---------- S8：探针模式只读 ----------
mk_sandbox s8
run_case s8 notchecked "--probe" "SPT_MOCK"; CODE=$?
ROW=$(last_row "$SANDBOX_ROOT/s8")
check "S8 探针模式 → 退出码 0" "$([ "$CODE" = "0" ] && echo 1 || echo 0)" "code=$CODE"
check "S8 探针不写签到历史" "$([ -z "$ROW" ] && echo 1 || echo 0)" "$ROW"

# ---------- S9/S10：端口回退策略 ----------
mk_sandbox s9
run_case s9 portfallback "" "SPT_MOCK"; CODE=$?
check "S9 19222 不通自动回退到旧端口 → 退出码 0" "$([ "$CODE" = "0" ] && echo 1 || echo 0)" "code=$CODE"
check "S9 输出提示已回退" "$(grep -q '回退到旧默认端口' "$LAST_OUT" && echo 1 || echo 0)" "$(tail -n 1 "$LAST_OUT")"

mk_sandbox s10
run_case s10 portfallback "--port 19222" "SPT_MOCK"; CODE=$?
check "S10 显式指定端口时【不】回退 → 退出码 2" "$([ "$CODE" = "2" ] && echo 1 || echo 0)" "code=$CODE"

# ---------- S11：--spt-file（仓库外文件注入凭据） ----------
mk_sandbox s11
printf 'SPT_FROMFILE_MOCK\n' > "$SANDBOX_ROOT/s11/spt.txt"
run_case s11 port "--spt-file $SANDBOX_ROOT/s11/spt.txt" ""; CODE=$?
check "S11 --spt-file 生效（无环境变量也推送）" "$(grep -q '提醒已发送(port)' "$(log_of s11)" && echo 1 || echo 0)" "code=$CODE"
check "S11 SPT 文件值未回显、未落盘" "$(grep -q 'SPT_FROMFILE_MOCK' "$LAST_OUT" "$(log_of s11)" "$SANDBOX_ROOT/s11/签到历史.md" && echo 0 || echo 1)" ""

# ---------- S12：个人标识脱敏 ----------
mk_sandbox s12
run_case s12 already "--probe" ""; CODE=$?
check "S12 目标 URL 已脱敏（不含 accountSnapshot 值）" "$(grep -q 'MOCK_SECRET_UID' "$LAST_OUT" && echo 0 || echo 1)" ""
check "S12 输出含实际使用的端口号" "$(grep -qE '▶ 端口 [0-9]+' "$LAST_OUT" && echo 1 || echo 0)" "$(head -n 1 "$LAST_OUT")"

# ---------- S13：端口被别的应用占用时不误连 ----------
mk_sandbox s13
run_case s13 otherpage "" "SPT_MOCK"; CODE=$?
check "S13 端口上是别的应用 → 不误连，退出码 2" "$([ "$CODE" = "2" ] && echo 1 || echo 0)" "code=$CODE"
check "S13 报「没有 WorkBuddy 的页面 target」" "$(grep -q '没有 WorkBuddy 的页面 target' "$LAST_OUT" && echo 1 || echo 0)" "$(head -n 3 "$LAST_OUT" | tr '\n' ' ')"
ROW=$(last_row "$SANDBOX_ROOT/s13")
check "S13 历史行区分「被占用」而非「端口没开」" "$(echo "$ROW" | grep -q '端口被其他应用占用' && echo 1 || echo 0)" "$ROW"

printf '\nTOTAL %s/%s passed\n' "$PASS" "$TOTAL" >> "$RESULT"
cat "$RESULT"
[ "$PASS" = "$TOTAL" ]
