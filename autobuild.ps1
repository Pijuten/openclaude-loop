<#
autobuild.ps1 — idea -> spec -> bite-sized plan -> unattended implementation
with OpenClaude + Superpowers, keeping EVERY session under a hard turn cap.

  .\autobuild.ps1 plan "a CLI that syncs my dotfiles to S3"
  .\autobuild.ps1 plan -Interactive "..."    # ask clarifying questions first
  .\autobuild.ps1 implement -TestCmd "npm test"
  .\autobuild.ps1 status

Why chunked: some models (e.g. deepseek 4.1 flash) cap a session at ~50 turns.
So the spec and the plan are each produced across several SMALL sessions
(--session-id then --resume), and every task is implemented in its own fresh
session. Nothing ever runs one giant session.

PROVIDER (OpenRouter is NOT a --provider choice; use the OpenAI-compatible path):
  $env:CLAUDE_CODE_USE_OPENAI = "1"
  $env:OPENAI_API_KEY  = "sk-or-..."                     # your OpenRouter key
  $env:OPENAI_BASE_URL = "https://openrouter.ai/api/v1"
  $env:OPENAI_MODEL    = "deepseek/deepseek-chat"        # any OpenRouter model id
  .\autobuild.ps1 plan "..." -Cli "openclaude --provider openai"

Requires: openclaude (provider set up), the Superpowers plugin, git.
Works in Windows PowerShell 5.1 and PowerShell 7+. Run it on a fresh git branch.
#>
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Idea,
  [string]$Cli = "openclaude",
  [int]$MaxTurns = 40,        # hard cap PER SESSION; keep below your 50 limit
  [int]$MaxChunks = 6,        # sessions a single spec/plan may span
  [int]$TaskBudget = 20,      # planner sizes each task to this many tool calls
  [int]$MaxAttempts = 2,      # fresh-session attempts before a task gets split
  [int]$MaxSplitDepth = 2,
  [string]$TestCmd = "",      # e.g. "npm test": independent check after each task
  [string]$Perm = "acceptEdits",  # acceptEdits | bypassPermissions (fully unattended)
  [switch]$Interactive      # 'plan -Interactive': ask clarifying questions first
)

$S = ".autobuild"; $Tasks = "$S/tasks.json"; $Prog = "$S/progress.md"; $Logs = "$S/logs"
$Questions = "$S/questions.md"; $Answers = "$S/answers.md"
# In -p mode only whitelisted tools are auto-approved; everything else
# (including subagents, which would burn turns unpredictably) is denied.
$Tools = "Read,Edit,Write,Glob,Grep,Bash,Skill,TodoWrite"

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Run inside a git repo."; exit 1 }
New-Item -ItemType Directory -Force -Path $Logs, "docs" | Out-Null
if (-not (Test-Path $Prog)) { New-Item -ItemType File -Path $Prog | Out-Null }

$script:Sub = ""   # last session's result subtype

# Invoke-Session <Name> <Prompt> <Sid> [Resume]
# Runs one turn-capped session. The prompt goes in via stdin, which avoids
# Windows' quoting problems with multi-line arguments. Sets $script:Sub.
function Invoke-Session([string]$Name, [string]$Prompt, [string]$Sid, [switch]$Resume) {
  $log = Join-Path $Logs "$Name.json"; $err = Join-Path $Logs "$Name.err"
  $a = @("-p", "--max-turns", $MaxTurns, "--output-format", "json",
         "--permission-mode", $Perm, "--allowedTools", $Tools)
  if ($Sid) { if ($Resume) { $a += @("--resume", $Sid) } else { $a += @("--session-id", $Sid) } }
  # allow -Cli "openclaude --provider openai"
  $cliParts = @($Cli -split '\s+' | Where-Object { $_ })
  $exe = $cliParts[0]
  $all = @()
  if ($cliParts.Count -gt 1) { $all += $cliParts[1..($cliParts.Count - 1)] }
  $all += $a
  $Prompt | & $exe @all 2> $err | Out-File -FilePath $log -Encoding utf8
  $script:Sub = "crashed"; $turns = "?"
  try {
    $r = Get-Content $log -Raw | ConvertFrom-Json
    if ($r.subtype) { $script:Sub = $r.subtype }
    if ($r.num_turns) { $turns = $r.num_turns }
  } catch {}
  Write-Host "  [$Name] $($script:Sub), $turns turns"
}

