---
name: qark
description: Write files through Qark, the workspace's atomic, syntax-checked file writer. Use whenever you create, replace, edit, or delete files, and when generating many similar scripts from data with templates. Qark returns a receipt with each file's sha256.
---

# Qark

Qark writes files for agents. One operation, `apply`, creates, replaces, edits, or deletes any number of files under the workspace root. Before anything touches disk, Qark renders every file, refuses unsafe paths, checks Python, Node, PowerShell, Bash, JSON, and TOML syntax, and compares each file with what is already there. Under a cooperative workspace lock (`.qark/lock`) and two-phase write-ahead log (`.qark/wal.json`), Qark stages and publishes all files via atomic per-file temp-rename, rolls back or finishes interrupted transactions on crash recovery, and answers with a receipt (note: external non-Qark readers that do not acquire `.qark/lock` can observe sequential per-file renames during publication).

Full-content specs (`text`, `lines`, `json`, `tmpl`) are idempotent when repeated: files that already hold the same bytes report `unchanged` with a `reason` — `same_content` when the bytes match, or `no_change` when edits ran but produced the same bytes. For relative `edits`, `delete`, or `move` specs that might be retried after a transport timeout, pass `idempotency_key` so Qark replays the committed receipt (`replayed: true`, `idempotent_replay: true`) without re-running the edits.

## Connect

| How | Start | Calls |
| --- | --- | --- |
| MCP | `qark mcp [--root <workspace>] [--lock-root] [--require-check] [--require-expect] [--no-custom-exec] [--strict-spec] [--durable]` | `qark_apply`, `qark_edit`, `qark_read`, `qark_search`, `qark_impact`, `qark_undo`, `qark_check`, `qark_templates`, `qark_define_template`; plus resources (`qark://capabilities`, `qark://schema`, `qark://undo`, `qark://events`) and prompts (`qark-edit-symbol`, `qark-refactor`) |
| NDJSON | `qark --headless --stdio --root <workspace> [--lock-root] [--require-check] [--require-expect] [--no-custom-exec] [--strict-spec] [--durable]` | one `{"id":1,"op":"apply","args":{...}}` per line; ops `apply`, `undo`, `redo`, `read`, `search`, `impact`, `events`, `project.validate`, `capabilities`, `schema`, `release.sign`, `release.verify`, `template.list`, `template.define`, `template.render`, `job.verify`, `session.info` |
| CLI | `qark apply spec.json --root <workspace> [--durable] [--strict-spec] [--require-expect] [--no-custom-exec]` (`-` reads stdin, `--dry-run` writes nothing; `qark undo [txn] [--steps N]`, `qark redo`, `qark impact <sym>`, `qark events`, `qark check`, `qark release sign\|verify <dir> --key <key>`, `qark --dump capabilities\|schema`) | prints `{"ok":true,"result":...}` or `{"ok":false,"error":...}` |
| `qa` CLI | `qa [--root <workspace>] ...` | `qa read <path> [first last \| --outline \| --fold [sym...] \| <symbol>...]`, `qa -e <path> \| -g <glob> (-f/-F -r \| -B/-A/-S -W \| -x \| -k)`, `qa s <pat> [glob]`, `qa impact <sym> [glob]`, `qa undo\|redo [txn]`, `qa [--dry] -w dst=src` |

