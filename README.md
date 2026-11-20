# cpmods

A simple mod manager for Cyberpunk 2077 on Windows. Find mods on Nexus, click "Slow download", and cpmods installs them, keeps track of every file, and can undo everything.

## What it does

- **Installs from Nexus.** Browse and search Nexus inside the app, or queue a list of mods. Clicking "Slow download" on Nexus hands the file to cpmods, which checks it and installs it.
- **Updates in one go.** "Check for updates" looks at all your Nexus mods and frameworks at once. Update them all with one button, or untick the ones to skip; a restore point is made first.
- **Never loses a game file.** Every file a mod replaces is backed up and put back when you remove the mod. When two mods ship the same file, you choose: use the new copy, keep the old one, or combine both (for JSON settings files). Removing either mod gives the other its own copy back.
- **Frameworks.** Installs and updates CET, RED4ext, redscript, ArchiveXL, TweakXL, Codeware, Mod Settings and Input Loader from their GitHub releases.
- **Safety nets.** Restore points of your whole mod setup, copies of your saves before a launch with changed mods, and backups of mod settings (CET mods, Mod Settings, hotkeys).
- **Play without mods.** One click sets every mod aside (also ReShade and other DLL injectors) for a vanilla launch; they come back when the game closes, even if you closed cpmods meanwhile.
- **When something breaks.** The Reports page reads the RED4ext, CET and redscript logs and crash reports. Each problem says which other mod is involved and what you can do: update or turn off the mod, open its log, or hide a message you already know about. A message that also showed up in an earlier launch that closed normally is not flagged again. Troubleshooting turns half of your mods off per launch until it finds the one causing the problem.
- **Profiles.** Save which mods are on as a named profile (Story, Photo mode...) and switch between them with one click.
- **Disk space.** How much your mods and cpmods' own data take, the largest mods, and a cleanup of downloads no mod or restore point uses. After an update, a mod's two previous downloads stay so you can go back; older ones are deleted.
- **Mouse profile while playing.** For Logitech mice with onboard profiles (Onboard Memory Manager or G HUB): in Settings, Mouse, turn it on and pick a profile, for example one with a lower polling rate if 8000 Hz drops your fps. cpmods switches to it when the game starts, also from Steam, and puts the previous one back when the game closes. It only switches profiles and never writes to the mouse.
- **Settings search.** Type a word in the box at the top of Settings (or press /) to see only the settings about it.
- **Your look.** Yellow, red or your own color, on a matching, grey, black, OLED black, white or custom background.
- **Load order and conflicts.** A Compatibility page with every finding and its risk; when two mods change the same game assets you pick which one wins (either of them). The Library only warns about what can crash the game. Plus a map of every key binding used by the game and your mods.
- **Modpacks.** Turn the mods you have on into a short code of letters and digits (about 300 characters for 125 mods; a longer code that also lists each file's mod is there too) to paste in any chat. A friend pastes it, or the whole message, in Downloads, Modpacks: cpmods looks the mods up on Nexus, shows what changes, skips mods they already have, updates their older versions (or keeps them, their choice), makes a restore point and a mod settings backup, then queues the downloads. A mistyped or cut code is refused.
- **Share with friends.** One click makes a zip with the app and your mod list (optionally your mod settings).

## Install

1. Download `cpmods-*.zip` from [Releases](../../releases/latest).
2. Right-click the zip, "Extract All...", then double-click `Install.cmd` in the extracted folder.
3. Follow the window. It installs PowerShell 7 if needed, finds your game (Steam, GOG or Epic), and asks for your Nexus API key (a free account is enough: <https://next.nexusmods.com/settings/api-keys>).

Then open "Cyberpunk Mods" from the desktop or the Start menu. cpmods installs to `%LOCALAPPDATA%\Programs\cpmods` (no admin needed), starts from `cpmods.exe`, and shows in Windows Settings, Apps, where Uninstall removes the app but leaves your mods and data.

**Updates.** When a new release is out, cpmods says so (banner and Settings, App) and updates with one click: it downloads the release from GitHub, checks its SHA-256, then closes and opens again. Your mods and settings stay. Copies installed before 1.10 need `Install.cmd` from a newer release once; it moves them to the new layout and keeps everything.

From a clone of this repository: run `pwsh -File setup.ps1` (PowerShell 7.2 or newer). A git copy keeps its data beside the code and never updates itself.

## Requirements

- Windows 10 or 11
- PowerShell 7.2+ (the installer adds it)
- 7-Zip for `.7z` and `.rar` mods (`.zip` works without it)
- Microsoft Edge WebView2 Runtime for the app window (included in Windows 11; without it, cpmods opens in your browser)

## Your data

Everything stays on your PC, in `%LOCALAPPDATA%\cpmods`. The Nexus API key is stored encrypted for your Windows user. cpmods talks only to Nexus Mods and GitHub (for framework releases and its own updates). The app window talks to a small local server on `localhost`, protected by a random token made at each start.

## Tests

The backend tests run in a throwaway copy of the app with a fake game folder and never touch a real install:

```
pwsh -NoProfile -File tests\core.ps1
pwsh -NoProfile -File tests\merge-json.ps1
```

`tests\core.ps1` also starts a throwaway server and checks that it refuses requests without its token, from another host name or from another web page.

The UI tests (`tests\ui`) copy the app into `%TEMP%\cpmods-uisb` with a fake game folder, open a hidden app window (Microsoft Edge WebView2) and drive it. They never start the game or open Nexus pages, and only read a connected Logitech mouse (no profile switch):

```
Get-ChildItem tests\ui\*.ps1 -Exclude cdp.ps1, sandbox.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName }
```

## Notes

cpmods is a fan project, not affiliated with CD PROJEKT RED or Nexus Mods. Mods change game files: keep the restore points and save copies turned on.

`lib/webview2` contains the Microsoft WebView2 SDK libraries, redistributed under their license (`lib/webview2/LICENSE.txt`).
