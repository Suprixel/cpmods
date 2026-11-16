# cpmods first-time setup on a new PC (Install.cmd -> bootstrap.ps1 -> this, in PowerShell 7)
# -Check: dry run into a temp folder (no shortcuts, links, frameworks or app start)
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dest = if ($Check) { Join-Path ([IO.Path]::GetTempPath()) ('cpmods-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) } else { Join-Path $env:LOCALAPPDATA 'cpmods' }
$log = if ($Check) { Join-Path ([IO.Path]::GetTempPath()) 'cpmods-check.log' } else { Join-Path $env:LOCALAPPDATA 'cpmods-setup.log' }
$steps = 7
function Say([string]$M, [string]$C = 'Gray') { Write-Host $M -ForegroundColor $C }
function Step([int]$N, [string]$M) { Write-Host "`n[$N/$steps] $M" -ForegroundColor Cyan }

function Find-Game {
    $found = [Collections.Generic.List[object]]::new()
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libs = @($steam -replace '/', '\')
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) { $libs += [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
        foreach ($l in $libs | Select-Object -Unique) {
            $g = Join-Path $l 'steamapps\common\Cyberpunk 2077'
            if (Test-Path -LiteralPath (Join-Path $g 'bin\x64\Cyberpunk2077.exe')) { $found.Add(@{ path = $g; manifest = (Join-Path $l 'steamapps\appmanifest_1091500.acf'); store = 'Steam' }) }
        }
    }
    foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue) {
        $p = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).path
        if ($p -and (Test-Path -LiteralPath (Join-Path $p 'bin\x64\Cyberpunk2077.exe'))) { $found.Add(@{ path = $p; manifest = ''; store = 'GOG' }) }
    }
    foreach ($f in Get-ChildItem 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests' -Filter *.item -ErrorAction SilentlyContinue) {
        try {
            $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            if ($j.InstallLocation -and (Test-Path -LiteralPath (Join-Path $j.InstallLocation 'bin\x64\Cyberpunk2077.exe'))) { $found.Add(@{ path = $j.InstallLocation; manifest = ''; store = 'Epic' }) }
        }
        catch { }
    }
    , $found
}

function Test-Writable([string]$Dir) {
    $t = Join-Path $Dir ('.cpmods-write-test-' + $PID)
    try { [IO.File]::WriteAllText($t, 'x'); Remove-Item -LiteralPath $t -Force; $true } catch { $false }
}

function Get-RunningServer([string]$Dir) {
    $f = Join-Path $Dir 'state\server.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null }
}

function Test-Server($I) {
    try { [void](Invoke-RestMethod "http://localhost:$($I.port)/api/ping" -Headers @{ 'X-Cp-Token' = "$($I.token)" } -TimeoutSec 2); $true } catch { $false }
}

# An open cpmods keeps running its old code: ask it to quit before files are replaced
function Stop-OldServer([string]$Dir) {
    $i = Get-RunningServer $Dir
    if (-not $i -or -not (Test-Server $i)) { return }
    Say 'Closing the cpmods that is open now, so it can be updated...'
    try { [void](Invoke-RestMethod -Method Post "http://localhost:$($i.port)/api/system" -Headers @{ 'X-Cp-Token' = "$($i.token)" } -ContentType 'application/json' -Body '{"op":"quit"}' -TimeoutSec 5) } catch { }
    for ($n = 0; $n -lt 30 -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue); $n++) { Start-Sleep -Milliseconds 500 }
    if (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue) { Stop-Process -Id ([int]$i.pid) -Force -ErrorAction SilentlyContinue }
}

