#!/usr/bin/env node
/**
 * probe-cdp.js — Phase 1 探针
 *
 * 作用：检测 WorkBuddy 桌面端是否开放了 CDP 调试端口，以及渲染进程 target
 *       是否可被命中。纯 Node 实现，零依赖（依赖 Node 22+ 内置 fetch）。
 *
 * 用法：
 *   node scripts/probe-cdp.js                     # 默认扫描 19222 / 19223
 *   node scripts/probe-cdp.js 19222 9333          # 自定义端口
 *   node scripts/probe-cdp.js 9222                # 旧默认端口需显式指定（易与其他调试端口撞车）
 *
 * 端口也可用环境变量覆盖：WB_CDP_PORT
 *
 * 退出码：0 = 找到可用调试端口；1 = 未找到（需按方案重启客户端）
 *
 * 安全：仅访问 127.0.0.1，不读取任何令牌或设备指纹；
 *       输出已去掉 URL 的 query（避免带出 accountSnapshot 里的个人标识）。
 */

const DEFAULT_CANDIDATES = [19222, 19223];
const ARG_PORTS = process.argv.slice(2).map(Number).filter(Boolean);
const ENV_PORT = Number(process.env.WB_CDP_PORT) || 0;
const CANDIDATES = ARG_PORTS.length ? ARG_PORTS : [...new Set([ENV_PORT, ...DEFAULT_CANDIDATES].filter(Boolean))];

async function fetchJson(url, timeoutMs = 2500) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) return { ok: false, status: res.status };
    return { ok: true, data: await res.json() };
  } catch (err) {
    return { ok: false, error: err.name === 'AbortError' ? 'timeout' : err.message };
  } finally {
    clearTimeout(timer);
  }
}

const line = (s = '') => console.log(s);

(async () => {
  line('=== WorkBuddy CDP 探针 ===');
  line(`扫描端口: ${CANDIDATES.join(', ')}`);
  line('');

  let found = null;

  for (const port of CANDIDATES) {
    const base = `http://127.0.0.1:${port}`;
    const ver = await fetchJson(`${base}/json/version`);

    if (!ver.ok) {
      line(`[端口 ${port}] 不可用 (${ver.status || ver.error})`);
      continue;
    }

    line(`[端口 ${port}] ✅ 调试端口已开放`);
    line(`  Browser : ${ver.data.Browser || '(未知)'}`);
    if (ver.data.webSocketDebuggerUrl) line(`  WS      : ${ver.data.webSocketDebuggerUrl}`);

    const list = await fetchJson(`${base}/json`);
    const pages = Array.isArray(list.data)
      ? list.data.filter((t) => t.type === 'page')
      : [];

    line(`  Targets : ${Array.isArray(list.data) ? list.data.length : 0} 个，其中 page ${pages.length} 个`);

    const target = pages.find((t) => /workbuddy|codebuddy|index/i.test(t.url || '')) || pages[0];
    if (target) {
      line(`  ▶ 主界面 target`);
      line(`    title : ${target.title || '(无)'}`);
      // 去掉 query：里面可能带 accountSnapshot（uid / 昵称等个人标识）
      line(`    url   : ${String(target.url || '(无)').split('?')[0]}`);
      line(`    ws    : ${target.webSocketDebuggerUrl || '(无)'}`);
      found = { port, target };
    } else {
      line('  ⚠️ 未找到 page 类型 target（界面可能尚未加载完成）');
    }
    line('');
  }

  line('=== 结论 ===');
  if (found) {
    line(`✅ 通过：端口 ${found.port} 可用，可进入验证项 3（调用 __wbInvoke）。`);
    line(`   下一步：node scripts/checkin-via-cdp.js --probe --port ${found.port}`);
    process.exit(0);
  } else {
    line('❌ 未通过：未发现调试端口。');
    line('   请按 docs/02-实施方案.md 的 Phase 1 前置操作，退出客户端后带参数重启：');
    line(`   WorkBuddy.exe --remote-debugging-port=${DEFAULT_CANDIDATES[0]}`);
    line('   （Windows 可先跑 scripts/setup-automation.ps1 把带参启动设为默认）');
    process.exit(1);
  }
})();
