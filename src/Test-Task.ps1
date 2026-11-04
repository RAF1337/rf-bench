#Requires -Version 7.6
<#
.SYNOPSIS
    Validates a benchmark task against the BC container.

.DESCRIPTION
    Grades the task's apps with the real grader and checks:
      - solution/app is fully right;
      - solution/variants/alt is fully right;
      - solution/variants/bad compiles and passes all functional tests, and the set of failing
        checks is exactly the list in solution/variants/bad/expected-failures.json (a JSON
        array of check names, each one listed in solution/checks.json). Budget results of the
        bad variant are reported but not required: a planted standards violation may
        legitimately cost SQL;
      - if solution/variants/budget-probe exists (a functionally correct, standards-naive
        solution), it compiles, passes the functional tests and fails at least one Budget_
        test, which shows that the budgets can fail;
      - for bugfix and feature tasks, assignment/app is not fully right (the task is not
        already solved).

    Exit codes: 0 = valid, 1 = the task is invalid (a rule above fails or the task does not
    load), 2 = validator error (configuration, Docker, compiler or grader infrastructure).

.EXAMPLE
    pwsh src/Test-Task.ps1 -Task T001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Task,
    # Folder holding the task folders. Default: <repo>/tasks.
    [string]$TasksRoot,
    [string]$ConfigPath,
    [switch]$SwitchDocker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in 'Config', 'Task', 'Backend.Docker', 'Grader') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1")
}
Import-Module (Join-Path $PSScriptRoot 'Checks\AlParser.psm1')

$script:Problems = [Collections.Generic.List[string]]::new()
# One grader folder per graded app.
$script:GraderFolders = @{
    'solution/app' = 'solution'; 'solution/variants/alt' = 'alt'; 'solution/variants/bad' = 'bad'
    'solution/variants/budget-probe' = 'budget-probe'; 'assignment/app' = 'assignment'
}

function Add-Problem([string]$Variant, [string]$Text) {
    $script:Problems.Add("${Variant}: $Text")
    Write-Host "  FAIL ${Variant}: $Text"
}

# Short reasons why a grade is not fully right.
function Get-GradeReasons($Grade) {
    if (-not $Grade.Compiled) {
        $errs = @($Grade.CompileErrors | Select-Object -First 5)
        return @('does not compile') + @($errs | ForEach-Object { "    $_" })
    }
    $r = @()
    foreach ($t in @($Grade.Tests | Where-Object { -not $_.Passed })) {
        $kind = if ($t.IsBudget) { 'budget' } else { 'test' }
        $r += "$kind $($t.Codeunit).$($t.Name) failed: $($t.Message)"
    }
    foreach ($c in Get-FailedChecks $Grade) { $r += "check $c failed" }
    $r
}

function Get-FailedChecks($Grade) {
    @($Grade.Findings | Where-Object { $_ -and -not $_.Passed } | ForEach-Object { [string]$_.Check } | Sort-Object -Unique)
}

function Invoke-VariantGrade($Ctx, [string]$Name, [string]$AppDir) {
    Write-Host "Grading $Name ..."
    $graderDir = Join-Path $Ctx.Config.TempRoot "validate\$($Ctx.Task.Id)\$($script:GraderFolders[$Name])"
    try {
        Invoke-Grade -Config $Ctx.Config -Task $Ctx.Task -AgentAppDir $AppDir -GraderDir $graderDir -Attempt 1
    }
    catch {
        throw [System.InvalidOperationException]::new("grading $Name failed: $($_.Exception.Message)", $_.Exception)
    }
}

# Must be fully right (reference and alternative solutions).
function Test-FullyRight($Ctx, [string]$Name, [string]$AppDir) {
    if (-not $AppDir -or -not (Test-Path -LiteralPath $AppDir -PathType Container)) { Add-Problem $Name 'folder is missing'; return }
    $g = Invoke-VariantGrade $Ctx $Name $AppDir
    if ($g.FullyRight) { Write-Host "  ok   ${Name}: fully right"; return }
    Add-Problem $Name ("not fully right`n    " + ((Get-GradeReasons $g) -join "`n    "))
}

# Reads expected-failures.json; returns $null (after reporting) when it is unusable.
function Get-ExpectedFailures($Ctx, [string]$Name) {
    $file = Join-Path $Ctx.Task.BadDir 'expected-failures.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Add-Problem $Name 'expected-failures.json is missing'; return $null }
    try { $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -NoEnumerate }
    catch { Add-Problem $Name "expected-failures.json is not valid JSON ($($_.Exception.Message))"; return $null }
    # -NoEnumerate keeps a JSON array as one array object, so a bare value can be told apart.
    $isArray = $json -is [array]
    $list = @(if ($isArray) { $json | ForEach-Object { $_ } })
    $names = @($list | Where-Object { $_ -is [string] -and $_ })
    if (-not $isArray -or $names.Count -eq 0 -or $names.Count -ne $list.Count) {
        Add-Problem $Name 'expected-failures.json must be a non-empty JSON array of check names'
        return $null
    }
    $configured = @(Get-Content -LiteralPath $Ctx.Task.ChecksFile -Raw | ConvertFrom-Json | ForEach-Object { [string]$_.check })
    $unknown = @($names | Where-Object { $_ -notin $configured })
    if ($unknown) {
        Add-Problem $Name "expected-failures.json names checks that are not in checks.json: $($unknown -join ', ')"
        return $null
    }
    , @($names | Sort-Object -Unique)
}

