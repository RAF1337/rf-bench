#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Checks\AlParser.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Checks\Checks.psm1') -Force

    $script:GoodDir = Join-Path $PSScriptRoot 'fixtures\al\good'
    $script:BadDir = Join-Path $PSScriptRoot 'fixtures\al\bad'
    Import-AlParser -Config (Get-BenchConfig) | Out-Null

    function New-Spec([string]$Check, [string]$Category = 'data-access', [hashtable]$Params = @{}) {
        [pscustomobject]@{ check = $Check; category = $Category; params = [pscustomobject]$Params }
    }
    # Returns "File:Line" strings for the failing findings of one check.
    function Get-FailedSites([object[]]$Findings, [string]$Check) {
        @($Findings | Where-Object { $_.Check -eq $Check -and -not $_.Passed } |
            ForEach-Object { '{0}:{1}' -f $_.File, $_.Line } | Sort-Object)
    }
    function Assert-AllPassed([object[]]$Findings) {
        foreach ($f in $Findings) {
            $f.Passed | Should -BeTrue -Because "$($f.Check) at $($f.File):$($f.Line) ($($f.Detail))"
        }
    }

    $script:CoverageParams = @{ checkFieldCoverage = $true; keyFields = @('No.') }
    $script:AllSpecs = @(
        New-Spec 'RequiresSetLoadFieldsBeforeRead' 'data-access' $script:CoverageParams
        New-Spec 'ReadIsolationOnCount' 'locking-isolation'
        New-Spec 'NoCommitIn' 'transactions'
        New-Spec 'NoFindMinus' 'data-access'
        New-Spec 'NoCalcFieldsInLoop' 'data-access'
        New-Spec 'LogicNotOnPage' 'architecture'
    )
}

Describe 'Import-AlParser' {
    It 'returns the loaded DLL path' {
        $p = Import-AlParser -Config (Get-BenchConfig)
        $p | Should -Exist
        (Split-Path $p -Leaf) | Should -Be 'Microsoft.Dynamics.Nav.CodeAnalysis.dll'
    }
    It 'is idempotent' {
        $a = Import-AlParser -Config (Get-BenchConfig)
        $b = Import-AlParser -Config (Get-BenchConfig)
        $b | Should -Be $a
    }
    It 'throws with searched paths when DLL missing' {
        $empty = Join-Path $TestDrive 'no-extensions'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $compiler = Join-Path $TestDrive 'missing-compiler'
        $cfg = [pscustomobject]@{
            Paths = [pscustomobject]@{ AlParserDll = '' }
            Bc    = [pscustomobject]@{ CompilerFolder = $compiler }
        }
        { Import-AlParser -Config $cfg -ExtensionsRoot $empty } | Should -Throw '*Searched:*'
        { Import-AlParser -Config $cfg -ExtensionsRoot $empty } | Should -Throw "*$compiler*"
        { Import-AlParser -Config $cfg -ExtensionsRoot $empty } | Should -Throw "*$empty*"
    }
    It 'throws when the configured DLL path does not exist or is a directory' {
        $bogus = Join-Path $TestDrive 'missing\Microsoft.Dynamics.Nav.CodeAnalysis.dll'
        $cfg = [pscustomobject]@{
            Paths = [pscustomobject]@{ AlParserDll = $bogus }
            Bc    = [pscustomobject]@{ CompilerFolder = '' }
        }
        # No fallthrough to the extension search, even though a DLL exists there.
        { Import-AlParser -Config $cfg } | Should -Throw "AL parser DLL not found at configured path $bogus"
        $cfg.Paths.AlParserDll = $TestDrive
        { Import-AlParser -Config $cfg } | Should -Throw "AL parser DLL not found at configured path $TestDrive"
    }
}

