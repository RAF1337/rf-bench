#Requires -Version 7.6
<#
.SYNOPSIS
    Runs a harness profile against benchmark tasks and writes results/<runId>/run.json.

.DESCRIPTION
    Per (task, repeat), sequentially: fresh workspace -> profile install -> up to MaxAttempts
    Claude attempts in one session (attempt 1 gets the base prompt, later attempts the grader
    feedback with --resume) -> grade after every attempt, stop when fully right -> leak scan
    over all attempt transcripts. run.json is saved after every attempt.

    Task outcome: 'done' (graded to the end), 'aborted' (Claude timeout / rate limit / no
    result, grader infrastructure failure 'infra', or an unexpected error 'error'; resumable)
    or 'invalid' (transcript leak, or the leak scan failed).

.EXAMPLE
    pwsh src/Invoke-Bench.ps1 -Profile baseline -Tasks T001,T002 -Repeat 3
.EXAMPLE
    pwsh src/Invoke-Bench.ps1 -Resume 20261104-101500-baseline
#>
[CmdletBinding()]
param(
    # Folder name under profiles/. Required for a new run; taken from run.json with -Resume.
    [string]$Profile,
    [string[]]$Tasks,
    [string]$Model,
    [ValidateRange(1, 10000)][int]$MaxTurns,
    [ValidateRange(1, 100)][int]$Repeat = 1,
    [ValidateSet('strict', 'open')][string]$McpMode,
    [switch]$AllowWeb,
    [switch]$SwitchDocker,
    [string]$Resume,
    [string]$RunId,
    [switch]$KeepWorkspace,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in 'Config', 'Task', 'Workspace', 'Agent', 'Backend.Docker', 'Grader', 'Feedback', 'LeakScan', 'Results') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1")
}
Import-Module (Join-Path $PSScriptRoot 'Checks\AlParser.psm1')

