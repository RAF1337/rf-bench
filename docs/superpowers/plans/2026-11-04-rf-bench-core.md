# rf-bench Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working PowerShell bench that runs a Claude Code harness profile against self-contained AL tasks in a local Docker BC container, grades each attempt (compile, hidden tests, SQL budgets, analyzers, parser-based standards checks), retries up to 3 attempts with category-only feedback, and produces JSON results plus an HTML comparison report. Proven end to end with 2 sample tasks.

**Architecture:** Small `pwsh` modules under `src/`, one responsibility each, glued by `src/Invoke-Bench.ps1`. Backend calls (BcContainerHelper) and agent calls (`claude -p`) sit behind thin functions so everything else is unit-tested with Pester mocks. Standards checks use the AL compiler's own parser (`Microsoft.Dynamics.Nav.CodeAnalysis.dll`).

**Tech Stack:** PowerShell 7.6 (`pwsh`), Pester 5.9.1, BcContainerHelper 6.1.15, Docker Desktop (Windows containers), Claude Code CLI 2.1.x, AL compiler from a BcContainerHelper compiler folder.

**Spec:** `docs/superpowers/specs/2026-11-03-rf-bench-design.md`

**Out of scope here:** tasks 3–10 of the first batch (plan 2), Continia backend (plan 3).

## Global Constraints

- Runner runs under `pwsh` 7.6+, invoked as `pwsh` (MSIX install, no fixed path). Every script starts with `#Requires -Version 7.6`.
- No code, tasks, environments or data from `C:\GeneralDev\AL\BC-Bench` or `BC-BenchTaskAndTests`.
- Tasks depend on standard BC only (Base App, System App, test libraries).
- Agent sees only `assignment/` copied to `%TEMP%\rf-bench\<runId>\<taskId>\<repeat>\ws`. Never anything under the repo or `...\grader`.
- Each run uses a clean `CLAUDE_CONFIG_DIR` at `%TEMP%\rf-bench\<runId>\<taskId>\<repeat>\claude-home`.
- Max 3 attempts per run, same Claude session (`--resume`).
- Feedback: compile errors and functional test failures verbatim; budget failures as "Performance: <scenario> used more SQL statements/rows than allowed"; standards only as category names.
- Fixed categories: `data-access`, `locking-isolation`, `transactions`, `architecture`, `naming-style`, `ui`, `error-handling`.
- `fullyRight = compiled && testsPassed && budgetsPassed && checksPassed`. Analyzer warnings are reported only.
- Budget tests: test procedure names start with `Budget_`.
- Auth: `bench.json` `auth.mode` = `subscription` (env `CLAUDE_CODE_OAUTH_TOKEN`) or `apiKey` (env `ANTHROPIC_API_KEY`). Token read from a user env var whose name is configured. No credential files copied.
- MCP mode `strict` (default: `--mcp-config` + `--strict-mcp-config`, claude.ai connectors off) or `open`.
- Agent runs with `--permission-mode bypassPermissions`. Runner deny rules merged last. WebFetch/WebSearch denied unless profile `allowWeb: true`.
- `DISABLE_AUTOUPDATER=1` for every agent call. CLI, compiler, BC artifact, plugin and MCP versions recorded in `run.json`.
- Runner never switches Docker mode unless `-SwitchDocker`; then it switches back to Linux in `finally`.
- Usage-limit/429 failures mark the attempt `aborted`; batch is resumable.
- Commit messages end with: `Claude-Session: https://claude.ai/code/session_01Lw1M7Qm2qSbXXuXZdqst74`

## Review Focus

1. **Shell bypass of deny rules** — agent runs `Get-Content C:\GeneralDev\al\rf-bench\tasks\...` through PowerShell. Expected: leak scan marks the run `invalid`. Test in Task 8.
2. **Agent leaves app uncompilable or deletes `app.json`** — expected: attempt graded `compiled=false` with compiler output as feedback, no runner crash. Test in Task 7.
3. **Claude process hangs or exceeds the task timeout** — expected: process killed, attempt `aborted` with reason `timeout`, batch continues. Test in Task 5.
4. **Stale apps left in the container by a previous crashed run** — expected: grader removes any app with the task's app id before publishing. Test in Task 6.
5. **AL parser DLL missing or wrong version** — expected: clear error naming the searched paths, before any agent call. Test in Task 2.

---

## File Structure

