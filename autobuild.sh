#!/usr/bin/env bash
# autobuild.sh — idea -> spec -> bite-sized plan -> unattended implementation
# with OpenClaude + Superpowers, keeping EVERY session under a hard turn cap.
#
#   ./autobuild.sh plan "a CLI that syncs my dotfiles to S3"
#   ./autobuild.sh plan -i "..."    # ask clarifying questions first
#   ./autobuild.sh implement
#   ./autobuild.sh status
#
# Why chunked: some models (e.g. deepseek 4.1 flash) cap a session at ~50
# turns. So the spec and the plan are each produced across several SMALL
# sessions (--session-id then --resume), and every task is implemented in its
# own fresh session. Nothing ever runs one giant session.
#
# Requires: openclaude (provider set up; see PROVIDER note below), git, and
# node OR python on PATH for JSON (jq is NOT required).
# Run it on a fresh git branch.
set -euo pipefail

CLI="${CLI:-openclaude}"
MAX_TURNS="${MAX_TURNS:-40}"          # hard cap PER SESSION; keep below your 50 limit
MAX_CHUNKS="${MAX_CHUNKS:-6}"         # sessions a single spec/plan may span
TASK_BUDGET="${TASK_BUDGET:-20}"      # planner sizes each task to this many tool calls
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"     # fresh-session attempts before a task gets split
MAX_SPLIT_DEPTH="${MAX_SPLIT_DEPTH:-2}"
TEST_CMD="${TEST_CMD:-}"              # e.g. "npm test": independent check after each task
PERM="${PERM:-acceptEdits}"           # acceptEdits | bypassPermissions (fully unattended)
INTERACTIVE="${INTERACTIVE:-0}"       # set by 'plan -i': ask clarifying questions first

# ------------------------------------------------------------------ PROVIDER
# OpenRouter is NOT a --provider choice. Use the OpenAI-compatible path:
#   export CLAUDE_CODE_USE_OPENAI=1
#   export OPENAI_API_KEY="sk-or-..."                     # your OpenRouter key
#   export OPENAI_BASE_URL="https://openrouter.ai/api/v1"
#   export OPENAI_MODEL="deepseek/deepseek-chat"          # any OpenRouter model id
#   CLI="openclaude --provider openai" ./autobuild.sh plan "..."
# (or just set "model" in ~/.openclaude/settings.json and leave CLI=openclaude)

S=".autobuild"; TASKS="$S/tasks.json"; PROG="$S/progress.md"; LOGS="$S/logs"
QUESTIONS="$S/questions.md"; ANSWERS="$S/answers.md"
# In -p mode only whitelisted tools are auto-approved; everything else
# (including subagents, which would burn turns unpredictably) is denied.
TOOLS="Read,Edit,Write,Glob,Grep,Bash,Skill,TodoWrite"

# ------------------------------------------------------------- JSON (no jq)
# A tiny node-based jq replacement so the script works with no extra installs.
JSON_HELPER='
const fs=require("fs");
const [,op,...a]=process.argv;
function load(f){try{return JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){process.exit(3)}}
function out(v){process.stdout.write(typeof v==="object"?JSON.stringify(v):String(v))}
switch(op){
  case "get":{const d=load(a[0]);let v=d;for(const k of a[1].split(".")){if(v==null){v=undefined;break}v=v[k]}if(v===undefined||v===null)process.exit(4);out(v);break}
  case "len":{const d=load(a[0]);out(Array.isArray(d)?d.length:Object.keys(d).length);break}
  case "list":{const d=load(a[0]);out((d||[]).map(x=>x.status+"\t"+x.id+"\t"+x.title).join("\n")+"\n");break}
  case "first_todo":{const t=(load(a[0])||[]).find(x=>x.status==="todo");if(!t)process.exit(4);out(t.id);break}
  case "field":{const t=(load(a[0])||[]).find(x=>x.id===a[1]);if(!t)process.exit(4);out(t[a[2]]);break}
  case "over_budget":{const b=Number(a[1]);out((load(a[0])||[]).filter(x=>Number(x.est_tool_calls)>b).map(x=>x.id).join(","));break}
  case "has_todo":{out((load(a[0])||[]).some(x=>x.id===a[1]&&x.status==="todo")?"yes":"no");break}
  case "setstatus":{const d=load(a[0]);(d||[]).forEach(x=>{if(x.id===a[1])x.status=a[2]});fs.writeFileSync(a[0],JSON.stringify(d,null,2));break}
  default:process.exit(2)
}
'
json() { node -e "$JSON_HELPER" "$@"; }
newid() { node -e 'process.stdout.write(require("crypto").randomUUID())' 2>/dev/null || printf 'sess-%s-%s' "$RANDOM" "$RANDOM"; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Run inside a git repo."; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required for JSON handling."; exit 1; }
mkdir -p "$LOGS" docs; touch "$PROG"

