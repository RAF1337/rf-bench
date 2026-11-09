#Requires -Version 7.6
<#
.SYNOPSIS
    Renders one static HTML page that compares benchmark runs (one column per run).

.DESCRIPTION
    Reads results/<runId>/run.json for every run and writes a single HTML file with inline CSS
    and inline SVG (no scripts, no external resources), light and dark via prefers-color-scheme.

    Percentages and average attempts count only task runs with status 'done'. Invalid, aborted
    and pending task runs are excluded from them but counted and shown. Cost, token, time and
    turn totals include every recorded attempt (also of aborted and invalid task runs), since
    that spend is real. Cost is labelled "estimated" when the run used a subscription.
    Analyzer warnings and failed checks come from the last graded attempt of each counted task run.

.EXAMPLE
    pwsh src/New-Report.ps1 -Runs 20261104-101500-baseline,20261104-111500-example-rules
.EXAMPLE
    pwsh src/New-Report.ps1 -Runs results/x/run.json -Out C:\temp\report.html
#>
[CmdletBinding()]
param(
    # Run ids (folders under -ResultsRoot), run folders or run.json paths. "a,b" is split.
    [Parameter(Mandatory)][string[]]$Runs,
    [string]$Out,
    [string]$ResultsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $ResultsRoot) { $ResultsRoot = Join-Path $repoRoot 'results' }
if (-not $Out) { $Out = Join-Path $ResultsRoot 'report.html' }

$inv = [Globalization.CultureInfo]::InvariantCulture
$categories = @('data-access', 'locking-isolation', 'transactions', 'architecture', 'naming-style', 'ui', 'error-handling')
$maxChartSeries = 8

# --- helpers -------------------------------------------------------------------------------------

function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Name/value pairs of a JSON object or dictionary.
function Get-Pairs($Obj) {
    if ($null -eq $Obj) { return }
    if ($Obj -is [System.Collections.IDictionary]) { foreach ($k in $Obj.Keys) { [pscustomobject]@{ Name = [string]$k; Value = $Obj[$k] } } }
    else { foreach ($p in $Obj.PSObject.Properties) { [pscustomobject]@{ Name = $p.Name; Value = $p.Value } } }
}

function E($Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }

function Format-Pct($Count, $Total) {
    if ($Total -le 0) { return 'n/a' }
    ([math]::Round(100.0 * $Count / $Total, 1)).ToString('0.#', $inv) + '%'
}

function Format-Num($Value, [string]$Format = 'N0') {
    if ($null -eq $Value) { return 'n/a' }
    ([double]$Value).ToString($Format, $inv)
}

function Join-OrNone($Items) {
    $list = @($Items | Where-Object { $_ })
    if ($list.Count) { $list -join ', ' } else { 'none' }
}

function Resolve-RunJson([string]$Ref) {
    if (Test-Path -LiteralPath $Ref -PathType Leaf) { return (Resolve-Path -LiteralPath $Ref).Path }
    if (Test-Path -LiteralPath (Join-Path $Ref 'run.json') -PathType Leaf) { return (Resolve-Path -LiteralPath (Join-Path $Ref 'run.json')).Path }
    $p = Join-Path $ResultsRoot (Join-Path $Ref 'run.json')
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    throw "run '$Ref' not found (looked for $p)"
}

# Short text for one attempt's outcome.
function Get-AttemptOutcome($Attempt) {
    $g = Get-Prop $Attempt 'grade'
    if ($null -eq $g) {
        $reason = Get-Prop (Get-Prop $Attempt 'agent') 'AbortReason'
        return $(if ($reason) { "not graded ($reason)" } else { 'not graded' })
    }
    if (-not (Get-Prop $g 'Compiled')) { return 'compile failed' }
    if (-not (Get-Prop $g 'TestsPassed')) { return 'tests failed' }
    if (-not (Get-Prop $g 'BudgetsPassed')) { return 'budgets failed' }
    if (-not (Get-Prop $g 'ChecksPassed')) { return 'checks failed' }
    'fully right'
}

# --- per-run statistics --------------------------------------------------------------------------

