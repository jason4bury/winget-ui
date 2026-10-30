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
$script:AppVersion = '1.13.0'

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

function Stop-ProcessTree {
    # winget starts the actual installer as a child process, so kill the whole tree
    # rather than just winget itself, or the installer carries on in the background.
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null
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
        $p = Start-Process -FilePath $script:WingetExe -ArgumentList $Arguments -NoNewWindow -PassThru `
            -WorkingDirectory (Split-Path -Parent $script:WingetExe) `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle
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
        Title="Winget Update Manager" Height="980" Width="1360" MinWidth="780" MinHeight="640"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Height" Value="30"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="Margin" Value="0,0,6,6"/>
            <Setter Property="MinWidth" Value="80"/>
        </Style>
        <Style x:Key="Divider" TargetType="Border">
            <Setter Property="Width" Value="1"/>
            <Setter Property="Height" Value="24"/>
            <Setter Property="Margin" Value="6,0,12,6"/>
            <Setter Property="Background" Value="#CCCCCC"/>
        </Style>
    </Window.Resources>
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="150"/>
            <RowDefinition Height="6"/>
            <RowDefinition x:Name="LogRow" Height="380" MinHeight="120"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Row 0: views and package actions -->
        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <WrapPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnCheck" Content="Check for Updates" ToolTip="Show packages with an update available"/>
                <Button x:Name="BtnUpgradeSelected" Content="Upgrade Selected"
                        ToolTip="Upgrade the selected package(s). Ctrl+click or Shift+click to select several."/>
                <Button x:Name="BtnUpgradeAll" Content="Upgrade All"
                        ToolTip="Upgrade everything with an update available (excluded apps are skipped)"/>
                <Border Style="{StaticResource Divider}"/>
                <Button x:Name="BtnInstalled" Content="Installed Apps" ToolTip="Show everything installed on this PC"/>
                <Button x:Name="BtnUninstallSelected" Content="Uninstall Selected" ToolTip="Uninstall the selected app(s)"/>
                <Border Style="{StaticResource Divider}"/>
                <Button x:Name="BtnExcluded" Content="Excluded Apps"
                        ToolTip="Show apps excluded from Upgrade All (winget pins)"/>
                <Button x:Name="BtnExcludeSelected" Content="Exclude Selected"
                        ToolTip="Stop Upgrade All (and -UpgradeAll mode) from upgrading the selected app(s)"/>
                <Button x:Name="BtnRemoveExclusion" Content="Remove Exclusion"
                        ToolTip="Let Upgrade All upgrade the selected app(s) again"/>
                <Border Style="{StaticResource Divider}"/>
                <Button x:Name="BtnCancel" Content="Cancel" IsEnabled="False"
                        ToolTip="Stop the current operation and skip anything still queued"/>
            </WrapPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnAbout" Content="About" Margin="12,0,6,6"/>
                <Button x:Name="BtnExit" Content="Exit" Margin="0,0,0,6"/>
            </StackPanel>
        </Grid>

        <!-- Row 1: search, export/import, tools -->
        <WrapPanel Grid.Row="1" Orientation="Horizontal">
            <TextBox x:Name="TxtSearchQuery" Width="200" Height="26" Margin="0,0,6,6" VerticalContentAlignment="Center"
                     ToolTip="Type a name (e.g. 'notepad++') then press Enter or click Search"/>
            <Button x:Name="BtnSearch" Content="Search"/>
            <Button x:Name="BtnInstallSelected" Content="Install Selected"
                    ToolTip="Install the selected search result(s). Ctrl+click or Shift+click to select several."/>
            <Border Style="{StaticResource Divider}"/>
            <Button x:Name="BtnExport" Content="Export List..." ToolTip="Save a list of installed apps to a file (winget export)"/>
            <Button x:Name="BtnImport" Content="Import List..." ToolTip="Install every app in a list saved with Export List (winget import)"/>
            <Border Style="{StaticResource Divider}"/>
            <Button x:Name="BtnSaveLog" Content="Save Log..." ToolTip="Save the log below to a text file"/>
            <Button x:Name="BtnResetSources" Content="Reset Sources"/>
            <Button x:Name="BtnDiagnose" Content="Diagnose Network"/>
        </WrapPanel>

        <!-- Row 2: current view, options, filter -->
        <Grid Grid.Row="2" Margin="0,2,0,6">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="TxtView" Grid.Column="0" FontWeight="SemiBold" FontSize="14" VerticalAlignment="Center" Margin="0,0,16,0" Text="Updates available"/>
            <WrapPanel Grid.Column="1" VerticalAlignment="Center">
                <CheckBox x:Name="ChkIncludeUnknown" Content="Include unknown versions" Margin="0,2,14,2" IsChecked="True"/>
                <CheckBox x:Name="ChkSkipStore" Content="Skip Microsoft Store (msstore) source" Margin="0,2,14,2" IsChecked="True"/>
                <CheckBox x:Name="ChkRemoveDesktopIcons" Content="Remove new desktop icons after install/upgrade" Margin="0,2,14,2" IsChecked="True"/>
            </WrapPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="TxtFilter" Width="200" Height="26" VerticalContentAlignment="Center"
                         ToolTip="Show only rows whose name or Id contains this text. Doesn't affect Upgrade All."/>
                <Button x:Name="BtnClearFilter" Content="X" MinWidth="26" Width="26" Height="26" Padding="0" Margin="4,0,0,0" ToolTip="Clear filter"/>
            </StackPanel>
        </Grid>

        <!-- Row 3: package list + details pane -->
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" MinWidth="300"/>
                <ColumnDefinition Width="6"/>
                <ColumnDefinition Width="340" MinWidth="200"/>
            </Grid.ColumnDefinitions>

            <DataGrid x:Name="Grid1" Grid.Column="0" AutoGenerateColumns="False" IsReadOnly="True"
                      SelectionMode="Extended" SelectionUnit="FullRow" AlternatingRowBackground="#F3F3F3"
                      CanUserAddRows="False" CanUserDeleteRows="False" GridLinesVisibility="Horizontal"
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

            <GridSplitter Grid.Column="1" Width="6" HorizontalAlignment="Stretch" Background="Transparent"/>

            <Border Grid.Column="2" BorderBrush="#D0D0D0" BorderThickness="1" Padding="10">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Details" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,6"/>
                    <WrapPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                        <Button x:Name="BtnDetails" Content="Show Details" ToolTip="Show details for the selected package (or double-click it)"/>
                        <Button x:Name="BtnHomepage" Content="Homepage" IsEnabled="False"/>
                        <Button x:Name="BtnReleaseNotes" Content="Release Notes" IsEnabled="False"/>
                    </WrapPanel>
                    <TextBox x:Name="TxtDetails" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0"
                             VerticalScrollBarVisibility="Auto" FontFamily="Segoe UI" Foreground="#333333"
                             Text="Select a package and click Show Details (or double-click it) to see its publisher, description and links."/>
                </DockPanel>
            </Border>
        </Grid>

        <GridSplitter Grid.Row="4" Height="6" HorizontalAlignment="Stretch" VerticalAlignment="Center"
                      ResizeDirection="Rows" ResizeBehavior="PreviousAndNext" Background="Transparent"/>

        <TextBox x:Name="TxtLog" Grid.Row="5" FontFamily="Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 IsReadOnly="True" TextWrapping="NoWrap" Background="#111111" Foreground="#DDDDDD"/>

        <StackPanel Grid.Row="6" Margin="0,6,0,0">
            <TextBlock x:Name="TxtStatus" Text="Ready." FontStyle="Italic"/>
            <ProgressBar x:Name="Progress" Height="6" Margin="0,6,0,0" IsIndeterminate="False" Visibility="Collapsed"/>
        </StackPanel>
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
$txtLog               = $window.FindName('TxtLog')
$txtStatus            = $window.FindName('TxtStatus')
$progress             = $window.FindName('Progress')
$logRow               = $window.FindName('LogRow')

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
$script:layoutVersion = 2

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
    $progress.Visibility      = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $progress.IsIndeterminate = $Busy
    Update-ActionButtons
    if ($Status) { $txtStatus.Text = $Status }
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
        [switch]$NoLogStream
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

    $startParams = @{
        FilePath               = $FilePath
        ArgumentList           = $Arguments
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $script:tempOut
        RedirectStandardError  = $script:tempErr
    }
    if ($FilePath -eq $script:WingetExe) { $startParams.WorkingDirectory = Split-Path -Parent $script:WingetExe }
    $script:proc = Start-Process @startParams

    # Touching .Handle straight away makes .NET keep the process handle open, which is
    # what lets ExitCode be read after the process has exited. Without it, ExitCode on a
    # Start-Process -PassThru object often comes back empty.
    $null = $script:proc.Handle

    $timer.Start()
}

