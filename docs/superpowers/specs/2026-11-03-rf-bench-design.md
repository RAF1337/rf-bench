# rf-bench design

Date: 2026-11-03
Status: approved by user 2026-11-04

## 1. Intent

rf-bench measures whether a Claude Code *harness* (CLAUDE.md, rules, skills, subagents, memories, settings) makes Claude better at writing Business Central AL code. The model and run settings are held fixed within a comparison and are selectable per run.

It is a new, small, self-built tool. It must not reuse code, tasks, environments or infrastructure from the existing BC-Bench fork (`C:\GeneralDev\AL\BC-Bench`), which the user found heavy and unreliable. BC-Bench and `BC-BenchTaskAndTests` may be used only as *inspiration* for task ideas.

"Better" means more than "compiles and passes tests". It also means the code follows AL coding standards: correct `SetLoadFields`, sensible `ReadIsolation`, no `Commit` in the wrong place, logic in codeunits rather than pages, and so on.

## 2. Goals

- A folder of self-contained AL assignments, with solutions and hidden tests kept apart and never visible to the agent during a run.
- A PowerShell runner that runs a chosen harness profile and model against tasks and grades the result.
- Measure **how many attempts** (1, 2 or 3) Claude needs until a task is fully right.
- Deterministic (non-LLM) grading of coding standards.
- Results stored as JSON and compared across profiles in a static HTML report.

## 3. Non-goals

- Not built on BC-Bench, not using its Continia envs (`TestBcBenchOnPrem`, `TestBCBench`) or its datasets.
- No tasks inside real product repos (Continia Banking etc.). Every task is self-contained.
- No dependencies beyond standard BC (Base App, System App, test framework/libraries).
- No LLM judge in the first version.
- No parallel execution in the first version.
- Not a model benchmark (CentralGauge-style). Model is a parameter, harness is the variable.

## 4. Anti-goals (would be failure even if it "works")

- The agent can read solutions, hidden tests or checks during a run, or results leak between runs.
- The user's own `~/.claude` setup (global CLAUDE.md, plugins such as caveman/superpowers, memories, MCP servers) silently influences runs.
- Standards checks punish valid alternative solutions (different variable names, statement order, formatting).
- Retry feedback tells the agent exactly what to change for standards issues, so attempts 2–3 measure instruction-following instead of the harness.
- The runner becomes heavy and flaky like BC-Bench.

## 5. Decisions made with the user

| Topic | Decision |
|---|---|
| Runner language | PowerShell 7.6+ (`pwsh`). Installed via winget (MSIX build; invoke as `pwsh`, not a fixed path). |
| Task form | Mix: some tasks ship a small purpose-built starter app (bug to fix or feature to add), others are spec text only (greenfield, with fixed object names/IDs). |
| Dependencies | Standard BC only. |
| Hiding solutions | Runner copies only `assignment/` to a temp workspace outside the repo; hidden tests and checks are applied after the agent finishes. |
| Isolation | Clean Claude config per run; only the harness profile under test is installed. |
| First task batch | Claude drafts ~10 tasks (spread over difficulty and AL areas), each with verified solution and tests; user reviews. |
| Scoring | Compiles + hidden tests pass; cost/tokens/time/turns; CodeCop (and other analyzer) warnings; deterministic standards checks. |
| Attempts | One run = up to 3 attempts in the same Claude session, with grader feedback between attempts. Record attempt of first test pass and attempt of fully-right. |
| Feedback between attempts | Compile errors and test failure messages verbatim (like CI). Standards issues reported **only as categories**, no rule name/file/line. |
| Agent tooling during attempt | Agent may compile locally with `alc.exe` against provided symbols. It cannot run hidden tests or publish. |
| Execution order | Sequential. |
| Repeats | `-Repeat N`, default 1. |
| Report | JSON per run + static HTML comparison. |
| BC backend | Local Docker Desktop BC container first (Windows containers). Continia env (`continia.exe`) backend later, behind the same interface. Do not use BC-Bench envs. |
| Docker mode | Docker Desktop normally runs Linux containers (presidio, gliner, ollama). Switch to Windows containers for the bench; switch back to Linux when testing is done. |
| Standards checker | Parse AL with `Microsoft.Dynamics.Nav.CodeAnalysis.dll` from the installed AL extension, inside `pwsh` (DLL targets .NET 10). Spike proved it works (comments/strings ignored, per-variable, multi-line). |

