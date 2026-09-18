# Changelog

All notable changes to this project are documented here.

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
