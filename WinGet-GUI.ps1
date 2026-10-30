<#
    Winget-GUI.ps1
    A simple WPF front end for winget.

    On launch it runs "winget upgrade" to list what's outdated, then lets you
    upgrade everything ("winget upgrade --all") or one or more selected
    packages, search for new software and install one or more results, with
    live output in the log pane.

    Tip: Ctrl+click or Shift+click in the list to select several packages,
    then use Upgrade Selected / Install Selected to process them one after
    another.

    Run it by double-clicking, or from a terminal:
        powershell -ExecutionPolicy Bypass -File .\Winget-GUI.ps1
#>

# Bump this whenever you ship a change worth noting in CHANGELOG.md.
$script:AppVersion = '1.12.0'

# ---------------------------------------------------------------------------
# Hide the PowerShell console window this script is running in, if any, so
# only the GUI shows. The compiled .exe (see README) already has no console
# via ps2exe's -noConsole switch, so this is a no-op there; it's for running
# the .ps1 directly (double-click, a shortcut, or an existing terminal),
# where a console window would otherwise sit behind/alongside the GUI. Done
# as early as possible to minimise any visible flash before it takes effect.
# ---------------------------------------------------------------------------
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
        try {
            # -STA is included here too so an elevated relaunch satisfies both requirements
            # (admin rights and a WPF-compatible thread) in a single relaunch.
            Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-File', "`"$PSCommandPath`"") -Verb RunAs -WindowStyle Hidden | Out-Null
        } catch {
            # Most likely the UAC prompt was cancelled, or this account can't elevate at all.
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                "Winget Update Manager needs to run as Administrator (installing/upgrading software " +
                "and managing the shared Public Desktop both require it), but elevation was cancelled " +
                "or failed.`r`n`r`n$($_.Exception.Message)",
                "Winget GUI", 'OK', 'Error') | Out-Null
        }
        exit
    }

    # WPF needs an STA thread. Windows PowerShell defaults to STA, but PowerShell 7 (pwsh)
    # defaults to MTA, so relaunch ourselves with -STA if needed. (Normally already satisfied
    # by the elevation relaunch above, but this covers running the script from an already-
    # elevated pwsh session directly.)
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-File', "`"$PSCommandPath`"") -WindowStyle Hidden
        exit
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
# Make sure winget is actually available before we build any UI.
# ---------------------------------------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
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
        Title="Winget Update Manager" Height="760" Width="1300" MinWidth="620"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="280"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <WrapPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnCheck" Content="Check for Updates" Width="150" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnUpgradeSelected" Content="Upgrade Selected" Width="160" Height="30" Margin="0,0,8,8"
                        ToolTip="Upgrade the selected package(s). Ctrl+click or Shift+click to select several."/>
                <Button x:Name="BtnUpgradeAll" Content="Upgrade All" Width="120" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnResetSources" Content="Reset Sources" Width="120" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnDiagnose" Content="Diagnose Network" Width="130" Height="30" Margin="0,0,8,8"/>
                <TextBox x:Name="TxtSearchQuery" Width="200" Height="26" Margin="12,0,4,8" VerticalAlignment="Center"
                         ToolTip="Type a name (e.g. 'notepad++') then click Search"/>
                <Button x:Name="BtnSearch" Content="Search" Width="90" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnInstallSelected" Content="Install Selected" Width="150" Height="30" Margin="0,0,8,8"
                        ToolTip="Install the selected search result(s). Ctrl+click or Shift+click to select several."/>
                <CheckBox x:Name="ChkIncludeUnknown" Content="Include unknown versions" VerticalAlignment="Center" Margin="12,0,0,8" IsChecked="True"/>
                <CheckBox x:Name="ChkSkipStore" Content="Skip Microsoft Store (msstore) source" VerticalAlignment="Center" Margin="12,0,0,8" IsChecked="True"/>
                <CheckBox x:Name="ChkRemoveDesktopIcons" Content="Remove new desktop icons after install/upgrade" VerticalAlignment="Center" Margin="12,0,0,8" IsChecked="True"/>
            </WrapPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnAbout" Content="About" Width="80" Height="30" Margin="12,0,8,0"/>
                <Button x:Name="BtnExit" Content="Exit" Width="80" Height="30"/>
            </StackPanel>
        </Grid>

        <DataGrid x:Name="Grid1" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                  SelectionMode="Extended" SelectionUnit="FullRow" AlternatingRowBackground="#F3F3F3"
                  CanUserAddRows="False" CanUserDeleteRows="False" GridLinesVisibility="Horizontal"
                  ToolTip="Ctrl+click or Shift+click to select several packages">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="2*"/>
                <DataGridTextColumn Header="Id" Binding="{Binding Id}" Width="2*"/>
                <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="1*"/>
                <DataGridTextColumn Header="Available" Binding="{Binding Available}" Width="1*"/>
                <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="1*"/>
            </DataGrid.Columns>
        </DataGrid>

        <TextBlock x:Name="TxtStatus" Grid.Row="2" Margin="0,8,0,4" Text="Ready." FontStyle="Italic"/>

        <TextBox x:Name="TxtLog" Grid.Row="3" FontFamily="Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 IsReadOnly="True" TextWrapping="NoWrap" Background="#111111" Foreground="#DDDDDD"/>

        <ProgressBar x:Name="Progress" Grid.Row="4" Height="6" Margin="0,8,0,0" IsIndeterminate="False" Visibility="Collapsed"/>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$btnCheck           = $window.FindName('BtnCheck')
