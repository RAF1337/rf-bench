#Requires -Version 7.6
<#
.SYNOPSIS
    One-time backend setup: BC container (rfbench) and compiler folder.
.DESCRIPTION
    Creates the BC container for the pinned artifact if it does not exist (starts it if stopped),
    creates the compiler folder and writes its path as Bc.CompilerFolder into config/bench.local.json
    (gitignored, machine specific; Get-BenchConfig overlays it on config/bench.json).
    Idempotent. Requires Docker in Windows containers mode; with -SwitchDocker the script switches
    Docker to Windows mode and back to Linux mode when done.
    The BC password is read from the user environment variable named by Bc.Credential.PasswordEnvVar.
#>
[CmdletBinding()]
param(
    [switch]$SwitchDocker,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\bench.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backend.Docker.psm1') -Force

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$config = Get-BenchConfig -Path $ConfigPath
$switched = $false
try {
    if ($SwitchDocker -and (Get-DockerMode) -ne 'windows') {
        Write-Host 'Switching Docker to Windows containers...'
        Switch-DockerMode windows
        $switched = $true
    }
    Initialize-BenchBackend $config -ConfigPath $ConfigPath
    Write-Host "Container:       $($config.Bc.ContainerName)"
    Write-Host "Compiler folder: $($config.Bc.CompilerFolder)"
    Write-Host "alc.exe:         $(Get-AlcPath $config)"
}
finally {
    if ($switched) {
        Write-Host 'Switching Docker back to Linux containers...'
        Switch-DockerMode linux
    }
}
