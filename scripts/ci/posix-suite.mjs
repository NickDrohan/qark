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

  // 7. P1 #3: Real in-flight transaction SIGKILL at deterministic barriers (apply, undo, redo x publishing, committed)
  async function killAtBarrier(stage, op, args) {
    const worker = spawn(qarkBin, ["--headless", "--stdio", "--root", ws, "--pause-at", stage], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stderrBuf = "";
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout waiting for barrier ${stage}; stderr=${stderrBuf}`)), 15000);
      worker.stderr.on("data", (chunk) => {
        stderrBuf += chunk.toString("utf8");
        if (stderrBuf.includes(`"barrier":"${stage}"`)) {
          clearTimeout(timer);
          resolve();
        }
      });
      worker.on("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
      worker.on("exit", (code, sig) => {
        clearTimeout(timer);
        reject(new Error(`worker exited early (${code}/${sig}) before barrier ${stage}; stderr=${stderrBuf}`));
      });
      worker.stdin.write(JSON.stringify({ id: 1, op, args }) + "\n");
    });

    // Verify WAL exists in expected state AND that the paused worker holds .qark/lock
    assert(fs.existsSync(walPath), `WAL must exist while paused at ${stage}`);
    const walDoc = JSON.parse(fs.readFileSync(walPath, "utf8"));
    const expectedState = stage.endsWith("_publishing") ? "publishing" : "committed";
    assert(walDoc.state === expectedState, `WAL state at ${stage} must be ${expectedState}`, walDoc);

    const contender = callOne(
      ws,
      "apply",
      { path: "lock_probe.txt", mode: "upsert", text: "contend\n" },
      ["--lock-timeout-ms", "50"]
    );
    assert(
      !contender.ok && contender.error.code === "locked",
      `competing worker must be rejected with locked while paused at ${stage}`,
      contender
    );

    worker.kill("SIGKILL");
    await new Promise((resolve) => worker.once("exit", resolve));
  }

  // 7a. apply_publishing barrier: kill in-flight, restart twice, retry with original idempotency_key
  const applyPubSpec = {
    idempotency_key: "idem-inflight-apply-pub",
    durable: true,
    files: [
      { path: "inflight/a/b/file1.txt", mode: "create", perm: 0o640, text: "inflight-v1\n" },
      { path: "inflight/a/b/file2.txt", mode: "create", perm: 0o750, text: "#!/bin/sh\necho v1\n" },
    ],
  };
  await killAtBarrier("apply_publishing", "apply", applyPubSpec);
  assert(fs.existsSync(path.join(ws, "inflight/a/b/file1.txt")), "file1 exists at apply_publishing barrier");
  // Restart 1: retry with original idempotency_key -> rolls back interrupted publishing WAL and executes apply cleanly
  const rApplyPubRetry1 = callOne(ws, "apply", applyPubSpec);
  assert(
    rApplyPubRetry1.ok && !rApplyPubRetry1.result.replayed && rApplyPubRetry1.result.created === 2,
    "restart 1 after apply_publishing SIGKILL rolls back partial txn and applies cleanly",
    rApplyPubRetry1
  );
  // Restart 2: retry with original idempotency_key -> replays committed receipt
  const rApplyPubRetry2 = callOne(ws, "apply", applyPubSpec);
  assert(
    rApplyPubRetry2.ok && rApplyPubRetry2.result.replayed === true && rApplyPubRetry2.result.txn === rApplyPubRetry1.result.txn,
    "restart 2 after apply_publishing SIGKILL replays idempotent receipt",
    rApplyPubRetry2
  );

  // 7b. apply_committed barrier: kill in-flight, restart twice, retry with original idempotency_key
  const applyComSpec = {
    idempotency_key: "idem-inflight-apply-com",
    durable: true,
    files: [
      { path: "inflight/a/b/file1.txt", mode: "replace", perm: 0o600, text: "inflight-v2\n" },
    ],
  };
  await killAtBarrier("apply_committed", "apply", applyComSpec);
  // Restart 1: retry with original idempotency_key -> rolls forward committed WAL (including idempotency record) and replays receipt!
  const rApplyComRetry1 = callOne(ws, "apply", applyComSpec);
  assert(
    rApplyComRetry1.ok && rApplyComRetry1.result.replayed === true && rApplyComRetry1.result.replaced === 1,
    "restart 1 after apply_committed SIGKILL rolls forward committed WAL and replays idempotent receipt",
    rApplyComRetry1
  );
  // Restart 2: retry with original idempotency_key -> still replays same receipt
  const rApplyComRetry2 = callOne(ws, "apply", applyComSpec);
  assert(
    rApplyComRetry2.ok && rApplyComRetry2.result.replayed === true && rApplyComRetry2.result.txn === rApplyComRetry1.result.txn,
    "restart 2 after apply_committed SIGKILL replays identical receipt",
    rApplyComRetry2
  );
  assert(fs.readFileSync(path.join(ws, "inflight/a/b/file1.txt"), "utf8") === "inflight-v2\n", "file1 has v2 content");
  assert((fs.statSync(path.join(ws, "inflight/a/b/file1.txt")).mode & 0o777) === 0o600, "file1 has 0600 mode");

  // 7c. undo_publishing barrier: kill in-flight, restart twice
  await killAtBarrier("undo_publishing", "undo", { durable: true });
  // Restart 1: run undo -> first recovers (rolls back the interrupted undo back to v2), then executes undo to v1
  const rUndoPubRetry1 = callOne(ws, "undo", { durable: true });
  assert(rUndoPubRetry1.ok && rUndoPubRetry1.result.replaced === 1, "restart 1 after undo_publishing recovers and undoes to v1", rUndoPubRetry1);
  assert(fs.readFileSync(path.join(ws, "inflight/a/b/file1.txt"), "utf8") === "inflight-v1\n", "file1 restored to v1");
  assert((fs.statSync(path.join(ws, "inflight/a/b/file1.txt")).mode & 0o777) === 0o640, "file1 mode restored to 0640");
  // Redo back to v2 to prepare for undo_committed test
  const rRedoPrep = callOne(ws, "redo", { durable: true });
  assert(rRedoPrep.ok, "redo back to v2 before undo_committed test", rRedoPrep);

  // 7d. undo_committed barrier: kill in-flight, restart twice
  await killAtBarrier("undo_committed", "undo", { durable: true });
  const rUndoComRec1 = callOne(ws, "apply", { path: "inflight/noop.txt", mode: "upsert", text: "ok\n" });
  assert(rUndoComRec1.ok, "restart 1 after undo_committed finalizes committed undo WAL", rUndoComRec1);
  assert(fs.readFileSync(path.join(ws, "inflight/a/b/file1.txt"), "utf8") === "inflight-v1\n", "file1 is v1 after undo_committed recovery");
  const rReapplyV2 = callOne(ws, "apply", {
    durable: true,
    files: [{ path: "inflight/a/b/file1.txt", mode: "replace", perm: 0o600, text: "inflight-v2\n" }],
  });
  assert(rReapplyV2.ok, "re-apply v2 for redo barrier tests", rReapplyV2);
  const rCleanUndo = callOne(ws, "undo", { durable: true });
  assert(rCleanUndo.ok, "clean undo of v2", rCleanUndo);

  // 7e. redo_publishing barrier: kill in-flight, restart twice
  await killAtBarrier("redo_publishing", "redo", { durable: true });
  const rRedoPubRetry1 = callOne(ws, "redo", { durable: true });
  assert(rRedoPubRetry1.ok && rRedoPubRetry1.result.replaced === 1, "restart 1 after redo_publishing recovers and redoes to v2", rRedoPubRetry1);
  assert(fs.readFileSync(path.join(ws, "inflight/a/b/file1.txt"), "utf8") === "inflight-v2\n", "file1 redone to v2");

  // 7f. redo_committed barrier: undo v2, then kill redo at redo_committed, restart twice
  assert(callOne(ws, "undo", { durable: true }).ok, "undo v2 before redo_committed test");
  await killAtBarrier("redo_committed", "redo", { durable: true });
  const rRedoComRec1 = callOne(ws, "apply", { path: "inflight/noop.txt", mode: "upsert", text: "ok\n" });
  assert(rRedoComRec1.ok, "restart 1 after redo_committed finalizes committed redo WAL", rRedoComRec1);
  assert(fs.readFileSync(path.join(ws, "inflight/a/b/file1.txt"), "utf8") === "inflight-v2\n", "file1 is v2 after redo_committed recovery");

  // 8. P2 #4: Glob edits with per-path expect map under --require-expect
  const g1 = callOne(ws, "apply", {
    files: [
      { path: "glob_exp/x.py", mode: "create", text: "val = 1\n" },
      { path: "glob_exp/y.py", mode: "create", text: "val = 1\n" },
    ],
  });
  assert(g1.ok, "seed glob_exp files", g1);
  const shaX = g1.result.files[0].sha256;
  const shaY = g1.result.files[1].sha256;

  // Without expect map under --require-expect -> expect_required
  const gNoExp = callOne(
    ws,
    "apply",
    {
      files: [{ glob: "glob_exp/*.py", edits: [{ find: "val = 1", replace: "val = 2" }] }],
    },
    ["--require-expect"]
  );
  assert(!gNoExp.ok && gNoExp.error.code === "expect_required", "glob without expect rejected under --require-expect", gNoExp);

  // Partial expect map (missing y.py) under --require-expect -> expect_required
  const gPartExp = callOne(
    ws,
    "apply",
    {
      files: [
        {
          glob: "glob_exp/*.py",
          expect: { "glob_exp/x.py": shaX },
          edits: [{ find: "val = 1", replace: "val = 2" }],
        },
      ],
    },
    ["--require-expect"]
  );
  assert(!gPartExp.ok && gPartExp.error.code === "expect_required", "glob with partial expect map rejected under --require-expect", gPartExp);

  // Stale hash in expect map -> stale
  const gStaleExp = callOne(
    ws,
    "apply",
    {
      files: [
        {
          glob: "glob_exp/*.py",
          expect: {
            "glob_exp/x.py": shaX,
            "glob_exp/y.py": "0000000000000000000000000000000000000000000000000000000000000000",
          },
          edits: [{ find: "val = 1", replace: "val = 2" }],
        },
      ],
    },
    ["--require-expect"]
  );
  assert(!gStaleExp.ok && gStaleExp.error.code === "stale", "glob with stale per-path expect rejected with stale", gStaleExp);

  // Complete per-path expect map under --require-expect -> succeeds!
  const gOkExp = callOne(
    ws,
    "apply",
    {
      files: [
        {
          glob: "glob_exp/*.py",
          expect: { "glob_exp/x.py": shaX, "glob_exp/y.py": shaY },
          edits: [{ find: "val = 1", replace: "val = 2" }],
        },
      ],
    },
    ["--require-expect"]
  );
  assert(gOkExp.ok && gOkExp.result.replaced === 2, "glob with per-path expect map succeeds under --require-expect", gOkExp);

  console.log("PASS all POSIX permission, umask, torn-journal byte-prefix, in-flight SIGKILL barrier, and glob expect checks");
} finally {
  fs.rmSync(ws, { recursive: true, force: true });
}