try { Start-Transcript -LiteralPath $log -Append -Force | Out-Null } catch { }
$failed = $false
try {
    Say "cpmods setup$(if ($Check) { ' (check only: nothing on this PC is changed)' })" Cyan
    Say "PowerShell $($PSVersionTable.PSVersion), Windows $([Environment]::OSVersion.Version)" DarkGray

    Step 1 'Copying cpmods'
    if (-not $Check) { Stop-OldServer $dest }
    # drop the "downloaded from the internet" mark on the app files only (state\ may hold files the app window keeps open)
    Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(state|downloads|backup|tmp)\\' } | Unblock-File -ErrorAction SilentlyContinue
    if ($src -ne $dest) {
        [void](New-Item -ItemType Directory -Force -Path $dest)
        Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
    }
    Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(state|downloads|backup|tmp)\\' } | Unblock-File -ErrorAction SilentlyContinue
    Say "Installed to $dest" Green

    Step 2 'Finding Cyberpunk 2077'
    $games = Find-Game
    if ($games.Count) { $game = $games[0]; Say "Found it ($($game.store)): $($game.path)" Green }
    elseif ($Check) { throw 'Cyberpunk 2077 was not found (check mode does not ask for a folder)' }
    else {
        Say 'Cyberpunk 2077 was not found automatically.' Yellow
        do { $p = (Read-Host 'Paste the game folder (the one that contains the bin folder)').Trim('" ') }
        until ($p -and (Test-Path -LiteralPath (Join-Path $p 'bin\x64\Cyberpunk2077.exe')))
        $game = @{ path = $p; manifest = ''; store = 'manual' }
    }
    if (-not (Test-Writable $game.path)) {
        Say "cpmods cannot write to the game folder ($($game.path))." Yellow
        Say 'Mods cannot be installed there like this. Close this window, right-click Install.cmd and choose "Run as administrator", or move the game to a folder you own (for example D:\Games).' Yellow
        throw 'No write access to the game folder'
    }
    [IO.File]::WriteAllText((Join-Path $dest 'config.json'), (@{ gamePath = $game.path; steamManifest = $game.manifest; nexusGame = 'cyberpunk2077' } | ConvertTo-Json))
    Import-Module (Join-Path $dest 'lib\cpmods.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $dest 'lib\cpinsight.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $dest 'lib\cpserver.psm1') -Force -DisableNameChecking
    Set-CpContext 'setup' $false
    $g = Get-GameState
    Say "Game version $($g.version)" DarkGray
    if ($Check) { Say "`nCheck passed: the package copies, finds the game and loads." Green; return }

    Step 3 '7-Zip (for mods packed as .7z or .rar)'
    if (Get-7z) { Say 'Already installed.' Green }
    elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        if ((Read-Host 'Install 7-Zip now? [Y/n]') -notmatch '^[nN]') {
            & winget install --id 7zip.7zip -e --source winget --accept-source-agreements --accept-package-agreements
            if (Get-7z) { Say '7-Zip installed.' Green } else { Say 'It did not install; .zip mods still work. You can get 7-Zip later from https://www.7-zip.org/' Yellow }
        }
    }
    else { Say 'Not installed. .zip mods work without it; get it later from https://www.7-zip.org/ for .7z and .rar mods.' Yellow }

    Step 4 'Nexus account (downloads need your own free API key)'
    if (Test-NexusKey) { Say 'A key is already saved.' Green }
    else {
        Say 'Opening the Nexus page with your key. Log in, scroll to "Personal API Key", copy it, then paste it here.'
        Start-Process 'https://next.nexusmods.com/settings/api-keys'
        while ($true) {
            $sec = Read-Host 'Paste the key and press Enter (it stays hidden; just Enter to skip)' -AsSecureString
            $k = [Net.NetworkCredential]::new('', $sec).Password.Trim()
            if (-not $k) { Say 'Skipped. Add it later in cpmods: Settings, Nexus, API key.' Yellow; break }
            Say "Got $($k.Length) characters, checking with Nexus..." DarkGray
            try { $v = Set-NexusKey $k; Say "Key works (account $($v.name))." Green; break }
            catch { Say $_.Exception.Message Red; Say 'Copy the whole key (the copy button next to it on Nexus) and paste it again.' }
        }
    }

    Step 5 'Download links and shortcuts'
    $cur = "$((Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\nxm\shell\open\command' -ErrorAction SilentlyContinue).'(default)')"
    $takeOver = $true
    if ($cur -and $cur -notmatch 'cpmods') {
        Say "Nexus 'Mod manager download' links open another app now: $cur" Yellow
        $takeOver = (Read-Host 'Make them open cpmods instead? (repairing that app switches them back) [Y/n]') -notmatch '^[nN]'
    }
    if ($takeOver) { Register-NxmHandler; Say 'Nexus download links now open cpmods.' Green }
    else { Say 'Left as is. cpmods can still install archives you download yourself (Downloads page).' Yellow }
    New-CpShortcuts | ForEach-Object { Say "Shortcut: $_" Green }

    Step 6 'Mod frameworks (CET, RED4ext, redscript, ArchiveXL, TweakXL, Codeware...)'
    $ver = 0.0
    [void][double]::TryParse("$($g.version)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ver)
    $gameDir = (Get-CpPaths).game
    $existing = @('bin\x64\plugins\cyber_engine_tweaks.asi', 'red4ext\RED4ext.dll', 'engine\tools\scc.exe', 'red4ext\plugins\ArchiveXL') | Where-Object { Test-Path -LiteralPath (Join-Path $gameDir $_) }
    if ($g.running) { Say "The game is running, so frameworks were not installed. Close it, then use 'Update frameworks' in cpmods." Yellow }
    elseif ($ver -and $ver -lt 2.5) { Say "Your game is version $($g.version); the frameworks need 2.5 or newer. Update the game, then use 'Update frameworks' in cpmods." Yellow }
    else {
        $doFw = $true
        if ($existing) {
            Say 'Frameworks are already installed (CET/RED4ext/redscript/ArchiveXL).' Yellow
            Say 'Updating replaces them with the latest versions; your current files are backed up and come back if you remove them in cpmods.'
            $doFw = (Read-Host 'Update frameworks now? [y/N]') -match '^[yY]'
        }
        if ($doFw) {
            Say 'Installing from GitHub...'
            try { Use-Lock { Invoke-Sync } | ForEach-Object { Say "  $_" } }
            catch { Say "Framework install failed: $($_.Exception.Message). Retry later with 'Update frameworks' in cpmods." Yellow }
        }
        else { Say 'Left as they are.' Green }
    }
    $ml = Join-Path (Split-Path $src -Parent) 'modlist.json'
    if (Test-Path -LiteralPath $ml) {
        $list = [IO.File]::ReadAllText($ml) | ConvertFrom-Json -AsHashtable
        $r = Add-QueueItems $list.mods 'From shared mod list'
        Say "Queued $($r.added) mods from the shared list ($($r.skipped) already installed)." Green
    }

    Step 7 'Starting cpmods'
    Start-CpServer -Open
    $ok = $false
    for ($n = 0; $n -lt 40 -and -not $ok; $n++) {
        Start-Sleep -Milliseconds 500
        $i = Get-RunningServer $dest
        if ($i -and (Test-Server $i)) { $ok = $true }
    }
    if ($ok) {
        Say 'cpmods is open. Find mods in Discover, click Download, then "Slow download" on the Nexus page: cpmods installs it.' Green
        Say 'Already have mods? Library, then "Find existing mods" lets cpmods manage them too (nothing changes until you choose).'
        Say 'Next time, open "Cyberpunk Mods" from the desktop or the Start menu.'
    }
    else {
        $failed = $true
        Say 'cpmods was installed but did not start.' Red
        $lf = Join-Path $dest 'cpmods.log'
        if (Test-Path -LiteralPath $lf) { Say 'Last lines of its log:'; Get-Content -LiteralPath $lf -Tail 8 | ForEach-Object { Say "  $_" DarkGray } }
        Say 'Try the "Cyberpunk Mods" shortcut on the desktop. If nothing opens, send the setup log below to whoever gave you cpmods.'
    }
}
catch {
    $failed = $true
    Say "`nSetup stopped: $($_.Exception.Message)" Red
    Say 'Nothing is broken. Fix the problem above and run Install.cmd again; finished steps are skipped or repeated safely.'
}
finally {
    Say "Setup log: $log" DarkGray
    try { Stop-Transcript | Out-Null } catch { }
    if ($Check) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($failed) { exit 1 }