function Set-EntryValue($Entry, [string]$Name, $Value) {
    if ($Entry.PSObject.Properties[$Name]) { $Entry.$Name = $Value }
    else { $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-EntryValue($Entry, [string]$Name) {
    $p = $Entry.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# A resumed task starts over from attempt 1: the old Claude session cannot be continued.
function Reset-TaskEntry($Entry) {
    $Entry.status = 'pending'
    $Entry.abortReason = $null
    $Entry.leak = [pscustomobject][ordered]@{ leaked = $false; hits = @() }
    $Entry.firstTestsPassAttempt = $null
    $Entry.fullyRightAttempt = $null
    $Entry.attempts = @()
    Set-EntryValue $Entry 'error' $null
}

function Get-TaskEntry($Record, [string]$TaskId, [int]$Rep) {
    @($Record.tasks) | Where-Object { $_.taskId -ceq $TaskId -and $_.repeat -eq $Rep } | Select-Object -First 1
}

function Get-FileVersion([string]$Path) {
    try { (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.FileVersion } catch { $null }
}

# Runs one (task, repeat) and records its outcome in the run record. Failures after the workspace
# exists are turned into an outcome here; setup failures propagate to the caller.
function Invoke-TaskRun {
    param($Ctx, $Task, [int]$Rep)

    $record = $Ctx.Record
    $taskId = $Task.Id
    $ws = New-RunWorkspace -Config $Ctx.Config -Task $Task -RunId $Ctx.RunId -Repeat $Rep
    $installed = Install-Profile -HarnessProfile $Ctx.Profile -Workspace $ws
    $record.mcp.installedPlugins = @($installed.InstalledPlugins | Where-Object { $_ } | ForEach-Object { "$($_.Name)@$($_.Version)" })
    $agentEnv = Get-AgentEnvironment -Config $Ctx.Config -HarnessProfile $Ctx.Profile -Workspace $ws

    $timeout = if ($Task.TimeoutMinutes) { $Task.TimeoutMinutes } else { $Ctx.Config.Claude.TimeoutMinutes }
    $transcriptDir = Join-Path $Ctx.ResultsDir $taskId ([string]$Rep)
    $prompt = $Ctx.BasePrompt
    $sessionId = $null
    $status = 'done'
    $reason = $null
    $errorText = $null

    # A resumed task starts over: drop transcripts of the earlier, abandoned attempts.
    if (Test-Path -LiteralPath $transcriptDir) { Remove-Item -LiteralPath $transcriptDir -Recurse -Force }
    $transcripts = [Collections.Generic.List[string]]::new()

    try {
        for ($n = 1; $n -le $Ctx.MaxAttempts; $n++) {
            # Regenerated every attempt: the agent may have edited it through a shell.
            $null = New-AgentSettings -Config $Ctx.Config -HarnessProfile $Ctx.Profile -Workspace $ws
            $transcript = Join-Path $transcriptDir "attempt$n.jsonl"
            $transcripts.Add($transcript)
            Write-Host "  $taskId/$Rep attempt $n ..."
            $agent = Invoke-ClaudeAttempt -Env $agentEnv -Ws $ws.Ws -Prompt $prompt -Model $Ctx.Model -MaxTurns $Ctx.MaxTurns `
                -TimeoutMinutes $timeout -McpConfigPath $installed.McpConfigPath -McpMode $Ctx.Profile.McpMode `
                -ResumeSessionId $sessionId -TranscriptPath $transcript

            $cli = Get-EntryValue $agent 'CliVersion'
            if ($cli) {
                if (-not $record.versions.cli) { $record.versions.cli = $cli }
                elseif ($record.versions.cli -ne $cli) { Write-Warning "Claude CLI version changed during the run: $($record.versions.cli) -> $cli" }
            }

            if ($agent.Status -eq 'aborted') {
                Add-AttemptRecord $record $taskId $Rep $agent $null ''
                Save-RunRecord $record $Ctx.RunJson
                $status = 'aborted'; $reason = $agent.AbortReason
                break
            }
            if ($agent.SessionId) { $sessionId = $agent.SessionId }

            try {
                $grade = Invoke-Grade -Config $Ctx.Config -Task $Task -AgentAppDir (Join-Path $ws.Ws 'app') -GraderDir $ws.GraderDir -Attempt $n
            }
            catch {
                Write-Warning "$taskId/$Rep attempt ${n}: grading failed: $($_.Exception.Message)"
                Add-AttemptRecord $record $taskId $Rep $agent $null ''
                Save-RunRecord $record $Ctx.RunJson
                $status = 'aborted'; $reason = 'infra'; $errorText = $_.Exception.Message
                break
            }

            $feedback = if ($grade.FullyRight) { '' } else { New-AttemptFeedback $grade }
            Add-AttemptRecord $record $taskId $Rep $agent $grade $feedback
            Save-RunRecord $record $Ctx.RunJson
            if ($grade.FullyRight) { break }
            $prompt = $feedback
        }
    }
    catch {
        # Unexpected failure in the agent call or the record: resumable abort. The transcripts
        # written so far are still scanned below.
        Write-Warning "$taskId/${Rep}: $($_.Exception.Message)"
        $status = 'aborted'; $reason = 'error'; $errorText = $_.Exception.Message
    }

    # Leak scan over every transcript of this (task, repeat), also after an abort.
    $leaked = $false
    $hits = [Collections.Generic.List[object]]::new()
    try {
        foreach ($t in @($transcripts | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $scan = Test-TranscriptLeak -TranscriptPath $t -Config $Ctx.Config -Task $Task -GraderDir $ws.GraderDir
            if ($scan.Leaked) { $leaked = $true }
            foreach ($h in @($scan.Hits)) { if ($null -ne $h) { $hits.Add($h) } }
        }
        if ($leaked) { $status = 'invalid'; $reason = $null }
    }
    catch {
        Write-Warning "$taskId/${Rep}: leak scan failed: $($_.Exception.Message)"
        $status = 'invalid'; $reason = $null; $errorText = "leak scan failed: $($_.Exception.Message)"
    }

    $entry = Get-TaskEntry $record $taskId $Rep
    Set-TaskOutcome $record $taskId $Rep -Status $status -AbortReason $reason -Leak ([pscustomobject]@{ Leaked = $leaked; Hits = $hits.ToArray() })
    if ($null -eq $reason) { $entry.abortReason = $null }
    Set-EntryValue $entry 'error' $errorText
    Save-RunRecord $record $Ctx.RunJson
}

function Write-RunSummary($Record) {
    $rows = foreach ($t in @($Record.tasks)) {
        $atts = @($t.attempts)
        $cost = ($atts | ForEach-Object { Get-EntryValue $_.agent 'CostUsd' } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum
        [pscustomobject][ordered]@{
            Task       = $t.taskId
            Repeat     = $t.repeat
            Status     = $t.status
            Reason     = $t.abortReason
            Attempts   = $atts.Count
            TestsPass  = $t.firstTestsPassAttempt
            FullyRight = $t.fullyRightAttempt
            CostUsd    = [math]::Round([double]$cost, 2)
        }
    }
    Write-Host ''
    Write-Host "Run $($Record.runId) ($($Record.profile.name), $($Record.model))"
    Write-Host (($rows | Format-Table -AutoSize | Out-String).TrimEnd())
}

# --- settings ------------------------------------------------------------------------------------

$cfg = if ($ConfigPath) { Get-BenchConfig -Path $ConfigPath } else { Get-BenchConfig }
$resultsRoot = Join-Path $cfg.RepoRoot 'results'
# pwsh -File passes "T001,T002" as one string.
$taskIds = @($Tasks | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$existing = $null
if ($Resume) {
    if ($RunId -and $RunId -cne $Resume) { throw "-RunId and -Resume name different runs" }
    if ($taskIds) { throw '-Tasks cannot be combined with -Resume (the run plan is fixed)' }
    $RunId = $Resume
}
if (-not $RunId) {
    if (-not $Profile) { throw '-Profile is required for a new run' }
    $RunId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Profile
}
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "invalid run id '$RunId' (letters, digits, '.', '_', '-')" }
$resultsDir = Join-Path $resultsRoot $RunId
$runJson = Join-Path $resultsDir 'run.json'

if ($Resume) {
    $existing = Get-RunRecord $runJson
    $checks = @(
        , @('Profile', $Profile, $existing.profile.name)
        , @('Model', $Model, $existing.model)
        , @('MaxTurns', $(if ($MaxTurns) { [string]$MaxTurns }), [string]$existing.maxTurns)
        , @('McpMode', $McpMode, $existing.mcp.mode)
    )
    foreach ($c in $checks) {
        if ($c[1] -and $c[1] -cne $c[2]) { throw "-$($c[0]) '$($c[1])' differs from run $RunId ('$($c[2])'); a resumed run keeps its settings" }
    }
    $Profile = $existing.profile.name
    $Model = $existing.model
    $MaxTurns = [int]$existing.maxTurns
    $McpMode = $existing.mcp.mode
    $runAllowWeb = [bool](Get-EntryValue $existing.profile 'allowWeb')
    if ($AllowWeb -and -not $runAllowWeb) { throw "-AllowWeb differs from run $RunId; a resumed run keeps its settings" }
}
elseif (Test-Path -LiteralPath $runJson) {
    throw "run $RunId already exists ($runJson); use -Resume $RunId to continue it"
}

$profileDir = Join-Path $cfg.RepoRoot "profiles\$Profile"
if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) { throw "profile '$Profile' not found: $profileDir" }
$harness = Get-BenchProfile -ProfileDir $profileDir
$profileHash = Get-ProfileHash -ProfileDir $profileDir
# CLI flags override profile.json.
if ($McpMode) { $harness.McpMode = $McpMode }
if ($Resume) { $harness.AllowWeb = $runAllowWeb }
elseif ($AllowWeb) { $harness.AllowWeb = $true }
if ($existing -and $existing.profile.hash -ne $profileHash) {
    throw "profile '$Profile' changed since run $RunId started (hash $($existing.profile.hash) -> $profileHash)"
}
if (-not $Model) { $Model = $cfg.Claude.DefaultModel }
if (-not $MaxTurns) { $MaxTurns = [int]$cfg.Claude.MaxTurns }

# --- plan ----------------------------------------------------------------------------------------

if ($existing) {
    $plan = @(Get-PendingWork -RunJson $runJson)
    $ids = @($plan | ForEach-Object { $_.TaskId } | Select-Object -Unique)
    $taskList = if ($ids) { @(Get-BenchTasks -TasksRoot (Join-Path $cfg.RepoRoot 'tasks') -Ids $ids) } else { @() }
}
else {
    $taskList = if ($taskIds) { @(Get-BenchTasks -TasksRoot (Join-Path $cfg.RepoRoot 'tasks') -Ids $taskIds) }
    else { @(Get-BenchTasks -TasksRoot (Join-Path $cfg.RepoRoot 'tasks')) }
    if (-not $taskList) { throw 'no tasks to run' }
    $plan = @(foreach ($t in $taskList) { foreach ($r in 1..$Repeat) { [pscustomobject]@{ TaskId = $t.Id; Repeat = $r } } })
}
$tasksById = @{}
foreach ($t in $taskList) { $tasksById[$t.Id] = $t }

# --- preflight (before any agent call) -----------------------------------------------------------

$alParserDll = Import-AlParser -Config $cfg
$alc = Get-AlcPath $cfg
# Validates that the auth env var is present; the real environment is built per workspace.
$null = Get-AgentEnvironment -Config $cfg -HarnessProfile $harness -Workspace ([pscustomobject]@{ ClaudeHome = ''; Ws = ''; Root = ''; GraderDir = '' })
$basePrompt = Get-BasePrompt -CompilerHint "& `"$alc`" /project:app /packagecachepath:.alpackages /out:app.app"
$maxAttempts = [Math]::Min(3, [int]$cfg.Claude.MaxAttempts)
if ($maxAttempts -lt 1) { throw 'Claude.MaxAttempts must be at least 1' }

$switched = $false
try {
    if ($SwitchDocker) { $switched = $true; Switch-DockerMode -Mode windows }
    else { Assert-DockerWindowsMode }

    if ($existing) {
        $record = $existing
        foreach ($w in $plan) { Reset-TaskEntry (Get-TaskEntry $record $w.TaskId $w.Repeat) }
    }
    else {
        $versions = [pscustomobject][ordered]@{
            cli         = $null
            bcArtifact  = "$($cfg.Bc.ArtifactType)/$($cfg.Bc.Country)/$($cfg.Bc.Version)"
            compiler    = [pscustomobject][ordered]@{ path = $alc; version = (Get-FileVersion $alc) }
            alParserDll = $alParserDll
            pwsh        = $PSVersionTable.PSVersion.ToString()
        }
        $record = New-RunRecord -RunId $RunId -Profile ([pscustomobject]@{ name = $Profile; hash = $profileHash }) -Model $Model `
            -MaxTurns $MaxTurns -AuthMode $cfg.Auth.Mode -McpMode $harness.McpMode -AllowedMcp @($harness.McpServers.Keys) `
            -InstalledPlugins @($harness.Plugins | ForEach-Object { "$($_.Name)@$($_.Marketplace)" }) -Versions $versions -Plan $plan
        $record.profile | Add-Member -NotePropertyName allowWeb -NotePropertyValue $harness.AllowWeb
    }
    Save-RunRecord $record $runJson

    $ctx = [pscustomobject]@{
        Config      = $cfg
        Profile     = $harness
        Record      = $record
        RunId       = $RunId
        RunJson     = $runJson
        ResultsDir  = $resultsDir
        Model       = $Model
        MaxTurns    = $MaxTurns
        MaxAttempts = $maxAttempts
        BasePrompt  = $basePrompt
    }

    Write-Host "Run ${RunId}: $($plan.Count) task run(s), profile $Profile, model $Model, MCP $($harness.McpMode)"
    foreach ($w in $plan) {
        $task = $tasksById[$w.TaskId]
        Write-Host "$($w.TaskId)/$($w.Repeat)"
        try {
            Invoke-TaskRun $ctx $task $w.Repeat
        }
        catch {
            # Unexpected failure (workspace, profile install, agent process): resumable abort.
            Write-Warning "$($w.TaskId)/$($w.Repeat): $($_.Exception.Message)"
            Set-TaskOutcome $record $w.TaskId $w.Repeat -Status aborted -AbortReason 'error'
            Set-EntryValue (Get-TaskEntry $record $w.TaskId $w.Repeat) 'error' $_.Exception.Message
            Save-RunRecord $record $runJson
        }
    }

    if (-not $KeepWorkspace) {
        $tempRoot = Get-CanonicalPath $cfg.TempRoot
        $runTemp = Join-Path $tempRoot $RunId
        if ((Test-Path -LiteralPath $runTemp) -and $runTemp.TrimEnd('\') -ine $tempRoot.TrimEnd('\')) {
            try { Remove-Item -LiteralPath $runTemp -Recurse -Force }
            catch { Write-Warning "could not remove ${runTemp}: $($_.Exception.Message)" }
        }
    }

    Write-RunSummary $record
    Write-Host "run.json: $runJson"
}
finally {
    if ($switched) { Switch-DockerMode -Mode linux }
}
