# AutoCode & Agent Editor Integration Guide

This document defines the integration contract between **Qark** (`>= 0.3.0`, protocol `2`) and agent-driven code editors or orchestrators such as **AutoCode**.

---

## 1. Validation Completeness & Fail-Closed Checker Contract

### 1.1 Workspace-Independent Node Checker (`.cjs`)

Qark installs its embedded Node syntax checker as `.qark/checkers/check.cjs`. Because the helper uses the `.cjs` extension, Node always loads the checker itself as CommonJS—even when the target workspace (or an ancestor directory above a nested repository) has a `package.json` with `"type": "module"`.

Each candidate file's **own** module semantics remain strictly isolated from the helper's execution format:

| Candidate File | How Qark Validates Syntax |
| --- | --- |
| `*.mjs` | Parsed as ES module (`vm.SourceTextModule` when `--experimental-vm-modules` is present, or strict ES module transform + `vm.Script`), catching both syntax errors and duplicate lexical (`let`/`const`) declarations. |
| `*.cjs` | Parsed as CommonJS (`vm.Script`, with CommonJS wrapper fallback for top-level `return`), rejecting ES module `import`/`export` syntax even inside `"type": "module"` workspaces. |
| `*.js` | Walks upward from the candidate file's directory to the nearest `package.json`. If `"type": "module"` is set (or top-level `import`/`export` syntax is present), parsed as ES module; otherwise parsed as CommonJS. |

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
import readline from "node:readline";

export class QarkSession {
  constructor(qarkBin, workspaceRoot) {
    this.proc = spawn(qarkBin, ["--headless", "--stdio", "--root", workspaceRoot], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.rl = readline.createInterface({ input: this.proc.stdout });
    this.nextId = 1;
    this.pending = new Map();

    this.rl.on("line", (line) => {
      if (!line.trim()) return;
      const msg = JSON.parse(line);
      const waiter = this.pending.get(msg.id);
      if (waiter) {
        this.pending.delete(msg.id);
        waiter(msg);
      }
    });
  }

  async call(op, args = {}) {
    const id = this.nextId++;
    const payload = JSON.stringify({ id, op, args }) + "\n";
    const replyPromise = new Promise((resolve) => this.pending.set(id, resolve));
    this.proc.stdin.write(payload, "utf8");
    return replyPromise;
  }

  close() {
    this.proc.stdin.end();
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
  "ts": 1793591200,
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
