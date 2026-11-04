#Requires -Version 7.6
Set-StrictMode -Version Latest

# Claude Code invocation (`claude -p ... --output-format stream-json`) and stream parsing.
# Stream shape (one JSON object per line), see https://code.claude.com/docs/en/headless:
# - system/init: session_id, model, claude_code_version, tools[], mcp_servers[{name,status}]
# - system/api_retry: error ('rate_limit', 'overloaded', ...), error_status
# - assistant: message.content[] with {type:'tool_use', name} blocks
# - result (last line): subtype, is_error, result, total_cost_usd, num_turns, duration_ms, usage{...}

$script:McpModes = @('strict', 'open')
# Prompts longer than this go on stdin instead of the command line (Windows limit is 32767 chars).
$script:MaxArgPromptLength = 24000
$script:RateLimitPattern = 'rate limit|usage limit|hit your (usage )?limit|429|overloaded'
# Inherited variables that are kept although they match CLAUDE*/ANTHROPIC*.
$script:KeepEnv = @('CLAUDE_CODE_GIT_BASH_PATH')
# Run variables whose values are secrets; they are redacted from the attempt's output files.
$script:SecretEnv = @('CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY')

function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function ConvertTo-NullableLong($Value) { if ($null -eq $Value) { $null } else { [long]$Value } }

# Replaces every occurrence of the secret values with '<redacted>' in the given files.
function Remove-SecretsFromFiles([string[]]$Paths, [string[]]$Secrets) {
    $values = @($Secrets | Where-Object { $_ } | Sort-Object Length -Descending)
    if (-not $values) { return }
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($p)
        $new = $text
        foreach ($v in $values) { $new = $new.Replace($v, '<redacted>') }
        if ($new -cne $text) { [IO.File]::WriteAllText($p, $new, [Text.UTF8Encoding]::new($false)) }
    }
}

function ConvertFrom-ClaudeStream {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TranscriptPath)

    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) { throw "transcript not found: $TranscriptPath" }

    $init = $null
    $result = $null
    $lastRetryError = $null
    $tools = @{}
    foreach ($line in [IO.File]::ReadLines($TranscriptPath)) {
        if (-not $line.StartsWith('{')) { continue }
        try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $type = Get-Prop $e 'type'
        $subtype = Get-Prop $e 'subtype'
        if ($type -eq 'system' -and $subtype -eq 'init') { if ($null -eq $init) { $init = $e } }
        elseif ($type -eq 'system' -and $subtype -eq 'api_retry') { $lastRetryError = [string](Get-Prop $e 'error') }
        elseif ($type -eq 'assistant') {
            # A retry followed by model output was recovered; only a trailing retry counts.
            $lastRetryError = $null
            foreach ($block in @(Get-Prop (Get-Prop $e 'message') 'content')) {
                if ((Get-Prop $block 'type') -ne 'tool_use') { continue }
                $name = [string](Get-Prop $block 'name')
                if ($name) { $tools[$name] = 1 + [int]$tools[$name] }
            }
        }
        elseif ($type -eq 'result') { $result = $e }
    }

    $servers = @(foreach ($s in @(Get-Prop $init 'mcp_servers')) {
            if ($null -eq $s) { continue }
            [pscustomobject]@{ Name = [string](Get-Prop $s 'name'); Status = [string](Get-Prop $s 'status') }
        })
    $toolUses = @(foreach ($k in $tools.Keys | Sort-Object) { [pscustomobject]@{ Tool = $k; Count = $tools[$k] } })

    $usage = Get-Prop $result 'usage'
    $isError = [bool](Get-Prop $result 'is_error')
    $status = 'ok'
    $reason = $null
    $retryRateLimited = $lastRetryError -in 'rate_limit', 'overloaded'
    # Precedence: rate-limit > no-result (the caller sets 'timeout' above both).
    if ($null -eq $result) {
        $status = 'aborted'
        $reason = $(if ($retryRateLimited) { 'rate-limit' } else { 'no-result' })
    }
    elseif ($isError) {
        $text = @([string](Get-Prop $result 'result')) + @(Get-Prop $result 'errors' | ForEach-Object { [string]$_ })
        if (($text -join "`n") -match $script:RateLimitPattern -or $retryRateLimited) {
            $status = 'aborted'; $reason = 'rate-limit'
        }
    }

    $sessionId = Get-Prop $init 'session_id'
    if (-not $sessionId) { $sessionId = Get-Prop $result 'session_id' }
    $cost = Get-Prop $result 'total_cost_usd'

    [pscustomobject]@{
        SessionId           = $(if ($sessionId) { [string]$sessionId } else { $null })
        ExitCode            = $null
        Status              = $status
        AbortReason         = $reason
        CostUsd             = $(if ($null -ne $cost) { [double]$cost } else { $null })
        InputTokens         = ConvertTo-NullableLong (Get-Prop $usage 'input_tokens')
        OutputTokens        = ConvertTo-NullableLong (Get-Prop $usage 'output_tokens')
        CacheReadTokens     = ConvertTo-NullableLong (Get-Prop $usage 'cache_read_input_tokens')
        CacheCreationTokens = ConvertTo-NullableLong (Get-Prop $usage 'cache_creation_input_tokens')
        Turns               = $(if ($null -ne (Get-Prop $result 'num_turns')) { [int](Get-Prop $result 'num_turns') } else { $null })
        DurationMs          = ConvertTo-NullableLong (Get-Prop $result 'duration_ms')
        Model               = $(if (Get-Prop $init 'model') { [string](Get-Prop $init 'model') } else { $null })
        CliVersion          = $(if (Get-Prop $init 'claude_code_version') { [string](Get-Prop $init 'claude_code_version') } else { $null })
        McpServers          = $servers
        ToolUses            = $toolUses
        IsError             = $isError
        ResultSubtype       = $(if ($null -ne $result) { [string](Get-Prop $result 'subtype') } else { $null })
        TranscriptPath      = $TranscriptPath
    }
}

