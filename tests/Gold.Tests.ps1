#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Grader.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Gold.psm1') -Force
    $script:Task = [pscustomobject]@{ Id = 'T001'; Hash = ('ab' * 32); SolutionAppDir = 'C:\fake\solution\app' }
    $script:CacheFile = { param($dir) Join-Path $dir 'T001-abababababababab.json' }
    function Get-Gold([string]$Dir, [string]$Compiler = '29.0.1') {
        Get-GoldResult -Config ([pscustomobject]@{}) -Task $script:Task -CacheDir $Dir -BcArtifact 'Sandbox/w1/29.0' `
            -CompilerVersion $Compiler -GraderDir (Join-Path $TestDrive 'g')
    }
}

Describe 'Get-GoldResult' {
    BeforeEach {
        $script:Cache = Join-Path $TestDrive "cache-$([guid]::NewGuid().ToString('N'))"
        $script:Calls = [Collections.Generic.List[object]]::new()
        $script:Right = $true
        Mock Invoke-Grade {
            $script:Calls.Add([pscustomobject]@{ AgentAppDir = $AgentAppDir; Attempt = $Attempt })
            [pscustomobject]@{ FullyRight = $script:Right }
        } -ModuleName Gold
    }

    It 'grades the reference solution once on a miss and writes the cache file' {
        $r = Get-Gold $script:Cache
        $r.FullyRight | Should -BeTrue
        $r.Cached | Should -BeFalse
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].AgentAppDir | Should -Be 'C:\fake\solution\app'
        $script:Calls[0].Attempt | Should -Be 1
        $j = Get-Content (& $script:CacheFile $script:Cache) -Raw | ConvertFrom-Json
        $j.taskId | Should -Be 'T001'
        $j.taskHash | Should -Be ('ab' * 32)
        $j.bcArtifact | Should -Be 'Sandbox/w1/29.0'
        $j.compilerVersion | Should -Be '29.0.1'
        $j.fullyRight | Should -BeTrue
        $j.gradedUtc | Should -Not -BeNullOrEmpty
    }
    It 'returns the cached result for the same inputs without grading' {
        $null = Get-Gold $script:Cache
        $r = Get-Gold $script:Cache
        $r.Cached | Should -BeTrue
        $r.FullyRight | Should -BeTrue
        $script:Calls.Count | Should -Be 1
    }
    It 're-grades when the compiler version differs' {
        $null = Get-Gold $script:Cache '29.0.1'
        $r = Get-Gold $script:Cache '29.0.2'
        $r.Cached | Should -BeFalse
        $script:Calls.Count | Should -Be 2
    }
    It 're-grades when the BC artifact or the task hash differs' {
        $null = Get-Gold $script:Cache
        $null = Get-GoldResult -Config ([pscustomobject]@{}) -Task $script:Task -CacheDir $script:Cache -BcArtifact 'Sandbox/w1/30.0' `
            -CompilerVersion '29.0.1' -GraderDir (Join-Path $TestDrive 'g')
        $script:Calls.Count | Should -Be 2
        $edited = [pscustomobject]@{ Id = 'T001'; Hash = ('ab' * 8) + ('cd' * 28); SolutionAppDir = 'x' }
        $null = Get-GoldResult -Config ([pscustomobject]@{}) -Task $edited -CacheDir $script:Cache -BcArtifact 'Sandbox/w1/30.0' `
            -CompilerVersion '29.0.1' -GraderDir (Join-Path $TestDrive 'g')
        $script:Calls.Count | Should -Be 3
    }
    It 'caches a not-fully-right result too' {
        $script:Right = $false
        (Get-Gold $script:Cache).FullyRight | Should -BeFalse
        $r = Get-Gold $script:Cache
        $r.Cached | Should -BeTrue
        $r.FullyRight | Should -BeFalse
        $script:Calls.Count | Should -Be 1
    }
    It 'propagates a grading failure and writes no cache file' {
        Mock Invoke-Grade { throw 'infra: container is down' } -ModuleName Gold
        { Get-Gold $script:Cache } | Should -Throw '*container is down*'
        @(Get-ChildItem $script:Cache -Filter *.json -ErrorAction Ignore).Count | Should -Be 0
    }
    It 're-grades and overwrites an incomplete cache entry' {
        New-Item -ItemType Directory $script:Cache -Force | Out-Null
        Set-Content (& $script:CacheFile $script:Cache) '{}'
        $r = Get-Gold $script:Cache
        $r.Cached | Should -BeFalse
        $script:Calls.Count | Should -Be 1
        (Get-Gold $script:Cache).Cached | Should -BeTrue
    }
    It 're-grades an unreadable cache entry' {
        New-Item -ItemType Directory $script:Cache -Force | Out-Null
        Set-Content (& $script:CacheFile $script:Cache) 'not json'
        (Get-Gold $script:Cache).Cached | Should -BeFalse
    }
    It 'neither reads nor writes the cache when the compiler version is empty' {
        $null = Get-Gold $script:Cache ''
        $r = Get-Gold $script:Cache ''
        $r.Cached | Should -BeFalse
        $script:Calls.Count | Should -Be 2
        Test-Path $script:Cache | Should -BeFalse
    }
}