function Get-SourceArg {
    # Scoping to the default "winget" source skips msstore entirely, which avoids
    # its recurring source-agreement / region-reporting prompt on machines where
    # it has never been interactively accepted.
    if ($chkSkipStore.IsChecked) { return '--source winget' } else { return '' }
}

function Start-CheckForUpdates {
    param([switch]$KeepLog)
    $extra = if ($chkIncludeUnknown.IsChecked) { '--include-unknown' } else { '' }
    $src   = Get-SourceArg
    # --disable-interactivity turns off winget's console-only behaviour (progress bars,
    # width detection, etc). Without it, winget run with redirected output (as we do here,
    # so the log pane can show it) can misbehave in ways that don't show up when you run
    # the same command directly in a normal terminal window.
    Start-WingetOperation -Arguments "upgrade $extra $src --accept-source-agreements --disable-interactivity" `
        -Mode 'check' -StatusText 'Checking for updates...' -KeepLog:$KeepLog
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
        [System.Windows.MessageBox]::Show("Type something to search for first, e.g. `"notepad++`".", "Winget GUI", 'OK', 'Warning') | Out-Null
        return
    }

    $src      = Get-SourceArg
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

    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($diagScript)
    $encoded = [Convert]::ToBase64String($bytes)

    Start-WingetOperation -FilePath 'powershell.exe' `
        -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" `
        -Mode 'diagnose' -StatusText 'Running network diagnostics...' `
        -LogPrefix '> Running network diagnostics...'
}

# ---------------------------------------------------------------------------
# Details pane
# ---------------------------------------------------------------------------
function Set-DetailsLinks {
    param([string]$Homepage, [string]$ReleaseNotes)
    $btnHomepage.Tag           = $Homepage
    $btnHomepage.IsEnabled     = [bool]$Homepage
    $btnReleaseNotes.Tag       = $ReleaseNotes
    $btnReleaseNotes.IsEnabled = [bool]$ReleaseNotes
}

function Show-PackageDetails {
    $item = $dataGrid.SelectedItem
    if (-not $item -or $script:busy) { return }

    $script:detailsItem = $item
    Set-DetailsLinks
    if (-not $item.Source) {
        $txtDetails.Text = "$($item.Name)`r`n$($item.Id)`r`n`r`nThis app wasn't installed from a winget source, so winget has no details for it."
        return
    }

    $txtDetails.Text = "Loading details for $($item.Name)..."
    $id = $item.Id
    Start-WingetOperation -Arguments "show --id `"$id`" -e --source `"$($item.Source)`" --accept-source-agreements --disable-interactivity" `
        -Mode 'details' -StatusText "Loading details for $($item.Name)..." -NoLogStream
}

function Complete-PackageDetails {
    param([string]$Output)

    $lines = @()
    if ($Output) { $lines = $Output -split "`r?`n" }

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^Found ') { $start = $i; break } }

    if ($start -lt 0) {
        $msg = ($lines | Where-Object { $_ -match '\S' }) -join "`r`n"
        if (-not $msg) { $msg = 'winget returned no details.' }
        $txtDetails.Text = "$($script:detailsItem.Name)`r`n`r`n$msg"
        Set-DetailsLinks
        return
    }

    # Keep everything from "Found ..." up to the installer technicalities.
    $kept = New-Object System.Collections.Generic.List[string]
    for ($i = $start; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Installer:') { break }
        $kept.Add($lines[$i].TrimEnd())
    }
    $text = ($kept -join "`r`n").Trim()

    $homepage = $null; $notes = $null
    foreach ($l in $kept) {
        if (-not $homepage -and $l -match '^\s*Homepage:\s*(https?://\S+)') { $homepage = $Matches[1] }
        if (-not $notes -and $l -match '^\s*Release Notes Url:\s*(https?://\S+)') { $notes = $Matches[1] }
    }

    $txtDetails.Text = $text
    $txtDetails.ScrollToHome()
    Set-DetailsLinks -Homepage $homepage -ReleaseNotes $notes
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
function Format-PackageList {
    param([object[]]$Items, [int]$Max = 15)
    $lines = @($Items | Select-Object -First $Max | ForEach-Object { "  - $($_.Name) ($($_.Id))" })
    if ($Items.Count -gt $Max) { $lines += "  ...and $($Items.Count - $Max) more" }
    return ($lines -join "`r`n")
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

        Start-WingetOperation -Arguments $wingetArgs -Mode 'queue' -KeepLog `
            -StatusText "$verb$counter $($item.Name)..." -LogPrefix $prefix
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
    # Shared "nothing selected" warning + confirmation prompt for the Selected buttons.
    param([object[]]$Items, [string]$Question, [string]$Title, [string]$Icon = 'Question')
    if ($Items.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Select one or more packages in the list first (Ctrl+click or Shift+click to select several).", "Winget GUI", 'OK', 'Warning') | Out-Null
        return $false
    }
    $answer = [System.Windows.MessageBox]::Show("$Question`r`n`r`n$(Format-PackageList -Items $Items)", $Title, 'YesNo', $Icon)
    return ($answer -eq 'Yes')
}

