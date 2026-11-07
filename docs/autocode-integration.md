# AutoCode & Agent Editor Integration Guide

This document defines the integration contract between **Qark** (`>= 0.3.0`, protocol `2`) and agent-driven code editors or orchestrators such as **AutoCode**.

---

## 1. Validation Completeness & Fail-Closed Checker Contract

### 1.1 Workspace-Independent Node Checker (`.cjs`)

Qark installs its embedded Node syntax checker as `.qark/checkers/check.cjs`. Because the helper uses the `.cjs` extension, Node always loads the checker itself as CommonJS—even when the target workspace (or an ancestor directory above a nested repository) has a `package.json` with `"type": "module"`.

Each candidate file's **own** module semantics remain strictly isolated from the helper's execution format:

| Candidate File | How Qark Validates Syntax |
| --- | --- |
| `*.mjs` | Checked with `node --check` on an isolated `.mjs` candidate, catching both ES module syntax errors and duplicate lexical (`let`/`const`) declarations. |
| `*.cjs` | Parsed inside the exact CommonJS wrapper `(function (exports, require, module, __filename, __dirname) { ... })` via `vm.Script`, rejecting ES module `import`/`export` syntax and wrapper parameter redeclarations (`const require = ...`). |
| `*.js` | Walks upward from the candidate file's directory to the nearest `package.json` (applying in-transaction `package.json` creates/edits/deletions first). Rejects malformed `package.json` files, validates `"type": "module"` as ES module, validates `"type": "commonjs"` as strict CommonJS, and validates untyped `.js` files using the host Node runtime's typeless `.js` rules. |

### 1.2 Source Invalidity vs. Checker Infrastructure Failure

For any file with a recognized, configured checker (`python`, `node`, `powershell`, `bash`, `json`, `toml`, or `.qark/checks.json`), Qark **fails closed by default**:

| Condition | Top-Level Error `code` | Per-File `check` | `ready` (dry run) | `validation_complete` | Publication |
| --- | --- | --- | --- | --- | --- |
| All checked files valid | *(none — `ok: true`)* | `"ok"` | `true` | `true` (when no files skipped/unchecked) | Allowed |
| Candidate source has syntax error | `"check_failed"` | `"failed"` | `false` | `false` | **Blocked** (whole transaction) |
| Checker crashes, times out, returns non-JSON, or returns wrong item count | `"checker_error"` | `"error"` | `false` | `false` | **Blocked** (whole transaction unless `"check": "permissive"`) |
| Language runtime not installed on host | `"check_unavailable"` (under `"check": "required"`) | `"skipped"` | `false` if `"required"`, `true` if `"strict"` | `false` | Blocked under `"required"`; allowed under `"strict"` with `validation_complete: false` |
| Unsupported extension (e.g. `.txt`, `.md`) | *(none)* | `"none"` | `true` | `false` | Allowed (`checks.unchecked > 0`) |

### 1.3 Check Policies (`"check"`)

Top-level `"check"` in `apply` / `qark_apply` / `qark_edit` accepts:

- `true` or `"strict"` *(default)*: Fail closed on any syntax error (`check_failed`) **or** checker infrastructure failure (`checker_error`). Missing host runtimes mark affected files `skipped` and set `validation_complete: false`.
- `"required"`: Fail closed on syntax errors, checker infrastructure failures, **and** missing runtimes (`check_unavailable`).
- `"permissive"`: Explicit opt-in that allows publication when a checker crashes (`check: "error"`), recording `"check_policy": "permissive"` and `"validation_complete": false` in the receipt. Syntax errors (`check: "failed"`) still block publication.
- `false` or `"off"`: Disable syntax checking (`"check_policy": "off"`, `"validation_complete": false`).

### 1.4 Receipt Validation Summary & Checker Diagnostics

Every `apply` receipt includes top-level validation completeness fields:

