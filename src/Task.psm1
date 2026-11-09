#Requires -Version 7.6
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Checks/Checks.psm1')
Import-Module (Join-Path $PSScriptRoot 'Results.psm1')

$script:Categories = @('data-access', 'locking-isolation', 'transactions', 'architecture', 'naming-style', 'ui', 'error-handling')
$script:Types = @('bugfix', 'feature', 'greenfield')
$script:Difficulties = @('easy', 'medium', 'hard')

function Read-TaskJson([string]$Id, [string]$Path) {
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "${Id}: invalid JSON in $Path ($($_.Exception.Message))" }
}

function Get-Prop($Obj, [string]$Name) {
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-BenchTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDir)

    $root = (Resolve-Path -LiteralPath $TaskDir -ErrorAction Stop).Path.TrimEnd('\', '/')
    $folder = Split-Path $root -Leaf

    $taskFile = Join-Path $root 'task.json'
    if (-not (Test-Path -LiteralPath $taskFile)) { throw "${folder}: missing task.json" }
    $j = Read-TaskJson $folder $taskFile

    foreach ($k in 'id', 'title', 'type', 'difficulty', 'area', 'categories') {
        if ($null -eq (Get-Prop $j $k)) { throw "${folder}: task.json missing '$k'" }
    }
    $id = [string]$j.id
    if ($id -cne $folder) { throw "${folder}: task.json id '$id' does not match folder name" }
    if ($j.type -cnotin $script:Types) { throw "${id}: invalid type '$($j.type)' (expected $($script:Types -join '|'))" }
    if ($j.difficulty -cnotin $script:Difficulties) { throw "${id}: invalid difficulty '$($j.difficulty)'" }
    $cats = @($j.categories)
    foreach ($c in $cats) {
        if ($c -cnotin $script:Categories) { throw "${id}: unknown category '$c' in task.json" }
    }
    $timeout = Get-Prop $j 'timeoutMinutes'
    if ($null -ne $timeout -and ($timeout -isnot [int] -and $timeout -isnot [long] -or $timeout -le 0)) {
        throw "${id}: timeoutMinutes must be a positive integer"
    }

    $family = Get-Prop $j 'family'
    if ($null -ne $family -and $family -isnot [string]) { throw "${id}: family must be a string" }
    $split = Get-Prop $j 'split'
    if ($null -eq $split) { $split = 'dev' }
    if ($split -isnot [string] -or $split -cnotin 'dev', 'holdout') { throw "${id}: invalid split '$split'" }

    $assign = Join-Path $root 'assignment'
    $solApp = Join-Path $root 'solution\app'
    $tests = Join-Path $root 'solution\tests'
    $checksFile = Join-Path $root 'solution\checks.json'

    $required = @(
        @((Join-Path $assign 'TASK.md'), 'assignment/TASK.md'),
        @((Join-Path $solApp 'app.json'), 'solution/app/app.json'),
        @((Join-Path $tests 'app.json'), 'solution/tests/app.json'),
        @($checksFile, 'solution/checks.json')
    )
    if ($j.type -in 'bugfix', 'feature') {
        $required += , @((Join-Path $assign 'app\app.json'), 'assignment/app/app.json')
    }
    foreach ($r in $required) {
        if (-not (Test-Path -LiteralPath $r[0] -PathType Leaf)) { throw "${id}: missing $($r[1])" }
    }
    if ($j.type -eq 'greenfield' -and (Test-Path -LiteralPath (Join-Path $assign 'app\src'))) {
        throw "${id}: greenfield task must not have assignment/app/src"
    }

    $appId = [string](Read-TaskJson $id (Join-Path $solApp 'app.json')).id
    $testAppId = [string](Read-TaskJson $id (Join-Path $tests 'app.json')).id
    if (-not $appId) { throw "${id}: solution/app/app.json has no id" }
    if (-not $testAppId) { throw "${id}: solution/tests/app.json has no id" }
    $assignAppJson = Join-Path $assign 'app\app.json'
    if (Test-Path -LiteralPath $assignAppJson) {
        $aid = [string](Read-TaskJson $id $assignAppJson).id
        if ($aid -ine $appId) { throw "${id}: assignment app id '$aid' does not match solution app id '$appId'" }
    }

    $knownChecks = Get-AlCheckNames
    $specs = @(Read-TaskJson $id $checksFile)
    foreach ($s in $specs) {
        $chk = Get-Prop $s 'check'
        $cat = Get-Prop $s 'category'
        if ($chk -notin $knownChecks) { throw "${id}: unknown check '$chk' in checks.json" }
        if ($cat -cnotin $script:Categories) { throw "${id}: unknown category '$cat' in checks.json (check '$chk')" }
    }

    $bad = Join-Path $root 'solution\variants\bad'
    $alt = Join-Path $root 'solution\variants\alt'
    [pscustomobject]@{
        Id             = $id
        Title          = [string]$j.title
        Type           = [string]$j.type
        Difficulty     = [string]$j.difficulty
        Area           = [string]$j.area
        Categories     = [string[]]$cats
        Family         = $family
        Split          = $split
        Hash           = Get-FolderHash -Path $root
        Root           = $root
        AssignmentDir  = $assign
        SolutionAppDir = $solApp
        TestsDir       = $tests
        ChecksFile     = $checksFile
        BadDir         = if (Test-Path -LiteralPath $bad -PathType Container) { $bad } else { $null }
        AltDir         = if (Test-Path -LiteralPath $alt -PathType Container) { $alt } else { $null }
        AppId          = $appId
        TestAppId      = $testAppId
        TimeoutMinutes = if ($null -ne $timeout) { [int]$timeout } else { $null }
    }
}

function Get-BenchTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TasksRoot, [string[]]$Ids)

    $dirs = @(Get-ChildItem -LiteralPath $TasksRoot -Directory | Sort-Object Name)
    if ($Ids) {
        foreach ($i in $Ids) {
            if ($i -cnotin $dirs.Name) { throw "${i}: task not found in $TasksRoot" }
        }
        $dirs = @($dirs | Where-Object { $_.Name -cin $Ids })
    }
    @($dirs | ForEach-Object { Get-BenchTask $_.FullName })
}

Export-ModuleMember -Function Get-BenchTask, Get-BenchTasks