$btnUpgradeSelected = $window.FindName('BtnUpgradeSelected')
$btnUpgradeAll      = $window.FindName('BtnUpgradeAll')
$btnResetSources    = $window.FindName('BtnResetSources')
$btnDiagnose        = $window.FindName('BtnDiagnose')
$txtSearchQuery     = $window.FindName('TxtSearchQuery')
$btnSearch          = $window.FindName('BtnSearch')
$btnInstallSelected = $window.FindName('BtnInstallSelected')
$btnAbout           = $window.FindName('BtnAbout')
$btnExit            = $window.FindName('BtnExit')
$chkIncludeUnknown  = $window.FindName('ChkIncludeUnknown')
$chkSkipStore       = $window.FindName('ChkSkipStore')
$chkRemoveDesktopIcons = $window.FindName('ChkRemoveDesktopIcons')
$dataGrid           = $window.FindName('Grid1')
$txtStatus          = $window.FindName('TxtStatus')
$txtLog             = $window.FindName('TxtLog')
$progress           = $window.FindName('Progress')

# ---------------------------------------------------------------------------
# State shared between the UI thread and the poll timer
# ---------------------------------------------------------------------------
$script:proc          = $null
$script:tempOut       = $null
$script:tempErr       = $null
$script:lastOutLength = 0
$script:lastErrLength = 0
$script:mode          = $null
$script:busy          = $false
$script:preShortcuts  = $null
$script:relatedNames  = $null
$script:desktopWatchBefore       = $null
$script:desktopWatchRelatedNames = $null
$script:desktopWatchTicksLeft    = 0

# What the grid is currently showing: 'updates' (installed packages with an
# upgrade available) or 'search' (search results, which may not be installed).
# Upgrade Selected only makes sense for the former, Install Selected for the latter.
$script:gridMode = 'updates'

# Multi-package queue for Install Selected / Upgrade Selected. Packages are
# processed one at a time (one winget process each) so every package gets its
# own clearly separated log section and its own exit code in the summary.
$script:queue            = New-Object System.Collections.Generic.List[object]
$script:queueAction      = $null    # 'install' or 'upgrade'
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

