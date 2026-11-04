#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\Backend.Docker.psm1') -Force

    # BcContainerHelper is never imported by the unit tests. Where its commands are not loaded
    # in this session, global stubs with the parameters the backend uses let Pester mock them.
    $script:Stubs = @{
        'Compile-AppWithBcCompilerFolder' = 'param([string]$compilerFolder, [string]$appProjectFolder, [string]$appOutputFolder, [string]$appSymbolsFolder, [string]$appName, [switch]$EnableCodeCop, [switch]$EnableUICop, [switch]$EnablePerTenantExtensionCop, [switch]$AzureDevOps, [switch]$gitHubActions, [string[]]$treatWarningsAsErrors, [scriptblock]$outputTo)'
        'Publish-BcContainerApp'          = 'param([string]$containerName, $appFile, [switch]$skipVerification, [switch]$sync, [switch]$install)'
        'Get-BcContainerAppInfo'          = 'param([string]$containerName, [switch]$tenantSpecificProperties)'
        'UnPublish-BcContainerApp'        = 'param([string]$containerName, [string]$name, [string]$publisher, [string]$version, [switch]$unInstall, [switch]$doNotSaveData, [switch]$doNotSaveSchema, [switch]$force)'
        'Run-TestsInBcContainer'          = 'param([string]$containerName, [pscredential]$credential, [string]$extensionId, [string]$XUnitResultFileName, [switch]$detailed)'
        'Get-BcArtifactUrl'               = 'param([string]$type, [string]$country, [string]$version, [string]$select)'
        'Test-BcContainer'                = 'param([string]$containerName, [switch]$doNotIncludeStoppedContainers)'
        'New-BcContainer'                 = 'param([switch]$accept_eula, [string]$containerName, [string]$artifactUrl, [string]$auth, [pscredential]$credential, [switch]$includeTestToolkit, [switch]$includeTestLibrariesOnly, [switch]$updateHosts, [string]$isolation)'
        'Start-BcContainer'               = 'param([string]$containerName)'
        'New-BcCompilerFolder'            = 'param([string]$artifactUrl, [string]$containerName)'
    }
    $script:Defined = @()
    # Get-Command would auto-import BcContainerHelper (even with -ListImported), so check the
    # loaded module and function drive instead.
    $helperLoaded = [bool](Get-Module BcContainerHelper)
    foreach ($name in $script:Stubs.Keys) {
        if (-not $helperLoaded -and -not (Test-Path "function:$name")) {
            Set-Item "function:global:$name" ([scriptblock]::Create("$($script:Stubs[$name]) throw 'stub $name called unmocked'"))
            $script:Defined += $name
        }
    }

    $env:RFBENCH_TEST_BC_PASSWORD = 'P@ssw0rd!'
    function New-TestConfig {
        $cfg = Get-BenchConfig
        $cfg.TempRoot = Join-Path $TestDrive 'temp'
        $cfg.Bc.Credential.PasswordEnvVar = 'RFBENCH_TEST_BC_PASSWORD'
        $cfg
    }
    # Compiler folder with alc.exe at the BcContainerHelper layout.
    function New-CompilerFolder([string]$Name = 'compiler') {
        $cf = Join-Path $TestDrive $Name
        New-Item -ItemType Directory (Join-Path $cf 'compiler\extension\bin\win32'), (Join-Path $cf 'symbols') -Force | Out-Null
        Set-Content (Join-Path $cf 'compiler\extension\bin\win32\alc.exe') 'exe'
        $cf
    }
    function New-AppDir {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $d | Out-Null
        Set-Content (Join-Path $d 'app.json') '{}'
        $d
    }
}

AfterAll {
    foreach ($name in $script:Defined) { Remove-Item "function:global:$name" -ErrorAction Ignore }
    Remove-Item Env:RFBENCH_TEST_BC_PASSWORD -ErrorAction Ignore
}

