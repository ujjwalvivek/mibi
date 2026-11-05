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

- **From a terminal you already have open**: run `mibi <file>` — it uses that
  window, with that profile, and sets the tab title.
- **Double-clicking** the executable shows a message ("mibi is a terminal text
  editor") and exits, instead of leaving you in a bare console. Start it from a
  terminal, or use `mibi.cmd`.
- **From the profile menu**: after `install.ps1`, "mibi" appears in Windows
  Terminal's profile dropdown with its own icon and colours.

## SmartScreen

A local build is unsigned, so double-clicking `mibi.exe` from Explorer makes
Windows SmartScreen ask "Windows protected your PC" (publisher: Unknown).
Click **Run anyway** once, or avoid the check entirely:

- run `mibi` from a terminal (SmartScreen only inspects shell launches), or
- double-click `mibi.cmd` (it launches `wt.exe`, which starts mibi as a child
  process), or
- sign the binary with a code-signing certificate for distribution.

## A chrome-less look

Windows Terminal can hide most of its own chrome, which is the closest a TUI
gets to "custom chrome":

- `F11` (or `"launchMode": "focus"`) — full screen, tabs hidden.
- `"showTabsInTitlebar": false` — keep tabs in the tab row, not the title bar.
- `"showTerminalTitleInTitlebar": false` — no title text in the chrome.
- `"tabWidthMode": "compact"` — narrower tabs.
- mibi draws its own tab bar (top row), status line and help panel, so the
  in-window chrome is already ours.
