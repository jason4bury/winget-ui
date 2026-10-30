<# : batch part - runs the PowerShell part below. Just double-click this file.
@echo off
setlocal
set "BUILD_DIR=%~dp0"
set "BUILD_FILE=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:BUILD_FILE))"
set "BUILD_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %BUILD_RESULT%
: end of batch part #>

# ===========================================================================
# Build-Exe.cmd - compiles WinGet-GUI.ps1 into "WinGet-GUI v<version>.exe".
#
# Double-click this file (no admin rights needed). It:
#   1. sets the execution policy to Bypass for this build only (nothing
#      machine-wide changes),
#   2. installs the ps2exe module for the current user if it's missing
#      (turning on TLS 1.2 and installing the NuGet provider first, so this
#      works unattended on a fresh PC),
#   3. reads the version from $script:AppVersion in WinGet-GUI.ps1,
#   4. compiles the exe with -STA -requireAdmin -noConsole and the icon.
#
# Expects WinGet-GUI.ps1 and WinGet-GUI.ico in the same folder.
# Everything shown on screen is also written to Build-Exe.log.
# ===========================================================================

$ErrorActionPreference = 'Stop'

$here = if ($env:BUILD_DIR) { $env:BUILD_DIR.TrimEnd('\') } else { (Get-Location).Path }

$scriptPath = Join-Path $here 'WinGet-GUI.ps1'
$iconPath   = Join-Path $here 'WinGet-GUI.ico'
$logPath    = Join-Path $here 'Build-Exe.log'
$failed     = $false

try { Start-Transcript -LiteralPath $logPath -Force | Out-Null } catch { }

try {
    # Process scope = this build only. Needed because ps2exe's module file won't load
    # under PowerShell's default "Restricted" policy.
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Can't find the script to compile: $scriptPath"
    }

    $useIcon = Test-Path -LiteralPath $iconPath
    if (-not $useIcon) {
        Write-Warning "Icon file not found at '$iconPath' - building without a custom icon."
    }

    # Pull the version straight out of the script so the exe's version metadata never
    # drifts out of sync with $script:AppVersion.
    $version = '0.0.0'
    $versionMatch = Select-String -LiteralPath $scriptPath -Pattern "AppVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1
    if ($versionMatch) {
        $version = $versionMatch.Matches[0].Groups[1].Value
    } else {
        Write-Warning "Couldn't find `$script:AppVersion in $scriptPath - using '$version' instead."
    }
    $outputPath = Join-Path $here "WinGet-GUI v$version.exe"

    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-Host 'ps2exe module not found - installing for the current user (one-time)...' -ForegroundColor Cyan

        # Windows PowerShell 5.1 can default to older TLS versions that the PowerShell
        # Gallery no longer accepts ("unable to resolve package source").
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }

        # Install-Module needs the NuGet provider; installing it up front avoids the
        # "NuGet provider is required to continue" prompt.
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
                  Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
            Write-Host '  Installing the NuGet package provider...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }

        # -Force also skips the "untrusted repository" prompt for the PowerShell Gallery.
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
        Write-Host '  ps2exe installed.'
        Write-Host ''
    }
    Import-Module ps2exe

    Write-Host "Building WinGet-GUI v$version.exe..." -ForegroundColor Cyan
    Write-Host "  Script: $scriptPath"
    Write-Host "  Output: $outputPath"
    Write-Host ''

    $appArgs = @{
        inputFile    = $scriptPath
        outputFile   = $outputPath
        STA          = $true
        requireAdmin = $true
        noConsole    = $true
        title        = 'Winget Update Manager'
        version      = $version
        product      = 'Winget GUI'
    }
    if ($useIcon) { $appArgs['iconFile'] = $iconPath }
    Invoke-ps2exe @appArgs

    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "ps2exe didn't report an error, but $outputPath wasn't created."
    }
    Write-Host ''
    Write-Host "Done: $outputPath" -ForegroundColor Green
} catch {
    $failed = $true
    Write-Host ''
    Write-Host "Build failed: $($_.Exception.Message)" -ForegroundColor Red
}

try { Stop-Transcript | Out-Null } catch { }

if ($failed) { [Environment]::Exit(1) }
