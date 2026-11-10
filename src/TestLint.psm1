#Requires -Version 7.6
# Text-based lint of a task's hidden AL tests: finds tests that assert nothing, exit before
# asserting, or use random/current-time data. Deliberately regex based (comments and strings
# stripped, line numbers kept) so it needs no parser DLL and no config.
Set-StrictMode -Version Latest

# Replaces comments and single-quoted string literals with spaces, keeping every newline, so
# line numbers survive. Double-quoted identifiers are copied untouched (but skipped, so an
# apostrophe inside one cannot open a string). AL doubles '' inside a string, which a plain
# close-then-reopen handles.
function Remove-AlCommentsAndStrings([string]$Text) {
    $sb = [Text.StringBuilder]::new($Text.Length)
    $mode = 'code'
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        $isEol = $c -eq "`n" -or $c -eq "`r"
        switch ($mode) {
            'code' {
                if ($c -eq '/' -and $n -eq '/') { $mode = 'line'; [void]$sb.Append('  '); $i++ }
                elseif ($c -eq '/' -and $n -eq '*') { $mode = 'block'; [void]$sb.Append('  '); $i++ }
                elseif ($c -eq "'") { $mode = 'string'; [void]$sb.Append(' ') }
                elseif ($c -eq '"') { $mode = 'ident'; [void]$sb.Append($c) }
                else { [void]$sb.Append($c) }
            }
            'line' {
                if ($isEol) { [void]$sb.Append($c); if ($c -eq "`n") { $mode = 'code' } }
                else { [void]$sb.Append(' ') }
            }
            'block' {
                if ($c -eq '*' -and $n -eq '/') { $mode = 'code'; [void]$sb.Append('  '); $i++ }
                elseif ($isEol) { [void]$sb.Append($c) }
                else { [void]$sb.Append(' ') }
            }
            'string' {
                if ($c -eq "'") { $mode = 'code'; [void]$sb.Append(' ') }
                elseif ($isEol) { [void]$sb.Append($c); $mode = 'code' }
                else { [void]$sb.Append(' ') }
            }
            'ident' {
                [void]$sb.Append($c)
                if ($c -eq '"' -or $c -eq "`n") { $mode = 'code' }
            }
        }
    }
    $sb.ToString()
}

$script:HeaderRx = [regex]'^\s*(?:(?:local|internal|protected)\s+)?(?:procedure|trigger)\s+("[^"]+"|\w+)'
$script:AttributeRx = [regex]'^\s*\[\s*[A-Za-z]+\s*(?:\(|\])'
$script:TestAttrRx = [regex]'(?i)^\s*\[\s*Test\s*\]'
$script:AssertionRx = [regex]'(?i)(?<!\w)(?:\w*Assert|"[^"\r\n]*Assert")\s*\.\s*\w+|\basserterror\b|\bError\s*\('
$script:ExitRx = [regex]'(?i)\bexit\b'
$script:NondetRx = @(
    @{ Rx = [regex]'(?i)\bRandom\s*\('; Name = 'Random()' }
    @{ Rx = [regex]'(?i)\bRandomize\b'; Name = 'Randomize' }
    @{ Rx = [regex]'(?i)\bCurrentDateTime\b'; Name = 'CurrentDateTime' }
    @{ Rx = [regex]'(?i)\bToday\b'; Name = 'Today' }
)
$script:AnyCallRx = [regex]'(?i)\bAny\s*\.\s*(\w+)\s*\('
$script:AnySeedRx = [regex]'(?i)\bAny\s*\.\s*(?:SetDefaultSeed|SetSeed)\s*\('