SUB=""   # set by session(): last session's result subtype

# session <name> <prompt> <sid> [resume] -> runs one turn-capped session.
# Prompt goes in via stdin (avoids argv quoting problems on Windows). Sets SUB.
session() {
  local name="$1" prompt="$2" sid="$3" resume="${4:-}"
  local log="$LOGS/$name.json" err="$LOGS/$name.err"
  local -a args=(-p --max-turns "$MAX_TURNS" --output-format json
                 --permission-mode "$PERM" --allowedTools "$TOOLS")
  if [ -n "$sid" ]; then
    if [ "$resume" = resume ]; then args+=(--resume "$sid"); else args+=(--session-id "$sid"); fi
  fi
  set +e
  read -r -a cli_arr <<<"$CLI" || true   # allow CLI="openclaude --provider openai"
  "${cli_arr[@]}" "${args[@]}" <<<"$prompt" >"$log" 2>"$err"
  local rc=$?
  set -e
  SUB=$(json get "$log" subtype 2>/dev/null) || SUB="crashed"
  local turns; turns=$(json get "$log" num_turns 2>/dev/null) || turns="?"
  echo "  [$name] $SUB, $turns turns" >&2
  return $rc
}

# chunked <name> <prompt> <continuation> <check-cmd>
# Runs the work as one or more small sessions. On a turn-cap hit it resumes the
# SAME session; on a premature "success" it resumes until <check-cmd> passes.
# Returns 0 only when a session succeeds AND <check-cmd> passes.
chunked() {
  local name="$1" prompt="$2" cont="$3" check="$4" sid c
  sid="$(newid)"
  for c in $(seq 1 "$MAX_CHUNKS"); do
    if [ "$c" = 1 ]; then
      session "$name-$c" "$prompt" "$sid" || true
    else
      session "$name-$c" "$cont" "$sid" resume || true
    fi
    case "$SUB" in
      success)
        if bash -c "$check" >/dev/null 2>&1; then return 0; fi
        echo "  [$name] success but artifact check failed; continuing" >&2 ;;
      error_max_turns)
        echo "  [$name] turn cap hit; resuming (chunk $((c+1))/$MAX_CHUNKS)" >&2 ;;
      *)
        echo "  [$name] session failed ($SUB) — see $LOGS/$name-$c.json" >&2; return 1 ;;
    esac
  done
  echo "  [$name] incomplete after $MAX_CHUNKS chunks" >&2
  return 1
}

set_status() { json setstatus "$TASKS" "$1" "$2"; }

