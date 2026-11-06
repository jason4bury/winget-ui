# Changelog

All notable changes to this project are documented here.

## [1.15.3] - 2026-11-06
### Fixed
- **Homepage and Release Notes buttons** filled with little boxes after showing a package's
  details. The web address was stored where the button keeps its icon; it is now kept separately.

### Added
- **"Still listed after upgrading" note.** When an app upgrades successfully but winget still
  lists it (for example Internet Download Manager 6.43.18 / 6.43.18.1, where the app reports a
  different version number to Windows than winget's listing), the log explains why, says it's
  safe to ignore, and suggests Exclude Selected to hide it.

## [1.15.2] - 2026-11-04
### Fixed
- **Exclude Selected did nothing for apps in the updates list.** With "Skip Microsoft Store
  source" ticked, winget leaves the Source column out of its table, so every row was read with
  a blank source and then skipped as "not from a winget source". The source the list was
  fetched from is now filled back in, so excluding works.
- The same blank source made **Show Details** say updates and search results "weren't
  installed from a winget source". They now show their details.

## [1.15.1] - 2026-11-03
### Changed
- **Details pane tidied up.** Instead of winget's raw text run together, it now shows the app
  name as a heading with its Id and a version badge, then neat label / value rows (Publisher,
  Author, Licence, Copyright, Short name), the description as separate paragraphs under
  "About", release notes under "What's new in this version" (trimmed if very long) and tags as
  small pills.
- The Homepage button falls back to the publisher's website when a package has no homepage.

## [1.15.0] - 2026-10-31
### Added
- **Progress card**: while winget is working, a card over the list shows what's happening
  (e.g. "Upgrading Google Chrome..."), a progress bar, how long it's been running and a Cancel
  button. When several packages are being installed, upgraded or uninstalled, the bar fills
  step by step ("Package 2 of 5"); Upgrade All and Import do the same by following winget's
  "(2/5) Found ..." lines.

### Fixed
- **No more command prompt windows.** In the compiled exe, every winget run opened its own
  console window, because the exe has no console to share. winget (and the network check,
  version check and the command that stops a cancelled install) now run with no window at all,
  with their output still shown in the log. This also applies to `-UpgradeAll` mode.
- Diagnose Network now runs its checks from a temporary script file instead of a very long
  encoded command line.

## [1.14.0] - 2026-10-31
### Changed
- A friendlier, less formal look to match the new mascot:
  - A blue header with the box mascot and a time-of-day greeting, with About and Exit in it.
  - All the actions moved into a sidebar of rounded cards (Updates, Find New Apps, Installed
    Apps, Leave Alone, Tools), so the package list and log keep their height.
  - Rounded, colour-coded buttons with small icons: blue to show a list, green to install or
    upgrade, pink to uninstall, yellow to cancel.
  - Softer colours throughout: a cream background, white cards, a lilac list header and a
    deep-purple log panel ("What's happening").
  - Save Log moved to the log panel, and Cancel sits next to the progress bar.
- **About** is now its own window in the same style (mascot header, version badge, a
  "What it does" card and "What's new" lists) instead of a plain message box.
- Friendlier messages, e.g. "All up to date - nothing to do!", and a picture of the mascot with
  a short note when a list is empty instead of a blank box.
- The mascot is embedded in the script, so the header works without any image files and inside
  the compiled exe.
- The window opens taller (1120 instead of 980) so the whole sidebar fits without scrolling;
  smaller screens still get a window shrunk to fit. Window and log sizes saved by older
  versions are ignored once, because the layout changed.

## [1.13.0] - 2026-10-30
### Added
- **Installed Apps** view (`winget list`), including apps that didn't come from winget, with
  **Uninstall Selected**.
- **Exclude Selected**, **Excluded Apps** and **Remove Exclusion**: keep chosen apps out of
  Upgrade All. Exclusions are winget pins, so they also apply to `winget upgrade --all` run by
  hand and to the new `-UpgradeAll` mode. Excluded apps can still be upgraded one at a time.
- **Cancel** button: stops the running operation, including the installer winget launched
  (the whole process tree is ended), and skips anything still queued. The summary marks those
  packages as cancelled or skipped.
- **Export List** / **Import List** (`winget export` / `winget import`) for copying a set of
  apps from one PC to another.
- **Filter** box to narrow the current list by name or Id.
- **Details pane** (`winget show`): publisher, description, licence and links for the selected
  package, with Homepage and Release Notes buttons. Opens on double-click too.
- **Save Log** button.
- Remembers the checkbox settings and window size/position between runs
  (`%APPDATA%\WingetUpdateManager\settings.json`).
- **Unattended mode**: `-UpgradeAll` upgrades everything with no window, logs to
  `%ProgramData%\WingetUpdateManager\Logs` (or `-LogPath`) and exits with winget's exit code,
  for Task Scheduler or Intune. Also `-Silent`, `-SkipUnknown`, `-IncludeStore` and
  `-KeepDesktopIcons`. Works as SYSTEM: winget is found in the App Installer package folder
  when it isn't on the PATH.
- The log pane and Details pane can be resized by dragging the splitters. The log pane is
  taller by default (and the window taller to fit), its height is remembered, and the window
  is shrunk to fit smaller screens.

### Changed
- Toolbar reorganised into two rows, with the current view and its item count shown above the
  list.
- Relaunching (for elevation or STA mode) now passes along any command-line switches, and adds
  `-ExecutionPolicy Bypass` for the relaunched process.
- Long package Ids that winget truncated with "..." in its table are now matched by prefix
  instead of failing an exact match.

- `Build-Exe.ps1` replaced by `Build-Exe.cmd`: double-click to build the exe, no PowerShell
  window or admin rights needed. It sets the execution policy for the build only, installs
  ps2exe if it's missing (enabling TLS 1.2 and installing the NuGet provider first, so it works
  unattended on a fresh PC), and saves its output to `Build-Exe.log`.
