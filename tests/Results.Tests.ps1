#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Results.psm1') -Force
    function New-Rec {
        New-RunRecord -RunId 'r1' -Profile ([pscustomobject]@{ name = 'baseline'; hash = 'abc' }) -Model 'm' -MaxTurns 30 `
            -AuthMode 'subscription' -McpMode 'strict' -AllowedMcp @('mslearn') -InstalledPlugins @('p1') `
            -Versions ([pscustomobject]@{ cli = '2.1'; bcArtifact = 'a'; compiler = 'c'; alParserDll = 'd'; pwsh = '7.6' }) `
            -Plan @(@{ TaskId = 'T001'; Repeat = 1 }, @{ TaskId = 'T001'; Repeat = 2 }, @{ TaskId = 'T002'; Repeat = 1 })
    }
    function New-Agent($Servers = @()) {
        [pscustomobject]@{ SessionId = 's'; Status = 'ok'; Turns = 3; McpServers = @($Servers); TranscriptPath = 'x' }
    }
    function New-Grade($Tests, $Full) { [pscustomobject]@{ Compiled = $true; TestsPassed = $Tests; FullyRight = $Full } }
}

Describe 'Run record' {
    It 'has the documented shape' {
        $r = New-Rec
        $r.runId | Should -Be 'r1'
        $r.profile.hash | Should -Be 'abc'
        $r.auth.mode | Should -Be 'subscription'
        $r.mcp.mode | Should -Be 'strict'
        $r.mcp.allowed | Should -Be @('mslearn')
        $r.versions.cli | Should -Be '2.1'
        $r.tasks.Count | Should -Be 3
        $r.tasks[0].firstTestsPassAttempt | Should -BeNullOrEmpty
        $r.tasks[0].leak.leaked | Should -BeFalse
    }
    It 'round-trips through Save-RunRecord and Get-RunRecord' {
        $r = New-Rec
        Add-AttemptRecord $r -TaskId 'T001' -Repeat 1 -Agent (New-Agent @(@{ Name = 'mslearn'; Status = 'connected' })) -Grade (New-Grade $true $false) -Feedback 'fb'
        $p = Join-Path $TestDrive 'sub\run.json'
        Save-RunRecord $r $p
        $back = Get-RunRecord $p
        $back.runId | Should -Be 'r1'
        $back.tasks[0].attempts[0].feedback | Should -Be 'fb'
        $back.tasks[0].attempts[0].agent.Turns | Should -Be 3
        $back.tasks[0].firstTestsPassAttempt | Should -Be 1
        $back.tasks[0].fullyRightAttempt | Should -BeNullOrEmpty
        (Get-Content $p -Raw) | Should -Match '"fullyRightAttempt": null'
    }
    It 'tracks first tests-pass and fully-right attempts' {
        $r = New-Rec
        Add-AttemptRecord $r 'T001' 1 (New-Agent) (New-Grade $false $false) 'a'
        Add-AttemptRecord $r 'T001' 1 (New-Agent) (New-Grade $true $false) 'b'
        Add-AttemptRecord $r 'T001' 1 (New-Agent) (New-Grade $true $true) 'c'
        $t = $r.tasks[0]
        $t.attempts.Count | Should -Be 3
        $t.attempts[2].n | Should -Be 3
        $t.firstTestsPassAttempt | Should -Be 2
        $t.fullyRightAttempt | Should -Be 3
    }
    It 'computes foundByClaude as available names not in allowed' {
        $r = New-Rec
        Add-AttemptRecord $r 'T001' 1 (New-Agent @(@{ Name = 'mslearn'; Status = 'connected' }, @{ Name = 'claude.ai Gmail'; Status = 'connected' })) (New-Grade $false $false) ''
        $m = $r.tasks[0].attempts[0].mcp
        @($m.available).Count | Should -Be 2
        @($m.foundByClaude) | Should -Be @('claude.ai Gmail')
    }
    It 'records an ungraded (aborted) attempt with a null grade' {
        $r = New-Rec
        Add-AttemptRecord $r 'T001' 1 (New-Agent) $null ''
        $t = $r.tasks[0]
        $t.attempts.Count | Should -Be 1
        $t.attempts[0].grade | Should -BeNullOrEmpty
        $t.fullyRightAttempt | Should -BeNullOrEmpty
    }
    It 'throws for an unknown task entry' {
        { Add-AttemptRecord (New-Rec) 'T999' 1 (New-Agent) (New-Grade $true $true) '' } | Should -Throw '*T999*'
    }
}

Describe 'Get-PendingWork' {
    It 'returns only entries that are not done or invalid' {
        $r = New-Rec
        Set-TaskOutcome $r 'T001' 1 -Status 'done'
        Set-TaskOutcome $r 'T001' 2 -Status 'aborted'
        $p = Join-Path $TestDrive 'run.json'
        Save-RunRecord $r $p
        $w = @(Get-PendingWork $p)
        $w.Count | Should -Be 2
        ($w | ForEach-Object { "$($_.TaskId)/$($_.Repeat)" }) | Should -Be @('T001/2', 'T002/1')
        Set-TaskOutcome $r 'T002' 1 -Status 'invalid' -Leak ([pscustomobject]@{ Leaked = $true; Hits = @([pscustomobject]@{ Kind = 'repo-root' }) })
        Save-RunRecord $r $p
        @(Get-PendingWork $p).Count | Should -Be 1
        (Get-RunRecord $p).tasks[2].leak.leaked | Should -BeTrue
    }
    It 'accepts skipped and treats it as not pending' {
        $r = New-Rec
        Set-TaskOutcome $r 'T001' 1 -Status 'skipped' -AbortReason 'gold-failed'
        $r.tasks[0].status | Should -Be 'skipped'
        $r.tasks[0].abortReason | Should -Be 'gold-failed'
        $p = Join-Path $TestDrive 'run-skipped.json'
        Save-RunRecord $r $p
        ($(Get-PendingWork $p) | ForEach-Object { "$($_.TaskId)/$($_.Repeat)" }) | Should -Be @('T001/2', 'T002/1')
    }
    It 'rejects an invalid status' {
        { Set-TaskOutcome (New-Rec) 'T001' 1 -Status 'weird' } | Should -Throw
    }
}

Describe 'Get-ProfileHash' {
    BeforeEach {
        $script:d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force "$script:d\rules" | Out-Null
        Set-Content "$script:d\profile.json" '{"name":"x"}' -NoNewline
        Set-Content "$script:d\rules\a.md" 'rule a' -NoNewline
    }
    It 'is stable across calls and copies' {
        $h = Get-ProfileHash $script:d
        $h | Should -Match '^[0-9a-f]{64}$'
        Get-ProfileHash $script:d | Should -Be $h
        Copy-Item $script:d "$script:d-copy" -Recurse
        Get-ProfileHash "$script:d-copy" | Should -Be $h
    }
    It 'changes when content changes' {
        $h = Get-ProfileHash $script:d
        Set-Content "$script:d\rules\a.md" 'rule b' -NoNewline
        Get-ProfileHash $script:d | Should -Not -Be $h
    }
    It 'changes when a file is renamed or added' {
        $h = Get-ProfileHash $script:d
        Rename-Item "$script:d\rules\a.md" 'b.md'
        $h2 = Get-ProfileHash $script:d
        $h2 | Should -Not -Be $h
        Set-Content "$script:d\extra.txt" 'x'
        Get-ProfileHash $script:d | Should -Not -Be $h2
    }
}

Describe 'Get-FolderHash' {
    BeforeEach {
        $script:d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force "$script:d\a\b" | Out-Null
        Set-Content "$script:d\a\b\f.txt" 'abc' -NoNewline
        Set-Content "$script:d\g.txt" 'g' -NoNewline
    }
    It 'matches Get-ProfileHash for the same folder' {
        Get-FolderHash $script:d | Should -Be (Get-ProfileHash $script:d)
    }
    It 'changes when one byte of a nested file changes' {
        $h = Get-FolderHash $script:d
        Set-Content "$script:d\a\b\f.txt" 'abd' -NoNewline
        Get-FolderHash $script:d | Should -Not -Be $h
    }
    It 'changes when a file is renamed' {
        $h = Get-FolderHash $script:d
        Rename-Item "$script:d\g.txt" 'h.txt'
        Get-FolderHash $script:d | Should -Not -Be $h
    }
    It 'does not depend on file creation order' {
        $e = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force "$e\a\b" | Out-Null
        Set-Content "$e\g.txt" 'g' -NoNewline
        Start-Sleep -Milliseconds 20
        Set-Content "$e\a\b\f.txt" 'abc' -NoNewline
        Get-FolderHash $e | Should -Be (Get-FolderHash $script:d)
    }
}

Describe 'Get-McpServerHash' {
    It 'hashes command, args and url as compact JSON, ignoring env and other keys' {
        $a = [pscustomobject]@{ command = 'npx'; args = @('-y', 'srv'); env = [pscustomobject]@{ TOKEN = 'one' }; type = 'stdio' }
        $b = [pscustomobject]@{ command = 'npx'; args = @('-y', 'srv'); env = [pscustomobject]@{ TOKEN = 'two' } }
        $h = Get-McpServerHash $a
        $h | Should -Match '^[0-9a-f]{64}$'
        Get-McpServerHash $b | Should -Be $h
        $json = '{"command":"npx","args":["-y","srv"],"url":null}'
        $expected = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))) -replace '-', '').ToLowerInvariant()
        $h | Should -Be $expected
    }
    It 'changes when args or url change' {
        $a = Get-McpServerHash ([pscustomobject]@{ command = 'npx'; args = @('-y', 'srv@1') })
        Get-McpServerHash ([pscustomobject]@{ command = 'npx'; args = @('-y', 'srv@2') }) | Should -Not -Be $a
        $u1 = Get-McpServerHash ([pscustomobject]@{ type = 'http'; url = 'https://a' })
        Get-McpServerHash ([pscustomobject]@{ type = 'http'; url = 'https://b' }) | Should -Not -Be $u1
    }
}

Describe 'Get-ManagedSettingsHash' {
    It 'returns the SHA256 of the managed settings file' {
        $p = Join-Path $TestDrive 'managed-settings.json'
        Set-Content -LiteralPath $p '{"permissions":{}}' -NoNewline
        Get-ManagedSettingsHash -Path $p | Should -Be (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'returns null when there is no managed settings file' {
        Get-ManagedSettingsHash -Path (Join-Path $TestDrive 'none.json') | Should -BeNullOrEmpty
    }
    It 'defaults to the Windows managed settings location' {
        InModuleScope Results { $script:ManagedSettingsPath } | Should -Be (Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json')
    }
}
