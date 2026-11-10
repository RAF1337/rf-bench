#Requires -Version 7.6
Set-StrictMode -Version Latest

# Pure statistics over run records as parsed from run.json. Only 'done' task runs count.

function Get-Member2($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-AttemptScore {
    [CmdletBinding()]
    [OutputType([double])]
    param($FullyRightAttempt)
    if ($null -eq $FullyRightAttempt) { return [double]0 }
    [Math]::Max([double]0, (4 - [int]$FullyRightAttempt) / [double]3)
}

function Get-RunCostPerSolved($Run) {
    $cost = 0.0; $seen = $false; $solved = 0
    foreach ($t in $Run.tasks) {
        foreach ($a in @(Get-Member2 $t 'attempts')) {
            $c = Get-Member2 (Get-Member2 $a 'agent') 'CostUsd'
            if ($null -ne $c) { $cost += [double]$c; $seen = $true }
        }
        if ($t.status -eq 'done' -and $null -ne $t.fullyRightAttempt) { $solved++ }
    }
    if (-not $seen -or $solved -eq 0) { return $null }
    $cost / $solved
}

function Get-RunScores {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)
    $hashes = Get-Member2 (Get-Member2 $Run 'versions') 'tasks'
    $perTask = @{}
    $all = [System.Collections.Generic.List[double]]::new()
    foreach ($t in @($Run.tasks | Where-Object status -EQ 'done')) {
        if (-not $perTask.ContainsKey($t.taskId)) {
            $perTask[$t.taskId] = [pscustomobject]@{
                Hash = Get-Member2 $hashes $t.taskId
                Scores = [System.Collections.Generic.List[double]]::new()
                FirstTry = @{}
                Solved = [System.Collections.Generic.List[bool]]::new()
            }
        }
        $e = $perTask[$t.taskId]
        $s = Get-AttemptScore -FullyRightAttempt $t.fullyRightAttempt
        $e.Scores.Add($s); $all.Add($s)
        $e.FirstTry[[int]$t.repeat] = ($t.fullyRightAttempt -eq 1)
        $e.Solved.Add($null -ne $t.fullyRightAttempt)
    }
    $multi = @($perTask.Values | Where-Object { $_.Scores.Count -ge 2 })
    $passHat = $null
    if ($multi.Count -gt 0) {
        $passHat = @($multi | Where-Object { $_.Solved -notcontains $false }).Count / $multi.Count
    }
    foreach ($k in @($perTask.Keys)) {
        $e = $perTask[$k]
        $perTask[$k] = [pscustomobject]@{ Hash = $e.Hash; Scores = [double[]]$e.Scores; FirstTry = $e.FirstTry }
    }
    [pscustomobject]@{
        Auc3           = if ($all.Count) { ($all | Measure-Object -Average).Average } else { $null }
        PassHatK       = $passHat
        PassHatKTasks  = $multi.Count
        PerTask        = $perTask
        CostPerSolved  = Get-RunCostPerSolved $Run
    }
}

function Get-McNemarExactP {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$B, [Parameter(Mandatory)][int]$C)
    $n = $B + $C
    if ($n -eq 0) { return [double]1 }
    $k = [Math]::Min($B, $C)
    # Binomial(n, 0.5) tail, summed in log space so large n cannot overflow.
    $logC = 0.0; $tail = 0.0
    for ($i = 0; $i -le $k; $i++) {
        if ($i -gt 0) { $logC += [Math]::Log($n - $i + 1) - [Math]::Log($i) }
        $tail += [Math]::Exp($logC - $n * [Math]::Log(2))
    }
    [Math]::Min([double]1, [Math]::Round(2 * $tail, 12))
}

function Get-HolmAdjusted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double[]]$P)
    $m = $P.Count
    $order = 0..($m - 1) | Sort-Object { $P[$_] }
    $adj = [double[]]::new($m)
    $running = 0.0
    for ($r = 0; $r -lt $m; $r++) {
        $running = [Math]::Max($running, ($m - $r) * $P[$order[$r]])
        $adj[$order[$r]] = [Math]::Min([double]1, $running)
    }
    , $adj
}

