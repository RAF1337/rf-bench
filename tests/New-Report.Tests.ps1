#Requires -Version 7.6
# Report tests. Fixtures (tests/fixtures/results) were produced with Results.psm1:
#   run-a: baseline, subscription, CLI 2.1.300. T001 right at 1; T002 tests at 2, never fully right;
#          T003 invalid (right at 1, leak hit with markup in the excerpt); T004 aborted (timeout).
#   run-b: example-rules, apiKey, CLI 2.1.314, MCP mslearn allowed, 'claude.ai Gmail' found by Claude.
#          T001 right at 2 (tests at 1); T002 right at 3 (tests at 2); T003 right at 1.
BeforeAll {
    $script:Report = Join-Path $PSScriptRoot '..\src\New-Report.ps1'
    $script:Fx = Join-Path $PSScriptRoot 'fixtures\results'
    $script:A = Join-Path $script:Fx 'run-a.json'
    $script:B = Join-Path $script:Fx 'run-b.json'

    function Invoke-Report([string[]]$Runs, [string]$ResultsRoot) {
        $out = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).html"
        $params = @{ Runs = $Runs; Out = $out }
        if ($ResultsRoot) { $params.ResultsRoot = $ResultsRoot }
        $null = & $script:Report @params
        Get-Content -LiteralPath $out -Raw
    }

    # Text of the table cell for one run column and one metric.
    function Get-Cell([string]$Html, [int]$Run, [string]$Metric) {
        $m = [regex]::Match($Html, "<td[^>]*data-run=""$Run""[^>]*data-metric=""$Metric""[^>]*>(.*?)</td>", 'Singleline')
        if (-not $m.Success) { throw "no cell run=$Run metric=$Metric" }
        ($m.Groups[1].Value -replace '<[^>]+>', '').Trim()
    }

    function Copy-Fixture([string]$Path, [scriptblock]$Change) {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50
        & $Change $j
        $p = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
        $j | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $p
        $p
    }
}