# Command-line arguments for one attempt. A prompt longer than MaxArgPromptLength is not
# included; the caller writes it to stdin (claude -p reads the prompt from stdin).
function Get-ClaudeArguments {
    param([string]$Prompt, [string]$Model, [int]$MaxTurns, [string]$McpConfigPath, [string]$McpMode, [string]$ResumeSessionId)

    if ($McpMode -cnotin $script:McpModes) { throw "invalid McpMode '$McpMode' (expected strict|open)" }
    if (-not $McpConfigPath) { throw 'McpConfigPath is required' }
    $a = [Collections.Generic.List[string]]::new()
    $a.Add('-p')
    if ($Prompt.Length -le $script:MaxArgPromptLength) { $a.Add($Prompt) }
    $a.AddRange([string[]]@('--model', $Model, '--max-turns', [string]$MaxTurns, '--output-format', 'stream-json', '--verbose',
            '--permission-mode', 'bypassPermissions', '--mcp-config', $McpConfigPath))
    if ($McpMode -eq 'strict') { $a.Add('--strict-mcp-config') }
    if ($ResumeSessionId) { $a.Add('--resume'); $a.Add($ResumeSessionId) }
    , $a.ToArray()
}

function Resolve-ClaudeCommand {
    $c = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
        Sort-Object { if ($_.Source -like '*.exe') { 0 } else { 1 } } | Select-Object -First 1
    if (-not $c) { throw 'claude CLI not found on PATH' }
    if ($c.Source -notlike '*.exe') { throw "claude resolves to $($c.Source); a native claude.exe is required (prompt quoting through cmd/ps1 shims is unsafe)" }
    , @($c.Source)
}