function Get-BootstrapCi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double[]]$Diffs, [Parameter(Mandatory)][int]$Seed, [int]$Resamples = 10000)
    $rng = [System.Random]::new($Seed)
    $n = $Diffs.Count
    $means = [double[]]::new($Resamples)
    for ($r = 0; $r -lt $Resamples; $r++) {
        $sum = 0.0
        for ($i = 0; $i -lt $n; $i++) { $sum += $Diffs[$rng.Next($n)] }
        $means[$r] = $sum / $n
    }
    [Array]::Sort($means)
    [pscustomobject]@{
        Low  = $means[[int][Math]::Floor(0.025 * $Resamples)]
        High = $means[[int][Math]::Ceiling(0.975 * $Resamples) - 1]
    }
}

# Seed from the paired task set and hashes, so a changed task set gives a different but repeatable resample.
function Get-PairedSeed([string[]]$Lines) {
    $text = (@($Lines) | Sort-Object -CaseSensitive) -join "`n"
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
    [int][Math]::Min([Math]::Abs([long][BitConverter]::ToInt32($bytes, 0)), [int]::MaxValue)
}

function Get-Mean([double[]]$Values) { ($Values | Measure-Object -Average).Average }

function Get-PairedComparison {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Baseline, [Parameter(Mandatory)]$Candidate)
    $b = Get-RunScores -Run $Baseline
    $c = Get-RunScores -Run $Candidate
    $paired = [System.Collections.Generic.List[string]]::new()
    $excluded = [System.Collections.Generic.List[string]]::new()
    $unknown = $false
    foreach ($id in @($b.PerTask.Keys + $c.PerTask.Keys | Sort-Object -Unique)) {
        if (-not ($b.PerTask.ContainsKey($id) -and $c.PerTask.ContainsKey($id))) { $excluded.Add("$id (missing)"); continue }
        $hb = $b.PerTask[$id].Hash; $hc = $c.PerTask[$id].Hash
        if ($null -eq $hb -or $null -eq $hc) { $unknown = $true }
        elseif ($hb -ne $hc) { $excluded.Add("$id (hash differs)"); continue }
        $paired.Add($id)
    }
    $diffs = [double[]]@($paired | ForEach-Object { (Get-Mean $c.PerTask[$_].Scores) - (Get-Mean $b.PerTask[$_].Scores) })
    $nb = 0; $nc = 0
    foreach ($id in $paired) {
        foreach ($rep in $b.PerTask[$id].FirstTry.Keys) {
            if (-not $c.PerTask[$id].FirstTry.ContainsKey($rep)) { continue }
            $pb = $b.PerTask[$id].FirstTry[$rep]; $pc = $c.PerTask[$id].FirstTry[$rep]
            if ($pb -and -not $pc) { $nb++ } elseif ($pc -and -not $pb) { $nc++ }
        }
    }
    $mean = $null; $lo = $null; $hi = $null; $verdict = 'too few tasks'
    if ($paired.Count -gt 0) {
        $mean = Get-Mean $diffs
        $seed = Get-PairedSeed ($paired | ForEach-Object { '{0}:{1}' -f $_, $b.PerTask[$_].Hash })
        $ci = Get-BootstrapCi -Diffs $diffs -Seed $seed
        $lo = $ci.Low; $hi = $ci.High
        if ($paired.Count -ge 10) {
            $verdict = if ($lo -gt 0) { 'better' } elseif ($hi -lt 0) { 'worse' } else { 'no clear difference' }
        }
    }
    [pscustomobject]@{
        PairedTasks = $paired.Count; ExcludedTasks = [string[]]$excluded
        MeanDiff = $mean; CiLow = $lo; CiHigh = $hi
        McNemarB = $nb; McNemarC = $nc; McNemarP = Get-McNemarExactP -B $nb -C $nc
        Verdict = $verdict; HashesUnknown = $unknown
    }
}

Export-ModuleMember -Function Get-AttemptScore, Get-RunScores, Get-PairedComparison, Get-McNemarExactP, Get-HolmAdjusted, Get-BootstrapCi