```json
{
  "txn": "a70d17f49f9a9f4b",
  "dry_run": false,
  "check_policy": "strict",
  "validation_complete": true,
  "checks": {
    "ok": 2,
    "failed": 0,
    "error": 0,
    "skipped": 0,
    "unchecked": 0
  }
}
```

When a checker crashes, times out, or emits unparseable output, Qark returns `code: "checker_error"` with bounded, sanitized `checker_diagnostics`:

```json
{
  "id": 1,
  "ok": false,
  "error": {
    "code": "checker_error",
    "message": "a language checker crashed or returned an invalid response; nothing was written",
    "check_policy": "strict",
    "validation_complete": false,
    "checks": {
      "ok": 1,
      "failed": 0,
      "error": 1,
      "skipped": 0,
      "unchecked": 0
    },
    "checker_diagnostics": {
      "category": "crash",
      "lang": "node",
      "executable": "C:\\Program Files\\nodejs\\node.exe",
      "exit_code": 1,
      "message": "Simulated checker crash",
      "stderr": "Simulated checker crash",
      "affected_files": ["src/app.js"]
    },
    "files": [
      {
        "path": "src/app.js",
        "status": "would_create",
        "lang": "node",
        "check": "error",
        "check_category": "crash",
        "check_executable": "C:\\Program Files\\nodejs\\node.exe",
        "check_exit_code": 1,
        "check_stderr": "Error: custom checker crash",
        "check_message": "the checker exited with a non-zero status"
      }
    ]
  }
}
```

> **Atomicity Guarantee:** If a transaction batches `config.json` (valid JSON) with `src/app.js` (invalid JS or crashed JS checker), **neither** file is written to disk.

---

## 2. Reference Persistent-Session Client (Node.js)

Below is a complete, zero-dependency Node.js reference client demonstrating capability discovery, symbol outline/span inspection, hash-pinned dry run with `validation_complete` verification, atomic apply, receipt consumption, and persistent undo.

