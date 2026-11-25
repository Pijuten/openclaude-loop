# autobuild

Turn an idea into a spec, a bite-sized plan, and a working implementation —
unattended, using [OpenClaude](https://github.com/Twigpine/openclaude) and its
**Superpowers** skills, while keeping **every** session under a hard turn cap.

```
idea ──▶ docs/spec.md ──▶ docs/plan.md + .autobuild/tasks.json ──▶ commits
        (chunked)        (chunked)                               (one session per task)
```

## Why chunking

Some models (e.g. `deepseek/deepseek-chat` via OpenRouter) cap a session at ~50
turns. A single "write the whole spec" session dies at the cap with an empty
file. So instead:

- The spec and the plan are each produced across several **small** sessions.
- Each session runs with `--max-turns`. If it reports `error_max_turns`, the
  same session is resumed with `--resume <id>` so no work is lost.
- Every plan task is then implemented in its **own fresh session**.
- A task that does not fit is automatically **split** into smaller tasks
  (depth-capped).

Nothing ever runs one giant session.

## Requirements

- `openclaude` on `PATH` (provider configured — see below)
- the **Superpowers** plugin (`superpowers:brainstorming`,
  `superpowers:writing-plans`, `superpowers:test-driven-development`,
  `superpowers:verification-before-completion`)
- `git`
- `node` on `PATH` (used for JSON in the bash script; **`jq` is not required**)
- bash ≥ 4, or PowerShell 5.1 / 7+

Run it on a fresh git branch.

## Quick start

```bash
./autobuild.sh plan "a CLI that reverses its argument"
./autobuild.sh implement
./autobuild.sh status
```

PowerShell:

```powershell
.\autobuild.ps1 plan "a CLI that reverses its argument"
.\autobuild.ps1 implement
.\autobuild.ps1 status
```

Between `plan` and `implement`, read `docs/plan.md` — that is the moment to
correct course.

## Interactive planning

By default `plan` runs fully unattended and records every judgment call under an
*Assumptions* heading. If you want a say in the design, use `-i`:

```bash
./autobuild.sh plan -i "a CLI that syncs my dotfiles to S3"
./autobuild.ps1 plan -Interactive "..."        # PowerShell
```

The orchestrator first runs a tiny session that writes
`.autobuild/questions.md` (3–6 questions whose answers most change the design).
You answer them at the terminal — one line each, blank to let it decide:

```
1. Which storage backend?
2. Should the sync be encrypted?
3. One-way or two-way?

Q1> S3
Q2> Yes, client-side
Q3> One-way
```

The answers are saved to `.autobuild/answers.md` and embedded in the spec prompt
as requirements. This is why the sessions themselves never need to be
interactive: **a `-p` session cannot prompt a human**, and letting it try is
exactly how you hit a turn cap with nothing written. The questions are answered
by the shell, then handed to the model as context.

Answers can also be piped in, which makes it scriptable:

```bash
printf 'S3\nYes, client-side\nOne-way\n' | ./autobuild.sh plan -i "sync dotfiles"
```

If `.autobuild/answers.md` already exists it is reused (delete it to start
over). Answering is entirely skippable: `plan` without `-i` behaves as before.
After the first `-i` run, `implement` works the same way.

## Commands

| Command | What it does |
| --- | --- |
| `plan [-i] "<idea>"` | spec (brainstorming skill) → plan (writing-plans skill) → `tasks.json`; splits over-budget tasks |
| `implement` | one fresh session per task; verifies `DONE`, runs the test command, splits tasks that don't fit |
| `status` | prints `status<TAB>id<TAB>title` for every task |

## Configuration

### Bash (environment variables)

| Var | Default | Meaning |
| --- | --- | --- |
| `CLI` | `openclaude` | command line; flags allowed |
| `MAX_TURNS` | `40` | hard cap per session — keep below your model's limit |
| `MAX_CHUNKS` | `6` | sessions one spec/plan may span |
| `TASK_BUDGET` | `20` | tool calls the planner sizes a task to |
| `MAX_ATTEMPTS` | `2` | fresh attempts before a task is split |
| `MAX_SPLIT_DEPTH` | `2` | maximum recursive splitting |
| `TEST_CMD` | *(empty)* | e.g. `npm test`; independent check after each task |
| `PERM` | `acceptEdits` | `acceptEdits` or `bypassPermissions` |

### PowerShell (parameters)

Same names: `-MaxTurns`, `-MaxChunks`, `-TaskBudget`, `-MaxAttempts`,
`-MaxSplitDepth`, `-TestCmd`, `-Perm`, `-Cli`, `-Interactive`.

```powershell
.\autobuild.ps1 implement -TestCmd "npm test" -MaxTurns 30
```

## Using OpenRouter

There is **no `openrouter` provider**. Use the OpenAI-compatible path:

```bash
export CLAUDE_CODE_USE_OPENAI=1
export OPENAI_API_KEY="sk-or-..."                        # your OpenRouter key
export OPENAI_BASE_URL="https://openrouter.ai/api/v1"
export OPENAI_MODEL="deepseek/deepseek-chat"             # any OpenRouter model id

CLI="openclaude --provider openai" ./autobuild.sh plan "..."
```

`CLI` may contain spaces; both scripts split it into a command plus flags. Or
just set `model` in `~/.openclaude/settings.json` and leave `CLI=openclaude`.

## How it works

**`plan`**

1. If `docs/spec.md` is missing, a chunked session writes it using
   `superpowers:brainstorming` (preceded by the question round under `-i`).
2. A chunked session reads the spec and writes `docs/plan.md` plus
   `.autobuild/tasks.json` using `superpowers:writing-plans`, with each task
   sized to `TASK_BUDGET` tool calls and headed `### Task T01: <title>`.
3. Up to three "split" rounds ask the planner to break up any task estimated
   above budget.

**`implement`** — loop until no `todo` tasks remain:

1. Take the first `todo` task and run a fresh session with a prompt scoped to
   exactly that task (TDD + verification skills).
2. The task must commit and append `<id> DONE` to `.autobuild/progress.md`;
   if it appends `<id> BLOCKED: ...` the run stops.
3. If `TEST_CMD` is set, it is run as an independent gate. A `DONE` whose tests
   fail is discarded and retried.
4. Still not done after `MAX_ATTEMPTS`? The task is replaced by 2–4 smaller
   tasks covering only the remaining work.

## Files

```
.autobuild/
  tasks.json      # [{id, title, est_tool_calls, status, depth}, ...]
  progress.md     # "<id> DONE" / "<id> BLOCKED: ..." markers
  logs/           # one <session>.json per session + .err streams
  questions.md    # only with plan -i
  answers.md      # only with plan -i (reused if present)
docs/
  spec.md
  plan.md
```

`tasks.json` is the source of truth for what remains; `progress.md` is how the
model reports back across sessions (it has no memory between them).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `node is required for JSON handling` | install node; the bash script does not use `jq` |
| `Run inside a git repo` | `git init` first |
| `Spec was not written; see .autobuild/logs/spec-*.json` | raise `MAX_TURNS` or `MAX_CHUNKS`; inspect the log |
| `No valid .autobuild/tasks.json` | the planner didn't emit the array; check `logs/plan-*.json` |
| `BLOCKED: <id> still too big after splitting` | task needs a human; raise `MAX_SPLIT_DEPTH` or edit the plan |
| tests fail despite `DONE` | the task's tests are wrong or flaky; check `logs/<id>-tests.log` |
| script exits 3 on `status` | no readable `tasks.json` — run `plan` first |

## Notes

- `--allowedTools` is deliberately limited to
  `Read,Edit,Write,Glob,Grep,Bash,Skill,TodoWrite`. Subagents are excluded
  because they burn turns unpredictably under a hard cap.
- Prompts are delivered on **stdin**, which avoids Windows argument-quoting
  problems with multi-line text.
- `acceptEdits` is usually enough for unattended runs; use
  `bypassPermissions` only in a sandbox you trust.