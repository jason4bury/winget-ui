# Changelog

All notable changes to this project are documented here.

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