Paths are relative to the workspace root, with `/` or `\`. When you pass an absolute path that lies inside the workspace root (e.g. `D:\Dev\Project\src\main.py`), Qark automatically strips the workspace root prefix (`src/main.py`, case-insensitively on Windows and case-sensitively on POSIX). Every MCP tool and NDJSON op also accepts an optional `"root": "<dir>"` parameter to target a specific workspace for that single call without mutating the session root (unless `--lock-root` is passed at startup, which refuses `session.set_root` and per-call `root` overrides with `root_locked`). Passing `--require-check` at startup locks the session's minimum check policy so callers cannot downgrade checking to `"permissive"` or `false`; `--require-expect` (or `"require_expect": true`) requires every modification or deletion of an existing file (including `edits`, `move`, and `glob`) to carry an explicit caller-supplied `"expect": "<sha256>"` (recommended in mixed-writer workspaces where external tools do not acquire `.qark/lock` and could otherwise modify an unpinned file between `observe` and `publish`); `--no-custom-exec` disables custom `.qark/checks.json` and `validate` commands (`exec_forbidden`); `--strict-spec` (or `"strict_spec": true`) rejects any unknown spec key with `spec_unknown_key`; and `--durable` (or `"durable": true`) enforces crash-durable `fsync` ordering across staged files, `.qark/undo/<txn>.json`, `.qark/wal.json`, `.qark/journal.ndjson`, `.qark/idempotency`, and their parent directories (and propagates `"durable": true` through WAL recovery). Qark refuses symlinked workspace roots, paths outside the workspace root, symlinks, `..`, `:` streams, device names such as `NUL`, trailing dots or spaces, and anything under `.git` or `.qark`.

## MCP Tools at a Glance

- `qark_edit`: Fast, flat-parameter surgical edit on one file (`path`) or across files (`glob`). Pass `symbol` + `body`/`signature`/`rename`/`with`, or `find`/`find_re` + `replace`, or `lines: [first, last]` + `with`, or `insert_before`/`insert_after` + `with` directly at the top level — no `files: [{"edits": [...]}]` wrapper needed. Also supports `contract`, `rebase`, `expect`, `dry_run`, and `diff`.
- `qark_apply`: Full multi-file transaction, template/macro expansion (`vars`, `each`, `expand`), file creation/deletion/moves, or flat single-file edits.
- `qark_read`: Read a file, directory listing, symbol outline (`outline: true`), signature-folded view (`fold: true`), or specific symbols (`symbol` / `symbols`).
- `qark_search`: Ripgrep-style literal or regex search returning file `sha256` and enclosing `symbol` for every match.
- `qark_impact`: Resolved symbol definition, call/reference sites with enclosing symbol, module imports/dependents, `affected_files`, and `affected_symbols`.
- `qark_undo`: Persistent multi-file undo (`steps: N`, `txn`), `redo: true`, or `list: true`.
- `qark_check`: Run project-wide validation (`validate: [...]`), verify a job manifest (`dir`), or inspect `capabilities`, `schema`, or `events`.
- `qark_templates` / `qark_define_template`: List or register session and persistent templates.

## Write files

One file:

```json
{"path": "src/util.py", "text": "def double(x):\n    return 2 * x\n"}
```

Several at once, all or nothing. Each entry has a `path` and exactly one source:

```json
{"files": [
  {"path": "src/a.py", "text": "print(1)\n"},
  {"path": "notes.md", "lines": ["# Notes", "", "first point"]},
  {"path": "config/app.json", "json": {"port": 8080, "debug": false}},
  {"path": "old.txt", "delete": true}
]}
```

| Source | Writes |
| --- | --- |
| `text` | the string as given |
| `lines` | the lines joined with `\n`, ending in `\n` |
| `json` | the value as pretty JSON |
| `tmpl` | inline template text, rendered |
| `template` | a named template, rendered |
| `edits` | the current file with the edits applied |
| `move` | a source path moved here: the destination gets its bytes, the source is deleted, all in one commit |
| `delete: true` | removes the file |

## Generate scripts from data

Put the data in `vars`, write the script once, and fan it out with `each`. One template and a list replace many hand-written files, and every file comes out consistent.

```json
{"job": "loaders",
 "vars": {"tables": [{"table": "users", "columns": ["id", "name"]},
                     {"table": "orders", "columns": ["id", "total"]}]},
 "templates": {"loader": "COLUMNS = {{columns|py}}\n\n\ndef load(rows):\n    return [dict(zip(COLUMNS, r)) for r in rows]\n"},
 "files": [{"each": "tables", "path": "load_{{table}}.py", "template": "loader"}],
 "run": {"argv": ["python", "load_users.py"], "timeout_ms": 30000}}