## 6. Architecture

```
rf-bench/
  config/
    bench.json                 # BC version/artifact, container name, model defaults, paths
  profiles/
    baseline/                  # empty harness
    <name>/
      user/                    # copied into the clean CLAUDE_CONFIG_DIR (CLAUDE.md, skills/, agents/, rules/, settings.json, memory files)
      project/                 # copied into the workspace (.claude/, CLAUDE.md)
  tasks/
    <task-id>/
      task.json                # id, title, type (bugfix|feature|greenfield), difficulty, area, categories, timeouts
      assignment/              # ONLY thing the agent sees
        TASK.md                # the assignment text
        app/                   # optional starter app (app.json + src)
      solution/                # never copied to the workspace
        app/                   # reference solution (full app)
        tests/                 # hidden test app (app.json + test codeunits)
        checks.json            # standards checks that apply + parameters
        variants/
          bad/                 # planted-wrong version (must fail intended checks)
          alt/                 # valid alternative (must pass everything)
  src/
    Runner.ps1                 # entry point: Invoke-Bench
    Workspace.psm1             # temp workspace + clean config + profile install
    Agent.psm1                 # claude -p invocation, resume, metrics parsing
    Grader.psm1                # compile, publish, test, analyzers, checks, feedback
    Backend.Docker.psm1        # BcContainerHelper calls
    Backend.Continia.psm1      # later
    Checks/                    # AL parser loader + one file per check
    Report.ps1                 # JSON -> HTML
  results/<runId>/...          # per run JSON, transcripts, grader logs
  docs/
```

### 6.1 Run flow (per task, per repeat)

1. Create workspace `%TEMP%\rf-bench\<runId>\<task-id>\ws` (outside the repo). Copy `assignment/` into it. Copy BC symbols (`.alpackages`) from the container's cache.
2. Create clean config dir `%TEMP%\rf-bench\<runId>\<task-id>\claude-home`. Copy `profiles/<name>/user/*` into it. Copy `profiles/<name>/project/*` into the workspace. Install allowed plugins and write the MCP config for the run (section 11). Pass auth through environment variables only (section 10).
3. Write workspace `.claude/settings.json` deny rules (see 6.3) merged with the profile's project settings.
4. Attempt 1: run `claude -p` in the workspace with the fixed base prompt + `TASK.md`, `--model`, `--max-turns`, `--output-format stream-json`, env `CLAUDE_CONFIG_DIR=<claude-home>`. Capture session id, transcript, cost, tokens, turns, duration.
5. Grade (6.2).
6. If not fully right and attempts < 3: build feedback (6.4), `claude -p --resume <session-id>` with the feedback, go to 5.
7. Scan transcript for leakage (6.3). If found, mark run `invalid`.
8. Clean up: uninstall/unpublish task apps from container, write `result.json`.

### 6.2 Grader

Copies the agent's app out of the workspace into a grader folder (outside the workspace), then:

1. **Compile** agent app with `alc.exe` plus analyzers (CodeCop, UICop, PerTenantExtensionCop; LinterCop optional). Record errors and warning counts per rule.
2. **Publish** agent app + hidden test app to the container, run tests (BcContainerHelper `Run-TestsInBcContainer`). Record pass/fail per test with messages.
3. **Runtime budgets**: hidden tests may measure `SessionInformation.SqlStatementsExecuted()` / `SqlRowsRead()` around calls with enough data seeded (e.g. hundreds of records). Budget tests follow a naming convention (e.g. procedure name prefix `Budget_`) so they report as a separate category and do not count as functional failures.
4. **Standards checks**: run the checks listed in `checks.json` against the agent's source using the AL parser. Each check returns pass/fail findings with file:line (stored in results, not sent to the agent) and a category.

