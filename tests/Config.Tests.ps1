#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force
    function New-TempConfig([scriptblock]$Mutate) {
        $cfg = Get-Content (Join-Path $PSScriptRoot '..\config\bench.json') -Raw | ConvertFrom-Json -AsHashtable
        & $Mutate $cfg
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $p
        $p
    }
}

Describe 'Get-BenchConfig' {
    It 'loads defaults' {
        $c = Get-BenchConfig
        $c.Claude.MaxAttempts | Should -Be 3
        $c.Auth.Mode | Should -Be 'subscription'
        $c.TempRoot | Should -Be 'C:\rfb-runs'
    }
    It 'sets RepoRoot to the repo root' {
        (Get-BenchConfig).RepoRoot | Should -Be (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    It 'canonicalises RepoRoot to on-disk casing' {
        $root = (Get-BenchConfig).RepoRoot
        $parts = $root.Split('\')
        $parts[0] | Should -BeExactly $parts[0].ToUpperInvariant()
        $cur = $parts[0] + '\'
        foreach ($seg in $parts[1..($parts.Count - 1)]) {
            $onDisk = (Get-ChildItem -LiteralPath $cur -Force | Where-Object Name -EQ $seg).Name
            $seg | Should -BeExactly $onDisk
            $cur = Join-Path $cur $seg
        }
    }
    It 'pins an exact BC version' {
        (Get-BenchConfig).Bc.Version | Should -Match '^\d+\.\d+\.\d+\.\d+$'
    }
    It 'throws on missing key' {
        $p = New-TempConfig { param($c) $c.Remove('Bc') }
        { Get-BenchConfig -Path $p } | Should -Throw '*missing Bc*'
    }
    It 'throws on missing nested key' {
        $p = New-TempConfig { param($c) $c.Claude.Remove('MaxTurns') }
        { Get-BenchConfig -Path $p } | Should -Throw '*missing Claude.MaxTurns*'
    }
    It 'defaults Grader.InfraRetries to 2 when the Grader section is missing' {
        $p = New-TempConfig { param($c) $c.Remove('Grader') }
        (Get-BenchConfig -Path $p).Grader.InfraRetries | Should -Be 2
    }
    It 'accepts Grader.InfraRetries = 0' {
        $p = New-TempConfig { param($c) $c.Grader = @{ InfraRetries = 0 } }
        (Get-BenchConfig -Path $p).Grader.InfraRetries | Should -Be 0
    }
    It 'rejects a negative Grader.InfraRetries' {
        $p = New-TempConfig { param($c) $c.Grader = @{ InfraRetries = -1 } }
        { Get-BenchConfig -Path $p } | Should -Throw '*InfraRetries*'
    }
    It 'rejects unknown auth mode' {
        $p = New-TempConfig { param($c) $c.Auth.Mode = 'foo' }
        { Get-BenchConfig -Path $p } | Should -Throw '*auth.mode*'
    }
    It 'overlays bench.local.json from the same folder on bench.json' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        $p = Join-Path $dir 'bench.json'
        Copy-Item (Join-Path $PSScriptRoot '..\config\bench.json') $p
        Set-Content (Join-Path $dir 'bench.local.json') '{ "Bc": { "CompilerFolder": "%RFB_TEST_DIR%\\compiler" }, "Claude": { "MaxTurns": 9 } }'
        $env:RFB_TEST_DIR = 'C:\rfb'
        $c = Get-BenchConfig -Path $p
        $c.Bc.CompilerFolder | Should -Be 'C:\rfb\compiler'
        $c.Claude.MaxTurns | Should -Be 9
        $c.Bc.ContainerName | Should -Be 'rfbench'
        $c.Bc.Credential.User | Should -Be 'admin'
        $c.Claude.MaxAttempts | Should -Be 3
    }
    It 'throws naming bench.local.json when it is not valid JSON' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        $p = Join-Path $dir 'bench.json'
        Copy-Item (Join-Path $PSScriptRoot '..\config\bench.json') $p
        Set-Content (Join-Path $dir 'bench.local.json') '{ broken'
        { Get-BenchConfig -Path $p } | Should -Throw '*bench.local.json*'
    }
    It 'expands environment variables in path values' {
        $env:RFB_TEST_DIR = 'C:\rfb'
        $p = New-TempConfig { param($c) $c.TempRoot = '%RFB_TEST_DIR%\x' }
        (Get-BenchConfig -Path $p).TempRoot | Should -Be 'C:\rfb\x'
    }
}
