#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Feedback.psm1') -Force

    function New-Grade {
        param(
            [bool]$Compiled = $true,
            [string[]]$CompileErrors = @(),
            [object[]]$Tests = @(),
            [object[]]$Findings = @()
        )
        [pscustomobject]@{
            Compiled         = $Compiled
            CompileErrors    = $CompileErrors
            AnalyzerWarnings = [ordered]@{ AA0021 = 3 }
            Tests            = $Tests
            TestsPassed      = -not @($Tests | Where-Object { -not $_.Passed -and -not $_.IsBudget })
            BudgetsPassed    = -not @($Tests | Where-Object { -not $_.Passed -and $_.IsBudget })
            Findings         = $Findings
            ChecksPassed     = -not @($Findings | Where-Object { -not $_.Passed })
            FullyRight       = $false
        }
    }
    function New-Test([string]$Name, [bool]$Passed, [string]$Message, [string]$CallStack) {
        [pscustomobject]@{ Codeunit = 'TX01 Tests'; Name = $Name; Passed = $Passed; Message = $Message; CallStack = $CallStack; IsBudget = $Name -like 'Budget_*' }
    }
    function New-TestFinding([string]$Check, [string]$Category, [bool]$Passed = $false, [string]$File = 'Foo.al', [int]$Line = 12) {
        [pscustomobject]@{ Check = $Check; Category = $Category; File = $File; Line = $Line; Passed = $Passed; Detail = "detail of $Check" }
    }
}

Describe 'New-AttemptFeedback' {
    It 'never leaks check names, files or lines' {
        $g = New-Grade -Findings @(New-TestFinding 'RequiresSetLoadFieldsBeforeRead' 'data-access')
        $text = New-AttemptFeedback $g
        $text | Should -Match 'data-access'
        $text | Should -Not -Match 'RequiresSetLoadFieldsBeforeRead'
        $text | Should -Not -Match 'Foo\.al'
        $text | Should -Not -Match '12'
        $text | Should -Not -Match 'detail of'
    }

    It 'lists failed categories sorted and distinct, ignoring passed findings' {
        $g = New-Grade -Findings @(
            New-TestFinding 'NoCommitIn' 'transactions'
            New-TestFinding 'NoFindMinus' 'data-access'
            New-TestFinding 'RequiresSetLoadFieldsBeforeRead' 'data-access'
            New-TestFinding 'ReadIsolationOnCount' 'locking-isolation' -Passed $true
        )
        $text = New-AttemptFeedback $g
        $text | Should -Match ([regex]::Escape('Coding standards issues found in: data-access, transactions.'))
        $text | Should -Not -Match 'locking-isolation'
    }

    It 'budget feedback has no numbers' {
        $g = New-Grade -Tests @(
            New-Test 'TestPost' $true
            New-Test 'Budget_PostLargeOrder' $false 'SQL statements: 14 > budget 10' 'TX01 Tests(CodeUnit 50150).Budget_PostLargeOrder line 7'
        )
        $text = New-AttemptFeedback $g
        $text | Should -Match 'Performance:'
        $text | Should -Match 'PostLargeOrder used more SQL statements/rows than allowed'
        $text | Should -Not -Match 'Budget_'
        $text | Should -Not -Match 'Failing tests:'
        ($text -replace 'PostLargeOrder', '') | Should -Not -Match '\d'
    }

    It 'reports compile errors verbatim and nothing else' {
        $err = 'C:\ws\app\src\Foo.al(3,5): error AL0104: Syntax error, ''end'' expected'
        $text = New-AttemptFeedback (New-Grade -Compiled $false -CompileErrors @($err))
        $lines = $text -split "`r?`n"
        $lines[0] | Should -Be 'Compilation failed:'
        $lines | Should -Contain $err
        $text | Should -Not -Match 'AA0021'
        $text | Should -Not -Match 'Failing tests:|Performance:|Coding standards'
        $lines[-1] | Should -Be 'Fix the issues and finish again.'
    }

    It 'reports failing functional tests verbatim with call stacks' {
        $g = New-Grade -Tests @(
            New-Test 'TestPost' $false 'Assert.AreEqual failed. Expected:<5> Actual:<4>.' 'TX01 Tests(CodeUnit 50150).TestPost line 9'
            New-Test 'TestOther' $true
        )
        $text = New-AttemptFeedback $g
        $text | Should -Match ([regex]::Escape('Failing tests:'))
        $text | Should -Match ([regex]::Escape('TX01 Tests::TestPost: Assert.AreEqual failed. Expected:<5> Actual:<4>.'))
        $text | Should -Match ([regex]::Escape('TX01 Tests(CodeUnit 50150).TestPost line 9'))
        $text | Should -Not -Match 'TestOther'
    }

    It 'orders the sections compile, tests, performance, standards, closing line' {
        $g = New-Grade -Tests @(
            New-Test 'TestPost' $false 'boom' 'stack'
            New-Test 'Budget_Post' $false 'over' 'stack'
        ) -Findings @(New-TestFinding 'NoCommitIn' 'transactions')
        $g.CompileErrors = @('error AL0001: x')
        $text = New-AttemptFeedback $g
        $i = @('Compilation failed:', 'Failing tests:', 'Performance:', 'Coding standards issues found in:', 'Fix the issues and finish again.') |
            ForEach-Object { $text.IndexOf($_) }
        $i | Should -Not -Contain -1
        ($i | Sort-Object) | Should -Be $i
    }

    It 'lists an app publish failure under failing tests' {
        $g = New-Grade -Tests @(New-Test 'App' $false 'Publishing your app failed: install error' $null)
        $g.Tests[0].Codeunit = 'Publish'
        $text = New-AttemptFeedback $g
        $text | Should -Match ([regex]::Escape("Failing tests:`nPublish::App: Publishing your app failed: install error"))
    }

    It 'ignores empty and unknown categories with a verbose note' {
        $g = New-Grade -Findings @(
            New-TestFinding 'NoCommitIn' 'transactions'
            New-TestFinding 'NoFindMinus' ''
            New-TestFinding 'Secret' 'RequiresSetLoadFieldsBeforeRead'
        )
        $all = @(New-AttemptFeedback $g -Verbose 4>&1)
        $text = @($all | Where-Object { $_ -is [string] }) -join "`n"
        $verbose = @($all | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $text | Should -Match ([regex]::Escape('Coding standards issues found in: transactions.'))
        $text | Should -Not -Match 'RequiresSetLoadFieldsBeforeRead'
        $verbose.Count | Should -BeGreaterThan 0
        ($verbose.Message -join ' ') | Should -Match 'RequiresSetLoadFieldsBeforeRead'
    }

    It 'omits the standards section when only unknown categories failed' {
        $text = New-AttemptFeedback (New-Grade -Findings @(New-TestFinding 'X' 'bogus'))
        $text | Should -Not -Match 'Coding standards'
    }

    It 'ends with the closing line' {
        $text = New-AttemptFeedback (New-Grade -Findings @(New-TestFinding 'NoCommitIn' 'transactions'))
        ($text -split "`r?`n")[-1] | Should -Be 'Fix the issues and finish again.'
    }
}
