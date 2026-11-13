# Windows Terminal profile

This folder is optional Windows packaging. It is not used by the editor at
runtime; it makes sure mibi opens **inside your configured terminal** (with
your profile, font, colours and icon) instead of a bare `conhost` window, and
sets the tab title so the chrome reads `mibi - notes.txt`.

| File | What it is |
| --- | --- |
| `mibi.json` | A Windows Terminal **fragment**: the `mibi` profile and its colour scheme. The icon path is inside the installed fragment folder. |
| `install.ps1` | Copies the fragment under `% LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\mibi`, fills in the built `mibi.exe` path and the font face, and copies the 128 px icon and `.ico`. Per-user, no admin. |
| `mibi.cmd` | A development launcher for a source checkout: runs `zig-out\bin\mibi.exe` through `wt.exe` when Windows Terminal is installed, otherwise directly. |

## Install the profile (per user, no admin)

```powershell
.\assets\windows-terminal\install.ps1
```

This copies `mibi.json` and the icons into
`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\mibi\`. Restart Windows
Terminal and "mibi" appears in the profile dropdown (and in the new-tab menu)
with its own colour scheme matching `mibi.ini`'s defaults.

If `mibi.exe` is not on your `PATH`, pass `-Exe` or edit `commandline` in
`mibi.json` to the full path of the executable.

The profile defaults to the `Maple Mono NF` face. If the file tree's Nerd Font
icons clip in Windows Terminal, install the mono-icon variant (NFo/NFMono) and
pass it to the installer: `install.ps1 -Font 'Maple Mono NFo'`.

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

The release archive includes this folder together with the `icons/` directory
next to it, so `install.ps1` can find the artwork.
