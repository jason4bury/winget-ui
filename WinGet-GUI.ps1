<#
.SYNOPSIS
    Winget Update Manager - a simple WPF front end for winget.

.DESCRIPTION
    On launch it runs "winget upgrade" to list what's outdated. From there you can
    upgrade everything or just the selected packages, search for and install new
    software, view and uninstall installed apps, exclude packages from upgrades,
    export/import a list of apps, and see package details - with live output in
    the log pane.

    Tip: Ctrl+click or Shift+click in the list to select several packages; the
    "Selected" buttons then work through them one after another.

    It can also run unattended with no window (see -UpgradeAll), e.g. from Task
    Scheduler or an Intune script.

.PARAMETER UpgradeAll
    Run "winget upgrade --all" with no window, write a log file and exit with
    winget's exit code. Packages excluded in the GUI (winget pins) are skipped.

.PARAMETER Silent
    With -UpgradeAll: write nothing to the console, only to the log file.

.PARAMETER LogPath
    With -UpgradeAll: where to write the log. Defaults to
    %ProgramData%\WingetUpdateManager\Logs\upgrade-<date>-<time>.log

.PARAMETER SkipUnknown
    With -UpgradeAll: leave out packages whose installed version winget can't
    detect (by default they're included, like the GUI's default).

.PARAMETER IncludeStore
    With -UpgradeAll: include the Microsoft Store (msstore) source (by default
    only the "winget" source is used, like the GUI's default).

.PARAMETER KeepDesktopIcons
    With -UpgradeAll: don't remove desktop icons created by the upgrades.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WinGet-GUI.ps1
    Opens the GUI.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WinGet-GUI.ps1 -UpgradeAll -Silent
    Upgrades everything with no window and logs to %ProgramData%.
#>
param(
    [switch]$UpgradeAll,
    [switch]$Silent,
    [string]$LogPath,
    [switch]$SkipUnknown,
    [switch]$IncludeStore,
    [switch]$KeepDesktopIcons
)

# Bump this whenever you ship a change worth noting in CHANGELOG.md.
$script:AppVersion = '1.15.4'

$script:cliMode = [bool]$UpgradeAll
$script:showConsole = $script:cliMode -and -not $Silent

# ---------------------------------------------------------------------------
# Hide the PowerShell console window this script is running in, if any, so
# only the GUI shows. The compiled .exe (see README) already has no console
# via ps2exe's -noConsole switch, so this is a no-op there; it's for running
# the .ps1 directly (double-click, a shortcut, or an existing terminal),
# where a console window would otherwise sit behind/alongside the GUI. Done
# as early as possible to minimise any visible flash before it takes effect.
# Left visible in -UpgradeAll mode (unless -Silent) so progress can be seen.
# ---------------------------------------------------------------------------
if (-not $script:showConsole) {
    try {
        Add-Type -Name Window -Namespace Win32Console -MemberDefinition @'
            [System.Runtime.InteropServices.DllImport("kernel32.dll")]
            public static extern System.IntPtr GetConsoleWindow();
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop

        $consoleHandle = [Win32Console.Window]::GetConsoleWindow()
        if ($consoleHandle -ne [IntPtr]::Zero) {
            [Win32Console.Window]::ShowWindow($consoleHandle, 0) | Out-Null   # 0 = SW_HIDE
        }
    } catch {
        # Not fatal if this fails for any reason - worst case the console stays visible.
    }
}

# ---------------------------------------------------------------------------
# If this script has been compiled to a standalone .exe (e.g. with the ps2exe
# module), the host process is that .exe rather than powershell.exe/pwsh.exe,
# so the manual relaunch tricks below don't apply and would just misfire.
# Compile with ps2exe's own -STA and -requireAdmin switches instead, which bake
# both requirements into the .exe's manifest and are handled by Windows before
# our code even starts running. See README.md for the exact build command.
# ---------------------------------------------------------------------------
$hostExeName   = [System.IO.Path]::GetFileNameWithoutExtension((Get-Process -Id $PID).Path)
$isCompiledExe = $hostExeName -notin @('powershell', 'pwsh')

function Get-RelaunchArguments {
    # Rebuilds the command line for a relaunch, passing along whatever parameters
    # this run was started with (e.g. -UpgradeAll -Silent) so they aren't lost.
    $relaunchArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($key in $script:boundParams.Keys) {
        $value = $script:boundParams[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $relaunchArgs += "-$key" }
        } else {
            $relaunchArgs += "-$key"
            $relaunchArgs += "`"$value`""
        }
    }
    return $relaunchArgs
}
$script:boundParams = $PSBoundParameters

if (-not $isCompiledExe) {
    # -------------------------------------------------------------------
    # Installing/upgrading software and managing shortcuts on the shared
    # Public Desktop both normally need administrator rights, so relaunch
    # elevated automatically if we're not already running as admin, rather
    # than hitting "Access is denied" errors partway through.
    # -------------------------------------------------------------------
    $currentIdentity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $exe = (Get-Process -Id $PID).Path
        $windowStyle = if ($script:showConsole) { 'Normal' } else { 'Hidden' }
        try {
            # -STA is included here too so an elevated relaunch satisfies both requirements
            # (admin rights and a WPF-compatible thread) in a single relaunch.
            Start-Process -FilePath $exe -ArgumentList (Get-RelaunchArguments) -Verb RunAs -WindowStyle $windowStyle | Out-Null
        } catch {
            # Most likely the UAC prompt was cancelled, or this account can't elevate at all.
            if (-not $script:cliMode) {
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show(
                    "Winget Update Manager needs to run as Administrator (installing/upgrading software " +
                    "and managing the shared Public Desktop both require it), but elevation was cancelled " +
                    "or failed.`r`n`r`n$($_.Exception.Message)",
                    "Winget GUI", 'OK', 'Error') | Out-Null
            }
            exit 1
        }
        exit
    }

    # WPF needs an STA thread. Windows PowerShell defaults to STA, but PowerShell 7 (pwsh)
    # defaults to MTA, so relaunch ourselves with -STA if needed. (Normally already satisfied
    # by the elevation relaunch above, but this covers running the script from an already-
    # elevated pwsh session directly.) Not needed for -UpgradeAll, which has no window.
    if (-not $script:cliMode -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList (Get-RelaunchArguments) -WindowStyle Hidden
        exit
    }
}

# ---------------------------------------------------------------------------
# Find winget. Normally it's on PATH via its App Execution Alias, but not when
# running as SYSTEM (Intune scripts, scheduled tasks), so fall back to the
# App Installer package folder in that case.
# ---------------------------------------------------------------------------
function Resolve-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    $appsFolder = Join-Path $env:ProgramFiles 'WindowsApps'
    $candidates = Get-ChildItem -Path $appsFolder -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Descending -Property @{ Expression = { try { [version](($_.Name -split '_')[1]) } catch { [version]'0.0' } } }
    foreach ($dir in $candidates) {
        $path = Join-Path $dir.FullName 'winget.exe'
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}
$script:WingetExe = Resolve-WingetPath

# ---------------------------------------------------------------------------
# Logging. In the GUI, log text goes to the log pane; in -UpgradeAll mode it
# goes to the log file (and the console, unless -Silent).
# ---------------------------------------------------------------------------
$script:cliLogPath = $null
$txtLog = $null

function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    if ($script:cliMode) {
        try { Add-Content -LiteralPath $script:cliLogPath -Value $Text -NoNewline -Encoding UTF8 } catch { }
        # Never Write-Host here: a ps2exe -noConsole build turns console output into pop-ups.
        if ($script:showConsole -and -not $isCompiledExe) { [Console]::Out.Write($Text) }
        return
    }
    $txtLog.AppendText($Text)
    $txtLog.ScrollToEnd()
}

function Read-OutputFile {
    # winget writes UTF-8 when its output is redirected. Windows PowerShell 5.1's
    # Get-Content assumes the system ANSI code page unless told otherwise, which
    # mangles winget's truncation character and any non-ASCII package names (and
    # can then throw the column slicing off), so always read as UTF-8.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-WingetTableColumns {
    <#
      Figures out which of winget's known column headers are actually present in a
      given header line, and where each one starts. Different winget commands print
      different columns ("upgrade" has Name/Id/Version/Available/Source; "search"
      has Name/Id/Version/Source, sometimes with an extra "Match" column in the
      middle; "pin list" ends with "Pin type"), so this is detected per-table rather
      than assumed fixed.
    #>
    param([string]$HeaderLine)

    $candidates = @('Name', 'Id', 'Version', 'Match', 'Available', 'Source', 'Pin type')
    $found = @()
    foreach ($name in $candidates) {
        $m = [regex]::Match($HeaderLine, "\b$name\b")
        if ($m.Success) {
            $found += [PSCustomObject]@{ Name = $name; Start = $m.Index }
        }
    }

    return @($found | Sort-Object Start)
}

function ConvertFrom-WingetUpgradeTable {
    <#
      winget's tables ("upgrade", "search", "list", "pin list") are column-aligned,
      not delimited, so we find the header row, work out which columns are actually
      present and where each one starts, then slice every following line at those
      offsets.
    #>
    param([string[]]$Lines)

    $results = @()

    $headerIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^Name\s+Id\s+Version') {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0) { return $results }

    $header  = $Lines[$headerIndex]
    $columns = Get-WingetTableColumns -HeaderLine $header

    if ($columns.Count -lt 3) { return $results }

    # Row after the header is the "----" separator; data starts after that.
    for ($i = $headerIndex + 2; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]

        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -match '^\d+\s+upgrades? available' -or
            $line -match '^No installed package found' -or
            $line -match '^No package found matching input criteria') { break }

        $pad = $line
        if ($pad.Length -lt $header.Length) { $pad = $pad.PadRight($header.Length) }

        $values = @{}
        for ($c = 0; $c -lt $columns.Count; $c++) {
            $start = $columns[$c].Start
            $end   = if ($c -lt $columns.Count - 1) { $columns[$c + 1].Start } else { $pad.Length }
            if ($end -lt $start) { $end = $start }
            $values[$columns[$c].Name] = $pad.Substring($start, $end - $start).Trim()
        }

        $name = $values['Name']
        $id   = $values['Id']

        if ($name -and $id) {
            $results += [PSCustomObject]@{
                Name      = $name
                Id        = $id
                Version   = $values['Version']
                Available = if ($values.ContainsKey('Available')) { $values['Available'] } else { '' }
                Source    = if ($values.ContainsKey('Source')) { $values['Source'] } else { '' }
            }
        }
    }

    return $results
}

function Get-DesktopShortcutSnapshot {
    # Covers both the current user's Desktop and the shared "Public" Desktop, since
    # installers can drop a shortcut in either depending on install scope.
    $paths = @()
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
        if ($folder -and (Test-Path $folder)) {
            $paths += Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.lnk', '.url' } |
                Select-Object -ExpandProperty FullName
        }
    }
    return @($paths)
}

function Test-ShortcutRelatesToPackage {
    <#
      Only treat a newly-appeared shortcut as "created by this install/upgrade" if its
      filename plausibly matches one of the package names involved, rather than removing
      *any* shortcut that happens to be new. Without this, an icon you (or something else)
      added to the Desktop in the few seconds around an install/upgrade - including one
      already pinned there - could get swept up and deleted along with the real one.
    #>
    param(
        [string]$ShortcutPath,
        [string[]]$RelatedNames
    )

    if (-not $RelatedNames -or $RelatedNames.Count -eq 0) { return $true }

    $shortcutName = [System.IO.Path]::GetFileNameWithoutExtension($ShortcutPath)
    if (-not $shortcutName) { return $true }

    foreach ($name in $RelatedNames) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        # Direct containment either way (handles e.g. "Adobe Acrobat" vs. "Adobe Acrobat DC").
        if ($shortcutName -like "*$name*" -or $name -like "*$shortcutName*") { return $true }

        # Word-level overlap, so a longer package name like "Adobe Acrobat Reader DC (64-bit)"
        # still matches a shortcut named just "Acrobat Reader.lnk".
        $words = $name -split '[^a-zA-Z0-9]+' | Where-Object { $_.Length -ge 3 }
        foreach ($w in $words) {
            if ($shortcutName -match [regex]::Escape($w)) { return $true }
        }
    }

    return $false
}

# Shortcuts already reported as "left alone", so the 20-second re-check doesn't
# log the same message every two seconds.
$script:reportedSkips = New-Object System.Collections.Generic.HashSet[string]

function Remove-NewDesktopShortcuts {
    param([string[]]$Before, [string[]]$RelatedNames)

    if (-not $Before) { return }

    $after = Get-DesktopShortcutSnapshot
    $new   = @($after | Where-Object { $Before -notcontains $_ })

    $toRemove = @($new | Where-Object { Test-ShortcutRelatesToPackage -ShortcutPath $_ -RelatedNames $RelatedNames })
    $toSkip   = @($new | Where-Object { $_ -notin $toRemove })

    foreach ($p in $toSkip) {
        if ($script:reportedSkips.Add($p)) {
            Append-Log "`r`nLeaving new desktop icon alone (doesn't look related to what was just installed/upgraded): $p`r`n"
        }
    }

    if ($toRemove.Count -gt 0) {
        Append-Log "`r`nRemoving $($toRemove.Count) new desktop icon(s) created by this install/upgrade:`r`n"
        foreach ($p in $toRemove) {
            # The app always runs elevated (see the relaunch logic at the top, or ps2exe's
            # -requireAdmin for the .exe), so a failure here is a genuine problem such as the
            # file being locked, not a missing-rights issue that a second elevation would fix.
            try {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                Append-Log "  Removed: $p`r`n"
            } catch {
                Append-Log "  Could not remove ${p}: $($_.Exception.Message)`r`n"
            }
        }
    }
}

function Start-HiddenProcess {
    <#
      Starts a console program with no window and its output sent to files.
      Start-Process -NoNewWindow only avoids a new window when there's already a
      console to share; the compiled .exe has none, so Windows would pop up a
      command prompt window for every winget run. CreateNoWindow stops that, and
      cmd.exe does the redirection to the files the log pane reads from.
    #>
    param([string]$FilePath, [string]$Arguments, [string]$OutFile, [string]$ErrFile, [string]$WorkingDirectory)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = Join-Path $env:SystemRoot 'System32\cmd.exe'
    # /s + the outer quotes keep cmd from mangling the quoted parts inside.
    $psi.Arguments       = '/d /s /c ""{0}" {1} 1>"{2}" 2>"{3}""' -f $FilePath, $Arguments, $OutFile, $ErrFile
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-HiddenCapture {
    # Runs a console program hidden, waits for it and returns its text output.
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutMs = 20000)
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-HiddenProcess -FilePath $FilePath -Arguments $Arguments -OutFile $out -ErrFile $err
        [void]$p.WaitForExit($TimeoutMs)
        return [string](Read-OutputFile -Path $out)
    } catch {
        return ''
    } finally {
        Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    }
}

function Get-WingetVersion {
    $v = ([string](Invoke-HiddenCapture -FilePath $script:WingetExe -Arguments '--version' -TimeoutMs 10000)).Trim()
    if ($v) { return ($v -split "`r?`n")[0] } else { return 'unknown' }
}

function Stop-ProcessTree {
    # winget starts the actual installer as a child process, so kill the whole tree
    # rather than just winget itself, or the installer carries on in the background.
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $kill = New-Object System.Diagnostics.ProcessStartInfo
            $kill.FileName        = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $kill.Arguments       = "/PID $($Process.Id) /T /F"
            $kill.UseShellExecute = $false
            $kill.CreateNoWindow  = $true
            [void]([System.Diagnostics.Process]::Start($kill)).WaitForExit(10000)
        }
    } catch { }
}

# ===========================================================================
# Unattended mode: -UpgradeAll. No window; log to file; exit with winget's code.
# ===========================================================================
function Invoke-WingetCli {
    param([string]$Arguments)

    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    Append-Log "> winget $Arguments`r`n"
    try {
        $p = Start-HiddenProcess -FilePath $script:WingetExe -Arguments $Arguments -OutFile $out -ErrFile $err `
            -WorkingDirectory (Split-Path -Parent $script:WingetExe)
        $p.WaitForExit()
        $text = Read-OutputFile -Path $out
        $errText = Read-OutputFile -Path $err
        if ($text) { Append-Log $text }
        if ($errText) { Append-Log $errText }
        return [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = [string]$text }
    } finally {
        Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    }
}

if ($script:cliMode) {
    if (-not $LogPath) {
        $logFolder = Join-Path $env:ProgramData 'WingetUpdateManager\Logs'
        $LogPath = Join-Path $logFolder ("upgrade-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $script:cliLogPath = $LogPath
    try { New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force -ErrorAction Stop | Out-Null } catch { }

    Append-Log ("Winget Update Manager {0} - unattended Upgrade All`r`n" -f $script:AppVersion)
    Append-Log ("Started {0} as {1}\{2} on {3}`r`n`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)

    if (-not $script:WingetExe) {
        Append-Log "winget was not found on this PC. Install 'App Installer' and try again.`r`n"
        exit 1
    }

    $srcArg     = if ($IncludeStore) { '' } else { '--source winget' }
    $unknownArg = if ($SkipUnknown) { '' } else { '--include-unknown' }

    $check = Invoke-WingetCli "upgrade $unknownArg $srcArg --accept-source-agreements --disable-interactivity"
    $pending = @(ConvertFrom-WingetUpgradeTable -Lines ($check.Output -split "`r?`n"))
    Append-Log "`r`n$($pending.Count) package(s) to upgrade.`r`n`r`n"

    if ($pending.Count -eq 0) {
        Append-Log "Nothing to do.`r`n"
        exit 0
    }

    $before = if ($KeepDesktopIcons) { $null } else { Get-DesktopShortcutSnapshot }

    $result = Invoke-WingetCli "upgrade --all $unknownArg $srcArg --accept-package-agreements --accept-source-agreements --disable-interactivity"

    if ($before) {
        # Same 20-second grace period as the GUI, for installers that create their
        # shortcut from a background process after winget has already exited.
        $names = @($pending | ForEach-Object { $_.Name })
        for ($i = 0; $i -lt 10; $i++) {
            Remove-NewDesktopShortcuts -Before $before -RelatedNames $names
            Start-Sleep -Seconds 2
        }
    }

    $hex = '0x{0:X8}' -f [int]$result.ExitCode
    Append-Log ("`r`nFinished {0}. winget exit code: {1} ({2})`r`nLog: {3}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $result.ExitCode, $hex, $LogPath)
    exit $result.ExitCode
}

# ===========================================================================
# GUI mode
# ===========================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
# Make sure winget is actually available before we build any UI.
# ---------------------------------------------------------------------------
if (-not $script:WingetExe) {
    [System.Windows.MessageBox]::Show(
        "winget was not found on this PC. Install 'App Installer' from the Microsoft Store, then try again.",
        "Winget GUI", 'OK', 'Error') | Out-Null
    exit
}

# ---------------------------------------------------------------------------
# UI definition
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Winget Update Manager" Height="1120" Width="1360" MinWidth="940" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#FFF7EA" FontFamily="Segoe UI" FontSize="13"
        Foreground="#2B2340">
    <Window.Resources>
        <!-- Palette, matching the box mascot -->
        <SolidColorBrush x:Key="Ink" Color="#2B2340"/>
        <SolidColorBrush x:Key="SoftInk" Color="#5E5672"/>
        <SolidColorBrush x:Key="Card" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="CardEdge" Color="#EADFCB"/>
        <SolidColorBrush x:Key="Mint" Color="#7BE0A0"/>
        <SolidColorBrush x:Key="Sky" Color="#7FD8FF"/>
        <SolidColorBrush x:Key="Periwinkle" Color="#5B7CFA"/>
        <SolidColorBrush x:Key="Sun" Color="#FFE066"/>
        <SolidColorBrush x:Key="Blush" Color="#FFB4C2"/>
        <SolidColorBrush x:Key="Lilac" Color="#EEE8FF"/>

        <!-- Rounded "pill" buttons. Tag holds an optional Segoe MDL2 Assets icon glyph. -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#2B2340"/>
            <Setter Property="BorderBrush" Value="#2B2340"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="Margin" Value="0,0,8,8"/>
            <Setter Property="MinWidth" Value="40"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="Shadow" CornerRadius="17" Background="#2B2340" Margin="0,3,0,-3" Opacity="0.9"/>
                            <Border x:Name="Face" CornerRadius="17" Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                                <Grid>
                                    <Border x:Name="Glow" CornerRadius="16" Background="#FFFFFF" Opacity="0"/>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"
                                                Margin="{TemplateBinding Padding}">
                                        <TextBlock x:Name="Glyph" Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets"
                                                   FontSize="14" FontWeight="Normal" VerticalAlignment="Center" Margin="0,1,7,0"/>
                                        <ContentPresenter VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Tag" Value="{x:Null}">
                                <Setter TargetName="Glyph" Property="Visibility" Value="Collapsed"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Glow" Property="Opacity" Value="0.35"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Face" Property="RenderTransform">
                                    <Setter.Value><TranslateTransform Y="2"/></Setter.Value>
                                </Setter>
                                <Setter TargetName="Shadow" Property="Margin" Value="0,1,0,-1"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="MintButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#7BE0A0"/>
        </Style>
        <Style x:Key="SkyButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#CDEFFF"/>
        </Style>
        <Style x:Key="SunButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#FFE066"/>
        </Style>
        <Style x:Key="BlushButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#FFB4C2"/>
        </Style>
        <Style x:Key="LilacButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#EEE8FF"/>
        </Style>
        <Style x:Key="HeaderButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Margin" Value="8,0,0,0"/>
        </Style>

        <!-- Rounded text boxes for search and filter -->
        <Style x:Key="PillBox" TargetType="TextBox">
            <Setter Property="Height" Value="34"/>
            <Setter Property="Padding" Value="12,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Foreground" Value="#2B2340"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Box" CornerRadius="17" Background="#FFFFFF" BorderBrush="#2B2340" BorderThickness="1.5">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="#5B7CFA"/>
                                <Setter TargetName="Box" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- White rounded cards -->
        <Style x:Key="CardBox" TargetType="Border">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#EADFCB"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="CornerRadius" Value="16"/>
            <Setter Property="Padding" Value="12,12,4,4"/>
        </Style>
        <Style x:Key="CardTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="#8A80A0"/>
            <Setter Property="Margin" Value="2,0,0,6"/>
        </Style>

        <!-- Friendly data grid -->
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#EEE8FF"/>
            <Setter Property="Foreground" Value="#2B2340"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" Padding="10,0">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#CFE0FF"/>
                    <Setter Property="Foreground" Value="#2B2340"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#2B2340"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="232"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Grid.ColumnSpan="2" CornerRadius="20" Padding="14,8" Margin="0,0,0,14" BorderBrush="#2B2340" BorderThickness="1.5">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#3FA4EE" Offset="0"/>
                    <GradientStop Color="#5B6CF0" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Image x:Name="ImgLogo" Grid.Column="0" Width="58" Height="58" Margin="0,0,12,0" VerticalAlignment="Center"
                       RenderOptions.BitmapScalingMode="HighQuality"/>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="Winget Update Manager" FontSize="23" FontWeight="Bold" Foreground="#FFFFFF"/>
                    <TextBlock x:Name="TxtGreeting" Text="Keeping your apps fresh, no terminal needed." FontSize="13" Foreground="#FFFFFF" Margin="1,1,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnAbout" Content="About" Tag="&#xE946;" Style="{StaticResource HeaderButton}"/>
                    <Button x:Name="BtnExit" Content="Exit" Tag="&#xE7E8;" Style="{StaticResource HeaderButton}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Sidebar with all the actions -->
        <ScrollViewer Grid.Row="1" Grid.Column="0" VerticalScrollBarVisibility="Auto" Margin="0,0,14,0">
            <StackPanel>
                <Border Style="{StaticResource CardBox}" Padding="12,10,12,4" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="UPDATES" Style="{StaticResource CardTitle}"/>
                        <Button x:Name="BtnCheck" Content="Check for Updates" Tag="&#xE72C;" Style="{StaticResource SkyButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Show packages with an update available"/>
                        <Button x:Name="BtnUpgradeSelected" Content="Upgrade Selected" Tag="&#xE74A;" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Upgrade the selected package(s). Ctrl+click or Shift+click to select several."/>
                        <Button x:Name="BtnUpgradeAll" Content="Upgrade All" Tag="&#xE895;" Style="{StaticResource MintButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Upgrade everything with an update available (excluded apps are skipped)"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBox}" Padding="12,10,12,4" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="FIND NEW APPS" Style="{StaticResource CardTitle}"/>
                        <TextBox x:Name="TxtSearchQuery" Margin="0,0,0,7" Style="{StaticResource PillBox}"
                                 ToolTip="Type a name (e.g. 'notepad++') then press Enter or click Search"/>
                        <Button x:Name="BtnSearch" Content="Search" Tag="&#xE721;" Style="{StaticResource SkyButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"/>
                        <Button x:Name="BtnInstallSelected" Content="Install Selected" Tag="&#xE896;" Style="{StaticResource MintButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Install the selected search result(s). Ctrl+click or Shift+click to select several."/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBox}" Padding="12,10,12,4" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="INSTALLED APPS" Style="{StaticResource CardTitle}"/>
                        <Button x:Name="BtnInstalled" Content="Installed Apps" Tag="&#xE71D;" Style="{StaticResource SkyButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Show everything installed on this PC"/>
                        <Button x:Name="BtnUninstallSelected" Content="Uninstall Selected" Tag="&#xE74D;" Style="{StaticResource BlushButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Uninstall the selected app(s)"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBox}" Padding="12,10,12,4" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="LEAVE ALONE" Style="{StaticResource CardTitle}"/>
                        <Button x:Name="BtnExcluded" Content="Excluded Apps" Tag="&#xE72E;" Style="{StaticResource SkyButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Show apps excluded from Upgrade All (winget pins)"/>
                        <Button x:Name="BtnExcludeSelected" Content="Exclude Selected" Tag="&#xE72E;" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Stop Upgrade All (and -UpgradeAll mode) from upgrading the selected app(s)"/>
                        <Button x:Name="BtnRemoveExclusion" Content="Remove Exclusion" Tag="&#xE785;" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Let Upgrade All upgrade the selected app(s) again"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBox}" Padding="12,10,12,4" Margin="0,0,0,0">
                    <StackPanel>
                        <TextBlock Text="TOOLS" Style="{StaticResource CardTitle}"/>
                        <Button x:Name="BtnExport" Content="Export List..." Tag="&#xE74E;" Style="{StaticResource LilacButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Save a list of installed apps to a file (winget export)"/>
                        <Button x:Name="BtnImport" Content="Import List..." Tag="&#xE8E5;" Style="{StaticResource LilacButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Install every app in a list saved with Export List (winget import)"/>
                        <Button x:Name="BtnResetSources" Content="Reset Sources" Tag="&#xE895;" Style="{StaticResource LilacButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Reset winget's sources when searches keep failing"/>
                        <Button x:Name="BtnDiagnose" Content="Diagnose Network" Tag="&#xE9D9;" Style="{StaticResource LilacButton}" HorizontalContentAlignment="Left" Margin="0,0,0,7"
                                ToolTip="Check whether winget can reach its servers"/>
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <!-- Main area -->
        <Grid Grid.Row="1" Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*" MinHeight="160"/>
                <RowDefinition Height="8"/>
                <RowDefinition x:Name="LogRow" Height="380" MinHeight="120"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Current view, options, filter -->
            <Grid Grid.Row="0" Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" CornerRadius="14" Background="#2B2340" Padding="14,6" Margin="0,0,16,0" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtView" FontWeight="Bold" FontSize="14" Foreground="#FFFFFF" Text="Updates available"/>
                </Border>
                <WrapPanel Grid.Column="1" VerticalAlignment="Center">
                    <CheckBox x:Name="ChkIncludeUnknown" Content="Include unknown versions" Margin="0,3,16,3" IsChecked="True"/>
                    <CheckBox x:Name="ChkSkipStore" Content="Skip Microsoft Store source" Margin="0,3,16,3" IsChecked="True"
                              ToolTip="Only use the winget source, skipping the Microsoft Store (msstore) source"/>
                    <CheckBox x:Name="ChkRemoveDesktopIcons" Content="Tidy up new desktop icons" Margin="0,3,16,3" IsChecked="True"
                              ToolTip="Remove desktop icons that installs and upgrades create"/>
                </WrapPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="&#xE71C;" FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#5E5672"/>
                    <TextBox x:Name="TxtFilter" Width="200" Style="{StaticResource PillBox}"
                             ToolTip="Show only rows whose name or Id contains this text. Doesn't affect Upgrade All."/>
                    <Button x:Name="BtnClearFilter" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontWeight="Normal"
                            Width="34" MinWidth="34" Padding="0" Margin="6,0,0,0" ToolTip="Clear filter"/>
                </StackPanel>
            </Grid>

            <!-- Package list + details pane -->
            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" MinWidth="300"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="320" MinWidth="200"/>
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Style="{StaticResource CardBox}" Padding="6">
                    <Grid>
                        <DataGrid x:Name="Grid1" AutoGenerateColumns="False" IsReadOnly="True"
                                  SelectionMode="Extended" SelectionUnit="FullRow"
                                  Background="#FFFFFF" RowBackground="#FFFFFF" AlternatingRowBackground="#FBF7F0"
                                  BorderThickness="0" RowHeight="32" Foreground="#2B2340"
                                  CanUserAddRows="False" CanUserDeleteRows="False" GridLinesVisibility="None"
                                  HeadersVisibility="Column"
                                  ToolTip="Ctrl+click or Shift+click to select several. Double-click for details.">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="2*"/>
                                <DataGridTextColumn Header="Id" Binding="{Binding Id}" Width="2*"/>
                                <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="1*"/>
                                <DataGridTextColumn Header="Available" Binding="{Binding Available}" Width="1*"/>
                                <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="1*"/>
                            </DataGrid.Columns>
                        </DataGrid>
                        <StackPanel x:Name="PnlEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"
                                    IsHitTestVisible="False">
                            <Image x:Name="ImgEmpty" Width="96" Height="96" RenderOptions.BitmapScalingMode="HighQuality"/>
                            <TextBlock x:Name="TxtEmpty" FontSize="15" FontWeight="SemiBold" Foreground="#5E5672"
                                       HorizontalAlignment="Center" TextAlignment="Center" Margin="0,8,0,0"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <GridSplitter Grid.Column="1" Width="10" HorizontalAlignment="Stretch" Background="Transparent"/>

                <Border Grid.Column="2" Style="{StaticResource CardBox}" Padding="14,12,6,4">
                    <DockPanel>
                        <TextBlock DockPanel.Dock="Top" Text="DETAILS" Style="{StaticResource CardTitle}"/>
                        <WrapPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                            <Button x:Name="BtnDetails" Content="Show Details" Tag="&#xE946;" Style="{StaticResource SkyButton}"
                                    ToolTip="Show details for the selected package (or double-click it)"/>
                            <Button x:Name="BtnHomepage" Content="Homepage" Tag="&#xE8A7;" IsEnabled="False"/>
                            <Button x:Name="BtnReleaseNotes" Content="Release Notes" Tag="&#xE8A7;" IsEnabled="False"/>
                        </WrapPanel>
                        <ScrollViewer x:Name="ScrDetails" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,0,0">
                            <StackPanel x:Name="PnlDetails" Margin="0,0,10,0">
                                <TextBlock x:Name="TxtDetails" TextWrapping="Wrap" Foreground="#5E5672" LineHeight="20"
                                           Text="Pick a package and click Show Details (or just double-click it) to see who makes it, what it does and where to find out more."/>
                            </StackPanel>
                        </ScrollViewer>
                    </DockPanel>
                </Border>

                <!-- Progress card, shown over the list while winget is working -->
                <Border x:Name="PnlBusy" Grid.ColumnSpan="3" Background="#D9FFF7EA" CornerRadius="16" Visibility="Collapsed">
                    <Border Style="{StaticResource CardBox}" Padding="22,18,22,14" BorderBrush="#2B2340"
                            HorizontalAlignment="Center" VerticalAlignment="Center" Width="460">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal">
                                <Image x:Name="ImgBusy" Width="52" Height="52" Margin="0,0,14,0" RenderOptions.BitmapScalingMode="HighQuality">
                                    <Image.RenderTransform>
                                        <TranslateTransform/>
                                    </Image.RenderTransform>
                                    <Image.Triggers>
                                        <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                                            <BeginStoryboard>
                                                <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                                    <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)"
                                                                     From="0" To="-6" Duration="0:0:0.6">
                                                        <DoubleAnimation.EasingFunction>
                                                            <SineEase EasingMode="EaseInOut"/>
                                                        </DoubleAnimation.EasingFunction>
                                                    </DoubleAnimation>
                                                </Storyboard>
                                            </BeginStoryboard>
                                        </EventTrigger>
                                    </Image.Triggers>
                                </Image>
                                <StackPanel VerticalAlignment="Center" Width="350">
                                    <TextBlock x:Name="TxtBusyTitle" FontSize="16" FontWeight="Bold" TextWrapping="Wrap" Text="Working..."/>
                                    <TextBlock x:Name="TxtBusyDetail" Foreground="#5E5672" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
                                </StackPanel>
                            </StackPanel>
                            <ProgressBar x:Name="BusyBar" Height="14" Margin="0,16,0,10" IsIndeterminate="True"
                                         Foreground="#7BE0A0" Background="#F3ECDD" BorderBrush="#2B2340" BorderThickness="1"/>
                            <Grid>
                                <TextBlock x:Name="TxtBusyTime" Foreground="#8A80A0" VerticalAlignment="Center"/>
                                <Button x:Name="BtnBusyCancel" Content="Cancel" Tag="&#xE711;" Style="{StaticResource SunButton}"
                                        HorizontalAlignment="Right" Margin="0,0,0,4"/>
                            </Grid>
                        </StackPanel>
                    </Border>
                </Border>
            </Grid>

            <GridSplitter Grid.Row="2" Height="8" HorizontalAlignment="Stretch" VerticalAlignment="Center"
                          ResizeDirection="Rows" ResizeBehavior="PreviousAndNext" Background="Transparent"/>

            <!-- Log -->
            <Border Grid.Row="3" CornerRadius="16" Background="#2B2340" Padding="12,8,4,4" BorderBrush="#2B2340" BorderThickness="1.5">
                <DockPanel>
                    <Grid DockPanel.Dock="Top" Margin="2,0,8,6">
                        <TextBlock Text="WHAT'S HAPPENING" FontSize="11" FontWeight="Bold" Foreground="#9D93C0" VerticalAlignment="Center"/>
                        <Button x:Name="BtnSaveLog" Content="Save Log..." Tag="&#xE74E;" Style="{StaticResource LilacButton}"
                                HorizontalAlignment="Right" Height="28" Margin="0" BorderBrush="#EEE8FF"
                                ToolTip="Save this log to a text file"/>
                    </Grid>
                    <TextBox x:Name="TxtLog" FontFamily="Consolas" FontSize="12"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             IsReadOnly="True" TextWrapping="NoWrap" Background="#2B2340" Foreground="#EDE8FF" BorderThickness="0"/>
                </DockPanel>
            </Border>

            <!-- Status, progress and Cancel -->
            <Grid Grid.Row="4" Margin="2,12,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="TxtStatus" Grid.Column="0" Text="Hi! Getting ready..." FontWeight="SemiBold" Foreground="#5E5672"
                           VerticalAlignment="Center" Margin="0,0,16,0"/>
                <ProgressBar x:Name="Progress" Grid.Column="1" Height="8" IsIndeterminate="False" Visibility="Collapsed"
                             Foreground="#7BE0A0" Background="#EADFCB" BorderThickness="0" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <Button x:Name="BtnCancel" Grid.Column="2" Content="Cancel" Tag="&#xE711;" Style="{StaticResource SunButton}" IsEnabled="False"
                        Margin="0" ToolTip="Stop the current operation and skip anything still queued"/>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# ---------------------------------------------------------------------------
# Window / taskbar icon. Uses WinGet-GUI.ico from the same folder as the script
# (or the .exe) when it's there. For a compiled .exe with no .ico beside it, the
# icon ps2exe embedded in the .exe itself is used instead. If neither works the
# window just keeps the default icon - purely cosmetic, so never fatal.
# ---------------------------------------------------------------------------
try {
    $appPath   = if ($isCompiledExe) { (Get-Process -Id $PID).Path } else { $PSCommandPath }
    $appFolder = if ($appPath) { Split-Path -Parent $appPath } else { $null }
    $icoPath   = if ($appFolder) { Join-Path $appFolder 'WinGet-GUI.ico' } else { $null }

    if ($icoPath -and (Test-Path -LiteralPath $icoPath)) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath)
    } elseif ($isCompiledExe -and $appPath) {
        Add-Type -AssemblyName System.Drawing
        $exeIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($appPath)
        if ($exeIcon) {
            $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $exeIcon.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        }
    }
} catch {
    # Cosmetic only - keep the default icon.
}