function Get-TestLintFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TestsDir)

    if (-not (Test-Path -LiteralPath $TestsDir -PathType Container)) { return }
    $root = (Resolve-Path -LiteralPath $TestsDir).Path
    $files = Get-ChildItem -LiteralPath $root -Filter *.al -File -Recurse | Sort-Object FullName
    foreach ($f in $files) {
        $rel = [IO.Path]::GetRelativePath($root, $f.FullName)
        $raw = Get-Content -LiteralPath $f.FullName -Raw
        if (-not $raw) { continue }
        $text = Remove-AlCommentsAndStrings $raw
        if ($text -notmatch '(?i)\bSubtype\s*=\s*Test\s*;') { continue }
        $lines = $text -split "`r?`n"
        # Quoted identifiers ("Posted Today") must not match the nondeterminism tokens.
        $codeLines = [regex]::Replace($text, '"[^"\r\n]*"', { param($m) ' ' * $m.Length }) -split "`r?`n"

        # Procedure headers: line index, name, and whether a [Test] attribute precedes it.
        $procs = [Collections.Generic.List[object]]::new()
        $pendingTest = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($script:TestAttrRx.IsMatch($lines[$i])) { $pendingTest = $true; continue }
            $m = $script:HeaderRx.Match($lines[$i])
            if ($m.Success) {
                $procs.Add([pscustomobject]@{ Index = $i; Name = $m.Groups[1].Value.Trim('"'); IsTest = $pendingTest })
                $pendingTest = $false
            }
        }

        foreach ($p in @($procs | Where-Object IsTest)) {
            # Body: up to the next procedure header or attribute line (nested begin/end blocks
            # make "the matching end;" unreliable), or the end of the file.
            $end = $lines.Count
            for ($j = $p.Index + 1; $j -lt $lines.Count; $j++) {
                if ($script:HeaderRx.IsMatch($lines[$j]) -or $script:AttributeRx.IsMatch($lines[$j])) { $end = $j; break }
            }
            $firstAssert = $null
            $firstExit = $null
            for ($j = $p.Index + 1; $j -lt $end; $j++) {
                $x = $script:ExitRx.Match($lines[$j])
                $a = $script:AssertionRx.Match($lines[$j])
                if ($x.Success -and $null -eq $firstExit) { $firstExit = @{ Line = $j; Col = $x.Index } }
                if ($a.Success) { $firstAssert = @{ Line = $j; Col = $a.Index }; break }
            }
            if ($null -eq $firstAssert) {
                [pscustomobject]@{ File = $rel; Line = $p.Index + 1; Procedure = $p.Name; Rule = 'no-assertion'
                    Detail = 'test has no Assert call, asserterror or Error(' }
            }
            elseif ($firstExit -and ($firstExit.Line -lt $firstAssert.Line -or ($firstExit.Line -eq $firstAssert.Line -and $firstExit.Col -lt $firstAssert.Col))) {
                [pscustomobject]@{ File = $rel; Line = $firstExit.Line + 1; Procedure = $p.Name; Rule = 'exit-before-assertion'
                    Detail = 'exit before the first assertion' }
            }
        }

        # Nondeterminism is checked over the whole test codeunit: seeding helpers count too.
        $seeded = $script:AnySeedRx.IsMatch($text)
        $current = ''
        $procByLine = @{}
        foreach ($p in $procs) { $procByLine[$p.Index] = $p.Name }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($procByLine.ContainsKey($i)) { $current = $procByLine[$i] }
            foreach ($n in $script:NondetRx) {
                if ($n.Rx.IsMatch($codeLines[$i])) {
                    [pscustomobject]@{ File = $rel; Line = $i + 1; Procedure = $current; Rule = 'nondeterministic'
                        Detail = "uses $($n.Name)" }
                }
            }
            if (-not $seeded) {
                foreach ($m in $script:AnyCallRx.Matches($lines[$i])) {
                    [pscustomobject]@{ File = $rel; Line = $i + 1; Procedure = $current; Rule = 'nondeterministic'
                        Detail = "Any.$($m.Groups[1].Value)() without Any.SetDefaultSeed or Any.SetSeed in the same file" }
                }
            }
        }
    }
}

Export-ModuleMember -Function Get-TestLintFindings
