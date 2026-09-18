<#
    Winget-GUI.ps1
    A simple WPF front end for winget.

    On launch it runs "winget upgrade" to list what's outdated, then lets you
    upgrade everything ("winget upgrade --all") or just the selected package,
    with live output in the log pane.

    Run it by double-clicking, or from a terminal:
        powershell -ExecutionPolicy Bypass -File .\Winget-GUI.ps1
#>

# WPF needs an STA thread. Windows PowerShell defaults to STA, but PowerShell 7 (pwsh)
# defaults to MTA, so relaunch ourselves with -STA if needed.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-File', "`"$PSCommandPath`"")
    exit
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
        Title="Winget Update Manager" Height="660" Width="1300" MinWidth="620"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="180"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <WrapPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnCheck" Content="Check for Updates" Width="150" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnUpgradeSelected" Content="Upgrade Selected" Width="140" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnUpgradeAll" Content="Upgrade All" Width="120" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnResetSources" Content="Reset Sources" Width="120" Height="30" Margin="0,0,8,8"/>
                <Button x:Name="BtnDiagnose" Content="Diagnose Network" Width="130" Height="30" Margin="0,0,8,8"/>
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
                  SelectionMode="Single" SelectionUnit="FullRow" AlternatingRowBackground="#F3F3F3"
                  CanUserAddRows="False" CanUserDeleteRows="False" GridLinesVisibility="Horizontal">
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
$script:preShortcuts = $null

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)

function Set-UiBusy {
    param([bool]$Busy, [string]$Status)
    $btnCheck.IsEnabled           = -not $Busy
    $btnUpgradeSelected.IsEnabled = -not $Busy
    $btnUpgradeAll.IsEnabled      = -not $Busy
    $btnResetSources.IsEnabled    = -not $Busy
    $btnDiagnose.IsEnabled        = -not $Busy
    $dataGrid.IsEnabled           = -not $Busy
    $progress.Visibility          = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $progress.IsIndeterminate     = $Busy
    if ($Status) { $txtStatus.Text = $Status }
}

function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $txtLog.AppendText($Text)
    $txtLog.ScrollToEnd()
}

