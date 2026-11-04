#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Agent.psm1') -Force
    $script:StreamDir = Join-Path $PSScriptRoot 'fixtures\stream'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

    # Writes a line-per-event JSONL file into TestDrive and returns its path.
    function New-Stream([string]$Name, [object[]]$Events) {
        $p = Join-Path $TestDrive $Name
        $lines = foreach ($e in $Events) { if ($e -is [string]) { $e } else { ConvertTo-Json $e -Depth 20 -Compress } }
        Set-Content -LiteralPath $p -Value $lines -Encoding utf8NoBOM
        $p
    }
    function New-Stub([string]$Name, [string]$Body) {
        $p = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $p -Value $Body -Encoding utf8NoBOM
        @($script:Pwsh, '-NoProfile', '-NonInteractive', '-File', $p)
    }
    # Stub that reports its args, cwd, stdin and selected env vars as one stream line.
    $script:EchoStub = @'
$stdin = [Console]::In.ReadToEnd()
$envDump = [ordered]@{}
Get-ChildItem env: | Where-Object Name -Match '^(CLAUDE|ANTHROPIC|RFB_|DISABLE_)' | Sort-Object Name | ForEach-Object { $envDump[$_.Name] = $_.Value }
[Console]::Out.WriteLine((ConvertTo-Json -Compress @{ type = 'system'; subtype = 'init'; session_id = 'stub-echo'; model = 'stub-model'; claude_code_version = '9.9.9'; mcp_servers = @() }))
[Console]::Out.WriteLine((ConvertTo-Json -Compress -Depth 5 @{ type = 'stub'; args = @($args); cwd = (Get-Location).Path; stdin = $stdin; env = $envDump }))
[Console]::Out.WriteLine((ConvertTo-Json -Compress @{ type = 'result'; subtype = 'success'; is_error = $false; duration_ms = 5; num_turns = 1; total_cost_usd = 0.5; session_id = 'stub-echo'; usage = @{ input_tokens = 1; output_tokens = 2; cache_read_input_tokens = 3; cache_creation_input_tokens = 4 } }))
[Console]::Error.WriteLine('stub stderr line')
exit 3
'@
}