```

- `each` takes a list, or the name of a list in `vars`, and writes one file per item. Each item's fields become variables, and its path must contain a variable so the files differ.
- `with` adds variables to one entry.
- `templates` holds inline templates by name: a string, or `{"text"|"lines", "lang"}`.
- `template.define` (MCP `qark_define_template`) keeps a template for the whole session, and `persist: true` saves it under `.qark/templates` (refused with `dry_run_persist` when `dry_run: true`, and failing closed with `path_link` / `io_write` on unsafe or unwritable paths).
- Builtin templates: `py/script`, `py/pytest`, `js/script`, `ps1/script`, `sh/script`. List them, with the variables each reads, using `template.list` or `qark_templates`.

## Shorthand tables

When the script's shape is already a template, send a table instead of the script. `expand` is one or more blocks. The first line names the template. The next line is the header, so each column name appears once. Each later line is one record. Cells split on `|` and cannot contain `|`. A blank line ends a table.

```json
{"expand": "@greet.py\nwho\nAda\nit's Bob\n"}
```

`template.define` may set `path` to the pattern each row expands to, such as `gen/{{who|snake}}.py`. A column named `path` is the file's path for that row and wins over the pattern. A pattern with no `{{` and no `path` column writes one file: the template reads `{{#each rows}}`. The same spec may also carry `files`. A row with the wrong number of columns is `expand_row` and nothing is written.

## Change an existing file

Read it first. The reply carries its `sha256`:

```json
{"op": "read", "args": {"path": "src/util.py"}}
```

Then edit it. For a single edit (especially via `qark_edit` or `qark_apply`), you can pass the edit fields flat at the top level or directly on a file/glob entry without wrapping in `edits: [...]`:

```json
{"path": "src/util.py", "symbol": "double", "body": "return x * 2", "contract": {"symbol": "double", "preserve_signatures": true}}
```

Or pass multiple edits in order with `edits`:

```json
{"path": "src/util.py", "edits": [
  {"find": "return 2 * x", "replace": "return x + x"},
  {"lines": [10, 12], "with": ["def triple(x):", "    return 3 * x"]},
  {"insert_after": 0, "with": "\"\"\"Helpers.\"\"\""},
  {"append": "\n# end\n"},
  {"symbol": "helper", "ex": "%s/old_name/new_name/g"},
  {"symbol": "double", "with": "def double(x):\n    return x * 2"},
  {"keys": "ggdd"}
]}
```

- `find` must match exactly once (`replace` or `with` holds the replacement text). `occurrence: N` picks the Nth match (`-1` is the last), `count: N` expects exactly N and replaces them all, `all: true` replaces every match.
- `find_re` matches with the qark regex dialect (`. [] () | * + ? {} ^ $ \b \< \> \d \w \s \n \r \t`); the replacement may use `\0` for the whole match and `\1`-`\9` for captures, e.g. `{"find_re": "def (\\w+)\\(", "replace": "def \\1_v2("}` (single-escaped `\w` and `\1` in raw JSON are also accepted).
- `symbol` targets a named function, method (`Parent.method`), class, record, struct, enum, trait, or section directly using lexer- and indentation-aware boundary detection (never swallowing trailing top-level Python code or next-symbol decorators, and handling single-line functions, mixed-line brace bodies, and JS class methods):
  - `{"symbol": "name", "with": "..."}` (or `"replace"`) replaces the whole symbol span (keeping leading `@decorator` / `#[attr]` lines unless the replacement provides its own, and preserving any trailing code on the closing brace line).
  - `{"symbol": "name", "body": "..."}` replaces **only** the symbol's body while keeping its declaration signature and closing `}` intact, auto-indenting the body lines (works for multi-line, mixed-line, and single-line declarations).
  - `{"symbol": "name", "signature": "..."}` replaces **only** the declaration signature lines while keeping the body intact.
  - `{"symbol": "name", "rename": "new_name"}` validates `new_name` as a lexical identifier and renames the symbol declaration and code-token occurrences inside its lexical scope (skipping strings, comments, JS regex literals after operators or keywords such as `return`/`yield`/`case`/`throw`/`typeof`/`await`, property access keys, and inner scopes shadowed by parameter names or local declarations while still updating Python default parameter value expressions like `def f(cb=target):`; qualified method renames only rewrite receiver calls on `this`, `self`, `cls`, `super`, or the parent class).
  - Optional `"expect_signature": "def double(x):"` verifies the target symbol's current declaration header before applying `body`, `signature`, `rename`, or `with`, refusing with `signature_mismatch` if the signature drifted.
  - Adding `"symbol": "name"` (or `"within": {"symbol": "name"}`) to any `find`, `find_re`, `ex`, or `keys` edit restricts it to that symbol. Each edit object must specify exactly one primary operation (conflicting edit or symbol mode keys are refused with `edit_bad`).
- `contract` (or alias `scope`) enforces method and line scope guardrails on a file entry, glob entry, or top-level spec (when both top-level and per-entry contracts are given, both are enforced across all operations including `delete`, `move`, and `prune`):
  - `{"contract": {"symbols": ["total", "count"], "preserve_signatures": true, "max_lines_changed": 25, "forbid_delete": true}}` (also accepts `"symbol": "name"`, `"methods": [...]`, `"lines": [first, last]`, or `"max_changed_lines": 25`). Unknown or conflicting contract fields (e.g. passing both `contract` and `scope` on the same entry, disagreeing `symbols` and `methods`, or disagreeing `max_lines_changed` and `max_changed_lines`) are refused upfront with `contract_bad`.
  - Qark verifies byte-for-byte that no bytes outside the permitted symbols or line range were modified, that declaration headers were preserved when `preserve_signatures: true`, and that hunk line deltas stay within `max_lines_changed`, refusing with `contract_violation` or `contract_scope` before anything touches disk.
- `require_expect: true` at the top level refuses any transaction that modifies or deletes an existing file without an explicit `expect` SHA-256 (`expect_required`).
- `idempotency_key: "<key>"` deduplicates retried transactions across reconnects: if the key was already committed with the same `spec_sha256`, Qark replays the stored receipt with `"replayed": true` and `"idempotent_replay": true` before compiling or touching disk; if the spec differs, Qark refuses with `idempotency_mismatch`.
- `rebase: true` performs deterministic 3-way proposal rebasing when `expect` is set and another agent or process modified the file concurrently:
  - Qark looks up the base version matching `expect` in `.qark/undo` (or verifies explicit `base_text` against `expect`, refusing with `rebase_base_mismatch` or `base_unavailable` when the base cannot be verified), computes a 3-way line merge between `Base`, `Current` (on disk), and `Proposed`, and commits the merged result with `"rebased": true` and `"base_sha256"` in the file receipt — or refuses with `rebase_conflict` if both modified the same lines.
- `within` scopes any `find`, `find_re`, `ex`, or `keys` edit to part of the file: `[first, last]` lines, a string, or `{"find"|"find_re"|"symbol": ..., "occurrence": N}` naming the span.
- `insert_before`/`insert_after` take a 1-based line number, or an anchor: `"text"` or `{"find"|"find_re"|"symbol": ..., "occurrence": N}` -- the insert lands on the line before/after the line or symbol span holding the match. Use `with` for the inserted text, and set `"auto_indent": true` to automatically indent every inserted line to match the anchor line's leading whitespace.
- Line endings never need to match the file's: `find`, `within`, and string anchors written with `\n` match a CRLF file. Inserted and replacement text is written with the file's own endings, and the file's receipt `notes` says when matching was normalized. A `find_re` that only fails on line endings gets an error naming `\r\n`.
- `lines` is 1-based and inclusive.
- `ex` runs a vim ex command (`s`, `g`, `v`, `d`, `normal`, `set` -- with `\0`-`\9` capture groups in `%s`), and `keys` runs vim normal-mode keys. Both respect `within` and `symbol` scopes. Neither can write files, open files, or run a shell.
- Qark records the file's hash when it reads it, so an edit fails rather than landing on a file that changed in the meantime.

To replace a whole file, send `"mode": "replace", "expect": "<sha256 from read>"`.

To refactor across multiple files at once, use `"glob"` instead of `"path"` (`{"glob": "src/**/*.py", "edits": [{"find": "old_api(", "replace": "new_api(", "all": true}]}` or `qa -g "src/**/*.py" -f "old_api(" -r "new_api(" -a`). Qark walks the matching workspace files, applies `edits` to every file where they match, runs syntax and project checkers across all touched files, and commits all of them or none.

## Move a file

`{"path": "new/name.py", "move": "old/name.py"}` gives the destination the source's bytes and deletes the source in the same commit — atomic rename. `expect` on the entry pins the source's sha256, so a source that changed since you read it refuses the whole apply. `move` is relative to the same root or `dest` as `path`.

## Search and outline

`search` (MCP `qark_search`) works like ripgrep over the workspace:

```json
{"op": "search", "args": {"pattern": "MODE_DELETE", "glob": "src/gen/*.mach"}}
{"op": "search", "args": {"pattern": "^pub fun", "regex": true, "context": 1, "max": 50}}
{"op": "search", "args": {"glob": "**/*.py"}}
```

- `pattern` is literal unless `regex` is true; `icase` folds case; `context` adds surrounding lines.
- `glob` filters paths: `*` stays within a directory, `**` crosses, a bare `*.py` matches by basename. `path` restricts the search to a directory or a single file.
- With no `pattern` it lists the matching paths — use it to map a workspace instead of reading directories.
- Matches come grouped per file with that file's `sha256` and each match's enclosing `symbol` (when inside a function, class, or record), so a follow-up edit can target that symbol or `expect` the hash directly.
- It skips `.git`, `.qark`, `node_modules`, and build output unless `all` is true, and skips binary or >4 MiB files.

`read` with `"outline": true` (or `"symbols": true, "content": false`) adds a `symbols` list — functions, methods (with `parent`), classes, records, structs, enums, traits, interfaces, types, and sections with `line`/`end`/`kind`/`name` — without needing the file's text. `read` with `"symbol": "<name>"` (or `"Parent.method"`) returns only that symbol's span (`first_line`, `last_line`, `text`, and the whole file's `sha256`), or lists `available_symbols` when not found. Pass `"symbols": ["sym1", "sym2"]` to read several symbols at once (returned in `spans`). Pass `"fold": true` (optionally with `"symbol"` or `"symbols"` to keep specific functions expanded) for a compact signature-folded view of the file that keeps all imports, types, and function signatures while folding function bodies into `# ... [lines X-Y folded: name]`. `max_bytes` sets the total byte budget across all files/spans returned by the `read` call, and `truncated: true` is emitted when file count (`>256`), symbol count (`>64`), or byte limits truncate the output.

`impact` (NDJSON `impact`, CLI `qark impact <symbol> [glob]`, or `qark_search` with `"impact": true` / `"impact": "<symbol>"`) computes a lexical reference and impact graph across the workspace (`analysis_mode: "lexical"`):
- Returns `complete` (`true` when every matching file was scanned without size/encoding skips or caps), `definitions` (path, line, end, kind, sha256), `references` (every code-token reference site including multiple occurrences per line, same-line recursive calls, and `${...}` template expressions while ignoring template literal text after `${...}`, with its enclosing `symbol`, `line`, `col`, and `sha256`), `imports` and `dependents` (including relative `./`, `../`, and directory index/`__init__.py` imports when `"path"` is given), `affected_files`, and `affected_symbols` (`path:symbol`).

## Modes

| `mode` | When the file exists with other bytes | When it is missing |
| --- | --- | --- |
| `create` (default) | conflict `exists` | created |
| `replace` | replaced (add `expect` to guard it) | conflict `missing` |
| `upsert` | replaced | created |

A file that already holds the same bytes is `unchanged` in every mode (provided any explicit `expect` SHA-256 precondition matches; whenever `expect` is supplied, Qark enforces it as a strict compare-and-swap precondition across all modes even when the proposed bytes equal the current disk bytes, and emits `"precondition_matched": true` in the file receipt). Inside a `job`, the default is `upsert`. Each file entry may also set `"executable": true` (preserving existing read/write permission bits when adding execute bits) or an explicit octal permission mode `"perm": 0..511` (including `0` for `000`), which is preserved across staging, snapshots, `undo`, and `redo`.

## Jobs

`"job": "etl"` writes under `jobs/etl/` and adds `manifest.json`, which lists every file with its sha256 and records `run` for whoever executes the job. `"prune": true` deletes files the previous manifest listed that the new spec no longer makes. The executor checks a job with `qark validate jobs/etl` (NDJSON `job.verify`), which re-hashes every file and reports any file the manifest does not list.

## Preview, semantic diff, streaming events, and persistent undo/redo

`"dry_run": true` renders and checks everything, writes nothing, and reports `would_create`, `would_replace`, `unchanged`, or `conflict` per file, plus `ready`. Add `"preview": true` to see each rendered text, or `"diff": true` to get a unified diff of every changed file in the receipt — `dry_run` plus `diff` previews exactly what will land.

Every changed source file in a receipt (both `dry_run` and committed) includes a `"semantic"` change preview object listing `"added"`, `"modified"` (with `"signature_changed": true|false`), and `"removed"` symbols so agents can verify symbol-level impact at a glance.

Pass `"stream": true` on `apply` to include per-phase transaction timing and status events (`compile`, `observe`, `check`, `validate`, `commit`) in `receipt.events`. Call `{"op": "events", "args": {"since_offset": 0}}` (or `qark events`) to stream committed transaction events from `.qark/journal.ndjson`.

Every apply that writes to disk saves a persistent snapshot under `.qark/undo/<txn>.json` and a two-phase write-ahead log (`.qark/wal.json`: `"publishing"` before file renames, `"committed"` — carrying the committed journal line and idempotency receipt payload — immediately after all files land) before finalizing `.qark/journal.ndjson`, `.qark/idempotency/<sha>.json`, and `.qark/undo/latest` and clearing the WAL. On startup or before the next write (`dry_run` never mutates disk even if a WAL is pending), Qark automatically rolls back `"publishing"` WALs (verifying both pre-image and post-image SHA-256 hashes so post-crash user edits are never overwritten) or idempotently rolls forward `"committed"` WALs without duplicating journal entries; if `.qark/wal.json` or its snapshot is corrupted or unreadable, Qark preserves the WAL and refuses writes with `recovery_required`.
- Revert the latest transaction (or walk back `1..32` transactions atomically across all create/replace/delete/permission transitions with `"steps": N`): `{"op": "undo", "args": {"steps": 1}}` (or `qark_apply` with `{"undo": true}`, or `qark undo [--steps N]`). Reverting a non-latest `txn` requires `force: true` (otherwise refused with `undo_not_latest`).
- Redo an undone transaction (or pop `1..32` entries from the persistent `.qark/undo/redo` stack across consecutive `undo`/`redo` calls): `{"op": "redo", "args": {"steps": 1}}` (or `{"op": "undo", "args": {"redo": true}}`, `qark_apply` with `{"redo": true}`, or `qark redo`).
- Inspect the undo stack and available `redo_txn`: `{"op": "undo", "args": {"list": true}}` (or `qark undo --list`).

## Capabilities, schemas, and signed releases

- Discover capabilities: `{"op": "capabilities"}` or `qark --dump capabilities` returns version, supported features, symbol edit modes, contract fields, operations, languages, limits, and active checkers.
- Discover schemas: `{"op": "schema", "args": {"op": "apply"}}` or `qark --dump schema` returns machine-readable operation and contract schemas.
- Sign and verify releases: `qark release sign <dir> --key <key>` (NDJSON `release.sign`, or set `QARK_RELEASE_KEY`) hashes every release artifact, writes `SHA256SUMS` and a keyed RFC 2104 HMAC-SHA256 signed `RELEASE.json`. `qark release verify <dir> --key <key>` (NDJSON `release.verify`) verifies `SHA256SUMS` 1-for-1 against `RELEASE.json.files`, the cryptographic signature, and every file's SHA-256, refusing with `release_tampered`, `release_bad_signature`, or `release_key_required`.

## The receipt & validation completeness

```json
{"txn": "5d43f87bd6432102", "job": "loaders", "check_policy": "strict", "validation_complete": true,
 "checks": {"ok": 3, "failed": 0, "error": 0, "skipped": 0, "unchecked": 0},
 "created": 3, "replaced": 0, "unchanged": 0, "deleted": 0,
 "files": [{"path": "jobs/loaders/load_users.py", "status": "created", "sha256": "d8f0...", "bytes": 505, "lines": 18, "changed_lines": [1, 18], "lang": "python", "check": "ok"}],
 "manifest": "jobs/loaders/manifest.json", "journal_offset": 0,
 "ms": {"compile": 0.5, "check": 8.1, "commit": 5.2, "total": 13.8}}
```

- **Fail-closed checkers (`check_policy`)**: By default (`"check": true` / `"strict"`), Qark installs its Node helper as `.qark/checkers/check.cjs` (isolated from workspace `"type": "module"` settings while respecting `.js`/`.mjs`/`.cjs`, Node's CommonJS module wrapper, UTF-8 BOM-prefixed `package.json`, and nearest or batch-staged `package.json` semantics at any directory depth) and fails closed on both source syntax errors (`code: "check_failed"`, `check: "failed"`) and checker infrastructure crashes/timeouts/malformed output (`code: "checker_error"`, `check: "error"`, with bounded `checker_diagnostics`). Custom `.qark/checks.json` failures are monotonic and are never overwritten by built-in checkers. Pass `"check": "required"` (top-level or per-file) to also refuse missing language runtimes or unsupported file types (`check_unavailable`), `"check": "permissive"` to explicitly allow checker crashes as skipped (`validation_complete: false`), or `false` (`"off"`).
- **`validation_complete`**: `true` only when `check_policy` is `"strict"` or `"required"`, all created/replaced files were checked (`checks.ok > 0`, project validation passed, or the batch consists solely of deletions), and `failed == 0`, `error == 0`, `skipped == 0`, and `unchecked == 0`.
- **`changed_lines`**: `[first_line, last_line]` (1-based inclusive) on every created or replaced file in the receipt and in `.qark/journal.ndjson` (`event: "transaction.committed"`).
- Each file's `notes` reports advisory detail, such as line endings normalized to match or non-safety spec keys Qark ignored. Safety-critical key typos (`expct`, `require_expct`, `rebse`, `cntract`, `check_polcy`, `idempotency`, `expect_sig`, `forbid_deletes`) always fail closed with `spec_unknown_key`, and passing `--strict-spec` or `"strict_spec": true` rejects any unrecognized key with `spec_unknown_key`.
- Every apply that changes the disk appends one line to `.qark/journal.ndjson` (`v: 2`, `ts_ms`, `txn`, `created`, `replaced`, `deleted`, `validation_complete`, `changed_lines`), so other agents and editors can follow what changed. See `docs/autocode-integration.md` and `scripts/client/qark-session.mjs` for the full editor/orchestrator integration contract and reference Node.js client.

## When Qark refuses

Nothing was written. Every refusal has a `code` and a `message`. Edit failures also include structured repair fields (`file`, `edit`, `line`, `col`, `mismatch_category`, `target_lines`, and `actual_line`) so an agent or orchestrator can repair the edit in one turn without re-reading the file.

| `code` | Meaning | What to do |
| --- | --- | --- |
| `conflict`, reason `exists` | the file is there with other bytes | edit it, or `mode: replace` with `expect` set to the `current_sha256` in the reply |
| `conflict`, reason `stale` | the file changed since you read it | read it again (or pass `rebase: true` for 3-way merge) |
| `conflict`, reason `missing` | replace, delete, or edit of a missing file | `create` it instead |
| `expect_required` | `require_expect: true` and an existing file had no `expect` | pass `expect: "<current_sha256>"` |
| `spec_unknown_key` | a safety-critical key was misspelled (e.g. `expct`) or `--strict-spec` / `strict_spec: true` rejected an unknown key | fix the key name |
| `exec_forbidden` | custom `validate` or `.qark/checks.json` execution was requested when `--no-custom-exec` is active | remove custom command execution or run without `--no-custom-exec` |
| `idempotency_mismatch` | `idempotency_key` was reused with a different spec | use a new `idempotency_key` or resend the original spec |
| `check_failed` | a file has a syntax error (including duplicate `let`/`const` in JS) or project validation failed | fix the `line` and `col` named per file |
| `checker_error` | a language checker crashed, timed out, returned malformed output, or mutated a staged candidate file (`stage_mutated`) | inspect `checker_diagnostics` (`category`, `executable`, `exit_code`, `stderr`, `affected_files`); nothing was written |
| `check_unavailable` | `check: "required"` and no checker/runtime is available for a file | install the runtime or use `check: "strict"` |
| `undo_not_latest` | `undo` targeted a non-latest `txn` without `force: true` | pass `txn: "latest"` or `force: true` |
| `dry_run_persist` | `template.define` passed `persist: true` with `dry_run: true` | omit `persist: true` during `dry_run` |
| `tmpl_var` | a template names a variable that is not there | use one of the names listed after "visible here" |
| `tmpl_code` | a `{{ }}` tag holds code, or the file needs literal `{{` | use a variable with filters, or write `\{{` for literal braces |
| `tmpl_syntax`, `tmpl_unknown`, `tmpl_filter`, `tmpl_type` | a template is malformed, missing, or misused | the message names the line and the fix |
| `spec_each`, `spec_each_path`, `duplicate_path` | `each` names no list, or two files land on one path | put a list in `vars`, and an item variable in `path` |
| `spec_glob_unsupported` | a `glob` entry used `expect`, `rebase`, `move`, `delete`, `path`, or `each` | use per-file entries for those fields |
| `edit_not_found`, `edit_ambiguous`, `edit_range` | an edit did not match, matched multiple times, or is out of bounds | inspect `mismatch_category` (`near_miss`, `whitespace`, `crlf`, `ambiguous`, `out_of_bounds`), `line`, `col`, `target_lines`, and `actual_line` to repair in one turn |
| `signature_mismatch` | `expect_signature` did not match the target symbol's declaration header | read the symbol's current signature and retry |
| `contract_violation`, `contract_bad` | an edit modified lines or signatures outside `contract`, or `contract` has unknown keys | keep edits inside `contract.symbols` / `contract.lines` |
| `rebase_conflict`, `rebase_base_mismatch`, `base_unavailable` | concurrent edits overlap, `base_text` does not match `expect`, or base snapshot is unavailable | read the latest file and re-apply |
| `edit_too_many` | a pattern or `within` matched over 32768 times | narrow the pattern or scope it with `within` |
| `move_same`, `edit_missing` | a `move` names its own path, or its source is gone | give a different destination, or create the file |
| `edit_count` | a `keys` count is above 10000 | use a smaller count, or `text` / `lines` |
| `edit_macro` | a macro called itself more than 8 deep | the edit was not applied |
| `path_*` | the path is unsafe or traverses a symlink (`path_link`) | use a plain relative path inside the workspace |
| `locked` | another Qark held the workspace for over 10 s | send the same request again |
| `too_large`, `too_many_files` | over 8 MiB per file, 64 MiB, or 1024 files per apply | split the change |

## Template language

```
{{name}}  {{item.field}}  {{list.0}}  {{.}}  {{@index}} {{@first}} {{@last}} {{@key}}
{{#each list}}...{{else}}...{{/each}}   {{#if x}}...{{else}}...{{/if}}   {{#unless x}}...{{/unless}}
{{#with obj}}...{{/with}}   {{> other_template}}   {{! comment }}
```

| Filter | Gives |
| --- | --- |
| `py` `js` `json` `ps` `sh` | the value as a literal in that language: strings quoted and escaped, lists, dicts, `True`/`$true`, `None`/`$null` |
| `count` | the length of a list or string |
| `join:", "` | list items joined |
| `default:text` | used when the variable is missing |
| `upper` `lower` `trim` `snake` `camel` `pascal` `kebab` `const` | text transforms |
| `ident` | refuses text that is not a valid identifier in the file's language |
| `indent:4` | indents every line after the first, for code blocks you insert |

A block tag alone on its line removes that whole line, so templates read like the code they produce. A missing variable is an error unless it is an `#if` or `#unless` condition, or `default:` supplies text. Insert data with literal filters, such as `{{name|py}}`, rather than quoting it yourself.

Templates do not run code. Compute in the generated program, not inside `{{ }}`. When the generated file needs literal braces, such as a Python f-string, a dict literal, or Jinja, write `\{{` and the template keeps `{{` as text.

A count in `keys` repeats the edit: `3ix<Esc>` inserts `xxx`, `3dd` deletes three lines, `yy3p` pastes three times. A count above 10000 is refused as `edit_count` and the file is left unchanged. A macro that calls itself more than 8 deep is refused as `edit_macro`.

## Project checkers

`.qark/checks.json` maps a file extension to a command. The first word is found on `PATH`. Exit 0 accepts the file. A non-zero exit, a missing program, or a timeout refuses the whole apply and nothing is written.

`{file}` is the new bytes of that one file, written to an isolated per-run temporary preview directory. `{root}` is a disposable isolated staging tree containing a copy of the workspace with the candidate changes applied — **the live workspace is never mutated during `{root}` checks, `validate` commands, or `dry_run`**, and Qark re-hashes every staged candidate file after the validator exits so any validator that mutates or deletes staged candidates is refused with `checker_error` (`category: "stage_mutated"`).

```json
{"mach": ["mach", "check", "{root}"]}
```

`mach check` sees the project in the isolated staging tree as the apply will leave it. You can also configure `"project"` (or `"*"`) in `.qark/checks.json` or pass `"validate": ["pytest", "-q"]` (or alias `"project_check"`) directly in an `apply` spec (or run `qark check` / NDJSON `project.validate`): Qark stages all candidate changes in an isolated staging tree, runs the project-wide validation command, and refuses with `check_failed` before touching the live workspace if the command exits non-zero. Passing `"validate": true` when no project command is configured in `.qark/checks.json` fails closed (`check_failed`). Agents cannot write `.qark` themselves.

## Rules

- Write every file through Qark. Do not use other write tools in a Qark workspace.
- Prefer one `apply` per logical change, so related files land together or not at all.
- Before writing several similar files, look for a template with `template.list`. When one fits, your spec is only data: `vars` plus one `each` entry that names the template.
- When no template fits, write one, check it with `dry_run` and `preview`, and keep it with `template.define` so later calls only send data.
- Do not put timestamps or random names in generated files. The same spec must produce the same bytes.
- The producer writes; the executor runs `qark validate` and then the job's `run`. Qark never runs generated code.
