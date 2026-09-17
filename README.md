# Winget GUI

A small PowerShell + WPF front end for [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/) (the Windows Package Manager). It gives you a checkable list of what's outdated and buttons to upgrade everything, upgrade one package at a time, and recover from the source/network issues winget occasionally runs into.

![Windows](https://img.shields.io/badge/platform-Windows-blue) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE)

## Features

- On launch, automatically runs `winget upgrade` and lists what's outdated in a sortable grid (Name, Id, Version, Available, Source).
- **Upgrade All** — runs `winget upgrade --all` with a confirmation prompt, streaming live output into a log pane.
- **Upgrade Selected** — upgrades just the highlighted package.
- **Reset Sources** — runs `winget source reset --force` followed by `winget source update`, for when package searches start failing.
- **Diagnose Network** — checks WinHTTP vs. WinINet proxy configuration and reachability to winget's backend hosts, for tracking down "failed to search source" errors caused by proxies or content filters.
- Checkbox to skip the Microsoft Store (`msstore`) source, which avoids a recurring source-agreement prompt on machines where it's never been accepted interactively.
- Checkbox to include packages with unknown/undetectable versions (`--include-unknown`).
- About and Exit buttons.

## Requirements

- Windows 10 or 11 with [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) (which provides `winget`) installed.
- PowerShell 5.1 (built into Windows) or PowerShell 7+. The script detects which one it's running under and relaunches itself in STA mode automatically if needed (WPF requires an STA thread, and PowerShell 7 defaults to MTA).

## Usage

Download `Winget-GUI.ps1` and run it either by double-clicking (if `.ps1` files are associated with PowerShell on your system) or from a terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\Winget-GUI.ps1
```

No installation, no dependencies beyond winget itself.

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