# ask_questions <idea>
# Writes .autobuild/questions.md from a small session, then collects answers.
# Answers come from (in order): an existing $ANSWERS file, piped stdin, or the
# terminal. Sessions stay non-interactive, so a 50-turn cap can never stall here.
ask_questions() {
  [ -s "$ANSWERS" ] && { echo "Using existing $ANSWERS"; return 0; }

  chunked questions \
"Read the idea below. Write 3 to 6 short clarifying questions whose answers would
most change the design. Put them in $QUESTIONS as a numbered list, one line each,
with no preamble and no answers. Then stop.
Idea: $1" \
"Continue exactly where you left off. If $QUESTIONS is not yet written, write it now. Then stop." \
"test -s '$QUESTIONS'" || true

  if [ ! -s "$QUESTIONS" ]; then
    echo "  (could not generate questions; continuing without them)" >&2
    return 0
  fi

  echo
  cat "$QUESTIONS"
  echo

  if [ ! -t 0 ]; then
    # piped/redirected stdin: treat it as the answers, numbered like the questions
    {
      printf 'Answers to the questions above:\n'
      local an=0 aline
      while IFS= read -r aline; do
        [ -z "$aline" ] && continue
        an=$((an + 1))
        printf 'Q%s: %s\n' "$an" "$aline"
      done
    } >"$ANSWERS"
    echo "Read answers from stdin -> $ANSWERS"
    return 0
  fi

  # Ask exactly as many lines as there are numbered questions.
  local nq
  nq=$(grep -cE '^[[:space:]]*[0-9]+[.)]' "$QUESTIONS" || true)
  [ "$nq" -lt 1 ] && nq=$(wc -l <"$QUESTIONS")
  echo "Answer each question on one line. Leave a line blank to let me decide."
  : >"$ANSWERS"
  local line qn=0
  while [ "$qn" -lt "$nq" ]; do
    qn=$((qn + 1))
    printf 'Q%s> ' "$qn"
    IFS= read -r line || break
    [ -z "$line" ] && continue
    printf 'Q%s: %s\n' "$qn" "$line" >>"$ANSWERS"
  done
  if [ ! -s "$ANSWERS" ]; then
    echo "  (no answers given; I'll make reasonable decisions)"
  else
    echo "Saved answers -> $ANSWERS"
  fi
}