Describe 'Docker mode' {
    It 'reads the server OS' {
        Mock Invoke-DockerCli -ModuleName Backend.Docker { 'windows' }
        Get-DockerMode | Should -Be 'windows'
        Should -Invoke Invoke-DockerCli -ModuleName Backend.Docker -ParameterFilter { ($args -join ' ') -eq "version --format {{.Server.Os}}" }
    }
    It 'Assert-DockerWindowsMode throws in linux mode' {
        Mock Get-DockerMode -ModuleName Backend.Docker { 'linux' }
        { Assert-DockerWindowsMode } | Should -Throw 'Docker is in linux mode. Switch to Windows containers or pass -SwitchDocker.'
    }
    It 'Assert-DockerWindowsMode passes in windows mode' {
        Mock Get-DockerMode -ModuleName Backend.Docker { 'windows' }
        { Assert-DockerWindowsMode } | Should -Not -Throw
    }
    It 'Switch-DockerMode does nothing when already in the mode' {
        Mock Get-DockerMode -ModuleName Backend.Docker { 'windows' }
        Mock Invoke-DockerSwitch -ModuleName Backend.Docker { }
        Switch-DockerMode windows
        Should -Invoke Invoke-DockerSwitch -ModuleName Backend.Docker -Times 0 -Exactly
    }
    It 'Switch-DockerMode switches and waits for the new mode' {
        $script:modeCalls = 0
        Mock Get-DockerMode -ModuleName Backend.Docker {
            $script:modeCalls++
            if ($script:modeCalls -le 1) { 'linux' } elseif ($script:modeCalls -eq 2) { throw 'daemon restarting' } else { 'windows' }
        }
        Mock Invoke-DockerSwitch -ModuleName Backend.Docker { }
        Mock Start-Sleep -ModuleName Backend.Docker { }
        Switch-DockerMode windows
        Should -Invoke Invoke-DockerSwitch -ModuleName Backend.Docker -Times 1 -Exactly
        $script:modeCalls | Should -Be 3
    }
    It 'Switch-DockerMode throws when the mode does not change in time' {
        Mock Get-DockerMode -ModuleName Backend.Docker { 'linux' }
        Mock Invoke-DockerSwitch -ModuleName Backend.Docker { }
        Mock Start-Sleep -ModuleName Backend.Docker { }
        { Switch-DockerMode windows -TimeoutSeconds 0 } | Should -Throw '*did not switch to windows*'
    }
}

Describe 'Get-AlcPath' {
    It 'returns alc.exe in the compiler folder' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        Get-AlcPath $cfg | Should -Be (Join-Path $cfg.Bc.CompilerFolder 'compiler\extension\bin\win32\alc.exe')
    }
    It 'throws when the compiler folder is not set' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = ''
        { Get-AlcPath $cfg } | Should -Throw 'Bc.CompilerFolder not set; run src/Initialize-Backend.ps1'
    }
    It 'throws naming the searched paths when alc.exe is missing' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = Join-Path $TestDrive 'empty-compiler'
        { Get-AlcPath $cfg } | Should -Throw '*alc.exe not found*empty-compiler*'
    }
}