```
rf-bench/
  .gitignore                       # results/, *.app, .alpackages/
  config/bench.json                # all settings (Task 1)
  profiles/
    baseline/profile.json          # empty harness (Task 4)
    example-rules/                 # sample harness for smoke test (Task 11)
  tasks/                           # T001, T002 (Task 10)
  src/
    Config.psm1                    # Get-BenchConfig
    Checks/AlParser.psm1           # Import-AlParser, Get-AlSyntaxTree, Get-AlProcedureInfo
    Checks/Checks.psm1             # Invoke-AlChecks + one function per check
    Task.psm1                      # Get-BenchTask, Get-BenchTasks
    Workspace.psm1                 # New-RunWorkspace, Install-Profile, New-AgentSettings
    Agent.psm1                     # Invoke-ClaudeAttempt, ConvertFrom-ClaudeStream
    Backend.Docker.psm1            # Docker + BcContainerHelper wrapper
    Grader.psm1                    # Invoke-Grade
    Feedback.psm1                  # New-AttemptFeedback
    LeakScan.psm1                  # Test-TranscriptLeak
    Results.psm1                   # New-RunRecord, Save-RunRecord, Get-PendingWork
    Invoke-Bench.ps1               # entry point
    Test-Task.ps1                  # validates a task (reference/bad/alt)
    Initialize-Backend.ps1         # one-time container + compiler folder
    New-Report.ps1                 # JSON -> HTML
  tests/                           # Pester: <Module>.Tests.ps1, fixtures/
  docs/
```

Shared object shapes (PSCustomObject; property names are the contract):

- **BenchConfig**: `RepoRoot, TempRoot, Bc{ArtifactType, Country, Version, ContainerName, CompilerFolder, Credential{User, PasswordEnvVar}}, Claude{DefaultModel, MaxTurns, TimeoutMinutes, MaxAttempts}, Auth{Mode, TokenEnvVar, ApiKeyEnvVar}, Paths{AlParserDll}`
- **BenchTask**: `Id, Title, Type, Difficulty, Area, Categories[], Root, AssignmentDir, SolutionAppDir, TestsDir, ChecksFile, BadDir, AltDir, AppId, TestAppId, TimeoutMinutes`
- **Finding**: `Check, Category, File, Line, Passed, Detail`
- **AttemptResult** (from Agent): `SessionId, ExitCode, Status ('ok'|'aborted'), AbortReason, CostUsd, InputTokens, OutputTokens, CacheReadTokens, Turns, DurationMs, Model, CliVersion, McpServers[{Name, Status}], ToolUses[{Tool, Count}], TranscriptPath`
- **GradeResult**: `Compiled, CompileErrors[], AnalyzerWarnings{rule=count}, Tests[{Codeunit, Name, Passed, Message, CallStack, IsBudget}], TestsPassed, BudgetsPassed, Findings[Finding], ChecksPassed, FullyRight`

---

### Task 1: Repo scaffold and config

**Files:**
- Create: `.gitignore`, `config/bench.json`, `src/Config.psm1`, `tests/Config.Tests.ps1`, `README.md`

**Interfaces:**
- Produces: `Get-BenchConfig([string]$Path = "$RepoRoot/config/bench.json") -> BenchConfig`. Expands `%TEMP%` and env vars in path values. Throws `"bench.json: missing <key>"` on a missing required key.

- [ ] **Step 1:** `git init`, add `.gitignore` (`results/`, `*.app`, `.alpackages/`, `.output/`).
- [ ] **Step 2: Write failing tests** in `tests/Config.Tests.ps1`:
  - `It 'loads defaults'`: `(Get-BenchConfig).Claude.MaxAttempts | Should -Be 3`; `.Auth.Mode | Should -Be 'subscription'`; `.TempRoot | Should -Be (Join-Path $env:TEMP 'rf-bench')`.
  - `It 'throws on missing key'`: config file without `Bc` -> `Should -Throw '*missing Bc*'`.
  - `It 'rejects unknown auth mode'`: `Auth.Mode='foo'` -> `Should -Throw '*auth.mode*'`.
- [ ] **Step 3: Run** `pwsh -NoProfile -c "Invoke-Pester tests/Config.Tests.ps1 -Output Detailed"`. Expected: FAIL (module missing).
- [ ] **Step 4: Implement** `config/bench.json` with: `TempRoot "%TEMP%\\rf-bench"`, `Bc.ArtifactType "Sandbox"`, `Bc.Country "w1"`, `Bc.Version` = latest current major resolved once with `Get-BcArtifactUrl -type Sandbox -country w1 -select Latest` and pinned as an exact version string, `Bc.ContainerName "rfbench"`, `Bc.CompilerFolder ""` (filled by Task 6), `Bc.Credential.User "admin"`, `Bc.Credential.PasswordEnvVar "RFBENCH_BC_PASSWORD"`, `Claude.DefaultModel "claude-opus-5-5"`, `Claude.MaxTurns 60`, `Claude.TimeoutMinutes 30`, `Claude.MaxAttempts 3`, `Auth.Mode "subscription"`, `Auth.TokenEnvVar "RFBENCH_CLAUDE_OAUTH_TOKEN"`, `Auth.ApiKeyEnvVar "RFBENCH_ANTHROPIC_API_KEY"`, `Paths.AlParserDll ""` (empty = auto-locate). Then `Get-BenchConfig`.
- [ ] **Step 5: Run tests.** Expected: PASS.
- [ ] **Step 6:** `README.md` with prerequisites (pwsh 7.6, Docker Windows mode, BcContainerHelper, `claude setup-token` into `RFBENCH_CLAUDE_OAUTH_TOKEN`) and the commands added by later tasks.
- [ ] **Step 7: Commit** `chore: scaffold rf-bench repo and config`.

