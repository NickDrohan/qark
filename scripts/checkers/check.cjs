// qark syntax checker: reads [{"name","text"}] as json on stdin, compiles each text
// without running it, and prints [{"ok"} | {"ok":false,"line","col","msg"}] in order.
// with --serve [idle_seconds] it answers one json line per request line, and exits
// when stdin closes or when no request arrives for idle_seconds.
// Installed as check.cjs so Node always loads this helper as CommonJS even when the
// target workspace or an ancestor directory has package.json with "type": "module".
'use strict';
const vm = require('vm');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const WORKSPACE_ROOT = path.resolve(__dirname, '../..');
let seq = 0;

function lineCount(text) {
  const n = text.split('\n').length;
  return text.endsWith('\n') ? n - 1 : n;
}

function parseDiag(raw, text, lineOffset) {
  const lines = String(raw || '').split(/\r?\n/);
  const first = lines[0] || '';
  const m = /:(\d+)\s*$/.exec(first);
  let line = 0;
  if (m) {
    const rawLine = Number(m[1]) + (lineOffset || 0);
    line = Math.max(1, Math.min(rawLine, Math.max(1, lineCount(text))));
  }
  let col = 0;
  for (let i = 1; i < Math.min(lines.length, 6); i++) {
    const cm = /^(\s*)\^+\s*$/.exec(lines[i]);
    if (cm) {
      col = cm[1].length + 1;
      break;
    }
  }
  const errLine = lines.find((l) => /(SyntaxError|ReferenceError|TypeError|Error):/.test(l));
  const msg = errLine ? errLine.trim() : 'syntax error';
  return { ok: false, line, col, msg };
}

function isWorkspaceEsmFor(relName) {
  try {
    let dir = path.dirname(path.resolve(WORKSPACE_ROOT, relName || 'index.js'));
    for (let depth = 0; depth < 32; depth++) {
      const pkgPath = path.join(dir, 'package.json');
      if (fs.existsSync(pkgPath)) {
        const raw = fs.readFileSync(pkgPath, 'utf8');
        const pkg = JSON.parse(raw);
        return Boolean(pkg && pkg.type === 'module');
      }
      const parent = path.dirname(dir);
      if (!parent || parent === dir) break;
      dir = parent;
    }
  } catch (_) {
    // ignore unreadable or malformed package.json during package boundary walk
  }
  return false;
}

function checkModule(name, text, index) {
  seq += 1;
  const tmp = path.join(os.tmpdir(), 'qark-check-' + process.pid + '-' + index + '-' + seq + '.mjs');
  fs.writeFileSync(tmp, text);
  try {
    const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
    if (r.status === 0) return { ok: true };
    return parseDiag(r.stderr || r.stdout, text, 0);
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

function checkCommonJS(name, text) {
  try {
    new vm.Script(text, { filename: name });
    return { ok: true };
  } catch (e) {
    if (/Illegal return/.test(String(e && e.message))) {
      try {
        new vm.Script('(function (exports, require, module, __filename, __dirname) {\n' + text + '\n})', { filename: name });
        return { ok: true };
      } catch (e2) {
        return parseDiag(e2 && e2.stack, text, -1);
      }
    }
    return parseDiag(e && e.stack, text, 0);
  }
}

function check(name, source, index) {
  let text = source;
  if (text.startsWith('#!')) text = '//' + text.slice(2);
  if (/\.cjs$/i.test(name)) {
    return checkCommonJS(name, text);
  }
  if (/\.mjs$/i.test(name)) {
    return checkModule(name, text, index);
  }
  if (isWorkspaceEsmFor(name) || /^\s*(import\s*[\w{*'"]|export\s)/m.test(text)) {
    return checkModule(name, text, index);
  }
  return checkCommonJS(name, text);
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
