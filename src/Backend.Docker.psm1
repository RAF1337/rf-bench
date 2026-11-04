#Requires -Version 7.6
Set-StrictMode -Version Latest

# Docker Desktop mode handling and the BcContainerHelper wrapper: container and compiler
# folder setup, compile with analyzers, publish, run tests, remove apps.
# BcContainerHelper is imported lazily by the functions that need it, never at module load.

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

$script:CompileLine = '^(?<file>.+)\((?<line>\d+),\d+\): (?<sev>error|warning) (?<rule>\w+): (?<msg>.+)$'
$script:UnlocatedLine = '^\s*(?<sev>error|warning) (?<rule>\w+): (?<msg>.+)$'

# --- private helpers -------------------------------------------------------------------------

# Wrappers around the external executables so tests can mock them.
function Invoke-DockerCli { & docker @args 2>&1 }
function Invoke-DockerSwitch { & (Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe') -SwitchDaemon }

function Import-BcContainerHelper {
    if (Get-Module BcContainerHelper) { return }
    if (Get-Module -ListAvailable BcContainerHelper) {
        Import-Module BcContainerHelper -Global -DisableNameChecking -ErrorAction Stop
        return
    }
    # pwsh does not search the Windows PowerShell module path by default.
    $roots = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\BcContainerHelper')
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\BcContainerHelper')
    )
    $psd1 = $roots | Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory } |
        Where-Object { Test-Path (Join-Path $_.FullName 'BcContainerHelper.psd1') } |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'BcContainerHelper.psd1' }
    if (-not $psd1) { throw "BcContainerHelper not found. Searched: PSModulePath; $($roots -join '; ')" }
    Import-Module $psd1 -Global -DisableNameChecking -ErrorAction Stop
}

function Get-BenchCredential($Config) {
    $var = [string]$Config.Bc.Credential.PasswordEnvVar
    $pw = [Environment]::GetEnvironmentVariable($var, 'Process')
    if (-not $pw) { $pw = [Environment]::GetEnvironmentVariable($var, 'User') }
    if (-not $pw) { throw "BC password not set: user environment variable '$var' (Bc.Credential.PasswordEnvVar) is empty." }
    [pscredential]::new([string]$Config.Bc.Credential.User, (ConvertTo-SecureString $pw -AsPlainText -Force))
}

# Host path for the xUnit result; it must be in a folder shared with the container.
function Get-XUnitResultPath($Config) {
    $helper = 'C:\ProgramData\BcContainerHelper'
    $cfgVar = Get-Variable bcContainerHelperConfig -Scope Global -ValueOnly -ErrorAction Ignore
    if ($cfgVar -and $cfgVar.hostHelperFolder) { $helper = $cfgVar.hostHelperFolder }
    $dir = Join-Path $helper "Extensions\$($Config.Bc.ContainerName)"
    New-Item -ItemType Directory $dir -Force | Out-Null
    Join-Path $dir "rfbench-xunit-$([guid]::NewGuid().ToString('N')).xml"
}

function Get-PinnedArtifactUrl($Config) {
    $version = [string]$Config.Bc.Version
    $url = Get-BcArtifactUrl -type $Config.Bc.ArtifactType -country $Config.Bc.Country -version $version -select Closest
    $url = @($url) | Select-Object -First 1
    if (-not $url -or $url -notmatch "/$([regex]::Escape($version))/") {
        throw "BC artifact $($Config.Bc.ArtifactType)/$($Config.Bc.Country)/$version not found (got '$url')."
    }
    $url
}

function Test-CompilerFolder([string]$Folder) {
    if (-not $Folder -or -not (Test-Path -LiteralPath (Join-Path $Folder 'symbols') -PathType Container)) { return $false }
    try { $null = Find-AlcPath $Folder; $true } catch { $false }
}

