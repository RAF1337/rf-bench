#Requires -Version 7.6
Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$script:RequiredKeys = @(
    'TempRoot'
    'Bc', 'Bc.ArtifactType', 'Bc.Country', 'Bc.Version', 'Bc.ContainerName', 'Bc.CompilerFolder'
    'Bc.Credential', 'Bc.Credential.User', 'Bc.Credential.PasswordEnvVar'
    'Claude', 'Claude.DefaultModel', 'Claude.MaxTurns', 'Claude.TimeoutMinutes', 'Claude.MaxAttempts'
    'Auth', 'Auth.Mode', 'Auth.TokenEnvVar', 'Auth.ApiKeyEnvVar'
    'Paths', 'Paths.AlParserDll'
)

function Expand-ConfigValue($Value) {
    if ($Value -is [string]) {
        # Expand %VAR% (Windows style) and $env:-free plain env references.
        return [Environment]::ExpandEnvironmentVariables($Value)
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) { $p.Value = Expand-ConfigValue $p.Value }
    }
    return $Value
}

function Get-BenchConfig {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $script:RepoRoot 'config/bench.json'))

    if (-not (Test-Path -LiteralPath $Path)) { throw "bench.json: file not found: $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    foreach ($key in $script:RequiredKeys) {
        $node = $cfg
        foreach ($part in $key.Split('.')) {
            if ($null -eq $node -or $node -isnot [System.Management.Automation.PSCustomObject] -or -not $node.PSObject.Properties[$part]) {
                throw "bench.json: missing $key"
            }
            $node = $node.$part
        }
    }

    if ($cfg.Auth.Mode -notin 'subscription', 'apiKey') {
        throw "bench.json: invalid auth.mode '$($cfg.Auth.Mode)' (expected 'subscription' or 'apiKey')"
    }

    $cfg = Expand-ConfigValue $cfg
    $cfg | Add-Member -NotePropertyName RepoRoot -NotePropertyValue $script:RepoRoot
    $cfg
}

Export-ModuleMember -Function Get-BenchConfig