Describe 'Invoke-AlCompile' {
    BeforeAll {
        Mock Import-BcContainerHelper -ModuleName Backend.Docker { }
    }
    It 'parses errors and warnings from the compiler output' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        $app = New-AppDir
        $out = Join-Path $TestDrive 'out\app.app'
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker {
            $outputTo.Invoke('Microsoft (R) AL Compiler version 18.0')
            $outputTo.Invoke('C:\ws\app\src\Fix.Codeunit.al(12,5): error AL0118: The name ''Foo'' does not exist in the current context.')
            $outputTo.Invoke('C:\ws\app\src\Fix.Codeunit.al(3,1): warning AA0137: The variable ''x'' is declared but never used.')
            $outputTo.Invoke('C:\ws\app\src\Page (1).Page.al(40,9): warning AW0006: The page should specify an ApplicationArea.')
            throw 'App generation failed'
        }
        $r = Invoke-AlCompile $cfg -AppDir $app -OutFile $out
        $r.Success | Should -BeFalse
        $r.AppFile | Should -BeNullOrEmpty
        @($r.Errors).Count | Should -Be 1
        $r.Errors[0] | Should -Be 'C:\ws\app\src\Fix.Codeunit.al(12,5): error AL0118: The name ''Foo'' does not exist in the current context.'
        @($r.Warnings).Count | Should -Be 2
        $r.Warnings[0].Rule | Should -Be 'AA0137'
        $r.Warnings[0].Message | Should -Be 'The variable ''x'' is declared but never used.'
        $r.Warnings[0].File | Should -Be 'C:\ws\app\src\Fix.Codeunit.al'
        $r.Warnings[0].Line | Should -Be 3
        $r.Warnings[1].Rule | Should -Be 'AW0006'
    }
    It 'returns warning line numbers and files with parentheses' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        $out = Join-Path $TestDrive 'out2\app.app'
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker {
            $outputTo.Invoke('C:\ws\app\src\Fix.Codeunit.al(3,1): warning AA0137: unused')
            $outputTo.Invoke('C:\ws\app\src\Page (1).Page.al(40,9): warning AW0006: area')
            New-Item -ItemType Directory $appOutputFolder -Force | Out-Null
            Set-Content (Join-Path $appOutputFolder $appName) 'app'
            Join-Path $appOutputFolder $appName
        }
        $r = Invoke-AlCompile $cfg -AppDir (New-AppDir) -OutFile $out
        $r.Success | Should -BeTrue
        $r.AppFile | Should -Be $out
        @($r.Errors).Count | Should -Be 0
        $r.Warnings[0].Line | Should -Be 3
        $r.Warnings[1].File | Should -Be 'C:\ws\app\src\Page (1).Page.al'
        $r.Warnings[1].Line | Should -Be 40
        $r.Warnings[1].Rule | Should -Be 'AW0006'
    }
    It 'passes output folder, app name and analyzers to the compiler' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        $app = New-AppDir
        $out = Join-Path $TestDrive 'out3\my.app'
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker {
            New-Item -ItemType Directory $appOutputFolder -Force | Out-Null
            Set-Content (Join-Path $appOutputFolder $appName) 'app'
        }
        $null = Invoke-AlCompile $cfg -AppDir $app -OutFile $out -EnableAnalyzers
        Should -Invoke Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter {
            $compilerFolder -eq $cfg.Bc.CompilerFolder -and $appProjectFolder -eq $app -and
            $appOutputFolder -eq (Split-Path $out) -and $appName -eq 'my.app' -and
            $EnableCodeCop -and $EnableUICop -and $EnablePerTenantExtensionCop
        }
    }
    It 'does not enable analyzers by default' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        $out = Join-Path $TestDrive 'out4\my.app'
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker {
            New-Item -ItemType Directory $appOutputFolder -Force | Out-Null
            Set-Content (Join-Path $appOutputFolder $appName) 'app'
        }
        $null = Invoke-AlCompile $cfg -AppDir (New-AppDir) -OutFile $out
        Should -Invoke Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter {
            -not $EnableCodeCop -and -not $EnableUICop -and -not $EnablePerTenantExtensionCop
        }
    }
    It 'reports a compiler exception without diagnostics as an error' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker { throw 'Unable to locate system symbols.' }
        $r = Invoke-AlCompile $cfg -AppDir (New-AppDir) -OutFile (Join-Path $TestDrive 'out5\a.app')
        $r.Success | Should -BeFalse
        $r.Errors | Should -Contain 'Unable to locate system symbols.'
    }
    It 'fails without calling the compiler when app.json is missing' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        $app = Join-Path $TestDrive 'noappjson'
        New-Item -ItemType Directory $app -Force | Out-Null
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker { }
        $r = Invoke-AlCompile $cfg -AppDir $app -OutFile (Join-Path $TestDrive 'out6\a.app')
        $r.Success | Should -BeFalse
        $r.Errors[0] | Should -BeLike '*app.json not found*'
        Should -Invoke Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker -Times 0 -Exactly
    }
    It 'treats unlocated error lines as errors' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder
        Mock Compile-AppWithBcCompilerFolder -ModuleName Backend.Docker {
            $outputTo.Invoke('error AL1022: A package with publisher ''Microsoft'', name ''Base Application'' could not be found.')
            throw 'App generation failed'
        }
        $r = Invoke-AlCompile $cfg -AppDir (New-AppDir) -OutFile (Join-Path $TestDrive 'out7\a.app')
        $r.Success | Should -BeFalse
        @($r.Errors).Count | Should -Be 1
        $r.Errors[0] | Should -BeLike 'error AL1022:*'
    }
}

