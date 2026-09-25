// 从 asar 内指定文件提取关键词上下文
const fs = require('fs');
const ASAR = require('./_resolve-asar');
const fd = fs.openSync(ASAR, 'r');
const head = Buffer.alloc(16);
fs.readSync(fd, head, 0, 16, 0);
const headerSize = head.readUInt32LE(12);
const hbuf = Buffer.alloc(headerSize);
fs.readSync(fd, hbuf, 0, headerSize, 16);
const header = JSON.parse(hbuf.toString('utf8'));
const dataStart = 16 + headerSize;

const map = new Map();
function walk(node, p) {
  if (!node.files) return;
  for (const k of Object.keys(node.files)) {
    const c = node.files[k];
    const np = p + '/' + k;
    if (c.files) walk(c, np);
    else if (c.size !== undefined && c.offset !== undefined) map.set(np, { offset: dataStart + Number(c.offset), size: Number(c.size) });
  }
}
walk(header, '');

const target = process.argv[2];
const kw = process.argv[3];
const radius = parseInt(process.argv[4] || '350', 10);
const maxHits = parseInt(process.argv[5] || '6', 10);

const e = map.get(target);
if (!e) { console.log('file not found', target); process.exit(1); }
const buf = Buffer.alloc(e.size);
fs.readSync(fd, buf, 0, e.size, e.offset);
const needle = Buffer.from(kw, 'utf8');
let idx = buf.indexOf(needle), n = 0;
while (idx !== -1 && n < maxHits) {
  const s = Math.max(0, idx - radius), en = Math.min(buf.length, idx + needle.length + radius);
  console.log(`\n----- hit ${n + 1} @ ${idx} -----`);
  console.log(buf.slice(s, en).toString('utf8'));
  idx = buf.indexOf(needle, idx + needle.length);
  n++;
}
if (n === 0) console.log('no hit in ' + target);
fs.closeSync(fd);