function Get-RunStats($Run, [int]$Index) {
    $tasks = @(Get-Prop $Run 'tasks' | Where-Object { $null -ne $_ })
    $counted = @($tasks | Where-Object { $_.status -eq 'done' })
    $n = $counted.Count
    $allAttempts = @($tasks | ForEach-Object { @(Get-Prop $_ 'attempts') } | Where-Object { $null -ne $_ })
    $countedAttempts = @($counted | ForEach-Object { @(Get-Prop $_ 'attempts') } | Where-Object { $null -ne $_ })

    function Sum-Agent($Attempts, [string]$Field) {
        $vals = @($Attempts | ForEach-Object { Get-Prop (Get-Prop $_ 'agent') $Field } | Where-Object { $null -ne $_ })
        if ($vals.Count -eq 0) { return $null }
        ($vals | ForEach-Object { [double]$_ } | Measure-Object -Sum).Sum
    }
    function Mean-Of($Sum) { if ($null -eq $Sum -or $n -eq 0) { $null } else { $Sum / $n } }

    $fr = @{}; $tp = @{}
    foreach ($k in 1..3) {
        $fr[$k] = @($counted | Where-Object { $null -ne $_.fullyRightAttempt -and [int]$_.fullyRightAttempt -le $k }).Count
        $tp[$k] = @($counted | Where-Object { $null -ne $_.firstTestsPassAttempt -and [int]$_.firstTestsPassAttempt -le $k }).Count
    }
    $unsolved = @($counted | Where-Object { $null -eq $_.fullyRightAttempt }).Count
    $attemptSum = ($counted | ForEach-Object { if ($null -ne $_.fullyRightAttempt) { [int]$_.fullyRightAttempt } else { 4 } } | Measure-Object -Sum).Sum

    $aborted = @($tasks | Where-Object { $_.status -eq 'aborted' })
    $abortReasons = @($aborted | Group-Object { if ($_.abortReason) { [string]$_.abortReason } else { 'unknown' } } | Sort-Object Name |
            ForEach-Object { "$($_.Name) $($_.Count)" })

    # Final graded attempt of every counted task run.
    $finalGrades = @(foreach ($t in $counted) {
            $g = @(@(Get-Prop $t 'attempts') | Where-Object { $null -ne $_ -and $null -ne (Get-Prop $_ 'grade') }) | Select-Object -Last 1
            if ($g) { $g.grade }
        })
    $warnings = [ordered]@{}
    foreach ($g in $finalGrades) {
        foreach ($p in @(Get-Pairs (Get-Prop $g 'AnalyzerWarnings'))) {
            $warnings[$p.Name] = [int]$(if ($warnings.Contains($p.Name)) { $warnings[$p.Name] } else { 0 }) + [int]$p.Value
        }
    }
    $failedChecks = @{}
    foreach ($g in $finalGrades) {
        foreach ($f in @(Get-Prop $g 'Findings' | Where-Object { $null -ne $_ -and -not (Get-Prop $_ 'Passed') })) {
            $c = [string](Get-Prop $f 'Category')
            $failedChecks[$c] = 1 + $(if ($failedChecks.ContainsKey($c)) { $failedChecks[$c] } else { 0 })
        }
    }

    # MCP: servers the agent saw (last status wins), servers found by Claude, MCP tool calls.
    $available = [ordered]@{}
    $found = [Collections.Generic.List[string]]::new()
    $toolCalls = @{}
    foreach ($a in $allAttempts) {
        foreach ($s in @(Get-Prop (Get-Prop $a 'agent') 'McpServers' | Where-Object { $null -ne $_ })) {
            $available[[string](Get-Prop $s 'Name')] = [string](Get-Prop $s 'Status')
        }
        foreach ($f in @(Get-Prop (Get-Prop $a 'mcp') 'foundByClaude' | Where-Object { $_ })) { if (-not $found.Contains([string]$f)) { $found.Add([string]$f) } }
        foreach ($u in @(Get-Prop (Get-Prop $a 'agent') 'ToolUses' | Where-Object { $null -ne $_ })) {
            $tool = [string](Get-Prop $u 'Tool')
            if ($tool -like 'mcp__*') { $toolCalls[$tool] = [int](Get-Prop $u 'Count') + $(if ($toolCalls.ContainsKey($tool)) { $toolCalls[$tool] } else { 0 }) }
        }
    }

    $mcp = Get-Prop $Run 'mcp'
    $versions = Get-Prop $Run 'versions'
    $compiler = Get-Prop $versions 'compiler'
    $profileObj = Get-Prop $Run 'profile'
    $cost = Sum-Agent $allAttempts 'CostUsd'
    $duration = Sum-Agent $allAttempts 'DurationMs'
    $turns = Sum-Agent $allAttempts 'Turns'
    [pscustomobject]@{
        Index           = $Index
        Run             = $Run
        RunId           = [string](Get-Prop $Run 'runId')
        Profile         = [string](Get-Prop $profileObj 'name')
        Estimated       = [string](Get-Prop (Get-Prop $Run 'auth') 'mode') -eq 'subscription'
        Tasks           = $tasks
        Counted         = $n
        Fr              = $fr
        Tp              = $tp
        Unsolved        = $unsolved
        AvgAttempts     = $(if ($n) { $attemptSum / $n } else { $null })
        Aborted         = $aborted.Count
        AbortReasons    = $abortReasons
        Invalid         = @($tasks | Where-Object { $_.status -eq 'invalid' }).Count
        Pending         = @($tasks | Where-Object { $_.status -eq 'pending' }).Count
        CostTotal       = $cost
        CostMean        = Mean-Of (Sum-Agent $countedAttempts 'CostUsd')
        InputTokens     = Sum-Agent $allAttempts 'InputTokens'
        OutputTokens    = Sum-Agent $allAttempts 'OutputTokens'
        CacheReadTokens = Sum-Agent $allAttempts 'CacheReadTokens'
        DurationMin     = $(if ($null -ne $duration) { $duration / 60000 } else { $null })
        DurationMeanMin = $(if ($null -ne ($d = Mean-Of (Sum-Agent $countedAttempts 'DurationMs'))) { $d / 60000 } else { $null })
        Turns           = $turns
        TurnsMean       = Mean-Of (Sum-Agent $countedAttempts 'Turns')
        Warnings        = $warnings
        FailedChecks    = $failedChecks
        McpAllowed      = @(Get-Prop $mcp 'allowed' | Where-Object { $_ })
        McpAvailable    = $available
        McpFound        = @($found)
        McpToolCalls    = $toolCalls
        # versions.plugins ('name@marketplace' -> version) when present; older runs only list
        # installedPlugins, which carry no comparable version.
        PluginVersions  = Get-Prop $versions 'plugins'
        Plugins         = $(if ($null -ne (Get-Prop $versions 'plugins')) {
                @(Get-Pairs (Get-Prop $versions 'plugins') | ForEach-Object { if ($null -ne $_.Value -and "$($_.Value)" -ne '') { "$($_.Name) $($_.Value)" } else { $_.Name } })
            }
            else { @(Get-Prop $mcp 'installedPlugins' | Where-Object { $_ }) })
        CliVersion      = Get-Prop $versions 'cli'
        BcArtifact      = Get-Prop $versions 'bcArtifact'
        Compiler        = $(if ($compiler -is [string]) { $compiler } else { Get-Prop $compiler 'version' })
        McpVersions     = Get-Prop $versions 'mcp'
    }
}

