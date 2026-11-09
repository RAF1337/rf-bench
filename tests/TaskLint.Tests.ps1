#Requires -Version 7.6
# Every shipped task's hidden tests must lint clean.
BeforeDiscovery {
    $script:TaskCases = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\tasks') -Directory |
        ForEach-Object { @{ Id = $_.Name; TestsDir = (Join-Path $_.FullName 'solution\tests') } })
}
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\src\TestLint.psm1') -Force }

Describe 'task test lint' {
    It '<Id> hidden tests lint clean' -ForEach $script:TaskCases {
        $f = @(Get-TestLintFindings -TestsDir $TestsDir)
        ($f | ForEach-Object { "$($_.File):$($_.Line) $($_.Rule) $($_.Detail)" }) | Should -BeNullOrEmpty
    }
}
