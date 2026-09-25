#!/usr/bin/env node
/**
 * checkin-via-cdp.js — 经 CDP 触发「Buddy 加油站」签到
 *
 * 原理：不模拟鼠标，而是通过调试协议在渲染进程内调用客户端自身的 RPC 通道
 *       window.__wbInvoke('auth:claimDailyCheckin')，效果等同于点击
 *       「Buddy加油站 → 签到领积分」——鉴权由客户端自行完成。
 *
 * 用法：
 *   node scripts/checkin-via-cdp.js                    # 正常签到（先查后签，幂等）
 *   node scripts/checkin-via-cdp.js --probe            # 只读：仅查状态，不签到
 *   node scripts/checkin-via-cdp.js --port 19222       # 指定调试端口
 *   node scripts/checkin-via-cdp.js --json             # 额外输出原始响应，便于定性
 *   node scripts/checkin-via-cdp.js --no-push          # 失败时不发微信提醒
 *   node scripts/checkin-via-cdp.js --spt-file <路径>  # 从文件读 SPT（推荐给定时任务用）
 *   node scripts/checkin-via-cdp.js --loose-target     # 放宽 target 匹配（默认要求 URL 含 workbuddy）
 *
 * 端口也可用环境变量覆盖：WB_CDP_PORT（优先级：--port > WB_CDP_PORT > 默认 19222）
 *
 * 退出码：0 = 成功/已签到；2 = 端口或 target 不可用；3 = 未登录；4 = 接口报错
 *
 * 安全声明：
 *   - 仅访问 127.0.0.1 的调试端口，仅调用腾讯官方接口（由客户端代理发出）。
 *   - 不读取、不解密、不落盘、不外传任何 accessToken / refreshToken / X-Device-Token。
 *   - 失败提醒的 WxPusher SPT 按优先级读取：--spt-file > 环境变量 WXPUSHER_SPT。
 *     仓库内**不含任何真实凭据**；SPT 只在你自己的机器上、运行时注入。
 *   - 日志仅记录签到结果与积分，不记录任何凭据。
 */

const fs = require('fs');
const path = require('path');

// ---------- 参数 ----------
const argv = process.argv.slice(2);
const getFlag = (name) => argv.includes(name);
const getOpt = (name, def) => {
  const i = argv.indexOf(name);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : def;
};

const PROBE_ONLY = getFlag('--probe');
const SHOW_JSON = getFlag('--json');
const NO_PUSH = getFlag('--no-push');
// 默认要求 target URL 含 workbuddy/codebuddy（防止误连到占用同端口的浏览器）；
// 构建版本 URL 不含该特征时用这个开关放宽
const LOOSE_TARGET = getFlag('--loose-target');

// 调试端口：--port > 环境变量 WB_CDP_PORT > 默认 19222
// （19222 而非 9222：避开 CentBrowser / Chrome / Edge 等常用调试端口，防止撞车）
const DEFAULT_PORT = 19222;
const LEGACY_PORT = 9222;
const EXPLICIT_PORT = getOpt('--port', process.env.WB_CDP_PORT || null);
// 显式指定 → 只认这一个；否则先试 19222，再容忍旧默认 9222（平滑迁移期）
const PORT_CANDIDATES = EXPLICIT_PORT ? [Number(EXPLICIT_PORT)] : [DEFAULT_PORT, LEGACY_PORT];
const PORT = PORT_CANDIDATES[0];

/**
 * 解析 WxPusher SPT —— 仓库里永不硬编码，只从运行时来源取：
 *   1) --spt-file <路径>：从文件读取（推荐；文件放在仓库外，如 %USERPROFILE%\.wb-checkin\spt.txt）
 *   2) 环境变量 WXPUSHER_SPT（进程级/用户级均可）
 * 取不到就静默跳过推送，不影响签到本身。
 */
function resolveSpt() {
  const file = getOpt('--spt-file', null);
  if (file) {
    try {
      const v = fs.readFileSync(file, 'utf8').trim();
      if (v) return v;
      console.error(`⚠️ SPT 文件为空，忽略：${file}`);
    } catch (e) {
      console.error(`⚠️ SPT 文件读取失败（${e.message}），回退环境变量。`);
    }
  }
  return process.env.WXPUSHER_SPT || '';
}