$btnCheck             = $window.FindName('BtnCheck')
$btnUpgradeSelected   = $window.FindName('BtnUpgradeSelected')
$btnUpgradeAll        = $window.FindName('BtnUpgradeAll')
$btnInstalled         = $window.FindName('BtnInstalled')
$btnUninstallSelected = $window.FindName('BtnUninstallSelected')
$btnExcluded          = $window.FindName('BtnExcluded')
$btnExcludeSelected   = $window.FindName('BtnExcludeSelected')
$btnRemoveExclusion   = $window.FindName('BtnRemoveExclusion')
$btnCancel            = $window.FindName('BtnCancel')
$btnAbout             = $window.FindName('BtnAbout')
$btnExit              = $window.FindName('BtnExit')
$txtSearchQuery       = $window.FindName('TxtSearchQuery')
$btnSearch            = $window.FindName('BtnSearch')
$btnInstallSelected   = $window.FindName('BtnInstallSelected')
$btnExport            = $window.FindName('BtnExport')
$btnImport            = $window.FindName('BtnImport')
$btnSaveLog           = $window.FindName('BtnSaveLog')
$btnResetSources      = $window.FindName('BtnResetSources')
$btnDiagnose          = $window.FindName('BtnDiagnose')
$txtView              = $window.FindName('TxtView')
$chkIncludeUnknown    = $window.FindName('ChkIncludeUnknown')
$chkSkipStore         = $window.FindName('ChkSkipStore')
$chkRemoveDesktopIcons = $window.FindName('ChkRemoveDesktopIcons')
$txtFilter            = $window.FindName('TxtFilter')
$btnClearFilter       = $window.FindName('BtnClearFilter')
$dataGrid             = $window.FindName('Grid1')
$btnDetails           = $window.FindName('BtnDetails')
$btnHomepage          = $window.FindName('BtnHomepage')
$btnReleaseNotes      = $window.FindName('BtnReleaseNotes')
$txtDetails           = $window.FindName('TxtDetails')
$pnlDetails           = $window.FindName('PnlDetails')
$scrDetails           = $window.FindName('ScrDetails')
$txtLog               = $window.FindName('TxtLog')
$txtStatus            = $window.FindName('TxtStatus')
$progress             = $window.FindName('Progress')
$logRow               = $window.FindName('LogRow')
$imgLogo              = $window.FindName('ImgLogo')
$txtGreeting          = $window.FindName('TxtGreeting')
$pnlEmpty             = $window.FindName('PnlEmpty')
$imgEmpty             = $window.FindName('ImgEmpty')
$txtEmpty             = $window.FindName('TxtEmpty')
$pnlBusy              = $window.FindName('PnlBusy')
$imgBusy              = $window.FindName('ImgBusy')
$txtBusyTitle         = $window.FindName('TxtBusyTitle')
$txtBusyDetail        = $window.FindName('TxtBusyDetail')
$busyBar              = $window.FindName('BusyBar')
$txtBusyTime          = $window.FindName('TxtBusyTime')
$btnBusyCancel        = $window.FindName('BtnBusyCancel')
$script:busyStart     = $null
$script:listSource    = ''
$script:HomepageUrl   = $null
$script:ReleaseNotesUrl = $null
$script:JustUpgraded  = @()
$script:diagTemp      = $null

