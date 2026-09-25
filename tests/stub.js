// stub.js — 通过 node --require 预加载，拦截 fetch 与 WebSocket，
// 用固定应答驱动 checkin-via-cdp.js 的全部关键路径（不接触真实客户端）。
//
// 场景（MOCK_SCENARIO）：
//   already      — 今日已签到（幂等路径）
//   notchecked   — 未签到 → 执行签到成功
//   notlogin     — 未登录
//   nobridge     — 页面里没有 __wbInvoke
//   port         — 所有调试端口都不通
//   portfallback — 19222 不通、其他端口通（验证自动回退）
//   otherpage    — 端口开着，但上面跑的是别的应用（验证不会误连）
const SCENARIO = process.env.MOCK_SCENARIO || 'already';

const STATUS_NOT_CHECKED = {
  active: true,
  today_checked_in: false,
  streak_days: 9,
  daily_credit: 100,
  today_credit: 100,
  total_credits: 900,
};
const STATUS_CHECKED = { ...STATUS_NOT_CHECKED, today_checked_in: true, streak_days: 10 };
// 真实客户端签到接口的返回（注意字段是 credit，不是 daily_credit）
const CLAIM_OK = { credit: 100, streak_days: 10, is_streak_day: false };

// 用于验证「个人标识不落日志」：URL 里故意塞一个可识别的假 uid
const SNAPSHOT_MARKER = 'MOCK_SECRET_UID';

const origFetch = globalThis.fetch;

globalThis.fetch = async (url, opts) => {
  const u = String(url);

  if (u.includes('wxpusher')) {
    return { ok: true, status: 200, text: async () => '{"code":1000}', json: async () => ({ code: 1000 }) };
  }

  if (SCENARIO === 'port') {
    throw new Error('fetch failed');
  }
  if (SCENARIO === 'portfallback' && u.includes(':19222')) {
    throw new Error('fetch failed');
  }

  if (u.includes('/json')) {
    // otherpage：模拟该端口被浏览器等别的应用占用
    const pageUrl =
      SCENARIO === 'otherpage'
        ? 'http://localhost:8080/index.html?accountSnapshot=' + SNAPSHOT_MARKER
        : `file:///tmp/workbuddy/renderer/index.html?accountSnapshot=${SNAPSHOT_MARKER}`;
    return {
      ok: true,
      status: 200,
      json: async () => [
        {
          type: 'page',
          title: SCENARIO === 'otherpage' ? 'Some Other App' : 'WorkBuddy',
          url: pageUrl,
          webSocketDebuggerUrl: 'ws://127.0.0.1:9999/devtools/page/MOCK',
        },
      ],
    };
  }

  return origFetch(url, opts);
};

class MockWebSocket {
  constructor() {
    this.handlers = {};
    setImmediate(() => this._emit('open', {}));
  }
  addEventListener(type, fn) {
    (this.handlers[type] = this.handlers[type] || []).push(fn);
  }
  removeEventListener(type, fn) {
    this.handlers[type] = (this.handlers[type] || []).filter((f) => f !== fn);
  }
  _emit(type, ev) {
    for (const fn of this.handlers[type] || []) fn(ev);
  }
  send(payload) {
    const req = JSON.parse(payload);
    const expr = req.params && req.params.expression ? req.params.expression : '';
    let value;
    if (expr.includes('typeof window.__wbInvoke')) {
      value = SCENARIO === 'nobridge' ? 'undefined' : 'function';
    } else if (expr.includes('getCheckinStatus')) {
      value =
        SCENARIO === 'notlogin'
          ? { __err: 'claimDailyCheckin: no active session' }
          : SCENARIO === 'already'
            ? STATUS_CHECKED
            : STATUS_NOT_CHECKED;
    } else if (expr.includes('claimDailyCheckin')) {
      value = CLAIM_OK;
    } else {
      value = null;
    }
    const result = { id: req.id, result: { result: { value } } };
    setImmediate(() => this._emit('message', { data: JSON.stringify(result) }));
  }
  close() {
    this._emit('close', {});
  }
}

globalThis.WebSocket = MockWebSocket;
