# rf-bench Measurement Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rf-bench results trustworthy: task fingerprints, a reserved-name anti-cheat guard, a test lint, infra failures that never count against Claude, a gold preflight, and paired statistics in the report.

**Architecture:** Extends the existing `pwsh` modules. New pure modules `src/TestLint.psm1`, `src/Stats.psm1` and `src/Gold.psm1`; changes to `Task.psm1`, `Results.psm1`, `Grader.psm1`, `Invoke-Bench.ps1`, `Test-Task.ps1` and `New-Report.ps1`. Everything is unit-tested with Pester and mocks; no container needed.

**Tech Stack:** PowerShell 7.6 (`pwsh`), Pester 5.9.1.

**Spec:** `docs/superpowers/specs/2026-11-03-rf-bench-design.md`, section 12 (and sections 6.2, 6.8 for the existing grader and report).

## Global Constraints

- Every script and module starts with `#Requires -Version 7.6` and `Set-StrictMode -Version Latest`; follow the existing module style (small private helpers, `Export-ModuleMember` at the end, comments only where the reason is not obvious).
- Run the full suite with `pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"` from the repo root; every task ends with the full suite green.
- No container, Docker, Claude CLI or network call in any unit test; mock `Invoke-Grade`, `Invoke-AlCompile` and backend functions as the existing tests do.
- Attempt score: 1 at attempt 1, 2/3 at attempt 2, 1/3 at attempt 3, 0 when never fully right.
- Bootstrap: 10,000 resamples, 95% percentile CI, seed = first 4 bytes (little-endian `int32`, absolute value) of SHA256 over the sorted lines `<taskId>:<hash>` joined with `"`n"`; RNG `System.Random(seed)`.
- Verdict: fewer than 10 paired tasks gives `too few tasks`; else CI lower bound > 0 gives `better`, upper bound < 0 gives `worse`, otherwise `no clear difference`.
- Reserved object name regex (case-insensitive, whole name, quotes removed): `^(Assert|Any|Library( - |\s).*|Test Runner.*)$`.
- Task statuses: `pending`, `done`, `aborted`, `invalid`, `skipped` (new; reason `gold-failed`).
- Config: `Grader.InfraRetries` (int, default 2 when absent).
- Gold cache folder: `<repo>/results/_gold/`, file `<taskId>-<first 16 hex of task hash>.json`, holding `{ taskId, taskHash, bcArtifact, compilerVersion, fullyRight, gradedUtc }`; a cache entry is valid only when all of `taskHash`, `bcArtifact`, `compilerVersion` match.
- Commit messages end with: `Claude-Session: https://claude.ai/code/session_01Lw1M7Qm2qSbXXuXZdqst74`

## Review Focus

1. **Run records written before this plan** (no `versions.tasks`, no `skipped`) — the report must still render them; paired comparison then treats a task's hash as unknown and pairs it only when both runs lack a hash, with a banner line "task hashes unknown". Test in Task 7.
2. **A task with a single counted repeat** — pass^k skips it (needs at least 2 counted repeats); paired comparison still uses it. Test in Task 6.
3. **Reserved-name guard false positives** — an object named `"Library Card"` in the agent's app would be rejected; accepted trade-off, but the message must name the file and object so the agent can rename it. Names like `"Assertion Log"` or `"Anything"` must pass. Test in Task 2.
4. **Lint on comment or string text** — `// Random(` in a comment or `'Today'` in a string must not be flagged. Test in Task 4.
5. **Gold preflight with infra failure** — grading the reference throws: the run must stop before any agent call with a clear error (not mark tasks skipped, not cache a result). Test in Task 5.

---

### Task 1: Task fingerprint, family and split

**Files:**
- Modify: `src/Results.psm1` (generalize hashing), `src/Task.psm1`, `src/Invoke-Bench.ps1`, `docs/task-format.md`
- Test: `tests/Results.Tests.ps1`, `tests/Task.Tests.ps1`, `tests/Invoke-Bench.Tests.ps1`