function Update-ActionButtons {
    # Shows how many packages are selected on the two "Selected" buttons, and only
    # enables the one that fits what the grid is showing right now.
    $count  = $dataGrid.SelectedItems.Count
    $suffix = if ($count -gt 1) { " ($count)" } else { '' }
    $btnUpgradeSelected.Content   = "Upgrade Selected$suffix"
    $btnInstallSelected.Content   = "Install Selected$suffix"
    $btnUpgradeSelected.IsEnabled = (-not $script:busy) -and ($script:gridMode -eq 'updates')
    $btnInstallSelected.IsEnabled = (-not $script:busy) -and ($script:gridMode -eq 'search')
}

function Set-UiBusy {
    param([bool]$Busy, [string]$Status)
    $script:busy                  = $Busy
    $btnCheck.IsEnabled           = -not $Busy
    $btnUpgradeAll.IsEnabled      = -not $Busy
    $btnResetSources.IsEnabled    = -not $Busy
    $btnDiagnose.IsEnabled        = -not $Busy
    $btnSearch.IsEnabled          = -not $Busy
    $txtSearchQuery.IsEnabled     = -not $Busy
    $dataGrid.IsEnabled           = -not $Busy
    $progress.Visibility          = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $progress.IsIndeterminate     = $Busy
    Update-ActionButtons
    if ($Status) { $txtStatus.Text = $Status }
}

function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $txtLog.AppendText($Text)
    $txtLog.ScrollToEnd()
}