Outcome per attempt:
- `compiled` (bool)
- `testsPassed` (functional tests only)
- `budgetsPassed`
- `checksPassed`
- `analyzerWarnings` (count per rule)
- `fullyRight` = compiled && testsPassed && budgetsPassed && checksPassed

Analyzer warnings are reported but do not block `fullyRight` (open: see section 9).

### 6.3 Isolation and leakage protection

- Workspace and config dir live under `%TEMP%`, not in the repo.
- Clean `CLAUDE_CONFIG_DIR` so user-level CLAUDE.md, plugins, memories and MCP config are absent. Enterprise/managed policy settings cannot be removed; this is accepted and recorded.
- Deny rules in workspace settings: `Read`, `Edit`, `Glob`, `Grep` on the rf-bench repo path and `%TEMP%\rf-bench\**\grader`, plus `Bash`/`PowerShell` commands that mention those paths.
- Deny rules do not fully stop shell access, so after each run the transcript is scanned for the repo path, `solution`, task test codeunit names, and grader paths. Any hit marks the run `invalid` and it is excluded from scores.
- Hidden test app and checks are copied into the grader folder only after the agent's attempt ends.

### 6.4 Feedback between attempts

Fixed template, same for all profiles:
- Compile errors: verbatim compiler output.
- Functional test failures: test name + error message + call stack, verbatim.
- Budget failures: "Performance: <scenario name> used more SQL statements/rows than allowed" — no numbers that reveal the fix.
- Standards failures: categories only, e.g. "Coding standards issues found in: data access performance, transaction handling." Category list is fixed (e.g. `data-access`, `locking-isolation`, `transactions`, `architecture`, `naming-style`, `ui`, `error-handling`).

### 6.5 Agent prompt

A fixed base prompt (same for all profiles) states: the task is in `TASK.md`, the app is in `app/`, how to compile with `alc.exe` (path and symbols location), that hidden tests will be run, and to stop when done. Harness content goes only through the profile, never through the base prompt.

### 6.6 Standards checks

- AL parser: `Microsoft.Dynamics.Nav.CodeAnalysis.dll`, located by searching the newest `ms-dynamics-smb.al-*` extension, overridable in `bench.json`.
- Checks check **properties**, not exact code. First set:
  - `RequiresSetLoadFieldsBeforeRead` (optionally: loaded fields cover fields read afterwards)
  - `ReadIsolationOnCount` / `ReadIsolationOnRead`
  - `NoCommitIn` (procedures/objects)
  - `NoFindMinus` (`Find('-')`/`Find('+')`)
  - `LogicNotOnPage` (no data-modifying calls in page triggers)
  - `NoCalcFieldsInLoop`
  - `UsesEventSubscriber` / `NoModifyOfStandardTable` as needed per task
- `checks.json` per task: list of `{ "check": "<name>", "params": {...}, "category": "<category>" }`.
- Validation per task (`Test-Task`): reference solution passes all tests, budgets and checks; `variants/bad` fails the intended checks; `variants/alt` passes everything.

### 6.7 Backend (Docker first)

- Windows containers mode in Docker Desktop.
- One BC container created with BcContainerHelper from a pinned artifact (`bench.json`), with test toolkit and test libraries.
- Backend interface: `Initialize-Backend`, `Get-Symbols`, `Publish-App`, `Invoke-Tests`, `Remove-App`, `Reset-Backend`.
- Continia backend implements the same interface later using `continia.exe` (path from `bench.json`, default `C:\GeneralDev\AL\Continia Banking Master\Continia Banking\.tools\continia.exe`), against a newly created env, not BC-Bench envs.

### 6.8 Results and report

- `results/<runId>/run.json`: run settings (profile, model, max turns, BC version, git-like hash of tasks/profile content), per task per repeat: attempts with grader outcome, metrics, validity.
- `Report.ps1` builds a static HTML page comparing runs/profiles: % fully right at attempt 1 / ≤2 / ≤3, % tests passed at each attempt, average attempts, cost/tokens/time, analyzer warnings per rule, check failures per category, per-task table.

