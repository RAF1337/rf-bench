#Requires -Version 7.6
# Orchestrator tests. Every module function that touches Claude, Docker, BcContainerHelper,
# the AL parser, the file system outside TestDrive or the user's environment is mocked.
# Results.psm1, Get-BenchProfile and Get-ProfileHash run for real against TestDrive.
BeforeAll {
    $src = Join-Path $PSScriptRoot '..\src'
    foreach ($m in 'Config', 'Task', 'Workspace', 'Agent', 'Backend.Docker', 'Grader', 'Feedback', 'LeakScan', 'Results', 'Gold') {
        Import-Module (Join-Path $src "$m.psm1") -Force
    }
    Import-Module (Join-Path $src 'Checks\AlParser.psm1') -Force
    $script:Bench = Join-Path $src 'Invoke-Bench.ps1'
    # Mock bodies run while Invoke-Bench.ps1 is the current script, so $script: would name the
    # orchestrator's scope; shared mock state lives in one global table instead.
    $global:BT = @{}

    function New-Profile([string]$Name, [hashtable]$Json) {
        $dir = Join-Path $script:Repo "profiles\$Name"
        New-Item -ItemType Directory $dir -Force | Out-Null
        $Json | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'profile.json')
    }

    function Read-Run([string]$RunId) {
        Get-Content (Join-Path $script:Repo "results\$RunId\run.json") -Raw | ConvertFrom-Json
    }

    function Get-TaskEntry($Run, [string]$TaskId, [int]$Repeat = 1) {
        @($Run.tasks) | Where-Object { $_.taskId -eq $TaskId -and $_.repeat -eq $Repeat }
    }

    # $global:BT.Grades: queue of 'right' | 'wrong' | 'throw' per grade call (default 'wrong').
    # $global:BT.Agents: queue of 'ok' | 'aborted' | 'throw' per Claude call (default 'ok').
    function Set-Mocks {
        $global:BT.ClaudeCalls = [Collections.Generic.List[object]]::new()
        $global:BT.GradeCalls = [Collections.Generic.List[object]]::new()
        $global:BT.SettingsCalls = [Collections.Generic.List[object]]::new()
        $global:BT.DockerCalls = [Collections.Generic.List[string]]::new()
        $global:BT.LeakCalls = [Collections.Generic.List[string]]::new()
        $global:BT.Grades = [Collections.Generic.Queue[string]]::new()
        $global:BT.Agents = [Collections.Generic.Queue[string]]::new()
        $global:BT.LeakResult = 'clean'
        $global:BT.InstallFails = $false
        $global:BT.Managed = $null
        $global:BT.HashSuffix = ''
        $global:BT.GoldCalls = [Collections.Generic.List[object]]::new()
        $global:BT.GoldFails = @()
        $global:BT.GoldThrows = $false
        $global:BT.GoldThrowsLeft = 0
        $global:BT.Order = [Collections.Generic.List[string]]::new()
        Mock Get-GoldResult {
            $global:BT.Order.Add("gold:$($Task.Id)")
            $global:BT.GoldCalls.Add([pscustomobject]@{ TaskId = $Task.Id; CacheDir = $CacheDir; BcArtifact = $BcArtifact; CompilerVersion = $CompilerVersion; GraderDir = $GraderDir })
            if ($global:BT.GoldThrowsLeft -gt 0) { $global:BT.GoldThrowsLeft--; throw 'infra: gold grading failed' }
            if ($global:BT.GoldThrows) { throw 'infra: gold grading failed' }
            [pscustomobject]@{ FullyRight = ($Task.Id -notin $global:BT.GoldFails); Cached = $false }
        }
        Mock Get-ManagedSettingsHash { $global:BT.Managed }

        Mock Get-BenchConfig { $global:BT.Config }
        Mock Get-BenchTasks {
            $ids = if ($Ids) { $Ids } else { 'T001', 'T002' }
            foreach ($i in $ids) { [pscustomobject]@{ Id = $i; TimeoutMinutes = $null; TestsDir = 'x'; Hash = "hash-$i$($global:BT.HashSuffix)" } }
        }
        Mock Import-AlParser { 'C:\fake\Microsoft.Dynamics.Nav.CodeAnalysis.dll' }
        Mock Get-AlcPath { 'C:\fake\alc.exe' }
        Mock Assert-DockerWindowsMode { $global:BT.DockerCalls.Add('assert') }
        Mock Switch-DockerMode { $global:BT.DockerCalls.Add("switch:$Mode") }
        Mock Get-AgentEnvironment { @{ CLAUDE_CONFIG_DIR = $Workspace.ClaudeHome; CLAUDE_CODE_OAUTH_TOKEN = 'tok' } }
        Mock Get-BasePrompt { "BASE PROMPT: $CompilerHint" }
        Mock New-RunWorkspace {
            $root = Join-Path $Config.TempRoot "$RunId\$($Task.Id)\$Repeat"
            $ws = Join-Path $root 'ws'
            $grader = Join-Path $Config.TempRoot "$RunId\_grader\$($Task.Id)\$Repeat"
            New-Item -ItemType Directory $ws, (Join-Path $root 'claude-home'), $grader -Force | Out-Null
            [pscustomobject]@{ Root = $root; Ws = $ws; ClaudeHome = (Join-Path $root 'claude-home'); GraderDir = $grader }
        }
        Mock Install-Profile {
            if ($global:BT.InstallFails) { throw 'marketplace unreachable' }
            [pscustomobject]@{ McpConfigPath = (Join-Path $Workspace.ClaudeHome 'rfbench-mcp.json'); InstalledPlugins = @([pscustomobject]@{ Id = 'p1@mk'; Name = 'p1'; Version = '1.2.3' }) }
        }
        Mock New-AgentSettings {
            $global:BT.SettingsCalls.Add([pscustomobject]@{ McpMode = $HarnessProfile.McpMode; AllowWeb = $HarnessProfile.AllowWeb; Ws = $Workspace.Ws })
            Join-Path $Workspace.Ws '.claude\settings.json'
        }
        Mock Invoke-ClaudeAttempt {
            $global:BT.Order.Add('claude')
            $global:BT.ClaudeCalls.Add([pscustomobject]@{
                    Ws = $Ws; Prompt = $Prompt; Model = $Model; MaxTurns = $MaxTurns; TimeoutMinutes = $TimeoutMinutes
                    McpConfigPath = $McpConfigPath; McpMode = $McpMode; ResumeSessionId = $ResumeSessionId; TranscriptPath = $TranscriptPath
                })
            $kind = if ($global:BT.Agents.Count) { $global:BT.Agents.Dequeue() } else { 'ok' }
            if ($kind -eq 'throw') { throw 'claude exploded' }
            New-Item -ItemType Directory (Split-Path $TranscriptPath) -Force | Out-Null
            Set-Content -LiteralPath $TranscriptPath '{}'
            [pscustomobject]@{
                SessionId = $(if ($kind -eq 'nosession') { $null } else { "sess-$($global:BT.ClaudeCalls.Count)" }); ExitCode = 0
                Status = $(if ($kind -eq 'aborted') { 'aborted' } else { 'ok' })
                AbortReason = $(if ($kind -eq 'aborted') { 'rate-limit' } else { $null })
                CostUsd = 0.5; Turns = 4; Model = $Model; CliVersion = '2.5.0'; McpServers = @(); ToolUses = @(); TranscriptPath = $TranscriptPath
            }
        }
        Mock Invoke-Grade {
            $global:BT.GradeCalls.Add([pscustomobject]@{ AgentAppDir = $AgentAppDir; GraderDir = $GraderDir; Attempt = $Attempt })
            $kind = if ($global:BT.Grades.Count) { $global:BT.Grades.Dequeue() } else { 'wrong' }
            if ($kind -eq 'throw') { throw 'container is down' }
            $right = $kind -eq 'right'
            [pscustomobject]@{
                Compiled = $true; CompileErrors = @(); AnalyzerWarnings = @{}; Tests = @(); TestsPassed = $right
                BudgetsPassed = $true; Findings = @(); ChecksPassed = $true; FullyRight = $right
            }
        }
        Mock New-AttemptFeedback { "FEEDBACK $($global:BT.GradeCalls.Count)" }
        Mock Test-TranscriptLeak {
            $global:BT.LeakCalls.Add($TranscriptPath)
            switch ($global:BT.LeakResult) {
                'throw' { throw 'transcript unreadable' }
                'leak' { [pscustomobject]@{ Leaked = $true; Hits = @([pscustomobject]@{ Kind = 'repo-root'; Pattern = 'x' }); ParseErrors = 0 } }
                default { [pscustomobject]@{ Leaked = $false; Hits = @(); ParseErrors = 0 } }
            }
        }
    }
}

