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

All settings live in `config/bench.json`. `Get-BenchConfig` (in `src/Config.psm1`) loads and validates it and expands `%TEMP%` style variables.

## Tests

    pwsh -NoProfile -c "Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester tests -Output Detailed"

## Commands

Added by later tasks:

- `src/Initialize-Backend.ps1` - one-time BC container and compiler folder setup
- `src/Test-Task.ps1` - validate a task (reference, bad and alternative solutions)
- `src/Invoke-Bench.ps1` - run profiles against tasks (resumable)
- `src/New-Report.ps1` - turn result JSON into an HTML report