# Invoke-Chunked <Name> <Prompt> <Continuation> <CheckScriptBlock>
# Runs the work as one or more small sessions. On a turn-cap hit it resumes the
# SAME session; on a premature "success" it resumes until <Check> passes.
# Returns $true only when a session succeeds AND <Check> passes.
function Invoke-Chunked([string]$Name, [string]$Prompt, [string]$Cont, [scriptblock]$Check) {
  $sid = [guid]::NewGuid().ToString()
  for ($c = 1; $c -le $MaxChunks; $c++) {
    if ($c -eq 1) { Invoke-Session "$Name-$c" $Prompt $sid }
    else          { Invoke-Session "$Name-$c" $Cont   $sid -Resume }
    switch ($script:Sub) {
      "success" {
        if (& $Check) { return $true }
        Write-Host "  [$Name] success but artifact check failed; continuing" }
      "error_max_turns" {
        Write-Host "  [$Name] turn cap hit; resuming (chunk $($c + 1)/$MaxChunks)" }
      default {
        Write-Host "  [$Name] session failed ($($script:Sub)) - see $Logs/$Name-$c.json"
        return $false }
    }
  }
  Write-Host "  [$Name] incomplete after $MaxChunks chunks"
  return $false
}

function Get-Tasks {
  $t = ConvertFrom-Json (Get-Content $Tasks -Raw)
  # @() guarantees an array; the leading comma would double-wrap it, making
  # every pipeline element the whole array instead of one task.
  return @($t)
}

function Save-Tasks($list) {
  $json = ConvertTo-Json -InputObject @($list) -Depth 5
  [IO.File]::WriteAllText((Join-Path (Get-Location) $Tasks), $json)
}

function Set-Status([string]$Id, [string]$Status) {
  $list = Get-Tasks
  foreach ($t in $list) { if ($t.id -eq $Id) { $t.status = $Status } }
  Save-Tasks $list
}

function Test-ValidTasks {
  if (-not (Test-Path $Tasks)) { return $false }
  try {
    $t = @(Get-Tasks)
    return ($t.Count -gt 0 -and $null -ne $t[0].id)
  } catch { return $false }
}

function Test-ParsableTasks {
  if (-not (Test-Path $Tasks)) { return $false }
  try { Get-Tasks | Out-Null; return $true } catch { return $false }
}

function Get-ProgLines { return @(Get-Content $Prog) }

# Ask-Questions <idea>
# Writes .autobuild/questions.md from a small session, then collects answers.
# Answers come from (in order): an existing $Answers file, piped stdin, or the
# terminal. Sessions stay non-interactive, so a 50-turn cap can never stall here.
function Invoke-Questions([string]$IdeaText) {
  if ((Test-Path $Answers) -and (Get-Item $Answers).Length -gt 0) {
    Write-Host "Using existing $Answers"; return
  }

  Invoke-Chunked "questions" @"
Read the idea below. Write 3 to 6 short clarifying questions whose answers would
most change the design. Put them in ${Questions} as a numbered list, one line each,
with no preamble and no answers. Then stop.
Idea: $IdeaText
"@ "Continue exactly where you left off. If ${Questions} is not yet written, write it now. Then stop." { (Test-Path $Questions) -and (Get-Item $Questions).Length -gt 0 } | Out-Null

  if (-not (Test-Path $Questions) -or (Get-Item $Questions).Length -eq 0) {
    Write-Host "  (could not generate questions; continuing without them)"; return
  }

  Write-Host ""; Get-Content $Questions | ForEach-Object { Write-Host $_ }; Write-Host ""

  if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    $out = New-Object Collections.Generic.List[string]
    $out.Add("Answers to the questions above:")
    $an = 0
    foreach ($l in ($raw -split "`r?`n")) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      $an++
      $out.Add("Q${an}: $l")
    }
    $out | Set-Content $Answers
    Write-Host "Read answers from stdin -> $Answers"; return
  }

  # Read exactly as many answers as there are numbered questions.
  $nq = @(Get-Content $Questions | Where-Object { $_ -match '^\s*\d+[.)]' }).Count
  if ($nq -lt 1) { $nq = @(Get-Content $Questions).Count }
  Write-Host "Answer each question on one line. Leave a line blank to let me decide."
  $out = New-Object Collections.Generic.List[string]
  for ($qn = 1; $qn -le $nq; $qn++) {
    Write-Host -NoNewline "Q${qn}> "
    $line = Read-Host
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $out.Add("Q${qn}: $line")
  }
  if ($out.Count) { $out | Set-Content $Answers; Write-Host "Saved answers -> $Answers" }
  else { Write-Host "  (no answers given; I'll make reasonable decisions)" }
}

