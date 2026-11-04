#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Task.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Grader.psm1') -Force

    $script:Task = Get-BenchTask (Join-Path $PSScriptRoot 'fixtures\tasks\TX01')

    function New-AgentApp {
        $dir = Join-Path $TestDrive "agent-$([guid]::NewGuid().ToString('N'))\app"
        Copy-Item -LiteralPath (Join-Path $script:Task.AssignmentDir 'app') -Destination $dir -Recurse
        $dir
    }
    function New-Test([string]$Name, [bool]$Passed, [string]$Message = $null) {
        [pscustomobject]@{
            Codeunit = 'TX01 Tests'; Name = $Name; Passed = $Passed; Message = $Message
            CallStack = if ($Passed) { $null } else { 'TX01 Tests(CodeUnit 50150).' + $Name + ' line 3' }
            IsBudget = $Name -like 'Budget_*'
        }
    }
    function New-TestFinding([bool]$Passed, [string]$Category = 'data-access') {
        [pscustomobject]@{ Check = 'NoFindMinus'; Category = $Category; File = 'src\Starter.Codeunit.al'; Line = 1; Passed = $Passed; Detail = 'x' }
    }

    # Mocks the whole backend: compile writes the out file, publish/remove/tests are recorded.
    function Set-BackendMocks([object[]]$Tests = @((New-Test 'TestPost' $true)), [object[]]$Warnings = @(), [switch]$RealCompile, [switch]$RealChecks) {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:CompileArgs = [System.Collections.Generic.List[object]]::new()
        $script:MockTests = $Tests
        $script:MockWarnings = $Warnings
        if (-not $RealCompile) {
            Mock -ModuleName Grader Invoke-AlCompile {
                $script:CompileArgs.Add([pscustomobject]@{ AppDir = $AppDir; OutFile = $OutFile; Analyzers = [bool]$EnableAnalyzers })
                New-Item -ItemType Directory (Split-Path $OutFile -Parent) -Force | Out-Null
                Set-Content -LiteralPath $OutFile 'app'
                [pscustomobject]@{ Success = $true; Errors = @(); Warnings = $script:MockWarnings; AppFile = $OutFile }
            }
        }
        Mock -ModuleName Grader Remove-BenchApp { $script:Calls.Add("remove:$AppId") }
        Mock -ModuleName Grader Publish-BenchApp { $script:Calls.Add("publish:$(Split-Path $AppFile -Leaf)") }
        Mock -ModuleName Grader Invoke-BenchTests { $script:Calls.Add("tests:$TestAppId"); $script:MockTests }
        if (-not $RealChecks) { Mock -ModuleName Grader Invoke-AlChecks { @(New-TestFinding $true) } }
    }

    $script:Config = Get-BenchConfig
    $script:AppId = '11111111-1111-1111-1111-111111111111'
    $script:TestAppId = '22222222-2222-2222-2222-222222222222'
}