- `*.exe` added to `.gitignore`: attach builds to GitHub releases instead of committing them.

### Fixed
- **Diagnose Network** reported errors on networks where winget works fine. It requested the
  bare server addresses (which return 404 by design) and still tested `winget.azureedge.net`,
  which Microsoft has retired. It now checks DNS, TCP, the TLS certificate (a non-Microsoft
  issuer means SSL inspection by a web filter) and the real winget source file, treats any
  HTTP answer from a bare address as "reached", marks each check OK / PROBLEM and ends with a
  summary.
- "Leaving new desktop icon alone" was logged every two seconds during the 20-second
  desktop-icon check. It's now logged once per icon.
- The `Source` value for excluded apps no longer picks up the "Pin type" column.

## [1.12.1] - 2026-10-30
### Changed
- New, friendlier artwork: a cheerful cardboard-box mascot with an upgrade arrow replaces the
  old glossy logo (which also used the Windows logo, a Microsoft trademark). Updated
  `WinGet-GUI.ico` (16-256px, with simplified small sizes so it stays readable in the taskbar),
  `WinGet-GUI.png` (now 256px, down from 1.3 MB) and `assets/winget-gui-logo.png`.
- README title now uses the app's name, "Winget Update Manager", consistently.

### Added
- The window and taskbar now show the app's own icon instead of the default one. The script
  loads `WinGet-GUI.ico` from its own folder; the compiled `.exe` falls back to the icon ps2exe
  embedded in it.
- `assets/social-preview.png`: a 1280x640 banner for GitHub's Social preview setting, so links
  to the repo get a proper card in Teams, Slack, etc.
- `assets/icon.svg`: the icon as an editable vector file.

## [1.12.0] - 2026-10-30
### Added
- Multi-select in the package list (Ctrl+click / Shift+click). **Install Selected** and
  **Upgrade Selected** now work through every selected package one after another, each in its
  own clearly marked section of the log, then print a summary showing which succeeded and the
  exit code of any that didn't.
- The two "Selected" buttons show how many packages are selected, e.g. "Install Selected (3)".

### Fixed
- **Upgrade All** now passes `--include-unknown` when "Include unknown versions" is ticked, so it
  upgrades the same packages the list shows instead of silently skipping ones whose installed
  version winget can't detect.
- **Upgrade Selected** now honours the "Skip Microsoft Store (msstore) source" checkbox, like
  Install and Upgrade All already did.
