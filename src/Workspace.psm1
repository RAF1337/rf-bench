#Requires -Version 7.6
Set-StrictMode -Version Latest

# Run workspace, harness profile install and agent settings/environment.
# Isolation rules (see docs/profile-format.md):
# - the agent only ever sees a copy of assignment/ under TempRoot, never the repo;
# - CLAUDE_CONFIG_DIR is a fresh folder per run, so the user's ~/.claude never loads;
# - runner deny rules are merged last into the workspace project settings.

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

$script:McpModes = @('strict', 'open')

function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $null } }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Test-PathUnder([string]$Path, [string]$Parent) {
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + '\'
    $r = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + '\'
    $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

# Windows path -> forward slashes, e.g. C:/GeneralDev/AL/rf-bench
function ConvertTo-ForwardPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') -replace '\\', '/'
}

# Windows path -> documented permission-rule form: absolute paths start with '//' and
# Windows paths are normalised to POSIX form (C:\x -> /c/x), so C:\x -> //c/x.
function ConvertTo-PermissionPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -notmatch '^[A-Za-z]:') { throw "not a drive path: $Path" }
    '//' + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')
}

# Copies the children of $Source into $Dest (including hidden files).
function Copy-DirContent([string]$Source, [string]$Dest) {
    New-Item -ItemType Directory $Dest -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Dest -Recurse -Force
    }
}

