#Requires -Version 7.6
Set-StrictMode -Version Latest

# Collects every string inside tool_use inputs and tool_result contents of a stream-json transcript.
# Prompt text, assistant prose and system events are deliberately ignored.
function Get-TranscriptToolText([string]$Path) {
    $out = [System.Collections.Generic.List[object]]::new()
    $walk = {
        param($node, $tool, $kind)
        if ($null -eq $node) { return }
        if ($node -is [string]) { $out.Add([pscustomobject]@{ Tool = $tool; Kind = $kind; Text = $node }); return }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [System.Management.Automation.PSCustomObject]) {
            foreach ($i in $node) { & $walk $i $tool $kind }
            return
        }
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $node.PSObject.Properties) { & $walk $p.Value $tool $kind }
        }
    }
    $names = @{}
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $ev = $line | ConvertFrom-Json -Depth 50 } catch { continue }
        if ($null -eq $ev -or -not $ev.PSObject.Properties['message'] -or $null -eq $ev.message) { continue }
        $msg = $ev.message
        if (-not $msg.PSObject.Properties['content'] -or $msg.content -isnot [System.Collections.IEnumerable] -or $msg.content -is [string]) { continue }
        foreach ($b in $msg.content) {
            if ($b -isnot [System.Management.Automation.PSCustomObject] -or -not $b.PSObject.Properties['type']) { continue }
            if ($ev.type -eq 'assistant' -and $b.type -eq 'tool_use') {
                if ($b.PSObject.Properties['id']) { $names[[string]$b.id] = [string]$b.name }
                & $walk $b.input ([string]$b.name) 'tool_use'
            }
            elseif ($ev.type -eq 'user' -and $b.type -eq 'tool_result' -and $b.PSObject.Properties['content']) {
                $tool = if ($b.PSObject.Properties['tool_use_id'] -and $names.ContainsKey([string]$b.tool_use_id)) { $names[[string]$b.tool_use_id] } else { '' }
                & $walk $b.content $tool 'tool_result'
            }
        }
    }
    $out
}

# Lower-case, forward slashes, repeated slashes collapsed (so C:\\x, C:/x and //c/x compare equal).
function ConvertTo-FlatPath([string]$s) {
    ([regex]::Replace($s.Replace('\', '/'), '/{2,}', '/')).ToLowerInvariant()
}

# All textual spellings of a drive path: c:/x, /c/x (Git Bash), /mnt/c/x (WSL).
function Get-PathForms([string]$Path) {
    $flat = (ConvertTo-FlatPath $Path).TrimEnd('/')
    $forms = [System.Collections.Generic.List[string]]::new()
    $forms.Add($flat)
    if ($flat -match '^([a-z]):(/.*)?$') {
        $d = $Matches[1]; $rest = $Matches[2]
        $forms.Add("/$d$rest"); $forms.Add("/mnt/$d$rest")
    }
    $forms
}

function Get-TestCodeunitNames($Task) {
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $Task -or -not $Task.TestsDir -or -not (Test-Path -LiteralPath $Task.TestsDir)) { return @() }
    foreach ($f in Get-ChildItem -LiteralPath $Task.TestsDir -Recurse -File -Filter *.al) {
        foreach ($l in [IO.File]::ReadLines($f.FullName)) {
            if ($l -match '^\s*codeunit\s+\d+\s+(?:"([^"]+)"|([A-Za-z_][\w]*))') {
                $n = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                [void]$names.Add($n)
            }
        }
    }
    @($names)
}

function Test-TranscriptLeak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TranscriptPath,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Task,
        [string]$GraderDir
    )
    if (-not (Test-Path -LiteralPath $TranscriptPath)) { throw "Transcript not found: $TranscriptPath" }

    $patterns = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($kind, $paths)
        foreach ($p in $paths) { foreach ($f in (Get-PathForms $p)) { $patterns.Add([pscustomobject]@{ Kind = $kind; Pattern = $f; Flat = $true }) } }
    }
    & $add 'repo-root' @($Config.RepoRoot)
    if ($GraderDir) {
        & $add 'grader-dir' @($GraderDir)
        # Run-level _grader folder: <TempRoot>\<runId>\_grader
        $cur = $GraderDir.TrimEnd('\', '/')
        while ($cur -and (Split-Path $cur -Leaf) -ne '_grader') {
            $parent = Split-Path $cur -Parent
            if (-not $parent -or $parent -eq $cur) { $cur = $null; break }
            $cur = $parent
        }
        if ($cur) { & $add 'grader-root' @($cur) }
    }
    $patterns.Add([pscustomobject]@{ Kind = 'solution-folder'; Pattern = '/solution/'; Flat = $true })
    foreach ($n in Get-TestCodeunitNames $Task) {
        $patterns.Add([pscustomobject]@{ Kind = 'test-codeunit'; Pattern = $n.ToLowerInvariant(); Flat = $false })
    }

    $hits = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in Get-TranscriptToolText $TranscriptPath) {
        $flat = ConvertTo-FlatPath $t.Text
        $lower = $t.Text.ToLowerInvariant()
        foreach ($p in $patterns) {
            $hay = if ($p.Flat) { $flat } else { $lower }
            $i = $hay.IndexOf($p.Pattern, [StringComparison]::Ordinal)
            if ($i -lt 0) { continue }
            if (-not $seen.Add("$($p.Kind)|$($p.Pattern)|$($t.Tool)|$($t.Kind)")) { continue }
            $start = [Math]::Max(0, $i - 40)
            $excerpt = $hay.Substring($start, [Math]::Min(120, $hay.Length - $start))
            $hits.Add([pscustomobject]@{ Kind = $p.Kind; Pattern = $p.Pattern; Tool = $t.Tool; Source = $t.Kind; Excerpt = $excerpt })
        }
    }
    [pscustomobject]@{ Leaked = ($hits.Count -gt 0); Hits = @($hits) }
}

Export-ModuleMember -Function Test-TranscriptLeak