# ---------------------------------------------------------------------------
# The box mascot, embedded so the header and empty-list picture work even
# without any image files next to the script (or inside the compiled .exe).
# ---------------------------------------------------------------------------
$script:MascotPng = @'
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
'@

try {
    $bytes  = [Convert]::FromBase64String(($script:MascotPng -replace '\s', ''))
    $stream = New-Object System.IO.MemoryStream(,$bytes)
    $mascot = New-Object System.Windows.Media.Imaging.BitmapImage
    $mascot.BeginInit()
    $mascot.CacheOption  = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $mascot.StreamSource = $stream
    $mascot.EndInit()
    $mascot.Freeze()
    $imgLogo.Source  = $mascot
    $imgEmpty.Source = $mascot
    $imgBusy.Source  = $mascot
} catch {
    # Cosmetic only.
    $imgLogo.Visibility = 'Collapsed'
}

# A little hello that depends on the time of day.
$hour = (Get-Date).Hour
$txtGreeting.Text = if ($hour -lt 12) { 'Good morning! Let''s keep your apps fresh - no terminal needed.' }
                    elseif ($hour -lt 18) { 'Good afternoon! Let''s keep your apps fresh - no terminal needed.' }
                    else { 'Good evening! Let''s keep your apps fresh - no terminal needed.' }

# ---------------------------------------------------------------------------
# State shared between the UI thread and the poll timer
# ---------------------------------------------------------------------------
$script:proc            = $null
$script:tempOut         = $null
$script:tempErr         = $null
$script:lastOutLength   = 0
$script:lastErrLength   = 0
$script:mode            = $null
$script:busy            = $false
$script:streamToLog     = $true
$script:cancelRequested = $false
$script:preShortcuts    = $null
$script:relatedNames    = $null
$script:desktopWatchBefore       = $null
$script:desktopWatchRelatedNames = $null
$script:desktopWatchTicksLeft    = 0
$script:lastUpdateRows  = @()
$script:filterText      = ''
$script:detailsItem     = $null

# What the grid is currently showing:
#   'updates'   installed packages with an upgrade available
#   'search'    search results (may not be installed)
#   'installed' everything installed
#   'pins'      packages excluded from Upgrade All (winget pins)
# The action buttons are enabled to match.
$script:gridMode = 'updates'
$script:gridRows = @()

