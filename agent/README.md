# Training an agent to use Qark

Qark is the tool. The agent is trained to call it, not to imitate its keystrokes. `skill/SKILL.md` is the contract an agent reads; `.cursor/skills/qark/SKILL.md` is the same text for Cursor agents in this repo, and `.cursor/mcp.json` starts `qark mcp` for them.

## Roles

1. **Producer.** Reads a task and writes a spec: data in `vars`, scripts as templates, files fanned out with `each`, all in one `apply`. It never runs what it wrote.
2. **Qark.** Renders, checks syntax, refuses unsafe paths and conflicts, publishes all files or none, and returns a receipt with every file's sha256. A job also gets `manifest.json`.
3. **Executor.** Runs `qark validate jobs/<job>` (every file must match the manifest, and nothing unlisted may be present), then the manifest's `run` with a timeout and without the producer's credentials.

## Loop

1. Pick a task. Give the producer `skill/SKILL.md` and the task.
2. Apply what it returns. On a refusal, give it Qark's error object once and apply again; Qark's errors name the field, the line, and the names that were visible, so one repair turn is usually enough.
3. Run the executor and score: applied, first try or not, scripts correct, output tokens, model time, and Qark time.
4. Bucket failures: protocol misuse (wrong spec shape), template misuse (code inside `{{ }}`, wrong `each`), invalid code (caught by checks), or wrong behavior (caught only by running).
5. Fix the skill text, a builtin template, or an error message. Do not paper over it in the scorer.
6. Keep a change only when the applied and correct rates do not drop.

## Evals

| Script | What it measures |
| --- | --- |
| `eval/apply-suite.ps1` | 95 deterministic checks of the write layer through one warm ndjson worker and one mcp server: conflicts, edits, checks, templates, jobs, paths, a race between two processes |
| `eval/bench-apply.ps1` | warm latency per apply: plain, unchanged, checked per language, batched, fan-out, edit, read |
| `eval/spec-vs-raw.ps1 -Task report\|validate -Modes raw,spec,library` | local models write six scripts through one warm worker: `raw` writes every file, `spec` writes a template plus data, `library` writes only data for a template Qark already holds. One repair turn; every script is run against sample inputs |
| `eval/next-warm.ps1`, `eval/bench-qark.ps1` | the editor ops and job.write path from 0.1 |

Traces of what each model answered land in `eval/svr-*.txt`; results in `eval/spec-vs-raw.*.results.json`.

## The `qa` dev driver

`out/<target>/<profile>/bin/qa.exe` sits beside `qark.exe` and drives this build against this repo from any directory: the workspace root is derived from its own path, and `--root DIR` overrides.

| Command | Does |
| --- | --- |
| `qa apply spec.json` | applies a spec file; `-` reads the spec from stdin |
| `qa -w dst=src [-w ...]` | stages local files into an apply spec (`-m` picks the mode) |
| `qa -e dst -f find -r repl` | edits dst inline: `-F` regex, `-s` within, `-o` occurrence, `-a` all, `-n` count, `-B`/`-A` anchor inserts with `-W` payload, `--expect`, `--no-check`, `--dry`, `--diff` |
| `qa read path [a b]` | one-shot ndjson read |
| `qa op -` | one ndjson op from stdin, safe from Git Bash mangling |
| `qa <args>` | anything else passed to qark verbatim |

`-e` and `-f` repeat, so several edits and several files fit one apply. Text arguments may be `@file`, `-` for stdin, or inline argv, where `\n` `\r` `\t` `\\` expand and `\d`-style regex escapes pass through.
