<#
.SYNOPSIS
    Compiles WinGet-GUI.ps1 into a standalone WinGet-GUI.exe.

.DESCRIPTION
    Automates the ps2exe build steps from the README: sets the process-scoped execution
    policy ps2exe needs to load, installs the ps2exe module if it isn't already present,
    then compiles WinGet-GUI.ps1 into WinGet-GUI.exe with -STA, -requireAdmin and
    -noConsole baked into the exe's manifest, using WinGet-GUI.ico as its icon.

    The exe's version metadata is read straight out of $script:AppVersion in
    WinGet-GUI.ps1, so it can't drift out of sync with the script you're compiling.

    Must be run on a real Windows PowerShell (5.1) or PowerShell 7+ install - it can't
    produce an exe any other way. Run it from the same folder as WinGet-GUI.ps1 and
    WinGet-GUI.ico (the default), or point it elsewhere with -ScriptPath/-IconPath.

.PARAMETER ScriptPath
    Path to WinGet-GUI.ps1 to compile. Defaults to WinGet-GUI.ps1 next to this build script.

.PARAMETER IconPath
    Path to the .ico file to use for the exe. Defaults to WinGet-GUI.ico next to this
    build script. If not found, the exe is built without a custom icon instead of failing.

.PARAMETER OutputPath
    Path for the compiled .exe. Defaults to "WinGet-GUI v<version>.exe" next to this build
    script, with <version> read out of $script:AppVersion (e.g. "WinGet-GUI v1.11.0.exe").

.EXAMPLE
    .\Build-Exe.ps1

.EXAMPLE
    .\Build-Exe.ps1 -ScriptPath C:\Scripts\WinGet-GUI.ps1 -OutputPath C:\Scripts\Out\WinGet-GUI.exe
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'WinGet-GUI.ps1'),
    [string]$IconPath   = (Join-Path $PSScriptRoot 'WinGet-GUI.ico'),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Can't find the script to compile: $ScriptPath"
}

$useIcon = $true
if (-not (Test-Path -LiteralPath $IconPath)) {
    Write-Warning "Icon file not found at '$IconPath' - building without a custom icon."
    $useIcon = $false
}

# Pull the version straight out of the script so the exe's version metadata never
# drifts out of sync with $script:AppVersion as the script gets updated.
$version = '0.0.0'
$versionMatch = Select-String -LiteralPath $ScriptPath -Pattern "AppVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1
if ($versionMatch) {
    $version = $versionMatch.Matches[0].Groups[1].Value
} else {
    Write-Warning "Couldn't find `$script:AppVersion in $ScriptPath - using '$version' instead."
}

# Only fall back to a version-stamped default name if the caller didn't explicitly pass
# -OutputPath themselves.
if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
    $OutputPath = Join-Path $PSScriptRoot "WinGet-GUI v$version.exe"
}

Write-Host "Building WinGet-GUI.exe (version $version)..." -ForegroundColor Cyan
Write-Host "  Script: $ScriptPath"
Write-Host "  Output: $OutputPath"

# -Scope Process only affects this one console window, not the machine-wide policy -
# needed because ps2exe's own module file won't load under PowerShell's default
# "Restricted" policy.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "ps2exe module not found - installing for the current user (one-time)..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$buildArgs = @{
    inputFile    = $ScriptPath
    outputFile   = $OutputPath
    STA          = $true
    requireAdmin = $true
    noConsole    = $true
    title        = 'Winget Update Manager'
    version      = $version
    product      = 'Winget GUI'
}
if ($useIcon) {
    $buildArgs['iconFile'] = $IconPath
}

Invoke-ps2exe @buildArgs

if (Test-Path -LiteralPath $OutputPath) {
    Write-Host "Done: $OutputPath" -ForegroundColor Green
} else {
    throw "ps2exe didn't report an error, but $OutputPath wasn't created."
}
