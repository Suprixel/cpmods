cpmods - simple Cyberpunk 2077 mod manager

Setup (about 5 minutes)
1. Update Cyberpunk in Steam/GOG/Epic and close the game.
2. Right-click this zip, choose "Extract All...", then open the new folder.
   (If you run Install.cmd straight from the zip, it tries to unpack itself.)
3. Double-click Install.cmd. If Windows says "Windows protected your PC",
   click "More info", then "Run anyway".
   - Installs PowerShell 7 if it is missing (Windows asks for permission).
   - Finds your game (Steam, GOG or Epic) or asks for the folder.
   - Asks for your Nexus "Personal API Key" (a free account is enough):
     https://next.nexusmods.com/settings/api-keys
     You can skip it and add it later in cpmods: Settings, Nexus.
   - Offers to install the frameworks (CET, RED4ext, redscript, ArchiveXL,
     TweakXL, Codeware, Mod Settings, Input Loader) and queues the mods
     from modlist.json if the zip has one.
4. cpmods opens. Find a mod in Discover, click it, click Download, then
   "Slow download" on the Nexus page; cpmods installs it by itself.
   Your browser asks once how to open the link: allow it and tick "always".

Already have mods? They are left untouched. In cpmods, Library, the "..."
menu, "Find existing mods" lists them and lets cpmods manage them.
Any game file cpmods overwrites is backed up and restored when you remove
that mod in cpmods.

Later: open "Cyberpunk Mods" from the desktop or the Start menu.
When a new version is out, cpmods says so and updates itself with one click
(your mods and settings stay). It installs to %LOCALAPPDATA%\Programs\cpmods,
keeps your data in %LOCALAPPDATA%\cpmods, and can be removed in Windows
Settings, Apps (your mods stay in the game).

Something went wrong? The window says what to do. Everything is written to
  %LOCALAPPDATA%\cpmods-setup.log
Send that file to whoever gave you cpmods.