function ConvertFrom-WingetUpgradeTable {
    <#
      winget's "upgrade" table is column-aligned, not delimited, so we find the
      header row and slice every following line at the same character offsets.
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

    $header = $Lines[$headerIndex]

    function Get-ColStart {
        param([string]$Name, [int]$From)
        $idx = $header.IndexOf($Name, $From)
        return $idx
    }

    $nameStart      = Get-ColStart -Name 'Name' -From 0
    $idStart        = Get-ColStart -Name 'Id' -From ($nameStart + 4)
    $versionStart   = Get-ColStart -Name 'Version' -From ($idStart + 2)
    $availableStart = Get-ColStart -Name 'Available' -From ($versionStart + 7)
    $sourceStart    = Get-ColStart -Name 'Source' -From ($availableStart + 9)

    if ($idStart -lt 0 -or $versionStart -lt 0 -or $availableStart -lt 0) { return $results }

    # Row after the header is the "----" separator; data starts after that.
    for ($i = $headerIndex + 2; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]

        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -match '^\d+\s+upgrades? available' -or $line -match '^No installed package found') { break }

        $pad = $line
        if ($pad.Length -lt $header.Length) { $pad = $pad.PadRight($header.Length) }

        $name = $pad.Substring($nameStart, $idStart - $nameStart).Trim()
        $id   = $pad.Substring($idStart, $versionStart - $idStart).Trim()
        $ver  = $pad.Substring($versionStart, $availableStart - $versionStart).Trim()

        if ($sourceStart -gt $availableStart) {
            $avail  = $pad.Substring($availableStart, $sourceStart - $availableStart).Trim()
            $source = $pad.Substring($sourceStart).Trim()
        }
        else {
            $avail  = $pad.Substring($availableStart).Trim()
            $source = ''
        }

        if ($name -and $id) {
            $results += [PSCustomObject]@{
                Name      = $name
                Id        = $id
                Version   = $ver
                Available = $avail
                Source    = $source
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

function Remove-NewDesktopShortcuts {
    param([string[]]$Before)

    if (-not $Before) { return }

    $after = Get-DesktopShortcutSnapshot
    $new   = @($after | Where-Object { $Before -notcontains $_ })

    if ($new.Count -gt 0) {
        Append-Log "`r`nRemoving $($new.Count) new desktop icon(s) created by this install/upgrade:`r`n"
        foreach ($p in $new) {
            try {
                Remove-Item -Path $p -Force -ErrorAction Stop
                Append-Log "  Removed: $p`r`n"
            } catch {
                Append-Log "  Could not remove ${p}: $($_.Exception.Message)`r`n"
            }
        }
    }
}

function Start-WingetOperation {
    param(
        [string]$FilePath = 'winget',
        [string]$Arguments,
        [string]$Mode,
        [string]$StatusText,
        [string]$LogPrefix
    )

    $script:mode          = $Mode
    $script:tempOut       = [System.IO.Path]::GetTempFileName()
    $script:tempErr       = [System.IO.Path]::GetTempFileName()
    $script:lastOutLength = 0
    $script:lastErrLength = 0

    $txtLog.Clear()
    if ($LogPrefix) { Append-Log "$LogPrefix`r`n`r`n" } else { Append-Log "> winget $Arguments`r`n`r`n" }
    Set-UiBusy -Busy $true -Status $StatusText

    $script:proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $script:tempOut `
        -RedirectStandardError $script:tempErr

    $timer.Start()
}

function Get-SourceArg {
    # Scoping to the default "winget" source skips msstore entirely, which avoids
    # its recurring source-agreement / region-reporting prompt on machines where
    # it has never been interactively accepted.
    if ($chkSkipStore.IsChecked) { return '--source winget' } else { return '' }
}

function Start-CheckForUpdates {
    $extra = if ($chkIncludeUnknown.IsChecked) { '--include-unknown' } else { '' }
    $src   = Get-SourceArg
    # --disable-interactivity turns off winget's console-only behaviour (progress bars,
    # width detection, etc). Without it, winget run with redirected output (as we do here,
    # so the log pane can show it) can misbehave in ways that don't show up when you run
    # the same command directly in a normal terminal window.
    Start-WingetOperation -Arguments "upgrade $extra $src --accept-source-agreements --disable-interactivity" `
        -Mode 'check' -StatusText 'Checking for updates...'
}

function Start-SourceUpdate {
    # --verbose-logs makes winget write extra diagnostic detail to its log file
    # (%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir)
    # in case the console output here isn't enough to see why a source failed.
    Start-WingetOperation -Arguments 'source update --verbose-logs --disable-interactivity' `
        -Mode 'sourceUpdate' -StatusText 'Updating winget sources...'
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

$timer.Add_Tick({
    if ($script:tempOut -and (Test-Path $script:tempOut)) {
        $content = Get-Content -Path $script:tempOut -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Length -gt $script:lastOutLength) {
            Append-Log $content.Substring($script:lastOutLength)
            $script:lastOutLength = $content.Length
        }
    }
    if ($script:tempErr -and (Test-Path $script:tempErr)) {
        $content = Get-Content -Path $script:tempErr -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Length -gt $script:lastErrLength) {
            Append-Log $content.Substring($script:lastErrLength)
            $script:lastErrLength = $content.Length
        }
    }

    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()

        # One last read in case output landed between the final tick and exit.
        $finalContent = ''
        if (Test-Path $script:tempOut) {
            $finalContent = Get-Content -Path $script:tempOut -Raw -ErrorAction SilentlyContinue
            if ($finalContent -and $finalContent.Length -gt $script:lastOutLength) {
                Append-Log $finalContent.Substring($script:lastOutLength)
            }
        }
        if (Test-Path $script:tempErr) {
            $errContent = Get-Content -Path $script:tempErr -Raw -ErrorAction SilentlyContinue
            if ($errContent -and $errContent.Length -gt $script:lastErrLength) {
                Append-Log $errContent.Substring($script:lastErrLength)
            }
        }

        Remove-Item -Path $script:tempOut, $script:tempErr -ErrorAction SilentlyContinue

        switch ($script:mode) {
            'check' {
                $lines = @()
                if ($finalContent) { $lines = $finalContent -split "`r?`n" }
                # @() guards against PowerShell unwrapping a single-item result into a bare
                # object instead of a one-element array — DataGrid.ItemsSource requires an
                # IEnumerable and throws ("Cannot convert ... to System.Collections.IEnumerable")
                # if handed a lone PSCustomObject, which happens whenever exactly one upgrade
                # is found.
                $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
                $dataGrid.ItemsSource = $rows

                Set-UiBusy -Busy $false -Status "$($rows.Count) update(s) available."
                Append-Log "`r`n$($rows.Count) update(s) available.`r`n"
            }
            'upgradeAll' {
                Append-Log "`r`nUpgrade All finished.`r`n"
                if ($chkRemoveDesktopIcons.IsChecked) { Remove-NewDesktopShortcuts -Before $script:preShortcuts }
                Append-Log "`r`nRefreshing list...`r`n"
                Start-CheckForUpdates
            }
            'upgradeOne' {
                Append-Log "`r`nUpgrade finished.`r`n"
                if ($chkRemoveDesktopIcons.IsChecked) { Remove-NewDesktopShortcuts -Before $script:preShortcuts }
                Append-Log "`r`nRefreshing list...`r`n"
                Start-CheckForUpdates
            }
            'resetSources' {
                Append-Log "`r`nSources reset. Updating them now...`r`n"
                Start-SourceUpdate
            }
            'sourceUpdate' {
                Append-Log "`r`nSource update finished. Refreshing list...`r`n"
                Start-CheckForUpdates
            }
            'diagnose' {
                Set-UiBusy -Busy $false -Status 'Diagnostics complete.'
            }
        }
    }
})

$btnCheck.Add_Click({ Start-CheckForUpdates })

$btnUpgradeAll.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "Run 'winget upgrade --all' now? This will upgrade every package winget can update.",
        "Confirm Upgrade All", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        if ($chkRemoveDesktopIcons.IsChecked) { $script:preShortcuts = Get-DesktopShortcutSnapshot }
        $src = Get-SourceArg
        Start-WingetOperation -Arguments "upgrade --all $src --accept-package-agreements --accept-source-agreements --disable-interactivity" `
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

$btnAbout.Add_Click({
    $wingetVersion = try { (& winget --version) } catch { 'unknown' }
    [System.Windows.MessageBox]::Show(
        "Winget Update Manager`r`n`r`n" +
        "A simple GUI front end for winget (Windows Package Manager).`r`n`r`n" +
        "Checks for available updates, upgrades a selected package or everything at once, " +
        "and includes tools to reset winget's sources and diagnose network issues when " +
        "package searches fail.`r`n`r`n" +
        "Detected winget version: $wingetVersion",
        "About Winget Update Manager", 'OK', 'Information') | Out-Null
})

$btnExit.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        $confirm = [System.Windows.MessageBox]::Show(
            "A winget operation is still running. Exit anyway?",
            "Confirm Exit", 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        try { $script:proc.Kill() } catch { }
    }
    $window.Close()
})

$btnUpgradeSelected.Add_Click({
    $item = $dataGrid.SelectedItem
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Select a package in the list first.", "Winget GUI", 'OK', 'Warning') | Out-Null
        return
    }
    $confirm = [System.Windows.MessageBox]::Show(
        "Upgrade '$($item.Name)' ($($item.Id)) now?",
        "Confirm Upgrade", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        if ($chkRemoveDesktopIcons.IsChecked) { $script:preShortcuts = Get-DesktopShortcutSnapshot }
        $escapedId = $item.Id
        Start-WingetOperation -Arguments "upgrade --id `"$escapedId`" -e --accept-package-agreements --accept-source-agreements --disable-interactivity" `
            -Mode 'upgradeOne' -StatusText "Upgrading $($item.Name)..."
    }
})

# Kick off an initial check as soon as the window is shown.
$window.Add_ContentRendered({ Start-CheckForUpdates })

$window.ShowDialog() | Out-Null