Describe 'Invoke-Grade' {
    BeforeEach {
        $script:Grader = Join-Path $TestDrive "grader-$([guid]::NewGuid().ToString('N'))"
    }

    It 'grades missing app.json as not compiled' {
        # Real compile: it reports the missing app.json before touching BcContainerHelper.
        Set-BackendMocks -RealCompile
        $agent = New-AgentApp
        Remove-Item (Join-Path $agent 'app.json')
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir $agent -GraderDir $script:Grader -Attempt 1
        $g.Compiled | Should -BeFalse
        @($g.CompileErrors).Count | Should -BeGreaterThan 0
        $g.CompileErrors[0] | Should -Match 'app\.json not found'
        $g.FullyRight | Should -BeFalse
        Should -Invoke -ModuleName Grader Publish-BenchApp -Times 0 -Exactly
        Should -Invoke -ModuleName Grader Invoke-BenchTests -Times 0 -Exactly
        Should -Invoke -ModuleName Grader Invoke-AlChecks -Times 0 -Exactly
    }

    It 'grades a missing agent app folder as not compiled' {
        Set-BackendMocks -RealCompile
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (Join-Path $TestDrive 'nope\app') -GraderDir $script:Grader -Attempt 1
        $g.Compiled | Should -BeFalse
        $g.CompileErrors[0] | Should -Match 'app\.json not found'
    }

    It 'treats a compile exception as not compiled' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlCompile { throw 'The process cannot access the file because it is being used by another process.' }
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.Compiled | Should -BeFalse
        $g.CompileErrors | Should -Contain 'The process cannot access the file because it is being used by another process.'
        Should -Invoke -ModuleName Grader Publish-BenchApp -Times 0 -Exactly
    }

    It 'reports compile errors against the agent app folder, not the grader folder' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlCompile {
            [pscustomobject]@{ Success = $false; Errors = @("$AppDir\src\Starter.Codeunit.al(1,5): error AL0104: Syntax error"); Warnings = @(); AppFile = $null }
        }
        $agent = New-AgentApp
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir $agent -GraderDir $script:Grader -Attempt 1
        $g.CompileErrors[0] | Should -BeExactly "$agent\src\Starter.Codeunit.al(1,5): error AL0104: Syntax error"
        $g.CompileErrors[0] | Should -Not -Match ([regex]::Escape($script:Grader))
    }

    It 'copies the agent app and the tests into the attempt folder and compiles the app with analyzers' {
        Set-BackendMocks
        $agent = New-AgentApp
        $null = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir $agent -GraderDir $script:Grader -Attempt 2
        $att = Join-Path $script:Grader 'attempt2'
        Test-Path (Join-Path $att 'app\src\Starter.Codeunit.al') | Should -BeTrue
        Test-Path (Join-Path $att 'tests\app.json') | Should -BeTrue
        $script:CompileArgs.Count | Should -Be 2
        $script:CompileArgs[0].AppDir | Should -Be (Join-Path $att 'app')
        $script:CompileArgs[0].Analyzers | Should -BeTrue
        $script:CompileArgs[1].AppDir | Should -Be (Join-Path $att 'tests')
        $script:CompileArgs[1].Analyzers | Should -BeFalse
        Should -Invoke -ModuleName Grader Invoke-AlChecks -Times 1 -Exactly -ParameterFilter {
            $SourceDir -eq (Join-Path $att 'app') -and $null -ne $Config -and @($CheckSpecs).Count -eq 2
        }
    }

    It 'puts the built agent app in the test app symbol folder before compiling the tests' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlCompile {
            $script:CompileArgs.Add([pscustomobject]@{
                    AppDir = $AppDir
                    Symbols = @(Get-ChildItem (Join-Path $AppDir '.alpackages') -Filter *.app -ErrorAction Ignore | ForEach-Object Name)
                })
            New-Item -ItemType Directory (Split-Path $OutFile -Parent) -Force | Out-Null
            Set-Content -LiteralPath $OutFile 'app'
            [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @(); AppFile = $OutFile }
        }
        # A stale build in the task's test symbol folder must not reach the test compile.
        $task = $script:Task.PSObject.Copy()
        $task.TestsDir = Join-Path $TestDrive "tests-$([guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $script:Task.TestsDir -Destination $task.TestsDir -Recurse
        New-Item -ItemType Directory (Join-Path $task.TestsDir '.alpackages') | Out-Null
        Set-Content (Join-Path $task.TestsDir '.alpackages\rf_TX01 App_0.9.0.0.app') 'stale'
        $null = Invoke-Grade -Config $script:Config -Task $task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $script:CompileArgs[1].Symbols | Should -Be @('TX01.app')
    }

    It 'removes the test app then the app before publishing, publishes app then tests, and removes both after' {
        Set-BackendMocks
        $null = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $script:Calls | Should -Be @(
            "remove:$script:TestAppId", "remove:$script:AppId",
            'publish:TX01.app', 'publish:TX01.Tests.app',
            "tests:$script:TestAppId",
            "remove:$script:TestAppId", "remove:$script:AppId"
        )
    }

    It 'always removes apps' {
        Set-BackendMocks
        Mock -ModuleName Grader Publish-BenchApp {
            $script:Calls.Add("publish:$(Split-Path $AppFile -Leaf)")
            if ($AppFile -like '*Tests.app') { throw 'publish failed' }
        }
        { Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1 } |
            Should -Throw '*publish failed*'
        $script:Calls | Should -Be @(
            "remove:$script:TestAppId", "remove:$script:AppId",
            'publish:TX01.app', 'publish:TX01.Tests.app',
            "remove:$script:TestAppId", "remove:$script:AppId"
        )
    }

    It 'still removes the app when removing the test app fails during cleanup' {
        Set-BackendMocks
        $script:RemoveCount = 0
        Mock -ModuleName Grader Remove-BenchApp {
            $script:Calls.Add("remove:$AppId")
            $script:RemoveCount++
            if ($script:RemoveCount -eq 3) { throw 'unpublish failed' }
        }
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1 -WarningAction SilentlyContinue
        $g.FullyRight | Should -BeTrue
        $script:Calls[-1] | Should -Be "remove:$script:AppId"
    }

    It 'grades a test app that does not compile against the agent app as a failing test' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlCompile {
            if ($AppDir -like '*tests') {
                return [pscustomobject]@{ Success = $false; Errors = @("$AppDir\src\T.al(4,9): error AL0132: 'Post' is not found"); Warnings = @(); AppFile = $null }
            }
            New-Item -ItemType Directory (Split-Path $OutFile -Parent) -Force | Out-Null
            Set-Content -LiteralPath $OutFile 'app'
            [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @(); AppFile = $OutFile }
        }
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.Compiled | Should -BeTrue
        $g.TestsPassed | Should -BeFalse
        $g.FullyRight | Should -BeFalse
        $g.Tests[0].Passed | Should -BeFalse
        $g.Tests[0].Message | Should -Match "'Post' is not found"
        $g.Tests[0].Message | Should -Not -Match ([regex]::Escape($script:Grader))
        $g.Tests[0].Message | Should -Match ([regex]::Escape("tests\src\T.al(4,9): error AL0132"))
        Should -Invoke -ModuleName Grader Invoke-BenchTests -Times 0 -Exactly
        $script:Calls | Should -Be @(
            "remove:$script:TestAppId", "remove:$script:AppId", 'publish:TX01.app',
            "remove:$script:TestAppId", "remove:$script:AppId"
        )
    }

    It 'grades a publish failure of the agent app as a failing pseudo-test' {
        Set-BackendMocks
        Mock -ModuleName Grader Publish-BenchApp {
            $script:Calls.Add("publish:$(Split-Path $AppFile -Leaf)")
            throw "Install codeunit failed for $AppFile"
        }
        Mock -ModuleName Grader Invoke-AlChecks { @((New-TestFinding $false)) }
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.Compiled | Should -BeTrue
        @($g.Tests).Count | Should -Be 1
        $g.Tests[0].Codeunit | Should -Be 'Publish'
        $g.Tests[0].Name | Should -Be 'App'
        $g.Tests[0].Passed | Should -BeFalse
        $g.Tests[0].Message | Should -Match 'Install codeunit failed'
        $g.Tests[0].Message | Should -Not -Match ([regex]::Escape($script:Grader))
        $g.TestsPassed | Should -BeFalse
        $g.ChecksPassed | Should -BeFalse
        @($g.Findings).Count | Should -Be 1
        $g.FullyRight | Should -BeFalse
        Should -Invoke -ModuleName Grader Invoke-AlChecks -Times 1 -Exactly
        Should -Invoke -ModuleName Grader Invoke-BenchTests -Times 0 -Exactly
        $script:CompileArgs.Count | Should -Be 1
        $script:Calls | Should -Be @(
            "remove:$script:TestAppId", "remove:$script:AppId", 'publish:TX01.app',
            "remove:$script:TestAppId", "remove:$script:AppId"
        )
    }

    It 'never leaves an absolute grader path in compile errors' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlCompile {
            $fwd = $OutFile -replace '\\', '/'
            throw "The process cannot access the file '$OutFile' because it is being used by another process ($fwd)."
        }
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 3
        $g.Compiled | Should -BeFalse
        $text = $g.CompileErrors -join "`n"
        $text | Should -Match ([regex]::Escape('<build>\out\TX01.app'))
        $text | Should -Match ([regex]::Escape('<build>/out/TX01.app'))
        $text | Should -Not -Match ([regex]::Escape($script:Grader))
        $text | Should -Not -Match ([regex]::Escape(($script:Grader -replace '\\', '/')))
    }

    It 'throws when the test app compile throws, after removing both apps' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlCompile {
            if ($AppDir -like '*tests') { throw 'alc.exe not found' }
            New-Item -ItemType Directory (Split-Path $OutFile -Parent) -Force | Out-Null
            Set-Content -LiteralPath $OutFile 'app'
            [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @(); AppFile = $OutFile }
        }
        { Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1 } |
            Should -Throw '*alc.exe not found*'
        $script:Calls | Should -Be @(
            "remove:$script:TestAppId", "remove:$script:AppId", 'publish:TX01.app',
            "remove:$script:TestAppId", "remove:$script:AppId"
        )
    }

    It 'is fully right when everything passes' {
        Set-BackendMocks
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.Compiled | Should -BeTrue
        $g.TestsPassed | Should -BeTrue
        $g.BudgetsPassed | Should -BeTrue
        $g.ChecksPassed | Should -BeTrue
        $g.FullyRight | Should -BeTrue
    }

    It 'budget failure does not fail testsPassed' {
        Set-BackendMocks -Tests @((New-Test 'TestPost' $true), (New-Test 'Budget_PostLargeOrder' $false 'SQL statements 14 > 10'))
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.TestsPassed | Should -BeTrue
        $g.BudgetsPassed | Should -BeFalse
        $g.FullyRight | Should -BeFalse
    }

    It 'functional failure fails testsPassed but not budgetsPassed' {
        Set-BackendMocks -Tests @((New-Test 'TestPost' $false 'boom'), (New-Test 'Budget_PostLargeOrder' $true))
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.TestsPassed | Should -BeFalse
        $g.BudgetsPassed | Should -BeTrue
        $g.FullyRight | Should -BeFalse
    }

    It 'an empty test run does not pass' {
        Set-BackendMocks -Tests @()
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.TestsPassed | Should -BeFalse
        $g.FullyRight | Should -BeFalse
        @($g.Tests | Where-Object { -not $_.Passed }).Count | Should -Be 1
    }

    It 'fullyRight requires checks' {
        Set-BackendMocks
        Mock -ModuleName Grader Invoke-AlChecks { @((New-TestFinding $true), (New-TestFinding $false)) }
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.TestsPassed | Should -BeTrue
        $g.ChecksPassed | Should -BeFalse
        @($g.Findings).Count | Should -Be 2
        $g.FullyRight | Should -BeFalse
    }

    It 'analyzer warnings do not block fullyRight' {
        $w = @(
            [pscustomobject]@{ Rule = 'AA0021'; Message = 'm'; File = 'a.al'; Line = 1 }
            [pscustomobject]@{ Rule = 'AA0021'; Message = 'm'; File = 'b.al'; Line = 2 }
            [pscustomobject]@{ Rule = 'AW0006'; Message = 'm'; File = 'a.al'; Line = 3 }
        )
        Set-BackendMocks -Warnings $w
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.AnalyzerWarnings['AA0021'] | Should -Be 2
        $g.AnalyzerWarnings['AW0006'] | Should -Be 1
        $g.FullyRight | Should -BeTrue
    }

    It 'runs the real checks with the configured parser' {
        Set-BackendMocks -RealChecks
        $g = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        $g.ChecksPassed | Should -BeTrue
        $g.FullyRight | Should -BeTrue
    }

    It 'replaces a stale attempt folder' {
        Set-BackendMocks
        $stale = Join-Path $script:Grader 'attempt1\app\src\Stale.al'
        New-Item -ItemType Directory (Split-Path $stale -Parent) -Force | Out-Null
        Set-Content $stale 'old'
        $null = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir (New-AgentApp) -GraderDir $script:Grader -Attempt 1
        Test-Path $stale | Should -BeFalse
    }
}
