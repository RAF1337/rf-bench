#Requires -Version 7.6
Set-StrictMode -Version Latest

# Grades a task's reference solution so a broken task is found before any Claude run is spent on it.
# The result is cached per task under CacheDir and valid only while the task hash, the BC artifact
# and the compiler version all match. A grading failure (Invoke-Grade throws) propagates and caches nothing.
function Get-GoldResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$BcArtifact,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CompilerVersion,
        [Parameter(Mandatory)][string]$GraderDir
    )
    $file = Join-Path $CacheDir ('{0}-{1}.json' -f $Task.Id, $Task.Hash.Substring(0, 16))
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        try { $c = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { $c = $null }
        if ($c -and $c.taskHash -ceq $Task.Hash -and $c.bcArtifact -ceq $BcArtifact -and $c.compilerVersion -ceq $CompilerVersion) {
            return [pscustomobject]@{ FullyRight = [bool]$c.fullyRight; Cached = $true }
        }
    }

    $grade = Invoke-Grade -Config $Config -Task $Task -AgentAppDir $Task.SolutionAppDir -GraderDir $GraderDir -Attempt 1
    $fullyRight = [bool]$grade.FullyRight
    if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
    [pscustomobject][ordered]@{
        taskId          = $Task.Id
        taskHash        = $Task.Hash
        bcArtifact      = $BcArtifact
        compilerVersion = $CompilerVersion
        fullyRight      = $fullyRight
        gradedUtc       = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    [pscustomobject]@{ FullyRight = $fullyRight; Cached = $false }
}

Export-ModuleMember -Function Get-GoldResult
