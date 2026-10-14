// qark syntax checker: reads [{"name","text"}] as json on stdin, compiles each text
// without running it, and prints [{"ok"} | {"ok":false,"line","col","msg"}] in order.
// with --serve [idle_seconds] it answers one json line per request line, and exits
// when stdin closes or when no request arrives for idle_seconds.
'use strict';
const vm = require('vm');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

function lineCount(text) {
  const n = text.split('\n').length;
  return text.endsWith('\n') ? n - 1 : n;
}

function lineOf(stack, text) {
  const first = String(stack || '').split('\n')[0];
  const m = /:(\d+)$/.exec(first);
  if (!m) return 0;
  return Math.max(1, Math.min(Number(m[1]), lineCount(text)));
}

function checkModule(name, text, index) {
  const tmp = path.join(os.tmpdir(), 'qark-check-' + process.pid + '-' + index + '.mjs');
  fs.writeFileSync(tmp, text);
  try {
    const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
    if (r.status === 0) return { ok: true };
    const lines = String(r.stderr || '').split('\n');
    const m = /:(\d+)\s*$/.exec(lines[0] || '');
    const msg = lines.find((l) => /Error/.test(l)) || 'syntax error';
    return { ok: false, line: m ? Math.min(Number(m[1]), lineCount(text)) : 0, col: 0, msg: msg.trim() };
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

function check(name, source, index) {
  let text = source;
  if (text.startsWith('#!')) text = '//' + text.slice(2);
  if (/\.mjs$/i.test(name) || /^\s*(import\s*[\w{*'"]|export\s)/m.test(text)) return checkModule(name, text, index);
  try {
    new vm.Script(text, { filename: name });
    return { ok: true };
  } catch (e) {
    if (/Illegal return/.test(String(e && e.message))) {
      try {
        new vm.Script('(function (exports, require, module, __filename, __dirname) {' + text + '\n})', { filename: name });
        return { ok: true };
      } catch (e2) {
        return { ok: false, line: lineOf(e2.stack, text), col: 0, msg: String(e2.message || e2) };
      }
    }
    return { ok: false, line: lineOf(e && e.stack, text), col: 0, msg: String(e && e.message ? e.message : e) };
  }
}

function answer(raw) {
  const files = JSON.parse(raw);
  return JSON.stringify(files.map((f, i) => check(f.name, f.text, i)));
}

const serveAt = process.argv.indexOf('--serve');
if (serveAt >= 0) {
  const idle = Number(process.argv[serveAt + 1]) || 0;
  let timer = null;
  const arm = () => {
    if (idle > 0) {
      timer = setTimeout(() => process.exit(0), idle * 1000);
      timer.unref();
    }
  };
  const rl = require('readline').createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('line', (line) => {
    clearTimeout(timer);
    if (line.trim()) process.stdout.write(answer(line) + '\n');
    arm();
  });
  rl.on('close', () => process.exit(0));
  arm();
} else {
  const chunks = [];
  process.stdin.on('data', (c) => chunks.push(c));
  process.stdin.on('end', () => process.stdout.write(answer(Buffer.concat(chunks).toString('utf8'))));
}
