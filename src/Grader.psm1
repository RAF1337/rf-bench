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

# Compiler messages name files in the grader copy. App files are pointed at the agent's own
# folder so the feedback refers to files the agent can open; test app files become relative
# 'tests\...' paths. The grader location is never revealed.
function ConvertTo-AgentPath([string[]]$Lines, [string]$GraderAppDir, [string]$AgentAppDir, [string]$GraderTestsDir) {
    $map = @(
        , @($GraderAppDir.TrimEnd('\', '/'), $AgentAppDir.TrimEnd('\', '/'))
        if ($GraderTestsDir) { , @($GraderTestsDir.TrimEnd('\', '/'), 'tests') }
    )
    foreach ($l in $Lines) {
        foreach ($m in $map) {
            $rx = [regex]::new([regex]::Escape($m[0]), 'IgnoreCase')
            $to = $m[1]
            $l = $rx.Replace($l, { param($x) $to }.GetNewClosure())
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

    $build = Invoke-SafeCompile $Config $appDir (Join-Path $outDir "$($Task.Id).app") -EnableAnalyzers
    foreach ($g in @($build.Warnings | Group-Object Rule | Sort-Object Name)) { $grade.AnalyzerWarnings[$g.Name] = $g.Count }
    if (-not $build.Success) {
        $errs = if ($build.Errors.Count) { $build.Errors } else { @('Compilation failed without compiler output.') }
        $grade.CompileErrors = [string[]]@(ConvertTo-AgentPath $errs $appDir $AgentAppDir)
        return $grade
    }
    $grade.Compiled = $true

    $tests = @()
    try {
        # Stale copies from a crashed run would block the publish; the test app depends on the app.
        Remove-BenchApp $Config -AppId $Task.TestAppId
        Remove-BenchApp $Config -AppId $Task.AppId
        Publish-BenchApp $Config -AppFile $build.AppFile

        # The test app compiles against the agent's app: put it in a fresh test symbol folder
        # (a copied folder could hold a stale build of the app; the compiler refills the rest).
        $symbols = Join-Path $testsDir '.alpackages'
        if (Test-Path -LiteralPath $symbols) { Remove-Item -LiteralPath $symbols -Recurse -Force }
        New-Item -ItemType Directory $symbols -Force | Out-Null
        Copy-Item -LiteralPath $build.AppFile -Destination $symbols -Force
        $testBuild = Invoke-SafeCompile $Config $testsDir (Join-Path $outDir "$($Task.Id).Tests.app")
        if (-not $testBuild.Success) {
            $msg = @('The test app does not compile against your app:') + @(ConvertTo-AgentPath $testBuild.Errors $appDir $AgentAppDir $testsDir)
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
    finally {
        Remove-AppQuietly $Config $Task.TestAppId
        Remove-AppQuietly $Config $Task.AppId
    }

    $specs = @(Get-Content -LiteralPath $Task.ChecksFile -Raw | ConvertFrom-Json)
    $findings = @(Invoke-AlChecks -SourceDir $appDir -CheckSpecs $specs -Config $Config | Where-Object { $_ })

    $grade.Tests = [object[]]$tests
    $grade.TestsPassed = -not @($tests | Where-Object { -not $_.IsBudget -and -not $_.Passed })
    $grade.BudgetsPassed = -not @($tests | Where-Object { $_.IsBudget -and -not $_.Passed })
    $grade.Findings = [object[]]$findings
    $grade.ChecksPassed = -not @($findings | Where-Object { -not $_.Passed })
    $grade.FullyRight = $grade.Compiled -and $grade.TestsPassed -and $grade.BudgetsPassed -and $grade.ChecksPassed
    $grade
}

Export-ModuleMember -Function Invoke-Grade