## 7. First task batch (~10)

Drafted by Claude, spread over:
- Types: bugfix (starter app), feature (starter app), greenfield (spec only).
- Difficulty: easy / medium / hard.
- Areas: table/page extensions, codeunit logic, events/subscribers, posting-like processing, reports/queries, data access performance, error handling, permissions.

Each task is designed so at least one standard *changes the outcome* (e.g. large seeded data so `SetLoadFields` or loop structure shows in SQL budgets). Each passes `Test-Task` before review.

## 8. Builder's choices (left to the implementer)

- Exact module split and function names.
- Exact base prompt wording (must stay profile-neutral).
- HTML report styling.
- BC artifact version (pin a current w1 sandbox build).
- Object ID ranges per task (must not collide between tasks).

## 8a. Claude's calls (made during design, check while reading)

- **Agent permissions:** `claude -p --permission-mode bypassPermissions` inside the temp workspace. The runner's deny rules are merged *last* into the workspace settings, so a profile cannot loosen them. WebFetch and WebSearch are denied by default; a profile can opt in with a flag in its `profile.json`, and the run records it.
- **Docker mode switching:** the runner never switches Docker mode on its own. A preflight check refuses to start when Docker is not in Windows containers mode. An explicit `-SwitchDocker` switch makes the runner switch to Windows mode before the batch and back to Linux in `finally`.
- **Versions:** the Claude Code CLI version is recorded per run, and auto-update is disabled for runs (`DISABLE_AUTOUPDATER=1`). The `alc.exe` and analyzers used by both the agent and the grader come from the pinned BC artifact (or a pinned AL extension version in `bench.json`), not the newest installed extension. All versions go into `run.json`, and the report flags comparisons where versions differ.
- **Rate limits:** the runner detects usage-limit/429 failures, marks the attempt `aborted` (not failed), and can resume a batch from `run.json`.

## 9. Open points

- Whether analyzer warnings should block `fullyRight` (default: no, reported only).

## 10. Authentication (decided with user)

- Start with the user's **subscription**. Be ready to switch to an **API key** without code changes.
- `bench.json` has `auth.mode`: `subscription` or `apiKey`.
  - `subscription`: the user runs `claude setup-token` once. The long-lived token is kept outside the repo (user environment variable or PowerShell SecretManagement; name configurable). The runner passes it to each run as `CLAUDE_CODE_OAUTH_TOKEN`. No credential files are copied into the clean config dir. *(Claude's call: token env var instead of copying `.credentials.json`.)*
  - `apiKey`: the runner passes `ANTHROPIC_API_KEY` from the same kind of store.
- Results record the auth mode. With `subscription`, cost is reported as "estimated". Usage-limit failures are handled as in 8a (attempt `aborted`, batch resumable).

## 11. MCP servers and plugins (decided with user)

Measuring whether Claude does better with access to a given MCP server is an explicit use case.

- **Configurable before a run:** the run settings (profile `profile.json`, overridable on the command line) list the allowed MCP servers, with their configs, and the plugins to install into the clean config dir.
- **MCP mode** per run *(Claude's call on the mechanism)*:
  - `strict` (default): Claude gets only the allowed servers (`--mcp-config` + `--strict-mcp-config`). Account-provided servers, such as claude.ai connectors that come with a subscription login, are switched off.
  - `open`: allowed servers plus whatever is standard available to Claude in that environment (for example claude.ai connectors).
- **Reported for every run and in the final report:**
  - every MCP server that was *available* to Claude (from the session's init event), with connection status;
  - which of those were explicitly allowed and which were *found by Claude itself* (available without being on the allowlist);
  - which servers and tools Claude *actually used*, with call counts per tool per attempt (from `mcp__<server>__<tool>` tool calls in the transcript);
  - plugins installed and their versions.
- Server and plugin versions go into the run hash, so the report can flag comparisons with different MCP setups.
