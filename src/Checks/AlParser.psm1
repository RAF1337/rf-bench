#Requires -Version 7.6
Set-StrictMode -Version Latest

$script:DllName = 'Microsoft.Dynamics.Nav.CodeAnalysis.dll'
$script:SyntaxTreeType = 'Microsoft.Dynamics.Nav.CodeAnalysis.Syntax.SyntaxTree'
$script:LoadedDll = $null

# Record methods that may be called without parentheses (`Customer.FindFirst`).
# A member access with one of these names is a call, not a field read.
$script:RecordMethods = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'AddLink', 'AddLoadFields', 'AreFieldsLoaded', 'Ascending', 'CalcFields', 'CalcSums', 'ChangeCompany',
        'ClearMarks', 'Consistent', 'Copy', 'CopyFilter', 'CopyFilters', 'CopyLinks', 'Count', 'CountApprox',
        'CurrentCompany', 'CurrentKey', 'Delete', 'DeleteAll', 'DeleteLink', 'DeleteLinks', 'FieldActive',
        'FieldCaption', 'FieldError', 'FieldName', 'FieldNo', 'FilterGroup', 'Find', 'FindFirst', 'FindLast',
        'FindSet', 'Get', 'GetAscending', 'GetBySystemId', 'GetFilter', 'GetFilters', 'GetPosition',
        'GetRangeMax', 'GetRangeMin', 'GetView', 'HasFilter', 'HasLinks', 'Init', 'Insert', 'IsDirty', 'IsEmpty',
        'IsTemporary', 'LoadFields', 'LockTable', 'Mark', 'MarkedOnly', 'Modify', 'ModifyAll', 'Next',
        'ReadConsistency', 'ReadIsolation', 'ReadPermission', 'RecordId', 'RecordLevelLocking', 'Relation',
        'Rename', 'Reset', 'SecurityFiltering', 'SetAscending', 'SetAutoCalcFields', 'SetCurrentKey',
        'SetFilter', 'SetLoadFields', 'SetPermissionFilter', 'SetPosition', 'SetRange', 'SetRecFilter',
        'SetView', 'TableCaption', 'TableName', 'TestField', 'TransferFields', 'Truncate', 'Validate',
        'WritePermission'
    ), [System.StringComparer]::OrdinalIgnoreCase)

$script:LoopTypes = @('RepeatStatementSyntax', 'ForStatementSyntax', 'WhileStatementSyntax', 'ForEachStatementSyntax')

function Test-AlParserLoaded {
    $null -ne ($script:SyntaxTreeType -as [type])
}

function Import-AlParser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [string]$ExtensionsRoot = (Join-Path $HOME '.vscode/extensions')
    )

    $searched = [System.Collections.Generic.List[string]]::new()
    $found = $null

    $configured = $Config.Paths.AlParserDll
    if ($configured) {
        # An explicit path is authoritative: never fall back to another DLL.
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            throw "AL parser DLL not found at configured path $configured"
        }
        $searched.Add($configured)
        $found = (Resolve-Path -LiteralPath $configured).Path
    }

    $compilerFolder = $Config.Bc.CompilerFolder
    if (-not $found -and $compilerFolder) {
        $searched.Add((Join-Path $compilerFolder "**\$script:DllName"))
        if (Test-Path -LiteralPath $compilerFolder -PathType Container) {
            $hit = Get-ChildItem -LiteralPath $compilerFolder -Recurse -File -Filter $script:DllName -ErrorAction SilentlyContinue |
                Sort-Object FullName | Select-Object -First 1
            if ($hit) { $found = $hit.FullName }
        }
    }

    if (-not $found) {
        $searched.Add((Join-Path $ExtensionsRoot "ms-dynamics-smb.al-*\bin\$script:DllName"))
        if (Test-Path -LiteralPath $ExtensionsRoot -PathType Container) {
            $extensions = Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Filter 'ms-dynamics-smb.al-*' -ErrorAction SilentlyContinue |
                Sort-Object -Descending -Property @{ Expression = {
                        $v = $null
                        if ([version]::TryParse(($_.Name -replace '^ms-dynamics-smb\.al-', '' -replace '[^\d.].*$', ''), [ref]$v)) { $v } else { [version]'0.0' }
                    }
                }, Name
            foreach ($ext in $extensions) {
                $candidate = Join-Path $ext.FullName "bin\$script:DllName"
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found = $candidate; break }
            }
        }
    }

    if (-not $found) {
        throw "AL parser DLL not found. Searched: $($searched -join '; ')"
    }

    # Add-Type can load the assembly only once per process; later calls reuse it.
    if (Test-AlParserLoaded) {
        if (-not $script:LoadedDll) { $script:LoadedDll = ($script:SyntaxTreeType -as [type]).Assembly.Location }
        return $script:LoadedDll
    }

    try {
        Add-Type -LiteralPath $found -ErrorAction Stop
    } catch {
        throw "AL parser DLL could not be loaded from '$found' (wrong version?): $($_.Exception.Message). Searched: $($searched -join '; ')"
    }
    $treeType = $script:SyntaxTreeType -as [type]
    $parseOk = $treeType -and @($treeType.GetMethods() | Where-Object {
            $_.Name -eq 'ParseObjectText' -and ($p = $_.GetParameters()).Count -eq 5 -and
            $p[0].ParameterType -eq [string] -and $p[2].ParameterType -eq [System.Text.Encoding]
        }).Count -gt 0
    if (-not $parseOk) {
        throw "AL parser DLL at '$found' does not expose $script:SyntaxTreeType.ParseObjectText (wrong version?). Searched: $($searched -join '; ')"
    }
    $script:LoadedDll = $found
    $found
}

