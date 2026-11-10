#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Stats.psm1') -Force

    # fr = fullyRightAttempt (int or $null); cost = per-attempt CostUsd values.
    function New-TaskRun([string]$Id, [int]$Repeat, $Fr, [string]$Status = 'done', [double[]]$Cost = @()) {
        $n = 0
        [pscustomobject]@{
            taskId = $Id; repeat = $Repeat; status = $Status; abortReason = $null
            firstTestsPassAttempt = $null; fullyRightAttempt = $Fr
            attempts = @($Cost | ForEach-Object { $n++; [pscustomobject]@{ n = $n; agent = [pscustomobject]@{ CostUsd = $_ } } })
        }
    }
    function New-Run($Tasks, $Hashes) {
        $v = [pscustomobject]@{}
        if ($null -ne $Hashes) {
            $t = [pscustomobject]@{}
            foreach ($k in $Hashes.Keys) { $t | Add-Member -NotePropertyName $k -NotePropertyValue $Hashes[$k] }
            $v | Add-Member -NotePropertyName tasks -NotePropertyValue $t
        }
        [pscustomobject]@{ runId = 'r'; profile = [pscustomobject]@{ name = 'p'; hash = 'h' }; model = 'm'; versions = $v; tasks = @($Tasks) }
    }
    function New-ManyRuns([int]$Count, $BaseFr, $CandFr, [switch]$NoHashes) {
        $ids = 1..$Count | ForEach-Object { 'T{0:D3}' -f $_ }
        $h = $null
        if (-not $NoHashes) { $h = @{}; foreach ($i in $ids) { $h[$i] = "hash-$i" } }
        $b = New-Run @($ids | ForEach-Object { New-TaskRun $_ 1 $BaseFr }) $h
        $c = New-Run @($ids | ForEach-Object { New-TaskRun $_ 1 $CandFr }) $h
        $b, $c
    }
}

Describe 'Get-AttemptScore' {
    It 'scores <fr> as <want>' -ForEach @(
        @{ fr = 1; want = 1.0 }, @{ fr = 2; want = 0.6667 }, @{ fr = 3; want = 0.3333 }, @{ fr = $null; want = 0.0 }
    ) {
        $s = Get-AttemptScore -FullyRightAttempt $fr
        $s | Should -BeOfType [double]
        $s | Should -BeGreaterThan ($want - 1e-4)
        $s | Should -BeLessThan ($want + 1e-4)
    }
}

Describe 'Get-McNemarExactP' {
    It 'matches known exact values for B=<b> C=<c>' -ForEach @(
        @{ b = 0; c = 6; want = 0.03125 }, @{ b = 1; c = 5; want = 0.21875 }, @{ b = 0; c = 0; want = 1.0 }
        @{ b = 6; c = 0; want = 0.03125 }, @{ b = 5; c = 1; want = 0.21875 }, @{ b = 3; c = 3; want = 1.0 }
    ) {
        Get-McNemarExactP -B $b -C $c | Should -BeExactly $want
    }
}

Describe 'Get-HolmAdjusted' {
    It 'adjusts in input order' {
        $r = Get-HolmAdjusted -P @(0.01, 0.04, 0.03)
        $r.Count | Should -Be 3
        $r[0] | Should -BeExactly 0.03
        $r[1] | Should -BeExactly 0.06
        $r[2] | Should -BeExactly 0.06
    }
    It 'caps at 1' {
        (Get-HolmAdjusted -P @(0.6, 0.9))[0] | Should -Be 1
    }
}

Describe 'Get-BootstrapCi' {
    It 'is degenerate for constant diffs' {
        $ci = Get-BootstrapCi -Diffs @(0.5, 0.5, 0.5, 0.5) -Seed 7
        $ci.Low | Should -Be 0.5
        $ci.High | Should -Be 0.5
    }
    It 'is reproducible for one seed' {
        $d = 1..20 | ForEach-Object { $_ - 10 }
        $a = Get-BootstrapCi -Diffs $d -Seed 42 -Resamples 500
        $b = Get-BootstrapCi -Diffs $d -Seed 42 -Resamples 500
        $a.Low | Should -Be $b.Low
        $a.High | Should -Be $b.High
    }
    It 'brackets zero for symmetric diffs' {
        $ci = Get-BootstrapCi -Diffs @(1..20 | ForEach-Object { $_ - 10 }) -Seed 3 -Resamples 1000
        $ci.Low | Should -BeLessThan 0
        $ci.High | Should -BeGreaterThan 0
    }
}

