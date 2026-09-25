/**
 * _resolve-asar.js — 定位 WorkBuddy 的 app.asar（供同目录分析工具复用）
 *
 * 解析优先级：--asar <路径>  >  环境变量 WB_ASAR  >  常见安装位置
 * 命中后会把 --asar <路径> 从 process.argv 里摘掉，调用方拿到的就是纯业务参数。
 *
 * 用法：
 *   const ASAR = require('./_resolve-asar');
 */

const fs = require('fs');
const path = require('path');

function buildCandidates() {
  const out = [];
  const argv = process.argv.slice(2);

  const i = argv.indexOf('--asar');
  if (i !== -1 && argv[i + 1]) {
    out.push(argv[i + 1]);
    process.argv.splice(process.argv.indexOf('--asar'), 2); // 摘掉，避免污染业务参数
  }

  if (process.env.WB_ASAR) out.push(process.env.WB_ASAR);

  const bases = [
    process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'Programs', 'WorkBuddy') : '',
    process.env.ProgramFiles ? path.join(process.env.ProgramFiles, 'WorkBuddy') : '',
    process.env['ProgramFiles(x86)'] ? path.join(process.env['ProgramFiles(x86)'], 'WorkBuddy') : '',
  ];
  for (const b of bases) {
    if (b) out.push(path.join(b, 'resources', 'app.asar'));
  }
  return out.filter(Boolean);
}

const hit = buildCandidates().find((p) => {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
});

if (!hit) {
  console.error('✖ 未找到 app.asar。');
  console.error('  请用 --asar <路径> 指定，或设置环境变量 WB_ASAR。');
  console.error('  典型位置：%LOCALAPPDATA%\\Programs\\WorkBuddy\\resources\\app.asar');
  process.exit(2);
}

module.exports = hit;
