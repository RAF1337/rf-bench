#Requires -Version 7.6
Set-StrictMode -Version Latest

$script:Statuses = @('pending', 'done', 'aborted', 'invalid', 'skipped')

function Get-MemberValue($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# 'pending' is the initial status of planned work; it is never written once a task has finished.
function New-RunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$MaxTurns,
        [Parameter(Mandatory)][string]$AuthMode,
        [Parameter(Mandatory)][string]$McpMode,
        [string[]]$AllowedMcp = @(),
        [string[]]$InstalledPlugins = @(),
        $Versions = ([pscustomobject]@{}),
        [Parameter(Mandatory)][object[]]$Plan,
        [datetime]$StartedUtc = [datetime]::UtcNow
    )
    $tasks = foreach ($w in $Plan) {
        [pscustomobject][ordered]@{
            taskId                = [string](Get-MemberValue $w 'TaskId')
            repeat                = [int](Get-MemberValue $w 'Repeat')
            status                = 'pending'
            abortReason           = $null
            leak                  = [pscustomobject][ordered]@{ leaked = $false; hits = @() }
            firstTestsPassAttempt = $null
            fullyRightAttempt     = $null
            attempts              = @()
        }
    }
    [pscustomobject][ordered]@{
        runId      = $RunId
        startedUtc = $StartedUtc.ToUniversalTime().ToString('o')
        profile    = [pscustomobject][ordered]@{ name = [string](Get-MemberValue $Profile 'name'); hash = [string](Get-MemberValue $Profile 'hash') }
        model      = $Model
        maxTurns   = $MaxTurns
        auth       = [pscustomobject][ordered]@{ mode = $AuthMode }
        mcp        = [pscustomobject][ordered]@{ mode = $McpMode; allowed = @($AllowedMcp); installedPlugins = @($InstalledPlugins) }
        versions   = $Versions
        tasks      = @($tasks)
    }
}

function Find-TaskEntry($Record, [string]$TaskId, [int]$Repeat) {
    $t = @($Record.tasks) | Where-Object { $_.taskId -ceq $TaskId -and $_.repeat -eq $Repeat } | Select-Object -First 1
    if (-not $t) { throw "Run record has no task entry $TaskId/$Repeat" }
    $t
}

function Add-AttemptRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Record,
        [Parameter(Mandatory, Position = 1)][string]$TaskId,
        [Parameter(Mandatory, Position = 2)][int]$Repeat,
        [Parameter(Mandatory, Position = 3)]$Agent,
        [Parameter(Mandatory, Position = 4)][AllowNull()]$Grade,
        [Parameter(Position = 5)][string]$Feedback = ''
    )
    $t = Find-TaskEntry $Record $TaskId $Repeat
    $n = @($t.attempts).Count + 1
    $available = @(Get-MemberValue $Agent 'McpServers' | Where-Object { $null -ne $_ })
    $allowed = @($Record.mcp.allowed)
    $found = @($available | ForEach-Object { [string](Get-MemberValue $_ 'Name') } | Where-Object { $_ -and $_ -notin $allowed })
    $attempt = [pscustomobject][ordered]@{
        n        = $n
        agent    = $Agent
        grade    = $Grade
        feedback = $Feedback
        mcp      = [pscustomobject][ordered]@{ available = $available; foundByClaude = $found }
    }
    $t.attempts = @($t.attempts) + $attempt
    if ($null -eq $t.firstTestsPassAttempt -and (Get-MemberValue $Grade 'TestsPassed')) { $t.firstTestsPassAttempt = $n }
    if ($null -eq $t.fullyRightAttempt -and (Get-MemberValue $Grade 'FullyRight')) { $t.fullyRightAttempt = $n }
}

function Set-TaskOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Record,
        [Parameter(Mandatory, Position = 1)][string]$TaskId,
        [Parameter(Mandatory, Position = 2)][int]$Repeat,
        [Parameter(Mandatory)][ValidateSet('pending', 'done', 'aborted', 'invalid', 'skipped')][string]$Status,
        $Leak,
        [string]$AbortReason
    )
    $t = Find-TaskEntry $Record $TaskId $Repeat
    $t.status = $Status
    if ($PSBoundParameters.ContainsKey('AbortReason')) { $t.abortReason = $AbortReason }
    if ($Leak) {
        $t.leak = [pscustomobject][ordered]@{ leaked = [bool](Get-MemberValue $Leak 'Leaked'); hits = @(Get-MemberValue $Leak 'Hits') }
    }
}

function Save-RunRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Record, [Parameter(Mandatory, Position = 1)][string]$Path)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $tmp = "$Path.tmp"
    $Record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-RunRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "run.json not found: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50
}

function Get-PendingWork {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunJson)
    $rec = Get-RunRecord $RunJson
    foreach ($t in @($rec.tasks)) {
        if ($t.status -notin 'done', 'invalid', 'skipped') { [pscustomobject]@{ TaskId = $t.taskId; Repeat = [int]$t.repeat } }
    }
}

# SHA256 over sorted relative paths and file bytes of a whole folder. -ExcludeDirectories names
# directories skipped at any depth (case-insensitive); -ExcludeExtensions names file extensions
# skipped (for example '.app', case-insensitive).
function Get-FolderHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeExtensions = @()
    )
    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
        [pscustomobject]@{ Rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); Full = $_.FullName; Ext = $_.Extension }
    } | Where-Object {
        $f = $_
        $dirs = @($f.Rel.Split('/') | Select-Object -SkipLast 1)
        -not ($dirs | Where-Object { $_ -in $ExcludeDirectories }) -and $f.Ext -notin $ExcludeExtensions
    } | Sort-Object { $_.Rel } -Culture '' -CaseSensitive
    $h = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($f in $files) {
            $h.AppendData([Text.Encoding]::UTF8.GetBytes($f.Rel + "`n"))
            $bytes = [IO.File]::ReadAllBytes($f.Full)
            $h.AppendData([Text.Encoding]::UTF8.GetBytes("$($bytes.Length)`n"))
            $h.AppendData($bytes)
        }
        ([BitConverter]::ToString($h.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
    }
    finally { $h.Dispose() }
}

# Profile fingerprint (profile.json included).
function Get-ProfileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfileDir)
    Get-FolderHash -Path $ProfileDir
}

function ConvertTo-Sha256Hex([byte[]]$Bytes) {
    ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($Bytes)) -replace '-', '').ToLowerInvariant()
}

# Version stamp of one MCP server entry: SHA256 of the compact JSON {command, args, url}.
# env is left out (it may hold secrets and does not identify the server).
function Get-McpServerHash {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Server)
    $a = Get-MemberValue $Server 'args'
    $o = [ordered]@{
        command = Get-MemberValue $Server 'command'
        args    = $(if ($null -ne $a) { , @($a) } else { $null })
        url     = Get-MemberValue $Server 'url'
    }
    ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $o -Compress -Depth 20)))
}

# Claude Code managed (enterprise) settings apply to every run on this machine.
$script:ManagedSettingsPath = Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json'

# SHA256 of the managed settings file, or $null when there is none.
function Get-ManagedSettingsHash {
    [CmdletBinding()]
    param([string]$Path = $script:ManagedSettingsPath)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    ConvertTo-Sha256Hex ([IO.File]::ReadAllBytes($Path))
}

Export-ModuleMember -Function New-RunRecord, Add-AttemptRecord, Set-TaskOutcome, Save-RunRecord, Get-RunRecord, Get-PendingWork, Get-FolderHash, Get-ProfileHash,
    Get-McpServerHash, Get-ManagedSettingsHash
