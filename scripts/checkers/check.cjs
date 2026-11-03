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

function lineCount(text) {
  const n = text.split('\n').length;
  return text.endsWith('\n') ? n - 1 : n;
}

function normKey(p) {
  const resolved = path. normalize(path.resolve(p));
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
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

function isWorkspaceEsmFor(relName, wsRoot, pkgMap) {
  const baseRoot = wsRoot || WORKSPACE_ROOT;
  let dir = path.dirname(path.resolve(baseRoot, relName || 'index.js'));
  for (let depth = 0; depth < 32; depth++) {
    const pkgPath = path.join(dir, 'package.json');
    const key = normKey(pkgPath);
    if (pkgMap && pkgMap.has(key)) {
      const ov = pkgMap.get(key);
      if (!ov.deleted) {
        try {
          const pkg = JSON.parse(String(ov.text || ''));
          return Boolean(pkg && pkg.type === 'module');
        } catch (_) {
          return false;
        }
      }
    } else if (fs.existsSync(pkgPath)) {
      try {
        const raw = fs.readFileSync(pkgPath, 'utf8');
        const pkg = JSON.parse(raw);
        return Boolean(pkg && pkg.type === 'module');
      } catch (_) {
        return false;
      }
    }
    const parent = path.dirname(dir);
    if (!parent || parent === dir) break;
    dir = parent;
  }
  return false;
}

function checkModule(name, text) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'qark-esm-'));
  try {
    try {
      fs.chmodSync(tmpDir, 0o700);
    } catch (_) {}
    const tmpFile = path.join(tmpDir, 'candidate.mjs');
    fs.writeFileSync(tmpFile, text, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    const r = spawnSync(process.execPath, ['--check', tmpFile], { encoding: 'utf8' });
    if (r.status === 0) return { ok: true };
    return parseDiag(r.stderr || r.stdout, text, 0);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function checkCommonJS(name, text) {
  try {
    new vm.Script(
      '(function (exports, require, module, __filename, __dirname) {\n' + text + '\n});',
      { filename: name }
    );
    return { ok: true };
  } catch (e) {
    return parseDiag(e && e.stack, text, -1);
  }
}

function check(name, source, wsRoot, pkgMap) {
  let text = String(source || '');
  if (text.startsWith('#!')) text = '//' + text.slice(2);
  if (/\.cjs$/i.test(name)) {
    return checkCommonJS(name, text);
  }
  if (/\.mjs$/i.test(name)) {
    return checkModule(name, text);
  }
  if (isWorkspaceEsmFor(name, wsRoot, pkgMap)) {
    return checkModule(name, text);
  }
  return checkCommonJS(name, text);
}

function buildPkgMap(files, wsRoot) {
  const map = new Map();
  if (!Array.isArray(files) || files.length === 0) return map;
  const first = files[0];
  if (first && Array.isArray(first.packages)) {
    for (const p of first.packages) {
      if (p && typeof p.name === 'string') {
        const full = path.resolve(wsRoot, p.name);
        map.set(normKey(full), { deleted: Boolean(p.deleted), text: p.text || '' });
      }
    }
  }
  for (const f of files) {
    if (f && typeof f.name === 'string' && /(^|[\\/])package\.json$/i.test(f.name)) {
      const full = path.resolve(wsRoot, f.name);
      map.set(normKey(full), { deleted: Boolean(f.deleted), text: f.text || '' });
    }
  }
  return map;
}

function answer(raw) {
  const files = JSON.parse(raw);
  const wsRoot =
    Array.isArray(files) && files.length > 0 && files[0] && typeof files[0].root === 'string' && files[0].root
      ? path.resolve(files[0].root)
      : WORKSPACE_ROOT;
  const pkgMap = buildPkgMap(files, wsRoot);
  return JSON.stringify(files.map((f) => check(f.name, f.text, wsRoot, pkgMap)));
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