# Must compile and pass the functional tests; the failing checks must be exactly the expected ones.
function Test-BadVariant($Ctx) {
    $name = 'solution/variants/bad'
    if (-not $Ctx.Task.BadDir) { Add-Problem $name 'folder is missing'; return }
    $expected = Get-ExpectedFailures $Ctx $name
    if ($null -eq $expected) { return }

    $g = Invoke-VariantGrade $Ctx $name $Ctx.Task.BadDir
    if (-not $g.Compiled) { Add-Problem $name ((Get-GradeReasons $g) -join "`n    "); return }
    $ok = $true
    foreach ($t in @($g.Tests | Where-Object { -not $_.Passed -and -not $_.IsBudget })) {
        Add-Problem $name "test $($t.Codeunit).$($t.Name) failed (the bad variant must be functionally right): $($t.Message)"
        $ok = $false
    }
    if (-not $g.TestsPassed -and $ok) { Add-Problem $name 'functional tests did not pass'; $ok = $false }
    # A standards violation may legitimately cost SQL, so budgets are reported, not required.
    foreach ($t in @($g.Tests | Where-Object { -not $_.Passed -and $_.IsBudget })) {
        Write-Host "  note ${name}: budget $($t.Codeunit).$($t.Name) failed: $($t.Message)"
    }
    $failed = Get-FailedChecks $g
    $missing = @($expected | Where-Object { $_ -notin $failed })
    $extra = @($failed | Where-Object { $_ -notin $expected })
    if ($missing) { Add-Problem $name "expected checks did not fail: $($missing -join ', ')"; $ok = $false }
    if ($extra) { Add-Problem $name "unexpected checks failed: $($extra -join ', ')"; $ok = $false }
    if ($ok) { Write-Host "  ok   ${name}: fails exactly $($expected -join ', ')" }
}

# Optional: a functionally correct but standards-naive solution that proves the budgets can
# fail. It must compile, pass the functional tests and fail at least one Budget_ test.
function Test-BudgetProbe($Ctx) {
    $name = 'solution/variants/budget-probe'
    $dir = Join-Path $Ctx.Task.Root 'solution\variants\budget-probe'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $g = Invoke-VariantGrade $Ctx $name $dir
    if (-not $g.Compiled) { Add-Problem $name ((Get-GradeReasons $g) -join "`n    "); return }
    $ok = $true
    foreach ($t in @($g.Tests | Where-Object { -not $_.Passed -and -not $_.IsBudget })) {
        Add-Problem $name "test $($t.Codeunit).$($t.Name) failed (the budget probe must be functionally right): $($t.Message)"
        $ok = $false
    }
    if (-not $g.TestsPassed -and $ok) { Add-Problem $name 'functional tests did not pass'; $ok = $false }
    $budgetFails = @($g.Tests | Where-Object { -not $_.Passed -and $_.IsBudget })
    if ($budgetFails.Count -eq 0) { Add-Problem $name 'no Budget_ test failed; the budgets do not catch this naive solution'; return }
    if ($ok) { Write-Host "  ok   ${name}: fails budget(s) $(@($budgetFails | ForEach-Object { "$($_.Codeunit).$($_.Name)" }) -join ', ')" }
}

# The starter app of a bugfix or feature task must not already be fully right.
function Test-StarterApp($Ctx) {
    $name = 'assignment/app'
    $dir = Join-Path $Ctx.Task.AssignmentDir 'app'
    $g = Invoke-VariantGrade $Ctx $name $dir
    if ($g.FullyRight) { Add-Problem $name 'is already fully right (the task is solved before the agent starts)'; return }
    Write-Host "  ok   ${name}: not fully right ($((Get-GradeReasons $g | Select-Object -First 1)))"
}

# --- main ----------------------------------------------------------------------------------------

try {
    $cfg = if ($ConfigPath) { Get-BenchConfig -Path $ConfigPath } else { Get-BenchConfig }
}
catch {
    Write-Host "validator error: $($_.Exception.Message)"
    exit 2
}
if (-not $TasksRoot) { $TasksRoot = Join-Path $cfg.RepoRoot 'tasks' }

$taskDir = Join-Path $TasksRoot $Task
try {
    if (-not (Test-Path -LiteralPath $taskDir -PathType Container)) { throw "${Task}: task folder not found: $taskDir" }
    $benchTask = Get-BenchTask -TaskDir $taskDir
}
catch {
    Write-Host "${Task}: invalid: $($_.Exception.Message)"
    exit 1
}

$exitCode = 0
$switched = $false
try {
    # Preflight: a missing compiler or parser would otherwise show up as task failures.
    $null = Get-AlcPath $cfg
    $null = Import-AlParser -Config $cfg
    if ($SwitchDocker) { $switched = $true; Switch-DockerMode -Mode windows }
    else { Assert-DockerWindowsMode }

    $ctx = [pscustomobject]@{ Config = $cfg; Task = $benchTask }
    Write-Host "Validating $($benchTask.Id) ($($benchTask.Type)): $($benchTask.Title)"
    Test-FullyRight $ctx 'solution/app' $benchTask.SolutionAppDir
    Test-FullyRight $ctx 'solution/variants/alt' $benchTask.AltDir
    Test-BadVariant $ctx
    Test-BudgetProbe $ctx
    if ($benchTask.Type -in 'bugfix', 'feature') { Test-StarterApp $ctx }

    if ($script:Problems.Count -eq 0) {
        Write-Host "$($benchTask.Id): valid"
    }
    else {
        Write-Host "$($benchTask.Id): INVALID ($($script:Problems.Count) problem(s))"
        $exitCode = 1
    }
}
catch {
    Write-Host "validator error: $($_.Exception.Message)"
    $exitCode = 2
}
finally {
    if ($switched) {
        try { Switch-DockerMode -Mode linux }
        catch { Write-Host "validator error: switching Docker back to Linux failed: $($_.Exception.Message)"; $exitCode = 2 }
    }
}
exit $exitCode