const SPT = resolveSpt();

const ROOT = path.resolve(__dirname, '..');
const HISTORY = path.join(ROOT, '签到历史.md');
const LOG_DIR = path.join(ROOT, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'checkin.log');
const PUSH_GUARD = path.join(LOG_DIR, 'push-guard.json');

// ---------- 工具 ----------
const now = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return {
    date: `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`,
    time: `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`,
  };
};

function appendLog(text) {
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    fs.appendFileSync(LOG_FILE, `[${now().date} ${now().time}] ${text}\n`, 'utf8');
  } catch {
    /* 日志失败不影响主流程 */
  }
}

/** 在表头分隔行之后插入一行（最新在最上） */
function appendHistoryRow(date, time, result, detail) {
  try {
    const row = `| ${date} | ${time} | ${result} | ${detail} |`;
    let content = fs.existsSync(HISTORY) ? fs.readFileSync(HISTORY, 'utf8') : '';
    const lines = content.split(/\r?\n/);
    const sep = lines.findIndex((l) => /^\|[\s\-:|]+\|$/.test(l.trim()) && l.includes('-'));
    if (sep === -1) {
      lines.push(row);
    } else {
      lines.splice(sep + 1, 0, row);
    }
    fs.writeFileSync(HISTORY, lines.join('\n'), 'utf8');
  } catch (err) {
    console.error('写入签到历史失败:', err.message);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- WxPusher 失败提醒 ----------
/** 当日同一类失败原因只推一次，避免多点补签时刷屏 */
async function pushOnce(key, msg) {
  if (!SPT || NO_PUSH || PROBE_ONLY) return;
  const today = now().date;
  let guard = {};
  try {
    guard = JSON.parse(fs.readFileSync(PUSH_GUARD, 'utf8'));
  } catch {
    /* 首次运行或文件损坏 */
  }
  if (guard.date !== today) guard = { date: today, keys: [] };
  if (!Array.isArray(guard.keys)) guard.keys = [];
  if (guard.keys.includes(key)) {
    appendLog(`提醒跳过(当日已推送:${key})`);
    return;
  }

  const text = `【Buddy加油站签到失败】\n${today} ${now().time}\n类别: ${key}\n${msg}`;
  try {
    const res = await fetch('https://wxpusher.zjiecode.com/api/send/message/simple-push', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: text, contentType: 1, spt: SPT }),
      signal: AbortSignal.timeout(10000),
    });
    appendLog(`提醒已发送(${key}) HTTP ${res.status}`);
  } catch (e) {
    appendLog(`提醒发送失败(${key}): ${e.message}`);
  }

  guard.keys.push(key);
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    fs.writeFileSync(PUSH_GUARD, JSON.stringify(guard), 'utf8');
  } catch {
    /* 守卫写入失败不影响主流程 */
  }
}

/** 失败统一出口：打印 + 日志 + 历史 + 提醒 + 退出 */
async function bail(key, consoleMsg, historyDetail, exitCode) {
  const t = now();
  console.log(consoleMsg);
  appendLog(`失败 ${consoleMsg.replace(/^❌\s*/, '')}`);
  appendHistoryRow(t.date, t.time, '失败', historyDetail);
  await pushOnce(key, consoleMsg);
  process.exit(exitCode);
}

// ---------- CDP ----------
async function fetchJson(url, timeoutMs = 3000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

/** 极简 CDP 客户端（Node 22+ 内置 WebSocket，无第三方依赖） */
class CDP {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.id = 0;
    this.pending = new Map();
  }
  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.wsUrl);
      this.ws = ws;
      const onErr = (e) => reject(new Error('WebSocket 连接失败: ' + (e.message || 'unknown')));
      ws.addEventListener('error', onErr);
      ws.addEventListener('open', () => {
        ws.removeEventListener('error', onErr);
        resolve();
      });
      ws.addEventListener('message', (ev) => {
        let msg;
        try {
          msg = JSON.parse(ev.data);
        } catch {
          return;
        }
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve: res, reject: rej } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
        }
      });
      ws.addEventListener('close', () => this.pending.clear());
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`${method} 超时`));
        }
      }, 20000);
    });
  }
  /** 在页面上下文求值，支持 await */
  async evaluate(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.exception?.description || '页面内执行异常');
    }
    return r.result?.value;
  }
  close() {
    try {
      this.ws?.close();
    } catch {}
  }
}