# Multi-package queue for the "Selected" buttons. Packages are processed one at a
# time (one winget process each) so every package gets its own clearly separated
# log section and its own result in the summary.
$script:queue            = New-Object System.Collections.Generic.List[object]
$script:queueAction      = $null    # install / upgrade / uninstall / pin / unpin
$script:queueOriginView  = $null    # which view to refresh afterwards
$script:queueTotal       = 0
$script:queueResults     = New-Object System.Collections.Generic.List[object]
$script:currentQueueItem = $null

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)

# Some installers/updaters (Chrome, Edge, Zoom, Adobe products, etc.) create or
# refresh their desktop shortcut via a separate background process *after* winget's
# own process has already exited, so a single before/after check right when winget
# finishes can miss it. This timer keeps re-checking for a short grace period.
$desktopWatchTimer = New-Object System.Windows.Threading.DispatcherTimer
$desktopWatchTimer.Interval = [TimeSpan]::FromSeconds(2)

# ---------------------------------------------------------------------------
# Remembered settings (checkboxes, window size/position, log pane height)
# ---------------------------------------------------------------------------
$script:settingsPath = Join-Path $env:APPDATA 'WingetUpdateManager\settings.json'

# Bump when the default layout changes, so sizes saved with an older layout are
# ignored once instead of squashing the new one (e.g. a short window saved before
# the log pane was made taller).
$script:layoutVersion = 4

function Import-AppSettings {
    try {
        if (-not (Test-Path -LiteralPath $script:settingsPath)) { return }
        $s = Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return }
    if (-not $s) { return }

    if ($null -ne $s.IncludeUnknown)     { $chkIncludeUnknown.IsChecked     = [bool]$s.IncludeUnknown }
    if ($null -ne $s.SkipStore)          { $chkSkipStore.IsChecked          = [bool]$s.SkipStore }
    if ($null -ne $s.RemoveDesktopIcons) { $chkRemoveDesktopIcons.IsChecked = [bool]$s.RemoveDesktopIcons }

    try {
        $sameLayout = ($s.LayoutVersion -eq $script:layoutVersion)
        if ($sameLayout -and $s.Width -ge $window.MinWidth -and $s.Height -ge $window.MinHeight) {
            $window.Width  = [double]$s.Width
            $window.Height = [double]$s.Height
        }
        if ($sameLayout -and $s.LogHeight -ge $logRow.MinHeight) {
            $logRow.Height = New-Object System.Windows.GridLength([double]$s.LogHeight)
        }
        # Only restore the position if it's still on a screen (e.g. not on a monitor
        # that has since been unplugged).
        $vsLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
        $vsTop  = [System.Windows.SystemParameters]::VirtualScreenTop
        $vsW    = [System.Windows.SystemParameters]::VirtualScreenWidth
        $vsH    = [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($null -ne $s.Left -and $null -ne $s.Top -and
            $s.Left -ge $vsLeft -and $s.Left -le ($vsLeft + $vsW - 200) -and
            $s.Top  -ge $vsTop  -and $s.Top  -le ($vsTop + $vsH - 100)) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = [double]$s.Left
            $window.Top  = [double]$s.Top
        }
        if ($s.Maximized) { $window.WindowState = 'Maximized' }
    } catch { }
}

function Limit-WindowToScreen {
    # The default height suits a 1080p screen; on a smaller screen (or with a large
    # taskbar or display scaling) shrink the window, and the log pane with it, so
    # nothing ends up off the bottom of the screen.
    try {
        $workArea = [System.Windows.SystemParameters]::WorkArea
        if ($window.Height -gt $workArea.Height) {
            $shrinkBy = $window.Height - $workArea.Height
            $window.Height = [math]::Max($window.MinHeight, $workArea.Height)
            if ($window.WindowStartupLocation -eq 'Manual') { $window.Top = $workArea.Top }
            if ($logRow.Height.IsAbsolute) {
                $newLog = [math]::Max($logRow.MinHeight, $logRow.Height.Value - ($shrinkBy / 2))
                $logRow.Height = New-Object System.Windows.GridLength($newLog)
            }
        }
        if ($window.Width -gt $workArea.Width) {
            $window.Width = [math]::Max($window.MinWidth, $workArea.Width)
            if ($window.WindowStartupLocation -eq 'Manual') { $window.Left = $workArea.Left }
        }
    } catch { }
}