Describe 'ConvertFrom-ClaudeStream' {
    It 'parses the hello stream' {
        $r = ConvertFrom-ClaudeStream (Join-Path $script:StreamDir 'hello.jsonl')
        $r.SessionId | Should -Not -BeNullOrEmpty
        $r.CostUsd | Should -BeGreaterThan 0
        $r.CliVersion | Should -Match '^\d+\.\d+\.\d+'
        $r.Model | Should -Be 'claude-opus-5-5'
        $r.Status | Should -Be 'ok'
        $r.AbortReason | Should -BeNullOrEmpty
        $r.Turns | Should -Be 1
        $r.DurationMs | Should -Be 2843
        $r.InputTokens | Should -Be 3
        $r.OutputTokens | Should -Be 12
        $r.CacheReadTokens | Should -Be 12890
        $r.CacheCreationTokens | Should -Be 5214
        @($r.McpServers).Count | Should -Be 0
        @($r.ToolUses).Count | Should -Be 0
        $r.TranscriptPath | Should -Be (Join-Path $script:StreamDir 'hello.jsonl')
    }

    It 'counts tool uses by name and reads MCP server status' {
        $r = ConvertFrom-ClaudeStream (Join-Path $script:StreamDir 'tooluse.jsonl')
        ($r.ToolUses | Where-Object Tool -EQ 'mcp__mslearn__microsoft_docs_search').Count | Should -Be 1
        ($r.ToolUses | Where-Object Tool -EQ 'Bash').Count | Should -Be 2
        @($r.ToolUses).Count | Should -Be 2
        $r.McpServers.Count | Should -Be 2
        ($r.McpServers | Where-Object Name -EQ 'mslearn').Status | Should -Be 'connected'
        ($r.McpServers | Where-Object Name -EQ 'broken').Status | Should -Be 'failed'
        $r.Turns | Should -Be 4
        $r.Status | Should -Be 'ok'
    }

    It 'marks a 429 result as aborted/rate-limit' {
        $r = ConvertFrom-ClaudeStream (Join-Path $script:StreamDir 'ratelimit.jsonl')
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'rate-limit'
        $r.IsError | Should -BeTrue
    }

    It 'marks a usage-limit result as aborted/rate-limit' -TestCases @(
        @{ Msg = 'Claude AI usage limit reached|1762272000' }
        @{ Msg = 'API Error: Repeated 529 Overloaded errors' }
        @{ Msg = 'Rate limit exceeded' }
    ) {
        $p = New-Stream 'usage.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'result'; subtype = 'success'; is_error = $true; result = $Msg; session_id = 's1'; total_cost_usd = 0; num_turns = 1; duration_ms = 10 }
        )
        $r = ConvertFrom-ClaudeStream $p
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'rate-limit'
    }

    It 'marks an error result as rate-limit when the last API retry was a rate limit' {
        $p = New-Stream 'retry.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'system'; subtype = 'api_retry'; attempt = 10; error_status = 429; error = 'rate_limit'; session_id = 's1' }
            @{ type = 'result'; subtype = 'error_during_execution'; is_error = $true; session_id = 's1'; num_turns = 1; duration_ms = 10 }
        )
        (ConvertFrom-ClaudeStream $p).AbortReason | Should -Be 'rate-limit'
    }

    It 'keeps a non-rate-limit error result as ok (graded normally)' {
        $p = New-Stream 'maxturns.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'result'; subtype = 'error_max_turns'; is_error = $true; session_id = 's1'; total_cost_usd = 1.5; num_turns = 60; duration_ms = 10 }
        )
        $r = ConvertFrom-ClaudeStream $p
        $r.Status | Should -Be 'ok'
        $r.AbortReason | Should -BeNullOrEmpty
        $r.ResultSubtype | Should -Be 'error_max_turns'
        $r.Turns | Should -Be 60
    }

    It 'does not treat a successful result that mentions 429 as rate-limited' {
        $p = New-Stream 'ok429.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'Set field 429 to rate limit value'; session_id = 's1'; num_turns = 1; duration_ms = 10 }
        )
        (ConvertFrom-ClaudeStream $p).Status | Should -Be 'ok'
    }

    It 'skips malformed and non-JSON lines and counts subagent tool uses' {
        $p = New-Stream 'mixed.jsonl' @(
            'Waiting for background work to finish'
            '{"type":"assistant", broken'
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'assistant'; parent_tool_use_id = 'toolu_X'; message = @{ content = @(@{ type = 'tool_use'; id = 'a'; name = 'Read'; input = @{} }) } }
            @{ type = 'assistant'; parent_tool_use_id = $null; message = @{ content = @(@{ type = 'tool_use'; id = 'b'; name = 'Read'; input = @{} }, @{ type = 'tool_use'; id = 'c'; name = 'Agent'; input = @{} }) } }
        )
        $r = ConvertFrom-ClaudeStream $p
        $r.SessionId | Should -Be 's1'
        ($r.ToolUses | Where-Object Tool -EQ 'Read').Count | Should -Be 2
        ($r.ToolUses | Where-Object Tool -EQ 'Agent').Count | Should -Be 1
        # Sorted by tool name for stable output.
        $r.ToolUses[0].Tool | Should -Be 'Agent'
    }

    It 'marks an empty transcript as aborted/no-result' {
        $p = Join-Path $TestDrive 'empty.jsonl'
        Set-Content -LiteralPath $p -Value '' -NoNewline
        $r = ConvertFrom-ClaudeStream $p
        $r.SessionId | Should -BeNullOrEmpty
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'no-result'
        $r.CostUsd | Should -BeNullOrEmpty
        @($r.ToolUses).Count | Should -Be 0
    }

    It 'marks a stream without a result event as aborted/no-result' {
        $p = New-Stream 'noresult.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'assistant'; parent_tool_use_id = $null; message = @{ content = @(@{ type = 'tool_use'; id = 'a'; name = 'Bash'; input = @{} }) } }
        )
        $r = ConvertFrom-ClaudeStream $p
        $r.SessionId | Should -Be 's1'
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'no-result'
        ($r.ToolUses | Where-Object Tool -EQ 'Bash').Count | Should -Be 1
    }

    It 'maps a missing result after a final <Err> retry to rate-limit' -TestCases @(
        @{ Err = 'rate_limit' }, @{ Err = 'overloaded' }
    ) {
        $p = New-Stream 'noresult-retry.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'system'; subtype = 'api_retry'; attempt = 3; error_status = 429; error = $Err; session_id = 's1' }
        )
        $r = ConvertFrom-ClaudeStream $p
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'rate-limit'
    }

    It 'ignores a rate-limit retry that was followed by assistant output' {
        $p = New-Stream 'stale-retry.jsonl' @(
            @{ type = 'system'; subtype = 'init'; session_id = 's1'; claude_code_version = '2.1.318'; model = 'm'; mcp_servers = @() }
            @{ type = 'system'; subtype = 'api_retry'; attempt = 1; error_status = 429; error = 'rate_limit'; session_id = 's1' }
            @{ type = 'assistant'; parent_tool_use_id = $null; message = @{ content = @(@{ type = 'text'; text = 'working' }) } }
            @{ type = 'result'; subtype = 'error_max_turns'; is_error = $true; session_id = 's1'; total_cost_usd = 1; num_turns = 60; duration_ms = 10 }
        )
        $r = ConvertFrom-ClaudeStream $p
        $r.Status | Should -Be 'ok'
        $r.AbortReason | Should -BeNullOrEmpty
    }

    It 'throws for a missing transcript' {
        { ConvertFrom-ClaudeStream (Join-Path $TestDrive 'nope.jsonl') } | Should -Throw '*nope.jsonl*'
    }
}

