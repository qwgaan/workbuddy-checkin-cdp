// 定位 asar 内命中关键词的文件（按字节偏移反查）
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

const entries = [];
function walk(node, p) {
  if (!node.files) return;
  for (const k of Object.keys(node.files)) {
    const c = node.files[k];
    const np = p + '/' + k;
    if (c.files) walk(c, np);
    else if (c.size !== undefined && c.offset !== undefined) {
      entries.push({ path: np, offset: dataStart + Number(c.offset), size: Number(c.size) });
    }
  }
}
walk(header, '');
console.log('files in asar:', entries.length);

const keywords = process.argv.slice(2);
for (const kw of keywords) {
  const needle = Buffer.from(kw, 'utf8');
  const bufSize = 8 * 1024 * 1024;
  const stat = fs.statSync(ASAR);
  let pos = dataStart;
  const hits = new Map();
  while (pos < stat.size) {
    const len = Math.min(bufSize + needle.length, stat.size - pos);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, pos);
    let idx = buf.indexOf(needle);
    while (idx !== -1) {
      const abs = pos + idx;
      const e = entries.find(x => abs >= x.offset && abs < x.offset + x.size);
      if (e) hits.set(e.path, { size: e.size, off: e.offset, abs });
      idx = buf.indexOf(needle, idx + 1);
    }
    pos += bufSize;
  }
  console.log(`\n=== ${kw} ===  ${hits.size} file(s)`);
  for (const [p, v] of hits) console.log(`  ${p}  (size=${v.size}, abs=${v.abs})`);
}
fs.closeSync(fd);