# ---------------------------------------------------------------- plan
function Invoke-Plan([string]$IdeaText) {
  if (-not $IdeaText) { Write-Host 'usage: .\autobuild.ps1 plan "<idea>"'; exit 1 }

  if ($Interactive -and (-not (Test-Path "docs/spec.md") -or (Get-Item "docs/spec.md").Length -eq 0)) {
    Invoke-Questions $IdeaText
  }
  $ctx = ""
  if ((Test-Path $Answers) -and (Get-Item $Answers).Length -gt 0) {
    $ctx = "`nThe human answered clarifying questions; treat these as requirements:`n" + (Get-Content $Answers -Raw)
  }

  if (-not (Test-Path "docs/spec.md") -or (Get-Item "docs/spec.md").Length -eq 0) {
    $ok = Invoke-Chunked "spec" @"
Use the superpowers:brainstorming skill to turn the idea below into a design spec.
You are running unattended: do NOT ask questions or wait for approval. Make sensible decisions and list them under an 'Assumptions' heading.
Scope it as an MVP. Save the spec to docs/spec.md, then stop.
Idea: $IdeaText$ctx
"@ "Continue exactly where you left off. If docs/spec.md is not yet written, write it now. Then stop." { (Test-Path "docs/spec.md") -and (Get-Item "docs/spec.md").Length -gt 0 }
  }
  if (-not (Test-Path "docs/spec.md") -or (Get-Item "docs/spec.md").Length -eq 0) {
    Write-Host "Spec was not written; see $Logs/spec-*.json"; exit 1
  }

  $ok = Invoke-Chunked "plan" @"
Read docs/spec.md and use the superpowers:writing-plans skill to write docs/plan.md.
HARD CONSTRAINT: each task will be executed by a FRESH agent with no memory, limited to about $TaskBudget tool calls in total (reading, editing, running tests, committing). Size every task to fit comfortably: one behaviour, ideally 3 files or fewer, its own tests. Prefer many small tasks over few large ones. Order tasks so each one leaves the repo building with tests passing. Each task must be self-contained: exact file paths, what to test, and what 'done' means.
Head each task '### Task T01: <title>', '### Task T02: <title>', and so on.
Also write ${Tasks}: a JSON array like [{"id":"T01","title":"...","est_tool_calls":12,"status":"todo","depth":0}] with one entry per task, same ids and order. Then stop.
"@ "Continue exactly where you left off. Finish docs/plan.md and ${Tasks}, then stop." { (Test-Path "docs/plan.md") -and (Get-Item "docs/plan.md").Length -gt 0 -and (Test-ValidTasks) }

  if (-not (Test-ValidTasks)) { Write-Host "No valid $Tasks; see $Logs/plan-*.json"; exit 1 }

  foreach ($i in 1..3) {
    $big = (Get-Tasks | Where-Object { [int]$_.est_tool_calls -gt $TaskBudget } |
            ForEach-Object { $_.id }) -join ","
    if (-not $big) { break }
    Write-Host "Tasks over budget: $big - asking planner to split (round $i)"
    Invoke-Session "resplit-$i" @"
Tasks $big in docs/plan.md and $Tasks are estimated above $TaskBudget tool calls. Split each into smaller tasks (ids like T03a, T03b) in place, keeping order and depth, and update both files consistently. Change nothing else, then stop.
"@ ""
  }
  Write-Host "Plan ready: $((Get-Tasks).Count) tasks. Review docs/plan.md, then run: .\autobuild.ps1 implement"
}