# ---------------------------------------------------------------------------
# Cancel
# ---------------------------------------------------------------------------
function Request-Cancel {
    if (-not $script:proc -or $script:proc.HasExited) { return }
    $script:cancelRequested = $true
    $btnCancel.IsEnabled = $false
    $txtStatus.Text = 'Cancelling...'
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
            $txtDetails.Text = 'Cancelled.'
            Set-UiBusy -Busy $false -Status 'Cancelled.'
        }
        default {
            Append-Log "`r`n----- Cancelled -----`r`n"
            Set-UiBusy -Busy $false -Status 'Cancelled.'
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
                $script:lastUpdateRows = $rows
                Set-GridItems -Rows $rows -Mode 'updates'
                Set-UiBusy -Busy $false -Status "$($rows.Count) update(s) available."
                Append-Log "`r`n$($rows.Count) update(s) available.`r`n"
            }
            'search' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-GridItems -Rows $rows -Mode 'search'
                Set-UiBusy -Busy $false -Status "$($rows.Count) result(s) for '$($txtSearchQuery.Text.Trim())'."
                Append-Log "`r`n$($rows.Count) result(s) found. Select one or more (Ctrl+click / Shift+click) and click 'Install Selected' to install them.`r`n"
            }
            'installed' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-GridItems -Rows $rows -Mode 'installed'
                Set-UiBusy -Busy $false -Status "$($rows.Count) installed app(s)."
                Append-Log "`r`n$($rows.Count) installed app(s) listed.`r`n"
            }
            'pins' {
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                Set-GridItems -Rows $rows -Mode 'pins'
                Set-UiBusy -Busy $false -Status "$($rows.Count) excluded app(s)."
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
                Set-UiBusy -Busy $false -Status 'Diagnostics complete.'
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
$btnDetails.Add_Click({ Show-PackageDetails })
$btnHomepage.Add_Click({ Open-Url -Url $btnHomepage.Tag })
$btnReleaseNotes.Add_Click({ Open-Url -Url $btnReleaseNotes.Tag })

$txtFilter.Add_TextChanged({
    $script:filterText = $txtFilter.Text.Trim()
    Update-GridFilter
})
$btnClearFilter.Add_Click({ $txtFilter.Text = '' })

$btnUpgradeAll.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "Run 'winget upgrade --all' now? This will upgrade every package winget can update (excluded apps are skipped).",
        "Confirm Upgrade All", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
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
    if (Confirm-Selection -Items $items -Question "Upgrade $($items.Count) package(s) now?" -Title 'Confirm Upgrade') {
        Start-PackageQueue -Items $items -Action 'upgrade'
    }
})

$btnInstallSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Question "Install $($items.Count) package(s) now?" -Title 'Confirm Install') {
        Start-PackageQueue -Items $items -Action 'install'
    }
})

$btnUninstallSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Question "Uninstall $($items.Count) app(s)? This removes them from this PC." -Title 'Confirm Uninstall' -Icon 'Warning') {
        Start-PackageQueue -Items $items -Action 'uninstall'
    }
})

$btnExcludeSelected.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Question "Exclude $($items.Count) app(s) from Upgrade All? You can still upgrade them one at a time, and undo this from Excluded Apps." -Title 'Confirm Exclude') {
        Start-PackageQueue -Items $items -Action 'pin'
    }
})

$btnRemoveExclusion.Add_Click({
    $items = Get-SelectedPackages
    if (Confirm-Selection -Items $items -Question "Let Upgrade All upgrade $($items.Count) app(s) again?" -Title 'Confirm Remove Exclusion') {
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
        [System.Windows.MessageBox]::Show("That file couldn't be read as a winget export list.`r`n`r`n$($_.Exception.Message)", 'Winget GUI', 'OK', 'Error') | Out-Null
        return
    }
    if ($ids.Count -eq 0) {
        [System.Windows.MessageBox]::Show('That file doesn''t list any packages.', 'Winget GUI', 'OK', 'Warning') | Out-Null
        return
    }

    $preview = (@($ids | Select-Object -First 15 | ForEach-Object { "  - $_" }) -join "`r`n")
    if ($ids.Count -gt 15) { $preview += "`r`n  ...and $($ids.Count - 15) more" }
    $confirm = [System.Windows.MessageBox]::Show(
        "Install the $($ids.Count) app(s) in this list? Apps that are already installed are skipped.`r`n`r`n$preview",
        'Confirm Import', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

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
        [System.Windows.MessageBox]::Show('The log is empty.', 'Winget GUI', 'OK', 'Information') | Out-Null
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
        [System.Windows.MessageBox]::Show("Couldn't save the log.`r`n`r`n$($_.Exception.Message)", 'Winget GUI', 'OK', 'Error') | Out-Null
    }
})

