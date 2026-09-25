// 列出 asar 内文件中所有 exposeInMainWorld 暴露的全局名
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
const e = map.get(process.argv[2]);
const buf = Buffer.alloc(e.size);
fs.readSync(fd, buf, 0, e.size, e.offset);
const s = buf.toString('utf8');
const names = new Set();
const re = /exposeInMainWorld\(\s*["'`]([^"'`]+)["'`]/g;
let m;
while ((m = re.exec(s))) names.add(m[1]);
console.log('exposed globals (' + names.size + '):');
console.log([...names].sort().join('\n'));
fs.closeSync(fd);