# --- version comparison --------------------------------------------------------------------------

# One entry per dimension whose non-empty values differ between runs.
function Get-VersionMismatches($Stats) {
    if (@($Stats).Count -lt 2) { return @() }
    # Per run: label -> value. Named components (MCP servers, plugins) are compared only between
    # runs that have them.
    $perRun = foreach ($s in $Stats) {
        $v = [ordered]@{ 'Claude CLI' = $s.CliVersion; 'BC artifact' = $s.BcArtifact; 'AL compiler' = $s.Compiler }
        foreach ($p in @(Get-Pairs $s.McpVersions)) { $v["MCP $($p.Name)"] = $p.Value }
        foreach ($p in @(Get-Pairs $s.PluginVersions)) { $v["Plugin $($p.Name)"] = $p.Value }
        [pscustomobject]@{ Stats = $s; Values = $v }
    }
    $labels = [Collections.Generic.List[string]]::new()
    foreach ($r in $perRun) { foreach ($k in $r.Values.Keys) { if (-not $labels.Contains($k)) { $labels.Add($k) } } }
    foreach ($label in $labels) {
        $vals = @(foreach ($r in $perRun) {
                $v = $r.Values[$label]
                if ($null -ne $v -and [string]$v -ne '') { [pscustomobject]@{ Stats = $r.Stats; Value = [string]$v } }
            })
        if (@($vals.Value | Sort-Object -Unique).Count -gt 1) { [pscustomobject]@{ Label = $label; Values = $vals } }
    }
}