function Find-AlcPath([string]$Folder) {
    $candidates = @(
        (Join-Path $Folder 'compiler\extension\bin\win32\alc.exe')
        (Join-Path $Folder 'compiler\extension\bin\alc.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
    throw "alc.exe not found. Searched: $($candidates -join '; ')"
}

# Replaces the Bc.CompilerFolder string value in bench.json text, keeping all other text as is.
function Set-ConfigCompilerFolder([string]$ConfigPath, [string]$Folder) {
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $json = ConvertTo-Json -InputObject $Folder
    $rx = [regex]'("CompilerFolder"\s*:\s*)"(?:[^"\\]|\\.)*"'
    if (-not $rx.IsMatch($text)) { throw "bench.json: Bc.CompilerFolder not found in $ConfigPath" }
    $new = $rx.Replace($text, { param($m) $m.Groups[1].Value + $json }, 1)
    [IO.File]::WriteAllText($ConfigPath, $new, [Text.UTF8Encoding]::new($false))
}

# --- docker mode -----------------------------------------------------------------------------

function Get-DockerMode {
    [CmdletBinding()]
    param()
    $out = Invoke-DockerCli version --format '{{.Server.Os}}'
    $mode = ([string](@($out) | Select-Object -Last 1)).Trim().ToLowerInvariant()
    if ($mode -notin 'windows', 'linux') { throw "Docker is not running or not reachable: $($out -join ' ')" }
    $mode
}

function Switch-DockerMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('windows', 'linux')][string]$Mode,
        [int]$TimeoutSeconds = 180
    )
    if ((Get-DockerMode) -eq $Mode) { return }
    Invoke-DockerSwitch
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $current = $null
        try { $current = Get-DockerMode } catch { }   # daemon restarting
        if ($current -eq $Mode) { return }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Docker did not switch to $Mode mode within $TimeoutSeconds seconds."
        }
        Start-Sleep -Seconds 5
    }
}

function Assert-DockerWindowsMode {
    [CmdletBinding()]
    param()
    if ((Get-DockerMode) -ne 'windows') {
        throw 'Docker is in linux mode. Switch to Windows containers or pass -SwitchDocker.'
    }
}

# --- backend ---------------------------------------------------------------------------------

function Initialize-BenchBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Config,
        [string]$ConfigPath = (Join-Path $Config.RepoRoot 'config\bench.json')
    )
    Import-BcContainerHelper
    Assert-DockerWindowsMode
    $url = Get-PinnedArtifactUrl $Config
    $name = [string]$Config.Bc.ContainerName

    if (-not (Test-BcContainer -containerName $name)) {
        $cred = Get-BenchCredential $Config
        New-BcContainer -accept_eula -containerName $name -artifactUrl $url -auth NavUserPassword -credential $cred `
            -includeTestToolkit -includeTestLibrariesOnly -updateHosts -isolation hyperv
    }
    elseif (-not (Test-BcContainer -containerName $name -doNotIncludeStoppedContainers)) {
        Start-BcContainer -containerName $name
    }

    if (-not (Test-CompilerFolder ([string]$Config.Bc.CompilerFolder))) {
        # BcContainerHelper 6.1.15 New-BcCompilerFolder has no -includeTestToolkit/-includeTestLibrariesOnly;
        # it copies the test libraries into symbols itself. A fixed folder name keeps the path stable.
        $folder = @(New-BcCompilerFolder -artifactUrl $url -containerName $name) | Select-Object -Last 1
        $folder = [string]$folder
        if (-not (Test-CompilerFolder $folder)) { throw "New-BcCompilerFolder did not produce a usable compiler folder: '$folder'" }
        Set-ConfigCompilerFolder $ConfigPath $folder
        $Config.Bc.CompilerFolder = $folder
    }
}

function Get-AlcPath {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Config)
    $folder = [string]$Config.Bc.CompilerFolder
    if (-not $folder) { throw 'Bc.CompilerFolder not set; run src/Initialize-Backend.ps1' }
    Find-AlcPath $folder
}

function Invoke-AlCompile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Config,
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$OutFile,
        [switch]$EnableAnalyzers
    )
    $lines = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[object]]::new()
    $failure = $null

    if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'app.json') -PathType Leaf)) {
        $errors.Add("app.json not found in $AppDir")
    }
    else {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        try {
            Import-BcContainerHelper
            $params = @{
                compilerFolder        = [string]$Config.Bc.CompilerFolder
                appProjectFolder      = $AppDir
                appOutputFolder       = (Split-Path $OutFile -Parent)
                appName               = (Split-Path $OutFile -Leaf)
                AzureDevOps           = $false
                gitHubActions         = $false
                treatWarningsAsErrors = @()
                outputTo              = { param($line) $lines.Add([string]$line) }.GetNewClosure()
            }
            if ($EnableAnalyzers) {
                $params.EnableCodeCop = $true
                $params.EnableUICop = $true
                $params.EnablePerTenantExtensionCop = $true
            }
            $null = Compile-AppWithBcCompilerFolder @params 6>$null
        }
        catch { $failure = $_.Exception.Message }

        foreach ($l in $lines) {
            $m = [regex]::Match($l, $script:CompileLine)
            if (-not $m.Success) { $m = [regex]::Match($l, $script:UnlocatedLine) }
            if (-not $m.Success) { continue }
            if ($m.Groups['sev'].Value -eq 'error') { $errors.Add($l.Trim()); continue }
            $warnings.Add([pscustomobject]@{
                Rule    = $m.Groups['rule'].Value
                Message = $m.Groups['msg'].Value.Trim()
                File    = if ($m.Groups['file'].Success) { $m.Groups['file'].Value.Trim() } else { $null }
                Line    = if ($m.Groups['line'].Success) { [int]$m.Groups['line'].Value } else { 0 }
            })
        }
        if ($failure -and $errors.Count -eq 0) { $errors.Add($failure) }
    }

    $built = $errors.Count -eq 0 -and -not $failure -and (Test-Path -LiteralPath $OutFile -PathType Leaf)
    if ($errors.Count -eq 0 -and -not $built) { $errors.Add("Compiler produced no app file: $OutFile") }
    [pscustomobject]@{
        Success  = $built
        Errors   = [string[]]$errors.ToArray()
        Warnings = [object[]]$warnings.ToArray()
        AppFile  = if ($built) { $OutFile } else { $null }
        Output   = [string[]]$lines.ToArray()
    }
}

function Publish-BenchApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Config,
        [Parameter(Mandatory)][string]$AppFile
    )
    Import-BcContainerHelper
    Publish-BcContainerApp -containerName $Config.Bc.ContainerName -appFile $AppFile -sync -install -skipVerification 6>$null
}

function Remove-BenchApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Config,
        [Parameter(Mandatory)][guid]$AppId
    )
    Import-BcContainerHelper
    $name = [string]$Config.Bc.ContainerName
    $apps = @(Get-BcContainerAppInfo -containerName $name -tenantSpecificProperties 6>$null |
            Where-Object { "$($_.AppId)" -eq "$AppId" })
    foreach ($app in $apps) {
        $installed = $app.PSObject.Properties['IsInstalled'] -and [bool]$app.IsInstalled
        UnPublish-BcContainerApp -containerName $name -name $app.Name -publisher $app.Publisher -version "$($app.Version)" `
            -unInstall:$installed -doNotSaveData -doNotSaveSchema -force 6>$null
    }
}