function Get-AlSyntaxTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)
    if (-not (Test-AlParserLoaded)) { throw 'AL parser not loaded; call Import-AlParser first.' }
    $text = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    [Microsoft.Dynamics.Nav.CodeAnalysis.Syntax.SyntaxTree]::ParseObjectText(
        $text, $File, [System.Text.Encoding]::UTF8, $null, [System.Threading.CancellationToken]::None)
}

# Removes surrounding double quotes from an AL identifier and trims it.
function ConvertTo-AlName([string]$Text) {
    $t = "$Text".Trim()
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length - 2).Replace('""', '"') }
    $t
}

function Get-NodeTypeName($Node) { $Node.GetType().Name }

function Get-LineOf($Tree, $Node) { $Tree.GetLineSpan($Node.Span).StartLinePosition.Line + 1 }

# Adds record variables declared in (or below) $Node to $Vars / $TempVars.
function Add-RecordVars($Node, $Vars, $TempVars) {
    foreach ($d in $Node.DescendantNodesAndSelf()) {
        $typeName = Get-NodeTypeName $d
        if ($typeName -notin 'VariableDeclarationSyntax', 'VariableListDeclarationSyntax', 'ParameterSyntax') { continue }
        $type = $d.Type
        if ($null -eq $type -or (Get-NodeTypeName $type) -ne 'RecordTypeReferenceSyntax') { continue }
        $table = ConvertTo-AlName ($type.DataType.ToString() -replace '^\s*Record\s+', '')
        $isTemp = "$($type.Temporary)".Trim() -ieq 'temporary'
        $names = if ($typeName -eq 'VariableListDeclarationSyntax') { @($d.VariableNames | ForEach-Object { $_.ToString() }) } else { @($d.Name.ToString()) }
        foreach ($n in $names) {
            $name = ConvertTo-AlName $n
            $Vars[$name] = $table
            if ($isTemp) { [void]$TempVars.Add($name) }
        }
    }
}

function Get-ObjectInfo($Node) {
    $o = $Node.Parent
    while ($o -and -not ("$($o.Kind)".EndsWith('Object'))) { $o = $o.Parent }
    if (-not $o) { return $null }
    $o
}

function New-CaseInsensitiveTable { [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase) }