# --- chart ---------------------------------------------------------------------------------------

# Horizontal grouped bars: one group per attempt threshold, one bar per run (series = run order).
function New-BarChart([string]$Title, [string]$Key, $Stats) {
    $runs = @($Stats)
    $sb = [Text.StringBuilder]::new()
    $null = $sb.Append("<figure class=""chart""><figcaption>$(E $Title)</figcaption>")
    if ($runs.Count -gt $maxChartSeries) {
        $null = $sb.Append("<p class=""note"">Chart omitted for more than $maxChartSeries runs; see the table.</p></figure>")
        return $sb.ToString()
    }
    if ($runs.Count -ge 2) {
        $null = $sb.Append('<ul class="legend">')
        foreach ($s in $runs) { $null = $sb.Append("<li><span class=""swatch"" style=""background:var(--s$($s.Index + 1))""></span>$(E $s.Profile) <span class=""muted"">$(E $s.RunId)</span></li>") }
        $null = $sb.Append('</ul>')
    }
    $labelW = 112; $plotX = 120; $plotW = 440; $barH = 14; $gap = 2; $groupGap = 18; $top = 6; $axisH = 22; $width = 620
    $groupH = $runs.Count * $barH + ($runs.Count - 1) * $gap
    $height = $top + 3 * $groupH + 2 * $groupGap + $axisH
    $groups = @('Attempt 1', 'Within 2 attempts', 'Within 3 attempts')
    $summary = @(foreach ($s in $runs) { "$($s.Profile): " + ((1..3 | ForEach-Object { Format-Pct (($s.$Key)[$_]) $s.Counted }) -join ' / ') }) -join '; '
    $null = $sb.Append("<svg viewBox=""0 0 $width $height"" role=""img"" aria-label=""$(E "$Title. $summary")"">")
    foreach ($t in 0, 25, 50, 75, 100) {
        $x = $plotX + $plotW * $t / 100
        $null = $sb.Append("<line class=""grid"" x1=""$x"" x2=""$x"" y1=""$top"" y2=""$($height - $axisH + 2)""/>")
        $null = $sb.Append("<text class=""tick"" x=""$x"" y=""$($height - 6)"" text-anchor=""middle"">$t%</text>")
    }
    for ($gi = 0; $gi -lt 3; $gi++) {
        $gy = $top + $gi * ($groupH + $groupGap)
        $null = $sb.Append("<text class=""glabel"" x=""$($labelW - 4)"" y=""$($gy + $groupH / 2 + 4)"" text-anchor=""end"">$($groups[$gi])</text>")
        foreach ($s in $runs) {
            $y = $gy + $s.Index * ($barH + $gap)
            $label = Format-Pct (($s.$Key)[$gi + 1]) $s.Counted
            $null = $sb.Append("<g class=""bar"" tabindex=""0""><title>$(E "$($s.Profile) ($($s.RunId)), $($groups[$gi].ToLowerInvariant()): $label")</title>")
            $null = $sb.Append("<rect class=""hit"" x=""$plotX"" y=""$($y - 1)"" width=""$($plotW + 50)"" height=""$($barH + 2)""/>")
            $w = 0
            if ($s.Counted -gt 0) { $w = [math]::Round($plotW * ($s.$Key)[$gi + 1] / $s.Counted, 1) }
            if ($w -gt 0) {
                $x1 = $plotX + $w; $r = [math]::Min(4, $w)
                $d = "M$plotX $y H$($x1 - $r) Q$x1 $y $x1 $($y + $r) V$($y + $barH - $r) Q$x1 $($y + $barH) $($x1 - $r) $($y + $barH) H$plotX Z"
                $null = $sb.Append("<path d=""$d"" style=""fill:var(--s$($s.Index + 1))""/>")
            }
            $null = $sb.Append("<text class=""val"" x=""$($plotX + $w + 6)"" y=""$($y + $barH - 3)"">$label</text></g>")
        }
    }
    $null = $sb.Append("<line class=""axis"" x1=""$plotX"" x2=""$plotX"" y1=""$top"" y2=""$($height - $axisH + 2)""/></svg></figure>")
    $sb.ToString()
}

