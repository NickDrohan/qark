# Qark

Qark is an atomic, syntax-checked file writer built for agents — one bottleneck every write goes through, so multi-agent work stays consistent. An agent hands Qark a spec; Qark renders every file, refuses unsafe paths, syntax-checks the result, compares against what is on disk with sha256 optimistic concurrency, and publishes **all of the files or none of them**. Every call returns a receipt: per-file status, sha256, line counts, notes, and unified diffs when asked.

Sending the same request twice is safe. A conflicting write is refused with a named error, not silently clobbered.

## For agents

**Read [`agent/skill/SKILL.md`](agent/skill/SKILL.md) — that file is the contract.** It is intentionally self-contained: transports, the spec format, every edit operator, receipts, and error codes. The same file ships at `.claude/skills/qark/SKILL.md` and `.cursor/skills/qark/SKILL.md` so agents in those tools pick it up automatically.

Three ways in:

| Transport | Start | Shape |
| --- | --- | --- |
| MCP | `qark mcp [--root <workspace>]` | tools `qark_apply`, `qark_edit`, `qark_read`, `qark_search`, `qark_impact`, `qark_undo`, `qark_check`, `qark_templates`, `qark_define_template`; resources (`qark://capabilities`, `qark://schema`, `qark://undo`, `qark://events`) & prompts |
| NDJSON | `qark --headless --stdio --root <workspace>` | one `{"id":1,"op":"apply","args":{...}}` per line |
| CLI | `qark apply spec.json --root <workspace>` | `apply -` reads the spec from stdin; `--dry-run` previews with diffs |

Minimal write:

```json
{"path":"src/util.py","text":"def double(x):\n    return 2 * x\n"}
```

Edits do not need to know the file's line endings — `find` text written with `\n` matches CRLF files, replacements keep the file's own endings, and the receipt's `notes` says when normalization happened. A miss returns the nearest line and the column where it differs.

## Build

Requires the [Mach](https://github.com/briar-systems/mach) toolchain (`^6.0`) and the `dep/std` submodule:

```sh
git clone --recurse-submodules <this-repo>
cd Qark
mach build .                    # debug   -> out/<target>/debug/bin/qark
mach build . --profile release  # release -> out/<target>/release/bin/qark
mach test .                     # unit tests
```

`build.ps1` (Windows) and `build.sh` (Linux/macOS) build both profiles, run the tests, refresh `agent/reference/*.txt`, and smoke-test the headless worker.

## The `qa` dev driver

`qa` builds next to `qark` and drives *this build* against a workspace from any directory — the shorthand for agents that should not have to author JSON:

```sh
qa -w dst=src                    # stage a local file into an apply
qa -e a.txt -f old -r new        # inline edit: -F regex -a all -o N -s scope -B/-A anchors
qa apply - < spec.json           # spec from stdin
qa op -                          # one ndjson op from stdin
```

See `qa --help` and `agent/README.md`.

## Layout

| Path | What |
| --- | --- |
| `src/` | the whole tool: spec compiler, edit engine, checkers, commit/journal, ndjson + MCP servers, editor ops |
| `agent/skill/SKILL.md` | the agent contract — give this file to an agent and it can use Qark |
| `agent/reference/ops.txt` | `qark --dump ops` — the operation reference |
| `agent/eval/` | the PowerShell eval suite (151 deterministic checks) and model benches |
| `agent/README.md` | how to train/score an agent on Qark |
| `docs/autocode-integration.md` | editor/orchestrator integration guide, fail-closed checker contract, and reference Node.js client |
| `templates/`, `scripts/` | builtin templates, language checkers (`check.cjs`, `check.py`, `check.ps1`), MCP tool schema |

## License

MIT — see [LICENSE](LICENSE).