function Export-AppSettings {
    try {
        $bounds = if ($window.WindowState -eq 'Normal') {
            New-Object System.Windows.Rect($window.Left, $window.Top, $window.Width, $window.Height)
        } else { $window.RestoreBounds }

        $s = [ordered]@{
            IncludeUnknown     = [bool]$chkIncludeUnknown.IsChecked
            SkipStore          = [bool]$chkSkipStore.IsChecked
            RemoveDesktopIcons = [bool]$chkRemoveDesktopIcons.IsChecked
            Maximized          = ($window.WindowState -eq 'Maximized')
            LayoutVersion      = $script:layoutVersion
            LogHeight          = [math]::Round($logRow.ActualHeight)
        }
        if (-not $bounds.IsEmpty) {
            $s.Left = [math]::Round($bounds.Left); $s.Top = [math]::Round($bounds.Top)
            $s.Width = [math]::Round($bounds.Width); $s.Height = [math]::Round($bounds.Height)
        }
        $folder = Split-Path -Parent $script:settingsPath
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        ($s | ConvertTo-Json) | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
function Get-ViewName {
    switch ($script:gridMode) {
        'updates'   { 'Updates available' }
        'search'    { 'Search results' }
        'installed' { 'Installed apps' }
        'pins'      { 'Excluded apps' }
        default     { '' }
    }
}

function Get-GridView {
    if ($null -eq $dataGrid.ItemsSource) { return $null }
    # The unary comma matters: a collection view is itself enumerable, so without it
    # PowerShell "unrolls" it on return and the caller gets the rows instead of the
    # view (and then can't set .Filter on it).
    return ,([System.Windows.Data.CollectionViewSource]::GetDefaultView($dataGrid.ItemsSource))
}

function Update-ViewLabel {
    $total = $script:gridRows.Count
    $label = "$(Get-ViewName) ($total)"
    if ($script:filterText) {
        $view = Get-GridView
        $shown = 0
        if ($view) { foreach ($row in $view) { $shown++ } }
        $label = "$(Get-ViewName) ($shown of $total shown)"
    }
    $txtView.Text = $label
}

function Update-GridFilter {
    $view = Get-GridView
    if ($view) {
        if ([string]::IsNullOrWhiteSpace($script:filterText)) {
            $view.Filter = $null
        } else {
            $view.Filter = [Predicate[object]]{
                param($row)
                $t = $script:filterText
                return ([string]$row.Name).IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                       ([string]$row.Id).IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        }
    }
    Update-ViewLabel
}

function Set-GridItems {
    param([object[]]$Rows, [string]$Mode)
    $script:gridMode = $Mode
    # @() guards against PowerShell unwrapping a single-item result into a bare object -
    # DataGrid.ItemsSource requires an IEnumerable and throws if handed a lone PSCustomObject.
    $script:gridRows = @($Rows)
    $dataGrid.ItemsSource = $script:gridRows
    Update-GridFilter
    Update-ActionButtons

    # A friendly message instead of an empty white box.
    if ($script:gridRows.Count -eq 0) {
        $txtEmpty.Text = switch ($Mode) {
            'updates'   { "You're all up to date. Nice!`nNothing needs updating right now." }
            'search'    { "Couldn't find anything with that name.`nTry a shorter or different search." }
            'installed' { "No installed apps were found." }
            'pins'      { "No apps are excluded.`nUpgrade All will update everything." }
            default     { 'Nothing to show.' }
        }
        $pnlEmpty.Visibility = 'Visible'
    } else {
        $pnlEmpty.Visibility = 'Collapsed'
    }
}

function Update-ActionButtons {
    # Shows how many packages are selected on the "Selected" buttons, and only enables
    # the ones that fit what the grid is showing right now.
    $count  = $dataGrid.SelectedItems.Count
    $suffix = if ($count -gt 1) { " ($count)" } else { '' }
    $idle   = -not $script:busy
    $mode   = $script:gridMode

    $btnUpgradeSelected.Content   = "Upgrade Selected$suffix"
    $btnInstallSelected.Content   = "Install Selected$suffix"
    $btnUninstallSelected.Content = "Uninstall Selected$suffix"
    $btnExcludeSelected.Content   = "Exclude Selected$suffix"
    $btnRemoveExclusion.Content   = "Remove Exclusion$suffix"

    $btnUpgradeSelected.IsEnabled   = $idle -and $mode -eq 'updates'
    $btnInstallSelected.IsEnabled   = $idle -and $mode -eq 'search'
    $btnUninstallSelected.IsEnabled = $idle -and $mode -eq 'installed'
    $btnExcludeSelected.IsEnabled   = $idle -and $mode -in @('updates', 'installed')
    $btnRemoveExclusion.IsEnabled   = $idle -and $mode -eq 'pins'
    $btnDetails.IsEnabled           = $idle -and $count -ge 1
}

function Set-UiBusy {
    param([bool]$Busy, [string]$Status)
    $script:busy = $Busy
    foreach ($control in @($btnCheck, $btnUpgradeAll, $btnInstalled, $btnExcluded, $btnSearch, $txtSearchQuery,
                           $btnExport, $btnImport, $btnResetSources, $btnDiagnose, $dataGrid)) {
        $control.IsEnabled = -not $Busy
    }
    $btnCancel.IsEnabled      = $Busy
    $btnBusyCancel.IsEnabled  = $Busy
    $progress.Visibility      = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $progress.IsIndeterminate = $Busy

    # The progress card over the list. Not for the quick Details lookup.
    if ($Busy -and $script:mode -ne 'details') {
        if ($pnlBusy.Visibility -ne 'Visible') {
            $script:busyStart = Get-Date
            $txtBusyTime.Text = ''
        }
        $pnlBusy.Visibility = 'Visible'
    } else {
        $pnlBusy.Visibility = 'Collapsed'
    }

    Update-ActionButtons
    if ($Status) { $txtStatus.Text = $Status }
}

function Update-BusyCard {
    param([string]$Title, [string]$Detail, $Percent = $null)
    if ($Title) { $txtBusyTitle.Text = $Title }
    $txtBusyDetail.Text       = $Detail
    $txtBusyDetail.Visibility = if ($Detail) { 'Visible' } else { 'Collapsed' }
    if ($null -eq $Percent) {
        $busyBar.IsIndeterminate = $true
    } else {
        $busyBar.IsIndeterminate = $false
        $busyBar.Value = [math]::Max(0, [math]::Min(100, [double]$Percent))
    }
}

function Start-DesktopWatch {
    param([string[]]$Before, [string[]]$RelatedNames)

    if (-not $Before) { return }

    $script:reportedSkips.Clear()
    # Immediate check in case the shortcut was created synchronously, before we
    # start polling for the delayed/background case.
    Remove-NewDesktopShortcuts -Before $Before -RelatedNames $RelatedNames

    $script:desktopWatchBefore       = $Before
    $script:desktopWatchRelatedNames = $RelatedNames
    $script:desktopWatchTicksLeft    = 10   # 10 x 2s = 20s grace period
    $desktopWatchTimer.Start()
}

function Start-WingetOperation {
    param(
        [string]$FilePath = $script:WingetExe,
        [string]$Arguments,
        [string]$Mode,
        [string]$StatusText,
        [string]$LogPrefix,
        # Follow-on operations (the list refresh after an upgrade, each package in a
        # multi-package queue, etc.) keep the existing log instead of wiping it, so the
        # output of what just ran - and any desktop icon cleanup - is still visible.
        [switch]$KeepLog,
        # For lookups whose output goes somewhere else (the Details pane), so the log
        # pane isn't cluttered with it.
        [switch]$NoLogStream,
        # Shown on the progress card: a line under the title (e.g. "Package 2 of 5")
        # and how full the bar is (0-100). No percentage = a moving "working" bar.
        [string]$ProgressDetail = '',
        $ProgressPercent = $null
    )

    $script:mode            = $Mode
    $script:streamToLog     = -not $NoLogStream
    $script:cancelRequested = $false
    $script:tempOut         = [System.IO.Path]::GetTempFileName()
    $script:tempErr         = [System.IO.Path]::GetTempFileName()
    $script:lastOutLength   = 0
    $script:lastErrLength   = 0

    if (-not $NoLogStream) {
        if (-not $KeepLog) { $txtLog.Clear() }
        if ($LogPrefix) { Append-Log "$LogPrefix`r`n`r`n" } else { Append-Log "> winget $Arguments`r`n`r`n" }
    }
    Set-UiBusy -Busy $true -Status $StatusText
    Update-BusyCard -Title $StatusText -Detail $ProgressDetail -Percent $ProgressPercent

    $workDir = if ($FilePath -eq $script:WingetExe) { Split-Path -Parent $script:WingetExe } else { $null }
    $script:proc = Start-HiddenProcess -FilePath $FilePath -Arguments $Arguments `
        -OutFile $script:tempOut -ErrFile $script:tempErr -WorkingDirectory $workDir

    $timer.Start()
}

function Get-SourceArg {
    # Scoping to the default "winget" source skips msstore entirely, which avoids
    # its recurring source-agreement / region-reporting prompt on machines where
    # it has never been interactively accepted.
    if ($chkSkipStore.IsChecked) { return '--source winget' } else { return '' }
}

function Get-ListSource {
    # When a list is fetched with "--source winget", winget leaves the Source column out
    # of its table (every row is from the same source), so the parsed rows come back with
    # an empty Source. Remember which source was asked for so it can be filled back in.
    if ($chkSkipStore.IsChecked) { return 'winget' } else { return '' }
}

function Set-MissingSource {
    param([object[]]$Rows, [string]$Source)
    if (-not $Source) { return }
    foreach ($r in $Rows) { if (-not $r.Source) { $r.Source = $Source } }
}

function Start-CheckForUpdates {
    param([switch]$KeepLog)
    $extra = if ($chkIncludeUnknown.IsChecked) { '--include-unknown' } else { '' }
    $src   = Get-SourceArg
    $script:listSource = Get-ListSource
    # --disable-interactivity turns off winget's console-only behaviour (progress bars,
    # width detection, etc). Without it, winget run with redirected output (as we do here,
    # so the log pane can show it) can misbehave in ways that don't show up when you run
    # the same command directly in a normal terminal window.
    Start-WingetOperation -Arguments "upgrade $extra $src --accept-source-agreements --disable-interactivity" `
        -Mode 'check' -StatusText 'Looking for updates...' -KeepLog:$KeepLog
}

function Start-ListInstalled {
    param([switch]$KeepLog)
    # No --source here on purpose: that would hide everything winget can't match to a
    # source (most non-winget installs), and the point of this view is to see - and be
    # able to uninstall - everything.
    Start-WingetOperation -Arguments 'list --accept-source-agreements --disable-interactivity' `
        -Mode 'installed' -StatusText 'Listing installed apps...' -KeepLog:$KeepLog
}

function Start-ListPins {
    param([switch]$KeepLog)
    Start-WingetOperation -Arguments 'pin list --accept-source-agreements --disable-interactivity' `
        -Mode 'pins' -StatusText 'Listing excluded apps...' -KeepLog:$KeepLog
}

function Start-SearchSoftware {
    param([string]$Query)

    if ([string]::IsNullOrWhiteSpace($Query)) {
        [void](Show-FriendlyDialog -Kind Info -Title 'What shall we look for?' -YesText 'Got it' `
            -Message "Type the name of an app in the search box first - for example notepad++, vlc or 7-zip.")
        return
    }

    $src      = Get-SourceArg
    $script:listSource = Get-ListSource
    $escaped  = $Query.Trim()
    Start-WingetOperation -Arguments "search `"$escaped`" $src --accept-source-agreements --disable-interactivity" `
        -Mode 'search' -StatusText "Searching for '$escaped'..."
}

function Start-SourceUpdate {
    param([switch]$KeepLog)
    # --verbose-logs makes winget write extra diagnostic detail to its log file
    # (%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir)
    # in case the console output here isn't enough to see why a source failed.
    Start-WingetOperation -Arguments 'source update --verbose-logs --disable-interactivity' `
        -Mode 'sourceUpdate' -StatusText 'Updating winget sources...' -KeepLog:$KeepLog
}

function Start-NetworkDiagnostics {
    # Checks the things that stop winget reaching its sources, without needing a
    # separate terminal: a proxy set up for browsers (WinINet) but not for winget
    # (WinHTTP); DNS, firewall and TLS problems; SSL inspection by a web filter
    # (spotted by a non-Microsoft certificate issuer); and whether winget's real
    # source file can be fetched. Each check prints OK / PROBLEM, then a summary.
    # Note: a 404 from a bare server address is normal and counts as "reached".
    $diagScript = @'
$problems = New-Object System.Collections.Generic.List[string]
function Write-Check([string]$Status, [string]$Text) { Write-Output ("  [{0}] {1}" -f $Status, $Text) }

Write-Output "=== winget ==="
try {
    $ver = (winget --version 2>$null | Select-Object -First 1)
    Write-Check 'OK' "winget version $ver"
} catch {
    Write-Check 'PROBLEM' "winget didn't run: $($_.Exception.Message)"
    $problems.Add('winget itself did not run')
}
Write-Output ""
Write-Output "Configured sources:"
try { winget source list --disable-interactivity 2>&1 | ForEach-Object { "  $_" } } catch { }

Write-Output ""
Write-Output "=== Proxy settings ==="
$winhttp = (netsh winhttp show proxy) -join ' '
$winhttpDirect = $winhttp -match 'Direct access'
$inet = $null
try { $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch { }
$inetProxy = ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer)
$inetPac   = ($inet -and $inet.AutoConfigURL)

if ($winhttpDirect) { Write-Check 'OK' 'WinHTTP (used by winget): direct access, no proxy' }
else { Write-Check 'INFO' "WinHTTP (used by winget): $(($winhttp -replace '\s+', ' ').Trim())" }
if ($inetProxy)    { Write-Check 'INFO' "Browser (WinINet) proxy: $($inet.ProxyServer)" }
elseif ($inetPac)  { Write-Check 'INFO' "Browser (WinINet) proxy script: $($inet.AutoConfigURL)" }
else               { Write-Check 'OK' 'Browser (WinINet): no proxy' }
if ($winhttpDirect -and ($inetProxy -or $inetPac)) {
    Write-Check 'PROBLEM' 'Browsers use a proxy but winget (WinHTTP) does not. Fix, from an elevated prompt: netsh winhttp import proxy source=ie'
    $problems.Add('proxy mismatch between browsers and winget')
}

# Real endpoints winget uses. Any HTTP answer (even 404 on a bare address) means the
# server was reached; only DNS/connection/TLS failures, timeouts and 407s are problems.
$checks = @(
    @{ Name = 'winget source (cdn.winget.microsoft.com)'; Host = 'cdn.winget.microsoft.com'; Url = 'https://cdn.winget.microsoft.com/cache/source.msix'; ExpectFile = $true },
    @{ Name = 'Microsoft Store source (storeedgefd.dsx.mp.microsoft.com)'; Host = 'storeedgefd.dsx.mp.microsoft.com'; Url = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'; ExpectFile = $false }
)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

foreach ($c in $checks) {
    Write-Output ""
    Write-Output "=== $($c.Name) ==="

    # DNS
    $ips = @()
    try { $ips = @([Net.Dns]::GetHostAddresses($c.Host) | ForEach-Object { $_.IPAddressToString }) } catch { }
    if ($ips.Count -eq 0) {
        Write-Check 'PROBLEM' "DNS: $($c.Host) could not be resolved"
        $problems.Add("$($c.Host) does not resolve (DNS)")
        continue
    }
    Write-Check 'OK' "DNS: $($ips[0])"

    # TCP
    $tcpOk = $false
    try {
        $client = New-Object Net.Sockets.TcpClient
        $tcpOk = $client.ConnectAsync($c.Host, 443).Wait(8000) -and $client.Connected
        $client.Close()
    } catch { }
    if (-not $tcpOk) {
        Write-Check 'PROBLEM' 'TCP 443: no connection (firewall block or no internet)'
        $problems.Add("$($c.Host) port 443 blocked")
        continue
    }
    Write-Check 'OK' 'TCP 443: connected'

    # TLS certificate - a non-Microsoft issuer means something (e.g. a web filter) is
    # decrypting and re-signing the traffic, which can corrupt winget's source download.
    try {
        $tcp = New-Object Net.Sockets.TcpClient($c.Host, 443)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($c.Host)
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $issuer = $cert.Issuer
        $ssl.Dispose(); $tcp.Close()
        if ($issuer -match 'Microsoft|DigiCert') {
            Write-Check 'OK' "Certificate issued by: $issuer"
        } else {
            Write-Check 'PROBLEM' "Certificate issued by: $issuer - not Microsoft. Looks like SSL inspection by a web filter; ask for this domain to be excluded from inspection."
            $problems.Add("SSL inspection on $($c.Host)")
        }
    } catch {
        Write-Check 'PROBLEM' "TLS handshake failed: $($_.Exception.Message)"
        $problems.Add("TLS failure to $($c.Host)")
    }

    # HTTPS
    try {
        $resp = Invoke-WebRequest -Uri $c.Url -Method Head -UseBasicParsing -TimeoutSec 15
        $type = [string]$resp.Headers['Content-Type']
        if ($c.ExpectFile -and $type -match 'html') {
            Write-Check 'PROBLEM' "HTTPS: got a web page ($type) instead of the source file - probably a filter's block page"
            $problems.Add("block page instead of $($c.Url)")
        } else {
            $size = $resp.Headers['Content-Length']
            $extra = if ($c.ExpectFile -and $size) { " ($([math]::Round([double]$size / 1MB, 1)) MB source file)" } else { '' }
            Write-Check 'OK' "HTTPS: $($resp.StatusCode)$extra"
        }
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 407) {
            Write-Check 'PROBLEM' 'HTTPS: 407 - the proxy wants a login, which winget cannot provide'
            $problems.Add("proxy authentication required for $($c.Host)")
        } elseif ($code -and -not $c.ExpectFile) {
            # The server answered; there's just no page at this address. That's normal.
            Write-Check 'OK' "HTTPS: server reached (HTTP $code is normal for this address)"
        } elseif ($code) {
            Write-Check 'PROBLEM' "HTTPS: HTTP $code fetching $($c.Url)"
            $problems.Add("HTTP $code from $($c.Url)")
        } else {
            Write-Check 'PROBLEM' "HTTPS: $($_.Exception.Message)"
            $problems.Add("HTTPS failure to $($c.Host)")
        }
    }
}

Write-Output ""
Write-Output "=== Result ==="
if ($problems.Count -eq 0) {
    Write-Output "  No problems found. winget can reach its sources normally."
} else {
    Write-Output "  $($problems.Count) problem(s) found:"
    foreach ($p in $problems) { Write-Output "    - $p" }
    Write-Output ""
    Write-Output "  If searches still fail after fixing these, try Reset Sources."
}
'@

    # Written to a temp file rather than passed as -EncodedCommand, which would be too
    # long for the cmd.exe line used to start it hidden.
    $script:diagTemp = Join-Path ([System.IO.Path]::GetTempPath()) "winget-gui-diagnose-$PID.ps1"
    [System.IO.File]::WriteAllText($script:diagTemp, $diagScript, (New-Object System.Text.UTF8Encoding($true)))

    Start-WingetOperation -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($script:diagTemp)`"" `
        -Mode 'diagnose' -StatusText 'Running network diagnostics...' `
        -LogPrefix '> Running network diagnostics...'
}

# ---------------------------------------------------------------------------
# Details pane
# ---------------------------------------------------------------------------
function Set-DetailsLinks {
    param([string]$Homepage, [string]$ReleaseNotes)
    # Kept in variables, not the buttons' Tag - Tag holds each button's icon.
    $script:HomepageUrl        = $Homepage
    $script:ReleaseNotesUrl    = $ReleaseNotes
    $btnHomepage.IsEnabled     = [bool]$Homepage
    $btnReleaseNotes.IsEnabled = [bool]$ReleaseNotes
}

function Show-PackageDetails {
    $item = $dataGrid.SelectedItem
    if (-not $item -or $script:busy) { return }

    $script:detailsItem = $item
    Set-DetailsLinks
    if (-not $item.Source) {
        Show-DetailsMessage -Title $item.Name -Subtitle $item.Id -Message "This app wasn't installed from a winget source, so winget has no details for it."
        return
    }

    Show-DetailsMessage -Title $item.Name -Subtitle $item.Id -Message 'Looking up the details...'
    $id = $item.Id
    Start-WingetOperation -Arguments "show --id `"$id`" -e --source `"$($item.Source)`" --accept-source-agreements --disable-interactivity" `
        -Mode 'details' -StatusText "Loading details for $($item.Name)..." -NoLogStream
}

function New-DetailsText {
    # A wrapped TextBlock for the Details pane.
    param([string]$Text, [double]$Size = 13, [string]$Weight = 'Normal', [string]$Color = '#2B2340',
          [string]$Margin = '0,0,0,0')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text         = $Text
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize     = $Size
    $tb.FontWeight   = $Weight
    $tb.Foreground   = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
    $tb.Margin       = $Margin
    $tb.LineHeight   = [math]::Round($Size * 1.45)
    return $tb
}

function New-DetailsHeading {
    param([string]$Text)
    return New-DetailsText -Text $Text.ToUpper() -Size 11 -Weight 'Bold' -Color '#8A80A0' -Margin '0,14,0,6'
}

function Show-DetailsMessage {
    # Simple state for the Details pane: a title, an optional subtitle and a message.
    param([string]$Title, [string]$Subtitle, [string]$Message)
    $pnlDetails.Children.Clear()
    if ($Title)    { [void]$pnlDetails.Children.Add((New-DetailsText -Text $Title -Size 16 -Weight 'Bold')) }
    if ($Subtitle) { [void]$pnlDetails.Children.Add((New-DetailsText -Text $Subtitle -Color '#8A80A0' -Margin '0,2,0,0')) }
    if ($Message)  { [void]$pnlDetails.Children.Add((New-DetailsText -Text $Message -Color '#5E5672' -Margin '0,10,0,0')) }
    $scrDetails.ScrollToHome()
}

function ConvertFrom-WingetShow {
    <#
      Turns "winget show" output into an ordered set of fields. Top-level lines look like
      "Publisher: OpenAI"; multi-line values (Description, Release Notes, Tags, ...) follow
      their label on lines indented by two spaces, one paragraph or item per line.
    #>
    param([string[]]$Lines)
    $fields = [ordered]@{}
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^Installer:') { break }          # installer technicalities - not shown
        if ($line -match '^Found (.+?) \[(.+?)\]\s*$') {
            $fields['_Name'] = $Matches[1]; $fields['_Id'] = $Matches[2]; continue
        }
        if ($line -match '^(\S[^:]*?):\s*(.*)$') {
            $current = $Matches[1].Trim()
            $fields[$current] = New-Object System.Collections.Generic.List[string]
            if ($Matches[2].Trim()) { $fields[$current].Add($Matches[2].Trim()) }
        } elseif ($current -and $line -match '^\s+(\S.*)$') {
            $fields[$current].Add($Matches[1].TrimEnd())
        }
    }
    return $fields
}

function Complete-PackageDetails {
    param([string]$Output)

    $lines = @()
    if ($Output) { $lines = $Output -split "`r?`n" }
    $f = ConvertFrom-WingetShow -Lines $lines

    if (-not $f.Contains('_Name')) {
        $msg = (($lines | Where-Object { $_ -match '\S' }) -join "`r`n").Trim()
        if (-not $msg) { $msg = 'winget returned no details.' }
        Show-DetailsMessage -Title $script:detailsItem.Name -Message $msg
        Set-DetailsLinks
        return
    }

    function Get-Field([string]$Name) {
        if ($f.Contains($Name) -and $f[$Name].Count -gt 0) { return ($f[$Name] -join ' ').Trim() } else { return '' }
    }

    $pnlDetails.Children.Clear()

    # Name, Id and version
    [void]$pnlDetails.Children.Add((New-DetailsText -Text $f['_Name'] -Size 17 -Weight 'Bold'))
    [void]$pnlDetails.Children.Add((New-DetailsText -Text $f['_Id'] -Color '#8A80A0' -Margin '0,1,0,0'))
    $version = Get-Field 'Version'
    if ($version) {
        $badge = New-Object System.Windows.Controls.Border
        $badge.CornerRadius = 9
        $badge.Background   = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#2B2340')
        $badge.Padding      = '9,2,9,3'
        $badge.Margin       = '0,8,0,0'
        $badge.HorizontalAlignment = 'Left'
        $badge.Child = New-DetailsText -Text "Version $version" -Size 12 -Weight 'SemiBold' -Color '#FFFFFF'
        [void]$pnlDetails.Children.Add($badge)
    }

    # Short facts as label / value rows
    $facts = @(
        @('Publisher', 'Publisher'), @('Author', 'Author'), @('License', 'Licence'),
        @('Copyright', 'Copyright'), @('Moniker', 'Short name')
    )
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,12,0,0'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)
    $row = 0
    foreach ($fact in $facts) {
        $value = Get-Field $fact[0]
        if (-not $value) { continue }
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = 'Auto'
        $grid.RowDefinitions.Add($rd)
        $label = New-DetailsText -Text $fact[1] -Size 12 -Weight 'SemiBold' -Color '#8A80A0' -Margin '0,0,12,5'
        $val   = New-DetailsText -Text $value -Margin '0,0,0,5'
        [System.Windows.Controls.Grid]::SetRow($label, $row); [System.Windows.Controls.Grid]::SetColumn($label, 0)
        [System.Windows.Controls.Grid]::SetRow($val, $row);   [System.Windows.Controls.Grid]::SetColumn($val, 1)
        [void]$grid.Children.Add($label); [void]$grid.Children.Add($val)
        $row++
    }
    if ($row -gt 0) { [void]$pnlDetails.Children.Add($grid) }

    # Description: one paragraph per line, with space between them
    $desc = if ($f.Contains('Description')) { @($f['Description'] | Where-Object { $_ }) } else { @() }
    if ($desc.Count -eq 0 -and (Get-Field 'ShortDescription')) { $desc = @(Get-Field 'ShortDescription') }
    if ($desc.Count -gt 0) {
        [void]$pnlDetails.Children.Add((New-DetailsHeading 'About'))
        foreach ($para in $desc) { [void]$pnlDetails.Children.Add((New-DetailsText -Text $para -Margin '0,0,0,8')) }
    }

    # Release notes, kept to a sensible length
    $notesText = if ($f.Contains('Release Notes')) { @($f['Release Notes'] | Where-Object { $_ }) } else { @() }
    if ($notesText.Count -gt 0) {
        [void]$pnlDetails.Children.Add((New-DetailsHeading "What's new in this version"))
        $shown = 0
        foreach ($para in $notesText) {
            if ($shown -ge 12) {
                [void]$pnlDetails.Children.Add((New-DetailsText -Text '...more in the release notes.' -Color '#8A80A0'))
                break
            }
            [void]$pnlDetails.Children.Add((New-DetailsText -Text $para -Size 12 -Margin '0,0,0,4'))
            $shown++
        }
    }

    # Tags as little pills
    $tags = if ($f.Contains('Tags')) { @($f['Tags'] | Where-Object { $_ }) } else { @() }
    if ($tags.Count -gt 0) {
        [void]$pnlDetails.Children.Add((New-DetailsHeading 'Tags'))
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($tag in ($tags | Select-Object -First 20)) {
            $pill = New-Object System.Windows.Controls.Border
            $pill.CornerRadius = 10
            $pill.Background   = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#EEE8FF')
            $pill.Padding      = '8,2,8,3'
            $pill.Margin       = '0,0,6,6'
            $pill.Child = New-DetailsText -Text $tag -Size 12
            [void]$wrap.Children.Add($pill)
        }
        [void]$pnlDetails.Children.Add($wrap)
    }

    $scrDetails.ScrollToHome()

    $homepage = Get-Field 'Homepage'
    if (-not $homepage) { $homepage = Get-Field 'Publisher Url' }
    $notesUrl = Get-Field 'Release Notes Url'
    if ($homepage -notmatch '^https?://') { $homepage = $null }
    if ($notesUrl -notmatch '^https?://') { $notesUrl = $null }
    Set-DetailsLinks -Homepage $homepage -ReleaseNotes $notesUrl
}

function Open-Url {
    param([string]$Url)
    if (-not $Url -or $Url -notmatch '^https?://') { return }
    # Launched via explorer.exe so the browser opens un-elevated as the normal user,
    # rather than inheriting this app's administrator rights.
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Url`"" } catch { }
}

# ---------------------------------------------------------------------------
# Multi-package queue (Install / Upgrade / Uninstall / Exclude / Remove Exclusion)
# ---------------------------------------------------------------------------
function Show-FriendlyDialog {
    # The app's own pop-up, in place of the plain Windows message box: same cream
    # background, rounded cards and chunky buttons as the main window.
    # Returns $true for the Yes/OK button, $false for No or closing the window.
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('Question', 'Warning', 'Error', 'Info')][string]$Kind = 'Info',
        [object[]]$Items,
        [string]$ItemsTitle = 'THESE APPS',
        [string]$YesText = 'OK',
        [string]$NoText,
        [switch]$Danger,
        [int]$MaxItems = 40
    )

    $look = switch ($Kind) {
        'Question' { @{ Fill = '#7FD8FF'; Glyph = [string][char]0xE897; Sound = $null } }
        'Warning'  { @{ Fill = '#FFE066'; Glyph = [string][char]0xE7BA; Sound = 'Exclamation' } }
        'Error'    { @{ Fill = '#FFB4C2'; Glyph = [string][char]0xE783; Sound = 'Hand' } }
        default    { @{ Fill = '#7BE0A0'; Glyph = [string][char]0xE946; Sound = $null } }
    }

    try {
        [xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="500" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="#FFF7EA" FontFamily="Segoe UI" FontSize="13" Foreground="#2B2340">
    <StackPanel Margin="16">
        <Border CornerRadius="20" Padding="14,10" BorderBrush="#2B2340" BorderThickness="1.5">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#3FA4EE" Offset="0"/>
                    <GradientStop Color="#5B6CF0" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Image x:Name="DlgLogo" Width="54" Height="54" Margin="0,0,12,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                <TextBlock x:Name="DlgTitle" Grid.Column="1" FontSize="19" FontWeight="Bold" Foreground="#FFFFFF"
                           TextWrapping="Wrap" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <Border Style="{DynamicResource CardBox}" Padding="14,12" Margin="0,14,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="DlgBadge" Width="40" Height="40" CornerRadius="20" BorderBrush="#2B2340" BorderThickness="1.5"
                        VerticalAlignment="Top" Margin="0,0,12,0">
                    <TextBlock x:Name="DlgGlyph" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#2B2340"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="DlgMessage" Grid.Column="1" TextWrapping="Wrap" LineHeight="20" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <Border x:Name="DlgItemsCard" Style="{DynamicResource CardBox}" Padding="14,12" Margin="0,12,0,0" Visibility="Collapsed">
            <StackPanel>
                <TextBlock x:Name="DlgItemsTitle" Style="{DynamicResource CardTitle}"/>
                <ScrollViewer MaxHeight="210" VerticalScrollBarVisibility="Auto">
                    <StackPanel x:Name="DlgItems"/>
                </ScrollViewer>
            </StackPanel>
        </Border>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="DlgNo" Tag="&#xE711;" Style="{DynamicResource LilacButton}" Margin="0,0,10,4"/>
            <Button x:Name="DlgYes" Tag="&#xE73E;" Style="{DynamicResource MintButton}" Margin="0,0,0,4"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
        $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dlgXaml))
        $dlg.Resources.MergedDictionaries.Add($window.Resources)
        if ($window.IsLoaded) { $dlg.Owner = $window } else { $dlg.WindowStartupLocation = 'CenterScreen' }
        if ($window.Icon) { $dlg.Icon = $window.Icon }

        $dlg.Title = $Title
        $dlg.FindName('DlgLogo').Source  = $imgLogo.Source
        $dlg.FindName('DlgTitle').Text   = $Title
        $dlg.FindName('DlgMessage').Text = $Message
        $dlg.FindName('DlgGlyph').Text   = $look.Glyph
        $dlg.FindName('DlgBadge').Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($look.Fill)

        $list = @($Items | Where-Object { $_ })
        if ($list.Count -gt 0) {
            $dlg.FindName('DlgItemsCard').Visibility = 'Visible'
            $dlg.FindName('DlgItemsTitle').Text = $ItemsTitle
            $panel = $dlg.FindName('DlgItems')
            $soft  = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#5E5672')
            foreach ($item in ($list | Select-Object -First $MaxItems)) {
                $row = New-Object System.Windows.Controls.TextBlock
                $row.TextWrapping = 'Wrap'
                $row.Margin = New-Object System.Windows.Thickness(2, 0, 0, 5)
                $row.Inlines.Add((New-Object System.Windows.Documents.Run(([string][char]0x2022) + '  ')))
                if ($item -is [string]) {
                    $row.Inlines.Add((New-Object System.Windows.Documents.Run($item)))
                } else {
                    $name = New-Object System.Windows.Documents.Run([string]$item.Name)
                    $name.FontWeight = 'SemiBold'
                    $row.Inlines.Add($name)
                    if ($item.Id -and $item.Id -ne $item.Name) {
                        $id = New-Object System.Windows.Documents.Run("   $($item.Id)")
                        $id.Foreground = $soft
                        $id.FontSize = 12
                        $row.Inlines.Add($id)
                    }
                }
                [void]$panel.Children.Add($row)
            }
            if ($list.Count -gt $MaxItems) {
                $more = New-Object System.Windows.Controls.TextBlock
                $more.Text = "...and $($list.Count - $MaxItems) more"
                $more.Foreground = $soft
                $more.Margin = New-Object System.Windows.Thickness(2, 2, 0, 0)
                [void]$panel.Children.Add($more)
            }
        }

        $yes = $dlg.FindName('DlgYes')
        $no  = $dlg.FindName('DlgNo')
        $yes.Content = $YesText
        if ($Danger) { $yes.Style = $dlg.FindResource('BlushButton') }
        if ($NoText) {
            $no.Content = $NoText
            $no.IsCancel = $true
            # For risky actions, Enter means "no" - the safe choice has to be the easy one.
            if ($Danger) { $no.IsDefault = $true } else { $yes.IsDefault = $true }
        } else {
            $no.Visibility = 'Collapsed'
            $yes.IsDefault = $true
            $yes.IsCancel  = $true
        }
        $yes.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).DialogResult = $true })
        $no.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).DialogResult = $false })
        $dlg.Add_ContentRendered({ param($s, $e)
            $target = if ($s.FindName('DlgNo').IsDefault) { $s.FindName('DlgNo') } else { $s.FindName('DlgYes') }
            [void]$target.Focus()
        })

        if ($look.Sound) { try { [System.Media.SystemSounds]::($look.Sound).Play() } catch { } }
        return ($dlg.ShowDialog() -eq $true)
    } catch {
        # Never lose the question: fall back to the plain Windows box.
        $text = $Message
        if (@($Items).Count -gt 0) {
            $text += "`r`n`r`n" + ((@($Items) | Select-Object -First 15 | ForEach-Object {
                if ($_ -is [string]) { "  - $_" } else { "  - $($_.Name) ($($_.Id))" } }) -join "`r`n")
        }
        $icon = switch ($Kind) { 'Info' { 'Information' } default { $Kind } }
        if ($NoText) {
            return ([System.Windows.MessageBox]::Show($text, $Title, 'YesNo', $icon) -eq 'Yes')
        }
        [void][System.Windows.MessageBox]::Show($text, $Title, 'OK', $icon)
        return $true
    }
}

function Start-PackageQueue {
    param(
        [object[]]$Items,
        [ValidateSet('install', 'upgrade', 'uninstall', 'pin', 'unpin')][string]$Action
    )

    $script:queue.Clear()
    foreach ($i in $Items) { $script:queue.Add($i) }
    $script:queueAction     = $Action
    $script:queueOriginView = $script:gridMode
    $script:queueTotal      = $Items.Count
    $script:queueResults.Clear()

    if ($Action -in @('install', 'upgrade') -and $chkRemoveDesktopIcons.IsChecked) {
        # One snapshot for the whole batch, so icons from any package in it get caught,
        # matched against every selected package's name.
        $script:preShortcuts = Get-DesktopShortcutSnapshot
        $script:relatedNames = @($Items | ForEach-Object { $_.Name })
    } else {
        $script:preShortcuts = $null
        $script:relatedNames = $null
    }

    $txtLog.Clear()
    Start-NextQueuedPackage
}

function Add-QueueResult {
    param($Item, [string]$Status, $ExitCode = $null, [string]$Note = '')
    $script:queueResults.Add([PSCustomObject]@{
        Name = $Item.Name; Id = $Item.Id; Status = $Status; ExitCode = $ExitCode; Note = $Note
    })
}

function Start-NextQueuedPackage {
    while ($script:queue.Count -gt 0) {
        $item = $script:queue[0]
        $script:queue.RemoveAt(0)
        $script:currentQueueItem = $item

        $position = $script:queueTotal - $script:queue.Count
        $counter  = if ($script:queueTotal -gt 1) { " ($position of $($script:queueTotal))" } else { '' }

        # winget sometimes truncates long Ids in its tables with "...". Such an Id can't be
        # matched exactly, so fall back to a (non-exact) Id match on the visible part.
        $ellipsis = [string][char]0x2026
        $id = $item.Id
        $exact = '-e'
        if ($id.EndsWith($ellipsis)) { $id = $id.TrimEnd($ellipsis[0]); $exact = '' }

        $itemSrc = if ($item.Source) { "--source `"$($item.Source)`"" } else { '' }
        $common  = '--accept-source-agreements --disable-interactivity'
        $skip    = $false

        # Note: "continue" inside a PowerShell switch only moves to the switch's next input,
        # not the while loop's next iteration, hence the $skip flag.
        switch ($script:queueAction) {
            'install' {
                $verb = 'Installing'
                $wingetArgs = "install --id `"$id`" $exact $(Get-SourceArg) --accept-package-agreements $common"
            }
            'upgrade' {
                $verb = 'Upgrading'
                $wingetArgs = "upgrade --id `"$id`" $exact $(Get-SourceArg) --accept-package-agreements $common"
            }
            'uninstall' {
                $verb = 'Uninstalling'
                $wingetArgs = "uninstall --id `"$id`" $exact $common"
            }
            'pin' {
                $verb = 'Excluding'
                if (-not $item.Source) {
                    Append-Log "`r`n===== Skipping$counter : $($item.Name) - not from a winget source, so it can't be excluded =====`r`n"
                    Add-QueueResult -Item $item -Status 'Skipped' -Note 'not from a winget source'
                    $skip = $true
                } else {
                    $wingetArgs = "pin add --id `"$id`" $exact $itemSrc $common"
                }
            }
            'unpin' {
                $verb = 'Removing exclusion for'
                $wingetArgs = "pin remove --id `"$id`" $exact $itemSrc $common"
            }
        }
        if ($skip) { continue }

        $prefix = "===== $verb$counter : $($item.Name) =====`r`n> winget $wingetArgs"
        if ($position -gt 1) { $prefix = "`r`n$prefix" }

        $detail  = if ($script:queueTotal -gt 1) { "Package $position of $($script:queueTotal)" } else { $item.Id }
        $percent = if ($script:queueTotal -gt 1) { (($position - 1) / $script:queueTotal) * 100 } else { $null }
        Start-WingetOperation -Arguments $wingetArgs -Mode 'queue' -KeepLog `
            -StatusText "$verb $($item.Name)..." -LogPrefix $prefix `
            -ProgressDetail $detail -ProgressPercent $percent
        return
    }

    Complete-PackageQueue
}

function Complete-PackageQueue {
    $verb = switch ($script:queueAction) {
        'install'   { 'Install' }
        'upgrade'   { 'Upgrade' }
        'uninstall' { 'Uninstall' }
        'pin'       { 'Exclude' }
        'unpin'     { 'Remove exclusion' }
    }
    $okCount = @($script:queueResults | Where-Object { $_.Status -eq 'Done' -and $_.ExitCode -eq 0 }).Count
    # Remembered so the refreshed list can point out any that winget still offers (see 'check' below).
    $script:JustUpgraded = if ($script:queueAction -eq 'upgrade') {
        @($script:queueResults | Where-Object { $_.Status -eq 'Done' -and $_.ExitCode -eq 0 } | ForEach-Object { $_.Id })
    } else { @() }

    Append-Log "`r`n===== $verb summary: $okCount of $($script:queueResults.Count) succeeded =====`r`n"
    foreach ($r in $script:queueResults) {
        $label = "$($r.Name) ($($r.Id))"
        switch ($r.Status) {
            'Cancelled' { Append-Log "  CANCELLED  $label`r`n" }
            'Skipped'   { Append-Log "  SKIPPED    $label$(if ($r.Note) { " - $($r.Note)" })`r`n" }
            default {
                if ($r.ExitCode -eq 0) {
                    Append-Log "  OK         $label`r`n"
                } elseif ($null -eq $r.ExitCode) {
                    Append-Log "  CHECK      $label - exit code unavailable, see the log above`r`n"
                } else {
                    $hex = '0x{0:X8}' -f [int]$r.ExitCode
                    Append-Log "  CHECK      $label - exit code $hex, see the log above`r`n"
                }
            }
        }
    }

    if ($script:queueAction -in @('install', 'upgrade') -and $chkRemoveDesktopIcons.IsChecked) {
        Start-DesktopWatch -Before $script:preShortcuts -RelatedNames $script:relatedNames
    }

    Append-Log "`r`nRefreshing list...`r`n"
    switch ($script:queueAction) {
        'uninstall' { Start-ListInstalled -KeepLog }
        'unpin'     { Start-ListPins -KeepLog }
        'pin'       { if ($script:queueOriginView -eq 'installed') { Start-ListInstalled -KeepLog } else { Start-CheckForUpdates -KeepLog } }
        default     { Start-CheckForUpdates -KeepLog }
    }
}

function Get-SelectedPackages {
    return @($dataGrid.SelectedItems | ForEach-Object { $_ })
}

function Confirm-Selection {
    # Shared "nothing selected" note + confirmation prompt for the Selected buttons.
    param(
        [object[]]$Items, [string]$Question, [string]$Title,
        [string]$YesText = 'Yes, go ahead', [string]$NoText = 'Not now', [switch]$Danger
    )
    if ($Items.Count -eq 0) {
        [void](Show-FriendlyDialog -Kind Info -Title 'Pick some apps first' -YesText 'Got it' `
            -Message "Click an app in the list to select it. Hold Ctrl to pick a few, or Shift to pick a whole run of them.")
        return $false
    }
    $kind  = if ($Danger) { 'Warning' } else { 'Question' }
    $label = if ($Items.Count -eq 1) { 'THIS APP' } else { "THESE $($Items.Count) APPS" }
    return (Show-FriendlyDialog -Kind $kind -Title $Title -Message $Question -Items $Items -ItemsTitle $label `
        -YesText $YesText -NoText $NoText -Danger:$Danger)
}

# ---------------------------------------------------------------------------
# Cancel
# ---------------------------------------------------------------------------
function Request-Cancel {
    if (-not $script:proc -or $script:proc.HasExited) { return }
    $script:cancelRequested = $true
    $btnCancel.IsEnabled = $false
    $btnBusyCancel.IsEnabled = $false
    $txtStatus.Text = 'Cancelling...'
    Update-BusyCard -Title 'Stopping...' -Detail 'Ending winget and its installer'
    Stop-ProcessTree -Process $script:proc
}

function Complete-Cancel {
    $script:cancelRequested = $false
    switch ($script:mode) {
        'queue' {
            Append-Log "`r`n----- Cancelled -----`r`n"
            Add-QueueResult -Item $script:currentQueueItem -Status 'Cancelled'
            foreach ($remaining in $script:queue) { Add-QueueResult -Item $remaining -Status 'Skipped' -Note 'cancelled before it started' }
            $script:queue.Clear()
            Complete-PackageQueue
        }
        { $_ -in @('upgradeAll', 'import') } {
            Append-Log "`r`n----- Cancelled. Anything already finished stays installed/upgraded. -----`r`n"
            if ($chkRemoveDesktopIcons.IsChecked) { Start-DesktopWatch -Before $script:preShortcuts -RelatedNames $script:relatedNames }
            Start-CheckForUpdates -KeepLog
        }
        'details' {
            Show-DetailsMessage -Message 'Cancelled.'
            Set-UiBusy -Busy $false -Status 'Stopped. No worries.'
        }
        default {
            Append-Log "`r`n----- Cancelled -----`r`n"
            Set-UiBusy -Busy $false -Status 'Stopped. No worries.'
        }
    }
}

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------
$desktopWatchTimer.Add_Tick({
    if ($script:desktopWatchBefore) {
        Remove-NewDesktopShortcuts -Before $script:desktopWatchBefore -RelatedNames $script:desktopWatchRelatedNames
    }
    $script:desktopWatchTicksLeft--
    if ($script:desktopWatchTicksLeft -le 0) {
        $desktopWatchTimer.Stop()
    }
})

$timer.Add_Tick({
    if ($pnlBusy.Visibility -eq 'Visible' -and $script:busyStart) {
        $elapsed = (Get-Date) - $script:busyStart
        $txtBusyTime.Text = if ($elapsed.TotalMinutes -ge 1) {
            'Working for {0}m {1:00}s' -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
        } else { 'Working for {0}s' -f [math]::Floor($elapsed.TotalSeconds) }
    }

    # Upgrade All and Import print "(2/5) Found Google Chrome [Google.Chrome] ..." as they
    # go, which is enough to fill the bar step by step.
    if ($script:mode -in @('upgradeAll', 'import')) {
        $soFar = Read-OutputFile -Path $script:tempOut
        if ($soFar) {
            $steps = [regex]::Matches($soFar, '\((\d+)/(\d+)\)\s+Found\s+(.+?)\s+\[')
            if ($steps.Count -gt 0) {
                $last  = $steps[$steps.Count - 1]
                $n     = [int]$last.Groups[1].Value
                $total = [int]$last.Groups[2].Value
                $verb  = if ($script:mode -eq 'import') { 'Installing' } else { 'Upgrading' }
                if ($total -gt 0) {
                    Update-BusyCard -Title "$verb $($last.Groups[3].Value)..." -Detail "Package $n of $total" -Percent ((($n - 1) / $total) * 100)
                }
            }
        }
    }

    if ($script:streamToLog) {
        $content = Read-OutputFile -Path $script:tempOut
        if ($content -and $content.Length -gt $script:lastOutLength) {
            Append-Log $content.Substring($script:lastOutLength)
            $script:lastOutLength = $content.Length
        }
        $content = Read-OutputFile -Path $script:tempErr
        if ($content -and $content.Length -gt $script:lastErrLength) {
            Append-Log $content.Substring($script:lastErrLength)
            $script:lastErrLength = $content.Length
        }
    }

    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()

        # One last read in case output landed between the final tick and exit.
        $finalContent = Read-OutputFile -Path $script:tempOut
        $errContent   = Read-OutputFile -Path $script:tempErr
        if ($script:streamToLog) {
            if ($finalContent -and $finalContent.Length -gt $script:lastOutLength) {
                Append-Log $finalContent.Substring($script:lastOutLength)
            }
            if ($errContent -and $errContent.Length -gt $script:lastErrLength) {
                Append-Log $errContent.Substring($script:lastErrLength)
            }
        }

        Remove-Item -LiteralPath $script:tempOut, $script:tempErr -ErrorAction SilentlyContinue

        if ($script:cancelRequested) {
            Complete-Cancel
            return
        }

        $lines = @()
        if ($finalContent) { $lines = $finalContent -split "`r?`n" }

        switch ($script:mode) {
            'check' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-MissingSource -Rows $rows -Source $script:listSource
                $script:lastUpdateRows = $rows
                Set-GridItems -Rows $rows -Mode 'updates'
                Set-UiBusy -Busy $false -Status $(if ($rows.Count -eq 0) { "All up to date - nothing to do!" } elseif ($rows.Count -eq 1) { '1 update ready to install.' } else { "$($rows.Count) updates ready to install." })
                Append-Log "`r`n$($rows.Count) update(s) available.`r`n"

                # Upgraded fine but still listed: the package's version in winget doesn't match the one
                # the app reports to Windows, so winget will keep offering it. Say so, rather than leaving
                # it looking like the upgrade failed.
                $stuck = @($rows | Where-Object { $script:JustUpgraded -contains $_.Id })
                foreach ($r in $stuck) {
                    Append-Log (("`r`nNote: {0} upgraded successfully but is still listed ({1} installed, {2} offered). " +
                        "The app reports a different version number to Windows than winget's listing uses, so winget " +
                        "will keep offering this update. It's safe to ignore - or select it and click Exclude Selected " +
                        "to stop it appearing, and Remove Exclusion later.`r`n") -f $r.Name, $r.Version, $r.Available)
                }
                if ($stuck.Count -gt 0) {
                    Set-UiBusy -Busy $false -Status "$($stuck[0].Name) is still listed after upgrading - see the note in the log."
                }
                $script:JustUpgraded = @()
            }
            'search' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-MissingSource -Rows $rows -Source $script:listSource
                Set-GridItems -Rows $rows -Mode 'search'
                Set-UiBusy -Busy $false -Status $(if ($rows.Count -eq 0) { "No luck finding '$($txtSearchQuery.Text.Trim())'." } else { "Found $($rows.Count) match(es) for '$($txtSearchQuery.Text.Trim())' - pick some and click Install Selected." })
                Append-Log "`r`n$($rows.Count) result(s) found. Select one or more (Ctrl+click / Shift+click) and click 'Install Selected' to install them.`r`n"
            }
            'installed' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-GridItems -Rows $rows -Mode 'installed'
                Set-UiBusy -Busy $false -Status "$($rows.Count) apps installed on this PC."
                Append-Log "`r`n$($rows.Count) installed app(s) listed.`r`n"
            }
            'pins' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-GridItems -Rows $rows -Mode 'pins'
                Set-UiBusy -Busy $false -Status $(if ($rows.Count -eq 0) { 'No apps excluded - Upgrade All updates everything.' } else { "$($rows.Count) app(s) left alone by Upgrade All." })
                Append-Log "`r`n$($rows.Count) app(s) excluded from Upgrade All.`r`n"
            }
            'details' {
                Complete-PackageDetails -Output $finalContent
                Set-UiBusy -Busy $false -Status 'Ready.'
            }
            'queue' {
                $code = $null
                try { $code = $script:proc.ExitCode } catch { }
                Add-QueueResult -Item $script:currentQueueItem -Status 'Done' -ExitCode $code
                Start-NextQueuedPackage
            }
            { $_ -in @('upgradeAll', 'import') } {
                $what = if ($script:mode -eq 'import') { 'Import' } else { 'Upgrade All' }
                Append-Log "`r`n$what finished.`r`n"
                if ($chkRemoveDesktopIcons.IsChecked) { Start-DesktopWatch -Before $script:preShortcuts -RelatedNames $script:relatedNames }
                Append-Log "`r`nRefreshing list...`r`n"
                Start-CheckForUpdates -KeepLog
            }
            'export' {
                $code = $null
                try { $code = $script:proc.ExitCode } catch { }
                $msg = if ($code -eq 0) { 'Export finished.' } else { 'Export finished with errors - see the log.' }
                Append-Log "`r`n$msg`r`n"
                Set-UiBusy -Busy $false -Status $msg
            }
            'resetSources' {
                Append-Log "`r`nSources reset. Updating them now...`r`n"
                Start-SourceUpdate -KeepLog
            }
            'sourceUpdate' {
                Append-Log "`r`nSource update finished. Refreshing list...`r`n"
                Start-CheckForUpdates -KeepLog
            }
            'diagnose' {
                if ($script:diagTemp) { Remove-Item -LiteralPath $script:diagTemp -ErrorAction SilentlyContinue }
                Set-UiBusy -Busy $false -Status 'Network check done - see the results below.'
            }
        }
    }
})

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------
$dataGrid.Add_SelectionChanged({ Update-ActionButtons })

$dataGrid.Add_MouseDoubleClick({
    param($sender, $e)
    # Only react to double-clicks on an actual row, not the column headers or scrollbar.
    try {
        $node = $e.OriginalSource
        while ($node -and -not ($node -is [System.Windows.Controls.DataGridRow])) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        if ($node) { Show-PackageDetails }
    } catch { }
})

$btnCheck.Add_Click({ Start-CheckForUpdates })
$btnInstalled.Add_Click({ Start-ListInstalled })
$btnExcluded.Add_Click({ Start-ListPins })
$btnCancel.Add_Click({ Request-Cancel })
$btnBusyCancel.Add_Click({ Request-Cancel })
$btnDetails.Add_Click({ Show-PackageDetails })
$btnHomepage.Add_Click({ Open-Url -Url $script:HomepageUrl })
$btnReleaseNotes.Add_Click({ Open-Url -Url $script:ReleaseNotesUrl })

$txtFilter.Add_TextChanged({
    $script:filterText = $txtFilter.Text.Trim()
    Update-GridFilter
})
$btnClearFilter.Add_Click({ $txtFilter.Text = '' })

$btnUpgradeAll.Add_Click({
    $pending = @($script:lastUpdateRows)
    $confirm = Show-FriendlyDialog -Kind Question -Title 'Update everything?' `
        -Message "Winget will update every app it has an update for, one after another. Apps you've excluded are skipped." `
        -Items $pending -ItemsTitle "FOUND IN THE LAST CHECK ($($pending.Count))" `
        -YesText 'Yes, update all' -NoText 'Not now'
    if ($confirm) {
        if ($chkRemoveDesktopIcons.IsChecked) {
            $script:preShortcuts = Get-DesktopShortcutSnapshot
            # Everything last listed as outdated is what's about to be upgraded, so only
            # shortcuts matching one of these names are candidates for removal afterwards.
            $script:relatedNames = @($script:lastUpdateRows | ForEach-Object { $_.Name })
        } else {
            $script:preShortcuts = $null
        }
        $src = Get-SourceArg
        # Match what the list shows: if it was built with --include-unknown, packages with
        # an "Unknown" installed version appear as outdated, and --all silently skips them
        # unless it's given the same flag.
        $extra = if ($chkIncludeUnknown.IsChecked) { '--include-unknown' } else { '' }
        Start-WingetOperation -Arguments "upgrade --all $extra $src --accept-package-agreements --accept-source-agreements --disable-interactivity" `
            -Mode 'upgradeAll' -StatusText 'Upgrading all packages...'
    }
})

$btnUpgradeSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Title 'Update these apps?' -YesText 'Yes, update' `
            -Question "Winget will update each one in turn. You can keep an eye on it in the log while it works.") {
        Start-PackageQueue -Items $items -Action 'upgrade'
    }
})

$btnInstallSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Title 'Install these apps?' -YesText 'Yes, install' `
            -Question "Winget will download and install each one in turn.") {
        Start-PackageQueue -Items $items -Action 'install'
    }
})

$btnUninstallSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Title 'Remove these apps?' -YesText 'Yes, remove' -NoText 'Keep them' -Danger `
            -Question "They'll be uninstalled from this PC. You can always install them again later from Search.") {
        Start-PackageQueue -Items $items -Action 'uninstall'
    }
})

$btnExcludeSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Title 'Leave these out of Upgrade All?' -YesText 'Yes, exclude' `
            -Question "Upgrade All will skip them from now on. You can still update them one at a time, and bring them back any time from Excluded Apps.") {
        Start-PackageQueue -Items $items -Action 'pin'
    }
})

$btnRemoveExclusion.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Title 'Bring these back into Upgrade All?' -YesText 'Yes, include' `
            -Question "Upgrade All will update them along with everything else again.") {
        Start-PackageQueue -Items $items -Action 'unpin'
    }
})

$btnExport.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title    = 'Export list of installed apps'
    $dialog.Filter   = 'winget app list (*.json)|*.json'
    $dialog.FileName = "winget-apps-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd').json"
    if ($dialog.ShowDialog($window) -ne $true) { return }
    $path = $dialog.FileName
    Start-WingetOperation -Arguments "export -o `"$path`" $(Get-SourceArg) --accept-source-agreements --disable-interactivity" `
        -Mode 'export' -StatusText 'Exporting app list...'
})

$btnImport.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title  = 'Import a list of apps to install'
    $dialog.Filter = 'winget app list (*.json)|*.json|All files (*.*)|*.*'
    if ($dialog.ShowDialog($window) -ne $true) { return }
    $path = $dialog.FileName

    $ids = @()
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($source in @($json.Sources)) {
            foreach ($pkg in @($source.Packages)) { if ($pkg.PackageIdentifier) { $ids += $pkg.PackageIdentifier } }
        }
    } catch {
        [void](Show-FriendlyDialog -Kind Error -Title "That file didn't work" -YesText 'OK' `
            -Message "It couldn't be read as a winget app list. Pick a .json file made with Export List.`r`n`r`nDetails: $($_.Exception.Message)")
        return
    }
    if ($ids.Count -eq 0) {
        [void](Show-FriendlyDialog -Kind Info -Title 'That list is empty' -YesText 'OK' `
            -Message "There aren't any apps in that file, so there's nothing to install.")
        return
    }

    $confirm = Show-FriendlyDialog -Kind Question -Title 'Install the apps in this list?' `
        -Message "Winget will install everything in the list. Apps that are already on this PC are skipped." `
        -Items $ids -ItemsTitle "IN THE LIST ($($ids.Count))" -YesText 'Yes, install' -NoText 'Not now'
    if (-not $confirm) { return }

    if ($chkRemoveDesktopIcons.IsChecked) {
        $script:preShortcuts = Get-DesktopShortcutSnapshot
        # Package Ids like "Google.Chrome" still match shortcut names word by word.
        $script:relatedNames = $ids
    } else {
        $script:preShortcuts = $null
    }
    Start-WingetOperation -Arguments "import -i `"$path`" --ignore-unavailable --accept-package-agreements --accept-source-agreements --disable-interactivity" `
        -Mode 'import' -StatusText "Installing $($ids.Count) app(s) from list..."
})

