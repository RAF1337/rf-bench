#Requires -Version 7.6
# Task validator tests. Invoke-Grade, the Docker checks and the compiler/parser preflight are
# mocked; Get-BenchTask runs for real against a copy of fixture TX01 in TestDrive.
BeforeAll {
    $src = Join-Path $PSScriptRoot '..\src'
    foreach ($m in 'Config', 'Task', 'Backend.Docker', 'Grader') {
        Import-Module (Join-Path $src "$m.psm1") -Force
    }
    Import-Module (Join-Path $src 'Checks\AlParser.psm1') -Force
    $script:Validator = Join-Path $src 'Test-Task.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\tasks\TX01'
    # Mock bodies run while Test-Task.ps1 is the current script; shared state lives in a global.
    $global:TT = @{}

    # A grade result. 'right' = fully right; 'wrong' = a failing functional test;
    # 'bad' = tests pass, the checks named in $Fail fail.
    function New-Grade([string]$Kind, [string[]]$Fail = @(), [bool]$TestsPassed = $true, [bool]$BudgetsPassed = $true, [bool]$Compiled = $true) {
        $findings = @(foreach ($c in $Fail) { [pscustomobject]@{ Check = $c; Category = 'data-access'; File = 'a.al'; Line = 1; Passed = $false; Detail = "$c failed" } })
        $findings += [pscustomobject]@{ Check = 'NoCommitIn'; Category = 'transactions'; File = 'a.al'; Line = 2; Passed = $true; Detail = 'ok' }
        switch ($Kind) {
            'right' { $TestsPassed = $true; $BudgetsPassed = $true; $findings = @($findings | Where-Object Passed) }
            'wrong' { $TestsPassed = $false }
        }
        $tests = @([pscustomobject]@{ Codeunit = 'C'; Name = 'Func'; Passed = $TestsPassed; Message = $(if (-not $TestsPassed) { 'Assert.AreEqual failed' }); CallStack = $null; IsBudget = $false }
            [pscustomobject]@{ Codeunit = 'C'; Name = 'Budget_X'; Passed = $BudgetsPassed; Message = $(if (-not $BudgetsPassed) { 'too many rows' }); CallStack = $null; IsBudget = $true })
        $checksPassed = -not @($findings | Where-Object { -not $_.Passed })
        [pscustomobject]@{
            Compiled = $Compiled; CompileErrors = @(if (-not $Compiled) { 'app.al(1,1): error AL0001: boom' }); AnalyzerWarnings = @{}
            Tests = $(if ($Compiled) { $tests } else { @() }); TestsPassed = $Compiled -and $TestsPassed; BudgetsPassed = $Compiled -and $BudgetsPassed
            Findings = $(if ($Compiled) { $findings } else { @() }); ChecksPassed = $Compiled -and $checksPassed
            FullyRight = $Compiled -and $TestsPassed -and $BudgetsPassed -and $checksPassed
        }
    }

    function Set-LintTest([string]$TaskDir, [string]$Body) {
        $al = "codeunit 70199 `"L`"`n{`n    Subtype = Test;`n`n    [Test]`n    procedure P()`n    begin`n$Body`n    end;`n}"
        $dir = Join-Path $TaskDir 'solution\tests\src'
        New-Item -ItemType Directory $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Lint.Codeunit.al') -Value $al
    }
    function Invoke-Validator([hashtable]$Extra = @{}) {
        $out = & $script:Validator -Task TX01 -TasksRoot $script:Tasks @Extra 6>&1 2>&1 3>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out }
    }
}

AfterAll { Remove-Variable -Name TT -Scope Global -ErrorAction Ignore }

