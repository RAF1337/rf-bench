#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Task.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Workspace.psm1') -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\tasks\TX01'

    # Config pointing TempRoot and CompilerFolder into TestDrive; RepoRoot stays the real repo.
    function New-TestConfig([string]$CompilerFolder) {
        $cfg = Get-BenchConfig
        $cfg.TempRoot = Join-Path $TestDrive 'temp\rf-bench'
        if ($PSBoundParameters.ContainsKey('CompilerFolder')) { $cfg.Bc.CompilerFolder = $CompilerFolder }
        else {
            $cf = Join-Path $TestDrive 'compiler'
            New-Item -ItemType Directory (Join-Path $cf 'symbols') -Force | Out-Null
            Set-Content (Join-Path $cf 'symbols\Microsoft_Base Application_29.0.app') 'base'
            Set-Content (Join-Path $cf 'symbols\Microsoft_System_29.0.app') 'sys'
            $cfg.Bc.CompilerFolder = $cf
        }
        $cfg
    }
    # Copy of TX01 with extra, uniquely named solution files.
    function New-TaskWithSecrets {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $t = Join-Path $dir 'TX01'
        Copy-Item $script:Fixture $t -Recurse
        New-Item -ItemType Directory (Join-Path $t 'solution\app\src'), (Join-Path $t 'solution\tests\src') -Force | Out-Null
        Set-Content (Join-Path $t 'solution\app\src\SecretFix.Codeunit.al') 'codeunit 50101 SecretFix { }'
        Set-Content (Join-Path $t 'solution\tests\src\HiddenBudgetTests.Codeunit.al') 'codeunit 70101 HiddenBudgetTests { }'
        Get-BenchTask $t
    }
    function New-ProfileDir([string]$Name, $Json, [hashtable]$Files) {
        $p = Join-Path $TestDrive "profiles\$Name"
        New-Item -ItemType Directory $p -Force | Out-Null
        if ($null -ne $Json) { ConvertTo-Json $Json -Depth 20 | Set-Content (Join-Path $p 'profile.json') }
        if ($Files) {
            foreach ($k in $Files.Keys) {
                $f = Join-Path $p $k
                New-Item -ItemType Directory (Split-Path $f) -Force | Out-Null
                Set-Content -LiteralPath $f $Files[$k]
            }
        }
        $p
    }
    function ConvertTo-PermPath([string]$Path) {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        '//' + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')
    }
}