```js
import { spawn } from "node:child_process";
import { once } from "node:events";
import readline from "node:readline";

export class QarkSession {
  constructor(qarkBinOrOptions, workspaceRoot, options = {}) {
    if (typeof qarkBinOrOptions === "object" && qarkBinOrOptions !== null) {
      options = qarkBinOrOptions;
      workspaceRoot = options.root || options.workspaceRoot;
      qarkBinOrOptions = options.bin || options.qarkBin || "qark";
    }
    const qarkBin = qarkBinOrOptions;
    const extraArgs = Array.isArray(options.args) ? options.args : [];
    this.defaultTimeoutMs = options.timeoutMs ?? 30000;
    this.maxStderrBytes = options.maxStderrBytes ?? 8192;
    this.maxPending = options.maxPending ?? 1024;
    this.maxQueuedBytes = options.maxQueuedBytes ?? 32 * 1024 * 1024;
    this.stderrBuf = "";
    this.closed = false;
    this.exitError = null;
    this.nextId = 1;
    this.pending = new Map();
    this._writeQueue = [];
    this._queuedBytes = 0;
    this._draining = false;

    const isNodeHost =
      /(^|[\\/])node(\.exe)?$/i.test(String(qarkBin)) &&
      extraArgs.length > 0 &&
      /\.(m|c)?js$/i.test(String(extraArgs[0]));
    const spawnArgs = isNodeHost
      ? [extraArgs[0], "--headless", "--stdio", "--root", workspaceRoot, ...extraArgs.slice(1)]
      : ["--headless", "--stdio", "--root", workspaceRoot, ...extraArgs];

    this.proc = spawn(qarkBin, spawnArgs, { stdio: ["pipe", "pipe", "pipe"] });

    this.proc.stdin.on("error", () => {
      // Handled via write callback and process exit/error listeners.
    });

    this.proc.stderr.setEncoding("utf8");
    this.proc.stderr.on("data", (chunk) => {
      this.stderrBuf += chunk;
      if (this.stderrBuf.length > this.maxStderrBytes) {
        this.stderrBuf = this.stderrBuf.slice(-this.maxStderrBytes);
      }
    });

    this.rl = readline.createInterface({ input: this.proc.stdout });
    this.rl.on("line", (line) => {
      if (!line.trim()) return;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (err) {
        const parseErr = new Error(`Malformed JSON from Qark worker: ${err.message}`);
        parseErr.code = "QARK_BAD_JSON";
        this._failAll(parseErr);
        return;
      }
      const hasValidBody =
        msg !== null &&
        typeof msg === "object" &&
        !Array.isArray(msg) &&
        (msg.ok === true
          ? Object.prototype.hasOwnProperty.call(msg, "result") && msg.result !== undefined
          : msg.ok === false &&
            msg.error !== null &&
            typeof msg.error === "object" &&
            !Array.isArray(msg.error));
      if (
        msg === null ||
        typeof msg !== "object" ||
        Array.isArray(msg) ||
        (typeof msg.id !== "number" && typeof msg.id !== "string") ||
        typeof msg.ok !== "boolean" ||
        !hasValidBody
      ) {
        const protoErr = new Error("Malformed protocol envelope from Qark worker");
        protoErr.code = "QARK_BAD_PROTOCOL";
        this._failAll(protoErr);
        return;
      }
      const entry = this.pending.get(msg.id);
      if (entry) {
        this.pending.delete(msg.id);
        clearTimeout(entry.timer);
        entry.resolve(msg);
      }
    });

    this.proc.on("error", (err) => {
      const procErr = new Error(`Qark worker process error: ${err.message}`);
      procErr.code = "QARK_PROCESS_ERROR";
      this._failAll(procErr);
    });

    this.proc.on("exit", (code, signal) => {
      const finishExit = () => {
        const detail = this.stderrBuf.trim()
          ? ` (stderr: ${this.stderrBuf.trim()})`
          : "";
        const exitErr = new Error(
          `Qark worker exited before replying (code=${code}, signal=${signal})${detail}`
        );
        exitErr.code = "QARK_PROCESS_EXITED";
        this._failAll(exitErr);
      };
      const t = setTimeout(finishExit, 50);
      t.unref?.();
      this.rl.once("close", () => {
        clearTimeout(t);
        finishExit();
      });
    });

    this.proc.on("close", (code, signal) => {
      setImmediate(() => {
        const detail = this.stderrBuf.trim()
          ? ` (stderr: ${this.stderrBuf.trim()})`
          : "";
        const closeErr = new Error(
          `Qark worker stream closed (code=${code}, signal=${signal})${detail}`
        );
        closeErr.code = "QARK_PROCESS_EXITED";
        this._failAll(closeErr);
      });
    });
  }

  _failAll(err) {
    if (!this.exitError) {
      this.exitError = err;
    }
    this.closed = true;
    this._writeQueue.length = 0;
    this._queuedBytes = 0;
    for (const [id, entry] of this.pending.entries()) {
      this.pending.delete(id);
      clearTimeout(entry.timer);
      entry.reject(this.exitError);
    }
  }

  async _drainQueue() {
    if (this._draining) return;
    this._draining = true;
    try {
      while (this._writeQueue.length > 0 && !this.closed && this.proc.exitCode === null) {
        const item = this._writeQueue.shift();
        this._queuedBytes = Math.max(0, this._queuedBytes - item.bytes);
        const entry = this.pending.get(item.id);
        if (!entry) continue;
        entry.sent = true;
        const flushed = this.proc.stdin.write(item.payload, "utf8", (writeErr) => {
          if (writeErr && this.pending.has(item.id)) {
            this.pending.delete(item.id);
            clearTimeout(entry.timer);
            const err = new Error(`Failed to write to Qark worker stdin: ${writeErr.message}`);
            err.code = "QARK_WRITE_ERROR";
            entry.reject(err);
          }
        });
        if (!flushed && !this.closed && this.proc.exitCode === null) {
          await new Promise((resolveWait) => {
            const cleanup = () => {
              this.proc.stdin.removeListener("drain", onDone);
              this.proc.stdin.removeListener("close", onDone);
              this.proc.removeListener("exit", onDone);
              this.proc.removeListener("close", onDone);
            };
            const onDone = () => {
              cleanup();
              resolveWait();
            };
            this.proc.stdin.once("drain", onDone);
            this.proc.stdin.once("close", onDone);
            this.proc.once("exit", onDone);
            this.proc.once("close", onDone);
          });
        }
      }
    } finally {
      this._draining = false;
    }
  }

  async request(op, args = {}, timeoutMs = this.defaultTimeoutMs) {
    return this.call(op, args, timeoutMs);
  }

  async info(timeoutMs = this.defaultTimeoutMs) {
    const res = await this.call("session.info", {}, timeoutMs);
    return res.result || res;
  }

  async call(op, args = {}, timeoutMs = this.defaultTimeoutMs) {
    if (this.closed || this.exitError) {
      const closedErr = this.exitError || new Error("QarkSession is closed");
      if (!closedErr.code) closedErr.code = "QARK_SESSION_CLOSED";
      throw closedErr;
    }
    const id = this.nextId++;
    const payload = JSON.stringify({ id, op, args }) + "\n";
    const bytes = Buffer.byteLength(payload, "utf8");
    if (this.pending.size >= this.maxPending || this._queuedBytes + bytes > this.maxQueuedBytes) {
      const queueErr = new Error(
        `QarkSession queue limit (${this.maxPending} requests / ${this.maxQueuedBytes} bytes) exceeded`
      );
      queueErr.code = "QARK_QUEUE_FULL";
      throw queueErr;
    }

    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, timer: null, sent: false };
      entry.timer =
        timeoutMs > 0
          ? setTimeout(() => {
              this.pending.delete(id);
              const qIdx = this._writeQueue.findIndex((q) => q.id === id);
              if (qIdx >= 0) {
                const [removed] = this._writeQueue.splice(qIdx, 1);
                this._queuedBytes = Math.max(0, this._queuedBytes - removed.bytes);
              }
              const timeoutErr = new Error(
                `Qark request #${id} (${op}) timed out after ${timeoutMs}ms`
              );
              timeoutErr.code = "QARK_TIMEOUT";
              timeoutErr.outcomeUnknown = entry.sent;
              reject(timeoutErr);
            }, timeoutMs)
          : null;

      this.pending.set(id, entry);
      this._writeQueue.push({ id, payload, bytes });
      this._queuedBytes += bytes;
      this._drainQueue();
    });
  }

  async close(timeoutMs = 2000) {
    this.closed = true;
    this._writeQueue.length = 0;
    this._queuedBytes = 0;
    const closedErr = new Error("QarkSession closed by caller");
    closedErr.code = "QARK_SESSION_CLOSED";
    for (const [id, entry] of this.pending.entries()) {
      this.pending.delete(id);
      clearTimeout(entry.timer);
      entry.reject(closedErr);
    }
    if (this.proc.exitCode !== null || this.proc.signalCode !== null) {
      this.rl.close();
      return;
    }
    const exitPromise = once(this.proc, "exit").catch(() => {});
    try {
      this.proc.stdin.end();
    } catch {}

    const waitMs = Math.max(1, Number(timeoutMs) || 2000);
    let timer;
    await Promise.race([
      exitPromise,
      new Promise((resolve) => {
        timer = setTimeout(resolve, waitMs);
      }),
    ]);
    clearTimeout(timer);

    if (this.proc.exitCode === null && this.proc.signalCode === null) {
      try {
        this.proc.kill("SIGTERM");
      } catch {}
      const graceMs = Math.min(200, Math.max(25, Math.floor(waitMs / 2)));
      let graceTimer;
      await Promise.race([
        exitPromise,
        new Promise((resolve) => {
          graceTimer = setTimeout(resolve, graceMs);
        }),
      ]);
      clearTimeout(graceTimer);
    }

    if (this.proc.exitCode === null && this.proc.signalCode === null) {
      try {
        this.proc.kill("SIGKILL");
      } catch {}
      await exitPromise;
    }

    this.rl.close();
  }
}