function New-RunWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$Repeat
    )

    $compiler = [string]$Config.Bc.CompilerFolder
    if (-not $compiler) { throw 'Bc.CompilerFolder not set; run src/Initialize-Backend.ps1' }
    $symbols = Join-Path $compiler 'symbols'
    if (-not (Test-Path -LiteralPath $symbols -PathType Container)) {
        throw "symbols folder not found: $symbols (run src/Initialize-Backend.ps1)"
    }

    $tempRoot = Get-CanonicalPath $Config.TempRoot
    if (Test-PathUnder $tempRoot $Config.RepoRoot) { throw "TempRoot $tempRoot is inside the repo $($Config.RepoRoot); set TempRoot outside it" }
    # The grader folder is not next to ws, so no relative path from ws (..\grader) reaches it.
    $root = [IO.Path]::GetFullPath((Join-Path $tempRoot $RunId $Task.Id ([string]$Repeat)))
    $grader = [IO.Path]::GetFullPath((Join-Path $tempRoot $RunId '_grader' $Task.Id ([string]$Repeat)))
    foreach ($p in $root, $grader) {
        $norm = $p.TrimEnd('\')
        if (-not (Test-PathUnder $norm $tempRoot) -or $norm -ieq $tempRoot.TrimEnd('\')) {
            throw "run folder $norm is outside TempRoot $tempRoot (RunId '$RunId')"
        }
    }

    $ws = Join-Path $root 'ws'
    $home_ = Join-Path $root 'claude-home'

    # A repeat always starts from clean folders (no stale config, sessions, files or grader output).
    foreach ($p in $root, $grader) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    New-Item -ItemType Directory $ws, $home_, $grader -Force | Out-Null
    $root = Get-CanonicalPath $root
    $ws = Get-CanonicalPath $ws
    $home_ = Get-CanonicalPath $home_
    $grader = Get-CanonicalPath $grader

    # Only assignment/ is copied. Never the task root, task.json or solution/.
    Copy-DirContent $Task.AssignmentDir $ws
    $alpackages = Join-Path $ws '.alpackages'
    New-Item -ItemType Directory $alpackages -Force | Out-Null
    Get-ChildItem -LiteralPath $symbols -File | Copy-Item -Destination $alpackages -Force

    # Make the workspace a git root: Claude Code walks parent folders for project skills
    # "up to the repository root"; this keeps the walk from reaching e.g. ~/.claude/skills.
    $out = & git -C $ws init -q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git init failed in ${ws}: $out" }

    [pscustomobject]@{ Root = $root; Ws = $ws; ClaudeHome = $home_; GraderDir = $grader }
}

function Get-BenchProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfileDir)

    $dir = (Resolve-Path -LiteralPath $ProfileDir -ErrorAction Stop).Path.TrimEnd('\', '/')
    $name = Split-Path $dir -Leaf
    $file = Join-Path $dir 'profile.json'
    $j = $null
    if (Test-Path -LiteralPath $file) {
        try { $j = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
        catch { throw "profile ${name}: invalid JSON in $file ($($_.Exception.Message))" }
    }

    $allowWeb = Get-Prop $j 'allowWeb'
    if ($null -ne $allowWeb -and $allowWeb -isnot [bool]) { throw "profile ${name}: allowWeb must be true or false" }
    $mode = Get-Prop $j 'mcpMode'
    if ($null -eq $mode) { $mode = 'strict' }
    if ($mode -cnotin $script:McpModes) { throw "profile ${name}: invalid mcpMode '$mode' (expected strict|open)" }

    $servers = [ordered]@{}
    $ms = Get-Prop $j 'mcpServers'
    if ($null -ne $ms) {
        if ($ms -isnot [System.Management.Automation.PSCustomObject]) { throw "profile ${name}: mcpServers must be an object" }
        foreach ($p in $ms.PSObject.Properties) { $servers[$p.Name] = $p.Value }
    }

    $plugins = @()
    foreach ($pl in @(Get-Prop $j 'plugins')) {
        if ($null -eq $pl) { continue }
        foreach ($k in 'name', 'marketplace', 'marketplaceSource') {
            if (-not (Get-Prop $pl $k)) { throw "profile ${name}: plugin entry missing '$k'" }
        }
        $plugins += [pscustomobject]@{
            Name              = [string]$pl.name
            Marketplace       = [string]$pl.marketplace
            MarketplaceSource = [string]$pl.marketplaceSource
        }
    }

    [pscustomobject]@{
        Name        = $name
        Dir         = $dir
        Description = [string](Get-Prop $j 'description')
        AllowWeb    = [bool]$allowWeb
        McpMode     = [string]$mode
        McpServers  = $servers
        Plugins     = $plugins
    }
}

# Runs the claude CLI with CLAUDE_CONFIG_DIR pointing at the run's config dir, restoring
# the caller's environment afterwards. Throws on a non-zero exit code.
function Invoke-ClaudeCli([string]$ClaudeHome, [string[]]$Arguments) {
    $saved = $env:CLAUDE_CONFIG_DIR
    $env:CLAUDE_CONFIG_DIR = $ClaudeHome
    try {
        $global:LASTEXITCODE = 0
        $out = & claude @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally { $env:CLAUDE_CONFIG_DIR = $saved }
    $text = @($out | ForEach-Object { "$_" })
    if ($code -ne 0) { throw "claude $($Arguments -join ' ') failed (exit $code): $($text -join [Environment]::NewLine)" }
    , $text
}

# Parses `claude plugin list --json` output, or the human-readable text as a fallback.
# Returns a hashtable id ('name@marketplace') -> version.
function ConvertFrom-PluginList([string[]]$Lines) {
    $map = @{}
    $raw = $Lines -join "`n"
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    if ($null -ne $parsed -and ($raw.TrimStart().StartsWith('['))) {
        foreach ($e in @($parsed)) {
            $id = Get-Prop $e 'id'
            if ($id) { $map[[string]$id] = [string](Get-Prop $e 'version') }
        }
        return $map
    }
    $current = $null
    foreach ($l in $Lines) {
        if ($l -match '^\s*(?:\S+\s+)?([^\s@]+@[^\s@]+)\s*$') { $current = $Matches[1]; $map[$current] = $null }
        elseif ($current -and $l -match '^\s*Version:\s*(\S+)') { $map[$current] = $Matches[1] }
    }
    $map
}

function Install-Profile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('Profile')]$HarnessProfile, [Parameter(Mandatory)]$Workspace)

    $userDir = Join-Path $HarnessProfile.Dir 'user'
    $projDir = Join-Path $HarnessProfile.Dir 'project'

    if (Test-Path -LiteralPath $userDir) {
        $creds = @(Get-ChildItem -LiteralPath $userDir -Recurse -File -Force | Where-Object Name -Like '*credentials*')
        if ($creds) { throw "profile $($HarnessProfile.Name): user/ must not contain credentials files ($($creds[0].Name)); auth goes through env vars only" }
        Copy-DirContent $userDir $Workspace.ClaudeHome
    }
    if (Test-Path -LiteralPath $projDir) {
        foreach ($f in Get-ChildItem -LiteralPath $projDir -Recurse -File -Force) {
            $rel = [IO.Path]::GetRelativePath($projDir, $f.FullName)
            if (Test-Path -LiteralPath (Join-Path $Workspace.Ws $rel)) {
                throw "profile $($HarnessProfile.Name): project/$rel would overwrite a task file in the workspace"
            }
        }
        Copy-DirContent $projDir $Workspace.Ws
    }

    $mcpPath = Join-Path $Workspace.ClaudeHome 'rfbench-mcp.json'
    $mcp = [ordered]@{ mcpServers = $HarnessProfile.McpServers }
    ConvertTo-Json $mcp -Depth 50 | Set-Content -LiteralPath $mcpPath -Encoding utf8NoBOM

    $installed = @()
    if (@($HarnessProfile.Plugins).Count -gt 0) {
        $added = @{}
        foreach ($pl in $HarnessProfile.Plugins) {
            if (-not $added.ContainsKey($pl.MarketplaceSource)) {
                Invoke-ClaudeCli $Workspace.ClaudeHome @('plugin', 'marketplace', 'add', $pl.MarketplaceSource) | Out-Null
                $added[$pl.MarketplaceSource] = $true
            }
            Invoke-ClaudeCli $Workspace.ClaudeHome @('plugin', 'install', "$($pl.Name)@$($pl.Marketplace)") | Out-Null
        }
        $versions = ConvertFrom-PluginList (Invoke-ClaudeCli $Workspace.ClaudeHome @('plugin', 'list', '--json'))
        foreach ($pl in $HarnessProfile.Plugins) {
            $id = "$($pl.Name)@$($pl.Marketplace)"
            if (-not $versions.ContainsKey($id)) { throw "plugin $id not installed (not in 'claude plugin list' output)" }
            $installed += [pscustomobject]@{ Name = $pl.Name; Version = $versions[$id] }
        }
    }

    [pscustomobject]@{ McpConfigPath = $mcpPath; InstalledPlugins = $installed }
}