Describe 'New-Report' {
    BeforeAll { $script:Html = Invoke-Report @($script:A, $script:B) }

    It 'writes a self-contained page with light and dark styles and no scripts' {
        $script:Html | Should -Match '^<!doctype html>'
        $script:Html | Should -Match 'prefers-color-scheme: dark'
        $script:Html | Should -Not -Match '<script'
        $script:Html | Should -Not -Match '<link'
    }

    It 'shows fully-right percentages per run, excluding invalid and aborted task runs' {
        # run-a: 1 of 2 done task runs right at attempt 1 (would be 2 of 3 if the invalid run counted).
        Get-Cell $script:Html 0 'fr1' | Should -Be '50%'
        Get-Cell $script:Html 0 'fr2' | Should -Be '50%'
        Get-Cell $script:Html 0 'fr3' | Should -Be '50%'
        Get-Cell $script:Html 1 'fr1' | Should -Be '33.3%'
        Get-Cell $script:Html 1 'fr2' | Should -Be '66.7%'
        Get-Cell $script:Html 1 'fr3' | Should -Be '100%'
    }

    It 'shows tests-passed percentages per run' {
        Get-Cell $script:Html 0 'tp1' | Should -Be '50%'
        Get-Cell $script:Html 0 'tp2' | Should -Be '100%'
        Get-Cell $script:Html 1 'tp1' | Should -Be '66.7%'
        Get-Cell $script:Html 1 'tp3' | Should -Be '100%'
    }

    It 'counts unsolved task runs as 4 attempts and marks it' {
        Get-Cell $script:Html 0 'avgAttempts' | Should -Match '^2\.5\b.*1 unsolved'
        Get-Cell $script:Html 1 'avgAttempts' | Should -Be '2'
    }

    It 'shows counted, invalid and aborted task runs' {
        Get-Cell $script:Html 0 'counted' | Should -Be '2'
        Get-Cell $script:Html 0 'invalid' | Should -Be '1'
        Get-Cell $script:Html 0 'aborted' | Should -Match '^1 \(timeout 1\)$'
        Get-Cell $script:Html 1 'invalid' | Should -Be '0'
    }

    It 'labels cost as estimated only for subscription runs' {
        Get-Cell $script:Html 0 'costTotal' | Should -Match '2\.25.*estimated'
        Get-Cell $script:Html 1 'costTotal' | Should -Not -Match 'estimated'
        Get-Cell $script:Html 1 'costTotal' | Should -Match '2\.10'
    }

    It 'shows run metadata verbatim, independent of the current culture' {
        Get-Cell $script:Html 0 'started' | Should -Be '2026-11-04T10:00:00.0000000Z'
        Get-Cell $script:Html 1 'authMode' | Should -Be 'apiKey'
    }

    It 'shows token, time and turn totals' {
        Get-Cell $script:Html 1 'turns' | Should -Be '60'
        Get-Cell $script:Html 1 'outputTokens' | Should -Be '1,200'
    }

    It 'shows a version mismatch banner when CLI versions differ' {
        $script:Html | Should -Match 'id="version-mismatch"'
        $script:Html | Should -Match 'Claude CLI'
        $script:Html | Should -Match '2\.1\.300'
        $script:Html | Should -Match '2\.1\.314'
    }

    It 'has no version banner when versions match' {
        $same = Copy-Fixture $script:B { param($j) $j.versions.cli = '2.1.300' }
        Invoke-Report @($script:A, $same) | Should -Not -Match 'id="version-mismatch"'
    }

    It 'flags a plugin present in both runs with different versions (versions.plugins)' {
        $b2 = Copy-Fixture $script:B { param($j) $j.versions.plugins.'rf-al@rf-market' = '1.3.0' }
        $h = Invoke-Report @($script:B, $b2)
        $h | Should -Match 'id="version-mismatch"'
        $h | Should -Match 'Plugin rf-al@rf-market'
        $h | Should -Match '1\.3\.0'
    }

    It 'does not compare plugin names from installedPlugins as versions' {
        $b2 = Copy-Fixture $script:B { param($j) $j.mcp.installedPlugins = @('rf-al@other-market') }
        Invoke-Report @($script:B, $b2) | Should -Not -Match 'id="version-mismatch"'
    }

    It 'flags differing MCP server hashes' {
        $b2 = Copy-Fixture $script:B { param($j) $j.versions.mcp.mslearn = 'ffff' }
        Invoke-Report @($script:B, $b2) | Should -Match 'MCP mslearn'
    }

    It 'shows plugins of an older run without versions.plugins by name' {
        $old = Copy-Fixture $script:B { param($j) $j.versions.PSObject.Properties.Remove('plugins') }
        Get-Cell (Invoke-Report @($old)) 0 'plugins' | Should -Be 'rf-al@rf-market'
    }

    It 'flags differing compiler and BC artifact versions' {
        $b2 = Copy-Fixture $script:B { param($j) $j.versions.compiler.version = '19.0.1'; $j.versions.bcArtifact = 'Sandbox/w1/30.0' }
        $h = Invoke-Report @($script:B, $b2)
        $h | Should -Match 'AL compiler'
        $h | Should -Match 'BC artifact'
    }

    It 'shows the MCP table with servers found by Claude and MCP tool calls' {
        $script:Html | Should -Match 'Found by Claude'
        Get-Cell $script:Html 1 'mcpFound' | Should -Be 'claude.ai Gmail'
        Get-Cell $script:Html 1 'mcpAllowed' | Should -Be 'mslearn'
        Get-Cell $script:Html 0 'mcpFound' | Should -Be 'none'
        Get-Cell $script:Html 1 'mcpTool:mcp__mslearn__microsoft_docs_search' | Should -Be '3'
        Get-Cell $script:Html 1 'plugins' | Should -Be 'rf-al@rf-market 1.2.0'
    }

    It 'shows analyzer warnings per rule and failed checks per category from the final attempt' {
        # run-a final attempts: T001 AA0137=2; T002 AA0137=1, AA0021=3.
        Get-Cell $script:Html 0 'warn:AA0137' | Should -Be '3'
        Get-Cell $script:Html 0 'warn:AA0021' | Should -Be '3'
        Get-Cell $script:Html 0 'checks:data-access' | Should -Be '1'
        Get-Cell $script:Html 0 'checks:transactions' | Should -Be '1'
        Get-Cell $script:Html 1 'checks:transactions' | Should -Be '0'
        Get-Cell $script:Html 0 'checks:ui' | Should -Be '0'
    }

    It 'shows a per-task table with attempt outcomes' {
        $script:Html | Should -Match 'id="per-task"'
        Get-Cell $script:Html 0 'task:T002/1' | Should -Match 'compile failed.*checks failed.*checks failed'
        Get-Cell $script:Html 1 'task:T001/1' | Should -Match 'fully right'
        Get-Cell $script:Html 0 'task:T004/1' | Should -Match 'aborted.*timeout'
        Get-Cell $script:Html 1 'task:T004/1' | Should -Be 'not run'
    }

    It 'renders a run whose task runs were skipped by the gold preflight' {
        $skipped = Copy-Fixture $script:A { param($j) $j.tasks[0].status = 'skipped'; $j.tasks[0].abortReason = 'gold-failed' }
        $html = Invoke-Report @($skipped)
        Get-Cell $html 0 'task:T001/1' | Should -Match 'skipped'
    }

    It 'HTML-escapes values taken from run.json' {
        $script:Html | Should -Not -Match '<script>alert'
        $script:Html | Should -Match '&lt;script&gt;alert'
    }

    It 'resolves run ids under the results root and accepts a comma-joined list' {
        $root = Join-Path $TestDrive 'results'
        foreach ($p in $script:A, $script:B) {
            $id = (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).runId
            New-Item -ItemType Directory (Join-Path $root $id) -Force | Out-Null
            Copy-Item -LiteralPath $p (Join-Path $root "$id\run.json")
        }
        $h = Invoke-Report @('20261104-100000-baseline,20261104-110000-example-rules') -ResultsRoot $root
        Get-Cell $h 1 'fr3' | Should -Be '100%'
    }

    It 'throws for an unknown run' {
        { Invoke-Report @('nope') -ResultsRoot (Join-Path $TestDrive 'empty') } | Should -Throw '*nope*'
    }

    It 'shows n/a when a run has no counted task runs' {
        $p = Copy-Fixture $script:A { param($j) foreach ($t in $j.tasks) { $t.status = 'aborted'; $t.abortReason = 'rate-limit' } }
        $h = Invoke-Report @($p)
        Get-Cell $h 0 'fr1' | Should -Be 'n/a'
        Get-Cell $h 0 'aborted' | Should -Be '4 (rate-limit 4)'
    }
}