/**
 * 在指定端口上找 WorkBuddy 的页面 target。
 * 默认严格匹配 URL 含 workbuddy/codebuddy —— 这样即使该端口被别的应用（如浏览器）占用，
 * 也不会误连过去。若你的构建版本 URL 不含该特征，用 --loose-target 放宽。
 */
async function findTargetOnPort(port, allowLoose) {
  const list = await fetchJson(`http://127.0.0.1:${port}/json`);
  const pages = (Array.isArray(list) ? list : []).filter((t) => t.type === 'page');
  const strict = pages.find((t) => /workbuddy|codebuddy/i.test(t.url || ''));
  if (strict) return strict;
  return allowLoose ? pages.find((t) => t.webSocketDebuggerUrl) || null : null;
}

/** 按候选顺序找可用端口 + target */
async function findAnyTarget() {
  const errors = [];
  for (const p of PORT_CANDIDATES) {
    try {
      const t = await findTargetOnPort(p, LOOSE_TARGET);
      if (t) return { port: p, target: t, errors };
      errors.push(`端口 ${p} 已开放，但其中没有 WorkBuddy 的页面 target`);
    } catch (e) {
      errors.push(`端口 ${p} 不可用（${e.message}）`);
    }
  }
  return { port: null, target: null, errors };
}

// ---------- 结果归一化 ----------
function normalize(data) {
  if (data === null || data === undefined) return { ok: false, kind: 'unknown' };
  if (typeof data === 'string') {
    if (/已签到|already/i.test(data)) return { ok: true, kind: 'already' };
    return { ok: false, kind: 'unknown' };
  }
  const d = data.data && typeof data.data === 'object' ? data.data : data;

  const checkedIn = d.today_checked_in ?? d.todayCheckedIn;
  const streak = d.streak_days ?? d.streakDays;
  // 注意：状态接口用 daily_credit / today_credit，签到接口返回的是 credit —— 两者都要认
  const credit = d.credit ?? d.daily_credit ?? d.dailyCredit ?? d.today_credit ?? d.todayCredit;
  const total = d.total_credits ?? d.totalCredits;

  // 接口报错
  if (typeof data.code === 'number' && data.code !== 0) {
    return {
      ok: false,
      kind: 'error',
      detail: data.msg || data.message || `code=${data.code}`,
      raw: data,
    };
  }

  if (checkedIn === true) {
    return {
      ok: true,
      kind: 'already',
      detail: total != null ? `今日已签到，累计${total}积分` : '今日已签到，无需重复领取',
      raw: data,
    };
  }

  if (credit != null || streak != null) {
    return {
      ok: true,
      kind: 'success',
      detail: `领取${credit ?? '?'}积分` + (streak != null ? `，连续${streak}天` : ''),
      raw: data,
    };
  }

  if (checkedIn === false) return { ok: true, kind: 'pending', detail: '未签到', raw: data };
  return { ok: false, kind: 'unknown', raw: data };
}