$btnSaveLog.Add_Click({
    if ([string]::IsNullOrEmpty($txtLog.Text)) {
        [void](Show-FriendlyDialog -Kind Info -Title 'Nothing to save yet' -YesText 'Got it' `
            -Message "The log is empty. Run a check, search or install first, then save the log.")
        return
    }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title    = 'Save log'
    $dialog.Filter   = 'Text file (*.txt)|*.txt|Log file (*.log)|*.log'
    $dialog.FileName = "winget-log-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    if ($dialog.ShowDialog($window) -ne $true) { return }
    try {
        Set-Content -LiteralPath $dialog.FileName -Value $txtLog.Text -Encoding UTF8 -ErrorAction Stop
        $txtStatus.Text = "Log saved to $($dialog.FileName)"
    } catch {
        [void](Show-FriendlyDialog -Kind Error -Title "Couldn't save the log" -YesText 'OK' `
            -Message "Try a different folder.`r`n`r`nDetails: $($_.Exception.Message)")
    }
})

$btnResetSources.Add_Click({
    $confirm = Show-FriendlyDialog -Kind Warning -Title "Reset winget's sources?" `
        -Message ("This puts winget's app sources back to their defaults and refreshes them. It's the fix to try when searches fail with `"Failed when searching source`".`r`n`r`n" +
                  "If you've added any custom sources of your own, you'll need to add them again afterwards.") `
        -YesText 'Yes, reset' -NoText 'Cancel'
    if ($confirm) {
        Start-WingetOperation -Arguments 'source reset --force' `
            -Mode 'resetSources' -StatusText 'Resetting winget sources...'
    }
})