### Task 2: AL parser and standards checks

**Files:**
- Create: `src/Checks/AlParser.psm1`, `src/Checks/Checks.psm1`, `tests/Checks.Tests.ps1`, `tests/fixtures/al/good/*.al`, `tests/fixtures/al/bad/*.al`

**Interfaces:**
- Consumes: `BenchConfig.Paths.AlParserDll`, `BenchConfig.Bc.CompilerFolder`.
- Produces:
  - `Import-AlParser([BenchConfig]$Config) -> string` (loaded DLL path). Search order: `Paths.AlParserDll`, then `<CompilerFolder>` recursive, then newest `~/.vscode/extensions/ms-dynamics-smb.al-*/bin`. Throws `"AL parser DLL not found. Searched: <paths>"`.
  - `Get-AlProcedureInfo([string]$File) -> [{Object, ObjectType, Procedure, RecordVars{name=tableName}, Calls[{Var, Method, Args[], Pos, Line}], Assigns[{Var, Prop, Pos, Line}], InLoop(pos)->bool}]`
  - `Invoke-AlChecks([string]$SourceDir, [object[]]$CheckSpecs) -> Finding[]` where a CheckSpec is `{check, category, params}` from `checks.json`.
  - Checks (each `-> Finding[]`, one Finding per evaluated site, `Passed` true/false):
    - `RequiresSetLoadFieldsBeforeRead` params `{tables?: string[], checkFieldCoverage?: bool}` — a `Get/Find/FindFirst/FindLast/FindSet` on a Record var needs `SetLoadFields` on the same var earlier in the procedure; with `checkFieldCoverage`, every `Var."Field"`/`Var.Field` read after the call must be in the SetLoadFields args or be a primary key field listed in `params.keyFields`.
    - `ReadIsolationOnCount` params `{tables?}` — `Count()`/`IsEmpty()` needs an earlier `Var.ReadIsolation :=` assignment.
    - `NoCommitIn` params `{objects?: string[]}` — any `Commit()` in listed objects fails.
    - `NoFindMinus` — `Find('-')`, `Find('+')`, `Find('=')` fail.
    - `NoCalcFieldsInLoop` — `CalcFields` inside a `repeat`/`for`/`while`/`foreach` body fails.
    - `LogicNotOnPage` — `Insert/Modify/Delete/ModifyAll/DeleteAll` invoked inside a page or pageextension fails.
- Port the spike approach (file `scratchpad/spike/check.ps1`, summarised): `[Microsoft.Dynamics.Nav.CodeAnalysis.Syntax.SyntaxTree]::ParseObjectText($text, $path, [Text.Encoding]::UTF8, $null, [Threading.CancellationToken]::None)`, walk `DescendantNodes()`, match type names `MethodDeclarationSyntax`, `VariableDeclarationSyntax` (`.Type` is `RecordTypeReferenceSyntax`), `InvocationExpressionSyntax` whose `.Expression` is `MemberAccessExpressionSyntax`, `AssignmentStatementSyntax`. Line = `$tree.GetLineSpan($node.Span).StartLinePosition.Line + 1`. Also handle trigger declarations (`TriggerDeclarationSyntax`) and `VariableListDeclarationSyntax` (`a, b: Record X`) — confirm exact type names by dumping node types on fixtures first.

- [ ] **Step 1: Write fixtures**: `good/` and `bad/` codeunits plus one page, covering: read inside comment, `SetLoadFields` inside a string literal, `SetLoadFields` on other var, after `Get`, multi-line call, `a, b: Record Customer` list declaration, `Commit()`, `Find('-')`, `CalcFields` in `repeat`, `Modify()` in a page action trigger, field read not covered by `SetLoadFields`.
- [ ] **Step 2: Write failing tests**, one `Describe` per check:
  - good fixtures: every Finding `Passed | Should -BeTrue`.
  - bad fixtures: exact expected `(File, Line, Check)` tuples, e.g. `RequiresSetLoadFieldsBeforeRead` fails at `Bad.Codeunit.al:10` and `:21`; `ReadIsolationOnCount` fails at `:33`; field-coverage fails on the uncovered field line.
  - `It 'ignores comments and strings'`: no Finding with a Line inside a comment/string.
  - Review Focus 5: `It 'throws with searched paths when DLL missing'`: config with bogus `AlParserDll` and empty extension search root -> `Should -Throw '*Searched:*'`.
- [ ] **Step 3: Run** `Invoke-Pester tests/Checks.Tests.ps1`. Expected: FAIL.
- [ ] **Step 4: Implement** `AlParser.psm1` then `Checks.psm1`.
- [ ] **Step 5: Run tests.** Expected: PASS.
- [ ] **Step 6: Commit** `feat: AL parser-based standards checks`.