# ---------------------------------------------------------------- implement
function Get-ImplPrompt([string]$Id, [string]$Title, [int]$Attempt) {
  $extra = ""
  if ($Attempt -gt 1) {
    $extra = "`nNOTE: a previous session on this task ran out of turns. Start with 'git status', 'git diff' and the $Id lines in $Prog, then continue from where it stopped. Don't redo finished work."
  }
  return @"
You are implementing ONE task of a plan, unattended, with a hard limit of $MaxTurns turns. Be economical: read only what this task needs, don't re-read files, batch shell commands, and never ask questions.
Context: docs/spec.md (design) and docs/plan.md (full plan). Your task is '### Task ${Id}: $Title' in docs/plan.md. Do only this task.
Use the superpowers:test-driven-development and superpowers:verification-before-completion skills. Do not brainstorm, re-plan, or start subagents.
Every few steps, append a one-line note to $Prog such as '${Id}: failing test for X written'.
When the task is done and the tests pass: commit with message '${Id}: $Title', then append the line '$Id DONE' to $Prog and stop.
If something outside this task blocks you, append '$Id BLOCKED: <reason>' to $Prog and stop.$extra
"@
}

function Invoke-Implement {
  if (-not (Test-Path $Tasks)) { Write-Host "Run '.\autobuild.ps1 plan' first."; exit 1 }
  if (-not (Test-ValidTasks)) { Write-Host "$Tasks is not a valid non-empty task array - re-run '.\autobuild.ps1 plan'."; exit 1 }
  while ($true) {
    $task = Get-Tasks | Where-Object { $_.status -eq "todo" } | Select-Object -First 1
    if (-not $task) { Write-Host "All tasks done."; return }
    $id = [string]$task.id; $title = [string]$task.title
    Write-Host "> ${id}: $title"
    $ok = $false

    foreach ($attempt in 1..$MaxAttempts) {
      Invoke-Session "$id-$attempt" (Get-ImplPrompt $id $title $attempt) ""
      $lines = Get-ProgLines
      if ($lines | Where-Object { $_.StartsWith("$id BLOCKED") }) {
        Set-Status $id "blocked"; Write-Host "BLOCKED: $id - see $Prog"; exit 1
      }
      if ($lines -contains "$id DONE") {
        if ($TestCmd) {
          cmd /c $TestCmd *> (Join-Path $Logs "$id-tests.log")
          if ($LASTEXITCODE -ne 0) {
            Write-Host "  tests fail despite DONE - retrying"
            # Write directly: piping an EMPTY result into Set-Content is a no-op,
            # which would leave the stale DONE marker in place and let the next
            # attempt "succeed" without doing anything.
            $keep = @($lines | Where-Object { $_ -ne "$id DONE" })
            $body = if ($keep.Count) { ($keep -join [Environment]::NewLine) + [Environment]::NewLine } else { "" }
            [IO.File]::WriteAllText((Join-Path (Get-Location) $Prog), $body)
            continue
          }
        }
        $ok = $true; break
      }
    }
    if ($ok) { Set-Status $id "done"; continue }

    # Didn't fit: split the remaining work into smaller tasks.
    $depth = [int]$task.depth
    if ($depth -ge $MaxSplitDepth) {
      Set-Status $id "blocked"; Write-Host "BLOCKED: $id still too big after splitting - needs a human"; exit 1
    }
    Write-Host "  $id didn't fit in $MaxAttempts sessions - splitting"
    $next = $depth + 1
    Invoke-Session "$id-split" @"
Task $id in docs/plan.md could not be finished within the per-session turn limit. Check git log, git status and the $id lines in $Prog to see what is already done. In $Tasks, replace the $id entry with 2 to 4 smaller tasks covering only the REMAINING work, with ids ${id}a, ${id}b, ..., each with "status":"todo" and "depth":$next, inserted at ${id}'s position. Add matching '### Task ${id}a: <title>' sections to docs/plan.md under task $id. Change nothing else, then stop.
"@ ""
    if (Get-Tasks | Where-Object { $_.id -eq $id -and $_.status -eq "todo" }) {
      Set-Status $id "blocked"; Write-Host "BLOCKED: splitting $id failed - see $Logs/$id-split.json"; exit 1
    }
  }
}

switch ($Command) {
  "plan"      { Invoke-Plan ($Idea -join " ") }
  "implement" { Invoke-Implement }
  "status"    {
    if (-not (Test-ParsableTasks)) { Write-Host "No readable $Tasks - run '.\autobuild.ps1 plan' first."; exit 3 }
    Get-Tasks | ForEach-Object { "{0}`t{1}`t{2}" -f $_.status, $_.id, $_.title }
  }
  default     { Write-Host 'usage: .\autobuild.ps1 plan "<idea>" | implement [-TestCmd "npm test"] | status'; exit 1 }
}
