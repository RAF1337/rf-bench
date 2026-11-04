#Requires -Version 7.6
# Integration-style test of the grade -> feedback -> leak scan chain. Invoke-Grade,
# New-AttemptFeedback, Test-TranscriptLeak and the standards checks run for real; only the
# BcContainerHelper side of Backend.Docker is mocked (inside the Backend.Docker module).
BeforeAll {
    $src = Join-Path $PSScriptRoot '..\src'
    foreach ($m in 'Config', 'Task', 'Backend.Docker', 'Grader', 'Feedback', 'LeakScan') {
        Import-Module (Join-Path $src "$m.psm1") -Force
    }

    # Global stubs so Pester can mock the BcContainerHelper commands when the module is not loaded.
    $script:Stubs = @{
        'Compile-AppWithBcCompilerFolder' = 'param([string]$compilerFolder, [string]$appProjectFolder, [string]$appOutputFolder, [string]$appSymbolsFolder, [string]$appName, [switch]$EnableCodeCop, [switch]$EnableUICop, [switch]$EnablePerTenantExtensionCop, [switch]$AzureDevOps, [switch]$gitHubActions, [string[]]$treatWarningsAsErrors, [scriptblock]$outputTo)'
        'Publish-BcContainerApp'          = 'param([string]$containerName, $appFile, [switch]$skipVerification, [switch]$sync, [switch]$install)'
        'Get-BcContainerAppInfo'          = 'param([string]$containerName, [switch]$tenantSpecificProperties)'
        'UnPublish-BcContainerApp'        = 'param([string]$containerName, [string]$name, [string]$publisher, [string]$version, [switch]$unInstall, [switch]$doNotSaveData, [switch]$doNotSaveSchema, [switch]$force)'
        'Run-TestsInBcContainer'          = 'param([string]$containerName, [pscredential]$credential, [string]$extensionId, [string]$XUnitResultFileName, [switch]$detailed)'
    }
    $script:Defined = @()
    $helperLoaded = [bool](Get-Module BcContainerHelper)
    foreach ($name in $script:Stubs.Keys) {
        if (-not $helperLoaded -and -not (Test-Path "function:$name")) {
            Set-Item "function:global:$name" ([scriptblock]::Create("$($script:Stubs[$name]) throw 'stub $name called unmocked'"))
            $script:Defined += $name
        }
    }
    $env:RFBENCH_TEST_BC_PASSWORD = 'P@ssw0rd!'

    # Task copy with real hidden test source (codeunit 70100 "TX Feature Tests").
    $script:TaskDir = Join-Path $TestDrive 'tasks\TX01'
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\tasks\TX01') $script:TaskDir -Recurse
    New-Item -ItemType Directory (Join-Path $script:TaskDir 'solution\tests\src') -Force | Out-Null
    $script:HiddenSource = @'
codeunit 70100 "TX Feature Tests"
{
    Subtype = Test;

    [Test]
    procedure RejectsBlockedCustomer()
    begin
    end;
}
'@
    Set-Content (Join-Path $script:TaskDir 'solution\tests\src\TXFeatureTests.Codeunit.al') $script:HiddenSource
    $script:Task = Get-BenchTask $script:TaskDir

    $script:Config = Get-BenchConfig
    $script:Config.Bc.Credential.PasswordEnvVar = 'RFBENCH_TEST_BC_PASSWORD'
    $script:Sample = Join-Path $PSScriptRoot 'fixtures\xunit\sample.xml'

    function New-Transcript([object[]]$Events) {
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.jsonl')
        Set-Content $p ($Events | ForEach-Object { ConvertTo-Json $_ -Depth 20 -Compress }) -Encoding utf8NoBOM
        $p
    }
    function Use-Tool($Id, $Name, $InputObj) {
        @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = $Id; name = $Name; input = $InputObj }) } }
    }
    function Tool-Result($Id, $Text) {
        @{ type = 'user'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = $Id; content = $Text }) } }
    }
}