Describe 'Get-AlProcedureInfo' {
    BeforeAll {
        $script:Info = Get-AlProcedureInfo -File (Join-Path $script:BadDir 'Bad.Codeunit.al')
    }
    It 'returns one entry per procedure with object data' {
        $script:Info.Count | Should -Be 9
        $script:Info[0].Object | Should -Be 'Bad Codeunit'
        $script:Info[0].ObjectType | Should -Be 'codeunit'
        $script:Info[0].Procedure | Should -Be 'NoLoadFields'
    }
    It 'reads list declarations as record vars' {
        $p = $script:Info | Where-Object Procedure -EQ 'ListDeclared'
        $p.RecordVars['First'] | Should -Be 'Customer'
        $p.RecordVars['Second'] | Should -Be 'Customer'
    }
    It 'reports calls with var, method, args and line' {
        $p = $script:Info | Where-Object Procedure -EQ 'MultiLineRead'
        $c = $p.Calls | Where-Object Method -EQ 'Get'
        $c.Var | Should -Be 'Customer'
        $c.Args | Should -Be @('CustomerNo')
        $c.Line | Should -Be 61
    }
    It 'reports member assignments and loop membership' {
        $good = Get-AlProcedureInfo -File (Join-Path $script:GoodDir 'Good.Codeunit.al')
        $p = $good | Where-Object Procedure -EQ 'CountWithIsolation'
        ($p.Assigns | Where-Object Prop -EQ 'ReadIsolation').Var | Should -Be 'SalesLine'
        $loop = $good | Where-Object Procedure -EQ 'CalcAfterLoop'
        $inside = $loop.Calls | Where-Object Method -EQ 'Add'
        $after = $loop.Calls | Where-Object Method -EQ 'CalcFields'
        & $loop.InLoop $inside.Pos | Should -BeTrue
        & $loop.InLoop $after.Pos | Should -BeFalse
    }
    It 'names page triggers' {
        $p = Get-AlProcedureInfo -File (Join-Path $script:BadDir 'BadCustomer.Page.al')
        $p.ObjectType | Should -Be 'page'
        $p.Procedure | Should -Be 'Rename.OnAction'
    }
}

Describe 'Invoke-AlChecks' {
    It 'passes every finding on good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs $script:AllSpecs
        @($f).Count | Should -BeGreaterThan 10
        Assert-AllPassed $f
    }
    It 'ignores comments and strings' {
        $commentOrString = @{
            'Bad.Codeunit.al'         = 8, 18, 19, 20, 30, 31, 69
            'BadCustomer.Page.al'     = @(22)
            'BadExtra.Codeunit.al'    = @(9)
            'Good.Codeunit.al'        = 46, 47, 48
            'GoodGlobals.Codeunit.al' = 24, 30
            'GoodCustomer.Page.al'    = 26, 27
        }
        $f = @(Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs $script:AllSpecs) +
            @(Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs $script:AllSpecs)
        foreach ($x in $f) {
            if ($commentOrString.ContainsKey($x.File)) {
                $commentOrString[$x.File] | Should -Not -Contain $x.Line -Because "$($x.Check) at $($x.File):$($x.Line)"
            }
        }
    }
    It 'fills Finding fields' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoFindMinus' 'data-access')
        $x = $f | Where-Object { -not $_.Passed }
        $x.Check | Should -Be 'NoFindMinus'
        $x.Category | Should -Be 'data-access'
        $x.File | Should -Be 'Bad.Codeunit.al'
        $x.Line | Should -Be 78
        $x.Detail | Should -Not -BeNullOrEmpty
    }
    It 'throws on an unknown check' {
        { Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoSuchCheck') } | Should -Throw '*NoSuchCheck*'
    }
}