Describe 'Get-RunScores' {
    BeforeAll {
        $tasks = @(
            (New-TaskRun 'T001' 1 1 'done' @(0.10)), (New-TaskRun 'T001' 2 2 'done' @(0.10, 0.20)),
            (New-TaskRun 'T002' 1 $null 'done' @(0.30)), (New-TaskRun 'T002' 2 $null 'aborted' @(0.30))
        )
        $script:S = Get-RunScores -Run (New-Run $tasks @{ T001 = 'a'; T002 = 'b' })
    }
    It 'averages the attempt score over done task runs' {
        $script:S.Auc3 | Should -BeGreaterThan ((1 + 2 / 3 + 0) / 3 - 1e-9)
        $script:S.Auc3 | Should -BeLessThan ((1 + 2 / 3 + 0) / 3 + 1e-9)
    }
    It 'computes pass^k over tasks with at least two counted repeats' {
        $script:S.PassHatK | Should -Be 1.0
        $script:S.PassHatKTasks | Should -Be 1
    }
    It 'divides all cost, including aborted runs, by solved task runs' {
        $script:S.CostPerSolved | Should -BeGreaterThan (1.0 / 2 - 1e-9)
        $script:S.CostPerSolved | Should -BeLessThan (1.0 / 2 + 1e-9)
    }
    It 'keeps per-task hash, scores and first-try flags' {
        $t = $script:S.PerTask['T001']
        $t.Hash | Should -Be 'a'
        $t.Scores.Count | Should -Be 2
        $t.FirstTry[1] | Should -BeTrue
        $t.FirstTry[2] | Should -BeFalse
        $script:S.PerTask['T002'].Scores.Count | Should -Be 1
    }
    It 'returns nulls when nothing is done and no task is solved' {
        $s = Get-RunScores -Run (New-Run @((New-TaskRun 'T001' 1 $null 'aborted' @(0.5))) $null)
        $s.Auc3 | Should -BeNullOrEmpty
        $s.PassHatK | Should -BeNullOrEmpty
        $s.CostPerSolved | Should -BeNullOrEmpty
        $s.PassHatKTasks | Should -Be 0
    }
    It 'returns a null cost when no cost was recorded' {
        $s = Get-RunScores -Run (New-Run @((New-TaskRun 'T001' 1 1)) $null)
        $s.CostPerSolved | Should -BeNullOrEmpty
    }
    It 'reports pass^k below 1 when a repeat fails' {
        $r = New-Run @((New-TaskRun 'T001' 1 1), (New-TaskRun 'T001' 2 $null), (New-TaskRun 'T002' 1 1), (New-TaskRun 'T002' 2 1)) $null
        (Get-RunScores -Run $r).PassHatK | Should -Be 0.5
    }
}

Describe 'Get-PairedComparison' {
    It 'finds no difference between identical runs' {
        $b, $c = New-ManyRuns 12 1 1
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.PairedTasks | Should -Be 12
        $r.MeanDiff | Should -Be 0
        $r.Verdict | Should -Be 'no clear difference'
        $r.HashesUnknown | Should -BeFalse
        $r.McNemarP | Should -Be 1
    }
    It 'calls a candidate that is better on every task better' {
        $b, $c = New-ManyRuns 12 $null 1
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.Verdict | Should -Be 'better'
        $r.CiLow | Should -BeGreaterThan 0
        $r.McNemarB | Should -Be 0
        $r.McNemarC | Should -Be 12
    }
    It 'calls a candidate that is worse on every task worse' {
        $b, $c = New-ManyRuns 12 1 $null
        (Get-PairedComparison -Baseline $b -Candidate $c).Verdict | Should -Be 'worse'
    }
    It 'refuses a verdict below 10 paired tasks' {
        $b, $c = New-ManyRuns 5 $null 1
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.PairedTasks | Should -Be 5
        $r.Verdict | Should -Be 'too few tasks'
    }
    It 'excludes a task whose hash differs' {
        $b, $c = New-ManyRuns 12 1 1
        $c.versions.tasks.T003 = 'changed'
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.PairedTasks | Should -Be 11
        $r.ExcludedTasks | Should -Contain 'T003 (hash differs)'
    }
    It 'excludes a task missing from one run' {
        $b, $c = New-ManyRuns 12 1 1
        $c.tasks = @($c.tasks | Where-Object taskId -NE 'T004')
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.PairedTasks | Should -Be 11
        $r.ExcludedTasks | Should -Contain 'T004 (missing)'
    }
    It 'pairs all common tasks and flags unknown hashes for old records' {
        $b, $c = New-ManyRuns 12 1 1 -NoHashes
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.PairedTasks | Should -Be 12
        $r.HashesUnknown | Should -BeTrue
        @($r.ExcludedTasks).Count | Should -Be 0
    }
    It 'counts McNemar discordant first-try pairs by direction' {
        $ids = 1..12 | ForEach-Object { 'T{0:D3}' -f $_ }
        $b = New-Run @($ids | ForEach-Object { New-TaskRun $_ 1 $(if ($_ -le 'T002') { 1 } else { 2 }) }) $null
        $c = New-Run @($ids | ForEach-Object { New-TaskRun $_ 1 $(if ($_ -ge 'T003' -and $_ -le 'T005') { 1 } else { 2 }) }) $null
        $r = Get-PairedComparison -Baseline $b -Candidate $c
        $r.McNemarB | Should -Be 2
        $r.McNemarC | Should -Be 3
    }
    It 'is reproducible' {
        $b, $c = New-ManyRuns 12 2 1
        $x = Get-PairedComparison -Baseline $b -Candidate $c
        $y = Get-PairedComparison -Baseline $b -Candidate $c
        $x.CiLow | Should -Be $y.CiLow
        $x.CiHigh | Should -Be $y.CiHigh
    }
}