Describe 'Get-ClaudeArguments' {
    It 'builds the base command line' {
        InModuleScope Agent {
            $a = Get-ClaudeArguments -Prompt 'do it' -Model 'claude-opus-5-5' -MaxTurns 60 -McpConfigPath 'C:\h\rfbench-mcp.json' -McpMode 'open' -ResumeSessionId ''
            $a[0] | Should -Be '-p'
            $a[1] | Should -Be 'do it'
            $s = $a -join ' '
            $s | Should -BeLike '*--model claude-opus-5-5*'
            $s | Should -BeLike '*--max-turns 60*'
            $s | Should -BeLike '*--output-format stream-json*'
            $s | Should -BeLike '*--verbose*'
            $s | Should -BeLike '*--permission-mode bypassPermissions*'
            $s | Should -BeLike '*--mcp-config C:\h\rfbench-mcp.json*'
            $a | Should -Not -Contain '--strict-mcp-config'
            $a | Should -Not -Contain '--resume'
        }
    }
    It 'adds --strict-mcp-config in strict mode' {
        InModuleScope Agent {
            $a = Get-ClaudeArguments -Prompt 'x' -Model 'm' -MaxTurns 1 -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId ''
            $a | Should -Contain '--strict-mcp-config'
            $a | Should -Contain '--mcp-config'
        }
    }
    It 'adds --resume <id> when resuming' {
        InModuleScope Agent {
            $a = Get-ClaudeArguments -Prompt 'x' -Model 'm' -MaxTurns 1 -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId 'abc-123'
            $i = [array]::IndexOf($a, '--resume')
            $i | Should -BeGreaterThan 0
            $a[$i + 1] | Should -Be 'abc-123'
        }
    }
    It 'leaves a very long prompt out of the command line (sent on stdin)' {
        InModuleScope Agent {
            $long = 'x' * 40000
            $a = Get-ClaudeArguments -Prompt $long -Model 'm' -MaxTurns 1 -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId ''
            $a[0] | Should -Be '-p'
            $a | Should -Not -Contain $long
        }
    }
    It 'rejects an unknown MCP mode and a missing MCP config path' {
        InModuleScope Agent {
            { Get-ClaudeArguments -Prompt 'x' -Model 'm' -MaxTurns 1 -McpConfigPath 'c.json' -McpMode 'loose' -ResumeSessionId '' } | Should -Throw '*loose*'
            { Get-ClaudeArguments -Prompt 'x' -Model 'm' -MaxTurns 1 -McpConfigPath '' -McpMode 'strict' -ResumeSessionId '' } | Should -Throw '*McpConfigPath*'
        }
    }
}