$btnResetSources.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "This resets all configured winget sources back to their defaults (any custom sources you added would need to be re-added) and then refreshes them. Use this when package searches are failing, e.g. `"Failed when searching source`". Continue?",
        "Confirm Reset Sources", 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') {
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

$btnAbout.Add_Click({
    $wingetVersion = try { (& $script:WingetExe --version) } catch { 'unknown' }
    [System.Windows.MessageBox]::Show(
        "Winget Update Manager`r`n" +
        "Version $script:AppVersion`r`n`r`n" +
        "A simple GUI front end for winget (Windows Package Manager).`r`n`r`n" +
        "Checks for updates and upgrades selected packages or everything at once; searches " +
        "for and installs new software; lists and uninstalls installed apps; excludes apps " +
        "from Upgrade All; exports and imports app lists; and includes tools to reset " +
        "winget's sources and diagnose network issues. Can also run unattended with " +
        "-UpgradeAll (see README). Runs elevated (as Administrator) automatically.`r`n`r`n" +
        "New in $($script:AppVersion):`r`n" +
        "  - Installed Apps view with Uninstall Selected`r`n" +
        "  - Exclude apps from Upgrade All (Excluded Apps view)`r`n" +
        "  - Cancel button for long operations`r`n" +
        "  - Export / Import app lists`r`n" +
        "  - Filter box, Details pane and Save Log`r`n" +
        "  - Remembers your settings and window size`r`n" +
        "  - -UpgradeAll command-line mode for Task Scheduler / Intune`r`n`r`n" +
        "Detected winget version: $wingetVersion",
        "About Winget Update Manager", 'OK', 'Information') | Out-Null
})

# Exit button and the window's own close (X) button go through the same check.
$btnExit.Add_Click({ $window.Close() })

$window.Add_Closing({
    param($sender, $e)
    if ($script:proc -and -not $script:proc.HasExited) {
        $pending = $script:queue.Count
        $extra   = if ($pending -gt 0) { " $pending more queued package(s) will not be processed." } else { '' }
        $confirm = [System.Windows.MessageBox]::Show(
            "A winget operation is still running.$extra Exit anyway?",
            "Confirm Exit", 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') {
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