Describe 'Test-Task' {
    BeforeEach {
        $script:Tasks = Join-Path $TestDrive "tasks-$([guid]::NewGuid().ToString('N'))"
        $script:Temp = Join-Path $TestDrive "tmp-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory $script:Tasks, $script:Temp -Force | Out-Null
        Copy-Item -LiteralPath $script:Fixture -Destination $script:Tasks -Recurse
        $script:TaskDir = Join-Path $script:Tasks 'TX01'
        Set-Content -LiteralPath (Join-Path $script:TaskDir 'solution\variants\bad\expected-failures.json') -Value '["NoFindMinus"]'

        $global:TT.Config = [pscustomobject]@{
            RepoRoot = $TestDrive; TempRoot = $script:Temp
            Bc       = [pscustomobject]@{ ArtifactType = 'Sandbox'; Country = 'w1'; Version = '29.0.1.2'; ContainerName = 'rfbench'; CompilerFolder = 'C:\fake' }
            Paths    = [pscustomobject]@{ AlParserDll = '' }
        }
        # Grade per variant: solution, alt, bad, assignment.
        $global:TT.Grades = @{
            solution   = New-Grade right
            alt        = New-Grade right
            bad        = New-Grade bad -Fail NoFindMinus
            assignment = New-Grade wrong -Fail NoFindMinus
            probe      = New-Grade bad -Fail NoFindMinus -BudgetsPassed $false
        }
        $global:TT.Calls = [Collections.Generic.List[object]]::new()
        $global:TT.Docker = [Collections.Generic.List[string]]::new()

        Mock Get-BenchConfig { $global:TT.Config }
        Mock Get-AlcPath { 'C:\fake\alc.exe' }
        Mock Import-AlParser { 'C:\fake\parser.dll' }
        Mock Assert-DockerWindowsMode { $global:TT.Docker.Add('assert') }
        Mock Switch-DockerMode { $global:TT.Docker.Add("switch:$Mode") }
        Mock Invoke-Grade {
            $root = $Task.Root
            $variant = switch ($AgentAppDir) {
                (Join-Path $root 'solution\app') { 'solution' }
                (Join-Path $root 'solution\variants\alt') { 'alt' }
                (Join-Path $root 'solution\variants\bad') { 'bad' }
                (Join-Path $root 'assignment\app') { 'assignment' }
                (Join-Path $root 'solution\variants\budget-probe') { 'probe' }
                default { throw "unexpected app dir $AgentAppDir" }
            }
            $global:TT.Calls.Add([pscustomobject]@{ Variant = $variant; GraderDir = $GraderDir; Attempt = $Attempt })
            $g = $global:TT.Grades[$variant]
            if ($g -is [string] -and $g -eq 'throw') { throw 'container is down' }
            $g
        }
    }

    Context 'all rules hold' {
        It 'exits 0 after grading solution, alt, bad and the starter app' {
            $r = Invoke-Validator
            $r.Exit | Should -Be 0
            $global:TT.Calls.Variant | Sort-Object | Should -Be @('alt', 'assignment', 'bad', 'solution')
            $r.Output | Should -Match 'TX01: valid'
        }

        It 'grades each variant into its own folder under TempRoot\validate\<task>' {
            Invoke-Validator | Out-Null
            foreach ($c in $global:TT.Calls) {
                $c.GraderDir | Should -Be (Join-Path $script:Temp "validate\TX01\$($c.Variant)")
                $c.Attempt | Should -Be 1
            }
        }

        It 'deletes the validate grader root afterwards, also when grading throws' {
            Mock Invoke-Grade {
                New-Item -ItemType Directory (Join-Path $GraderDir 'attempt1\tests') -Force | Out-Null
                Set-Content (Join-Path $GraderDir 'attempt1\tests\Hidden.Codeunit.al') 'codeunit 70100 Hidden {}'
                $root = $Task.Root
                if ($AgentAppDir -eq (Join-Path $root 'solution\variants\bad')) { return New-Grade bad -Fail NoFindMinus }
                if ($AgentAppDir -eq (Join-Path $root 'assignment\app')) { return New-Grade wrong }
                New-Grade right
            }
            (Invoke-Validator).Exit | Should -Be 0
            Test-Path (Join-Path $script:Temp 'validate\TX01') | Should -BeFalse

            Mock Invoke-Grade {
                New-Item -ItemType Directory (Join-Path $GraderDir 'attempt1') -Force | Out-Null
                throw 'container is down'
            }
            (Invoke-Validator).Exit | Should -Be 2
            Test-Path (Join-Path $script:Temp 'validate\TX01') | Should -BeFalse
        }

        It 'asserts Windows Docker mode and never switches without -SwitchDocker' {
            Invoke-Validator | Out-Null
            $global:TT.Docker | Should -Be @('assert')
        }

        It 'switches to Windows and back to Linux with -SwitchDocker' {
            (Invoke-Validator @{ SwitchDocker = $true }).Exit | Should -Be 0
            $global:TT.Docker | Should -Be @('switch:windows', 'switch:linux')
        }
    }

    Context 'reference and alternative solutions' {
        It 'fails when the reference solution is not fully right' {
            $global:TT.Grades.solution = New-Grade wrong
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'solution/app'
            $r.Output | Should -Match 'C\.Func'
        }

        It 'fails when the reference solution does not compile and shows the compile error' {
            $global:TT.Grades.solution = New-Grade right -Compiled $false
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'AL0001'
        }

        It 'fails when the alternative solution is not fully right' {
            $global:TT.Grades.alt = New-Grade bad -Fail NoFindMinus
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'variants/alt'
            $r.Output | Should -Match 'NoFindMinus'
        }

        It 'fails when the alternative solution misses a budget' {
            $global:TT.Grades.alt = New-Grade bad -BudgetsPassed $false
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'Budget_X'
        }

        It 'fails when variants/alt is missing' {
            Remove-Item -LiteralPath (Join-Path $script:TaskDir 'solution\variants\alt') -Recurse -Force
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'variants/alt'
            $global:TT.Calls.Variant | Should -Not -Contain 'alt'
        }
    }

    Context 'planted-bad variant' {
        It 'fails when an expected check does not fail' {
            $global:TT.Grades.bad = New-Grade right
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'NoFindMinus'
        }

        It 'fails when a check that is not expected also fails' {
            $global:TT.Grades.bad = New-Grade bad -Fail NoFindMinus, NoCommitIn
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'NoCommitIn'
        }

        It 'fails when the bad variant also fails a functional test' {
            $global:TT.Grades.bad = New-Grade bad -Fail NoFindMinus -TestsPassed $false
            (Invoke-Validator).Exit | Should -Be 1
        }

        It 'accepts a bad variant that also misses a budget and reports it' {
            # A standards violation may legitimately cost SQL; budgets are not constrained here.
            $global:TT.Grades.bad = New-Grade bad -Fail NoFindMinus -BudgetsPassed $false
            $r = Invoke-Validator
            $r.Exit | Should -Be 0
            $r.Output | Should -Match 'Budget_X'
        }

        It 'fails when the bad variant does not compile' {
            $global:TT.Grades.bad = New-Grade bad -Fail NoFindMinus -Compiled $false
            (Invoke-Validator).Exit | Should -Be 1
        }

        It 'accepts several expected failures in any order' {
            Set-Content -LiteralPath (Join-Path $script:TaskDir 'solution\variants\bad\expected-failures.json') -Value '["NoFindMinus", "NoCommitIn"]'
            $global:TT.Grades.bad = New-Grade bad -Fail NoCommitIn, NoFindMinus, NoFindMinus
            (Invoke-Validator).Exit | Should -Be 0
        }

        It 'fails without grading the bad variant when expected-failures.json is missing' {
            Remove-Item -LiteralPath (Join-Path $script:TaskDir 'solution\variants\bad\expected-failures.json')
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'expected-failures\.json'
            $global:TT.Calls.Variant | Should -Not -Contain 'bad'
        }

        It 'fails when expected-failures.json is empty' {
            Set-Content -LiteralPath (Join-Path $script:TaskDir 'solution\variants\bad\expected-failures.json') -Value '[]'
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'expected-failures\.json'
        }

        It 'fails when expected-failures.json names a check that is not in checks.json' {
            Set-Content -LiteralPath (Join-Path $script:TaskDir 'solution\variants\bad\expected-failures.json') -Value '["LogicNotOnPage"]'
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'LogicNotOnPage'
        }

        It 'fails when expected-failures.json is a bare string instead of an array' {
            Set-Content -LiteralPath (Join-Path $script:TaskDir 'solution\variants\bad\expected-failures.json') -Value '"NoFindMinus"'
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'expected-failures\.json must be'
            $global:TT.Calls.Variant | Should -Not -Contain 'bad'
        }
    }

    Context 'budget probe' {
        BeforeEach {
            $script:ProbeDir = Join-Path $script:TaskDir 'solution\variants\budget-probe'
            New-Item -ItemType Directory $script:ProbeDir -Force | Out-Null
        }

        It 'is not graded when the folder does not exist' {
            Remove-Item -LiteralPath $script:ProbeDir -Recurse -Force
            (Invoke-Validator).Exit | Should -Be 0
            $global:TT.Calls.Variant | Should -Not -Contain 'probe'
        }

        It 'passes when the probe fails a budget, into its own grader folder' {
            $r = Invoke-Validator
            $r.Exit | Should -Be 0
            $r.Output | Should -Match 'budget-probe'
            $c = $global:TT.Calls | Where-Object Variant -EQ 'probe'
            $c.GraderDir | Should -Be (Join-Path $script:Temp 'validate\TX01\budget-probe')
        }

        It 'fails when the probe passes every budget' {
            $global:TT.Grades.probe = New-Grade bad -Fail NoFindMinus
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'variants/budget-probe'
            $r.Output | Should -Match 'no Budget_ test failed'
        }

        It 'fails when the probe fails a functional test' {
            $global:TT.Grades.probe = New-Grade bad -TestsPassed $false -BudgetsPassed $false
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'C\.Func'
        }

        It 'fails when the probe does not compile' {
            $global:TT.Grades.probe = New-Grade bad -Compiled $false -BudgetsPassed $false
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'AL0001'
        }
    }

    Context 'starter app' {
        It 'fails a bugfix task whose starter app is already fully right' {
            $global:TT.Grades.assignment = New-Grade right
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'assignment/app'
        }

        It 'does not grade the assignment of a greenfield task' {
            $tj = Join-Path $script:TaskDir 'task.json'
            $j = Get-Content $tj -Raw | ConvertFrom-Json
            $j.type = 'greenfield'
            $j | ConvertTo-Json | Set-Content $tj
            Remove-Item -LiteralPath (Join-Path $script:TaskDir 'assignment\app\src') -Recurse -Force
            $r = Invoke-Validator
            $r.Exit | Should -Be 0
            $global:TT.Calls.Variant | Should -Not -Contain 'assignment'
        }
    }

    Context 'validator errors' {
        It 'exits 2 (not a task failure) when grading throws, and still switches Docker back' {
            $global:TT.Grades.alt = 'throw'
            $r = Invoke-Validator @{ SwitchDocker = $true }
            $r.Exit | Should -Be 2
            $r.Output | Should -Match 'validator error'
            $r.Output | Should -Match 'container is down'
            $global:TT.Docker[-1] | Should -Be 'switch:linux'
        }

        It 'exits 2 when the compiler folder is not set up, before grading' {
            Mock Get-AlcPath { throw 'Bc.CompilerFolder not set; run src/Initialize-Backend.ps1' }
            $r = Invoke-Validator
            $r.Exit | Should -Be 2
            $r.Output | Should -Match 'Initialize-Backend'
            $global:TT.Calls.Count | Should -Be 0
        }

        It 'exits 1 when the task does not load' {
            Remove-Item -LiteralPath (Join-Path $script:TaskDir 'solution\checks.json')
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'missing solution/checks.json'
            $global:TT.Calls.Count | Should -Be 0
        }

        It 'exits 1 when the task folder does not exist' {
            $out = & $script:Validator -Task TX99 -TasksRoot $script:Tasks 6>&1 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'TX99'
        }
    }

    Context 'test lint' {

        It '-LintOnly exits 0 on a clean task without config, grading or Docker' {
            Set-LintTest $script:TaskDir "        Assert.IsTrue(true, 'x');"
            $r = Invoke-Validator @{ LintOnly = $true }
            $r.Exit | Should -Be 0
            Should -Invoke Get-BenchConfig -Times 0 -Exactly
            Should -Invoke Invoke-Grade -Times 0 -Exactly
            $global:TT.Docker.Count | Should -Be 0
        }

        It '-LintOnly exits 1 and prints the finding' {
            Set-LintTest $script:TaskDir '        Foo();'
            $r = Invoke-Validator @{ LintOnly = $true }
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'src[\\/]Lint\.Codeunit\.al:6 no-assertion'
            Should -Invoke Get-BenchConfig -Times 0 -Exactly
            Should -Invoke Invoke-Grade -Times 0 -Exactly
        }

        It 'normal mode reports lint findings as problems, exits 1 and still grades' {
            Set-LintTest $script:TaskDir '        Foo();'
            $r = Invoke-Validator
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'tests: src[\\/]Lint\.Codeunit\.al:6 no-assertion'
            $global:TT.Calls.Variant | Sort-Object | Should -Be @('alt', 'assignment', 'bad', 'solution')
        }
    }
}
