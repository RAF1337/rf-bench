#Requires -Version 7.6
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AlParser.psm1')

$script:ReadMethods = @('Get', 'Find', 'FindFirst', 'FindLast', 'FindSet')
$script:CountMethods = @('Count', 'IsEmpty')
$script:WriteMethods = @('Insert', 'Modify', 'Delete', 'ModifyAll', 'DeleteAll')
$script:FindMinusArgs = @("'-'", "'+'", "'='")
# System fields are always loaded, whatever SetLoadFields says.
$script:SystemFields = @('SystemId', 'SystemCreatedAt', 'SystemCreatedBy', 'SystemModifiedAt', 'SystemModifiedBy', 'SystemRowVersion')

$script:CheckFunctions = [ordered]@{
    RequiresSetLoadFieldsBeforeRead = 'Test-RequiresSetLoadFieldsBeforeRead'
    ReadIsolationOnCount            = 'Test-ReadIsolationOnCount'
    NoCommitIn                      = 'Test-NoCommitIn'
    NoFindMinus                     = 'Test-NoFindMinus'
    NoCalcFieldsInLoop              = 'Test-NoCalcFieldsInLoop'
    LogicNotOnPage                  = 'Test-LogicNotOnPage'
}

function Get-AlCheckNames { @($script:CheckFunctions.Keys) }

function New-Finding($Context, [string]$Line, [bool]$Passed, [string]$Detail) {
    [pscustomobject]@{
        Check    = $Context.Check
        Category = $Context.Category
        File     = $Context.File
        Line     = [int]$Line
        Passed   = $Passed
        Detail   = $Detail
    }
}