**Interfaces:**
- Produces: `Get-FolderHash -Path <dir>` (string, lowercase hex SHA256; same algorithm as today's `Get-ProfileHash`, which becomes a thin wrapper calling it). Task objects from `Get-BenchTask` gain `Family` (string or `$null`), `Split` (`'dev'` or `'holdout'`), `Hash` (from `Get-FolderHash $root`). `run.json` gains `versions.tasks` (object `taskId -> hash`) for every planned task.

- [ ] **Step 1: Failing tests**
  - `Results.Tests.ps1`: `Get-FolderHash` gives the same value as `Get-ProfileHash` for one folder; changes when one byte of a nested file changes; changes when a file is renamed; is independent of file creation order.
  - `Task.Tests.ps1`: a task with `"family": "n-plus-one", "split": "holdout"` loads with those values; a task without them has `Family = $null`, `Split = 'dev'`; `"split": "test"` throws `"<id>: invalid split 'test'"`; `"family": 5` throws `"<id>: family must be a string"`; `Hash` is 64 hex chars and changes when `solution/tests` content changes.
  - `Invoke-Bench.Tests.ps1`: a new run writes `versions.tasks.T001` equal to the task's `Hash`; `-Resume` throws `"task 'T001' changed since run <id> started"` when a planned pending task's hash differs from `versions.tasks`; a resumed run whose record has no `versions.tasks` adds it without throwing.
- [ ] **Step 2: Run, confirm failures.**
- [ ] **Step 3: Implement.** Hash covers the whole task folder. Resume check only covers tasks in the pending plan.
- [ ] **Step 4: Update `docs/task-format.md`** task.json table with `family` and `split` and a sentence on the task hash.
- [ ] **Step 5: Full suite green, commit** `feat: task fingerprint, family and split`.

### Task 2: Reserved object-name guard

**Files:**
- Modify: `src/Grader.psm1`
- Test: `tests/Grader.Tests.ps1`

**Interfaces:**
- Produces: private `Get-ReservedObjectViolations([string]$AppDir)` returning `[string[]]` messages of the form `app\src\X.Codeunit.al: object name 'Assert' is reserved by the test framework. Rename the object.` (path relative to the app folder, prefixed `app\`). `Invoke-GradeCore` calls it on the grader copy before compiling; when non-empty: `Compiled = $false`, `CompileErrors = <messages>`, new grade field `Guard = 'reserved-name'` (field present on every grade, `$null` when not triggered), nothing compiled or published.

- [ ] **Step 1: Failing tests.** Object declarations matched for any AL object type with or without id (`codeunit 50100 Assert`, `codeunit 50100 "Library - Sales"`, `interface "Any"`, `page 50101 "test runner x"`) are rejected; `"Assertion Log"`, `"Anything"`, `"My Library Card"`, a name inside a comment (`// codeunit 50100 Assert`) and files under `.alpackages` are not; `Invoke-AlCompile` is never called on a violation; grade `Guard` is `'reserved-name'`; a clean app has `Guard = $null` and grades as before.
- [ ] **Step 2: Run, confirm failures.**
- [ ] **Step 3: Implement** with a regex over each `*.al` file after removing `//` line comments and `/* */` blocks: declaration pattern `(?im)^\s*(table|tableextension|page|pageextension|pagecustomization|codeunit|report|reportextension|query|xmlport|enum|enumextension|interface|permissionset|permissionsetextension|profile|controladdin|entitlement)\s+(\d+\s+)?("[^"]+"|[A-Za-z_][A-Za-z0-9_]*)`, name with quotes removed, then the reserved regex from Global Constraints.
- [ ] **Step 4: Full suite green, commit** `feat: reject agent objects that shadow the test framework`.

### Task 3: Infrastructure failures never count against Claude

**Files:**
- Modify: `src/Grader.psm1`, `src/Invoke-Bench.ps1`, `src/Config.psm1` (default), `config/bench.json`
- Test: `tests/Grader.Tests.ps1`, `tests/Invoke-Bench.Tests.ps1`, `tests/Config.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-Grade` throws `"infra: the test run returned no results"` when `Invoke-BenchTests` returns nothing (replaces the `Test run::Results` pseudo-test). `Get-BenchConfig` returns `Grader.InfraRetries` (default 2 when missing). Invoke-Bench re-calls `Invoke-Grade` for the same attempt up to `InfraRetries` more times after a throw, writing a warning per retry; only after the last failure the task run aborts with reason `infra` (existing behavior).

- [ ] **Step 1: Failing tests.** Grader: zero results throws with that message and still removes both apps. Config: missing `Grader` section gives `InfraRetries = 2`; `"Grader": {"InfraRetries": 0}` gives 0; negative throws. Invoke-Bench: grading throws once then succeeds gives status `done` with one attempt recorded and `Invoke-Grade` called twice; throws 3 times with `InfraRetries = 2` gives `aborted`/`infra` after 3 calls; the agent is not re-invoked between grading retries.
- [ ] **Step 2: Run, confirm failures.**
- [ ] **Step 3: Implement.** Add `"Grader": { "InfraRetries": 2 }` to `config/bench.json`.
- [ ] **Step 4: Full suite green, commit** `feat: retry grading infra errors and treat empty test runs as infra`.

### Task 4: Test lint

**Files:**
- Create: `src/TestLint.psm1`, `tests/TestLint.Tests.ps1`, `tests/TaskLint.Tests.ps1`
- Modify: `src/Test-Task.ps1`, `docs/task-format.md`
- Test: `tests/Test-Task.Tests.ps1`

**Interfaces:**
- Produces: `Get-TestLintFindings -TestsDir <dir>` returning objects `{ File (relative), Line (int), Procedure (string), Rule ('no-assertion' | 'exit-before-assertion' | 'nondeterministic'), Detail (string) }`. `Test-Task.ps1` gains `-LintOnly`: loads the task, runs the lint, prints findings, exits 0 when none and 1 otherwise, with no config, Docker or compiler needed. Without `-LintOnly`, lint runs first and each finding becomes a problem `tests: <File>:<Line> <Rule> <Detail>`; grading continues so all problems are reported.

- [ ] **Step 1: Failing tests (`TestLint.Tests.ps1`, fixture AL written to `$TestDrive`).**
  - `[Test]` procedure with no `Assert.`, `asserterror` or `Error(` gives `no-assertion`; one with `LibraryAssert.AreEqual` passes; one with `asserterror` passes; a non-`[Test]` helper without assertions is ignored; a procedure in a codeunit without `Subtype = Test` is ignored.
  - `exit;` before the first assertion in a `[Test]` procedure gives `exit-before-assertion`; `exit` after an assertion passes.
  - `Random(10)`, `Randomize()`, `CurrentDateTime`, `Today` each give `nondeterministic`; `Any.Integer()` without `Any.SetDefaultSeed`/`Any.SetSeed` in the same codeunit gives `nondeterministic`, with a seed call it passes; `// Random(` in a comment and `'Today'` in a string literal are not flagged; `WorkDate` is not flagged.
  - The `Line` of a finding is the line of the offending token (procedure line for `no-assertion`).
- [ ] **Step 2: `TaskLint.Tests.ps1`:** one `It` per task folder under `tasks/` asserting `Get-TestLintFindings` on its `solution/tests` returns nothing (use `-ForEach` over the discovered folders).
- [ ] **Step 3: Test-Task tests:** `-LintOnly` exits 0 on a clean task without calling `Get-BenchConfig`/`Invoke-Grade`; exits 1 and prints the finding on a task with a lint finding; normal mode adds lint findings to the problems and exits 1 while still grading.
- [ ] **Step 4: Run, confirm failures; implement.** Strip `//` comments, `/* */` blocks and `'...'` string literals (AL doubles `''` inside strings) before matching, keeping line numbers. Find procedures by `[Test]` attribute lines followed by a `procedure` header; body = up to the matching `end;` at the procedure's indentation, or up to the next procedure header.
- [ ] **Step 5: `docs/task-format.md`:** a "Test lint" section listing the three rules.
- [ ] **Step 6: Full suite green (T001/T002 must lint clean; fix their tests if a real finding appears and say so in the report), commit** `feat: lint task tests for hollow and nondeterministic tests`.

### Task 5: Gold preflight

**Files:**
- Create: `src/Gold.psm1`, `tests/Gold.Tests.ps1`
- Modify: `src/Results.psm1` (status `skipped`), `src/Invoke-Bench.ps1`
- Test: `tests/Invoke-Bench.Tests.ps1`, `tests/Results.Tests.ps1`

**Interfaces:**
- Consumes: Task `Hash` (Task 1), `Invoke-Grade`.
- Produces: `Get-GoldResult -Config <cfg> -Task <task> -CacheDir <dir> -BcArtifact <string> -CompilerVersion <string> -GraderDir <dir>` returning `{ FullyRight (bool), Cached (bool) }`; grades `Task.SolutionAppDir` with `Invoke-Grade -Attempt 1` on a miss and writes the cache file (Global Constraints format); exceptions from `Invoke-Grade` propagate and write nothing. `Set-TaskOutcome` accepts `-Status skipped`; `Get-PendingWork` treats `skipped` as not pending. Invoke-Bench gains `-SkipPreflight`; without it, after the Docker check and before the agent loop it calls `Get-GoldResult` for every task in the plan (grader dir `<TempRoot>\<runId>\_grader\_gold\<taskId>`); a task with `FullyRight = $false` gets all its planned task runs `skipped` with `abortReason = 'gold-failed'`, and prints a warning; a throw stops the run before any agent call.

- [ ] **Step 1: Failing tests.** Gold: miss grades once and writes the cache; second call with same inputs returns `Cached = $true` without grading; different `CompilerVersion` re-grades; a not-fully-right result is cached too; a throw writes no file. Results: `skipped` is accepted and excluded from pending work. Invoke-Bench: preflight runs before the first agent call; a gold-failed task is never given to Claude and its runs are `skipped`/`gold-failed`; other tasks run; `-SkipPreflight` never calls `Get-GoldResult`; a preflight throw exits with the error and no `Invoke-ClaudeAttempt` call; on `-Resume`, skipped tasks stay skipped.
- [ ] **Step 2: Run, confirm failures; implement.**
- [ ] **Step 3: Full suite green, commit** `feat: gold preflight with a content-addressed cache`.

### Task 6: Statistics module

**Files:**
- Create: `src/Stats.psm1`, `tests/Stats.Tests.ps1`

**Interfaces:**
- Produces (all pure, input = run records as parsed from `run.json`):
  - `Get-AttemptScore -FullyRightAttempt <int or $null>` returns `[double]` per Global Constraints.
  - `Get-RunScores -Run <record>` returns `{ Auc3 ([double] or $null), PassHatK ([double] or $null), PassHatKTasks (int), PerTask (hashtable taskId -> { Hash, Scores (double[]), FirstTry (hashtable repeat -> bool) }), CostPerSolved ([double] or $null) }` over `done` task runs. pass^k uses tasks with at least 2 counted repeats.
  - `Get-PairedComparison -Baseline <record> -Candidate <record>` returns `{ PairedTasks (int), ExcludedTasks (string[] with reason 'hash differs' or 'missing'), MeanDiff, CiLow, CiHigh, McNemarB (baseline pass, candidate fail), McNemarC, McNemarP, Verdict, HashesUnknown (bool) }`. Per-task score = mean of its counted repeats; McNemar pairs (task, repeat) present and `done` in both.
  - `Get-McNemarExactP -B <int> -C <int>` two-sided exact binomial p (1.0 when B + C = 0).
  - `Get-HolmAdjusted -P <double[]>` returns adjusted p-values in input order.
  - `Get-BootstrapCi -Diffs <double[]> -Seed <int> [-Resamples 10000]` returns `{ Low, High }` percentile 2.5/97.5 (sorted resample means, index `floor(0.025*R)` and `ceil(0.975*R)-1`).
- [ ] **Step 1: Failing tests with exact values.**
  - `Get-AttemptScore`: 1 → 1; 2 → 0.6667 (±1e-4); 3 → 0.3333; `$null` → 0.
  - `Get-McNemarExactP -B 0 -C 6` = 0.03125; `-B 1 -C 5` = 0.21875; `-B 0 -C 0` = 1; symmetric in B and C.
  - `Get-HolmAdjusted @(0.01, 0.04, 0.03)` = `@(0.03, 0.06, 0.06)`; values capped at 1.
  - `Get-BootstrapCi` with all diffs 0.5 gives Low = High = 0.5; same seed gives identical output twice; different seeds may differ; `-Resamples 1000` with diffs `1..20 | % { $_ - 10 }` gives Low < 0 < High.
  - `Get-RunScores`: run fixture with T001 (repeats fully right at 1 and 2) and T002 (repeat 1 never, repeat 2 aborted) gives `Auc3 = (1 + 0.6667 + 0) / 3`, `PassHatK = 1.0` over `PassHatKTasks = 1` (T002 has one counted repeat), `CostPerSolved` = total cost of all attempts / 2.
  - `Get-PairedComparison`: identical runs over 12 tasks give MeanDiff 0, verdict `no clear difference`; candidate better on all 12 tasks gives `better` and CiLow > 0; 5 paired tasks give `too few tasks`; a task with differing hash is excluded with reason `hash differs`; two runs without `versions.tasks` pair all common tasks and set `HashesUnknown`.
- [ ] **Step 2: Run, confirm failures; implement.**
- [ ] **Step 3: Full suite green, commit** `feat: attempt score, pass^k and paired comparison statistics`.

### Task 7: Report: comparison, failure causes, families, holdout, skipped

**Files:**
- Modify: `src/New-Report.ps1`
- Test: `tests/New-Report.Tests.ps1`

**Interfaces:**
- Consumes: `Stats.psm1` (Task 6), task `family`/`split` read from `tasks/<id>/task.json` when the folder exists (unknown otherwise), `versions.tasks`.
- Produces: new report sections with stable ids: `#comparison` (one row per candidate run vs the first run: paired tasks, mean attempt-score difference with CI, McNemar b/c, Holm-adjusted p, verdict; skipped when only one run), `#consistency` (AUC@3, pass^k with task count, cost per solved task per run), `#failure-causes` (final-attempt outcome counts per run, using the existing `Get-AttemptOutcome` labels), `#families` (fully right within 3 and AUC@3 per family per run; tasks without family under `(none)`), `#holdout` (same metrics over holdout tasks; omitted when there are none). The Runs table gains "Skipped (excluded)". The version banner lists tasks whose hashes differ between runs, and "task hashes unknown" for runs without `versions.tasks`. `compare.json` is written next to the HTML with `{ runs: [ { runId, auc3, passHatK, passHatKTasks, costPerSolved, failureCauses } ], comparisons: [ { baseline, candidate, pairedTasks, meanDiff, ciLow, ciHigh, mcnemarB, mcnemarC, p, pHolm, verdict, excluded } ] }`.
- [ ] **Step 1: Failing tests.** Two-run fixture: `#comparison` row shows the verdict and CI; `compare.json` exists with matching numbers; one-run fixture: no `#comparison` section; failure-causes counts match a fixture with one compile failure and one checks failure; family rows appear for a fixture task folder with `family`; holdout section only when a holdout task exists; skipped count shown; an old-format run (no `versions.tasks`, no skipped) renders without error and shows "task hashes unknown".
- [ ] **Step 2: Run, confirm failures; implement** using the existing table helpers (`Add-TableStart`, `Add-Row`, `Add-TableEnd`) and encoding (`E`).
- [ ] **Step 3: Update the `.DESCRIPTION` help of `New-Report.ps1`** with the new metrics, one line each.
- [ ] **Step 4: Full suite green, commit** `feat: paired comparison, consistency and failure causes in the report`.