# Spellings of an absolute path as it may appear in a shell command: C:\x, C:/x, //c/x, /c/x.
# With -Lower also the all-lower-case variants (Bash rules may match case-sensitively).
function Get-ShellPathForms([string]$Path, [switch]$Lower) {
    $win = Get-CanonicalPath $Path
    $perm = ConvertTo-PermissionPath $win
    $forms = @($win, ($win -replace '\\', '/'), $perm, ($perm -replace '^//', '/'))
    if ($Lower) { $forms += $forms | ForEach-Object { $_.ToLowerInvariant() } }
    @($forms | Select-Object -Unique)
}

function Get-RunnerDenyRules($Config, $HarnessProfile, $Workspace) {
    $rules = [Collections.Generic.List[string]]::new()
    $repo = Get-CanonicalPath $Config.RepoRoot
    $grader = Get-CanonicalPath $Workspace.GraderDir
    # <TempRoot>\<runId>\_grader: holds the grader folders of every task in the run.
    $runGraders = Split-Path (Split-Path $grader)
    foreach ($p in $repo, $grader, $runGraders) {
        # Brief form (forward slashes) plus the documented absolute form (//c/...).
        foreach ($form in (ConvertTo-ForwardPath $p), (ConvertTo-PermissionPath $p)) {
            $rules.Add("Read($form/**)"); $rules.Add("Edit($form/**)")
        }
    }
    # The agent must not loosen its own settings (bypassPermissions allows writes to .claude/).
    $rules.Add("Edit($(ConvertTo-PermissionPath (Get-CanonicalPath $Workspace.Ws))/.claude/settings*.json)")
    $rules.Add("Edit($(ConvertTo-PermissionPath (Get-CanonicalPath $Workspace.ClaudeHome))/settings*.json)")
    # Shell rules name the full repo and grader paths in every spelling a command may use
    # (C:\x, C:/x, //c/x, /c/x; Bash also lower-case), never a bare word such as the repo
    # name that could also match the workspace path.
    foreach ($p in $repo, $grader, $runGraders) {
        foreach ($form in Get-ShellPathForms $p) { $rules.Add("PowerShell(*$form*)") }
        foreach ($form in Get-ShellPathForms $p -Lower) { $rules.Add("Bash(*$form*)") }
    }
    # Relative references to a grader folder (..\grader, ../_grader).
    foreach ($leaf in '\grader', '/grader', '\_grader', '/_grader') {
        $rules.Add("Bash(*$leaf*)"); $rules.Add("PowerShell(*$leaf*)")
    }
    if (-not $HarnessProfile.AllowWeb) { $rules.Add('WebFetch'); $rules.Add('WebSearch') }
    , @($rules | Select-Object -Unique)
}

