#Requires -Version 7.6
Set-StrictMode -Version Latest

# Builds the feedback text sent back to the agent after a graded attempt.
# Compile errors and functional test failures are passed on verbatim. Budget failures and
# standards findings are reduced to a scenario name or a category: no check names, files,
# lines, numbers or details.

$script:Categories = @('data-access', 'locking-isolation', 'transactions', 'architecture', 'naming-style', 'ui', 'error-handling')

function New-AttemptFeedback {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][object]$Grade)

    $sections = [Collections.Generic.List[string]]::new()

    $errors = @($Grade.CompileErrors | Where-Object { $_ })
    if ($errors.Count -gt 0) {
        $sections.Add((@('Compilation failed:') + $errors) -join "`n")
    }

    $tests = @($Grade.Tests | Where-Object { $_ })
    $failed = @($tests | Where-Object { -not $_.Passed -and -not $_.IsBudget })
    if ($failed.Count -gt 0) {
        $lines = @('Failing tests:')
        foreach ($t in $failed) {
            $lines += '{0}::{1}: {2}' -f $t.Codeunit, $t.Name, $t.Message
            if ($t.CallStack) { $lines += ([string]$t.CallStack).TrimEnd() }
        }
        $sections.Add($lines -join "`n")
    }

    $budgets = @($tests | Where-Object { -not $_.Passed -and $_.IsBudget })
    if ($budgets.Count -gt 0) {
        $lines = @('Performance:')
        foreach ($t in $budgets) {
            $scenario = ([string]$t.Name) -replace '^Budget_', ''
            $lines += "$scenario used more SQL statements/rows than allowed"
        }
        $sections.Add($lines -join "`n")
    }

    # Only the fixed category names may reach the agent; anything else could carry a check name.
    $known = foreach ($f in @($Grade.Findings | Where-Object { $_ -and -not $_.Passed })) {
        $c = [string]$f.Category
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($c -cnotin $script:Categories) {
            Write-Verbose "Feedback: ignoring unknown standards category '$c' (check '$($f.Check)')."
            continue
        }
        $c
    }
    $categories = @($known | Sort-Object -Unique)
    if ($categories.Count -gt 0) {
        $sections.Add("Coding standards issues found in: $($categories -join ', ').")
    }

    $sections.Add('Fix the issues and finish again.')
    $sections -join "`n`n"
}

Export-ModuleMember -Function New-AttemptFeedback