- Closing the window with the X now gets the same "operation still running" check as the Exit
  button, and stops the timers and cleans up temp files, instead of leaving winget running with
  no window.
- winget's output is now read as UTF-8. Windows PowerShell 5.1 otherwise reads it as ANSI,
  garbling winget's truncation character and non-ASCII package names, which could also throw
  the column parsing off.
- The automatic list refresh after an install, upgrade or source reset no longer wipes the log,
  so the operation's own output and any desktop-icon cleanup messages stay visible.
- **Upgrade Selected** is disabled while search results are shown (they may not be installed),
  and **Install Selected** is disabled while the list of updates is shown.

### Changed
- Removed the separate elevated-retry path when deleting a desktop shortcut, since the app
  always runs elevated now and the retry could never help.
- About box updated to describe multi-select.

## [1.11.0] - 2026-10-09
### Added
- The script now hides its own PowerShell console window on launch (via a `GetConsoleWindow`/
  `ShowWindow` Win32 call), so only the GUI is visible when running `WinGet-GUI.ps1` directly —
  double-clicked, run from a shortcut, or launched from an existing terminal. The compiled
  `.exe` already had no console via ps2exe's `-noConsole` switch, so this is a no-op there.
  The self-relaunches used for elevation and for switching into STA mode now also launch with
  `-WindowStyle Hidden`, so no console window flashes up even briefly during those relaunches.
- `Build-Exe.ps1`: a build script that automates the ps2exe steps in the README (execution
  policy workaround, installing the `ps2exe` module if needed, then compiling the exe with the
  icon and `-STA -requireAdmin -noConsole` switches). Reads the version number straight out of
  `$script:AppVersion`, so the exe's version metadata can't drift out of sync with the script it
  was built from, and names the output `WinGet-GUI v<version>.exe` (e.g. `WinGet-GUI v1.11.0.exe`)
  rather than a plain `WinGet-GUI.exe`, so multiple builds don't overwrite one another.

## [1.10.0] - 2026-10-08
### Fixed
- Automatic desktop-icon removal could occasionally catch icons that had nothing to do with
  the install/upgrade that triggered it — including one you'd already had pinned on the
  Desktop — if it happened to appear as "new" during the before/after check or the 20-second
  grace period. Removal is now also filtered by name: a new shortcut only gets deleted if its
  filename plausibly matches the package(s) that were actually just installed/upgraded
  (`Test-ShortcutRelatesToPackage`), and anything else that showed up as new is left alone and
  logged instead of removed.

## [1.9.2] - 2026-09-23
### Added
- `WinGet-GUI.ico`: a multi-resolution app icon, and a `-iconFile` example in the ps2exe build
  command so the compiled `.exe` gets its own icon instead of the generic PowerShell one.

## [1.9.1] - 2026-09-23
### Added
- Support for compiling the script into a standalone `.exe` via the [ps2exe](https://github.com/MScholtes/PS2EXE)
  module. The script now detects whether its host process is a compiled `.exe` rather than
  `powershell.exe`/`pwsh.exe` and, if so, skips its own manual STA/elevation relaunch logic
  (which assumes it's being hosted by the PowerShell console and would misfire under a
  compiled exe), relying instead on ps2exe's own `-STA`/`-requireAdmin` build switches. See
  README.md for the exact build command.

## [1.9.0] - 2026-09-23
### Added
- The script now checks whether it's running as Administrator on launch and, if not,
  relaunches itself elevated (a single UAC prompt) automatically, since installing/upgrading
  software and managing the shared Public Desktop both normally require it. Avoids hitting
  "Access is denied" errors partway through instead of asking for elevation up front. If
  elevation is cancelled or the account can't elevate, a message box explains why and the
  app exits.
- About dialog text updated to mention that it runs elevated automatically.

## [1.8.1] - 2026-09-23
### Fixed
- Removing a new desktop icon from the shared Public Desktop could fail with "Access to the
  path ... is denied" — some installers (Adobe Acrobat is one) self-elevate via their own UAC
  prompt to write there even when this script itself isn't running elevated, so the script's own
  (non-elevated) delete gets blocked. Deletion now retries via a one-off elevated process
  (a single UAC prompt) when it hits an access-denied error on that specific file.

## [1.8.0] - 2026-09-23
### Added
- **Search** box + **Search** button: runs `winget search "<query>"` and lists the results in the
  same grid used for outdated packages.
- **Install Selected** button: installs whatever's selected in the grid (a search result, or any
  other row) via `winget install --id <id> -e`, with the same confirmation prompt, live log
  output, and automatic desktop-icon cleanup as the existing upgrade actions.