Describe 'Publish-BenchApp and Remove-BenchApp' {
    BeforeAll {
        Mock Import-BcContainerHelper -ModuleName Backend.Docker { }
        $script:AppId = [guid]'11111111-2222-3333-4444-555555555555'
    }
    It 'publishes with sync, install and skipVerification' {
        $cfg = New-TestConfig
        Mock Publish-BcContainerApp -ModuleName Backend.Docker { }
        Publish-BenchApp $cfg -AppFile 'C:\x\a.app'
        Should -Invoke Publish-BcContainerApp -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter {
            $containerName -eq 'rfbench' -and $appFile -eq 'C:\x\a.app' -and $sync -and $install -and $skipVerification
        }
    }
    It 'removes stale app before publish' {
        $cfg = New-TestConfig
        $script:order = [Collections.Generic.List[string]]::new()
        Mock Get-BcContainerAppInfo -ModuleName Backend.Docker {
            [pscustomobject]@{ AppId = '11111111-2222-3333-4444-555555555555'; Name = 'TX App'; Publisher = 'rf'; Version = '1.0.0.0'; IsInstalled = $true }
            [pscustomobject]@{ AppId = [guid]'99999999-2222-3333-4444-555555555555'; Name = 'Other'; Publisher = 'rf'; Version = '1.0.0.0'; IsInstalled = $true }
        }
        Mock UnPublish-BcContainerApp -ModuleName Backend.Docker { $script:order.Add("unpublish $name") }
        Mock Publish-BcContainerApp -ModuleName Backend.Docker { $script:order.Add('publish') }

        Remove-BenchApp $cfg -AppId $script:AppId
        Publish-BenchApp $cfg -AppFile 'C:\x\a.app'

        Should -Invoke UnPublish-BcContainerApp -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter {
            $containerName -eq 'rfbench' -and $name -eq 'TX App' -and $publisher -eq 'rf' -and $version -eq '1.0.0.0' -and $unInstall
        }
        $script:order -join ',' | Should -Be 'unpublish TX App,publish'
    }
    It 'removes every published version of the app id' {
        $cfg = New-TestConfig
        Mock Get-BcContainerAppInfo -ModuleName Backend.Docker {
            [pscustomobject]@{ AppId = [guid]'11111111-2222-3333-4444-555555555555'; Name = 'TX App'; Publisher = 'rf'; Version = '1.0.0.0'; IsInstalled = $false }
            [pscustomobject]@{ AppId = [guid]'11111111-2222-3333-4444-555555555555'; Name = 'TX App'; Publisher = 'rf'; Version = '1.0.0.1'; IsInstalled = $true }
        }
        Mock UnPublish-BcContainerApp -ModuleName Backend.Docker { }
        Remove-BenchApp $cfg -AppId $script:AppId
        Should -Invoke UnPublish-BcContainerApp -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter { $version -eq '1.0.0.0' -and -not $unInstall }
        Should -Invoke UnPublish-BcContainerApp -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter { $version -eq '1.0.0.1' -and $unInstall }
    }
    It 'does nothing when the app is absent' {
        $cfg = New-TestConfig
        Mock Get-BcContainerAppInfo -ModuleName Backend.Docker {
            [pscustomobject]@{ AppId = [guid]'99999999-2222-3333-4444-555555555555'; Name = 'Other'; Publisher = 'rf'; Version = '1.0.0.0'; IsInstalled = $true }
        }
        Mock UnPublish-BcContainerApp -ModuleName Backend.Docker { }
        { Remove-BenchApp $cfg -AppId $script:AppId } | Should -Not -Throw
        Should -Invoke UnPublish-BcContainerApp -ModuleName Backend.Docker -Times 0 -Exactly
    }
}

