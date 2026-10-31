# Winget Update Manager

<p align="center">
  <img src="assets/winget-gui-logo.png" alt="Winget Update Manager logo" width="200">
</p>

A small PowerShell + WPF front end for [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/) (the Windows Package Manager). It gives you a checkable list of what's outdated and buttons to upgrade everything, upgrade, install or uninstall one or several selected packages, keep chosen apps out of bulk upgrades, and recover from the source/network issues winget occasionally runs into. It can also run unattended from Task Scheduler or Intune.

![Windows](https://img.shields.io/badge/platform-Windows-blue) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE)

## Features

A friendly window with a sidebar of colour-coded buttons, a list of packages in the middle, a details pane on the right and a live log underneath.


- On launch, automatically runs `winget upgrade` and lists what's outdated in a sortable grid (Name, Id, Version, Available, Source).
- **Search** — type a name and search winget's sources (`winget search`), then **Install Selected** to install whatever you pick from the results (one package or several), with the same confirmation prompt and live log output as an upgrade.
- **Upgrade All** — runs `winget upgrade --all` with a confirmation prompt, streaming live output into a log pane.
- **Upgrade Selected** — upgrades just the highlighted package(s).
- **Installed Apps** — lists everything installed on the PC (`winget list`), including apps that didn't come from winget, with **Uninstall Selected** to remove them.
- **Exclude Selected** / **Excluded Apps** / **Remove Exclusion** — keep particular apps out of **Upgrade All** (for example apps Intune manages, or ones that need to stay on a specific version). Exclusions are winget pins (`winget pin add`), so they also apply to `winget upgrade --all` run by hand and to `-UpgradeAll` mode. An excluded app can still be upgraded on purpose, one at a time.
- **Cancel** — stops the current operation (including the installer winget started) and skips anything still queued; the summary shows what was cancelled or skipped.
- **Export List** / **Import List** — save the apps on one PC to a `.json` file (`winget export`) and install them all on another (`winget import`). Handy for setting up a new machine with a standard set of apps.
- **Filter** — type in the filter box to narrow the current list by name or Id. It only affects what's shown; **Upgrade All** still upgrades everything.
- **Details pane** — select a package and click **Show Details** (or double-click it) to see its publisher, description, licence and links (`winget show`), with buttons to open its homepage and release notes.
- **Save Log** — saves the log pane to a text file, e.g. to attach to a ticket.
- Remembers the checkbox settings, the window's size and position, and the log pane's height between runs (in `%APPDATA%\WingetUpdateManager\settings.json`).
- **Multi-select** — Ctrl+click or Shift+click to select several packages in the list; the **Selected** buttons (install, upgrade, uninstall, exclude) then process them one after another, with a separate log section for each and a summary at the end showing which succeeded. The buttons show how many are selected, e.g. "Install Selected (3)".
- **Reset Sources** — runs `winget source reset --force` followed by `winget source update`, for when package searches start failing.
- **Diagnose Network** — checks the proxy settings winget uses (WinHTTP) against the browser's (WinINet), then DNS, firewall, TLS and HTTPS access to winget's real sources, including spotting SSL inspection by a web filter (a non-Microsoft certificate issuer). Each check shows OK or PROBLEM, with a summary at the end, for tracking down "failed to search source" errors caused by proxies or content filters.
- Checkbox to skip the Microsoft Store (`msstore`) source, which avoids a recurring source-agreement prompt on machines where it's never been accepted interactively.
- Checkbox to include packages with unknown/undetectable versions (`--include-unknown`).
- Checkbox to automatically remove any new desktop icons (`.lnk`/`.url`, on either your Desktop or the shared Public Desktop) that an install/upgrade creates, so **Upgrade All**/**Upgrade Selected**/**Install Selected** don't leave a trail of shortcuts behind. Keeps checking for 20 seconds after the operation finishes, since some installers create their shortcut via a background process rather than immediately — and only removes a new shortcut if its name plausibly matches the package(s) just installed/upgraded, so icons you already had (including pinned ones) are left alone.
- About and Exit buttons.
- Shows its own icon on the window and taskbar: `WinGet-GUI.ico` is picked up from the same folder as the script, and the compiled `.exe` uses the icon built into it.
- Relaunches itself elevated (as Administrator) automatically on launch if it isn't already, since installing/upgrading software and managing the shared Public Desktop both normally require it.
- Hides its own PowerShell console window on launch, so only the GUI window is shown (the compiled `.exe` already has no console via ps2exe's `-noConsole` switch). In `-UpgradeAll` mode the console stays visible to show progress, unless `-Silent` is used.

## Requirements

- Windows 10 or 11 with [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) (which provides `winget`) installed. winget 1.5 or later is needed for excluding apps (`winget pin`); everything else works with older versions.
- Administrator rights. The script will prompt for elevation (UAC) automatically on launch if it isn't already running as admin.
- PowerShell 5.1 (built into Windows) or PowerShell 7+. The script detects which one it's running under and relaunches itself in STA mode automatically if needed (WPF requires an STA thread, and PowerShell 7 defaults to MTA).

## Usage

Download `Winget-GUI.ps1` and run it either by double-clicking (if `.ps1` files are associated with PowerShell on your system) or from a terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\Winget-GUI.ps1
```

No installation, no dependencies beyond winget itself. Keep `WinGet-GUI.ico` in the same folder if you want the app's own icon on the window and taskbar (it works fine without it).

### Unattended mode (Task Scheduler / Intune)

Add `-UpgradeAll` to upgrade everything with no window, write a log file, and exit with winget's exit code:

```powershell
powershell -ExecutionPolicy Bypass -File .\WinGet-GUI.ps1 -UpgradeAll -Silent
```

The compiled `.exe` takes the same switches, e.g. `"WinGet-GUI v1.13.0.exe" -UpgradeAll -Silent`.

| Switch | What it does |
| --- | --- |
| `-UpgradeAll` | Runs `winget upgrade --all` with no window. Excluded apps are skipped. |
| `-Silent` | Writes only to the log file, nothing to the console. Use this for scheduled tasks. |
| `-LogPath <file>` | Where to write the log. Default: `%ProgramData%\WingetUpdateManager\Logs\upgrade-<date>-<time>.log` |
| `-SkipUnknown` | Leaves out packages whose installed version winget can't detect (included by default, like the GUI). |
| `-IncludeStore` | Also uses the Microsoft Store (`msstore`) source (skipped by default, like the GUI). |
| `-KeepDesktopIcons` | Doesn't remove desktop icons created by the upgrades. |

It works when run as SYSTEM (an Intune script, or a scheduled task set to run as SYSTEM): winget isn't normally on the PATH for SYSTEM, so the script finds it in the App Installer package folder instead. Note that apps installed per-user (rather than for all users) aren't visible to SYSTEM and won't be upgraded that way.

### Optional: build as a standalone .exe

If you'd rather distribute a single `.exe` than a `.ps1` (e.g. for deployment via Intune), you can compile it with the free, open-source [ps2exe](https://github.com/MScholtes/PS2EXE) module. This has to be run on a real Windows PowerShell/pwsh install — it can't be produced any other way.

Double-click `Build-Exe.cmd` (included in this repo) in the same folder as `WinGet-GUI.ps1` and `WinGet-GUI.ico`. No admin rights or open PowerShell window needed. It builds `WinGet-GUI v<version>.exe` in the same folder.

It sets the execution policy to Bypass for the build only (nothing machine-wide changes), installs the `ps2exe` module for your user the first time it's needed (turning on TLS 1.2 and installing the NuGet provider first, so it works on a fresh PC without prompts), and compiles the exe with the icon and `-STA -requireAdmin -noConsole` switches below. The output is named `WinGet-GUI v<version>.exe` (e.g. `WinGet-GUI v1.13.0.exe`), with `<version>` read straight out of `$script:AppVersion`, so the exe's filename and version metadata can't go stale. Everything shown on screen is also saved to `Build-Exe.log`.

If you'd rather run the ps2exe steps yourself, this is what `Build-Exe.cmd` does:

```powershell
# -Scope Process only affects this one console window, not the machine-wide policy — needed
# because ps2exe's own module file won't load under PowerShell's default "Restricted" policy.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

Install-Module -Name ps2exe -Scope CurrentUser -Force
Import-Module ps2exe

Invoke-ps2exe -inputFile .\WinGet-GUI.ps1 -outputFile ".\WinGet-GUI v1.13.0.exe" `
    -STA -requireAdmin -noConsole `
    -iconFile .\WinGet-GUI.ico `
    -title "Winget Update Manager" -version "1.13.0" -product "Winget GUI"
```

`-STA` and `-requireAdmin` bake the WPF thread and elevation requirements directly into the `.exe`'s manifest, so Windows handles both automatically before the script even runs — the script detects when it's running as a compiled `.exe` and skips its own manual relaunch logic in that case, so you won't get a double UAC prompt. `-noConsole` hides the PowerShell console window behind the GUI. `-iconFile` gives the compiled `.exe` its own icon (`WinGet-GUI.ico`, included in this repo) — it needs a real multi-resolution `.ico` file, not a `.png`/`.jpg` directly. The resulting `WinGet-GUI.exe` is fully standalone (winget itself still needs to be installed on the target machine, as before).

## Troubleshooting

winget can fail in a few distinct ways when run from a script rather than typed directly into a terminal. This tool grew out of debugging those, so a few notes in case you hit the same things:

**"The `msstore` source requires that you view the following agreements..."**
The Microsoft Store source needs a one-time interactive agreement acceptance that a non-interactive script can't provide. Tick "Skip Microsoft Store (msstore) source" (on by default) to bypass it entirely — most people don't need Store-app updates through winget anyway.

**"Failed when searching source; results will not be included: winget"**
This means the *default* community source failed to search, independent of the Store issue above. Try **Reset Sources** first. If that doesn't help, it's often a proxy/network problem — winget uses WinHTTP for its network calls, which has its own proxy configuration separate from the browser's (WinINet). Use **Diagnose Network** to compare the two and check reachability to `cdn.winget.microsoft.com`. On a network with content filtering or SSL inspection, that domain may need to be added to an inspection-bypass list (not just a general allow rule), since inspection can corrupt the binary index file in transit rather than cleanly blocking it.

**`0x8a15000f` / "Data required by the source is missing"**
A corrupted or incompatible local copy of the source index. Try:
```powershell
winget source remove -n winget
winget source add -n winget -a https://cdn.winget.microsoft.com/cache -t "Microsoft.PreIndexed.Package"
```
If it persists only on certain machines/networks and not others (e.g. works at home, fails behind a work firewall), the index download is likely being corrupted in transit by a filtering proxy rather than the client itself being at fault — compare `winget --version` across machines to rule out a stale client first.

**Works fine typed directly into a terminal, but fails through this GUI**
The GUI redirects winget's output to a file so it can display it in the log pane; winget's console-only behaviour (progress bars, width detection) can misbehave without a real console attached. The script already passes `--disable-interactivity` to every winget call to avoid this.

## How it works

It's a single self-contained script: an inline XAML window loaded via `XamlReader`, with winget invoked through `Start-Process` with redirected stdout/stderr written to temp files, polled by a `DispatcherTimer` so the UI stays responsive and the log pane updates live. The "upgrade" table winget prints isn't machine-readable (no `--output json` support for this command), so results are parsed by locating the header row and slicing each line at the same column offsets.

## License

MIT — see [LICENSE](LICENSE).