# Reads an optional param from a CheckSpec params object or hashtable.
function Get-Param($Params, [string]$Name) {
    if ($null -eq $Params) { return $null }
    if ($Params -is [System.Collections.IDictionary]) { return $Params[$Name] }
    $p = $Params.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Field name from a SetLoadFields/CalcFields argument: `Name`, `"Name 2"` or `Rec."Name 2"`.
function ConvertTo-FieldName([string]$Arg) {
    $m = [regex]::Match($Arg.Trim(), '("(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_]*)$')
    if ($m.Success) { ConvertTo-AlName $m.Value } else { ConvertTo-AlName $Arg }
}

function Test-TableFilter($Proc, [string]$Var, $Tables) {
    if (-not $Tables) { return $true }
    $table = $Proc.RecordVars[$Var]
    foreach ($t in @($Tables)) { if ((ConvertTo-AlName $t) -ieq $table) { return $true } }
    $false
}

# Local, non-temporary record variables are the only ones these checks evaluate:
# parameters and globals can be prepared by another procedure, and temporary
# records do not touch the database.
function Test-LocalDbRecord($Proc, [string]$Var) {
    $Var -and $Proc.RecordVars.ContainsKey($Var) -and $Var -notin $Proc.ParamVars -and -not $Proc.TempVars.Contains($Var)
}

function Test-RequiresSetLoadFieldsBeforeRead($Procs, $Params, $Context) {
    $tables = Get-Param $Params 'tables'
    $coverage = [bool](Get-Param $Params 'checkFieldCoverage')
    $keyFields = @(Get-Param $Params 'keyFields' | Where-Object { $_ } | ForEach-Object { ConvertTo-AlName $_ })

    foreach ($p in $Procs) {
        $sites = @($p.Calls | Where-Object { $_.Method -in $script:ReadMethods -and (Test-LocalDbRecord $p $_.Var) -and (Test-TableFilter $p $_.Var $tables) })
        foreach ($c in $sites) {
            $slf = @($p.Calls | Where-Object { $_.Var -ieq $c.Var -and $_.Method -ieq 'SetLoadFields' -and $_.Pos -lt $c.Pos }) | Select-Object -Last 1
            if (-not $slf) {
                New-Finding $Context $c.Line $false "$($c.Var).$($c.Method) in $($p.Procedure) without an earlier $($c.Var).SetLoadFields"
                continue
            }
            New-Finding $Context $c.Line $true "$($c.Var).$($c.Method) in $($p.Procedure) follows SetLoadFields"
            if (-not $coverage) { continue }

            $varCalls = @($p.Calls | Where-Object { $_.Var -ieq $c.Var })
            $nextRead = @($varCalls | Where-Object { $_.Method -in $script:ReadMethods -and $_.Pos -gt $c.Pos } | Sort-Object Pos) | Select-Object -First 1
            $limit = if ($nextRead) { $nextRead.Pos } else { [int]::MaxValue }
            $loaded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($f in @($slf.Args) + $keyFields + $script:SystemFields) { if ($f) { [void]$loaded.Add((ConvertTo-FieldName $f)) } }
            foreach ($a in $varCalls | Where-Object { $_.Method -ieq 'AddLoadFields' -and $_.Pos -gt $slf.Pos -and $_.Pos -lt $c.Pos }) {
                foreach ($f in $a.Args) { [void]$loaded.Add((ConvertTo-FieldName $f)) }
            }
            $reads = @($p.MemberReads | Where-Object { $_.Var -ieq $c.Var -and $_.Pos -ge $c.End -and $_.Pos -lt $limit })
            foreach ($r in $reads) {
                # CalcFields/SetAutoCalcFields before the read load FlowFields explicitly.
                $calc = @($varCalls | Where-Object { $_.Method -in 'CalcFields', 'SetAutoCalcFields' -and $_.Pos -lt $r.Pos } | ForEach-Object { $_.Args } | ForEach-Object { ConvertTo-FieldName $_ })
                $ok = $loaded.Contains($r.Member) -or ($calc -contains $r.Member)
                $detail = if ($ok) { "$($c.Var).""$($r.Member)"" is loaded" } else { "$($c.Var).""$($r.Member)"" read after $($c.Var).$($c.Method) is not in SetLoadFields" }
                New-Finding $Context $r.Line $ok $detail
            }
        }
    }
}

function Test-ReadIsolationOnCount($Procs, $Params, $Context) {
    $tables = Get-Param $Params 'tables'
    foreach ($p in $Procs) {
        foreach ($c in $p.Calls | Where-Object { $_.Method -in $script:CountMethods -and (Test-LocalDbRecord $p $_.Var) -and (Test-TableFilter $p $_.Var $tables) }) {
            $set = @($p.Assigns | Where-Object { $_.Var -ieq $c.Var -and $_.Prop -ieq 'ReadIsolation' -and $_.Pos -lt $c.Pos }).Count -gt 0 -or
                @($p.Calls | Where-Object { $_.Var -ieq $c.Var -and $_.Method -ieq 'ReadIsolation' -and $_.Args.Count -gt 0 -and $_.Pos -lt $c.Pos }).Count -gt 0
            $detail = if ($set) { "$($c.Var).$($c.Method) after ReadIsolation" } else { "$($c.Var).$($c.Method) in $($p.Procedure) without an earlier $($c.Var).ReadIsolation" }
            New-Finding $Context $c.Line $set $detail
        }
    }
}

function Test-NoCommitIn($Procs, $Params, $Context) {
    $objects = @(Get-Param $Params 'objects' | Where-Object { $_ } | ForEach-Object { ConvertTo-AlName $_ })
    foreach ($p in $Procs) {
        if ($objects.Count -gt 0 -and -not ($objects | Where-Object { $_ -ieq $p.Object })) { continue }
        foreach ($c in $p.Calls | Where-Object { -not $_.Var -and $_.Method -ieq 'Commit' }) {
            New-Finding $Context $c.Line $false "Commit in $($p.Object).$($p.Procedure)"
        }
    }
}

function Test-NoFindMinus($Procs, $Params, $Context) {
    foreach ($p in $Procs) {
        foreach ($c in $p.Calls | Where-Object { $_.Var -and $_.Method -ieq 'Find' }) {
            $arg = if ($c.Args.Count -gt 0) { $c.Args[0] } else { '' }
            $bad = $arg -in $script:FindMinusArgs
            $detail = if ($bad) { "$($c.Var).Find($arg); use FindFirst/FindLast/FindSet/Get" } else { "$($c.Var).Find($arg)" }
            New-Finding $Context $c.Line (-not $bad) $detail
        }
    }
}

function Test-NoCalcFieldsInLoop($Procs, $Params, $Context) {
    foreach ($p in $Procs) {
        foreach ($c in $p.Calls | Where-Object { $_.Var -and $_.Method -ieq 'CalcFields' }) {
            $inLoop = [bool](& $p.InLoop $c.Pos)
            $detail = if ($inLoop) { "$($c.Var).CalcFields inside a loop in $($p.Procedure); use SetAutoCalcFields" } else { "$($c.Var).CalcFields outside loops" }
            New-Finding $Context $c.Line (-not $inLoop) $detail
        }
    }
}

function Test-LogicNotOnPage($Procs, $Params, $Context) {
    foreach ($p in $Procs | Where-Object { $_.ObjectType -in 'page', 'pageextension' }) {
        foreach ($c in $p.Calls | Where-Object { $_.Var -and $_.Method -in $script:WriteMethods }) {
            $v = $c.Var
            $isDbRecord = if ($v -in 'Rec', 'xRec' -and -not $p.RecordVars.ContainsKey($v)) {
                -not $p.SourceTableTemporary
            } elseif ($p.RecordVars.ContainsKey($v)) {
                -not $p.TempVars.Contains($v)
            } elseif ($p.GlobalRecordVars.ContainsKey($v)) {
                -not $p.GlobalTempVars.Contains($v)
            } else { $false }
            if ($isDbRecord) {
                New-Finding $Context $c.Line $false "$v.$($c.Method) on page $($p.Object) ($($p.Procedure)); move logic to a codeunit"
            }
        }
    }
}

function Invoke-AlChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CheckSpecs,
        [object]$Config
    )

    foreach ($spec in $CheckSpecs) {
        if (-not $script:CheckFunctions.Contains([string]$spec.check)) {
            throw "Unknown check '$($spec.check)'. Known: $((Get-AlCheckNames) -join ', ')"
        }
    }
    if (-not ('Microsoft.Dynamics.Nav.CodeAnalysis.Syntax.SyntaxTree' -as [type])) {
        if (-not $Config) {
            Import-Module (Join-Path $PSScriptRoot '..\Config.psm1')
            $Config = Get-BenchConfig
        }
        Import-AlParser -Config $Config | Out-Null
    }

    $root = (Resolve-Path -LiteralPath $SourceDir).Path
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.al' | Sort-Object FullName
    $parsed = foreach ($f in $files) {
        [pscustomobject]@{ Rel = [System.IO.Path]::GetRelativePath($root, $f.FullName); Procs = Get-AlProcedureInfo -File $f.FullName }
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in $CheckSpecs) {
        $fn = $script:CheckFunctions[[string]$spec.check]
        foreach ($file in $parsed) {
            $ctx = [pscustomobject]@{ Check = [string]$spec.check; Category = [string]$spec.category; File = $file.Rel }
            $params = Get-Param $spec 'params'
            foreach ($x in & $fn $file.Procs $params $ctx) { $findings.Add($x) }
        }
    }
    , $findings.ToArray()
}

Export-ModuleMember -Function Invoke-AlChecks, Get-AlCheckNames, Test-RequiresSetLoadFieldsBeforeRead, Test-ReadIsolationOnCount,
    Test-NoCommitIn, Test-NoFindMinus, Test-NoCalcFieldsInLoop, Test-LogicNotOnPage
