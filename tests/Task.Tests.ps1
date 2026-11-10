#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Task.psm1') -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\tasks\TX01'
    function New-TaskCopy([scriptblock]$Mutate) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        $t = Join-Path $dir 'TX01'
        Copy-Item $script:Fixture $t -Recurse
        if ($Mutate) { & $Mutate $t }
        $t
    }
    function Set-Json($Path, [scriptblock]$Mutate) {
        $o = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
        & $Mutate $o
        ConvertTo-Json $o -Depth 10 | Set-Content $Path
    }
}

Describe 'Get-BenchTask' {
    It 'loads fixture TX01' {
        $t = Get-BenchTask $script:Fixture
        $t.Id | Should -Be 'TX01'
        $t.Type | Should -Be 'bugfix'
        $t.Difficulty | Should -Be 'easy'
        $t.Categories | Should -Be @('data-access', 'transactions')
        $t.TimeoutMinutes | Should -Be 20
        $t.AppId | Should -Be '11111111-1111-1111-1111-111111111111'
        $t.TestAppId | Should -Be '22222222-2222-2222-2222-222222222222'
        $t.AssignmentDir | Should -Be (Join-Path $t.Root 'assignment')
        $t.SolutionAppDir | Should -Be (Join-Path $t.Root 'solution\app')
        $t.TestsDir | Should -Be (Join-Path $t.Root 'solution\tests')
        $t.ChecksFile | Should -Be (Join-Path $t.Root 'solution\checks.json')
        $t.BadDir | Should -Be (Join-Path $t.Root 'solution\variants\bad')
        $t.AltDir | Should -Be (Join-Path $t.Root 'solution\variants\alt')
    }
    It 'returns null Bad/Alt dirs and null timeout when absent' {
        $p = New-TaskCopy { param($t)
            Remove-Item (Join-Path $t 'solution\variants') -Recurse
            Set-Json (Join-Path $t 'task.json') { param($o) $o.Remove('timeoutMinutes') }
        }
        $t = Get-BenchTask $p
        $t.BadDir | Should -BeNullOrEmpty
        $t.AltDir | Should -BeNullOrEmpty
        $t.TimeoutMinutes | Should -BeNullOrEmpty
    }
    It 'loads family and split from task.json' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.family = 'n-plus-one'; $o.split = 'holdout' } }
        $t = Get-BenchTask $p
        $t.Family | Should -Be 'n-plus-one'
        $t.Split | Should -Be 'holdout'
    }
    It 'defaults family to null and split to dev' {
        $t = Get-BenchTask $script:Fixture
        $t.Family | Should -BeNullOrEmpty
        $t.Split | Should -Be 'dev'
    }
    It 'throws on an invalid split' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.split = 'test' } }
        { Get-BenchTask $p } | Should -Throw "TX01: invalid split 'test'"
    }
    It 'throws when family is not a string' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.family = 5 } }
        { Get-BenchTask $p } | Should -Throw 'TX01: family must be a string'
    }
    It 'hashes the whole task folder' {
        $p = New-TaskCopy
        $h = (Get-BenchTask $p).Hash
        $h | Should -Match '^[0-9a-f]{64}$'
        Add-Content (Join-Path $p 'solution\tests\app.json') ' '
        (Get-BenchTask $p).Hash | Should -Not -Be $h
    }
    It 'ignores git-ignored build output when hashing' {
        $p = New-TaskCopy
        $h = (Get-BenchTask $p).Hash
        foreach ($rel in 'assignment\app\.alpackages\x.app', 'solution\app\.vscode\settings.json', 'solution\app\foo.app', 'solution\app\.output\o.txt', 'solution\app\.snapshots\s.bin', 'solution\app\Sub\.ALPackages\y.dll') {
            $f = Join-Path $p $rel
            New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
            Set-Content $f 'build output'
        }
        (Get-BenchTask $p).Hash | Should -Be $h
        Add-Content (Join-Path $p 'solution\tests\app.json') ' '
        (Get-BenchTask $p).Hash | Should -Not -Be $h
    }
    It 'throws on unknown task category' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.categories = @('bogus') } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *bogus*'
    }
    It 'throws on unknown checks.json category' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'solution\checks.json') { param($o) } ; '[{"check":"NoCommitIn","category":"bogus","params":{}}]' | Set-Content (Join-Path $t 'solution\checks.json') }
        { Get-BenchTask $p } | Should -Throw 'TX01: *bogus*'
    }
    It 'throws on unknown check name' {
        $p = New-TaskCopy { param($t) '[{"check":"NoSuchCheck","category":"transactions","params":{}}]' | Set-Content (Join-Path $t 'solution\checks.json') }
        { Get-BenchTask $p } | Should -Throw 'TX01: *NoSuchCheck*'
    }
    It 'throws on missing TASK.md' {
        $p = New-TaskCopy { param($t) Remove-Item (Join-Path $t 'assignment\TASK.md') }
        { Get-BenchTask $p } | Should -Throw 'TX01: *TASK.md*'
    }
    It 'throws on missing solution tests app.json' {
        $p = New-TaskCopy { param($t) Remove-Item (Join-Path $t 'solution\tests\app.json') }
        { Get-BenchTask $p } | Should -Throw 'TX01: *app.json*'
    }
    It 'throws when bugfix lacks assignment app.json' {
        $p = New-TaskCopy { param($t) Remove-Item (Join-Path $t 'assignment\app\app.json') }
        { Get-BenchTask $p } | Should -Throw 'TX01: *app.json*'
    }
    It 'throws on greenfield with starter source' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.type = 'greenfield' } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *greenfield*'
    }
    It 'accepts greenfield without starter source' {
        $p = New-TaskCopy { param($t)
            Set-Json (Join-Path $t 'task.json') { param($o) $o.type = 'greenfield' }
            Remove-Item (Join-Path $t 'assignment\app\src') -Recurse
        }
        (Get-BenchTask $p).Type | Should -Be 'greenfield'
    }
    It 'throws on id/folder mismatch' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.id = 'TX02' } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *TX02*'
    }
    It 'throws on assignment/solution app id mismatch' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'assignment\app\app.json') { param($o) $o.id = '33333333-3333-3333-3333-333333333333' } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *app id*'
    }
    It 'rejects a wrongly cased type' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.type = 'Bugfix' } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *Bugfix*'
    }
    It 'rejects a wrongly cased task category' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.categories = @('Data-Access') } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *Data-Access*'
    }
    It 'rejects a wrongly cased checks.json category' {
        $p = New-TaskCopy { param($t) '[{"check":"NoCommitIn","category":"Transactions","params":{}}]' | Set-Content (Join-Path $t 'solution\checks.json') }
        { Get-BenchTask $p } | Should -Throw 'TX01: *Transactions*'
    }
    It 'throws on invalid type' {
        $p = New-TaskCopy { param($t) Set-Json (Join-Path $t 'task.json') { param($o) $o.type = 'weird' } }
        { Get-BenchTask $p } | Should -Throw 'TX01: *type*'
    }
}

Describe 'Get-BenchTasks' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'tasks'
        New-Item -ItemType Directory $script:Root | Out-Null
        Copy-Item $script:Fixture (Join-Path $script:Root 'TX01') -Recurse
    }
    It 'loads all tasks' { @(Get-BenchTasks $script:Root).Id | Should -Be @('TX01') }
    It 'filters by id' { @(Get-BenchTasks $script:Root -Ids 'TX01').Count | Should -Be 1 }
    It 'throws on unknown id' { { Get-BenchTasks $script:Root -Ids 'T999' } | Should -Throw '*T999*' }
}