// Example end-to-end editor workflow:
async function runWorkflow(qarkBin, root) {
  const qark = new QarkSession(qarkBin, root);

  // 1. Discover capabilities and active checkers
  const caps = await qark.call("capabilities");
  if (!caps.ok || !caps.result.features.includes("fail_closed_checkers")) {
    throw new Error("Qark worker does not support fail_closed_checkers");
  }

  // 2. Read target symbol span and pin file sha256
  const readRes = await qark.call("read", {
    path: "src/game.js",
    symbol: "checkVictory",
    outline: true,
  });
  const fileInfo = readRes.result.files[0];
  const baseSha = fileInfo.sha256;

  // 3. Hash-pinned dry-run with scope contract and validation_complete check
  const candidateSpec = {
    path: "src/game.js",
    expect: baseSha,
    check: "strict",
    contract: {
      symbols: ["checkVictory"],
      preserve_signatures: true,
    },
    edits: [
      {
        symbol: "checkVictory",
        body: [
          "if (!state.started || state.moves === 0) return false;",
          "return state.player.x === state.goal.x && state.player.y === state.goal.y;",
        ],
      },
    ],
  };

  const dry = await qark.call("apply", { ...candidateSpec, dry_run: true, diff: true });
  if (!dry.ok || !dry.result.ready || !dry.result.validation_complete) {
    throw new Error(`Dry run rejected: ${JSON.stringify(dry.error || dry.result)}`);
  }

  // 4. Publish atomically with streaming phase events
  const commit = await qark.call("apply", { ...candidateSpec, stream: true });
  if (!commit.ok) {
    throw new Error(`Commit failed: ${commit.error.code}: ${commit.error.message}`);
  }

  const receiptFile = commit.result.files[0];
  console.log("Committed txn:", commit.result.txn);
  console.log("New sha256:", receiptFile.sha256);
  console.log("Changed lines:", receiptFile.changed_lines);
  console.log("Semantic diff:", receiptFile.semantic);

  // 5. Undo if downstream integration/browser check fails
  // const reverted = await qark.call("undo", { txn: commit.result.txn });

  qark.close();
}
```

---

## 3. Structured Repair Feedback on Edit Failures

When an edit fails (`edit_not_found`, `edit_ambiguous`, `edit_range`, `contract_violation`), Qark returns structured repair fields so an orchestrator can automatically adjust its selection or prompt a targeted one-turn repair without re-reading the entire file:

```json
{
  "id": 4,
  "ok": false,
  "error": {
    "code": "edit_not_found",
    "message": "find text not found; the closest line is the reported line, and they differ at column 15",
    "file": "src/game.js",
    "edit": 0,
    "line": 42,
    "col": 15,
    "mismatch_category": "near_miss",
    "target_lines": [38, 55],
    "actual_line": "  const speed = player.baseSpeed * 2;"
  }
}
```

### Repair Fields Reference

| Field | Type | Description |
| --- | --- | --- |
| `code` | `string` | Primary error code (`edit_not_found`, `edit_ambiguous`, `edit_range`, `contract_violation`, `rebase_conflict`). |
| `file` | `string` | Workspace-relative path of the file whose edit failed. |
| `edit` | `integer` | 0-based index in the file's `edits` array that failed. |
| `line` | `integer` | 1-based line number of the near miss, whitespace mismatch, or first ambiguous match. |
| `col` | `integer` | 1-based column where the near miss first diverges from the file's text. |
| `mismatch_category` | `string` | Machine-readable diagnosis: `"near_miss"`, `"whitespace"`, `"crlf"`, `"not_found"`, `"ambiguous"`, `"out_of_bounds"`, `"occurrence_out_of_range"`, `"symbol_not_found"`, or `"symbol_ambiguous"`. |
| `target_lines` | `[lo, hi]` | 1-based inclusive line range of the active `within` or `symbol` scope (or `[1, total_lines]` on `out_of_bounds`). |
| `actual_line` | `string` | Exact text of `line` on disk (up to 256 bytes) when `mismatch_category` is `"near_miss"` or `"whitespace"`. |

---

## 4. Coordinated Multi-Location Edits in One Atomic Transaction

When a feature requires adding an import, introducing module/global state, adding a helper function, updating a method body, and wiring a caller, **send all edits in a single `apply` call**.

Qark applies the `edits` array sequentially in memory, verifies optional scope contracts, and runs the language syntax checker on the **final assembled file** (catching duplicate `const`/`let` declarations or mismatched braces across edits) before touching disk:

```json
{
  "op": "apply",
  "args": {
    "tag": "labyrinth-victory-overlay",
    "check": "strict",
    "files": [
      {
        "path": "src/labyrinth.js",
        "expect": "8f3c...64-hex-sha256...",
        "edits": [
          {
            "insert_after": { "find": "import { renderMaze } from './render.js';" },
            "with": "import { formatTime } from './timer.js';"
          },
          {
            "insert_after": { "find": "let gameActive = false;" },
            "with": "let victoryShown = false;"
          },
          {
            "symbol": "resetGame",
            " within": { "symbol": "resetGame" },
            "insert_after": "gameActive = true;",
            "auto_indent": true,
            "with": "victoryShown = false;\nhideVictoryOverlay();"
          },
          {
            "insert_after": { "symbol": "resetGame" },
            "with": "\nfunction showVictoryOverlay(stats) {\n  const el = document.getElementById('victory-overlay');\n  el.textContent = `Solved in ${formatTime(stats.elapsedMs)}`;\n  el.hidden = false;\n}\n\nfunction hideVictoryOverlay() {\n  const el = document.getElementById('victory-overlay');\n  if (el) el.hidden = true;\n}"
          },
          {
            "within": { "symbol": "stepPlayer" },
            "find": "if (atGoal(player)) {\n  gameActive = false;\n}",
            "replace": "if (atGoal(player) && !victoryShown) {\n  gameActive = false;\n  victoryShown = true;\n  showVictoryOverlay({ elapsedMs: performance.now() - startTime });\n}"
          }
        ]
      }
    ]
  }
}
```

---

## 5. Documented Event & Journal Contract

### 5.1 Per-Transaction Phase Stream (`stream: true`)

Passing `"stream": true` on `apply` returns `events` in the receipt with microsecond timings for each phase:

```json
"events": [
  { "phase": "compile", "status": "ok", "us": 310, "files": 1 },
  { "phase": "observe", "status": "ok", "us": 480, "conflicts": 0 },
  { "phase": "check",   "status": "ok", "us": 14200, "failed": 0, "error": 0, "skipped": 0, "validation_complete": true },
  { "phase": "commit",  "status": "ok", "us": 15100, "txn": "a70d17f49f9a9f4b", "created": 0, "replaced": 1, "deleted": 0 }
]
```

### 5.2 Persistent Workspace Journal (`.qark/journal.ndjson` & `events` Op)

Every committed transaction appends one NDJSON record to `.qark/journal.ndjson`, which editors can tail via the `events` operation (`{"op": "events", "args": {"since_offset": 0, "limit": 50}}`):

```json
{
  "v": 2,
  "event": "transaction.committed",
  "ts_ms": 1793591200000,
  "txn": "a70d17f49f9a9f4b",
  "tag": "labyrinth-victory-overlay",
  "spec_sha256": "4b9c...",
  "check_policy": "strict",
  "validation_complete": true,
  "created": 0,
  "replaced": 1,
  "deleted": 0,
  "files": [
    {
      "path": "src/labyrinth.js",
      "status": "replaced",
      "sha256": "e3b0...",
      "prev_sha256": "8f3c...",
      "changed_lines": [2, 94]
    }
  ]
}
```

Each file entry in both the `apply` receipt and `.qark/journal.ndjson` includes `"changed_lines": [first_line, last_line]` (1-based inclusive range in the new file) so editors can highlight modified gutters and refresh open buffers without diffing full files.

---

## 6. Multi-Transaction Lifecycle, Project Validation, and Recovery

### Pattern A: Single Transaction with Pre-Commit Project Gate (`validate`)

Whenever possible, bundle related edits into one `apply` with `"validate"` set to a project-level test or build command. Qark stages the new files, runs the `validate` command, and **automatically rolls back** all files if the command exits non-zero:

```json
{
  "op": "apply",
  "args": {
    "tag": "feature-victory",
    "validate": ["node", "--test", "tests/game-smoke.test.mjs"],
    "files": [
      { "path": "src/labyrinth.js", "edits": [ ... ] },
      { "path": "tests/game-smoke.test.mjs", "mode": "upsert", "text": "..." }
    ]
  }
}
```

### Pattern B: Multi-Transaction Checkpoint & Atomic Rollback (`undo`)

When an orchestrator decomposes a feature into `N` separate transactions (e.g., Chunk 1: data model, Chunk 2: UI rendering, Chunk 3: wiring) and a downstream browser/gameplay verification gate fails after Chunk 2:

1. Record each chunk's `receipt.txn` (or inspect the stack with `{"op": "undo", "args": {"list": true}}`).
2. Revert all `K` completed chunks of the failed feature in one atomic call:

```json
{
  "op": "undo",
  "args": {
    "steps": 2
  }
}
```

Qark verifies that no file was concurrently modified outside the transaction chain, restores the exact pre-feature bytes across all affected files, and records the undone transactions so `{"op": "redo", "args": {}}` can replay them if needed.

---

## 7. Security Boundaries, Threat Model, and Hardening Flags

### 7.1 Workspace Threat Model

Qark operates across three distinct workspace concurrency models:

1. **Cooperative Multi-Agent Workspace:** Multiple Qark worker or MCP processes coordinate via `.qark/lock`, hash-pinned compare-and-swap (`expect`), WAL recovery (`.qark/wal.json`), and the append-only journal (`.qark/journal.ndjson`). Full multi-file serializability and crash recovery hold under this model.
2. **Mixed Editor / External Tool Workspace:** An IDE, formatter, or human edits files outside Qark without acquiring `.qark/lock`.
   - **Precondition & TOCTOU Boundary:** Qark reads target files during `observe()`, runs syntax checkers (`check`) and optional `validate` commands against staged copies, and then atomically renames staged files into place during `publish()`. Requiring `expect` (`--require-expect` / `"require_expect": true`) rejects stale proposals at `observe()` time, but it does **not** make the later filesystem `rename()` an atomic kernel compare-and-swap against unlocked external writers: a non-Qark process that does not acquire `.qark/lock` can still write between `observe()` and `publish()`.
   - **Post-Publish Rollback & Undo Protection:** Before rolling back an already-published entry during a mid-transaction `publish()` failure, replaying an interrupted `publishing` WAL in `recover_wal`, or executing `undo` / `redo` (without `force: true`), Qark checks both the on-disk content SHA-256 and the file permission mode (`published_perm` / `old_perm` when representable on the host OS). These guards protect external changes that are visible when verification runs; they do not eliminate the subsequent check/use window if an unlocked external process writes concurrently between verification and the rollback `rename()` or `unlink()`.
3. **Hostile Local Concurrent Process (Symlink Racer):** Another process running as the same OS user races symlinks or directory swaps against Qark. Qark verifies `metadata_link` on the workspace root (`--root`), re-checks path ancestry and `.qark` control-directory links immediately before and after staging/publishing/locking, and fails closed with `conflict` (`reason: "path_link"`). Full immunity against a same-UID local racer requires OS-level namespace/container isolation or `openat2(RESOLVE_NO_SYMLINKS)` dirfd plumbing.

### 7.2 Hardening Flags & Spec Options

- **Mandatory CAS Preconditions (`--require-expect` / `"require_expect": true`):** Starting Qark with `--require-expect` (or passing `"require_expect": true` in `apply`) requires every operation that modifies or deletes an existing file—including `edits`, `move`, and `glob`—to carry an explicit caller-supplied `expect`, failing closed with `expect_required` (`current_sha256` included) otherwise. For `glob` entries, callers can either pass a per-path expected-hash map (`"expect": {"src/a.py": "<sha256>", "src/b.py": "<sha256>"}`) covering every file modified by the glob, or expand `search` results into explicit hash-pinned `files` entries. Whenever `"expect"` is supplied, Qark verifies the on-disk SHA-256 matches `expect` at `observe()` time even when proposed bytes equal disk bytes, emitting `"precondition_matched": true` in the per-file receipt.
- **Crash-Durable Commits (`--durable` / `"durable": true`):** By default, Qark uses fast atomic rename durability (suitable for local agent inner loops). Passing `--durable` on the CLI or `"durable": true` in `apply`, `undo`, or `redo` enforces the following crash-durable ordering and fail-closed directory synchronization:
  1. Write each staged temp file (`O_CREAT | O_EXCL`), apply and verify its target permission mode, and `fsync` / `FlushFileBuffers` the staged file handle before closing.
  2. Persist `.qark/undo/<txn>.json` and `.qark/wal.json` (`state: "publishing"`, `"durable": true`) via `std.filesystem.replace_bytes_atomic` (which writes an exclusive sibling temp file, syncs the file handle, closes, renames into place, and syncs the parent directory) and synchronize the full `.qark` directory ancestry from the workspace root downward (`root`, `root/.qark`, `root/.qark/undo`) via `sync_ancestry_dirs`.
  3. Atomically rename staged temp files into place (or unlink deleted targets) and synchronize the workspace root and every intermediate directory along each target's relative path (`sync_ancestry_dirs`, e.g., `root`, `root/a`, `root/a/b` for `a/b/file.txt`). Directory synchronization (`sync_dir_status`) distinguishes `DIR_SYNC_OK`, `DIR_SYNC_UNSUPPORTED`, and `DIR_SYNC_FAILED`; when `durable: true` is requested, both `DIR_SYNC_UNSUPPORTED` and `DIR_SYNC_FAILED` fail closed (never reporting an unqualified durable success when the persistence barrier is unavailable or denied).
  4. Transition `.qark/wal.json` to `state: "committed"` (`"durable": true`) and synchronize `root` and `root/.qark`.
  5. Finalize `.qark/undo/latest`, `.qark/undo/redo`, `.qark/idempotency/<key>.json`, and `.qark/journal.ndjson`, syncing each file and its directory ancestry (`root`, `root/.qark`, `root/.qark/undo`, `root/.qark/idempotency`), then unlink `.qark/wal.json` and sync `root/.qark`. If interrupted, `recover_wal` preserves `"durable": true` from `.qark/wal.json` so recovery completes with the same file and directory ancestry sync guarantees.
- **Untrusted Workspace Safe Mode (`--no-custom-exec`):** Starting Qark with `--no-custom-exec` disables execution of workspace-defined `.qark/checks.json` commands and `validate` / `project.validate` shell commands, failing closed with `exec_forbidden` while keeping built-in/system language syntax checkers active.
- **Strict Spec Validation (`--strict-spec` / `"strict_spec": true`):** Rejects any unrecognized top-level, file-level, or edit-level key with `spec_unknown_key`. Safety-critical key typos (`expct`, `require_expct`, `rebse`, `cntract`, `check_polcy`, `idempotency`, `expect_sig`, `forbid_deletes`) always fail closed with `spec_unknown_key` even when `strict_spec` is not set.