Describe 'Invoke-BenchTests' {
    BeforeAll {
        Mock Import-BcContainerHelper -ModuleName Backend.Docker { }
        $script:Sample = Join-Path $PSScriptRoot 'fixtures\xunit\sample.xml'
    }
    It 'runs the test app and parses the xUnit result' {
        $cfg = New-TestConfig
        $xml = Join-Path $TestDrive 'xunit-result.xml'
        Mock Get-XUnitResultPath -ModuleName Backend.Docker { $xml }
        Mock Run-TestsInBcContainer -ModuleName Backend.Docker { Copy-Item $script:Sample $XUnitResultFileName }
        $tid = [guid]'aaaaaaaa-2222-3333-4444-555555555555'

        $tests = @(Invoke-BenchTests $cfg -TestAppId $tid)

        Should -Invoke Run-TestsInBcContainer -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter {
            $containerName -eq 'rfbench' -and $extensionId -eq 'aaaaaaaa-2222-3333-4444-555555555555' -and
            $XUnitResultFileName -eq $xml -and $detailed -and $credential.UserName -eq 'admin' -and
            $credential.GetNetworkCredential().Password -eq 'P@ssw0rd!'
        }
        $tests.Count | Should -Be 3
        $pass = $tests | Where-Object Name -eq 'PostOrderCreatesEntry'
        $pass.Codeunit | Should -Be '70100 TX Feature Tests'
        $pass.Passed | Should -BeTrue
        $pass.IsBudget | Should -BeFalse
        $fail = $tests | Where-Object Name -eq 'RejectsBlockedCustomer'
        $fail.Passed | Should -BeFalse
        $fail.Message | Should -Be 'Assert.AreEqual failed. Expected:<1> (Integer). Actual:<0> (Integer).'
        $fail.CallStack | Should -BeLike '*RejectsBlockedCustomer line 12*'
        $budget = $tests | Where-Object Name -eq 'Budget_PostOrder'
        $budget.IsBudget | Should -BeTrue
        $budget.Passed | Should -BeTrue
        $budget.Codeunit | Should -Be '70101 TX Budget Tests'
        Test-Path $xml | Should -BeFalse -Because 'the temporary result file is removed'
    }
    It 'throws when no result file is produced' {
        $cfg = New-TestConfig
        Mock Get-XUnitResultPath -ModuleName Backend.Docker { Join-Path $TestDrive 'missing.xml' }
        Mock Run-TestsInBcContainer -ModuleName Backend.Docker { }
        { Invoke-BenchTests $cfg -TestAppId ([guid]::NewGuid()) } | Should -Throw '*no xUnit result*'
    }
    It 'throws naming the env var when the password is not set' {
        $cfg = New-TestConfig
        $cfg.Bc.Credential.PasswordEnvVar = 'RFBENCH_TEST_NOT_SET_' + [guid]::NewGuid().ToString('N')
        Mock Run-TestsInBcContainer -ModuleName Backend.Docker { }
        { Invoke-BenchTests $cfg -TestAppId ([guid]::NewGuid()) } | Should -Throw "*$($cfg.Bc.Credential.PasswordEnvVar)*"
    }
}

