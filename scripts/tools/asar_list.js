// 列出 asar 内某目录的文件
const fs = require('fs');
const ASAR = require('./_resolve-asar');
const fd = fs.openSync(ASAR, 'r');
const head = Buffer.alloc(16);
fs.readSync(fd, head, 0, 16, 0);
const headerSize = head.readUInt32LE(12);
const hbuf = Buffer.alloc(headerSize);
fs.readSync(fd, hbuf, 0, headerSize, 16);
const header = JSON.parse(hbuf.toString('utf8'));
const prefix = process.argv[2] || '';
let out = [];
function walk(node, p) {
  if (!node.files) return;
  for (const k of Object.keys(node.files)) {
    const c = node.files[k];
    const np = p + '/' + k;
    if (c.files) walk(c, np);
    else out.push(`${np}  ${c.size}`);
  }
}
walk(header, '');
out = out.filter(x => x.startsWith(prefix));
console.log(out.join('\n'));
console.log('total', out.length);
fs.closeSync(fd);