Describe 'Invoke-ClaudeAttempt' {
    BeforeAll {
        $script:Ws = Join-Path $TestDrive 'ws'
        New-Item -ItemType Directory $script:Ws -Force | Out-Null
    }

    It 'runs in the workspace, tees stdout to the transcript and parses it' {
        $cmd = New-Stub 'echo-stub.ps1' $script:EchoStub
        $t = Join-Path $TestDrive 'out\echo.jsonl'
        $r = Invoke-ClaudeAttempt -Env @{ DISABLE_AUTOUPDATER = '1' } -Ws $script:Ws -Prompt 'hello there' -Model 'claude-opus-5-5' -MaxTurns 7 `
            -TimeoutMinutes 2 -McpConfigPath 'C:\h\rfbench-mcp.json' -McpMode 'strict' -ResumeSessionId 'sess-1' -TranscriptPath $t -ClaudeCommand $cmd
        Test-Path $t | Should -BeTrue
        $r.TranscriptPath | Should -Be $t
        $r.SessionId | Should -Be 'stub-echo'
        $r.CostUsd | Should -Be 0.5
        $r.ExitCode | Should -Be 3
        $r.Status | Should -Be 'ok'
        $stub = Get-Content $t | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -EQ 'stub'
        $stub.cwd | Should -Be (Resolve-Path $script:Ws).Path
        $stub.args[0] | Should -Be '-p'
        $stub.args[1] | Should -Be 'hello there'
        ($stub.args -join ' ') | Should -BeLike '*--max-turns 7*--mcp-config C:\h\rfbench-mcp.json --strict-mcp-config*'
        ($stub.args -join ' ') | Should -BeLike '*--resume sess-1*'
        Get-Content "$t.stderr.txt" -Raw | Should -BeLike '*stub stderr line*'
    }

    It 'applies env overrides, removes $null keys and strips inherited CLAUDE*/ANTHROPIC* vars' {
        $saved = @{}
        $set = @{ CLAUDECODE = '1'; CLAUDE_CODE_ENTRYPOINT = 'cli'; ANTHROPIC_BASE_URL = 'http://proxy'; ANTHROPIC_API_KEY = 'inherited-key'
            CLAUDE_CODE_OAUTH_TOKEN = 'inherited-token'; RFB_KEEP = 'keep'; RFB_REMOVE = 'gone' }
        foreach ($k in $set.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
        try {
            $cmd = New-Stub 'echo-stub2.ps1' $script:EchoStub
            $t = Join-Path $TestDrive 'env.jsonl'
            $envMap = @{ CLAUDE_CONFIG_DIR = 'C:\rfb-runs\x\claude-home'; CLAUDE_CODE_OAUTH_TOKEN = 'run-token'; ANTHROPIC_API_KEY = $null
                DISABLE_AUTOUPDATER = '1'; RFB_REMOVE = $null }
            $null = Invoke-ClaudeAttempt -Env $envMap -Ws $script:Ws -Prompt 'p' -Model 'm' -MaxTurns 1 -TimeoutMinutes 2 `
                -McpConfigPath 'c.json' -McpMode 'open' -ResumeSessionId '' -TranscriptPath $t -ClaudeCommand $cmd
            # The parent process environment is untouched.
            $env:CLAUDECODE | Should -Be '1'
            $env:RFB_REMOVE | Should -Be 'gone'
        }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $stub = Get-Content $t | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -EQ 'stub'
        $names = @($stub.env.PSObject.Properties.Name)
        $names | Should -Not -Contain 'CLAUDECODE'
        $names | Should -Not -Contain 'CLAUDE_CODE_ENTRYPOINT'
        $names | Should -Not -Contain 'ANTHROPIC_BASE_URL'
        $names | Should -Not -Contain 'ANTHROPIC_API_KEY'
        $names | Should -Not -Contain 'RFB_REMOVE'
        $stub.env.RFB_KEEP | Should -Be 'keep'
        $stub.env.CLAUDE_CODE_OAUTH_TOKEN | Should -Be 'run-token'
        $stub.env.CLAUDE_CONFIG_DIR | Should -Be 'C:\rfb-runs\x\claude-home'
        $stub.env.DISABLE_AUTOUPDATER | Should -Be '1'
    }

    It 'sends a very long prompt on stdin' {
        $cmd = New-Stub 'echo-stub3.ps1' $script:EchoStub
        $t = Join-Path $TestDrive 'long.jsonl'
        $long = ('compile error line ' * 2500).Trim()
        $null = Invoke-ClaudeAttempt -Env @{} -Ws $script:Ws -Prompt $long -Model 'm' -MaxTurns 1 -TimeoutMinutes 2 `
            -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId '' -TranscriptPath $t -ClaudeCommand $cmd
        $stub = Get-Content $t | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -EQ 'stub'
        $stub.stdin | Should -Be $long
        $stub.args | Should -Not -Contain $long
    }

    It 'kills and aborts on timeout' {
        $pidFile = Join-Path $TestDrive 'stub.pid'
        $childFile = Join-Path $TestDrive 'child.pid'
        $body = @"
`$PID | Set-Content '$pidFile'
`$c = Start-Process '$($script:Pwsh)' -ArgumentList '-NoProfile','-Command','Start-Sleep 300' -PassThru -WindowStyle Hidden
`$c.Id | Set-Content '$childFile'
[Console]::Out.WriteLine('{"type":"system","subtype":"init","session_id":"stub-timeout","claude_code_version":"9.9.9","model":"m","mcp_servers":[]}')
[Console]::Out.Flush()
Start-Sleep 300
"@
        $cmd = New-Stub 'sleep-stub.ps1' $body
        $t = Join-Path $TestDrive 'timeout.jsonl'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ClaudeAttempt -Env @{} -Ws $script:Ws -Prompt 'p' -Model 'm' -MaxTurns 1 -TimeoutMinutes 0.05 `
            -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId '' -TranscriptPath $t -ClaudeCommand $cmd
        $sw.Stop()
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'timeout'
        $r.SessionId | Should -Be 'stub-timeout'
        $r.DurationMs | Should -BeGreaterOrEqual 2500
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
        $stubPid = [int](Get-Content $pidFile)
        $childPid = [int](Get-Content $childFile)
        Get-Process -Id $stubPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'times out (no hang, no throw) when the child never reads a long stdin prompt' {
        # Stub ignores stdin and sleeps; a >24k prompt overflows the pipe buffer. The last
        # stream event is a rate-limit retry, so this also checks timeout > rate-limit.
        $body = @'
[Console]::Out.WriteLine('{"type":"system","subtype":"init","session_id":"stub-stdin","claude_code_version":"9.9.9","model":"m","mcp_servers":[]}')
[Console]::Out.WriteLine('{"type":"system","subtype":"api_retry","attempt":1,"error_status":429,"error":"rate_limit","session_id":"stub-stdin"}')
[Console]::Out.Flush()
Start-Sleep 300
'@
        $cmd = New-Stub 'nostdin-stub.ps1' $body
        $t = Join-Path $TestDrive 'nostdin.jsonl'
        $long = 'y' * 200000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ClaudeAttempt -Env @{} -Ws $script:Ws -Prompt $long -Model 'm' -MaxTurns 1 -TimeoutMinutes 0.05 `
            -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId '' -TranscriptPath $t -ClaudeCommand $cmd
        $sw.Stop()
        $r.Status | Should -Be 'aborted'
        $r.AbortReason | Should -Be 'timeout'
        $r.SessionId | Should -Be 'stub-stdin'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
    }

    It 'throws when the workspace does not exist' {
        { Invoke-ClaudeAttempt -Env @{} -Ws (Join-Path $TestDrive 'missing') -Prompt 'p' -Model 'm' -MaxTurns 1 -TimeoutMinutes 1 `
                -McpConfigPath 'c.json' -McpMode 'strict' -ResumeSessionId '' -TranscriptPath (Join-Path $TestDrive 'x.jsonl') } | Should -Throw '*missing*'
    }
}

Describe 'Get-BasePrompt' {
    It 'replaces {{COMPILE}} literally' {
        $hint = '& "C:\rfb-compiler\compiler\extension\bin\win32\alc.exe" /project:app /packagecachepath:.alpackages /out:app.app $_ $1'
        $p = Get-BasePrompt $hint
        $p | Should -Not -BeLike '*{{COMPILE}}*'
        $p.Contains($hint) | Should -BeTrue
    }
    It 'covers the required instructions and nothing harness-specific' {
        $p = Get-BasePrompt 'alc'
        $p | Should -BeLike '*TASK.md*'
        $p | Should -BeLike '*app/*'
        $p | Should -Match '(?i)hidden tests'
        $p | Should -Match '(?i)do not create (a )?test app'
        $p | Should -Match '(?i)stop'
        $p | Should -Not -Match '(?i)rf-bench|grader|solution|mcp'
    }
    It 'throws without a compile command' {
        { Get-BasePrompt '' } | Should -Throw
    }
}