function Split-Rule([string]$Rule) {
    if ($Rule -match '^\s*([^()]+?)\s*(?:\((.*)\))?\s*$') { return @($Matches[1], $(if ($Matches.Count -gt 2) { $Matches[2] } else { $null })) }
    @($Rule, $null)
}

# Normalises a Read/Edit path specifier to lower-case '//c/...' form for overlap checks.
function ConvertTo-ComparablePath([string]$Spec) {
    $s = $Spec -replace '\\', '/'
    if ($s -match '^([A-Za-z]):/(.*)$') { $s = '//' + $Matches[1] + '/' + $Matches[2] }
    elseif ($s -match '^/([A-Za-z])/(.*)$') { $s = '//' + $Matches[1] + '/' + $Matches[2] }
    $s.ToLowerInvariant()
}

# Literal prefix of a glob ('//c/x/**' -> '//c/x/').
function Get-GlobPrefix([string]$Spec) {
    $i = $Spec.IndexOfAny([char[]]'*?[')
    if ($i -lt 0) { $Spec } else { $Spec.Substring(0, $i) }
}

# True when an allow rule overlaps a deny rule (same tool and the deny covers or
# intersects the allow), so the allow entry is dropped from the merged settings.
function Test-AllowDenied([string]$Allow, [string[]]$Deny) {
    $a = Split-Rule $Allow
    foreach ($d in $Deny) {
        $dd = Split-Rule $d
        if ($a[0] -ne $dd[0]) { continue }
        if ($null -eq $dd[1] -or $dd[1] -eq '*') { return $true }
        if ($a[1] -eq $dd[1]) { return $true }
        if ($a[0] -in 'Read', 'Edit') {
            $ap = Get-GlobPrefix (ConvertTo-ComparablePath $a[1])
            $dp = Get-GlobPrefix (ConvertTo-ComparablePath $dd[1])
            # Only absolute allow paths can reach the repo/grader; relative ones stay.
            if ($ap.StartsWith('//') -and ($ap.StartsWith($dp) -or $dp.StartsWith($ap))) { return $true }
        }
        elseif ($a[1] -like $dd[1]) { return $true }
    }
    $false
}