function Read-OutputFile {
    # winget writes UTF-8 when its output is redirected. Windows PowerShell 5.1's
    # Get-Content assumes the system ANSI code page unless told otherwise, which
    # mangles winget's truncation character and any non-ASCII package names (and
    # can then throw the column slicing off), so always read as UTF-8.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    return Get-Content -Path $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-WingetTableColumns {
    <#
      Figures out which of winget's known column headers are actually present in a
      given header line, and where each one starts. Different winget commands print
      different columns ("upgrade" has Name/Id/Version/Available/Source; "search"
      has Name/Id/Version/Source, sometimes with an extra "Match" column in the
      middle), so this is detected per-table rather than assumed fixed.
    #>
    param([string]$HeaderLine)

    $candidates = @('Name', 'Id', 'Version', 'Match', 'Available', 'Source')
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
      winget's tables ("upgrade", "search", etc.) are column-aligned, not delimited,
      so we find the header row, work out which columns are actually present and
      where each one starts, then slice every following line at those offsets.
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

function Remove-NewDesktopShortcuts {
    param([string[]]$Before, [string[]]$RelatedNames)

    if (-not $Before) { return }

    $after = Get-DesktopShortcutSnapshot
    $new   = @($after | Where-Object { $Before -notcontains $_ })

    $toRemove = @($new | Where-Object { Test-ShortcutRelatesToPackage -ShortcutPath $_ -RelatedNames $RelatedNames })
    $toSkip   = @($new | Where-Object { $_ -notin $toRemove })

    foreach ($p in $toSkip) {
        Append-Log "`r`nLeaving new desktop icon alone (doesn't look related to what was just installed/upgraded): $p`r`n"
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

function Start-DesktopWatch {
    param([string[]]$Before, [string[]]$RelatedNames)

    if (-not $Before) { return }

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
        [string]$FilePath = 'winget',
        [string]$Arguments,
        [string]$Mode,
        [string]$StatusText,
        [string]$LogPrefix,
        # Follow-on operations (the list refresh after an upgrade, each package in a
        # multi-package queue, etc.) keep the existing log instead of wiping it, so the
        # output of what just ran - and any desktop icon cleanup - is still visible.
        [switch]$KeepLog
    )

    $script:mode          = $Mode
    $script:tempOut       = [System.IO.Path]::GetTempFileName()
    $script:tempErr       = [System.IO.Path]::GetTempFileName()
    $script:lastOutLength = 0
    $script:lastErrLength = 0

    if (-not $KeepLog) { $txtLog.Clear() }
    if ($LogPrefix) { Append-Log "$LogPrefix`r`n`r`n" } else { Append-Log "> winget $Arguments`r`n`r`n" }
    Set-UiBusy -Busy $true -Status $StatusText

    $script:proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $script:tempOut `
        -RedirectStandardError $script:tempErr

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
    # winget talks to its backends over WinHTTP, which has its OWN proxy
    # configuration separate from the browser's (WinINet). On a network with a
    # proxy set up only for browsers, this is the single most common reason
    # "winget" (the default source) fails to search while everything else
    # (browsing, Store apps, etc.) looks fine. This runs the checks that reveal
    # that, plus basic reachability to the source endpoints, without needing a
    # separate terminal.
    $diagScript = @'
Write-Output "=== WinHTTP proxy configuration (this is what winget actually uses) ==="
netsh winhttp show proxy
Write-Output ""
Write-Output "=== WinINet / system proxy (what browsers use, for comparison) ==="
try {
    $reg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
    Write-Output "ProxyEnable: $($reg.ProxyEnable)   ProxyServer: $($reg.ProxyServer)"
} catch {
    Write-Output "Could not read WinINet proxy settings: $($_.Exception.Message)"
}

$hostsToTest = @('cdn.winget.microsoft.com','winget.azureedge.net','storeedgefd.dsx.mp.microsoft.com')
foreach ($h in $hostsToTest) {
    Write-Output ""
    Write-Output "=== $h ==="
    try {
        $result = Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue
        Write-Output "TCP 443 reachable: $($result.TcpTestSucceeded)   Resolved IP: $($result.RemoteAddress)"
    } catch {
        Write-Output "TCP test failed: $($_.Exception.Message)"
    }
    try {
        $resp = Invoke-WebRequest -Uri "https://$h" -Method Head -UseBasicParsing -TimeoutSec 8
        Write-Output "HTTPS HEAD status: $($resp.StatusCode)"
    } catch {
        Write-Output "HTTPS HEAD failed: $($_.Exception.Message)"
    }
}

Write-Output ""
Write-Output "=== How to read this ==="
Write-Output "If WinHTTP shows 'Direct access (no proxy server)' but WinINet/your browser DOES use a proxy,"
Write-Output "that mismatch is almost certainly why winget fails. Fix (run elevated):"
Write-Output "    netsh winhttp import proxy source=ie"
Write-Output "A '407' in the HTTPS HEAD result means the proxy needs authentication winget cannot provide."
Write-Output "A TCP failure or timeout on all three hosts points to a firewall block on those domains."
'@

    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($diagScript)
    $encoded = [Convert]::ToBase64String($bytes)

    Start-WingetOperation -FilePath 'powershell.exe' `
        -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" `
        -Mode 'diagnose' -StatusText 'Running network diagnostics...' `
        -LogPrefix '> Running network diagnostics...'
}

# ---------------------------------------------------------------------------
# Multi-package queue (Install Selected / Upgrade Selected)
# ---------------------------------------------------------------------------
function Format-PackageList {
    param([object[]]$Items, [int]$Max = 15)
    $lines = @($Items | Select-Object -First $Max | ForEach-Object { "  - $($_.Name) ($($_.Id))" })
    if ($Items.Count -gt $Max) { $lines += "  ...and $($Items.Count - $Max) more" }
    return ($lines -join "`r`n")
}

function Start-PackageQueue {
    param([object[]]$Items, [ValidateSet('install', 'upgrade')][string]$Action)

    $script:queue.Clear()
    foreach ($i in $Items) { $script:queue.Add($i) }
    $script:queueAction  = $Action
    $script:queueTotal   = $Items.Count
    $script:queueResults.Clear()

    if ($chkRemoveDesktopIcons.IsChecked) {
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

function Start-NextQueuedPackage {
    if ($script:queue.Count -eq 0) {
        Complete-PackageQueue
        return
    }

    $item = $script:queue[0]
    $script:queue.RemoveAt(0)
    $script:currentQueueItem = $item

    $position = $script:queueTotal - $script:queue.Count
    $src      = Get-SourceArg
    $id       = $item.Id

    if ($script:queueAction -eq 'install') {
        $verb = 'Installing'
        $wingetArgs = "install --id `"$id`" -e $src --accept-package-agreements --accept-source-agreements --disable-interactivity"
    } else {
        $verb = 'Upgrading'
        $wingetArgs = "upgrade --id `"$id`" -e $src --accept-package-agreements --accept-source-agreements --disable-interactivity"
    }

    $counter = if ($script:queueTotal -gt 1) { " ($position of $($script:queueTotal))" } else { '' }
    $prefix  = "===== $verb$counter : $($item.Name) =====`r`n> winget $wingetArgs"
    if ($position -gt 1) { $prefix = "`r`n$prefix" }

    Start-WingetOperation -Arguments $wingetArgs -Mode 'queue' -KeepLog `
        -StatusText "$verb$counter $($item.Name)..." -LogPrefix $prefix
}

function Complete-PackageQueue {
    $verb = if ($script:queueAction -eq 'install') { 'Install' } else { 'Upgrade' }
    $okCount = @($script:queueResults | Where-Object { $_.ExitCode -eq 0 }).Count

    Append-Log "`r`n===== $verb summary: $okCount of $($script:queueResults.Count) succeeded =====`r`n"
    foreach ($r in $script:queueResults) {
        if ($r.ExitCode -eq 0) {
            Append-Log "  OK     $($r.Name) ($($r.Id))`r`n"
        } elseif ($null -eq $r.ExitCode) {
            Append-Log "  CHECK  $($r.Name) ($($r.Id)) - exit code unavailable, see the log above`r`n"
        } else {
            $hex = '0x{0:X8}' -f [int]$r.ExitCode
            Append-Log "  CHECK  $($r.Name) ($($r.Id)) - exit code $hex, see the log above`r`n"
        }
    }

    if ($chkRemoveDesktopIcons.IsChecked) {
        Start-DesktopWatch -Before $script:preShortcuts -RelatedNames $script:relatedNames
    }

    Append-Log "`r`nRefreshing list of outdated packages...`r`n"
    Start-CheckForUpdates -KeepLog
}

function Get-SelectedPackages {
    return @($dataGrid.SelectedItems | ForEach-Object { $_ })
}

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

    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()

        # One last read in case output landed between the final tick and exit.
        $finalContent = Read-OutputFile -Path $script:tempOut
        if ($finalContent -and $finalContent.Length -gt $script:lastOutLength) {
            Append-Log $finalContent.Substring($script:lastOutLength)
        }
        $errContent = Read-OutputFile -Path $script:tempErr
        if ($errContent -and $errContent.Length -gt $script:lastErrLength) {
            Append-Log $errContent.Substring($script:lastErrLength)
        }

        Remove-Item -Path $script:tempOut, $script:tempErr -ErrorAction SilentlyContinue

        switch ($script:mode) {
            'check' {
                $lines = @()
                if ($finalContent) { $lines = $finalContent -split "`r?`n" }
                # @() guards against PowerShell unwrapping a single-item result into a bare
                # object instead of a one-element array - DataGrid.ItemsSource requires an
                # IEnumerable and throws ("Cannot convert ... to System.Collections.IEnumerable")
                # if handed a lone PSCustomObject, which happens whenever exactly one upgrade
                # is found.
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                $script:gridMode = 'updates'
                $dataGrid.ItemsSource = $rows

                Set-UiBusy -Busy $false -Status "$($rows.Count) update(s) available."
                Append-Log "`r`n$($rows.Count) update(s) available.`r`n"
            }
            'search' {
                $lines = @()
                if ($finalContent) { $lines = $finalContent -split "`r?`n" }
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                $script:gridMode = 'search'
                $dataGrid.ItemsSource = $rows

                Set-UiBusy -Busy $false -Status "$($rows.Count) result(s) for '$($txtSearchQuery.Text.Trim())'."
                Append-Log "`r`n$($rows.Count) result(s) found. Select one or more (Ctrl+click / Shift+click) and click 'Install Selected' to install them.`r`n"
            }
            'queue' {
                $code = $null
                try { $code = $script:proc.ExitCode } catch { }
                $script:queueResults.Add([PSCustomObject]@{
                    Name     = $script:currentQueueItem.Name
                    Id       = $script:currentQueueItem.Id
                    ExitCode = $code
                })
                Start-NextQueuedPackage
            }
            'upgradeAll' {
                Append-Log "`r`nUpgrade All finished.`r`n"
                if ($chkRemoveDesktopIcons.IsChecked) { Start-DesktopWatch -Before $script:preShortcuts -RelatedNames $script:relatedNames }
                Append-Log "`r`nRefreshing list...`r`n"
                Start-CheckForUpdates -KeepLog
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

$dataGrid.Add_SelectionChanged({ Update-ActionButtons })

$btnCheck.Add_Click({ Start-CheckForUpdates })

$btnUpgradeAll.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "Run 'winget upgrade --all' now? This will upgrade every package winget can update.",
        "Confirm Upgrade All", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        if ($chkRemoveDesktopIcons.IsChecked) {
            $script:preShortcuts = Get-DesktopShortcutSnapshot
            # Everything currently listed as outdated is what's about to be upgraded, so only
            # shortcuts matching one of these names are candidates for removal afterwards.
            $script:relatedNames = @($dataGrid.ItemsSource | ForEach-Object { $_.Name })
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

$btnInstallSelected.Add_Click({
    $items = Get-SelectedPackages
    if ($items.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Select one or more packages in the search results first (Ctrl+click or Shift+click to select several).", "Winget GUI", 'OK', 'Warning') | Out-Null
        return
    }
    $confirm = [System.Windows.MessageBox]::Show(
        "Install $($items.Count) package(s) now?`r`n`r`n$(Format-PackageList -Items $items)",
        "Confirm Install", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        Start-PackageQueue -Items $items -Action 'install'
    }
})

$btnUpgradeSelected.Add_Click({
    $items = Get-SelectedPackages
    if ($items.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Select one or more packages in the list first (Ctrl+click or Shift+click to select several).", "Winget GUI", 'OK', 'Warning') | Out-Null
        return
    }
    $confirm = [System.Windows.MessageBox]::Show(
        "Upgrade $($items.Count) package(s) now?`r`n`r`n$(Format-PackageList -Items $items)",
        "Confirm Upgrade", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        Start-PackageQueue -Items $items -Action 'upgrade'
    }
})

$btnAbout.Add_Click({
    $wingetVersion = try { (& winget --version) } catch { 'unknown' }
    [System.Windows.MessageBox]::Show(
        "Winget Update Manager`r`n" +
        "Version $script:AppVersion`r`n`r`n" +
        "A simple GUI front end for winget (Windows Package Manager).`r`n`r`n" +
        "Checks for available updates, upgrades selected packages or everything at once, " +
        "lets you search for new software and install it, and includes tools to reset " +
        "winget's sources and diagnose network issues when package searches fail. Runs " +
        "elevated (as Administrator) automatically.`r`n`r`n" +
        "New in $($script:AppVersion): select several packages at once (Ctrl+click or " +
        "Shift+click) to install or upgrade them in one go, with a summary at the end.`r`n`r`n" +
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
        try { $script:proc.Kill() } catch { }
    }
    $script:queue.Clear()
    $timer.Stop()
    $desktopWatchTimer.Stop()
    if ($script:tempOut -or $script:tempErr) {
        Remove-Item -Path $script:tempOut, $script:tempErr -ErrorAction SilentlyContinue
    }
})

Update-ActionButtons

# Kick off an initial check as soon as the window is shown.
$window.Add_ContentRendered({ Start-CheckForUpdates })

$window.ShowDialog() | Out-Null