// ---------- 主流程 ----------
(async () => {
  const t = now();

  const found = await findAnyTarget();
  if (!found.target) {
    const hint = EXPLICIT_PORT
      ? `请以 --remote-debugging-port=${PORT} 启动客户端后再执行。`
      : `请以 --remote-debugging-port=${DEFAULT_PORT} 启动客户端后再执行（scripts/setup-automation.ps1 可把它设为默认启动方式）。`;
    await bail(
      'port',
      `❌ 未找到可用的调试端口。\n   ${found.errors.join('\n   ')}\n   ${hint}`,
      found.errors.some((e) => e.includes('没有 WorkBuddy'))
        ? '端口被其他应用占用(未见WorkBuddy页面)'
        : '调试端口不可用(客户端需带调试参数启动)',
      2
    );
  }
  const { port: USED_PORT, target } = found;

  // 只打印标题与去掉 query 的 URL：完整 URL 里带 accountSnapshot（含 uid / 昵称等个人标识），不入日志
  const safeUrl = String(target.url || '').split('?')[0];
  console.log(`▶ 端口 ${USED_PORT} ｜ 目标: ${target.title || ''} ${safeUrl}`);
  if (!EXPLICIT_PORT && USED_PORT !== DEFAULT_PORT) {
    console.log(`  （提示：${DEFAULT_PORT} 未开放，回退到旧默认端口 ${USED_PORT}；下次带 --remote-debugging-port=${DEFAULT_PORT} 启动即可）`);
  }

  const cdp = new CDP(target.webSocketDebuggerUrl);
  try {
    await cdp.connect();
  } catch (err) {
    await bail('cdp', `❌ CDP 连接失败：${err.message}`, `CDP连接失败:${String(err.message).slice(0, 40)}`, 2);
  }

  try {
    // 1) 确认桥接入口
    const hasBridge = await cdp.evaluate(`typeof window.__wbInvoke`);
    if (hasBridge !== 'function') {
      await bail(
        'bridge',
        `❌ 未找到 __wbInvoke（实际类型: ${hasBridge}），客户端 preload 可能已变更。`,
        `桥接入口不可用(${hasBridge})`,
        4
      );
    }

    // 2) 查状态
    const statusRaw = await cdp.evaluate(
      `(async () => { try { return await window.__wbInvoke('auth:getCheckinStatus'); } catch (e) { return { __err: String(e && e.message || e) }; } })()`
    );
    if (SHOW_JSON) console.log('  getCheckinStatus ->', JSON.stringify(statusRaw));

    if (statusRaw && statusRaw.__err) {
      const msg = statusRaw.__err;
      const notLogin = /no active session|未登录/i.test(msg);
      await bail(
        notLogin ? 'login' : 'status',
        `❌ 查询状态失败：${msg}`,
        notLogin ? '未登录(需登录客户端)' : `查询异常:${msg.slice(0, 40)}`,
        notLogin ? 3 : 4
      );
    }

    const status = normalize(statusRaw);
    if (PROBE_ONLY) {
      console.log('=== 探针模式（未执行签到） ===');
      console.log('  状态:', JSON.stringify(statusRaw));
      cdp.close();
      process.exit(0);
    }

    if (status.kind === 'already') {
      console.log(`✅ 今日已签到 — ${status.detail}`);
      appendLog(`已签到 ${status.detail}`);
      appendHistoryRow(t.date, t.time, '已签到', status.detail);
      cdp.close();
      process.exit(0);
    }

    // 3) 执行签到
    const claimRaw = await cdp.evaluate(
      `(async () => { try { return await window.__wbInvoke('auth:claimDailyCheckin'); } catch (e) { return { __err: String(e && e.message || e) }; } })()`
    );
    if (SHOW_JSON) console.log('  claimDailyCheckin ->', JSON.stringify(claimRaw));

    if (claimRaw && claimRaw.__err) {
      await bail('api', `❌ 签到失败：${claimRaw.__err}`, String(claimRaw.__err).slice(0, 60), 4);
    }

    const claim = normalize(claimRaw);
    if (claim.ok && claim.kind === 'already') {
      console.log(`✅ 今日已签到 — ${claim.detail}`);
      appendLog(`已签到 ${claim.detail}`);
      appendHistoryRow(t.date, t.time, '已签到', claim.detail);
      cdp.close();
      process.exit(0);
    }
    if (claim.ok && (claim.kind === 'success' || claim.kind === 'pending')) {
      const detail = claim.kind === 'success' ? claim.detail : '签到已提交';
      console.log(`✅ 签到成功 — ${detail}`);
      appendLog(`成功 ${detail}`);
      appendHistoryRow(t.date, t.time, '成功', detail);
      cdp.close();
      process.exit(0);
    }

    await bail('unknown', `⚠️ 未知返回：${JSON.stringify(claimRaw)}`, JSON.stringify(claimRaw).slice(0, 60), 4);
  } catch (err) {
    await bail('exception', `❌ 执行异常：${err.message}`, `异常:${String(err.message).slice(0, 50)}`, 4);
  } finally {
    cdp.close();
    // 关闭 CDP 连接后短暂等待，避免日志写入竞争
    await sleep(50);
  }
})();
