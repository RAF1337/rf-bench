#Requires -Version 7.6
Set-StrictMode -Version Latest

# Grades one attempt: compiles the agent's app with analyzers, publishes it with the hidden
# test app, runs the tests and the standards checks, and computes the fullyRight flags.

Import-Module (Join-Path $PSScriptRoot 'Backend.Docker.psm1')
Import-Module (Join-Path $PSScriptRoot 'Checks/Checks.psm1')

# Copies the contents of $Source into a new, empty $Destination. A missing source gives an
# empty destination, so the compile reports the missing app.json.
function Copy-Folder([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory $Destination -Force | Out-Null
    if (Test-Path -LiteralPath $Source -PathType Container) {
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
    }
}

# Compiles without ever throwing: an exception (for example a locked stale out file) is
# returned as a failed compile with the exception message as the error.
function Invoke-SafeCompile($Config, [string]$AppDir, [string]$OutFile, [switch]$EnableAnalyzers) {
    try {
        $r = Invoke-AlCompile $Config -AppDir $AppDir -OutFile $OutFile -EnableAnalyzers:$EnableAnalyzers
        [pscustomobject]@{
            Success  = [bool]$r.Success
            Errors   = [string[]]@($r.Errors | Where-Object { $_ })
            Warnings = [object[]]@($r.Warnings | Where-Object { $_ })
            AppFile  = $r.AppFile
        }
    }
    catch {
        [pscustomobject]@{ Success = $false; Errors = [string[]]@($_.Exception.Message); Warnings = [object[]]@(); AppFile = $null }
    }
}

# Compiler and backend messages name files in the grader copy. App files are pointed at the
# agent's own folder so the feedback refers to files the agent can open; test app files become
# relative 'tests\...' paths. As a catch-all, any other path under the attempt folder or the
# grader folder becomes a neutral token, so no absolute grader path reaches the agent.
$script:GraderToken = '<build>'

# The path as given and fully resolved, each with backslashes and with forward slashes.
function Get-PathForms([string]$Path) {
    $given = $Path.TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    @($full, ($full -replace '\\', '/'), $given, ($given -replace '\\', '/'), ($given -replace '/', '\')) |
        Where-Object { $_ } | Select-Object -Unique
}

# $Map holds ordered pairs @(from, to); specific paths must come before the catch-alls.
function ConvertTo-AgentPath([string[]]$Lines, [object[]]$Map) {
    $rules = foreach ($m in $Map) {
        foreach ($form in Get-PathForms $m[0]) {
            [pscustomobject]@{ Rx = [regex]::new([regex]::Escape($form), 'IgnoreCase'); To = [string]$m[1] }
        }
    }
    foreach ($l in $Lines) {
        foreach ($r in $rules) {
            $to = $r.To
            $l = $r.Rx.Replace([string]$l, { param($x) $to }.GetNewClosure())
        }
        $l
    }
}

function Remove-AppQuietly($Config, [guid]$AppId) {
    try { Remove-BenchApp $Config -AppId $AppId }
    catch { Write-Warning "Grader cleanup: removing app $AppId failed: $($_.Exception.Message)" }
}

function Invoke-Grade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$AgentAppDir,
        [Parameter(Mandatory)][string]$GraderDir,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Attempt
    )

    $attemptDir = Join-Path $GraderDir "attempt$Attempt"
    if (Test-Path -LiteralPath $attemptDir) { Remove-Item -LiteralPath $attemptDir -Recurse -Force }
    $appDir = Join-Path $attemptDir 'app'
    $testsDir = Join-Path $attemptDir 'tests'
    $outDir = Join-Path $attemptDir 'out'
    Copy-Folder $AgentAppDir $appDir
    Copy-Folder $Task.TestsDir $testsDir
    New-Item -ItemType Directory $outDir -Force | Out-Null

    $grade = [pscustomobject]@{
        Compiled         = $false
        CompileErrors    = [string[]]@()
        AnalyzerWarnings = [ordered]@{}
        Tests            = [object[]]@()
        TestsPassed      = $false
        BudgetsPassed    = $false
        Findings         = [object[]]@()
        ChecksPassed     = $false
        FullyRight       = $false
    }

    # Specific mappings first, then the attempt and grader folders as catch-alls.
    $pathMap = @(
        , @($appDir, $AgentAppDir.TrimEnd('\', '/'))
        , @($testsDir, 'tests')
        , @($attemptDir, $script:GraderToken)
        , @($GraderDir, $script:GraderToken)
    )

    $build = Invoke-SafeCompile $Config $appDir (Join-Path $outDir "$($Task.Id).app") -EnableAnalyzers
    foreach ($g in @($build.Warnings | Group-Object Rule | Sort-Object Name)) { $grade.AnalyzerWarnings[$g.Name] = $g.Count }
    if (-not $build.Success) {
        $errs = if ($build.Errors.Count) { $build.Errors } else { @('Compilation failed without compiler output.') }
        $grade.CompileErrors = [string[]]@(ConvertTo-AgentPath $errs $pathMap)
        return $grade
    }
    $grade.Compiled = $true

    $tests = @()
    try {
        # Stale copies from a crashed run would block the publish; the test app depends on the app.
        Remove-BenchApp $Config -AppId $Task.TestAppId
        Remove-BenchApp $Config -AppId $Task.AppId

        # A publish failure of the agent's app is the agent's result (for example an install
        # codeunit error), so it is graded as a failing pseudo-test and the tests are skipped.
        $publishError = $null
        try { Publish-BenchApp $Config -AppFile $build.AppFile }
        catch { $publishError = $_.Exception.Message }

        if ($null -ne $publishError) {
            $tests = @([pscustomobject]@{
                    Codeunit = 'Publish'; Name = 'App'; Passed = $false
                    Message = "Publishing your app failed: $publishError"; CallStack = $null; IsBudget = $false
                })
        }
        else {
            # The test app compiles against the agent's app: put it in a fresh test symbol folder
            # (a copied folder could hold a stale build of the app; the compiler refills the rest).
            $symbols = Join-Path $testsDir '.alpackages'
            if (Test-Path -LiteralPath $symbols) { Remove-Item -LiteralPath $symbols -Recurse -Force }
            New-Item -ItemType Directory $symbols -Force | Out-Null
            Copy-Item -LiteralPath $build.AppFile -Destination $symbols -Force
            # Exceptions here (missing compiler, locked file) are infrastructure errors and throw.
            $testBuild = Invoke-AlCompile $Config -AppDir $testsDir -OutFile (Join-Path $outDir "$($Task.Id).Tests.app")
            if (-not $testBuild.Success) {
                $msg = @('The test app does not compile against your app:') + @($testBuild.Errors | Where-Object { $_ })
                $tests = @([pscustomobject]@{
                        Codeunit = 'Test app'; Name = 'Compile'; Passed = $false
                        Message = $msg -join "`n"; CallStack = $null; IsBudget = $false
                    })
            }
            else {
                Publish-BenchApp $Config -AppFile $testBuild.AppFile
                $tests = @(Invoke-BenchTests $Config -TestAppId $Task.TestAppId | Where-Object { $_ })
                if ($tests.Count -eq 0) {
                    $tests = @([pscustomobject]@{
                            Codeunit = 'Test run'; Name = 'Results'; Passed = $false
                            Message = 'The test run returned no results.'; CallStack = $null; IsBudget = $false
                        })
                }
            }
        }
    }
    finally {
        Remove-AppQuietly $Config $Task.TestAppId
        Remove-AppQuietly $Config $Task.AppId
    }

    foreach ($t in $tests) {
        if ($t.Message) { $t.Message = (@(ConvertTo-AgentPath ([string]$t.Message -split "`n") $pathMap) -join "`n") }
        if ($t.CallStack) { $t.CallStack = (@(ConvertTo-AgentPath ([string]$t.CallStack -split "`n") $pathMap) -join "`n") }
    }

    $specs = @(Get-Content -LiteralPath $Task.ChecksFile -Raw | ConvertFrom-Json)
    # Invoke-AlChecks returns its findings as one array object; ForEach-Object unrolls it.
    $findings = @(Invoke-AlChecks -SourceDir $appDir -CheckSpecs $specs -Config $Config | ForEach-Object { $_ } | Where-Object { $_ })

    $grade.Tests = [object[]]$tests
    $grade.TestsPassed = -not @($tests | Where-Object { -not $_.IsBudget -and -not $_.Passed })
    $grade.BudgetsPassed = -not @($tests | Where-Object { $_.IsBudget -and -not $_.Passed })
    $grade.Findings = [object[]]$findings
    $grade.ChecksPassed = -not @($findings | Where-Object { -not $_.Passed })
    $grade.FullyRight = $grade.Compiled -and $grade.TestsPassed -and $grade.BudgetsPassed -and $grade.ChecksPassed
    $grade
}

Export-ModuleMember -Function Invoke-Grade