Describe 'New-RunWorkspace' {
    It 'creates the layout under TempRoot and copies assignment and symbols' {
        $cfg = New-TestConfig
        $task = Get-BenchTask $script:Fixture
        $w = New-RunWorkspace -Config $cfg -Task $task -RunId 'r1' -Repeat 2
        $w.Root | Should -Be (Join-Path $cfg.TempRoot 'r1\TX01\2')
        $w.Ws | Should -Be (Join-Path $w.Root 'ws')
        $w.ClaudeHome | Should -Be (Join-Path $w.Root 'claude-home')
        $w.GraderDir | Should -Be (Join-Path $cfg.TempRoot 'r1\_grader\TX01\2')
        $w.GraderDir.StartsWith($w.Root, [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
        Join-Path $w.Ws 'TASK.md' | Should -Exist
        Join-Path $w.Ws 'app\app.json' | Should -Exist
        Join-Path $w.Ws 'app\src\Starter.Codeunit.al' | Should -Exist
        Join-Path $w.Ws '.alpackages\Microsoft_Base Application_29.0.app' | Should -Exist
        Join-Path $w.Ws '.alpackages\Microsoft_System_29.0.app' | Should -Exist
        @(Get-ChildItem $w.ClaudeHome -Force).Count | Should -Be 0
        @(Get-ChildItem $w.GraderDir -Force).Count | Should -Be 0
    }

    It 'never copies solution content' {
        $cfg = New-TestConfig
        $task = New-TaskWithSecrets
        $w = New-RunWorkspace -Config $cfg -Task $task -RunId 'r1' -Repeat 1

        $solNames = @(Get-ChildItem (Join-Path $task.Root 'solution') -Recurse -File -Force).Name
        $assignNames = @(Get-ChildItem $task.AssignmentDir -Recurse -File -Force).Name
        $secretNames = @($solNames | Where-Object { $_ -notin $assignNames }) + 'task.json'
        $secretNames | Should -Contain 'SecretFix.Codeunit.al'
        $secretNames | Should -Contain 'checks.json'

        $wsFiles = @(Get-ChildItem $w.Ws -Recurse -File -Force | Where-Object FullName -NotLike (Join-Path $w.Ws '.git\*'))
        foreach ($f in $wsFiles) { $f.Name | Should -Not -BeIn $secretNames }
        foreach ($f in $wsFiles) { $f.FullName | Should -Not -Match '\\solution\\' }
        # Every workspace file outside .alpackages/.git comes from assignment, byte for byte.
        foreach ($f in $wsFiles | Where-Object FullName -NotLike (Join-Path $w.Ws '.alpackages\*')) {
            $rel = [IO.Path]::GetRelativePath($w.Ws, $f.FullName)
            Join-Path $task.AssignmentDir $rel | Should -Exist
        }
        $w.Ws.StartsWith($cfg.RepoRoot, [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
        $w.Root.StartsWith($cfg.RepoRoot, [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
    }

    It 'makes the workspace a git root so ancestor discovery stops there' {
        $w = New-RunWorkspace -Config (New-TestConfig) -Task (Get-BenchTask $script:Fixture) -RunId 'r1' -Repeat 1
        Join-Path $w.Ws '.git' | Should -Exist
    }

    It 'starts clean when the repeat folder already exists' {
        $cfg = New-TestConfig
        $task = Get-BenchTask $script:Fixture
        $w = New-RunWorkspace -Config $cfg -Task $task -RunId 'r1' -Repeat 1
        Set-Content (Join-Path $w.ClaudeHome 'stale.json') '{}'
        Set-Content (Join-Path $w.Ws 'stale.txt') 'x'
        $w = New-RunWorkspace -Config $cfg -Task $task -RunId 'r1' -Repeat 1
        Join-Path $w.ClaudeHome 'stale.json' | Should -Not -Exist
        Join-Path $w.Ws 'stale.txt' | Should -Not -Exist
    }

    It 'cleans the grader folder of the repeat too' {
        $cfg = New-TestConfig
        $task = Get-BenchTask $script:Fixture
        $w = New-RunWorkspace -Config $cfg -Task $task -RunId 'r1' -Repeat 1
        Set-Content (Join-Path $w.GraderDir 'stale.app') 'x'
        $w = New-RunWorkspace -Config $cfg -Task $task -RunId 'r1' -Repeat 1
        @(Get-ChildItem $w.GraderDir -Force).Count | Should -Be 0
    }

    It 'refuses a RunId that escapes TempRoot and deletes nothing' {
        $cfg = New-TestConfig
        $escaped = [IO.Path]::GetFullPath((Join-Path $cfg.TempRoot '..\..\TX01\1'))
        New-Item -ItemType Directory $escaped -Force | Out-Null
        Set-Content (Join-Path $escaped 'keep.txt') 'keep'
        { New-RunWorkspace -Config $cfg -Task (Get-BenchTask $script:Fixture) -RunId '..\..' -Repeat 1 } |
            Should -Throw '*outside TempRoot*'
        Join-Path $escaped 'keep.txt' | Should -Exist
    }

    It 'refuses a RunId that resolves to TempRoot itself' {
        $cfg = New-TestConfig
        # TempRoot ending in TX01\1 lets RunId '..\..' resolve the repeat folder to TempRoot itself.
        $cfg.TempRoot = Join-Path $TestDrive 'base\TX01\1'
        New-Item -ItemType Directory $cfg.TempRoot -Force | Out-Null
        Set-Content (Join-Path $cfg.TempRoot 'keep.txt') 'keep'
        { New-RunWorkspace -Config $cfg -Task (Get-BenchTask $script:Fixture) -RunId '..\..' -Repeat 1 } |
            Should -Throw '*TempRoot*'
        Join-Path $cfg.TempRoot 'keep.txt' | Should -Exist
    }

    It 'throws when CompilerFolder is not set' {
        $cfg = New-TestConfig -CompilerFolder ''
        { New-RunWorkspace -Config $cfg -Task (Get-BenchTask $script:Fixture) -RunId 'r1' -Repeat 1 } |
            Should -Throw 'Bc.CompilerFolder not set; run src/Initialize-Backend.ps1'
    }

    It 'throws when the symbols folder is missing' {
        $cfg = New-TestConfig -CompilerFolder (Join-Path $TestDrive 'nocompiler')
        { New-RunWorkspace -Config $cfg -Task (Get-BenchTask $script:Fixture) -RunId 'r1' -Repeat 1 } |
            Should -Throw '*symbols*'
    }

    It 'refuses a TempRoot inside the repo' {
        $cfg = New-TestConfig
        $cfg.TempRoot = Join-Path $cfg.RepoRoot 'results\tmp'
        { New-RunWorkspace -Config $cfg -Task (Get-BenchTask $script:Fixture) -RunId 'r1' -Repeat 1 } |
            Should -Throw '*inside the repo*'
    }
}

Describe 'Get-BenchProfile' {
    It 'applies defaults for an empty profile.json' {
        $p = Get-BenchProfile (New-ProfileDir 'empty' @{ description = 'No harness' })
        $p.Name | Should -Be 'empty'
        $p.AllowWeb | Should -BeFalse
        $p.McpMode | Should -Be 'strict'
        @($p.McpServers.Keys).Count | Should -Be 0
        @($p.Plugins).Count | Should -Be 0
    }
    It 'reads all keys' {
        $dir = New-ProfileDir 'full' @{
            allowWeb   = $true
            mcpMode    = 'open'
            mcpServers = @{ bcdocs = @{ type = 'http'; url = 'https://example.com/mcp' } }
            plugins    = @(@{ name = 'al-rules'; marketplace = 'rf-market'; marketplaceSource = 'rf/market' })
        }
        $p = Get-BenchProfile $dir
        $p.AllowWeb | Should -BeTrue
        $p.McpMode | Should -Be 'open'
        $p.McpServers['bcdocs'].url | Should -Be 'https://example.com/mcp'
        $p.Plugins[0].Name | Should -Be 'al-rules'
        $p.Plugins[0].Marketplace | Should -Be 'rf-market'
        $p.Plugins[0].MarketplaceSource | Should -Be 'rf/market'
    }
    It 'rejects an unknown mcpMode' {
        { Get-BenchProfile (New-ProfileDir 'badmode' @{ mcpMode = 'loose' }) } | Should -Throw '*mcpMode*'
    }
    It 'rejects a plugin without marketplace' {
        { Get-BenchProfile (New-ProfileDir 'badplug' @{ plugins = @(@{ name = 'x' }) }) } | Should -Throw '*marketplace*'
    }
    It 'loads the baseline profile' {
        $p = Get-BenchProfile (Join-Path $PSScriptRoot '..\profiles\baseline')
        $p.Name | Should -Be 'baseline'
        $p.McpMode | Should -Be 'strict'
    }
}

Describe 'Install-Profile' {
    BeforeEach {
        $script:W = New-RunWorkspace -Config (New-TestConfig) -Task (Get-BenchTask $script:Fixture) -RunId ([guid]::NewGuid().ToString('N')) -Repeat 1
    }

    It 'copies user/ into ClaudeHome and project/ into Ws' {
        $dir = New-ProfileDir 'files' @{} @{
            'user\CLAUDE.md'            = 'user rules'
            'user\skills\x\SKILL.md'    = 'skill'
            'project\CLAUDE.md'         = 'project rules'
            'project\.claude\rules\a.md' = 'rule a'
        }
        Install-Profile (Get-BenchProfile $dir) $script:W | Out-Null
        Get-Content (Join-Path $script:W.ClaudeHome 'CLAUDE.md') | Should -Be 'user rules'
        Join-Path $script:W.ClaudeHome 'skills\x\SKILL.md' | Should -Exist
        Get-Content (Join-Path $script:W.Ws 'CLAUDE.md') | Should -Be 'project rules'
        Join-Path $script:W.Ws '.claude\rules\a.md' | Should -Exist
    }

    It 'refuses project files that overwrite task files' {
        $dir = New-ProfileDir 'clobber' @{} @{ 'project\TASK.md' = 'hijack' }
        { Install-Profile (Get-BenchProfile $dir) $script:W } | Should -Throw '*TASK.md*overwrite*'
    }

    It 'refuses a credentials file in user/' {
        $dir = New-ProfileDir 'creds' @{} @{ 'user\.credentials.json' = '{}' }
        { Install-Profile (Get-BenchProfile $dir) $script:W } | Should -Throw '*credentials*'
    }

    It 'writes mcp config' {
        $servers = [ordered]@{
            bcdocs = @{ type = 'http'; url = 'https://example.com/mcp' }
            local  = @{ command = 'node'; args = @('server.js', '--x'); env = @{ A = '1' } }
        }
        $p = Get-BenchProfile (New-ProfileDir 'mcp' @{ mcpServers = $servers })
        $r = Install-Profile $p $script:W
        $r.McpConfigPath | Should -Be (Join-Path $script:W.ClaudeHome 'rfbench-mcp.json')
        $written = Get-Content $r.McpConfigPath -Raw | ConvertFrom-Json -AsHashtable
        @($written.Keys) | Should -Be @('mcpServers')
        (ConvertTo-Json $written.mcpServers -Depth 20 -Compress) |
            Should -Be (ConvertTo-Json ($p.McpServers) -Depth 20 -Compress)
        $written.mcpServers.local.args | Should -Be @('server.js', '--x')
    }

    It 'writes an empty mcp config when the profile has no servers' {
        $r = Install-Profile (Get-BenchProfile (New-ProfileDir 'nomcp' @{})) $script:W
        (Get-Content $r.McpConfigPath -Raw | ConvertFrom-Json -AsHashtable).mcpServers.Count | Should -Be 0
        @($r.InstalledPlugins).Count | Should -Be 0
    }

    Context 'plugins' {
        BeforeEach {
            $script:Calls = [Collections.Generic.List[object]]::new()
            $script:ListJson = '[{"id":"al-rules@rf-market","version":"1.2.3","scope":"user","enabled":true},{"id":"other@rf-market","version":"0.1.0","scope":"user","enabled":true}]'
            Mock claude -ModuleName Workspace {
                $script:Calls.Add([pscustomobject]@{ Args = ($args -join ' '); ConfigDir = $env:CLAUDE_CONFIG_DIR })
                if ($args[0] -eq 'plugin' -and $args[1] -eq 'list') { $script:ListJson }
                else { 'ok' }
            }
        }

        It 'runs marketplace add and install per plugin with CLAUDE_CONFIG_DIR set' {
            $before = $env:CLAUDE_CONFIG_DIR
            $p = Get-BenchProfile (New-ProfileDir 'plug' @{ plugins = @(
                        @{ name = 'al-rules'; marketplace = 'rf-market'; marketplaceSource = 'rf/market' }
                        @{ name = 'other'; marketplace = 'rf-market'; marketplaceSource = 'rf/market' }
                    )
                })
            $r = Install-Profile $p $script:W

            $lines = @($script:Calls.Args)
            $lines | Should -Contain 'plugin marketplace add rf/market'
            $lines | Should -Contain 'plugin install al-rules@rf-market'
            $lines | Should -Contain 'plugin install other@rf-market'
            $lines.IndexOf('plugin marketplace add rf/market') | Should -BeLessThan $lines.IndexOf('plugin install al-rules@rf-market')
            # Same source added once.
            @($lines | Where-Object { $_ -eq 'plugin marketplace add rf/market' }).Count | Should -Be 1
            $lines[-1] | Should -Be 'plugin list --json'
            foreach ($c in $script:Calls) { $c.ConfigDir | Should -Be $script:W.ClaudeHome }
            $env:CLAUDE_CONFIG_DIR | Should -Be $before

            $r.InstalledPlugins.Count | Should -Be 2
            ($r.InstalledPlugins | Where-Object Name -EQ 'al-rules').Version | Should -Be '1.2.3'
            ($r.InstalledPlugins | Where-Object Name -EQ 'other').Version | Should -Be '0.1.0'
            ($r.InstalledPlugins | Where-Object Name -EQ 'al-rules').Id | Should -Be 'al-rules@rf-market'
        }

        It 'falls back to text output when list --json is not JSON' {
            $script:ListJson = @(
                'Installed plugins:', '',
                '  ❯ al-rules@rf-market', '    Version: 2.0.0', '    Scope: user', '    Status: ✔ enabled'
            )
            $p = Get-BenchProfile (New-ProfileDir 'plugtxt' @{ plugins = @(@{ name = 'al-rules'; marketplace = 'rf-market'; marketplaceSource = 'rf/market' }) })
            $r = Install-Profile $p $script:W
            $r.InstalledPlugins[0].Version | Should -Be '2.0.0'
        }

        It 'throws when a plugin is missing from the installed list' {
            $script:ListJson = '[]'
            $p = Get-BenchProfile (New-ProfileDir 'plugmiss' @{ plugins = @(@{ name = 'al-rules'; marketplace = 'rf-market'; marketplaceSource = 'rf/market' }) })
            { Install-Profile $p $script:W } | Should -Throw '*al-rules@rf-market*not installed*'
        }

        It 'throws and restores CLAUDE_CONFIG_DIR when the CLI fails' {
            $before = $env:CLAUDE_CONFIG_DIR
            Mock claude -ModuleName Workspace { $global:LASTEXITCODE = 1; 'boom' }
            $p = Get-BenchProfile (New-ProfileDir 'plugfail' @{ plugins = @(@{ name = 'al-rules'; marketplace = 'rf-market'; marketplaceSource = 'rf/market' }) })
            { Install-Profile $p $script:W } | Should -Throw '*plugin marketplace add rf/market*boom*'
            $env:CLAUDE_CONFIG_DIR | Should -Be $before
            $global:LASTEXITCODE = 0
        }
    }
}

Describe 'New-AgentSettings' {
    BeforeEach {
        $script:Cfg = New-TestConfig
        $script:W = New-RunWorkspace -Config $script:Cfg -Task (Get-BenchTask $script:Fixture) -RunId ([guid]::NewGuid().ToString('N')) -Repeat 1
        $script:RepoFwd = $script:Cfg.RepoRoot -replace '\\', '/'
        function Get-Settings { Get-Content (Join-Path $script:W.Ws '.claude\settings.json') -Raw | ConvertFrom-Json -AsHashtable }
    }

    It 'deny rules win over profile allow' {
        $projSettings = @{ permissions = @{
                allow = @("Read($script:RepoFwd/**)", "Read($(ConvertTo-PermPath $script:Cfg.RepoRoot)/tasks/**)", 'Bash(npm test)', "Bash(cat $($script:Cfg.RepoRoot)\tasks\T001\solution\x.al)", 'Bash(cat *rf-bench*-notes.txt)', 'Read(//c/**)', 'Read(**/*.al)', 'Read', 'WebFetch(domain:learn.microsoft.com)')
                deny  = @('Bash(rm -rf *)')
            }; model = 'keep-me'
        }
        $dir = New-ProfileDir 'allowrepo' @{ allowWeb = $false } @{ 'project\.claude\settings.json' = (ConvertTo-Json $projSettings -Depth 10) }
        $p = Get-BenchProfile $dir
        Install-Profile $p $script:W | Out-Null
        New-AgentSettings $script:Cfg $p $script:W | Out-Null
        $s = Get-Settings

        $s.permissions.deny | Should -Contain "Read($script:RepoFwd/**)"
        $s.permissions.deny | Should -Contain "Read($(ConvertTo-PermPath $script:Cfg.RepoRoot)/**)"
        $s.permissions.deny | Should -Contain 'Bash(rm -rf *)'
        $s.permissions.allow | Should -Not -Contain "Read($script:RepoFwd/**)"
        $s.permissions.allow | Should -Not -Contain "Read($(ConvertTo-PermPath $script:Cfg.RepoRoot)/tasks/**)"
        $s.permissions.allow | Should -Not -Contain "Bash(cat $($script:Cfg.RepoRoot)\tasks\T001\solution\x.al)"
        $s.permissions.allow | Should -Contain 'Bash(cat *rf-bench*-notes.txt)'
        $s.permissions.allow | Should -Not -Contain 'WebFetch(domain:learn.microsoft.com)'
        $s.permissions.allow | Should -Contain 'Bash(npm test)'
        $s.permissions.allow | Should -Not -Contain 'Read(//c/**)'
        $s.permissions.allow | Should -Contain 'Read(**/*.al)'
        $s.permissions.allow | Should -Contain 'Read'
        $s.model | Should -Be 'keep-me'
        # Runner rules come last.
        $s.permissions.deny[0] | Should -Be 'Bash(rm -rf *)'
    }

    It 'contains the full runner deny list' {
        $p = Get-BenchProfile (New-ProfileDir 'plain' @{})
        New-AgentSettings $script:Cfg $p $script:W | Out-Null
        $deny = (Get-Settings).permissions.deny
        $repoPerm = ConvertTo-PermPath $script:Cfg.RepoRoot
        $graderPerm = ConvertTo-PermPath $script:W.GraderDir
        foreach ($r in @(
                "Read($script:RepoFwd/**)", "Edit($script:RepoFwd/**)",
                "Read($repoPerm/**)", "Edit($repoPerm/**)",
                "Read($($script:W.GraderDir -replace '\\','/')/**)", "Read($graderPerm/**)",
                'WebFetch', 'WebSearch')) {
            $deny | Should -Contain $r
        }
        foreach ($root in $script:Cfg.RepoRoot, $script:W.GraderDir) {
            $fwd = $root -replace '\\', '/'
            foreach ($form in $root, $fwd, (ConvertTo-PermPath $root)) {
                foreach ($tool in 'Bash', 'PowerShell') { $deny | Should -Contain "$tool(*$form*)" }
            }
        }
        # Never the bare word.
        $deny | Should -Not -Contain 'Bash(*rf-bench*)'
        $deny | Should -Not -Contain 'PowerShell(*rf-bench*)'
    }

    It 'shell deny patterns hit the repo and grader but not the workspace' {
        New-AgentSettings $script:Cfg (Get-BenchProfile (New-ProfileDir 'shell' @{})) $script:W | Out-Null
        $shellSpecs = @((Get-Settings).permissions.deny | Where-Object { $_ -match '^(Bash|PowerShell)\(' } |
            ForEach-Object { $_ -replace '^(Bash|PowerShell)\((.*)\)$', '$2' })
        $shellSpecs.Count | Should -BeGreaterThan 0
        function Test-Denied([string]$Cmd) { [bool]($shellSpecs | Where-Object { $Cmd -like $_ }) }

        $ws = $script:W.Ws
        $wsFwd = $ws -replace '\\', '/'
        $wsPosix = (ConvertTo-PermPath $ws) -replace '^//', '/'
        foreach ($cmd in @(
                "& `"$ws\.alpackages\alc.exe`" /project:`"$ws\app`" /packagecachepath:`"$ws\.alpackages`"",
                "cd $wsFwd/app && ls",
                "cd $wsPosix/app && cat app.json",
                "Get-Content $ws\TASK.md",
                "Get-Content ..\ws\app\app.json",
                "cat ./app/src/Starter.Codeunit.al")) {
            Test-Denied $cmd | Should -BeFalse -Because $cmd
        }
        $repo = $script:Cfg.RepoRoot
        foreach ($cmd in @(
                "Get-Content $repo\tasks\T001\solution\app\src\Fix.al",
                "cat $($repo -replace '\\', '/')/tasks/T001/task.json",
                "ls $(ConvertTo-PermPath $repo)/tasks",
                "cat $((ConvertTo-PermPath $repo) -replace '^//', '/')/tasks/T001/task.json",
                "dir $($script:W.GraderDir)\tests",
                "Get-Content ..\grader\x",
                "cat ../grader/x",
                "Get-Content ..\..\..\_grader\TX01\1\x",
                "cat ../_grader/x")) {
            Test-Denied $cmd | Should -BeTrue -Because $cmd
        }
    }

    It 'Bash deny rules match the repo path in on-disk and lower casing, case-sensitively' {
        $cfg = New-TestConfig
        $canonical = $cfg.RepoRoot
        $cfg.RepoRoot = $canonical.ToUpperInvariant()   # wrong casing in, canonical casing out
        New-AgentSettings $cfg (Get-BenchProfile (New-ProfileDir 'case' @{})) $script:W | Out-Null
        $deny = (Get-Settings).permissions.deny
        $bash = @($deny | Where-Object { $_ -like 'Bash(*' } | ForEach-Object { $_ -replace '^Bash\((.*)\)$', '$1' })
        function Test-BashDenied([string]$Cmd) { [bool]($bash | Where-Object { $Cmd -clike $_ }) }

        $deny | Should -Contain "Read($($canonical -replace '\\', '/')/**)"
        foreach ($root in $canonical, $canonical.ToLowerInvariant()) {
            Test-BashDenied "cat $root\tasks\T001\task.json" | Should -BeTrue -Because $root
            Test-BashDenied "cat $($root -replace '\\', '/')/tasks/T001/task.json" | Should -BeTrue -Because $root
            $posix = '/' + $root.Substring(0, 1).ToLowerInvariant() + ($root.Substring(2) -replace '\\', '/')
            Test-BashDenied "cat $posix/tasks/T001/task.json" | Should -BeTrue -Because $posix
        }
        Test-BashDenied "cat $($script:W.Ws)\app\app.json" | Should -BeFalse
    }

    It 'denies web unless allowWeb' {
        $off = Get-BenchProfile (New-ProfileDir 'noweb' @{})
        New-AgentSettings $script:Cfg $off $script:W | Out-Null
        (Get-Settings).permissions.deny | Should -Contain 'WebFetch'
        (Get-Settings).permissions.deny | Should -Contain 'WebSearch'

        Remove-Item (Join-Path $script:W.Ws '.claude\settings.json')
        $on = Get-BenchProfile (New-ProfileDir 'web' @{ allowWeb = $true })
        New-AgentSettings $script:Cfg $on $script:W | Out-Null
        (Get-Settings).permissions.deny | Should -Not -Contain 'WebFetch'
        (Get-Settings).permissions.deny | Should -Not -Contain 'WebSearch'
    }

    It 'turns off claude.ai connectors in strict mode only' {
        New-AgentSettings $script:Cfg (Get-BenchProfile (New-ProfileDir 'strict' @{})) $script:W | Out-Null
        (Get-Settings).disableClaudeAiConnectors | Should -BeTrue
        Remove-Item (Join-Path $script:W.Ws '.claude\settings.json')
        New-AgentSettings $script:Cfg (Get-BenchProfile (New-ProfileDir 'open' @{ mcpMode = 'open' })) $script:W | Out-Null
        (Get-Settings).ContainsKey('disableClaudeAiConnectors') | Should -BeFalse
    }

    It 'rebuilds from the profile settings, not the workspace copy, and deletes settings.local.json' {
        $projSettings = @{ permissions = @{ allow = @('Bash(npm test)') }; model = 'from-profile' }
        $p = Get-BenchProfile (New-ProfileDir 'rebuild' @{} @{ 'project\.claude\settings.json' = (ConvertTo-Json $projSettings -Depth 10) })
        Install-Profile $p $script:W | Out-Null
        New-AgentSettings $script:Cfg $p $script:W | Out-Null
        # The agent loosens its settings through a shell between attempts.
        $path = Join-Path $script:W.Ws '.claude\settings.json'
        Set-Content $path (ConvertTo-Json @{ permissions = @{ allow = @('Bash(*)'); deny = @() }; model = 'agent-edit'; extra = 1 } -Depth 10)
        $local = Join-Path $script:W.Ws '.claude\settings.local.json'
        Set-Content $local '{"permissions":{"allow":["Read(//c/**)"]}}'

        New-AgentSettings $script:Cfg $p $script:W | Out-Null
        $s = Get-Settings
        $s.model | Should -Be 'from-profile'
        $s.ContainsKey('extra') | Should -BeFalse
        $s.permissions.allow | Should -Be @('Bash(npm test)')
        $s.permissions.deny | Should -Contain "Read($script:RepoFwd/**)"
        Test-Path $local | Should -BeFalse
    }

    It 'rebuilds from empty settings when the profile has none' {
        $p = Get-BenchProfile (New-ProfileDir 'nosettings' @{})
        $path = Join-Path $script:W.Ws '.claude\settings.json'
        New-Item -ItemType Directory (Split-Path $path) -Force | Out-Null
        Set-Content $path '{"permissions":{"allow":["Bash(*)"]},"model":"agent-edit"}'
        New-AgentSettings $script:Cfg $p $script:W | Out-Null
        $s = Get-Settings
        $s.ContainsKey('model') | Should -BeFalse
        $s.permissions.ContainsKey('allow') | Should -BeFalse
    }

    It 'excludes ancestor CLAUDE.md files and protects settings files' {
        New-AgentSettings $script:Cfg (Get-BenchProfile (New-ProfileDir 'anc' @{})) $script:W | Out-Null
        $s = Get-Settings
        $parent = (Split-Path $script:W.Ws) -replace '\\', '/'
        $s.claudeMdExcludes | Should -Contain "$parent/CLAUDE.md"
        $s.claudeMdExcludes | Should -Contain "$parent/.claude/CLAUDE.md"
        $s.claudeMdExcludes | Should -Contain "$parent/.claude/rules/**"
        ($s.claudeMdExcludes | Where-Object { $_ -like "$($script:W.Ws -replace '\\','/')/*" }) | Should -BeNullOrEmpty
        $s.permissions.deny | Should -Contain "Edit($(ConvertTo-PermPath $script:W.Ws)/.claude/settings*.json)"
    }
}

Describe 'Get-AgentEnvironment' {
    BeforeEach {
        $script:Cfg = New-TestConfig
        $script:W = New-RunWorkspace -Config $script:Cfg -Task (Get-BenchTask $script:Fixture) -RunId ([guid]::NewGuid().ToString('N')) -Repeat 1
        $script:TokVar = 'RFBENCH_TEST_TOK_' + [guid]::NewGuid().ToString('N')
        $script:KeyVar = 'RFBENCH_TEST_KEY_' + [guid]::NewGuid().ToString('N')
        $script:Cfg.Auth.TokenEnvVar = $script:TokVar
        $script:Cfg.Auth.ApiKeyEnvVar = $script:KeyVar
        [Environment]::SetEnvironmentVariable($script:TokVar, 'tok-123', 'Process')
        [Environment]::SetEnvironmentVariable($script:KeyVar, 'key-456', 'Process')
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable($script:TokVar, $null, 'Process')
        [Environment]::SetEnvironmentVariable($script:KeyVar, $null, 'Process')
    }

    It 'sets config dir, autoupdater and subscription token' {
        $e = Get-AgentEnvironment $script:Cfg (Get-BenchProfile (New-ProfileDir 'e1' @{})) $script:W
        $e.CLAUDE_CONFIG_DIR | Should -Be $script:W.ClaudeHome
        $e.DISABLE_AUTOUPDATER | Should -Be '1'
        $e.CLAUDE_CODE_OAUTH_TOKEN | Should -Be 'tok-123'
        $e.ContainsKey('ANTHROPIC_API_KEY') | Should -BeTrue
        $e.ANTHROPIC_API_KEY | Should -BeNullOrEmpty
    }

    It 'uses the API key in apiKey mode' {
        $script:Cfg.Auth.Mode = 'apiKey'
        $e = Get-AgentEnvironment $script:Cfg (Get-BenchProfile (New-ProfileDir 'e2' @{})) $script:W
        $e.ANTHROPIC_API_KEY | Should -Be 'key-456'
        $e.ContainsKey('CLAUDE_CODE_OAUTH_TOKEN') | Should -BeTrue
        $e.CLAUDE_CODE_OAUTH_TOKEN | Should -BeNullOrEmpty
    }

    It 'strict mode disables claude.ai connectors' {
        $e = Get-AgentEnvironment $script:Cfg (Get-BenchProfile (New-ProfileDir 'e3' @{})) $script:W
        $e.ENABLE_CLAUDEAI_MCP_SERVERS | Should -Be 'false'
    }

    It 'open mode does not' {
        $e = Get-AgentEnvironment $script:Cfg (Get-BenchProfile (New-ProfileDir 'e4' @{ mcpMode = 'open' })) $script:W
        $e.ContainsKey('ENABLE_CLAUDEAI_MCP_SERVERS') | Should -BeFalse
    }

    It 'throws when auth secret missing' {
        [Environment]::SetEnvironmentVariable($script:TokVar, $null, 'Process')
        { Get-AgentEnvironment $script:Cfg (Get-BenchProfile (New-ProfileDir 'e5' @{})) $script:W } |
            Should -Throw "auth: env var $($script:TokVar) is empty"
        $script:Cfg.Auth.Mode = 'apiKey'
        [Environment]::SetEnvironmentVariable($script:KeyVar, '', 'Process')
        { Get-AgentEnvironment $script:Cfg (Get-BenchProfile (New-ProfileDir 'e6' @{})) $script:W } |
            Should -Throw "auth: env var $($script:KeyVar) is empty"
    }
}
