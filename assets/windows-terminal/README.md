# Windows Terminal profile

A terminal app cannot draw or remove the window chrome — the window belongs to
the terminal emulator. What mibi *can* do is make sure it opens **inside your
configured terminal** (with your profile, font, colours and icon) instead of a
bare `conhost` window, and set the tab title so the chrome reads
`mibi - notes.txt`.

## Install the profile (per user, no admin)

```powershell
.\assets\windows-terminal\install.ps1
```

This copies `mibi.json` and the icons into
`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\mibi\`. Restart Windows
Terminal and "mibi" appears in the profile dropdown (and in the new-tab menu)
with its own colour scheme matching `mibi.ini`'s defaults.

If `mibi.exe` is not on your `PATH`, edit `commandline` in `mibi.json` to the
full path of the executable.

## Launching

- **From a terminal you already have open**: just run `mibi <file>` — it runs in
  that window, with that profile.
- **From Explorer / a shortcut**: the binary hands itself off to Windows
  Terminal (`wt.exe`) with your default profile and exits, so no bare console
  window is left behind. Set `terminal = console` in `mibi.ini` to keep it in
  the console instead, or `terminal = wt` to always hand off.
- **Without changing the default**: `mibi.cmd` does the same hand-off
  explicitly and falls back to a plain console if Windows Terminal is missing.

## A chrome-less look

Windows Terminal can hide most of its own chrome, which is the closest a TUI
gets to "custom chrome":

- `F11` (or `"launchMode": "focus"`) — full screen, tabs hidden.
- `"showTabsInTitlebar": false` — keep tabs in the tab row, not the title bar.
- `"showTerminalTitleInTitlebar": false` — no title text in the chrome.
- `"tabWidthMode": "compact"` — narrower tabs.
- mibi draws its own tab bar (top row), status line and help panel, so the
  in-window chrome is already ours.