# --- HTML ----------------------------------------------------------------------------------------

function Add-Row([Text.StringBuilder]$Sb, [string]$Label, $Stats, [string]$Metric, [scriptblock]$Cell, [string]$Class = '') {
    $cls = if ($Class) { " class=""$Class""" } else { '' }
    $null = $Sb.Append("<tr$cls><th scope=""row"">$Label</th>")
    foreach ($s in $Stats) {
        $null = $Sb.Append("<td data-run=""$($s.Index)"" data-metric=""$(E $Metric)"">$(& $Cell $s)</td>")
    }
    $null = $Sb.Append('</tr>')
}

function Add-TableStart([Text.StringBuilder]$Sb, [string]$Id, [string]$Caption, $Stats, [string]$Corner = 'Metric') {
    $null = $Sb.Append("<div class=""tw""><table id=""$Id""><caption>$Caption</caption><thead><tr><th scope=""col"">$Corner</th>")
    foreach ($s in $Stats) { $null = $Sb.Append("<th scope=""col"">$(E $s.Profile)<br><span class=""muted"">$(E $s.RunId)</span></th>") }
    $null = $Sb.Append('</tr></thead><tbody>')
}

function Add-TableEnd([Text.StringBuilder]$Sb) { $null = $Sb.Append('</tbody></table></div>') }

$css = @'
:root {
  color-scheme: light;
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --ring: rgba(11,11,11,0.10); --warn-bg: #fdf3dc; --warn-ink: #5c4300;
  --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --s4: #eda100; --s5: #e87ba4; --s6: #008300; --s7: #6250d6; --s8: #e34948;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --ring: rgba(255,255,255,0.10); --warn-bg: #3a2e0c; --warn-ink: #fbe3a6;
    --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7; --muted: #898781;
  --grid: #2c2c2a; --axis: #383835; --ring: rgba(255,255,255,0.10); --warn-bg: #3a2e0c; --warn-ink: #fbe3a6;
  --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1200px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 17px; margin: 32px 0 8px; }
p { margin: 4px 0; } .muted { color: var(--muted); font-size: 12px; } .note { color: var(--ink-2); font-size: 13px; }
.banner { background: var(--warn-bg); color: var(--warn-ink); border-radius: 8px; padding: 12px 16px; margin: 16px 0; }
.banner strong { display: block; margin-bottom: 4px; } .banner ul { margin: 0; padding-left: 20px; }
.charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; }
.chart { margin: 0; background: var(--surface); border-radius: 8px; box-shadow: 0 0 0 1px var(--ring); padding: 12px 16px; }
.chart figcaption { font-weight: 600; margin-bottom: 6px; }
.chart svg { display: block; width: 100%; height: auto; }
.legend { list-style: none; margin: 0 0 6px; padding: 0; display: flex; flex-wrap: wrap; gap: 4px 16px; color: var(--ink-2); font-size: 12px; }
.swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: -1px; }
.grid { stroke: var(--grid); stroke-width: 1; } .axis { stroke: var(--axis); stroke-width: 1; }
.tick, .val { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
.val { fill: var(--ink-2); } .glabel { fill: var(--ink-2); font-size: 12px; }
.hit { fill: transparent; } .bar:hover path, .bar:focus path { opacity: 0.8; } .bar:focus { outline: none; }
.bar:focus .hit { stroke: var(--axis); }
.tw { overflow-x: auto; background: var(--surface); border-radius: 8px; box-shadow: 0 0 0 1px var(--ring); margin: 8px 0; }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
caption { text-align: left; padding: 10px 12px 4px; font-weight: 600; }
th, td { text-align: left; vertical-align: top; padding: 6px 12px; border-top: 1px solid var(--grid); }
thead th { border-top: none; font-weight: 600; }
tbody th { font-weight: 400; color: var(--ink-2); white-space: nowrap; }
tr.sub th { padding-left: 24px; }
.tag { font-size: 11px; color: var(--ink-2); border: 1px solid var(--axis); border-radius: 4px; padding: 0 4px; margin-left: 4px; }
ol.att { margin: 2px 0 0; padding-left: 18px; } .excerpt { font-family: ui-monospace, Consolas, monospace; font-size: 12px; word-break: break-all; }
'@

# --- main ----------------------------------------------------------------------------------------

$refs = @($Runs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $refs) { throw 'no runs given' }
$stats = @(for ($i = 0; $i -lt $refs.Count; $i++) {
        $path = Resolve-RunJson $refs[$i]
        $run = try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 -DateKind String } catch { throw "invalid run.json ${path}: $($_.Exception.Message)" }
        Get-RunStats $run $i
    })