AfterAll { Remove-Variable -Name BT -Scope Global -ErrorAction Ignore }

Describe 'Invoke-Bench' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive "repo-$([guid]::NewGuid().ToString('N'))"
        $script:Temp = Join-Path $TestDrive "tmp-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory $script:Repo, $script:Temp -Force | Out-Null
        $global:BT.Config = [pscustomobject]@{
            RepoRoot = $script:Repo; TempRoot = $script:Temp
            Bc       = [pscustomobject]@{ ArtifactType = 'Sandbox'; Country = 'w1'; Version = '29.0.1.2'; ContainerName = 'rfbench'; CompilerFolder = 'C:\fake' }
            Claude   = [pscustomobject]@{ DefaultModel = 'model-default'; MaxTurns = 60; TimeoutMinutes = 30; MaxAttempts = 3 }
            Auth     = [pscustomobject]@{ Mode = 'subscription'; TokenEnvVar = 'X'; ApiKeyEnvVar = 'Y' }
            Paths    = [pscustomobject]@{ AlParserDll = '' }
            Grader   = [pscustomobject]@{ InfraRetries = 0 }
        }
        New-Profile 'strictp' @{ description = 'strict'; mcpMode = 'strict'; mcpServers = @{ mslearn = @{ type = 'http'; url = 'https://x' } }
            plugins = @(@{ name = 'p1'; marketplace = 'mk'; marketplaceSource = 'rf/mk' })
        }
        Set-Mocks
    }

    Context 'attempt loop' {
        It 'stops after the attempt that is fully right' {
            $global:BT.Grades.Enqueue('wrong'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.ClaudeCalls.Count | Should -Be 2
            $t = Get-TaskEntry (Read-Run r1) T001
            $t.status | Should -Be 'done'
            @($t.attempts).Count | Should -Be 2
            $t.fullyRightAttempt | Should -Be 2
        }

        It 'uses the base prompt first, then feedback with --resume of the previous session' {
            $global:BT.Grades.Enqueue('wrong'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.ClaudeCalls[0].ResumeSessionId | Should -BeNullOrEmpty
            $global:BT.ClaudeCalls[0].Prompt | Should -BeLike 'BASE PROMPT: & "C:\fake\alc.exe" /project:app /packagecachepath:.alpackages /out:app.app'
            $global:BT.ClaudeCalls[1].ResumeSessionId | Should -Be 'sess-1'
            $global:BT.ClaudeCalls[1].Prompt | Should -Be 'FEEDBACK 1'
            (Get-TaskEntry (Read-Run r1) T001).attempts[0].feedback | Should -Be 'FEEDBACK 1'
        }

        It 'never exceeds MaxAttempts (3)' {
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.ClaudeCalls.Count | Should -Be 3
            $global:BT.GradeCalls.Attempt | Should -Be @(1, 2, 3)
            $t = Get-TaskEntry (Read-Run r1) T001
            $t.status | Should -Be 'done'
            $t.fullyRightAttempt | Should -BeNullOrEmpty
            @($t.attempts).Count | Should -Be 3
        }

        It 'regenerates the workspace settings before every attempt' {
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.SettingsCalls.Count | Should -Be 3
        }

        It 'grades the workspace app folder into the grader folder' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.GradeCalls[0].AgentAppDir | Should -Be (Join-Path $script:Temp 'r1\T001\1\ws\app')
            $global:BT.GradeCalls[0].GraderDir | Should -Be (Join-Path $script:Temp 'r1\_grader\T001\1')
        }

        It 'writes transcripts to results/<runId>/<taskId>/<repeat>/attempt<N>.jsonl' {
            & $script:Bench -Profile strictp -Tasks T001 -Repeat 2 -RunId r1 6>$null
            $global:BT.ClaudeCalls.TranscriptPath | Should -Contain (Join-Path $script:Repo 'results\r1\T001\1\attempt1.jsonl')
            $global:BT.ClaudeCalls.TranscriptPath | Should -Contain (Join-Path $script:Repo 'results\r1\T001\2\attempt3.jsonl')
            $global:BT.LeakCalls.Count | Should -Be 6
        }

        It 'uses the task timeout when set, else the config timeout' {
            Mock Get-BenchTasks { [pscustomobject]@{ Id = 'T001'; TimeoutMinutes = 7; TestsDir = 'x'; Hash = 'h1' }; [pscustomobject]@{ Id = 'T002'; TimeoutMinutes = $null; TestsDir = 'x'; Hash = 'h1' } }
            $global:BT.Grades.Enqueue('right'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -RunId r1 6>$null
            $global:BT.ClaudeCalls.TimeoutMinutes | Should -Be @(7, 30)
        }
    }

    Context 'aborts and failures' {
        It 'ends the task as aborted when Claude aborts and continues with the next task' {
            $global:BT.Agents.Enqueue('aborted')
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null
            $run = Read-Run r1
            $t1 = Get-TaskEntry $run T001
            $t1.status | Should -Be 'aborted'
            $t1.abortReason | Should -Be 'rate-limit'
            @($t1.attempts).Count | Should -Be 1
            $t1.attempts[0].grade | Should -BeNullOrEmpty
            (Get-TaskEntry $run T002).status | Should -Be 'done'
            $global:BT.GradeCalls.Count | Should -Be 1
        }

        It 'ends the task as aborted (infra) when grading throws and continues' {
            $global:BT.Grades.Enqueue('throw'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null 3>$null
            $run = Read-Run r1
            $t1 = Get-TaskEntry $run T001
            $t1.status | Should -Be 'aborted'
            $t1.abortReason | Should -Be 'infra'
            $t1.error | Should -BeLike '*container is down*'
            @($t1.attempts).Count | Should -Be 1
            (Get-TaskEntry $run T002).status | Should -Be 'done'
        }

        It 'retries grading after an infra error without re-invoking Claude' {
            $global:BT.Config.Grader = [pscustomobject]@{ InfraRetries = 2 }
            $global:BT.Grades.Enqueue('throw'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null
            $t = Get-TaskEntry (Read-Run r1) T001
            $t.status | Should -Be 'done'
            @($t.attempts).Count | Should -Be 1
            $global:BT.GradeCalls.Count | Should -Be 2
            $global:BT.GradeCalls.Attempt | Should -Be @(1, 1)
            $global:BT.ClaudeCalls.Count | Should -Be 1
        }

        It 'aborts as infra only after InfraRetries additional grading failures' {
            $global:BT.Config.Grader = [pscustomobject]@{ InfraRetries = 2 }
            1..3 | ForEach-Object { $global:BT.Grades.Enqueue('throw') }
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null
            $t = Get-TaskEntry (Read-Run r1) T001
            $t.status | Should -Be 'aborted'
            $t.abortReason | Should -Be 'infra'
            $global:BT.GradeCalls.Count | Should -Be 3
            $global:BT.ClaudeCalls.Count | Should -Be 1
        }

        It 'marks the task invalid when the transcript leaked' {
            $global:BT.Grades.Enqueue('right')
            $global:BT.LeakResult = 'leak'
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $t = Get-TaskEntry (Read-Run r1) T001
            $t.status | Should -Be 'invalid'
            $t.leak.leaked | Should -BeTrue
            @($t.leak.hits).Count | Should -Be 1
        }

        It 'marks the task invalid when the leak scan throws' {
            $global:BT.Grades.Enqueue('right')
            $global:BT.LeakResult = 'throw'
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null
            $t = Get-TaskEntry (Read-Run r1) T001
            $t.status | Should -Be 'invalid'
            $t.error | Should -BeLike '*transcript unreadable*'
        }

        It 'ends the task as aborted (no-session) when an ok attempt has no session id' {
            $global:BT.Agents.Enqueue('nosession')
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null 3>$null
            $run = Read-Run r1
            $t1 = Get-TaskEntry $run T001
            $t1.status | Should -Be 'aborted'
            $t1.abortReason | Should -Be 'no-session'
            @($t1.attempts).Count | Should -Be 1
            $t1.attempts[0].grade | Should -BeNullOrEmpty
            $global:BT.GradeCalls.Count | Should -Be 1
            (Get-TaskEntry $run T002).status | Should -Be 'done'
        }

        It 'records an unexpected task error as aborted and continues' {
            $global:BT.Agents.Enqueue('throw')
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null 3>$null
            $run = Read-Run r1
            (Get-TaskEntry $run T001).status | Should -Be 'aborted'
            (Get-TaskEntry $run T001).abortReason | Should -Be 'error'
            (Get-TaskEntry $run T001).error | Should -BeLike '*claude exploded*'
            (Get-TaskEntry $run T002).status | Should -Be 'done'
        }
    }

    Context 'preflight' {
        It 'fails before any agent call when the AL parser DLL is missing' {
            Mock Import-AlParser { throw 'AL parser DLL not found. Searched: a; b' }
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null } | Should -Throw '*AL parser DLL not found*'
            $global:BT.ClaudeCalls.Count | Should -Be 0
        }

        It 'fails before any agent call when the auth env var is missing' {
            Mock Get-AgentEnvironment { throw 'auth: env var X is empty' }
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null } | Should -Throw '*auth*'
            $global:BT.ClaudeCalls.Count | Should -Be 0
        }

        It 'asserts Windows Docker mode and never switches without -SwitchDocker' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.DockerCalls | Should -Be @('assert')
        }

        It 'fails before any agent call when Docker is in linux mode' {
            Mock Assert-DockerWindowsMode { throw 'Docker is in linux mode.' }
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null } | Should -Throw '*linux mode*'
            $global:BT.ClaudeCalls.Count | Should -Be 0
        }

        It 'refuses to overwrite an existing run without -Resume' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null } | Should -Throw '*-Resume*'
        }
    }

    Context '-SwitchDocker' {
        It 'switches to windows before and back to linux after, even when a task throws' {
            $global:BT.Agents.Enqueue('throw')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -SwitchDocker 6>$null 3>$null
            $global:BT.DockerCalls | Should -Be @('switch:windows', 'switch:linux')
        }

        It 'switches back to linux when the batch itself fails' {
            Mock Save-RunRecord { throw 'disk full' }
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -SwitchDocker 6>$null 3>$null } | Should -Throw '*disk full*'
            $global:BT.DockerCalls[-1] | Should -Be 'switch:linux'
        }

        It 'keeps the original batch error when switching back also fails' {
            Mock Switch-DockerMode { $global:BT.DockerCalls.Add("switch:$Mode"); if ($Mode -eq 'linux') { throw 'daemon did not restart' } }
            Mock Save-RunRecord { throw 'disk full' }
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -SwitchDocker 6>$null 3>$null } | Should -Throw '*disk full*'
            $global:BT.DockerCalls[-1] | Should -Be 'switch:linux'
        }

        It 'warns when switching back fails after a successful batch' {
            Mock Switch-DockerMode { $global:BT.DockerCalls.Add("switch:$Mode"); if ($Mode -eq 'linux') { throw 'daemon did not restart' } }
            $global:BT.Grades.Enqueue('right')
            $warnings = & $script:Bench -Profile strictp -Tasks T001 -RunId r2 -SwitchDocker 6>$null 3>&1
            @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -like '*daemon did not restart*' }).Count | Should -Be 1
            (Get-TaskEntry (Read-Run r2) T001).status | Should -Be 'done'
        }
    }

    Context 'gold preflight' {
        It 'grades every planned task before the first agent call' {
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null
            @($global:BT.Order)[0..2] | Should -Be @('gold:T001', 'gold:T002', 'claude')
            $global:BT.GoldCalls[0].CacheDir | Should -Be (Join-Path $script:Repo 'results\_gold')
            $global:BT.GoldCalls[0].BcArtifact | Should -Be 'Sandbox/w1/29.0.1.2'
            $global:BT.GoldCalls[0].GraderDir | Should -Be (Join-Path $script:Temp 'r1\_grader\_gold\T001')
            $global:BT.GoldCalls[0].CompilerVersion | Should -Be ([string](Read-Run r1).versions.compiler.version)
        }
        It 'skips every run of a gold-failed task and still runs the others' {
            $global:BT.GoldFails = @('T001')
            $global:BT.Grades.Enqueue('right')
            $warnings = & $script:Bench -Profile strictp -Tasks T001, T002 -Repeat 2 -RunId r1 6>$null 3>&1
            @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -like '*T001*' }).Count | Should -BeGreaterThan 0
            $run = Read-Run r1
            foreach ($rep in 1, 2) {
                $t = Get-TaskEntry $run T001 $rep
                $t.status | Should -Be 'skipped'
                $t.abortReason | Should -Be 'gold-failed'
                @($t.attempts).Count | Should -Be 0
            }
            (Get-TaskEntry $run T002 1).status | Should -Be 'done'
            @($global:BT.ClaudeCalls | Where-Object { $_.Ws -like '*\T001\*' }).Count | Should -Be 0
            $global:BT.ClaudeCalls.Count | Should -BeGreaterThan 0
        }
        It 'never calls Get-GoldResult with -SkipPreflight' {
            $global:BT.GoldFails = @('T001')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -SkipPreflight 6>$null
            Should -Invoke Get-GoldResult -Times 0 -Exactly
            (Get-TaskEntry (Read-Run r1) T001).status | Should -Be 'done'
        }
        It 'stops before any agent call when gold grading throws, and marks nothing skipped' {
            $global:BT.GoldThrows = $true
            { & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null } | Should -Throw '*gold grading failed*'
            $global:BT.ClaudeCalls.Count | Should -Be 0
            @((Read-Run r1).tasks | Where-Object { $_.status -eq 'skipped' }).Count | Should -Be 0
        }
        It 'retries a gold grading throw up to InfraRetries times before continuing' {
            $global:BT.Config.Grader = [pscustomobject]@{ InfraRetries = 2 }
            $global:BT.GoldThrowsLeft = 2
            $warnings = & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>&1
            @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -like '*gold preflight T001*retrying*' }).Count | Should -Be 2
            $global:BT.GoldCalls.Count | Should -Be 3
            $global:BT.ClaudeCalls.Count | Should -BeGreaterThan 0
        }
        It 'stops the run when gold grading still throws after InfraRetries retries' {
            $global:BT.Config.Grader = [pscustomobject]@{ InfraRetries = 1 }
            $global:BT.GoldThrows = $true
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null } | Should -Throw '*gold grading failed*'
            $global:BT.GoldCalls.Count | Should -Be 2
            $global:BT.ClaudeCalls.Count | Should -Be 0
        }
        It 'keys the gold cache on the current artifact and compiler on -Resume' {
            $exe = (Get-Process -Id $PID).Path
            Mock Get-AlcPath { $exe }.GetNewClosure()
            $global:BT.Agents.Enqueue('aborted')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null
            $path = Join-Path $script:Repo 'results\r1\run.json'
            $j = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
            $j.versions.bcArtifact = 'Old/xx/1.0'
            $j.versions.compiler.version = 'old-version'
            $j | ConvertTo-Json -Depth 20 | Set-Content $path
            Set-Mocks
            Mock Get-AlcPath { $exe }.GetNewClosure()
            $global:BT.Config.Bc.Version = '30.0.0.1'
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Resume r1 6>$null
            $global:BT.GoldCalls[0].BcArtifact | Should -Be 'Sandbox/w1/30.0.0.1'
            $global:BT.GoldCalls[0].CompilerVersion | Should -Be ((Get-Item $exe).VersionInfo.FileVersion)
        }
        It 'switches Docker back to linux when the preflight throws' {
            $global:BT.GoldThrows = $true
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -SwitchDocker 6>$null } | Should -Throw '*gold grading failed*'
            $global:BT.DockerCalls | Should -Be @('switch:windows', 'switch:linux')
        }
        It 'keeps skipped tasks skipped on -Resume' {
            $global:BT.GoldFails = @('T001')
            $global:BT.Agents.Enqueue('aborted')
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null 3>$null
            Set-Mocks
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Resume r1 6>$null
            $run = Read-Run r1
            (Get-TaskEntry $run T001).status | Should -Be 'skipped'
            (Get-TaskEntry $run T001).abortReason | Should -Be 'gold-failed'
            (Get-TaskEntry $run T002).status | Should -Be 'done'
            $global:BT.GoldCalls.TaskId | Should -Be @('T002')
        }
    }

    Context '-Resume' {
        It 'runs only pending work and resets an aborted task to attempt 1' {
            $global:BT.Agents.Enqueue('ok'); $global:BT.Agents.Enqueue('aborted')
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001, T002 -RunId r1 6>$null
            (Get-TaskEntry (Read-Run r1) T002).status | Should -Be 'aborted'

            Set-Mocks
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Resume r1 6>$null
            $global:BT.ClaudeCalls.Count | Should -Be 1
            $global:BT.ClaudeCalls[0].TranscriptPath | Should -BeLike '*\T002\1\attempt1.jsonl'
            $global:BT.ClaudeCalls[0].ResumeSessionId | Should -BeNullOrEmpty
            $run = Read-Run r1
            $t2 = Get-TaskEntry $run T002
            $t2.status | Should -Be 'done'
            $t2.abortReason | Should -BeNullOrEmpty
            @($t2.attempts).Count | Should -Be 1
            $t2.fullyRightAttempt | Should -Be 1
            (Get-TaskEntry $run T001).status | Should -Be 'done'
            @((Get-TaskEntry $run T001).attempts).Count | Should -Be 1
        }

        It 'reuses the run settings (profile, model, MCP mode)' {
            $global:BT.Agents.Enqueue('aborted')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -Model m-x -McpMode open 6>$null
            Set-Mocks
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Resume r1 6>$null
            $global:BT.ClaudeCalls[0].Model | Should -Be 'm-x'
            $global:BT.ClaudeCalls[0].McpMode | Should -Be 'open'
        }

        It 'refuses a pending task whose hash changed since the run started' {
            $global:BT.Agents.Enqueue('aborted')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            Set-Mocks
            $global:BT.HashSuffix = '-edited'
            { & $script:Bench -Resume r1 6>$null } | Should -Throw "task 'T001' changed since run r1 started"
            $global:BT.ClaudeCalls.Count | Should -Be 0
        }

        It 'adds versions.tasks to a run record that has none' {
            $global:BT.Agents.Enqueue('aborted')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $path = Join-Path $script:Repo 'results\r1\run.json'
            $j = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
            $j.versions.Remove('tasks')
            $j | ConvertTo-Json -Depth 20 | Set-Content $path
            Set-Mocks
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Resume r1 6>$null
            (Read-Run r1).versions.tasks.T001 | Should -Be 'hash-T001'
        }

        It 'refuses a different setting or a changed profile on resume' {
            $global:BT.Agents.Enqueue('aborted')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            { & $script:Bench -Resume r1 -Model other 6>$null } | Should -Throw '*Model*differs*'
            Add-Content (Join-Path $script:Repo 'profiles\strictp\profile.json') ' '
            { & $script:Bench -Resume r1 6>$null } | Should -Throw '*changed since run*'
            $global:BT.ClaudeCalls.Count | Should -Be 1
        }
    }

    Context 'task list' {
        It 'accepts -Tasks as one comma-separated string (pwsh -File)' {
            $global:BT.Grades.Enqueue('right'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks 'T001,T002' -RunId r1 6>$null
            @((Read-Run r1).tasks).taskId | Should -Be @('T001', 'T002')
        }

        It 'scans the transcripts of an aborted task for leaks' {
            $global:BT.Grades.Enqueue('wrong')
            $global:BT.Agents.Enqueue('ok'); $global:BT.Agents.Enqueue('aborted')
            $global:BT.LeakResult = 'leak'
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $global:BT.LeakCalls.Count | Should -Be 2
            (Get-TaskEntry (Read-Run r1) T001).status | Should -Be 'invalid'
        }
    }

    Context 'settings and record' {
        It 'CLI -McpMode open overrides profile strict' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -McpMode open 6>$null
            $global:BT.ClaudeCalls[0].McpMode | Should -Be 'open'
            $global:BT.SettingsCalls[0].McpMode | Should -Be 'open'
            (Read-Run r1).mcp.mode | Should -Be 'open'
        }

        It 'uses the profile MCP mode and config defaults without CLI flags' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $c = $global:BT.ClaudeCalls[0]
            $c.McpMode | Should -Be 'strict'
            $c.Model | Should -Be 'model-default'
            $c.MaxTurns | Should -Be 60
            $c.McpConfigPath | Should -Be (Join-Path $script:Temp 'r1\T001\1\claude-home\rfbench-mcp.json')
            $global:BT.SettingsCalls[0].AllowWeb | Should -BeFalse
        }

        It 'CLI -Model, -MaxTurns and -AllowWeb override the defaults' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 -Model m-x -MaxTurns 9 -AllowWeb 6>$null
            $global:BT.ClaudeCalls[0].Model | Should -Be 'm-x'
            $global:BT.ClaudeCalls[0].MaxTurns | Should -Be 9
            $global:BT.SettingsCalls[0].AllowWeb | Should -BeTrue
        }

        It 'records the task hashes in versions.tasks' {
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            (Read-Run r1).versions.tasks.T001 | Should -Be 'hash-T001'
        }

        It 'records versions, plugins and the MCP allowed list' {
            $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            $run = Read-Run r1
            $run.versions.cli | Should -Be '2.5.0'
            $run.versions.bcArtifact | Should -Be 'Sandbox/w1/29.0.1.2'
            $run.versions.compiler.path | Should -Be 'C:\fake\alc.exe'
            $run.versions.alParserDll | Should -Be 'C:\fake\Microsoft.Dynamics.Nav.CodeAnalysis.dll'
            $run.versions.pwsh | Should -Be $PSVersionTable.PSVersion.ToString()
            $run.mcp.allowed | Should -Be @('mslearn')
            # installedPlugins keeps the stable name@marketplace list; versions go to versions.plugins.
            $run.mcp.installedPlugins | Should -Be @('p1@mk')
            $run.versions.plugins.'p1@mk' | Should -Be '1.2.3'
            $run.versions.mcp.mslearn | Should -Be (Get-McpServerHash ([pscustomobject]@{ type = 'http'; url = 'https://x' }))
            $run.versions.mcp.mslearn | Should -Match '^[0-9a-f]{64}$'
            $run.versions.PSObject.Properties.Name | Should -Contain 'managedSettings'
            $run.versions.managedSettings | Should -BeNullOrEmpty
            $run.profile.name | Should -Be 'strictp'
            $run.profile.hash | Should -Match '^[0-9a-f]{64}$'
        }

        It 'records the managed settings hash when a managed settings file exists' {
            $global:BT.Grades.Enqueue('right')
            $global:BT.Managed = 'ab12'
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            (Read-Run r1).versions.managedSettings | Should -Be 'ab12'
        }

        It 'keeps a plugin version null until the plugin is installed' {
            $global:BT.InstallFails = $true
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null
            $run = Read-Run r1
            $run.versions.plugins.PSObject.Properties.Name | Should -Be @('p1@mk')
            $run.versions.plugins.'p1@mk' | Should -BeNullOrEmpty
            $run.mcp.installedPlugins | Should -Be @('p1@mk')
        }

        It 'deletes the run _grader folder even when the batch fails, unless -KeepWorkspace' {
            $global:BT.SaveCount = 0
            Mock Save-RunRecord {
                $global:BT.SaveCount++
                if ($global:BT.SaveCount -ge 3) { throw 'disk full' }
                New-Item -ItemType Directory (Split-Path $Path) -Force | Out-Null
                $Record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
            }
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null 3>$null } | Should -Throw '*disk full*'
            $global:BT.GradeCalls.Count | Should -BeGreaterThan 0
            Test-Path (Join-Path $script:Temp 'r1\_grader') | Should -BeFalse

            $global:BT.SaveCount = 0
            $global:BT.GradeCalls.Clear()
            { & $script:Bench -Profile strictp -Tasks T001 -RunId r2 -KeepWorkspace 6>$null 3>$null } | Should -Throw '*disk full*'
            Test-Path (Join-Path $script:Temp 'r2\_grader\T001\1') | Should -BeTrue
        }

        It 'removes the run temp folder unless -KeepWorkspace' {
            $global:BT.Grades.Enqueue('right'); $global:BT.Grades.Enqueue('right')
            & $script:Bench -Profile strictp -Tasks T001 -RunId r1 6>$null
            Test-Path (Join-Path $script:Temp 'r1') | Should -BeFalse
            & $script:Bench -Profile strictp -Tasks T001 -RunId r2 -KeepWorkspace 6>$null
            Test-Path (Join-Path $script:Temp 'r2\T001\1\ws') | Should -BeTrue
        }
    }
}
