#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

process.umask(0o077);

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const qarkBin =
  process.env.QARK_BIN ||
  (fs.existsSync(path.join(repoRoot, "out/linux-x86_64/release/bin/qark"))
    ? path.join(repoRoot, "out/linux-x86_64/release/bin/qark")
    : path.join(repoRoot, "out/darwin-x86_64/release/bin/qark"));

if (!fs.existsSync(qarkBin)) {
  throw new Error(`qark binary not found at ${qarkBin}`);
}

if (typeof process.getuid === "function" && process.getuid() === 0) {
  throw new Error("posix-suite.mjs must run as a non-root user so mode 0000 is genuinely unreadable");
}

function assert(cond, msg, detail) {
  if (!cond) {
    const extra = detail !== undefined ? `\nDetail: ${JSON.stringify(detail, null, 2)}` : "";
    throw new Error(`FAIL: ${msg}${extra}`);
  }
}

function runRpcBatch(root, requests, extraFlags = []) {
  const input = requests.map((r) => JSON.stringify(r)).join("\n") + "\n";
  const res = spawnSync(qarkBin, ["--headless", "--stdio", "--root", root, ...extraFlags], {
    input,
    encoding: "utf8",
    timeout: 30000,
  });
  if (res.status !== 0) {
    throw new Error(`qark exited with ${res.status}: ${res.stderr}`);
  }
  const lines = res.stdout
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => JSON.parse(l));
  return lines;
}

function callOne(root, op, args, extraFlags = []) {
  const [reply] = runRpcBatch(root, [{ id: 1, op, args }], extraFlags);
  return reply;
}