$sb = [Text.StringBuilder]::new()
$null = $sb.Append("<!doctype html><html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1"">")
$null = $sb.Append("<title>rf-bench report</title><style>$css</style></head><body><main>")
$null = $sb.Append("<h1>rf-bench report</h1><p class=""muted"">Generated $(E ([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm', $inv))) UTC from $($stats.Count) run(s).</p>")

$mismatches = @(Get-VersionMismatches $stats)
if ($mismatches.Count) {
    $null = $sb.Append('<div class="banner" id="version-mismatch" role="alert"><strong>Versions differ between the compared runs; results may not be comparable.</strong><ul>')
    foreach ($m in $mismatches) {
        $vals = ($m.Values | ForEach-Object { "$(E $_.Value) ($(E $_.Stats.Profile), $(E $_.Stats.RunId))" }) -join '; '
        $null = $sb.Append("<li>$(E $m.Label): $vals</li>")
    }
    $null = $sb.Append('</ul></div>')
}

# Overview charts (the tables below carry every value).
$null = $sb.Append('<h2>Overview</h2><p class="note">Share of counted task runs (status done). Invalid, aborted and pending task runs are excluded.</p><div class="charts">')
$null = $sb.Append((New-BarChart 'Fully right' 'Fr' $stats))
$null = $sb.Append((New-BarChart 'Tests passed' 'Tp' $stats))
$null = $sb.Append('</div>')

# Runs
$null = $sb.Append('<h2>Runs</h2>')
Add-TableStart $sb 'runs' 'Run settings and versions' $stats 'Setting'
Add-Row $sb 'Model' $stats 'model' { param($s) E (Get-Prop $s.Run 'model') }
Add-Row $sb 'Max turns' $stats 'maxTurns' { param($s) E (Get-Prop $s.Run 'maxTurns') }
Add-Row $sb 'Auth mode' $stats 'authMode' { param($s) E (Get-Prop (Get-Prop $s.Run 'auth') 'mode') }
Add-Row $sb 'MCP mode' $stats 'mcpMode' { param($s) E (Get-Prop (Get-Prop $s.Run 'mcp') 'mode') }
Add-Row $sb 'Web access' $stats 'allowWeb' { param($s) if (Get-Prop (Get-Prop $s.Run 'profile') 'allowWeb') { 'allowed' } else { 'denied' } }
Add-Row $sb 'Started (UTC)' $stats 'started' { param($s) E (Get-Prop $s.Run 'startedUtc') }
Add-Row $sb 'Profile hash' $stats 'profileHash' { param($s) $h = [string](Get-Prop (Get-Prop $s.Run 'profile') 'hash'); E $h.Substring(0, [math]::Min(12, $h.Length)) }
Add-Row $sb 'Claude CLI' $stats 'cli' { param($s) E (Join-OrNone @($s.CliVersion)) }
Add-Row $sb 'BC artifact' $stats 'bcArtifact' { param($s) E (Join-OrNone @($s.BcArtifact)) }
Add-Row $sb 'AL compiler' $stats 'compiler' { param($s) E (Join-OrNone @($s.Compiler)) }
Add-Row $sb 'Plugins' $stats 'plugins' { param($s) E (Join-OrNone $s.Plugins) }
Add-TableEnd $sb