# CLAUDE.md / rules exclusions for every folder above the workspace. Claude Code loads
# CLAUDE.md from every ancestor folder. Defense in depth: the default TempRoot (C:\rfb-runs) is outside
# the user home, but a TempRoot under it would expose ~/.claude/CLAUDE.md as an ancestor file.
function Get-AncestorClaudeMdExcludes([string]$Ws) {
    $list = [Collections.Generic.List[string]]::new()
    $dir = Split-Path ([IO.Path]::GetFullPath($Ws).TrimEnd('\'))
    while ($dir) {
        $fwd = ($dir.TrimEnd('\') -replace '\\', '/')
        $posix = '/' + $fwd.Substring(0, 1).ToLowerInvariant() + $fwd.Substring(2)
        foreach ($base in $fwd, $posix) {
            foreach ($leaf in 'CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md', '.claude/CLAUDE.md', '.claude/CLAUDE.local.md', '.claude/rules/**') {
                $list.Add("$base/$leaf")
            }
        }
        $parent = Split-Path $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    , $list.ToArray()
}

function New-AgentSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Alias('Profile')]$HarnessProfile, [Parameter(Mandatory)]$Workspace)

    $path = Join-Path $Workspace.Ws '.claude\settings.json'
    # The agent can edit workspace files through a shell between attempts, so the settings are
    # always rebuilt from the profile's own copy, and a settings.local.json (which would be
    # merged over them) is removed.
    $local = Join-Path $Workspace.Ws '.claude\settings.local.json'
    if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
    $profileDir = [string](Get-Prop $HarnessProfile 'Dir')
    $source = if ($profileDir) { Join-Path $profileDir 'project\.claude\settings.json' } else { $null }
    $s = [ordered]@{}
    if ($source -and (Test-Path -LiteralPath $source)) {
        try { $s = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json -AsHashtable }
        catch { throw "profile $($HarnessProfile.Name): invalid JSON in project/.claude/settings.json ($($_.Exception.Message))" }
        if ($null -eq $s) { $s = [ordered]@{} }
    }
    if (-not $s.Contains('permissions') -or $null -eq $s['permissions']) { $s['permissions'] = [ordered]@{} }
    $perm = $s['permissions']

    $runnerDeny = Get-RunnerDenyRules $Config $HarnessProfile $Workspace
    $profileDeny = @(if ($perm.Contains('deny')) { $perm['deny'] })
    $deny = [Collections.Generic.List[string]]::new()
    foreach ($r in @($profileDeny) + @($runnerDeny)) { if ($r -and -not $deny.Contains($r)) { $deny.Add($r) } }
    # Runner rules last: profile-only rules first, runner rules in their fixed order after.
    $ordered = @($deny | Where-Object { $_ -notin $runnerDeny }) + @($runnerDeny)
    $perm['deny'] = [string[]]$ordered

    if ($perm.Contains('allow')) {
        $perm['allow'] = [string[]]@(@($perm['allow']) | Where-Object { -not (Test-AllowDenied $_ $runnerDeny) })
    }

    if ($HarnessProfile.McpMode -eq 'strict') { $s['disableClaudeAiConnectors'] = $true }
    elseif ($s.Contains('disableClaudeAiConnectors')) { $null = $s.Remove('disableClaudeAiConnectors') }

    $excl = @(if ($s.Contains('claudeMdExcludes')) { $s['claudeMdExcludes'] }) + (Get-AncestorClaudeMdExcludes $Workspace.Ws)
    $s['claudeMdExcludes'] = [string[]]@($excl | Select-Object -Unique)

    New-Item -ItemType Directory (Split-Path $path) -Force | Out-Null
    ConvertTo-Json $s -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $path
}

function Get-AuthSecret([string]$VarName) {
    if (-not $VarName) { throw 'auth: env var name not configured' }
    # User scope (set once with setx / System settings); process scope as fallback for CI.
    $v = [Environment]::GetEnvironmentVariable($VarName, 'User')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($VarName, 'Process') }
    if (-not $v) { throw "auth: env var $VarName is empty" }
    $v
}

# Returns the environment for agent calls. A key with a $null value means "remove this
# variable from the child process" (so an inherited credential cannot override auth mode).
function Get-AgentEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Alias('Profile')]$HarnessProfile, [Parameter(Mandatory)]$Workspace)

    $e = [ordered]@{
        CLAUDE_CONFIG_DIR                                  = $Workspace.ClaudeHome
        DISABLE_AUTOUPDATER                                = '1'
        CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL = '1'
    }
    switch ($Config.Auth.Mode) {
        'subscription' {
            $e['CLAUDE_CODE_OAUTH_TOKEN'] = Get-AuthSecret $Config.Auth.TokenEnvVar
            $e['ANTHROPIC_API_KEY'] = $null
        }
        'apiKey' {
            $e['ANTHROPIC_API_KEY'] = Get-AuthSecret $Config.Auth.ApiKeyEnvVar
            $e['CLAUDE_CODE_OAUTH_TOKEN'] = $null
        }
        default { throw "auth: invalid mode '$($Config.Auth.Mode)'" }
    }
    if ($HarnessProfile.McpMode -eq 'strict') { $e['ENABLE_CLAUDEAI_MCP_SERVERS'] = 'false' }
    $h = @{}
    foreach ($k in $e.Keys) { $h[$k] = $e[$k] }
    $h
}

Export-ModuleMember -Function New-RunWorkspace, Get-BenchProfile, Install-Profile, New-AgentSettings, Get-AgentEnvironment