function Invoke-ClaudeAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Env,
        [Parameter(Mandatory)][string]$Ws,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$MaxTurns,
        [Parameter(Mandatory)][double]$TimeoutMinutes,
        [Parameter(Mandatory)][string]$McpConfigPath,
        [Parameter(Mandatory)][string]$McpMode,
        [AllowEmptyString()][string]$ResumeSessionId,
        [Parameter(Mandatory)][string]$TranscriptPath,
        # Executable plus leading arguments; defaults to the native claude.exe on PATH. Tests pass a stub.
        [string[]]$ClaudeCommand
    )

    if (-not (Test-Path -LiteralPath $Ws -PathType Container)) { throw "workspace not found: $Ws" }
    if ($TimeoutMinutes -le 0) { throw 'TimeoutMinutes must be > 0' }
    $claudeArgs = Get-ClaudeArguments -Prompt $Prompt -Model $Model -MaxTurns $MaxTurns -McpConfigPath $McpConfigPath -McpMode $McpMode -ResumeSessionId $ResumeSessionId
    if (-not $ClaudeCommand) { $ClaudeCommand = Resolve-ClaudeCommand }

    $psi = [Diagnostics.ProcessStartInfo]::new($ClaudeCommand[0])
    foreach ($x in @($ClaudeCommand | Select-Object -Skip 1) + $claudeArgs) { $psi.ArgumentList.Add($x) }
    $psi.WorkingDirectory = (Resolve-Path -LiteralPath $Ws).Path
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # The runner may itself run inside Claude Code: drop inherited CLAUDE*/ANTHROPIC* variables
    # unless the run sets them or they are machine setup (Git Bash location), then apply the
    # run's overrides ($null = remove).
    foreach ($k in @($psi.Environment.Keys)) {
        if ($k -match '^(CLAUDE|ANTHROPIC)' -and $k -notin $script:KeepEnv -and -not $Env.ContainsKey($k)) { $null = $psi.Environment.Remove($k) }
    }
    foreach ($k in $Env.Keys) {
        if ($null -eq $Env[$k]) { $null = $psi.Environment.Remove($k) } else { $psi.Environment[$k] = [string]$Env[$k] }
    }

    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($TranscriptPath))
    New-Item -ItemType Directory $dir -Force | Out-Null
    $out = [IO.File]::Create($TranscriptPath)
    $err = [IO.File]::Create("$TranscriptPath.stderr.txt")
    $proc = $null
    $timedOut = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        # Raw byte copies: stdout goes to the transcript unchanged, stderr to a side file.
        $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($out)
        $errCopy = $proc.StandardError.BaseStream.CopyToAsync($err)
        # A long prompt goes to stdin asynchronously: a child that never reads stdin must not
        # block the runner, so WaitForExit(timeout) stays the only blocking call.
        $stdin = $proc.StandardInput.BaseStream
        $write = $null
        if ($Prompt.Length -gt $script:MaxArgPromptLength) {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Prompt)
            try { $write = $stdin.WriteAsync($bytes, 0, $bytes.Length) }
            catch { Write-Verbose "stdin write failed: $($_.Exception.Message)" }
        }
        $stdinOpen = $true
        $timeoutMs = [long][Math]::Ceiling($TimeoutMinutes * 60000)
        while ($true) {
            # Close stdin (EOF for claude -p) once the write is done or failed.
            if ($stdinOpen -and ($null -eq $write -or $write.IsCompleted)) {
                try { $stdin.Close() } catch { Write-Verbose "stdin close failed: $($_.Exception.Message)" }
                $stdinOpen = $false
            }
            $remaining = $timeoutMs - $sw.ElapsedMilliseconds
            if ($remaining -le 0) { $timedOut = $true; break }
            $slice = $(if ($stdinOpen) { [Math]::Min($remaining, 200) } else { $remaining })
            if ($proc.WaitForExit([int]$slice)) { break }
        }
        if ($timedOut) {
            try { $proc.Kill($true) } catch { Write-Verbose "kill failed: $($_.Exception.Message)" }
            $null = $proc.WaitForExit(30000)
        }
        # Grandchildren may still hold the pipes; do not wait for them forever.
        try { $null = [Threading.Tasks.Task]::WaitAll(@($outCopy, $errCopy), 30000) }
        catch { Write-Verbose "output copy failed: $($_.Exception.Message)" }
    }
    finally {
        $sw.Stop()
        # Never leave a child running if anything above threw.
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { Write-Verbose "kill failed: $($_.Exception.Message)" } }
        if ($proc) { try { $proc.StandardInput.Dispose() } catch { Write-Verbose "stdin dispose failed: $($_.Exception.Message)" } }
        $out.Dispose()
        $err.Dispose()
        # The auth secret must never be stored in results (an agent can print its environment).
        Remove-SecretsFromFiles @($TranscriptPath, "$TranscriptPath.stderr.txt") @($script:SecretEnv | ForEach-Object { [string]$Env[$_] })
    }

    $r = ConvertFrom-ClaudeStream $TranscriptPath
    $r.ExitCode = $(if ($proc.HasExited) { $proc.ExitCode } else { $null })
    $proc.Dispose()
    if ($null -eq $r.DurationMs) { $r.DurationMs = $sw.ElapsedMilliseconds }
    if ($timedOut) {
        $r.Status = 'aborted'
        $r.AbortReason = 'timeout'
        $r.DurationMs = $sw.ElapsedMilliseconds
    }
    $r
}

function Get-BasePrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CompilerHint)

    $path = Join-Path $PSScriptRoot '..\docs\base-prompt.md'
    $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
    $text.Replace('{{COMPILE}}', $CompilerHint).TrimEnd()
}

Export-ModuleMember -Function Invoke-ClaudeAttempt, ConvertFrom-ClaudeStream, Get-BasePrompt