# Results
$null = $sb.Append('<h2>Results</h2>')
Add-TableStart $sb 'results' 'Outcomes (percentages over counted task runs)' $stats
Add-Row $sb 'Task runs' $stats 'taskRuns' { param($s) $s.Tasks.Count }
Add-Row $sb 'Counted (done)' $stats 'counted' { param($s) $s.Counted }
Add-Row $sb 'Aborted (excluded)' $stats 'aborted' { param($s) if ($s.Aborted) { E "$($s.Aborted) ($($s.AbortReasons -join ', '))" } else { '0' } }
Add-Row $sb 'Invalid (excluded)' $stats 'invalid' { param($s) $s.Invalid }
Add-Row $sb 'Pending (excluded)' $stats 'pending' { param($s) $s.Pending }
foreach ($k in 1..3) {
    $lbl = if ($k -eq 1) { 'Fully right at attempt 1' } else { "Fully right within $k attempts" }
    Add-Row $sb $lbl $stats "fr$k" { param($s) Format-Pct $s.Fr[$k] $s.Counted }
}
foreach ($k in 1..3) {
    $lbl = if ($k -eq 1) { 'Tests passed at attempt 1' } else { "Tests passed within $k attempts" }
    Add-Row $sb $lbl $stats "tp$k" { param($s) Format-Pct $s.Tp[$k] $s.Counted }
}
Add-Row $sb 'Average attempts to fully right' $stats 'avgAttempts' {
    param($s)
    if ($null -eq $s.AvgAttempts) { return 'n/a' }
    $v = ([double]$s.AvgAttempts).ToString('0.##', $inv)
    if ($s.Unsolved) { "$v <span class=""tag"">$($s.Unsolved) unsolved counted as 4</span>" } else { $v }
}
Add-TableEnd $sb

# Cost and usage
$null = $sb.Append('<h2>Cost and usage</h2><p class="note">Totals include every recorded attempt, also of aborted and invalid task runs. Means are per counted task run. Cost is estimated by Claude Code when the run used a subscription.</p>')
Add-TableStart $sb 'usage' 'Cost, tokens, time and turns' $stats
$estimated = { param($s, $text) if ($s.Estimated -and $text -ne 'n/a') { "$text <span class=""tag"">estimated</span>" } else { $text } }
Add-Row $sb 'Cost total' $stats 'costTotal' { param($s) & $estimated $s $(if ($null -ne $s.CostTotal) { (Format-Num $s.CostTotal 'N2') + ' USD' } else { 'n/a' }) }
Add-Row $sb 'Cost per task run' $stats 'costPerTask' { param($s) & $estimated $s $(if ($null -ne $s.CostMean) { (Format-Num $s.CostMean 'N2') + ' USD' } else { 'n/a' }) }
Add-Row $sb 'Input tokens' $stats 'inputTokens' { param($s) Format-Num $s.InputTokens }
Add-Row $sb 'Output tokens' $stats 'outputTokens' { param($s) Format-Num $s.OutputTokens }
Add-Row $sb 'Cache read tokens' $stats 'cacheReadTokens' { param($s) Format-Num $s.CacheReadTokens }
Add-Row $sb 'Time total (min)' $stats 'time' { param($s) Format-Num $s.DurationMin 'N1' }
Add-Row $sb 'Time per task run (min)' $stats 'timePerTask' { param($s) Format-Num $s.DurationMeanMin 'N1' }
Add-Row $sb 'Turns total' $stats 'turns' { param($s) Format-Num $s.Turns }
Add-Row $sb 'Turns per task run' $stats 'turnsPerTask' { param($s) Format-Num $s.TurnsMean 'N1' }
Add-TableEnd $sb

# Code quality
$null = $sb.Append('<h2>Code quality</h2><p class="note">From the last graded attempt of each counted task run. Analyzer warnings are reported only; failed checks count failing findings.</p>')
Add-TableStart $sb 'checks' 'Failed checks per category' $stats 'Category'
$extraCats = @($stats | ForEach-Object { $_.FailedChecks.Keys } | Where-Object { $_ -notin $categories } | Sort-Object -Unique)
foreach ($c in @($categories) + $extraCats) {
    Add-Row $sb (E $c) $stats "checks:$c" { param($s) if ($s.FailedChecks.ContainsKey($c)) { $s.FailedChecks[$c] } else { 0 } }
}
Add-TableEnd $sb
$rules = @($stats | ForEach-Object { $_.Warnings.Keys } | Sort-Object -Unique)
Add-TableStart $sb 'warnings' 'Analyzer warnings per rule' $stats 'Rule'
if ($rules.Count) {
    foreach ($r in $rules) { Add-Row $sb (E $r) $stats "warn:$r" { param($s) if ($s.Warnings.Contains($r)) { $s.Warnings[$r] } else { 0 } } }
}
else { Add-Row $sb 'No warnings' $stats 'warn:none' { param($s) '0' } }
Add-TableEnd $sb