Describe 'Initialize-BenchBackend' {
    BeforeAll {
        Mock Import-BcContainerHelper -ModuleName Backend.Docker { }
        Mock Assert-DockerWindowsMode -ModuleName Backend.Docker { }
        $script:Url = 'https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net/sandbox/29.0.54011.57417/w1'
    }
    BeforeEach {
        $script:ConfigPath = Join-Path $TestDrive 'bench.json'
        Copy-Item (Join-Path $PSScriptRoot '..\config\bench.json') $script:ConfigPath -Force
        $script:Original = Get-Content $script:ConfigPath -Raw
        Mock Get-BcArtifactUrl -ModuleName Backend.Docker { $script:Url }
        Mock New-BcContainer -ModuleName Backend.Docker { }
        Mock Start-BcContainer -ModuleName Backend.Docker { }
        Mock New-BcCompilerFolder -ModuleName Backend.Docker { New-CompilerFolder 'hostcompiler' }
    }
    It 'creates the container and compiler folder and writes the path into bench.json' {
        $cfg = New-TestConfig
        Mock Test-BcContainer -ModuleName Backend.Docker { $false }

        Initialize-BenchBackend $cfg -ConfigPath $script:ConfigPath

        Should -Invoke Get-BcArtifactUrl -ModuleName Backend.Docker -ParameterFilter {
            $type -eq 'Sandbox' -and $country -eq 'w1' -and $version -eq '29.0.54011.57417'
        }
        Should -Invoke New-BcContainer -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter {
            $accept_eula -and $containerName -eq 'rfbench' -and $artifactUrl -eq $script:Url -and $auth -eq 'NavUserPassword' -and
            $credential.UserName -eq 'admin' -and $includeTestToolkit -and $includeTestLibrariesOnly -and $updateHosts -and $isolation -eq 'hyperv'
        }
        Should -Invoke New-BcCompilerFolder -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter { $artifactUrl -eq $script:Url }
        $expected = Join-Path $TestDrive 'hostcompiler'
        $cfg.Bc.CompilerFolder | Should -Be $expected
        (Get-Content $script:ConfigPath -Raw | ConvertFrom-Json).Bc.CompilerFolder | Should -Be $expected
        $escaped = ($expected | ConvertTo-Json)
        Get-Content $script:ConfigPath -Raw | Should -Be ($script:Original -replace '"CompilerFolder": ""', "`"CompilerFolder`": $escaped")
    }
    It 'is idempotent when the container runs and the compiler folder exists' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder 'existing'
        Mock Test-BcContainer -ModuleName Backend.Docker { $true }
        Initialize-BenchBackend $cfg -ConfigPath $script:ConfigPath
        Should -Invoke New-BcContainer -ModuleName Backend.Docker -Times 0 -Exactly
        Should -Invoke Start-BcContainer -ModuleName Backend.Docker -Times 0 -Exactly
        Should -Invoke New-BcCompilerFolder -ModuleName Backend.Docker -Times 0 -Exactly
        Get-Content $script:ConfigPath -Raw | Should -Be $script:Original
    }
    It 'starts an existing stopped container' {
        $cfg = New-TestConfig
        $cfg.Bc.CompilerFolder = New-CompilerFolder 'existing2'
        Mock Test-BcContainer -ModuleName Backend.Docker { -not $doNotIncludeStoppedContainers }
        Initialize-BenchBackend $cfg -ConfigPath $script:ConfigPath
        Should -Invoke New-BcContainer -ModuleName Backend.Docker -Times 0 -Exactly
        Should -Invoke Start-BcContainer -ModuleName Backend.Docker -Times 1 -Exactly -ParameterFilter { $containerName -eq 'rfbench' }
    }
    It 'throws when the pinned artifact version is not found' {
        $cfg = New-TestConfig
        Mock Get-BcArtifactUrl -ModuleName Backend.Docker { 'https://x/sandbox/29.0.99999.0/w1' }
        Mock Test-BcContainer -ModuleName Backend.Docker { $false }
        { Initialize-BenchBackend $cfg -ConfigPath $script:ConfigPath } | Should -Throw '*29.0.54011.57417*'
        Should -Invoke New-BcContainer -ModuleName Backend.Docker -Times 0 -Exactly
    }
    It 'refuses to run in linux mode' {
        $cfg = New-TestConfig
        Mock Assert-DockerWindowsMode -ModuleName Backend.Docker { throw 'Docker is in linux mode. Switch to Windows containers or pass -SwitchDocker.' }
        Mock Test-BcContainer -ModuleName Backend.Docker { $false }
        { Initialize-BenchBackend $cfg -ConfigPath $script:ConfigPath } | Should -Throw '*linux mode*'
        Should -Invoke New-BcContainer -ModuleName Backend.Docker -Times 0 -Exactly
    }
}
