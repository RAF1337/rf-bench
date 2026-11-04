#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\LeakScan.psm1') -Force
    $script:Repo = 'C:\GeneralDev\AL\rf-bench'
    $script:Cfg = [pscustomobject]@{ RepoRoot = $script:Repo; TempRoot = 'C:\Temp\rf-bench' }
    $script:Grader = 'C:\Temp\rf-bench\run1\_grader\T001\1'

    $testsDir = Join-Path $TestDrive 'tests'
    New-Item -ItemType Directory -Force (Join-Path $testsDir 'sub') | Out-Null
    Set-Content (Join-Path $testsDir 'sub\Foo.Codeunit.al') @('codeunit 50100 "Secret Invoice Tests"', '{', '}', 'codeunit 50101 PlainNamed', '{')
    $script:Task = [pscustomobject]@{ Id = 'T001'; TestsDir = $testsDir }

    function New-Transcript([object[]]$Events) {
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.jsonl')
        Set-Content $p ($Events | ForEach-Object { ConvertTo-Json $_ -Depth 20 -Compress }) -Encoding utf8NoBOM
        $p
    }
    function Use-Tool($Name, $InputObj) {
        @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'tu1'; name = $Name; input = $InputObj }) } }
    }
    function Tool-Result($Text) {
        @{ type = 'user'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tu1'; content = $Text }) } }
    }
}

Describe 'Test-TranscriptLeak' {
    It 'flags shell read of repo' {
        $t = New-Transcript @(Use-Tool 'PowerShell' @{ command = 'Get-Content C:\GeneralDev\al\rf-bench\tasks\T001\solution\tests\Foo.Codeunit.al' })
        $r = Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader
        $r.Leaked | Should -BeTrue
        $r.Hits.Kind | Should -Contain 'repo-root'
    }
    It 'ignores repo path in the prompt text' {
        $t = New-Transcript @(
            @{ type = 'user'; message = @{ role = 'user'; content = 'Work in C:\GeneralDev\AL\rf-bench\tasks\T001\solution\ please' } },
            @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'See /c/GeneralDev/AL/rf-bench' }) } },
            (Use-Tool 'Bash' @{ command = 'ls app' }))
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Leaked | Should -BeFalse
    }
    It 'flags test codeunit name in tool output' {
        $t = New-Transcript @((Use-Tool 'Bash' @{ command = 'ls' }), (Tool-Result 'found: secret invoice TESTS here'))
        $r = Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader
        $r.Leaked | Should -BeTrue
        $r.Hits[0].Kind | Should -Be 'test-codeunit'
        $r.Hits[0].Source | Should -Be 'tool_result'
    }
    It 'flags unquoted codeunit name inside array-form tool_result content' {
        $t = New-Transcript @(Tool-Result @(@{ type = 'text'; text = 'x PlainNamed y' }))
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Leaked | Should -BeTrue
    }
    It 'flags <form> path form' -ForEach @(
        @{ form = 'forward slash'; cmd = 'cat C:/generaldev/al/rf-bench/README.md' }
        @{ form = 'git bash'; cmd = 'cat /c/GeneralDev/AL/rf-bench/README.md' }
        @{ form = 'double slash'; cmd = 'cat //c/GeneralDev/AL/rf-bench/README.md' }
        @{ form = 'escaped backslash'; cmd = 'cat C:\\GeneralDev\\AL\\rf-bench\\README.md' }
    ) {
        $t = New-Transcript @(Use-Tool 'Bash' @{ command = $cmd })
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Hits.Kind | Should -Contain 'repo-root'
    }
    It 'flags grader dir and run-level _grader folder' {
        $t = New-Transcript @(Use-Tool 'Bash' @{ command = 'ls /c/Temp/rf-bench/run1/_grader/T002' })
        $r = Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader
        $r.Hits.Kind | Should -Contain 'grader-root'
        $r.Hits.Kind | Should -Not -Contain 'grader-dir'
        $t2 = New-Transcript @(Use-Tool 'Bash' @{ command = 'ls C:\Temp\rf-bench\run1\_grader\T001\1\out' })
        (Test-TranscriptLeak $t2 $script:Cfg $script:Task $script:Grader).Hits.Kind | Should -Contain 'grader-dir'
    }
    It 'flags a solution folder reference' {
        $t = New-Transcript @(Use-Tool 'Read' @{ file_path = 'D:\other\Solution\x.al' })
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Hits.Kind | Should -Contain 'solution-folder'
    }
    It 'does not flag the agent workspace' {
        $t = New-Transcript @((Use-Tool 'Read' @{ file_path = 'C:\Temp\rf-bench\run1\T001\1\ws\app\src\X.al' }), (Tool-Result 'table 50100 Foo'))
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Leaked | Should -BeFalse
    }
    It 'fails closed on unparseable lines' {
        $p = Join-Path $TestDrive 'bad.jsonl'
        Set-Content $p @('not json', '{"type":"assistant"}', '')
        $r = Test-TranscriptLeak $p $script:Cfg $script:Task $script:Grader
        $r.ParseErrors | Should -Be 1
        $r.Leaked | Should -BeTrue
        $r.Hits.Pattern | Should -Contain 'unparseable-transcript'
    }
    It 'reports zero ParseErrors for a clean transcript' {
        $t = New-Transcript @((Use-Tool 'Bash' @{ command = 'ls' }))
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).ParseErrors | Should -Be 0
    }
    It 'throws when the task has no test codeunit names' {
        $empty = Join-Path $TestDrive 'emptytests'; New-Item -ItemType Directory -Force $empty | Out-Null
        $t = New-Transcript @((Use-Tool 'Bash' @{ command = 'ls' }))
        { Test-TranscriptLeak $t $script:Cfg ([pscustomobject]@{ Id = 'T009'; TestsDir = $empty }) $script:Grader } | Should -Throw 'T009: no test codeunit names found in*'
        { Test-TranscriptLeak $t $script:Cfg ([pscustomobject]@{ Id = 'T009'; TestsDir = (Join-Path $TestDrive 'nope') }) $script:Grader } | Should -Throw '*T009*'
    }
    It 'flags bare _grader segment (<name>)' -ForEach @(
        @{ name = 'relative'; cmd = 'cat ..\..\..\_grader\x\out.txt' }
        @{ name = 'env var'; cmd = 'ls $env:TEMP\rf-bench\r\_grader' }
        @{ name = 'casing'; cmd = 'ls /tmp/_GRADER/x' }
    ) {
        $t = New-Transcript @(Use-Tool 'PowerShell' @{ command = $cmd })
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Hits.Kind | Should -Contain 'grader-segment'
    }
    It 'flags /mnt/c form of the grader dir' {
        $t = New-Transcript @(Use-Tool 'Bash' @{ command = 'ls /mnt/c/Temp/rf-bench/run1/_grader/T001/1' })
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Hits.Kind | Should -Contain 'grader-dir'
    }
    It 'does not flag _grader embedded in a longer name' {
        $t = New-Transcript @(Use-Tool 'Bash' @{ command = 'ls my_grader_notes' })
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Leaked | Should -BeFalse
    }
    It 'takes the excerpt from the original text' {
        $t = New-Transcript @(Use-Tool 'Bash' @{ command = 'cat C:\\GeneralDev\\AL\\rf-bench\\README.md' })
        (Test-TranscriptLeak $t $script:Cfg $script:Task $script:Grader).Hits[0].Excerpt | Should -BeLike 'cat C:\\GeneralDev\\AL*'
    }
}