### Task 3: Task format and loader

**Files:**
- Create: `src/Task.psm1`, `tests/Task.Tests.ps1`, `tests/fixtures/tasks/TX01/**`, `docs/task-format.md`

**Interfaces:**
- Produces: `Get-BenchTask([string]$TaskDir) -> BenchTask`, `Get-BenchTasks([string]$TasksRoot, [string[]]$Ids) -> BenchTask[]`.
- `task.json` schema: `id` (matches folder), `title`, `type` (`bugfix|feature|greenfield`), `difficulty` (`easy|medium|hard`), `area`, `categories` (subset of the fixed list), `timeoutMinutes?`. `AppId` read from `solution/app/app.json`, `TestAppId` from `solution/tests/app.json`. `checks.json`: array of `{check, category, params}`; `check` must be a known check name, `category` from the fixed list.
- Validation errors throw `"<taskId>: <problem>"`. Required: `assignment/TASK.md`, `solution/app/app.json`, `solution/tests/app.json`, `solution/checks.json`. `bugfix`/`feature` additionally require `assignment/app/app.json`; `greenfield` must not have `assignment/app/src`.
- Assignment `app.json` id equals solution app id (so the agent's app is the one graded and the test app depends on it).

- [ ] **Step 1: Write failing tests**: loads fixture TX01; throws on unknown category, unknown check name, missing `TASK.md`, greenfield with starter source, id/folder mismatch, assignment/solution app id mismatch.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5:** Write `docs/task-format.md` (folder layout, schemas, ID range rule: task `Tnnn` uses objects `50000 + nnn*100` to `+99`, test app objects `70000 + nnn*100` to `+99`).
- [ ] **Step 6: Commit** `feat: task format and loader`.

### Task 4: Workspace, profile install, agent settings

**Files:**
- Create: `src/Workspace.psm1`, `tests/Workspace.Tests.ps1`, `profiles/baseline/profile.json`, `docs/profile-format.md`

**Interfaces:**
- Consumes: `BenchConfig`, `BenchTask`.
- Produces:
  - `New-RunWorkspace([BenchConfig]$Config, [BenchTask]$Task, [string]$RunId, [int]$Repeat) -> {Root, Ws, ClaudeHome, GraderDir}`. Copies `assignment/*` to `Ws`, copies compiler-folder symbols to `Ws/.alpackages`. Creates empty `ClaudeHome` and `GraderDir`.
  - `Get-BenchProfile([string]$ProfileDir) -> {Name, Dir, AllowWeb, McpMode, McpServers{name=config}, Plugins[{Name, Marketplace, MarketplaceSource}]}` from `profile.json` (all optional; defaults `AllowWeb=false`, `McpMode='strict'`).
  - `Install-Profile($Profile, $Workspace) -> {McpConfigPath, InstalledPlugins[{Name, Version}]}`: copy `user/*` into `ClaudeHome`, `project/*` into `Ws`; write `ClaudeHome/rfbench-mcp.json` as `{"mcpServers": {...}}`; for each plugin run `claude plugin marketplace add <source>` and `claude plugin install <name>@<marketplace>` with `CLAUDE_CONFIG_DIR=ClaudeHome`, then read versions from `claude plugin list --json` (verify the flag exists; fall back to parsing text).
  - `New-AgentSettings($Config, $Profile, $Workspace)`: merge `Ws/.claude/settings.json` (profile's, if any) with runner deny rules **last**. Deny list: `Read(<repo>/**)`, `Edit(<repo>/**)`, `Read(<GraderDir>/**)`, `Bash(*rf-bench*)`, `PowerShell(*rf-bench*)`, `Bash(*\\grader*)`, `PowerShell(*\\grader*)`, plus `WebFetch`, `WebSearch` unless `AllowWeb`. Profile `allow` entries matching a denied pattern are removed.
  - `Get-AgentEnvironment($Config, $Profile, $Workspace) -> hashtable`: `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER=1`, auth var per `Auth.Mode` (`CLAUDE_CODE_OAUTH_TOKEN` from `[Environment]::GetEnvironmentVariable(TokenEnvVar,'User')`, or `ANTHROPIC_API_KEY`), and when `McpMode='strict'` `ENABLE_CLAUDEAI_MCP_SERVERS=false` (verify this variable name against current Claude Code docs; record result in `docs/profile-format.md`). Throws `"auth: env var <name> is empty"` if the secret is missing.

- [ ] **Step 1: Write failing tests**:
  - `It 'never copies solution content'`: after `New-RunWorkspace` for fixture TX01, no file under `Ws` matches any file name under `solution/`; `Ws` path does not start with repo root.
  - `It 'deny rules win over profile allow'`: profile settings allow `Read(C:/GeneralDev/al/rf-bench/**)` -> merged settings has it in `deny`, not in `allow`.
  - `It 'denies web unless allowWeb'`.
  - `It 'strict mode disables claude.ai connectors'`, `It 'open mode does not'`.
  - `It 'throws when auth secret missing'`.
  - `It 'writes mcp config'`: `rfbench-mcp.json` equals profile servers.
  - Plugin install: mock `claude` calls; assert the two command lines per plugin with `CLAUDE_CONFIG_DIR` set.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5:** `profiles/baseline/profile.json` = `{"description": "No harness"}`. `docs/profile-format.md` documents `user/`, `project/`, `profile.json` keys.
- [ ] **Step 6: Commit** `feat: run workspace and harness profile install`.

### Task 5: Agent invocation and stream parsing

**Files:**
- Create: `src/Agent.psm1`, `tests/Agent.Tests.ps1`, `tests/fixtures/stream/*.jsonl`, `docs/base-prompt.md`

**Interfaces:**
- Consumes: workspace, env from `Get-AgentEnvironment`, `McpConfigPath`.
- Produces:
  - `Invoke-ClaudeAttempt([hashtable]$Env, [string]$Ws, [string]$Prompt, [string]$Model, [int]$MaxTurns, [int]$TimeoutMinutes, [string]$McpConfigPath, [string]$McpMode, [string]$ResumeSessionId, [string]$TranscriptPath) -> AttemptResult`. Command: `claude -p <prompt> --model <m> --max-turns <n> --output-format stream-json --verbose --permission-mode bypassPermissions --mcp-config <path>` plus `--strict-mcp-config` when strict, plus `--resume <id>` when resuming. Working dir `Ws`. stdout tee'd to `TranscriptPath`. Kill process tree after `TimeoutMinutes` -> `Status='aborted'`, `AbortReason='timeout'`.
  - `ConvertFrom-ClaudeStream([string]$TranscriptPath) -> AttemptResult` (without process fields). From the `system/init` event: `SessionId`, `Model`, `CliVersion` (`claude_code_version`), `McpServers` (`mcp_servers[].name/status`). From `assistant` events: count `tool_use` blocks by `name` into `ToolUses`. From the `result` event: `CostUsd` (`total_cost_usd`), tokens from `usage`, `Turns` (`num_turns`), `DurationMs`. Usage-limit/429: `result.is_error` with a message matching `rate limit|usage limit|429|overloaded` -> `Status='aborted'`, `AbortReason='rate-limit'`.
  - `Get-BasePrompt([string]$CompilerHint) -> string` reading `docs/base-prompt.md` and replacing `{{COMPILE}}`.
- Base prompt content (profile-neutral): task is in `TASK.md`; app lives in `app/` (create it if greenfield, with the object names/IDs from `TASK.md`); compile with `{{COMPILE}}`; hidden tests will be run after you finish; do not create test apps; stop when done.
- `{{COMPILE}}` = `& "<CompilerFolder>\compiler\...\alc.exe" /project:app /packagecachepath:.alpackages /out:app.app` (exact path resolved in Task 6).

- [ ] **Step 1: Capture real fixtures.** Run once by hand with the token set: `claude -p "say hi" --output-format stream-json --verbose --max-turns 1` in an empty temp dir with a clean `CLAUDE_CONFIG_DIR`. Save as `tests/fixtures/stream/hello.jsonl`. Confirm field names used above; adjust the parser spec to the real names. Hand-write `ratelimit.jsonl` and `tooluse.jsonl` (one `mcp__mslearn__microsoft_docs_search` call, two `Bash` calls) from that shape.
- [ ] **Step 2: Write failing tests**: parse `hello.jsonl` (SessionId non-empty, CostUsd > 0, CliVersion matches `^\d+\.\d+\.\d+`); `tooluse.jsonl` -> `ToolUses` has `mcp__mslearn__microsoft_docs_search=1`, `Bash=2`; `ratelimit.jsonl` -> `aborted/rate-limit`. Review Focus 3: `It 'kills and aborts on timeout'` with `claude` replaced by a stub script that sleeps; `TimeoutMinutes` passed as 0.05 -> `AbortReason='timeout'` and stub process gone. Argument test: strict mode includes `--strict-mcp-config`, resume includes `--resume <id>`.
- [ ] **Step 3: Run** — FAIL. **Step 4: Implement.** **Step 5: Run** — PASS.
- [ ] **Step 6: Commit** `feat: claude invocation and stream parsing`.

### Task 6: Docker backend

**Files:**
- Create: `src/Backend.Docker.psm1`, `src/Initialize-Backend.ps1`, `tests/Backend.Docker.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-DockerMode -> 'windows'|'linux'` (`docker version --format '{{.Server.Os}}'`).
  - `Switch-DockerMode([ValidateSet('windows','linux')]$Mode)` via `& "$env:ProgramFiles\Docker\Docker\DockerCli.exe" -SwitchDaemon` when current differs; waits until `Get-DockerMode` returns `$Mode` (max 3 min).
  - `Assert-DockerWindowsMode` throws `"Docker is in linux mode. Switch to Windows containers or pass -SwitchDocker."`.
  - `Initialize-BenchBackend([BenchConfig]$Config)`: `Get-BcArtifactUrl` for the pinned version; `New-BcContainer -accept_eula -containerName rfbench -artifactUrl $url -auth NavUserPassword -credential $cred -includeTestToolkit -includeTestLibrariesOnly -updateHosts -isolation hyperv` if not existing; `New-BcCompilerFolder -artifactUrl $url -includeTestToolkit -includeTestLibrariesOnly` and writes its path into `config/bench.json` `Bc.CompilerFolder`. Idempotent.
  - `Get-AlcPath($Config) -> string` (alc.exe inside the compiler folder).
  - `Invoke-AlCompile($Config, [string]$AppDir, [string]$OutFile, [switch]$EnableAnalyzers) -> {Success, Errors[], Warnings[{Rule, Message, File, Line}], AppFile}` using `Compile-AppWithBcCompilerFolder` with `-EnableCodeCop -EnableUICop -EnablePerTenantExtensionCop` when `$EnableAnalyzers`, `-outputTo` captured and parsed (`(?<file>.+)\((?<line>\d+),\d+\): (?<sev>error|warning) (?<rule>\w+): (?<msg>.+)`).
  - `Publish-BenchApp($Config, [string]$AppFile)` (`Publish-BcContainerApp -sync -install -skipVerification`).
  - `Remove-BenchApp($Config, [guid]$AppId)`: uninstall + unpublish any version with that id; no error if absent.
  - `Invoke-BenchTests($Config, [guid]$TestAppId) -> Tests[{Codeunit, Name, Passed, Message, CallStack, IsBudget}]` via `Run-TestsInBcContainer -extensionId -XUnitResultFileName <tmp> -detailed`, parse the xUnit XML; `IsBudget = Name -like 'Budget_*'`.
  - Credential password from user env var `Bc.Credential.PasswordEnvVar`.

- [ ] **Step 1: Write failing unit tests** with BcContainerHelper functions mocked: compile output parsing (sample error and warning lines -> objects); xUnit parsing from `tests/fixtures/xunit/sample.xml` (one pass, one fail with message, one `Budget_` test); `Assert-DockerWindowsMode` throws in linux mode. Review Focus 4: `It 'removes stale app before publish'` — mock `Get-BcContainerAppInfo` returning the app id -> `Unpublish-BcContainerApp` called.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Integration (manual, tagged `Integration`).** Switch Docker to Windows mode (user approved this for testing). Run `pwsh src/Initialize-Backend.ps1`. Expected: container `rfbench` healthy, compiler folder path written to `bench.json`, `Get-AlcPath` returns an existing file. Then point `Import-AlParser` at the compiler folder and re-run `tests/Checks.Tests.ps1` — PASS.
- [ ] **Step 6: Commit** `feat: docker backend`.

### Task 7: Grader and feedback

**Files:**
- Create: `src/Grader.psm1`, `src/Feedback.psm1`, `tests/Grader.Tests.ps1`, `tests/Feedback.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 `Invoke-AlChecks`, Task 6 backend functions, `BenchTask`, workspace `GraderDir`.
- Produces:
  - `Invoke-Grade($Config, [BenchTask]$Task, [string]$AgentAppDir, [string]$GraderDir, [int]$Attempt) -> GradeResult`. Steps: copy `AgentAppDir` to `GraderDir/attempt<N>/app`; copy `solution/tests` to `GraderDir/attempt<N>/tests`; compile app with analyzers; if failed return `Compiled=false` (tests/checks not run, `FullyRight=false`); `Remove-BenchApp` test app then app; publish app; compile test app against the produced app (add it to the test compile's package cache); publish test app; run tests; run `Invoke-AlChecks` on `GraderDir/attempt<N>/app` with `checks.json`; compute flags; always remove both apps in `finally`.
  - `New-AttemptFeedback([GradeResult]$Grade) -> string`. Sections, in order, only when non-empty: `Compilation failed:` + errors verbatim; `Failing tests:` + `Codeunit::Name: Message` + call stack; `Performance:` + one line per failed budget test, `"<scenario> used more SQL statements/rows than allowed"` where scenario = test name without `Budget_` prefix; `Coding standards issues found in: <categories, comma separated, sorted, distinct>.` Closing line: `Fix the issues and finish again.`

- [ ] **Step 1: Write failing tests** (backend mocked):
  - Review Focus 2: `It 'grades missing app.json as not compiled'` -> `Compiled=$false`, `CompileErrors` non-empty, no publish call, no throw.
  - `It 'budget failure does not fail testsPassed'`.
  - `It 'fullyRight requires checks'`: tests pass, one failed Finding -> `FullyRight=$false`.
  - `It 'analyzer warnings do not block fullyRight'`.
  - `It 'always removes apps'`: publish of test app throws -> `Remove-BenchApp` still called for both ids.
  - Feedback: `It 'never leaks check names, files or lines'`: grade with Finding `{Check='RequiresSetLoadFieldsBeforeRead'; File='Foo.al'; Line=12; Category='data-access'}` -> output contains `data-access`, does not contain `RequiresSetLoadFieldsBeforeRead`, `Foo.al`, `12`.
  - `It 'budget feedback has no numbers'`: message `Should -Not -Match '\d'` apart from scenario name.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: grader and category-only feedback`.

### Task 8: Leak scan and results store

**Files:**
- Create: `src/LeakScan.psm1`, `src/Results.psm1`, `tests/LeakScan.Tests.ps1`, `tests/Results.Tests.ps1`

**Interfaces:**
- Produces:
  - `Test-TranscriptLeak([string]$TranscriptPath, [BenchConfig]$Config, [BenchTask]$Task, [string]$GraderDir) -> {Leaked, Hits[]}`. Scans only `tool_use` inputs and `tool_result` contents (not the prompt). Patterns: repo root (both slash styles, case-insensitive), `GraderDir`, `\solution\`/`/solution/`, test codeunit names from `solution/tests/**/*.al`.
  - `New-RunRecord(...)`, `Add-AttemptRecord(...)`, `Save-RunRecord($Record, $Path)`, `Get-PendingWork([string]$RunJson) -> [{TaskId, Repeat}]`.
  - `run.json` shape: `runId, startedUtc, profile{name, hash}, model, maxTurns, auth{mode}, mcp{mode, allowed[], installedPlugins[]}, versions{cli, bcArtifact, compiler, alParserDll, pwsh}, tasks[{taskId, repeat, status ('done'|'aborted'|'invalid'), leak{leaked, hits}, firstTestsPassAttempt, fullyRightAttempt, attempts[{n, agent: AttemptResult, grade: GradeResult, feedback}]}]`. `firstTestsPassAttempt`/`fullyRightAttempt` are `null` when never reached. MCP `available` per attempt = `AttemptResult.McpServers`; `foundByClaude` = available names not in `allowed`.
  - Profile hash: SHA256 over sorted relative paths + contents of the profile folder + `profile.json`.

- [ ] **Step 1: Write failing tests**: Review Focus 1: `It 'flags shell read of repo'` — fixture transcript with a `PowerShell` tool_use `Get-Content C:\GeneralDev\al\rf-bench\tasks\T001\solution\tests\Foo.Codeunit.al` -> `Leaked=$true`; `It 'ignores repo path in the prompt text'`; `It 'flags test codeunit name in tool output'`. Results: round-trip save/load; `Get-PendingWork` returns only entries without `done`/`invalid` status; `foundByClaude` computed correctly; profile hash stable across runs and changes when a file changes.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: leak scan and run records`.

### Task 9: Orchestrator `Invoke-Bench.ps1`

**Files:**
- Create: `src/Invoke-Bench.ps1`, `tests/Invoke-Bench.Tests.ps1`

**Interfaces:**
- Consumes: all modules above.
- Produces CLI: `pwsh src/Invoke-Bench.ps1 -Profile <name> [-Tasks T001,T002] [-Model <id>] [-MaxTurns n] [-Repeat 1] [-McpMode strict|open] [-AllowWeb] [-SwitchDocker] [-Resume <runId>] [-RunId <id>]` -> writes `results/<runId>/run.json`, transcripts under `results/<runId>/<taskId>/<repeat>/attempt<N>.jsonl`, grader logs, prints a summary table.
- Flow per (task, repeat), sequential: preflight (`Assert-DockerWindowsMode` unless `-SwitchDocker`; `Import-AlParser`; auth env present) -> `New-RunWorkspace` -> `Install-Profile` -> `New-AgentSettings` -> attempt loop (1..MaxAttempts): `Invoke-ClaudeAttempt` (attempt 1 base prompt; later attempts feedback text with `-ResumeSessionId`) -> if `aborted`, record and stop this task -> `Invoke-Grade` on `Ws/app` -> record; stop if `FullyRight` -> `New-AttemptFeedback`. Then `Test-TranscriptLeak` across all attempt transcripts; `invalid` if leaked. `Save-RunRecord` after every attempt. `-SwitchDocker`: `Switch-DockerMode windows` before, `Switch-DockerMode linux` in `finally`. `-Resume` loads `run.json` and runs `Get-PendingWork` only. CLI flags override `profile.json` values.
- Remove `%TEMP%\rf-bench\<runId>` workspace folders at the end unless `-KeepWorkspace`.

- [ ] **Step 1: Write failing tests** (all external modules mocked): stops after attempt that is fully right; uses `--resume` session id on attempt 2; never exceeds 3 attempts; aborted attempt ends the task with status `aborted` and continues to next task; `-SwitchDocker` switches back to linux even when a task throws; `-Resume` runs only pending entries; CLI `-McpMode open` overrides profile `strict`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: bench orchestrator`.

### Task 10: Task validator and 2 sample tasks

**Files:**
- Create: `src/Test-Task.ps1`, `tasks/T001-*/**`, `tasks/T002-*/**`

**Interfaces:**
- Consumes: `Get-BenchTask`, `Invoke-Grade`.
- Produces CLI: `pwsh src/Test-Task.ps1 -Task T001` -> grades `solution/app` (must be `FullyRight`), `solution/variants/bad` (must fail every check name listed in `variants/bad/expected-failures.json`, and nothing else), `solution/variants/alt` (must be `FullyRight`). For bugfix/feature tasks also grades `assignment/app` and requires `FullyRight=$false` (the task is not already solved). Exit code 0 only if all hold.

Sample tasks (Claude drafts; ID ranges per `docs/task-format.md`):
- **T001 bugfix, medium, data-access** — starter app: codeunit computing total `"Credit Limit (LCY)"` of non-blocked customers with a filtering bug (blocked customers included) and no `SetLoadFields`. `TASK.md` describes the bug from a user's point of view. Hidden tests: functional (blocked excluded, empty table -> 0) and `Budget_SumCreditLimit` seeding 500 customers, asserting `SqlRowsRead`/`SqlStatementsExecuted` within reference + 20 %. Checks: `RequiresSetLoadFieldsBeforeRead` (`checkFieldCoverage`), `NoFindMinus`.
- **T002 greenfield, medium, architecture** — spec only: table `"RFB Shipment Note"` + list page + codeunit `"RFB Shipment Note Mgt."` with `procedure CloseNotesForCustomer(CustomerNo: Code[20]): Integer` that closes open notes and returns the count; must use `ReadIsolation` when counting, no `Commit`, no data modification from the page. Hidden tests call the codeunit API. Checks: `ReadIsolationOnCount`, `NoCommitIn`, `LogicNotOnPage`.

- [ ] **Step 1:** Write `Test-Task.ps1` with a failing Pester test using fixture TX01 and mocked grade results (all four rules above).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5:** Author T001 and T002 (assignment, solution app, tests, checks, bad, alt, expected-failures).
- [ ] **Step 6: Verify** `pwsh src/Test-Task.ps1 -Task T001` and `-Task T002` against the container. Expected: exit 0 for both. Adjust tasks, not the validator, until they pass.
- [ ] **Step 7: Commit** `feat: task validator and sample tasks T001-T002`.

### Task 11: HTML report and end-to-end smoke run

**Files:**
- Create: `src/New-Report.ps1`, `tests/New-Report.Tests.ps1`, `tests/fixtures/results/*.json`, `profiles/example-rules/**`

**Interfaces:**
- Produces CLI: `pwsh src/New-Report.ps1 -Runs <runId>[,<runId>...] [-Out results/report.html]` -> single static HTML file (inline CSS, no external scripts), light/dark via `prefers-color-scheme`.
- Content per run (column per run/profile): % fully right at attempt 1 / ≤2 / ≤3; % tests passed at 1 / ≤2 / ≤3; average attempts (unsolved counted as 4, marked); total and per-task cost (labelled "estimated" when auth mode is subscription), tokens, time, turns; analyzer warnings per rule; failed checks per category; MCP table: available servers, allowed, found by Claude, tool call counts per tool; plugins + versions; invalid/aborted counts (excluded from %). Version mismatch banner when CLI, BC artifact, compiler, MCP or plugin versions differ between compared runs. Per-task table with attempt outcomes.

- [ ] **Step 1: Write failing tests**: from two fixture runs, the HTML contains the expected percentages, the "estimated" label, the version mismatch banner when CLI versions differ, an MCP row with `found by Claude`, and excludes `invalid` runs from percentages.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5:** `profiles/example-rules/project/.claude/rules/al-performance.md` with a short rule set about `SetLoadFields`, `ReadIsolation`, no `Commit` in business logic.
- [ ] **Step 6: Smoke run (real):**
  - `pwsh src/Invoke-Bench.ps1 -Profile baseline -Tasks T001,T002`
  - `pwsh src/Invoke-Bench.ps1 -Profile example-rules -Tasks T001,T002`
  - `pwsh src/New-Report.ps1 -Runs <run1>,<run2>`
  - Expected: both runs complete with status `done` (or `aborted` with a stated reason), no `invalid`, report opens and shows both profiles. Inspect one transcript to confirm the clean config: no caveman/superpowers text, MCP list empty in strict mode.
- [ ] **Step 7:** Switch Docker back to Linux mode (`Switch-DockerMode linux`) and confirm `docker ps` shows `presidio-analyzer`, `gliner`, `ollama` again.
- [ ] **Step 8: Commit** `feat: HTML report and smoke-tested end to end`.