# ---------------------------------------------------------------- plan
cmd_plan() {
  local idea="${1:?usage: $0 plan \"<idea>\"}"
  local ctx=""
  if [ "$INTERACTIVE" = 1 ] && [ ! -s docs/spec.md ]; then
    ask_questions "$idea"
  fi
  [ -s "$ANSWERS" ] && ctx="
The human answered clarifying questions; treat these as requirements:
$(cat "$ANSWERS")"

  if [ ! -s docs/spec.md ]; then
    chunked spec \
"Use the superpowers:brainstorming skill to turn the idea below into a design spec.
You are running unattended: do NOT ask questions or wait for approval. Make sensible decisions and list them under an 'Assumptions' heading.
Scope it as an MVP. Save the spec to docs/spec.md, then stop.
Idea: $idea$ctx" \
"Continue exactly where you left off. If docs/spec.md is not yet written, write it now. Then stop." \
'test -s docs/spec.md' || true
  fi
  [ -s docs/spec.md ] || { echo "Spec was not written; see $LOGS/spec-*.json"; exit 1; }

  chunked plan \
"Read docs/spec.md and use the superpowers:writing-plans skill to write docs/plan.md.
HARD CONSTRAINT: each task will be executed by a FRESH agent with no memory, limited to about $TASK_BUDGET tool calls in total (reading, editing, running tests, committing). Size every task to fit comfortably: one behaviour, ideally 3 files or fewer, its own tests. Prefer many small tasks over few large ones. Order tasks so each one leaves the repo building with tests passing. Each task must be self-contained: exact file paths, what to test, and what 'done' means.
Head each task '### Task T01: <title>', '### Task T02: <title>', and so on.
Also write $TASKS: a JSON array like [{\"id\":\"T01\",\"title\":\"...\",\"est_tool_calls\":12,\"status\":\"todo\",\"depth\":0}] with one entry per task, same ids and order. Then stop." \
"Continue exactly where you left off. Finish docs/plan.md and $TASKS, then stop." \
"test -s docs/plan.md && test -s '$TASKS' && node -e 'const d=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(Array.isArray(d)&&d.length?0:1)' '$TASKS'" || true

  json len "$TASKS" >/dev/null 2>&1 || { echo "No valid $TASKS; see $LOGS/plan-*.json"; exit 1; }

  local i big
  for i in 1 2 3; do
    big=$(json over_budget "$TASKS" "$TASK_BUDGET")
    [ -z "$big" ] && break
    echo "Tasks over budget: $big — asking planner to split (round $i)"
    chunked "resplit-$i" \
"Tasks $big in docs/plan.md and $TASKS are estimated above $TASK_BUDGET tool calls. Split each into smaller tasks (ids like T03a, T03b) in place, keeping order and depth, and update both files consistently. Change nothing else, then stop." \
"Continue exactly where you left off. Finish splitting tasks $big in docs/plan.md and $TASKS, then stop." \
"node -e 'const d=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));const ids=process.argv[2].split(\",\");process.exit(ids.some(i=>d.some(t=>t.id===i))?1:0)' '$TASKS' '$big'" || true
  done
  echo "Plan ready: $(json len "$TASKS") tasks. Review docs/plan.md, then run: $0 implement"
}

# ---------------------------------------------------------------- implement
impl_prompt() {  # impl_prompt <id> <title> <attempt>
  local extra=""
  [ "$3" -gt 1 ] && extra="
NOTE: a previous session on this task ran out of turns. Start with 'git status', 'git diff' and the $1 lines in $PROG, then continue from where it stopped. Don't redo finished work."
  cat <<EOF
You are implementing ONE task of a plan, unattended, with a hard limit of $MAX_TURNS turns. Be economical: read only what this task needs, don't re-read files, batch shell commands, and never ask questions.
Context: docs/spec.md (design) and docs/plan.md (full plan). Your task is '### Task $1: $2' in docs/plan.md. Do only this task.
Use the superpowers:test-driven-development and superpowers:verification-before-completion skills. Do not brainstorm, re-plan, or start subagents.
Every few steps, append a one-line note to $PROG such as '$1: failing test for X written'.
When the task is done and the tests pass: commit with message '$1: $2', then append the line '$1 DONE' to $PROG and stop.
If something outside this task blocks you, append '$1 BLOCKED: <reason>' to $PROG and stop.$extra
EOF
}

cmd_implement() {
  [ -f "$TASKS" ] || { echo "Run '$0 plan' first."; exit 1; }
  json len "$TASKS" >/dev/null 2>&1 || { echo "$TASKS is not readable JSON - re-run '$0 plan'."; exit 1; }
  while :; do
    local id title depth ok=0
    id=$(json first_todo "$TASKS" 2>/dev/null) || true
    [ -z "$id" ] && { echo "✅ All tasks done."; return; }
    title=$(json field "$TASKS" "$id" title)
    echo "▶ $id: $title"

    for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
      session "$id-$attempt" "$(impl_prompt "$id" "$title" "$attempt")" "" || true
      if grep -q "^$id BLOCKED" "$PROG"; then
        set_status "$id" blocked; echo "⛔ $id blocked — see $PROG"; exit 1
      fi
      if grep -qx "$id DONE" "$PROG"; then
        if [ -n "$TEST_CMD" ] && ! bash -c "$TEST_CMD" >"$LOGS/$id-tests.log" 2>&1; then
          echo "  tests fail despite DONE — retrying"
          grep -vx "$id DONE" "$PROG" >"$PROG.tmp" || true; mv "$PROG.tmp" "$PROG"
          continue
        fi
        ok=1; break
      fi
    done
    if [ "$ok" = 1 ]; then set_status "$id" done; continue; fi

    # Didn't fit: split the remaining work into smaller tasks.
    depth=$(json field "$TASKS" "$id" depth 2>/dev/null) || depth=0
    if [ "$depth" -ge "$MAX_SPLIT_DEPTH" ]; then
      set_status "$id" blocked; echo "⛔ $id still too big after splitting — needs a human"; exit 1
    fi
    echo "  $id didn't fit in $MAX_ATTEMPTS sessions — splitting"
    session "$id-split" \
"Task $id in docs/plan.md could not be finished within the per-session turn limit. Check git log, git status and the $id lines in $PROG to see what is already done. In $TASKS, replace the $id entry with 2 to 4 smaller tasks covering only the REMAINING work, with ids ${id}a, ${id}b, ..., each with \"status\":\"todo\" and \"depth\":$((depth+1)), inserted at $id's position. Add matching '### Task ${id}a: <title>' sections to docs/plan.md under task $id. Change nothing else, then stop." \
      "" || true
    if [ "$(json has_todo "$TASKS" "$id" 2>/dev/null || echo no)" = yes ]; then
      set_status "$id" blocked; echo "⛔ Splitting $id failed — see $LOGS/$id-split.json"; exit 1
    fi
  done
}

case "${1:-}" in
  plan)
    shift
    if [ "${1:-}" = "-i" ] || [ "${1:-}" = "--interactive" ]; then
      INTERACTIVE=1; shift
    fi
    cmd_plan "$*" ;;
  implement) cmd_implement ;;
  status)    json list "$TASKS" ;;
  *)         echo "usage: $0 plan [-i] \"<idea>\" | implement | status"; exit 1 ;;
esac