# MCP
$null = $sb.Append('<h2>MCP</h2><p class="note">Found by Claude: servers the agent saw that the profile did not allow (for example claude.ai connectors in open mode).</p>')
Add-TableStart $sb 'mcp' 'MCP servers and tool calls' $stats 'Item'
Add-Row $sb 'Allowed' $stats 'mcpAllowed' { param($s) E (Join-OrNone $s.McpAllowed) }
Add-Row $sb 'Available' $stats 'mcpAvailable' { param($s) E (Join-OrNone @($s.McpAvailable.GetEnumerator() | ForEach-Object { if ($_.Value) { "$($_.Key) ($($_.Value))" } else { $_.Key } })) }
Add-Row $sb 'Found by Claude' $stats 'mcpFound' { param($s) E (Join-OrNone $s.McpFound) }
$mcpTools = @($stats | ForEach-Object { $_.McpToolCalls.Keys } | Sort-Object -Unique)
foreach ($t in $mcpTools) {
    Add-Row $sb (E $t) $stats "mcpTool:$t" { param($s) if ($s.McpToolCalls.ContainsKey($t)) { $s.McpToolCalls[$t] } else { 0 } } 'sub'
}
if (-not $mcpTools.Count) { Add-Row $sb 'MCP tool calls' $stats 'mcpTool:none' { param($s) '0' } }
Add-TableEnd $sb

# Per task
$null = $sb.Append('<h2>Per task</h2>')
$keys = @($stats | ForEach-Object { $_.Tasks } | ForEach-Object { [pscustomobject]@{ Id = [string]$_.taskId; Rep = [int]$_.repeat } } |
        Sort-Object Id, Rep -Unique)
Add-TableStart $sb 'per-task' 'Attempt outcomes per task run' $stats 'Task / repeat'
foreach ($key in $keys) {
    $label = "$($key.Id)/$($key.Rep)"
    Add-Row $sb (E $label) $stats "task:$label" {
        param($s)
        $t = @($s.Tasks | Where-Object { [string]$_.taskId -ceq $key.Id -and [int]$_.repeat -eq $key.Rep }) | Select-Object -First 1
        if (-not $t) { return 'not run' }
        $status = [string]$t.status
        $head = switch ($status) {
            'aborted' { "aborted ($(if ($t.abortReason) { $t.abortReason } else { 'unknown' }))" }
            'invalid' { 'invalid (excluded)' }
            'done' { if ($null -ne $t.fullyRightAttempt) { "done, fully right at $($t.fullyRightAttempt)" } else { 'done, not fully right' } }
            default { $status }
        }
        $html = "<strong>$(E $head)</strong>"
        $atts = @(Get-Prop $t 'attempts' | Where-Object { $null -ne $_ })
        if ($atts.Count) {
            $cost = @($atts | ForEach-Object { Get-Prop (Get-Prop $_ 'agent') 'CostUsd' } | Where-Object { $null -ne $_ })
            $html += '<ol class="att">' + (($atts | ForEach-Object { "<li>$(E (Get-AttemptOutcome $_))</li>" }) -join '') + '</ol>'
            if ($cost.Count) {
                $c = (Format-Num (($cost | Measure-Object -Sum).Sum) 'N2') + ' USD'
                $html += "<span class=""muted"">$c</span>$(if ($s.Estimated) { ' <span class="tag">estimated</span>' })"
            }
        }
        $err = Get-Prop $t 'error'
        if ($err) { $html += "<div class=""excerpt"">$(E $err)</div>" }
        foreach ($h in @(Get-Prop (Get-Prop $t 'leak') 'hits' | Where-Object { $null -ne $_ })) {
            $what = "$(Get-Prop $h 'Kind') via $(Get-Prop $h 'Tool') ($(Get-Prop $h 'Source'))"
            $html += "<div class=""excerpt"">$(E $what): $(E (Get-Prop $h 'Excerpt'))</div>"
        }
        $html
    }
}
Add-TableEnd $sb

$null = $sb.Append('</main></body></html>')

$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
Set-Content -LiteralPath $Out -Value $sb.ToString() -Encoding utf8NoBOM -NoNewline
(Resolve-Path -LiteralPath $Out).Path