Describe 'RequiresSetLoadFieldsBeforeRead' {
    It 'passes good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs @(New-Spec 'RequiresSetLoadFieldsBeforeRead')
        # 8 read sites in Good.Codeunit.al (incl. a global) + 1 global in GoodGlobals.Codeunit.al.
        @($f).Count | Should -Be 9
        Assert-AllPassed $f
    }
    It 'fails reads without earlier SetLoadFields on the same var' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'RequiresSetLoadFieldsBeforeRead')
        Get-FailedSites $f 'RequiresSetLoadFieldsBeforeRead' |
            Should -Be (@('Bad.Codeunit.al:10', 'Bad.Codeunit.al:21', 'Bad.Codeunit.al:52', 'Bad.Codeunit.al:61',
                    'BadExtra.Codeunit.al:16', 'BadExtra.Codeunit.al:30') | Sort-Object)
        @($f | Where-Object Passed).Count | Should -Be 4
    }
    It 'fails an uncovered field read with checkFieldCoverage' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'RequiresSetLoadFieldsBeforeRead' 'data-access' $script:CoverageParams)
        Get-FailedSites $f 'RequiresSetLoadFieldsBeforeRead' |
            Should -Be (@('Bad.Codeunit.al:10', 'Bad.Codeunit.al:21', 'Bad.Codeunit.al:43', 'Bad.Codeunit.al:52', 'Bad.Codeunit.al:61',
                    'BadExtra.Codeunit.al:16', 'BadExtra.Codeunit.al:30') | Sort-Object)
    }
    It 'restricts to listed tables' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'RequiresSetLoadFieldsBeforeRead' 'data-access' @{ tables = @('Sales Line') })
        @($f).Count | Should -Be 0
    }
}

Describe 'ReadIsolationOnCount' {
    It 'passes good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs @(New-Spec 'ReadIsolationOnCount' 'locking-isolation')
        # IsEmpty + Count in Good.Codeunit.al, global Count in GoodGlobals.Codeunit.al.
        @($f).Count | Should -Be 3
        Assert-AllPassed $f
    }
    It 'fails Count without ReadIsolation' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'ReadIsolationOnCount' 'locking-isolation')
        Get-FailedSites $f 'ReadIsolationOnCount' | Should -Be (@('Bad.Codeunit.al:33', 'BadExtra.Codeunit.al:22') | Sort-Object)
        @($f).Count | Should -Be 2
    }
    It 'restricts to listed tables' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'ReadIsolationOnCount' 'locking-isolation' @{ tables = @('Customer') })
        @($f).Count | Should -Be 0
    }
}

Describe 'NoCommitIn' {
    It 'passes good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs @(New-Spec 'NoCommitIn' 'transactions')
        # Commit only appears in comments and strings there: no sites at all.
        @($f).Count | Should -Be 0
    }
    It 'fails Commit in any object when no objects listed' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoCommitIn' 'transactions')
        Get-FailedSites $f 'NoCommitIn' | Should -Be @('Bad.Codeunit.al:70')
    }
    It 'fails Commit only in listed objects' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoCommitIn' 'transactions' @{ objects = @('bad codeunit') })
        Get-FailedSites $f 'NoCommitIn' | Should -Be @('Bad.Codeunit.al:70')
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoCommitIn' 'transactions' @{ objects = @('Other Codeunit') })
        @($f).Count | Should -Be 0
    }
}

Describe 'NoFindMinus' {
    It 'passes good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs @(New-Spec 'NoFindMinus')
        @($f).Count | Should -Be 2
        Assert-AllPassed $f
    }
    It 'fails Find with -, + or =' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoFindMinus')
        Get-FailedSites $f 'NoFindMinus' | Should -Be @('Bad.Codeunit.al:78')
    }
}

Describe 'NoCalcFieldsInLoop' {
    It 'passes good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs @(New-Spec 'NoCalcFieldsInLoop')
        @($f).Count | Should -Be 1
        Assert-AllPassed $f
    }
    It 'fails CalcFields inside a repeat loop' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'NoCalcFieldsInLoop')
        Get-FailedSites $f 'NoCalcFieldsInLoop' | Should -Be @('Bad.Codeunit.al:90')
    }
}

Describe 'LogicNotOnPage' {
    It 'passes good fixtures' {
        $f = Invoke-AlChecks -SourceDir $script:GoodDir -CheckSpecs @(New-Spec 'LogicNotOnPage' 'architecture')
        # Writes there target temporary records, non-records or a codeunit: no sites at all.
        @($f).Count | Should -Be 0
    }
    It 'fails Modify in a page action trigger' {
        $f = Invoke-AlChecks -SourceDir $script:BadDir -CheckSpecs @(New-Spec 'LogicNotOnPage' 'architecture')
        Get-FailedSites $f 'LogicNotOnPage' | Should -Be @('BadCustomer.Page.al:24')
    }
}