const ws = fs.mkdtempSync(path.join(os.tmpdir(), "qark-posix-ci-"));
try {
  // 1. F03: Exact POSIX modes under restrictive umask(0o077)
  const modes = [
    ["m600.txt", 0o600],
    ["m640.txt", 0o640],
    ["m750.sh", 0o750],
    ["m740.sh", 0o740],
  ];
  for (const [name, mode] of modes) {
    const r = callOne(ws, "apply", {
      files: [{ path: name, mode: "upsert", perm: mode, text: "#!/bin/sh\necho ok\n" }],
      durable: true,
    });
    assert(r.ok && r.result.durable === true, `apply ${name} mode ${mode.toString(8)}`, r);
    const actual = fs.statSync(path.join(ws, name)).mode & 0o777;
    assert(
      actual === mode,
      `expected on-disk mode 0o${mode.toString(8)} for ${name} under umask 0077, got 0o${actual.toString(8)}`
    );
  }

  // 2. F03: make_stage_tree preserves exact perm in isolated {root} during validate
  const rStagePerm = callOne(ws, "apply", {
    files: [{ path: "m750_stage.sh", mode: "upsert", perm: 0o750, text: "#!/bin/sh\necho staged\n" }],
    validate: [
      process.execPath,
      "-e",
      "const fs=require('fs'), path=require('path'); const m=fs.statSync(path.join(process.argv[1], 'm750_stage.sh')).mode & 0o777; if (m !== 0o750) { console.error('got mode ' + m.toString(8)); process.exit(1); }",
      "{root}",
    ],
  });
  assert(rStagePerm.ok, "make_stage_tree preserves 0o750 in {root} staging tree", rStagePerm);

  // 3. F03 & F05: 0740 + executable:true -> 0751 on both same-content and changed-content, undo/redo restores mode, and external chmod blocks undo without force
  const r740Same = callOne(ws, "apply", {
    files: [{ path: "m740.sh", mode: "replace", executable: true, text: "#!/bin/sh\necho ok\n" }],
  });
  assert(r740Same.ok && r740Same.result.replaced === 1, "same-content 0740 + executable:true replaces mode", r740Same);
  assert(
    (fs.statSync(path.join(ws, "m740.sh")).mode & 0o777) === 0o751,
    "0740 + executable:true yields 0751"
  );

  const rUndo740 = callOne(ws, "undo", {});
  assert(rUndo740.ok, "undo 0751 -> 0740", rUndo740);
  assert(
    (fs.statSync(path.join(ws, "m740.sh")).mode & 0o777) === 0o740,
    "undo restored mode 0740"
  );

  const rRedo751 = callOne(ws, "redo", {});
  assert(rRedo751.ok, "redo 0740 -> 0751", rRedo751);
  assert(
    (fs.statSync(path.join(ws, "m740.sh")).mode & 0o777) === 0o751,
    "redo restored mode 0751"
  );

  // External chmod race before undo: undo without force must refuse with conflict(stale)
  fs.chmodSync(path.join(ws, "m740.sh"), 0o600);
  const rUndoChmodConflict = callOne(ws, "undo", {});
  assert(
    !rUndoChmodConflict.ok && rUndoChmodConflict.error.code === "conflict",
    "external chmod causes undo without force to fail closed with conflict",
    rUndoChmodConflict
  );
  assert(
    (fs.statSync(path.join(ws, "m740.sh")).mode & 0o777) === 0o600,
    "external mode 0600 was not clobbered by refused undo"
  );
  // Restore mode 0751 so undo stack stays clean
  fs.chmodSync(path.join(ws, "m740.sh"), 0o751);

  // 4. F01: Mode 0000 file creation and non-mutating conflict(path_unreadable) on dry_run / apply / read
  const rZeroCreate = callOne(ws, "apply", {
    files: [{ path: "zero.txt", mode: "create", perm: 0, text: "secret\n" }],
  });
  assert(rZeroCreate.ok, "create mode 0000 file", rZeroCreate);
  const zeroPath = path.join(ws, "zero.txt");
  assert((fs.statSync(zeroPath).mode & 0o777) === 0, "zero.txt has mode 0000 on disk");

  const rZeroDry = callOne(ws, "apply", {
    path: "zero.txt",
    mode: "upsert",
    dry_run: true,
    text: "overwritten\n",
  });
  assert(
    rZeroDry.ok && rZeroDry.result.ready === false && rZeroDry.result.files[0].reason === "path_unreadable",
    "dry_run on 0000 file reports conflict(path_unreadable)",
    rZeroDry
  );
  assert(
    (fs.statSync(zeroPath).mode & 0o777) === 0,
    "dry_run did not widen permissions on 0000 file"
  );

  const rZeroLive = callOne(ws, "apply", {
    path: "zero.txt",
    mode: "upsert",
    text: "overwritten\n",
  });
  assert(
    !rZeroLive.ok && rZeroLive.error.code === "conflict" && rZeroLive.error.files[0].reason === "path_unreadable",
    "live apply on 0000 file fails closed with conflict(path_unreadable)",
    rZeroLive
  );
  assert(
    (fs.statSync(zeroPath).mode & 0o777) === 0,
    "live apply did not widen permissions on 0000 file"
  );
  fs.unlinkSync(zeroPath);

  // 5. F04: Exhaustive byte-by-byte torn-journal prefix repair & strict schema validation
  const journalPath = path.join(ws, ".qark/journal.ndjson");
  const walPath = path.join(ws, ".qark/wal.json");
  const baseJournal = fs.readFileSync(journalPath, "utf8");
  const latestTxn = fs.readFileSync(path.join(ws, ".qark/undo/latest"), "utf8").trim();
  const bodyBytes = Buffer.from("torn-body\n", "utf8");
  const bodySha = crypto.createHash("sha256").update(bodyBytes).digest("hex");
  const tornTxn = "abcdef0123456789";
  const fullJLine = JSON.stringify({
    v: 2,
    event: "transaction.committed",
    ts_ms: 1700000000000,
    txn: tornTxn,
    spec_sha256: bodySha,
    check_policy: "strict",
    validation_complete: true,
    created: 1,
    replaced: 0,
    deleted: 0,
    files: [{ path: "torn_target.txt", status: "created", sha256: bodySha }],
  });
  const fullJBuf = Buffer.from(fullJLine, "utf8");

  fs.writeFileSync(path.join(ws, "torn_target.txt"), bodyBytes, { mode: 0o644 });
  fs.chmodSync(path.join(ws, "torn_target.txt"), 0o644);
  fs.writeFileSync(
    path.join(ws, `.qark/undo/${tornTxn}.json`),
    JSON.stringify({
      v: 1,
      txn: tornTxn,
      prev_txn: latestTxn,
      spec_sha256: bodySha,
      files: [
        {
          path: "torn_target.txt",
          status: "created",
          existed: false,
          sha256: bodySha,
          target_perm: 0o644,
          published_perm: 0o644,
          has_target_perm: true,
          new_text: "torn-body\n",
        },
      ],
    }),
    "utf8"
  );
  const committedWal = JSON.stringify({
    v: 1,
    op: "apply",
    state: "committed",
    durable: true,
    txn: tornTxn,
    has_latest: true,
    latest_txn: tornTxn,
    journal_line: fullJLine + "\n",
  });

  for (let cut = 1; cut < fullJBuf.length; cut++) {
    const prefix = fullJBuf.subarray(0, cut);
    fs.writeFileSync(journalPath, Buffer.concat([Buffer.from(baseJournal, "utf8"), prefix]));
    fs.writeFileSync(walPath, committedWal, "utf8");
    const rRec = callOne(ws, "apply", { path: "probe_after_torn.txt", mode: "upsert", text: "ok\n" });
    assert(rRec.ok, `torn journal prefix cut=${cut}/${fullJBuf.length} recovered cleanly`, rRec);
    const jLines = fs
      .readFileSync(journalPath, "utf8")
      .trim()
      .split("\n")
      .filter((l) => l.includes(tornTxn));
    assert(jLines.length === 1 && jLines[0] === fullJLine, `repaired journal line at cut=${cut}`);
  }

  // Non-prefix torn line containing txn needle must fail closed
  fs.writeFileSync(journalPath, `${baseJournal}{"not_a_prefix":1,"txn":"${tornTxn}"`);
  fs.writeFileSync(walPath, committedWal, "utf8");
  const rBadTail = callOne(ws, "apply", { path: "probe_after_torn.txt", mode: "upsert", text: "no\n" });
  assert(!rBadTail.ok && rBadTail.error.code === "recovery_required", "non-prefix tail fails closed", rBadTail);

  // Restore clean journal
  fs.writeFileSync(journalPath, baseJournal + fullJLine + "\n", "utf8");
  fs.rmSync(walPath, { force: true });

  // 6. Real SIGKILL crash recovery during active worker session & publishing WAL rollback
  const pubTxn = "fedcba9876543210";
  const partialPath = path.join(ws, "sigkill_partial.txt");
  const partialBytes = Buffer.from("partial-write\n", "utf8");
  const partialSha = crypto.createHash("sha256").update(partialBytes).digest("hex");
  fs.writeFileSync(partialPath, partialBytes, { mode: 0o640 });
  fs.chmodSync(partialPath, 0o640);
  fs.writeFileSync(
    path.join(ws, `.qark/undo/${pubTxn}.json`),
    JSON.stringify({
      v: 1,
      txn: pubTxn,
      prev_txn: tornTxn,
      spec_sha256: partialSha,
      files: [
        {
          path: "sigkill_partial.txt",
          status: "created",
          existed: false,
          sha256: partialSha,
          target_perm: 0o640,
          published_perm: 0o640,
          has_target_perm: true,
          new_text: "partial-write\n",
        },
      ],
    }),
    "utf8"
  );
  fs.writeFileSync(
    walPath,
    JSON.stringify({
      v: 1,
      op: "apply",
      state: "publishing",
      durable: true,
      txn: pubTxn,
      keep_snapshot: false,
    }),
    "utf8"
  );

  // Spawn a worker, send session.info, SIGKILL it, then run apply on a new worker to verify lock release + WAL rollback
  const child = spawn(qarkBin, ["--headless", "--stdio", "--root", ws], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  await new Promise((resolve, reject) => {
    child.stdout.once("data", () => {
      child.kill("SIGKILL");
      resolve();
    });
    child.on("error", reject);
    child.stdin.write(JSON.stringify({ id: 1, op: "session.info", args: {} }) + "\n");
  });
  await new Promise((resolve) => child.once("exit", resolve));

  const rAfterKill = callOne(ws, "apply", {
    path: "recovered_after_sigkill.txt",
    mode: "create",
    durable: true,
    text: "recovered\n",
  });
  assert(rAfterKill.ok, "fresh worker acquires lock and rolls back publishing WAL after SIGKILL", rAfterKill);
  assert(!fs.existsSync(partialPath), "publishing WAL created file was rolled back");
  assert(!fs.existsSync(walPath), "WAL was cleared after recovery");

  console.log("PASS all POSIX permission, umask, torn-journal byte-prefix, and SIGKILL recovery checks");
} finally {
  fs.rmSync(ws, { recursive: true, force: true });
}
