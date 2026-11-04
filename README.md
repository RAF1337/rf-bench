# rf-bench

PowerShell benchmark that measures Claude Code harnesses (profiles) on Business Central AL tasks.

## Prerequisites

- PowerShell (`pwsh`) 7.6 or later
- Docker Desktop in Windows containers mode (the runner only switches modes with `-SwitchDocker`)
- BcContainerHelper (`Install-Module BcContainerHelper`)
- Pester 5.9.1
- Claude Code CLI, logged in. For subscription auth run `claude setup-token` and store the token in the user environment variable `RFBENCH_CLAUDE_OAUTH_TOKEN`. For API key auth set `Auth.Mode` to `apiKey` in `config/bench.json` and store the key in `RFBENCH_ANTHROPIC_API_KEY`.
- BC container password in `RFBENCH_BC_PASSWORD`

## Configuration

All settings live in `config/bench.json`. Machine-specific values go in `config/bench.local.json` (gitignored), which uses the same shape and only needs the keys it overrides; `src/Initialize-Backend.ps1` writes `Bc.CompilerFolder` there. `Get-BenchConfig` (in `src/Config.psm1`) loads `bench.json`, overlays `bench.local.json` from the same folder (nested objects are merged, other values replace), validates the result and expands `%TEMP%` style variables.

## Results

`src/Invoke-Bench.ps1` writes `results/<runId>/run.json` (saved after every attempt) and the
attempt transcripts under `results/<runId>/<taskId>/<repeat>/attempt<N>.jsonl` (the auth secret
is redacted from transcripts and their `.stderr.txt` files). `run.json` shape:

- `runId`, `startedUtc`, `profile{name, hash, allowWeb}`, `model`, `maxTurns`, `auth{mode}`
- `mcp{mode, allowed[], installedPlugins[]}`: `allowed` = the profile's MCP server names,
  `installedPlugins` = the profile's plugins as `name@marketplace`
- `versions`:
  - `cli`, `bcArtifact`, `compiler{path, version}`, `alParserDll`, `pwsh`
  - `mcp`: `serverName -> SHA256` of the compact JSON `{command, args, url}` of the profile's
    server entry (`env` is excluded)
  - `plugins`: `name@marketplace -> version` (`null` until the plugin is installed)
  - `managedSettings`: SHA256 of the Claude Code managed settings file
    (`C:\Program Files\ClaudeCode\managed-settings.json`), `null` when there is none
- `tasks[]`: `taskId`, `repeat`, `status` (`pending`, `done`, `aborted`, `invalid`),
  `abortReason` (`timeout`, `rate-limit`, `no-result`, `no-session`, `infra`, `error`),
  `leak{leaked, hits[]}`, `firstTestsPassAttempt`, `fullyRightAttempt`, `error`,
  `attempts[]{n, agent, grade, feedback, mcp{available, foundByClaude}}`

## Tests

    pwsh -NoProfile -c "Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester tests -Output Detailed"

## Commands

Added by later tasks:

- `src/Initialize-Backend.ps1` - one-time BC container and compiler folder setup
- `src/Test-Task.ps1` - validate a task (reference, bad and alternative solutions)
- `src/Invoke-Bench.ps1` - run profiles against tasks (resumable)
- `src/New-Report.ps1` - turn result JSON into an HTML report