AfterAll {
    foreach ($name in $script:Defined) { Remove-Item "function:global:$name" -ErrorAction Ignore }
    Remove-Item Env:RFBENCH_TEST_BC_PASSWORD -ErrorAction Ignore
}

Describe 'Grade -> feedback -> leak scan chain' {
    It 'grades with noisy backend output, hands test names to the agent, and only flags real leaks' {
        $xmlPath = Join-Path $TestDrive 'xunit-chain.xml'
        Mock -ModuleName Backend.Docker Import-BcContainerHelper { }
        Mock -ModuleName Backend.Docker Get-XUnitResultPath { $xmlPath }
        Mock -ModuleName Backend.Docker Compile-AppWithBcCompilerFolder {
            New-Item -ItemType Directory $appOutputFolder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $appOutputFolder $appName) 'app'
            & $outputTo 'Compilation started'
            [pscustomobject]@{ Noise = 'compile' }
        }
        # BcContainerHelper commands that write objects to the pipeline (finding #2).
        Mock -ModuleName Backend.Docker Publish-BcContainerApp { [pscustomobject]@{ Noise = 'publish' }; 'Publishing done' }
        Mock -ModuleName Backend.Docker Get-BcContainerAppInfo {
            [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; Name = 'TX01 App'; Publisher = 'rf'; Version = '1.0.0.0'; IsInstalled = $true }
        }
        Mock -ModuleName Backend.Docker UnPublish-BcContainerApp { 'Unpublished' }
        Mock -ModuleName Backend.Docker Run-TestsInBcContainer { Copy-Item $script:Sample $XUnitResultFileName; $true; 'Tests done' }

        $agentApp = Join-Path $TestDrive 'ws\app'
        Copy-Item (Join-Path $script:Task.AssignmentDir 'app') $agentApp -Recurse
        $grader = Join-Path $TestDrive 'run1\_grader\TX01\1'

        $grade = Invoke-Grade -Config $script:Config -Task $script:Task -AgentAppDir $agentApp -GraderDir $grader -Attempt 1

        # The grade result is one object with the documented shape.
        @($grade).Count | Should -Be 1
        $grade.Compiled | Should -BeTrue
        @($grade.Tests).Count | Should -Be 3
        @($grade.Tests | Where-Object { $_ -isnot [pscustomobject] -or -not $_.PSObject.Properties['IsBudget'] }).Count | Should -Be 0
        $grade.TestsPassed | Should -BeFalse
        $grade.FullyRight | Should -BeFalse
        Test-Path (Join-Path $grader 'attempt1\tests') | Should -BeFalse

        $feedback = New-AttemptFeedback $grade
        $feedback | Should -Match 'Failing tests:'
        $feedback | Should -Match '70100 TX Feature Tests::RejectsBlockedCustomer'

        # Attempt 2: the agent searches its own app for the test name from the feedback.
        $clean = New-Transcript @(
            (Use-Tool 'tu1' 'Grep' @{ pattern = 'TX Feature Tests'; path = 'app' }),
            (Tool-Result 'tu1' 'No matches found'),
            (Use-Tool 'tu2' 'Bash' @{ command = 'grep -rn "RejectsBlockedCustomer\|TX Feature Tests" app' }),
            (Tool-Result 'tu2' ''))
        $scan = Test-TranscriptLeak -TranscriptPath $clean -Config $script:Config -Task $script:Task -GraderDir $grader
        $scan.Leaked | Should -BeFalse

        # A tool result that returns the hidden test source is a leak.
        $leak = New-Transcript @(
            (Use-Tool 'tu1' 'PowerShell' @{ command = 'Get-Content $env:TEMP\x\TXFeatureTests.Codeunit.al' }),
            (Tool-Result 'tu1' $script:HiddenSource))
        $scan2 = Test-TranscriptLeak -TranscriptPath $leak -Config $script:Config -Task $script:Task -GraderDir $grader
        $scan2.Leaked | Should -BeTrue
        $scan2.Hits.Kind | Should -Contain 'test-codeunit'
    }
}