function Get-AlProcedureInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)

    $tree = Get-AlSyntaxTree -File $File
    $root = $tree.GetRoot()
    $result = [System.Collections.Generic.List[object]]::new()
    $objectCache = @{}

    $methods = $root.DescendantNodes() | Where-Object { (Get-NodeTypeName $_) -in 'MethodDeclarationSyntax', 'TriggerDeclarationSyntax' }
    foreach ($m in $methods) {
        $obj = Get-ObjectInfo $m
        $objKey = if ($obj) { $obj.SpanStart } else { -1 }
        if (-not $objectCache.ContainsKey($objKey)) {
            $globals = New-CaseInsensitiveTable
            $globalTemps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $sourceTemp = $false
            if ($obj) {
                foreach ($c in $obj.ChildNodes()) {
                    if ((Get-NodeTypeName $c) -eq 'GlobalVarSectionSyntax') { Add-RecordVars $c $globals $globalTemps }
                }
                foreach ($p in $obj.DescendantNodes() | Where-Object { (Get-NodeTypeName $_) -eq 'PropertySyntax' }) {
                    if ($p.Name.ToString().Trim() -ieq 'SourceTableTemporary' -and "$($p.Value)".Trim() -ieq 'true') { $sourceTemp = $true }
                }
            }
            $objectCache[$objKey] = [pscustomobject]@{
                Name                 = if ($obj) { ConvertTo-AlName $obj.Name.ToString() } else { '' }
                Type                 = if ($obj) { ("$($obj.Kind)" -replace 'Object$', '').ToLowerInvariant() } else { '' }
                GlobalRecordVars     = $globals
                GlobalTempVars       = $globalTemps
                SourceTableTemporary = $sourceTemp
            }
        }
        $o = $objectCache[$objKey]

        $vars = New-CaseInsensitiveTable
        $temps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($m.ParameterList) { Add-RecordVars $m.ParameterList $vars $temps }
        $paramVars = @($vars.Keys)
        if ($m.Variables) { Add-RecordVars $m.Variables $vars $temps }

        $name = $m.Name.ToString().Trim()
        if ((Get-NodeTypeName $m) -eq 'TriggerDeclarationSyntax' -and $m.Parent -ne $obj) {
            # Triggers on actions/fields: prefix the owning control name.
            $owner = $m.Parent
            while ($owner -and $owner -ne $obj -and -not ($owner.PSObject.Properties['Name'] -and $owner.Name)) { $owner = $owner.Parent }
            if ($owner -and $owner -ne $obj) { $name = "$(ConvertTo-AlName $owner.Name.ToString()).$name" }
        }

        $calls = [System.Collections.Generic.List[object]]::new()
        $assigns = [System.Collections.Generic.List[object]]::new()
        $reads = [System.Collections.Generic.List[object]]::new()
        $loops = [System.Collections.Generic.List[object]]::new()

        $body = $m.Body
        $bodyNodes = if ($body) { @($body.DescendantNodesAndSelf()) } else { @() }
        foreach ($n in $bodyNodes) {
            switch (Get-NodeTypeName $n) {
                'InvocationExpressionSyntax' {
                    $expr = $n.Expression
                    $argList = @(if ($n.ArgumentList) { $n.ArgumentList.Arguments | ForEach-Object { $_.ToString().Trim() } })
                    $exprType = Get-NodeTypeName $expr
                    if ($exprType -eq 'MemberAccessExpressionSyntax') {
                        $calls.Add([pscustomobject]@{ Var = ConvertTo-AlName $expr.Expression.ToString(); Method = $expr.Name.ToString().Trim(); Args = $argList; Pos = $n.SpanStart; End = $n.Span.End; Line = Get-LineOf $tree $n })
                    } elseif ($exprType -eq 'IdentifierNameSyntax') {
                        $calls.Add([pscustomobject]@{ Var = ''; Method = $expr.ToString().Trim(); Args = $argList; Pos = $n.SpanStart; End = $n.Span.End; Line = Get-LineOf $tree $n })
                    }
                }
                'ExpressionStatementSyntax' {
                    # Bare parameterless call such as `Commit;`.
                    if ((Get-NodeTypeName $n.Expression) -eq 'IdentifierNameSyntax') {
                        $calls.Add([pscustomobject]@{ Var = ''; Method = $n.Expression.ToString().Trim(); Args = @(); Pos = $n.SpanStart; End = $n.Span.End; Line = Get-LineOf $tree $n })
                    }
                }
                'MemberAccessExpressionSyntax' {
                    $parent = $n.Parent
                    $parentType = Get-NodeTypeName $parent
                    if ($parentType -eq 'InvocationExpressionSyntax' -and $parent.Expression -eq $n) { break }
                    $member = $n.Name.ToString().Trim()
                    $var = ConvertTo-AlName $n.Expression.ToString()
                    $isTarget = $parentType -in 'AssignmentStatementSyntax', 'CompoundAssignmentStatementSyntax' -and $parent.Target -eq $n
                    if ($isTarget) {
                        # `Rec.ReadIsolation := ...` or `Rec.Field := ...`.
                        $assigns.Add([pscustomobject]@{ Var = $var; Prop = $member; Pos = $n.SpanStart; Line = Get-LineOf $tree $n })
                        if ($parentType -eq 'AssignmentStatementSyntax') { break }
                    }
                    if ($script:RecordMethods.Contains($member)) {
                        # Parenless call, e.g. `if Customer.FindFirst then`.
                        if (-not $isTarget) {
                            $calls.Add([pscustomobject]@{ Var = $var; Method = $member; Args = @(); Pos = $n.SpanStart; End = $n.Span.End; Line = Get-LineOf $tree $n })
                        }
                        break
                    }
                    # `Rec."Document Type"::Order` is an enum value, not a field read.
                    if ($parentType -eq 'OptionAccessExpressionSyntax' -and $parent.Expression -eq $n) { break }
                    $reads.Add([pscustomobject]@{ Var = $var; Member = ConvertTo-AlName $member; Pos = $n.SpanStart; Line = Get-LineOf $tree $n })
                }
                default {
                    if ($_ -in $script:LoopTypes) { $loops.Add([pscustomobject]@{ Start = $n.SpanStart; End = $n.Span.End }) }
                }
            }
        }

        $loopSpans = $loops.ToArray()
        $inLoop = { param([int]$Pos) foreach ($l in $loopSpans) { if ($Pos -ge $l.Start -and $Pos -lt $l.End) { return $true } }; $false }.GetNewClosure()

        $result.Add([pscustomobject]@{
                File                 = $File
                Object               = $o.Name
                ObjectType           = $o.Type
                Procedure            = $name
                Line                 = Get-LineOf $tree $m
                RecordVars           = $vars
                TempVars             = $temps
                ParamVars            = $paramVars
                GlobalRecordVars     = $o.GlobalRecordVars
                GlobalTempVars       = $o.GlobalTempVars
                SourceTableTemporary = $o.SourceTableTemporary
                Calls                = $calls.ToArray()
                Assigns              = $assigns.ToArray()
                MemberReads          = $reads.ToArray()
                InLoop               = $inLoop
            })
    }
    , $result.ToArray()
}

Export-ModuleMember -Function Import-AlParser, Get-AlSyntaxTree, Get-AlProcedureInfo, ConvertTo-AlName