Describe 'New-Report comparison and consistency' {
    BeforeAll {
        $script:Hashes = { param($j) $j.versions | Add-Member -NotePropertyName tasks -NotePropertyValue ([pscustomobject]@{ T001 = 'h1'; T002 = 'h2'; T003 = 'h3'; T004 = 'h4' }) -Force }
        $script:AH = Copy-Fixture $script:A $script:Hashes
        $script:BH = Copy-Fixture $script:B $script:Hashes

        function Invoke-ReportFull([string[]]$Runs, [string]$TasksRoot) {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $out = Join-Path $dir 'report.html'
            $params = @{ Runs = $Runs; Out = $out }
            if ($TasksRoot) { $params.TasksRoot = $TasksRoot }
            $null = & $script:Report @params
            [pscustomobject]@{ Html = (Get-Content -LiteralPath $out -Raw); Dir = $dir }
        }
        function Get-Section([string]$Html, [string]$Id) {
            $m = [regex]::Match($Html, "<table id=""$Id"".*?</table>", 'Singleline')
            if ($m.Success) { ($m.Value -replace '<[^>]+>', ' ' -replace '\s+', ' ') } else { $null }
        }
    }

    It 'shows one comparison row per candidate with verdict, CI and McNemar counts, and writes compare.json' {
        $r = Invoke-ReportFull @($script:AH, $script:BH)
        $sec = Get-Section $r.Html 'comparison'
        $sec | Should -Not -BeNullOrEmpty
        $sec | Should -Match 'too few tasks'
        $sec | Should -Match '\[.*,.*\]'
        $json = Get-Content -LiteralPath (Join-Path $r.Dir 'compare.json') -Raw | ConvertFrom-Json
        @($json.runs).Count | Should -Be 2
        @($json.comparisons).Count | Should -Be 1
        $c = $json.comparisons[0]
        $c.pairedTasks | Should -Be 2
        $c.verdict | Should -Be 'too few tasks'
        $c.baseline | Should -Be (Get-Content $script:A -Raw | ConvertFrom-Json).runId
        $c.pHolm | Should -BeGreaterOrEqual $c.p
        $json.runs[1].auc3 | Should -BeGreaterThan 0
        # run-b: T001 right at 2 (2/3), T002 right at 3 (1/3), T003 right at 1 (1) -> mean 2/3
        $json.runs[1].auc3 | Should -BeLessThan 0.67
        $json.runs[1].auc3 | Should -BeGreaterThan 0.66
        $sec | Should -Match 'T003 \(missing\)'
    }

    It 'has no comparison section for a single run but still writes compare.json' {
        $r = Invoke-ReportFull @($script:AH)
        $r.Html | Should -Not -Match 'id="comparison"'
        $r.Html | Should -Match 'id="consistency"'
        $json = Get-Content -LiteralPath (Join-Path $r.Dir 'compare.json') -Raw | ConvertFrom-Json
        @($json.comparisons).Count | Should -Be 0
    }

    It 'counts final-attempt failure causes per run' {
        $r = Invoke-ReportFull @($script:A)
        $sec = Get-Section $r.Html 'failure-causes'
        $sec | Should -Match 'checks failed 1'
        $json = Get-Content -LiteralPath (Join-Path $r.Dir 'compare.json') -Raw | ConvertFrom-Json
        # run-a done runs: T001 fully right, T002 final attempt checks failed.
        $json.runs[0].failureCauses.'fully right' | Should -Be 1
        $json.runs[0].failureCauses.'checks failed' | Should -Be 1
    }

    It 'groups by family from the task folder and under (none) otherwise' {
        $tr = Join-Path $TestDrive 'tasks'
        New-Item -ItemType Directory (Join-Path $tr 'T001') -Force | Out-Null
        '{ "id": "T001", "family": "locking" }' | Set-Content (Join-Path $tr 'T001\task.json')
        $r = Invoke-ReportFull @($script:AH) $tr
        $sec = Get-Section $r.Html 'families'
        $sec | Should -Match 'locking'
        $sec | Should -Match '\(none\)'
        $r.Html | Should -Not -Match 'id="holdout"'
    }

    It 'shows the holdout section only when a holdout task exists' {
        $tr = Join-Path $TestDrive 'tasks2'
        New-Item -ItemType Directory (Join-Path $tr 'T002') -Force | Out-Null
        '{ "id": "T002", "split": "holdout" }' | Set-Content (Join-Path $tr 'T002\task.json')
        $r = Invoke-ReportFull @($script:AH) $tr
        Get-Section $r.Html 'holdout' | Should -Not -BeNullOrEmpty
    }

    It 'shows the skipped count in the Runs table' {
        $sk = Copy-Fixture $script:A { param($j) $j.tasks[0].status = 'skipped'; $j.tasks[0].abortReason = 'gold-failed' }
        Get-Cell (Invoke-Report @($sk)) 0 'skipped' | Should -Match '^1'
    }

    It 'renders an old-format run without versions.tasks and says task hashes are unknown' {
        $h = Invoke-Report @($script:A, $script:B)
        $h | Should -Match 'task hashes unknown'
    }

    It 'lists tasks whose hashes differ between runs in the banner' {
        $b2 = Copy-Fixture $script:BH { param($j) $j.versions.tasks.T002 = 'changed' }
        $h = Invoke-Report @($script:AH, $b2)
        $h | Should -Match 'id="version-mismatch"'
        $h | Should -Match 'Task T002'
    }
}