$btnDiagnose.Add_Click({ Start-NetworkDiagnostics })

$btnSearch.Add_Click({ Start-SearchSoftware -Query $txtSearchQuery.Text })

$txtSearchQuery.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') { Start-SearchSoftware -Query $txtSearchQuery.Text }
})

# ---------------------------------------------------------------------------
# About window - same look as the main window. It shares the main window's
# styles (merged in after loading, so they're referenced with DynamicResource),
# so the two can't drift apart.
# ---------------------------------------------------------------------------
$script:AboutWhatsNew = [ordered]@{
    $script:AppVersion = @(
        'Friendlier pop-ups: questions and notes now match the app, with plain wording, clear button labels and the apps listed neatly',
        'Risky questions (uninstall, close while busy) put the safe answer on Enter'
    )
    '1.15.3' = @(
        'Fixed the Homepage and Release Notes buttons showing little boxes instead of their icon',
        'Explains when an app is still listed after upgrading (winget version mismatch) and how to hide it'
    )
    '1.15.2' = @(
        'Fixed Exclude Selected, which skipped every app in the updates list',
        'Fixed Show Details wrongly saying updates and search results had no winget details'
    )
    '1.15.1' = @(
        'A tidier Details pane: clear headings, label / value rows, separate paragraphs and tags'
    )
    '1.15.0' = @(
        'No more command prompt windows popping up while winget runs',
        'A progress card showing what''s happening, how far along it is and how long it''s taken'
    )
    '1.14.0' = @(
        'A friendlier look: a header with the box mascot and a greeting',
        'All the actions in a sidebar of rounded, colour-coded cards',
        'Cheerier messages, and a note from the mascot when a list is empty'
    )
}

function Show-AboutWindow {
    [xml]$aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About Winget Update Manager" Width="560" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="#FFF7EA" FontFamily="Segoe UI" FontSize="13" Foreground="#2B2340">
    <StackPanel Margin="16">
        <Border CornerRadius="20" Padding="16,12" BorderBrush="#2B2340" BorderThickness="1.5">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#3FA4EE" Offset="0"/>
                    <GradientStop Color="#5B6CF0" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Image x:Name="AboutLogo" Width="76" Height="76" Margin="0,0,14,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="Winget Update Manager" FontSize="22" FontWeight="Bold" Foreground="#FFFFFF"/>
                    <Border CornerRadius="10" Background="#2B2340" Padding="10,3" Margin="0,6,0,0" HorizontalAlignment="Left">
                        <TextBlock x:Name="AboutVersion" Foreground="#FFFFFF" FontWeight="SemiBold"/>
                    </Border>
                </StackPanel>
            </Grid>
        </Border>

        <Border Style="{DynamicResource CardBox}" Padding="16,14" Margin="0,14,0,0">
            <StackPanel>
                <TextBlock Text="WHAT IT DOES" Style="{DynamicResource CardTitle}"/>
                <TextBlock TextWrapping="Wrap" LineHeight="20">
                    A friendly front end for winget, the Windows Package Manager. Check for updates and
                    upgrade one app, several or everything at once; find and install new software; see and
                    uninstall what's installed; keep chosen apps out of bulk upgrades; and copy a set of apps
                    to another PC. It can also run unattended with -UpgradeAll for Task Scheduler or Intune.
                </TextBlock>
            </StackPanel>
        </Border>

        <Border Style="{DynamicResource CardBox}" Padding="16,14" Margin="0,12,0,0">
            <StackPanel x:Name="AboutNew"/>
        </Border>

        <Grid Margin="2,14,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="AboutFooter" Grid.Column="0" Foreground="#5E5672" VerticalAlignment="Center" TextWrapping="Wrap"/>
            <Button x:Name="AboutClose" Grid.Column="1" Content="Close" Tag="&#xE73E;" Style="{DynamicResource MintButton}"
                    Margin="12,0,0,0" IsDefault="True" IsCancel="True"/>
        </Grid>
    </StackPanel>
</Window>
'@

    $about = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $aboutXaml))
    # Share the main window's styles (buttons, cards, titles).
    $about.Resources.MergedDictionaries.Add($window.Resources)
    $about.Owner = $window
    if ($window.Icon) { $about.Icon = $window.Icon }

    $about.FindName('AboutLogo').Source   = $imgLogo.Source
    $about.FindName('AboutVersion').Text  = "Version $script:AppVersion"

    $wingetVersion = Get-WingetVersion
    $about.FindName('AboutFooter').Text = "winget $wingetVersion  -  running as Administrator"

    # "What's new" lists, newest first.
    $panel  = $about.FindName('AboutNew')
    $bullet = [string][char]0x2022
    $first  = $true
    foreach ($version in $script:AboutWhatsNew.Keys) {
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = if ($first) { "WHAT'S NEW IN $version" } else { "ALSO NEW IN $version" }
        $title.Style = $about.FindResource('CardTitle')
        if (-not $first) { $title.Margin = New-Object System.Windows.Thickness(2, 12, 0, 6) }
        [void]$panel.Children.Add($title)

        foreach ($line in $script:AboutWhatsNew[$version]) {
            $row = New-Object System.Windows.Controls.TextBlock
            $row.Text = "$bullet  $line"
            $row.TextWrapping = 'Wrap'
            $row.Margin = New-Object System.Windows.Thickness(4, 0, 0, 4)
            [void]$panel.Children.Add($row)
        }
        $first = $false
    }

    $about.FindName('AboutClose').Add_Click({ $about.Close() }.GetNewClosure())
    [void]$about.ShowDialog()
}

$btnAbout.Add_Click({
    try {
        Show-AboutWindow
    } catch {
        # Never leave the About button doing nothing: fall back to a plain box.
        $wingetVersion = Get-WingetVersion
        [System.Windows.MessageBox]::Show(
            "Winget Update Manager`r`nVersion $script:AppVersion`r`n`r`n" +
            "A friendly front end for winget (Windows Package Manager).`r`n`r`n" +
            "winget $wingetVersion`r`n`r`n" +
            "(The styled About window couldn't open: $($_.Exception.Message))",
            'About Winget Update Manager', 'OK', 'Information') | Out-Null
    }
})

# Exit button and the window's own close (X) button go through the same check.
$btnExit.Add_Click({ $window.Close() })

$window.Add_Closing({
    param($sender, $e)
    if ($script:proc -and -not $script:proc.HasExited) {
        $pending = $script:queue.Count
        $extra   = if ($pending -gt 0) { " The $pending app(s) still waiting in the queue won't be done either." } else { '' }
        $confirm = Show-FriendlyDialog -Kind Warning -Title 'Winget is still working' `
            -Message "If you close now, the current job is stopped part-way.$extra" `
            -YesText 'Close anyway' -NoText 'Keep going' -Danger
        if (-not $confirm) {
            $e.Cancel = $true
            return
        }
        Stop-ProcessTree -Process $script:proc
    }
    Export-AppSettings
    $script:queue.Clear()
    $timer.Stop()
    $desktopWatchTimer.Stop()
    if ($script:tempOut -or $script:tempErr) {
        Remove-Item -LiteralPath $script:tempOut, $script:tempErr -ErrorAction SilentlyContinue
    }
})

Import-AppSettings
Limit-WindowToScreen
Update-ActionButtons

# Kick off an initial check as soon as the window is shown.
$window.Add_ContentRendered({ Start-CheckForUpdates })

$window.ShowDialog() | Out-Null