function ConvertFrom-XUnitResult([string]$Path) {
    [xml]$doc = Get-Content -LiteralPath $Path -Raw
    foreach ($asm in @($doc.SelectNodes('/assemblies/assembly'))) {
        foreach ($t in @($asm.SelectNodes('collection/test'))) {
            $result = $t.GetAttribute('result')
            $msgNode = $t.SelectSingleNode('failure/message')
            $stackNode = $t.SelectSingleNode('failure/stack-trace')
            $message = if ($msgNode) { $msgNode.InnerText } elseif ($result -eq 'Skip') { 'Skipped' } else { $null }
            $name = $t.GetAttribute('method')
            [pscustomobject]@{
                Codeunit  = $asm.GetAttribute('name')
                Name      = $name
                Passed    = $result -eq 'Pass'
                Message   = $message
                CallStack = if ($stackNode) { $stackNode.InnerText } else { $null }
                IsBudget  = $name -like 'Budget_*'
            }
        }
    }
}

function Invoke-BenchTests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Config,
        [Parameter(Mandatory)][guid]$TestAppId
    )
    $cred = Get-BenchCredential $Config
    Import-BcContainerHelper
    $xml = Get-XUnitResultPath $Config
    try {
        Run-TestsInBcContainer -containerName $Config.Bc.ContainerName -credential $cred -extensionId "$TestAppId" `
            -XUnitResultFileName $xml -detailed 6>$null
        if (-not (Test-Path -LiteralPath $xml -PathType Leaf)) {
            throw "Test run for $TestAppId produced no xUnit result file ($xml)."
        }
        ConvertFrom-XUnitResult $xml
    }
    finally {
        Remove-Item -LiteralPath $xml -Force -ErrorAction Ignore
    }
}

Export-ModuleMember -Function Get-DockerMode, Switch-DockerMode, Assert-DockerWindowsMode, Initialize-BenchBackend,
    Get-AlcPath, Invoke-AlCompile, Publish-BenchApp, Remove-BenchApp, Invoke-BenchTests