- Pressing Enter in the search box now runs the search too.
- About dialog text updated to mention searching for and installing new software.

### Changed
- The table parser (`ConvertFrom-WingetUpgradeTable`) now detects which columns are actually
  present in a given winget table instead of assuming a fixed set, since `winget search` doesn't
  always print the same columns as `winget upgrade` (it can add an extra "Match" column, and never
  has "Available"). Upgrade parsing is unaffected.

## [1.7.2] - 2026-09-23
### Fixed
- Desktop icon removal could miss shortcuts created by installers/updaters that drop
  their icon via a background process after winget itself has already exited (Chrome,
  Edge, Zoom, and similar are notorious for this). The removal check now keeps polling
  for 20 seconds after the upgrade finishes instead of checking only once.

## [1.7.1] - 2026-09-18
### Added
- The About dialog now shows the app's own version number (alongside the detected winget CLI
  version), sourced from a new `$script:AppVersion` variable at the top of the script.

## [1.7.0] - 2026-09-18
### Added
- "Remove new desktop icons after install/upgrade" checkbox (on by default). Before **Upgrade All**
  or **Upgrade Selected** runs, the script snapshots every `.lnk`/`.url` shortcut on the current
  user's Desktop and the shared Public Desktop; once the upgrade finishes, any shortcuts that
  weren't there before are deleted automatically, so installers/updaters that drop a desktop icon
  don't leave one behind.

## [1.6.1] - 2026-09-18
### Fixed
- `DataGrid.ItemsSource` crashed with a `SetValueInvocationException` ("Cannot convert ... to
  System.Collections.IEnumerable") whenever `winget upgrade` found exactly one available update.
  PowerShell unwraps a single-item array into a bare object on return, so the parsed result list
  is now wrapped in `@(...)` before being assigned to `ItemsSource`, guaranteeing it stays an
  array whether there are 0, 1, or many rows.

## [1.6.0] - 2026-09-17
### Added
- About and Exit buttons, top-right of the toolbar.
- Exit prompts for confirmation and terminates a running winget process cleanly if one is in progress.

### Fixed
- Toolbar buttons/checkboxes no longer get clipped by the window edge — the row now wraps (`WrapPanel`) and the default window width was increased so everything fits on one line at the default size.

## [1.5.0] - 2026-09-17
### Added
- `--disable-interactivity` passed to every winget call, to avoid inconsistent behaviour caused by running winget with redirected (non-console) output.

## [1.4.0] - 2026-09-17
### Added
- **Diagnose Network** button: checks WinHTTP vs. WinINet proxy configuration and HTTPS reachability to winget's backend hosts, to help identify proxy/firewall causes of source-search failures.

## [1.3.0] - 2026-09-17
### Added
- **Reset Sources** button: runs `winget source reset --force` followed by `winget source update`, then refreshes the list.

## [1.2.0] - 2026-09-17
### Added
- "Skip Microsoft Store (msstore) source" checkbox (on by default), scoping all winget calls to `--source winget` to avoid the msstore source-agreement prompt.

### Fixed
- Live log output now tails both stdout and stderr as the process runs, rather than only showing stderr after the process exits.

## [1.1.0] - 2026-09-17
### Added
- "Include unknown versions" checkbox (`--include-unknown`).
- "Upgrade Selected" button for upgrading a single highlighted package.

## [1.0.0] - 2026-09-17
### Added
- Initial release: WPF GUI listing outdated packages via `winget upgrade`, with a "Check for Updates" button and an "Upgrade All" button (`winget upgrade --all`), live log output via a polled temp-file redirect, and self-relaunch into STA mode for PowerShell 7 compatibility.
