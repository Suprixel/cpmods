# cpmods

A simple mod manager for Cyberpunk 2077 on Windows. Find mods on Nexus, click "Slow download", and cpmods installs them, keeps track of every file, and can undo everything.

## What it does

- **Installs from Nexus.** Browse and search Nexus inside the app, or queue a list of mods. Clicking "Slow download" on Nexus hands the file to cpmods, which checks it and installs it.
- **Never loses a game file.** Every file a mod replaces is backed up and put back when you remove the mod. When two mods ship the same file, you choose: use the new copy, keep the old one, or combine both (for JSON settings files). Removing either mod gives the other its own copy back.
- **Frameworks.** Installs and updates CET, RED4ext, redscript, ArchiveXL, TweakXL, Codeware, Mod Settings and Input Loader from their GitHub releases.
- **Safety nets.** Restore points of your whole mod setup, copies of your saves before a launch with changed mods, and backups of mod settings (CET mods, Mod Settings, hotkeys).
- **Play without mods.** One click sets every mod aside for a vanilla launch; they come back when the game closes.
- **When something breaks.** A launch report reads the RED4ext, CET and redscript logs and crash reports. Troubleshooting turns half of your mods off per launch until it finds the one causing the problem.
- **Load order and conflicts.** A compatibility check, archive load order (who wins a conflict), and a map of every key binding used by the game and your mods.
- **Share with friends.** One click makes a zip with the app and your mod list (optionally your mod settings).

## Install

1. Download `cpmods-*.zip` from [Releases](../../releases/latest).
2. Right-click the zip, "Extract All...", then double-click `Install.cmd` in the extracted folder.
3. Follow the window. It installs PowerShell 7 if needed, finds your game (Steam, GOG or Epic), and asks for your Nexus API key (a free account is enough: <https://next.nexusmods.com/settings/api-keys>).

Then open "Cyberpunk Mods" from the desktop or the Start menu. Running `Install.cmd` from a newer release updates cpmods and keeps your mods and settings.

From a clone of this repository: run `pwsh -File setup.ps1` (PowerShell 7.2 or newer).

## Requirements

- Windows 10 or 11
- PowerShell 7.2+ (the installer adds it)
- 7-Zip for `.7z` and `.rar` mods (`.zip` works without it)
- Microsoft Edge WebView2 Runtime for the app window (included in Windows 11; without it, cpmods opens in your browser)

## Your data

Everything stays on your PC, in `%LOCALAPPDATA%\cpmods`. The Nexus API key is stored encrypted for your Windows user. cpmods talks only to Nexus Mods and GitHub (for framework releases). The app window talks to a small local server on `localhost`, protected by a random token made at each start.

## Tests

The backend tests run in a throwaway copy of the app with a fake game folder and never touch a real install:

```
pwsh -NoProfile -File tests\core.ps1
pwsh -NoProfile -File tests\merge-json.ps1
```

## Notes

cpmods is a fan project, not affiliated with CD PROJEKT RED or Nexus Mods. Mods change game files: keep the restore points and save copies turned on.

`lib/webview2` contains the Microsoft WebView2 SDK libraries, redistributed under their license (`lib/webview2/LICENSE.txt`).
