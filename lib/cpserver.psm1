# cpmods HTTP API: request routing, background jobs, Nexus GraphQL proxy
$ErrorActionPreference = 'Stop'
$script:UiDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui'
$script:Mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml' }

# Job bodies run in their own runspace: param($Job, $P, $Shared)
$script:JobScripts = @{
    nxm         = @'
param($Job, $P, $Shared)
$intent = $Shared.intents["$($P.fileId)"]
$cb = { param($l) if (Set-QueueItemDone $l.modId $l.fileId) { if ((Get-CpSettings).autoNext) { $n = Open-NextQueue; if ($n) { $Job.next = $n.name } } } }.GetNewClosure()
$res = Invoke-NxmDownload -Url $P.url -Job $Job -IntentName $(if ($intent) { $intent.name } else { $null }) -OnLinkReady $cb
$Job.phase = 'installing'
Save-AutoSafety "Before installing $($res.meta.name)"
$r = Complete-NexusDownload $res.archive $res.meta
"$($res.meta.name): $r"
'@
    install     = @'
param($Job, $P, $Shared)
$a = Resolve-DownloadFile $P.archive
Use-Lock {
    $meta = Get-DeferredMeta $a
    if (-not $meta) { $meta = [ordered]@{ name = [IO.Path]::GetFileNameWithoutExtension($a); version = ''; source = 'manual' } }
    if ($P.name) { $meta.name = "$($P.name)" }
    if ($P.sub) { $meta.sub = "$($P.sub)" }
    $Job.title = "Install $($meta.name)"
    Save-AutoSafety "Before installing $($meta.name)"
    try { $r = Install-ModArchive -Archive $a -Meta $meta -Ask:(Test-AskOverwrite) -OnConflict "$($P.conflict)" }
    catch { Add-Deferred 'failed' $a $meta $_.Exception.Message; throw }
    if ($r.conflict) { Add-Deferred 'pending' $a $meta '' $r.conflict; return "$($meta.name): waiting for your choice (another mod has some of the same files)" }
    "Installed $($meta.name)"
}
'@
    remove      = @'
param($Job, $P, $Shared)
Save-AutoSafety "Before removing $($P.name)"
Use-Lock { Remove-InstalledMod -Name $P.name -Purge:([bool]$P.purge) }
"Removed $($P.name)"
'@
    disable     = @'
param($Job, $P, $Shared)
Save-AutoSafety "Before turning off $($P.name)"
Use-Lock { Disable-InstalledMod -Name $P.name }
"Disabled $($P.name)"
'@
    enable      = @'
param($Job, $P, $Shared)
Save-AutoSafety "Before turning on $($P.name)"
Use-Lock {
    $r = Enable-InstalledMod -Name $P.name -Ask:(Test-AskOverwrite)
    if (-not $r.conflict) { return "Enabled $($P.name)" }
    # another mod has some of its files now: waits for your choice, like an install
    $d = (Get-State).disabled | Where-Object { $_.name -eq $P.name } | Select-Object -First 1
    Add-Deferred 'pending' $d.archive (Copy-Meta $d) '' $r.conflict
    "$($P.name): waiting for your choice (another mod has some of the same files)"
}
'@
    adopt       = @'
param($Job, $P, $Shared)
Save-AutoSafety 'Before adopting existing mods'
$r = @(Use-Lock { Add-AdoptedMods $P.items })
"Now tracking $($r.Count) mod(s)"
'@
    restore     = @'
param($Job, $P, $Shared)
Use-Lock { Invoke-RestorePoint "$($P.id)" $Job }
'@
    saves       = @'
param($Job, $P, $Shared)
if ("$($P.op)" -eq 'restore') { return (Restore-Saves "$($P.id)" @($P.names | Where-Object { $_ })) }
$r = if ("$($P.op)" -eq 'auto') { Invoke-AutoSaveBackup 'The game started with changed mods' } else { Backup-Saves 'Made by you' }
if ($r) { "Copied $(@($r.saves).Count) saves" } else { 'No saves needed copying' }
'@
    vanilla     = @'
param($Job, $P, $Shared)
if ("$($P.op)" -ne 'start') { return (Use-Lock { Restore-VanillaSession }) }
$r = Use-Lock { Start-VanillaSession }
try { Invoke-GameLaunch "$($P.mode)" }
catch { $e = $_.Exception.Message; Use-Lock { [void](Restore-VanillaSession) }; throw "The game did not start, so your mods were put back. $e" }
"$r. Starting the game without mods; they come back when it closes."
'@
    frameworks  = @'
param($Job, $P, $Shared)
Save-AutoSafety 'Before updating frameworks'
$r = Use-Lock { Invoke-Frameworks -Names @($P.names | Where-Object { $_ }) }
$Shared.cache.Remove('fwupdates')
(@($r) | Where-Object { "$_" -notmatch 'up to date' }) -join '; '
'@
    sync        = @'
param($Job, $P, $Shared)
Save-AutoSafety 'Before installing waiting mods'
$r = Use-Lock { Invoke-Sync }
$Shared.cache.Remove('fwupdates')
(@($r) | Where-Object { "$_" -notmatch 'up to date' }) -join '; '
'@
    bisect      = @'
param($Job, $P, $Shared)
$Shared.cache.Remove('launch')
switch ("$($P.op)") {
    'start' { Save-AutoSafety 'Before troubleshooting'; Use-Lock { Start-Bisect -Names @($P.names) -Job $Job } }
    'result' { Use-Lock { Submit-BisectResult -Ok ([bool]$P.ok) -Job $Job } }
    'stop' { Use-Lock { Stop-Bisect -KeepCulprit ([bool]$P.keep) -Job $Job } }
    default { throw "Unknown troubleshooting step $($P.op)" }
}
'@
    cleanup     = @'
param($Job, $P, $Shared)
Use-Lock { Invoke-StorageCleanup ([bool]$P.old) }
'@
    profile     = @'
param($Job, $P, $Shared)
Use-Lock { Invoke-Profile "$($P.name)" $Job }
'@
    pack        = @'
param($Job, $P, $Shared)
try { Use-Lock { Invoke-ModPack $P.pack @($P.use) $Job -Start } }
finally { $Shared.cache.Remove('fwupdates') }
'@
    # the new version swaps in once this server has quit, then opens again
    update      = @'
param($Job, $P, $Shared)
$r = Start-CpUpdate $Job
$Shared.stop = $true
$r
'@
}

function Send-Bytes($Ctx, [byte[]]$Bytes, [string]$Type, [int]$Code = 200) {
    $r = $Ctx.Response
    $r.StatusCode = $Code
    $r.ContentType = $Type
    $r.Headers['Cache-Control'] = 'no-store'
    $r.Headers['X-Content-Type-Options'] = 'nosniff'
    $r.ContentLength64 = $Bytes.Length
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $r.OutputStream.Close()
}

function Send-Json($Ctx, $Obj, [int]$Code = 200) {
    $json = if ($Obj -is [string]) { $Obj } else { ConvertTo-Json -InputObject $Obj -Depth 12 -Compress }
    Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $Code
}

function Send-Static($Ctx, [string]$Path, $Shared) {
    $name = if ($Path -eq '/' -or $Path -eq '/index.html') { 'index.html' } else { $Path.TrimStart('/') }
    if ($name -notmatch '^[\w\-]+\.(html|js|css|svg)$') { Send-Json $Ctx @{ error = 'not found' } 404; return }
    $file = Join-Path $script:UiDir $name
    if (-not (Test-Path -LiteralPath $file)) { Send-Json $Ctx @{ error = 'not found' } 404; return }
    $ext = [IO.Path]::GetExtension($file)
    if ($ext -eq '.html') {
        $txt = [IO.File]::ReadAllText($file).Replace('__CP_TOKEN__', $Shared.token).Replace('__CP_PREFS__', (Get-UiPrefsJson))
        Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes($txt)) $script:Mime[$ext]
    }
    else { Send-Bytes $Ctx ([IO.File]::ReadAllBytes($file)) $script:Mime[$ext] }
}

function Send-Gql($Ctx, [string]$Raw, $Shared) {
    $key = 'gql-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Raw)))
    $c = $Shared.cache[$key]
    if ($c -and ([datetime]::UtcNow - $c.t).TotalSeconds -lt 300) { Send-Json $Ctx $c.v; return }
    $resp = Invoke-WebRequest -Method Post -Uri 'https://api.nexusmods.com/v2/graphql' -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Raw)) -Headers @{ 'User-Agent' = 'cpmods/2.0' } -TimeoutSec 45 -SkipHttpErrorCheck
    $txt = if ($resp.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    if ([int]$resp.StatusCode -eq 200 -and $txt -notmatch '"errors"\s*:') {
        # answers count for 5 min: older ones go now, so browsing Discover never piles them up (the cap bounds the rest)
        foreach ($k in @($Shared.cache.Clone().Keys)) { $e = $Shared.cache[$k]; if ("$k".StartsWith('gql-') -and $e -and ([datetime]::UtcNow - $e.t).TotalSeconds -ge 300) { $Shared.cache.Remove($k) } }
        if ($Shared.cache.Count -gt 400) { $Shared.cache.Clear() }
        $Shared.cache[$key] = @{ t = [datetime]::UtcNow; v = $txt }
    }
    Send-Json $Ctx $txt
}

function Get-Cached($Shared, [string]$Key, [int]$Seconds, [scriptblock]$Make) {
    $c = $Shared.cache[$Key]
    if ($c -and ([datetime]::UtcNow - $c.t).TotalSeconds -lt $Seconds) { return $c.v }
    $v = & $Make
    $Shared.cache[$Key] = @{ t = [datetime]::UtcNow; v = $v }
    $v
}

# UI preferences (theme, filters, performance) live in state\ui.json, written by the page
function Get-UiPrefsFile { Join-Path (Get-CpPaths).state 'ui.json' }
function Get-UiPrefs { $f = Get-UiPrefsFile; if (Test-Path -LiteralPath $f) { try { $p = Read-JsonFile $f; if ($p -is [hashtable]) { return $p } } catch { } }; @{} }
function Get-UiPerf { $p = (Get-UiPrefs).perf; if ($p -is [hashtable]) { $p } else { @{} } }
# raw file text for the page's inline script; 'null' when missing or broken
function Get-UiPrefsJson {
    $f = Get-UiPrefsFile
    if (-not (Test-Path -LiteralPath $f)) { return 'null' }
    try { $t = [IO.File]::ReadAllText($f); if ((ConvertFrom-Json $t -AsHashtable) -is [hashtable]) { return $t.Replace('<', '\u003c') } } catch { }
    'null'
}
function Save-UiPrefs([string]$Raw) {
    if ($Raw.Length -gt 65536 -or -not ((ConvertFrom-Json $Raw -AsHashtable) -is [hashtable])) { throw 'Invalid preferences' }
    $f = Get-UiPrefsFile
    $tmp = '{0}.{1}.{2}.tmp' -f $f, $PID, [Threading.Thread]::CurrentThread.ManagedThreadId
    [IO.File]::WriteAllText($tmp, $Raw, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $f, $true)
}

# Shows the app window: the built-in one (server thread) or a browser window when that is off or failed.
# -IfClosed: leave an open window alone (download links must not steal focus).
function Request-CpWindow($Shared, [switch]$IfClosed) {
    if ($IfClosed -and $Shared.winOpen) { return }
    if (-not $Shared.winFail -and "$((Get-UiPerf).window)" -ne 'browser') { $Shared.winShow = $true; [void]$Shared.winEvt.Set(); return }
    if ($IfClosed) {
        # a browser tab counts as open until it says goodbye; hidden ones poll about once a minute
        $ui = $Shared.lastUi
        if ($ui -and -not ($Shared.byeAt -and $Shared.byeAt -ge $ui) -and ([datetime]::UtcNow - $ui).TotalSeconds -le 150) { return }
    }
    Open-CpWindow $Shared.port -Browser
}

# Everything Get-UiState reads; while unchanged, polls reuse the last JSON (~1 ms instead of ~60 ms)
function Get-UiStateKey($Shared) {
    $p = Get-CpPaths
    $sb = [Text.StringBuilder]::new()
    $man = Get-Cached $Shared 'manifest' 3600 { "$(([IO.File]::ReadAllText((Join-Path $p.root 'config.json')) | ConvertFrom-Json).steamManifest)" }
    foreach ($f in (Join-Path $p.state 'mods.json'), (Join-Path $p.state 'settings.json'), (Join-Path $p.state 'bisect.json'), (Join-Path $p.state 'vanilla.json'), (Join-Path $p.state 'nexus.key'), (Join-Path $p.state 'profiles.json'), (Join-Path $p.root 'queue.json'), (Join-Path $p.app 'frameworks.json'), $p.downloads, (Join-Path $p.game 'bin\x64\Cyberpunk2077.exe'), $man) {
        if ($f) { [void]$sb.Append([IO.File]::GetLastWriteTimeUtc($f).Ticks).Append('|') }
    }
    foreach ($j in @($Shared.jobs.Clone().Values)) { [void]$sb.Append("$($j.id):$($j.status):$($j.phase):$($j.done):$($j.total):$($j.detail):$($j.error):$($j.next)|") }
    [void]$sb.Append((@(Get-GameProcesses | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ',')).Append('|')
    $b = try { Get-BriefCached $Shared } catch { $null }
    [void]$sb.Append((ConvertTo-Json -InputObject $b -Compress -Depth 4)).Append('|')
    [void]$sb.Append((Get-Cached $Shared 'handler' 30 { Test-NxmHandler }))
    $sb.ToString()
}

# Memory of the server and the built-in window (all its WebView2 processes), for Settings > Performance
function Get-CpPerf($Shared) {
    $me = [Diagnostics.Process]::GetCurrentProcess()
    $win = $null
    if ($Shared.winOpen -and $Shared.winPid) {
        $Shared.winProcReq = $true
        for ($i = 0; $i -lt 25 -and $Shared.winProcReq; $i++) { Start-Sleep -Milliseconds 100 }
        $priv = 0L; $ws = 0L; $n = 0
        foreach ($id in @($Shared.winPids)) {
            try { $p = [Diagnostics.Process]::GetProcessById([int]$id); $priv += $p.PrivateMemorySize64; $ws += $p.WorkingSet64; $n++; $p.Dispose() } catch { }
        }
        if ($n) { $win = [ordered]@{ private = $priv; ws = $ws; procs = $n; ram = 0L } }
    }
    # "Memory" as Task Manager shows it (private working set); one WMI query, only when Settings asks
    $ram = @{}
    try {
        $flt = (@($PID) + @(if ($win) { $Shared.winPids }) | ForEach-Object { "IDProcess=$([int]$_)" }) -join ' OR '
        foreach ($c in Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter $flt) { $ram[[int]$c.IDProcess] = [long]$c.WorkingSetPrivate }
    }
    catch { }
    if ($win) { foreach ($id in @($Shared.winPids)) { $win.ram += [long]$ram[[int]$id] } }
    [ordered]@{
        server = [ordered]@{ private = $me.PrivateMemorySize64; ws = $me.WorkingSet64; ram = [long]$ram[$PID]; cpu = [math]::Round($me.TotalProcessorTime.TotalSeconds, 1) }
        window = $win; builtIn = [bool]$Shared.winOpen; winFail = $Shared.winFail; lean = [bool]$Shared.lean
    }
}

function Start-CpJob($Shared, [string]$Kind, [string]$Title, [hashtable]$Params) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $job = [hashtable]::Synchronized(@{
            id = $id; kind = $Kind; title = $Title; status = 'running'; phase = ''; total = $null; done = $null
            detail = ''; error = $null; next = $null; started = [datetime]::UtcNow.ToString('o'); finished = $null
        })
    $Shared.jobs[$id] = $job
    $rs = [runspacefactory]::CreateRunspace($Shared.iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($Script, $Job, $P, $Shared)
            Set-CpContext $Job.kind $true
            try {
                $out = & ([scriptblock]::Create($Script)) $Job $P $Shared
                $txt = (@($out) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }) -join '; '
                if ($txt) { $Job.detail = $txt }
                $Job.status = 'done'
            }
            catch {
                $Job.status = 'error'
                $Job.error = $_.Exception.Message
                Write-Note "$($Job.title): $($_.Exception.Message)"
            }
            finally { $Job.finished = [datetime]::UtcNow.ToString('o') }
        }.ToString()).AddArgument($script:JobScripts[$Kind]).AddArgument($job).AddArgument($Params).AddArgument($Shared)
    [void]$Shared.workers.Add([pscustomobject]@{ ps = $ps; rs = $rs; h = $ps.BeginInvoke() })
    $job
}

# kinds and size on disk per enabled mod, recomputed only when mods.json changes
function Get-ModInfoCache($Shared, $S) {
    $sf = Join-Path (Get-CpPaths).state 'mods.json'
    $mt = if (Test-Path -LiteralPath $sf) { (Get-Item -LiteralPath $sf).LastWriteTimeUtc.Ticks } else { 0 }
    $c = $Shared.cache['modinfo']
    if ($c -and $c.t -eq $mt) { return $c.v }
    $g = (Get-CpPaths).game
    $v = @{}
    foreach ($m in $S.mods) {
        $sum = [long]0
        foreach ($f in @($m.files)) { $fi = [IO.FileInfo]::new((Join-Path $g $f)); if ($fi.Exists) { $sum += $fi.Length } }
        $v[$m.name] = @{ kinds = @(Get-ModKinds $m.files); size = $sum }
    }
    $Shared.cache['modinfo'] = @{ t = $mt; v = $v }
    $v
}

# Launch summary (~15 ms): rebuilt when the RED4ext log folder, the crash folder or the game process change
function Get-BriefCached($Shared) {
    $g = (Get-CpPaths).game
    $ps = [Diagnostics.Process]::GetProcessesByName('Cyberpunk2077'); $run = $ps.Length -gt 0; foreach ($x in $ps) { $x.Dispose() }
    $k = '{0}|{1}|{2}' -f [IO.File]::GetLastWriteTimeUtc((Join-Path $g 'red4ext\logs')).Ticks, [IO.File]::GetLastWriteTimeUtc((Join-Path $env:LOCALAPPDATA 'REDEngine\ReportQueue')).Ticks, $run
    $c = $Shared.cache['brief']
    if ($c -and $c.k -eq $k) { return $c.v }
    $v = Get-LaunchBrief
    $Shared.cache['brief'] = @{ k = $k; t = [datetime]::UtcNow; v = $v }
    # saved by Get-UiState (a worker): this also runs on the main loop, which must never wait for the install lock
    if ($v.result -eq 'clean') { $Shared.cleanDue = $v }
    $v
}

# Full launch report, rebuilt when a new launch, crash or mod change shows up
function Get-LaunchCached($Shared, [switch]$Fresh) {
    $brief = Get-BriefCached $Shared
    $sf = Join-Path (Get-CpPaths).state 'mods.json'
    $mt = if (Test-Path -LiteralPath $sf) { (Get-Item -LiteralPath $sf).LastWriteTimeUtc.Ticks } else { 0 }
    $key = "$($brief.log)|$($brief.end)|$($brief.lastCrash)|$($brief.running)|$mt"
    $c = $Shared.cache['launch']
    if (-not $Fresh -and $c -and $c.k -eq $key -and ([datetime]::UtcNow - $c.t).TotalSeconds -lt 300) { return $c.v }
    $v = Get-LaunchReport
    $Shared.cache['launch'] = @{ k = $key; t = [datetime]::UtcNow; v = $v }
    $v
}

function Get-UiState($Shared) {
    $s = Get-State
    $mi = Get-ModInfoCache $Shared $s
    $mods = foreach ($m in $s.mods) {
        $x = $mi[$m.name]
        [ordered]@{
            name = $m.name; version = $m.version; source = $m.source; modId = $m.modId; fileId = $m.fileId; fileName = $m.fileName
            installed = $m.installed; fileCount = @($m.files).Count; archive = $(if ($m.archive) { [IO.Path]::GetFileName($m.archive) }); sub = $m.sub; broken = $m.broken
            kinds = @(if ($x) { $x.kinds }); size = $(if ($x) { $x.size } else { $null }); adopted = [bool]$m.adopted
        }
    }
    $disabled = foreach ($d in $s.disabled) {
        [ordered]@{ name = $d.name; version = $d.version; source = $d.source; modId = $d.modId; fileId = $d.fileId; fileName = $d.fileName; disabledAt = $d.disabledAt; archive = [IO.Path]::GetFileName("$($d.archive)")
            kinds = @(if ($d.files) { Get-ModKinds $d.files }); fileCount = $(if ($d.files) { @($d.files).Count } else { $null }); adopted = [bool]$d.adopted
        }
    }
    $pending = foreach ($p in $s.pending) {
        [ordered]@{ name = $p.meta.name; archive = [IO.Path]::GetFileName("$($p.archive)"); at = $p.at; modId = $p.meta.modId
            conflict = @($p.conflict | Where-Object { $_ } | ForEach-Object { [ordered]@{ path = $_.path; owners = @($_.owners); merge = $_.merge } })
        }
    }
    $van = Get-VanillaState
    $launch = try { Get-BriefCached $Shared } catch { $null }
    $failed = foreach ($f in $s.failed) { [ordered]@{ name = $f.meta.name; archive = [IO.Path]::GetFileName("$($f.archive)"); error = $f.error; at = $f.at; modId = $f.meta.modId } }
    $jobs = foreach ($j in @($Shared.jobs.Clone().Values)) {
        [ordered]@{ id = $j.id; kind = $j.kind; title = $j.title; status = $j.status; phase = $j.phase; total = $j.total; done = $j.done; detail = $j.detail; error = $j.error; next = $j.next; started = $j.started; finished = $j.finished; modId = $j.modId; fileId = $j.fileId; cancel = [bool]$j.cancel }
    }
    # not while a job runs: it may hold the lock, and its changes must not count as known good (the job's end rebuilds the state)
    if ($Shared.cleanDue -and -not @($jobs | Where-Object { $_.status -eq 'running' }).Count) { $v = $Shared.cleanDue; $Shared.cleanDue = $null; try { Save-CleanRestorePoint $v } catch { } }
    [ordered]@{
        version    = Get-CpVersion
        game       = Get-GameState
        settings   = Get-CpSettings
        key        = Test-NexusKey
        handler    = Test-NxmHandler
        mods       = @($mods)
        disabled   = @($disabled)
        pending    = @($pending)
        failed     = @($failed)
        queue      = @(Get-Queue)
        jobs       = @($jobs)
        downloads  = @(Get-DownloadsInfo $s)
        frameworks = @(Get-Frameworks | ForEach-Object { [ordered]@{ name = $_.name; nexusId = $_.nexusId; repo = $_.repo } })
        browsers   = @(Get-Cached $Shared 'browsers' 600 { @(Get-InstalledBrowsers) })
        paths      = Get-CpPaths
        launch     = $launch
        profile    = $(try { Get-ProfileInUse $s } catch { $null })
        bisect     = $(try { Get-BisectState } catch { $null })
        vanilla    = $(if ($van) { [ordered]@{ started = $van.started; seen = [bool]$van.gameSeen; parked = @($van.moves | Where-Object { $_.done }).Count } } else { $null })
    }
}

# Starts the game through Steam or the exe; saves are copied first when the mod setup changed since the last copy
function Invoke-GameLaunch([string]$Mode) {
    # test hook: UI tests must never start the game (or Steam)
    if ($env:CPMODS_NOLAUNCH) { throw 'Game launch is disabled in this test session' }
    $cfg =[IO.File]::ReadAllText((Join-Path (Get-CpPaths).root 'config.json')) | ConvertFrom-Json
    if (-not $Mode) { $Mode = "$((Get-CpSettings).launchMode)" }
    [void](Invoke-AutoSaveBackup 'Before a launch with changed mods')
    # launch through explorer so Steam/the game never become children of this hidden server process
    if ($cfg.steamManifest -and $Mode -ne 'direct') {
        $fix = Repair-SteamRunningFlag
        if ($fix.blockers) { throw "Steam still counts $($fix.blockers -join ', ') as part of Cyberpunk (it was opened by the game, e.g. the crash folder). Close it, then press Play again." }
        if ($fix.restarted) { Write-Note 'Steam had the game stuck as running with no game process; restarted Steam' }
        Start-Process explorer.exe -ArgumentList 'steam://rungameid/1091500'
    }
    else { Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path (Get-CpPaths).game 'bin\x64\Cyberpunk2077.exe')) }
}

function Invoke-CpRequest {
    param($Ctx, $Shared)
    $req = $Ctx.Request
    try {
        $port = $Shared.port
        if ($req.Headers['Host'] -notin "localhost:$port", "127.0.0.1:$port") { Send-Json $Ctx @{ error = 'forbidden host' } 403; return }
        $Shared.lastSeen = [datetime]::UtcNow
        $path = $req.Url.AbsolutePath
        $q = $req.QueryString
        if ($path -eq '/api/bye') {
            if ($q['t'] -eq $Shared.token) { $Shared.byeAt = [datetime]::UtcNow }
            Send-Json $Ctx @{ ok = $true }; return
        }
        if (-not $path.StartsWith('/api/')) { Send-Static $Ctx $path $Shared; return }
        if ($req.Headers['X-Cp-Token'] -ne $Shared.token) { Send-Json $Ctx @{ error = 'bad token' } 403; return }
        $origin = $req.Headers['Origin']
        if ($origin -and $origin -notin "http://localhost:$port", "http://127.0.0.1:$port") { Send-Json $Ctx @{ error = 'bad origin' } 403; return }
        $raw = ''
        if ($req.HasEntityBody) { $sr = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); $sr.Dispose() }
        $b = if ($raw) { $raw | ConvertFrom-Json -AsHashtable } else { @{} }
        switch ("$($req.HttpMethod) $path") {
            'GET /api/ping' { Send-Json $Ctx @{ ok = $true; pid = $PID } }
            'GET /api/state' {
                $Shared.lastUi = [datetime]::UtcNow
                # rebuilt only when an input changed (or after 60 s); unchanged since the client's copy: tiny reply
                $k = Get-UiStateKey $Shared
                $c = $Shared.cache['ui']
                if (-not $c -or $c.k -ne $k -or ([datetime]::UtcNow - $c.t).TotalSeconds -gt 60) {
                    $json = ConvertTo-Json -InputObject (Get-UiState $Shared) -Depth 12 -Compress
                    $c = @{ k = $k; t = [datetime]::UtcNow; json = $json; sig = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($json))).Substring(0, 16) }
                    $Shared.cache['ui'] = $c
                }
                if ($q['have'] -eq $c.sig) { Send-Json $Ctx "{`"same`":true,`"sig`":`"$($c.sig)`"}" }
                else { Send-Json $Ctx ($c.json.Substring(0, $c.json.Length - 1) + ",`"sig`":`"$($c.sig)`"}") }
            }
            'POST /api/prefs' { Save-UiPrefs $raw; Send-Json $Ctx @{ ok = $true } }
            'POST /api/window' { Request-CpWindow $Shared; Send-Json $Ctx @{ ok = $true } }
            'GET /api/perf' { Send-Json $Ctx (Get-CpPerf $Shared) }
            'GET /api/mouse' { Send-Json $Ctx (Get-CpMouseInfo) }
            'GET /api/storage' { Send-Json $Ctx (Get-StorageInfo) }
            'GET /api/profiles' { Send-Json $Ctx @{ profiles = @(Get-ProfileSummaries) } }
            'POST /api/profiles' {
                $n = "$($b.name)"
                switch ("$($b.op)") {
                    'save' { $r = Save-Profile $n; Send-Json $Ctx @{ ok = $true; name = $r.name; mods = @($r.mods).Count } }
                    'delete' { Remove-Profile $n; Send-Json $Ctx @{ ok = $true } }
                    'apply' { $j = Start-CpJob $Shared 'profile' "Switching to the profile $n" @{ name = $n }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    default { throw "Unknown op $($b.op)" }
                }
            }
            'POST /api/storage' {
                if ("$($b.op)" -ne 'clean') { throw "Unknown op $($b.op)" }
                $j = Start-CpJob $Shared 'cleanup' 'Freeing disk space' @{ old = [bool]$b.old }
                Send-Json $Ctx @{ ok = $true; job = $j.id }
            }
            'POST /api/free' { $Shared.winFree = $true; $Shared.trimNow = $true; Send-Json $Ctx @{ ok = $true } }
            'POST /api/key' {
                $v = Set-NexusKey "$($b.key)"
                Write-Note "Nexus API key saved for $($v.name)"
                Send-Json $Ctx @{ ok = $true; name = "$($v.name)"; premium = [bool]$v.is_premium }
            }
            'POST /api/gql' { Send-Gql $Ctx $raw $Shared }
            'GET /api/fileinfo' {
                $mid = [int]$q['mod']; $fid = [int]$q['file']
                Send-Json $Ctx (Get-Cached $Shared "fi-$mid-$fid" 3600 { Get-NexusFileInfo $mid $fid })
            }
            'GET /api/modcats' {
                $cats = Get-Cached $Shared 'modcats' 86400 { @((Invoke-NexusV1 'games/cyberpunk2077.json').categories | Where-Object { $_.parent_category } | ForEach-Object { $_.name } | Sort-Object -Unique) }
                Send-Json $Ctx @{ categories = @($cats) }
            }
            # cpmods itself: checked on GitHub at most every 6 hours unless asked
            'GET /api/update' { Send-Json $Ctx (Get-Cached $Shared 'appupdate' $(if ($q['fresh']) { 0 } else { 21600 }) { Get-CpUpdate }) }
            'POST /api/update' {
                if (@($Shared.jobs.Clone().Values | Where-Object { $_.status -eq 'running' }).Count) { throw 'Wait until the running tasks finish, then update' }
                if ((Get-GameState).running) { throw 'Close the game first: cpmods closes and opens again during the update' }
                $j = Start-CpJob $Shared 'update' 'Updating cpmods' @{}
                Send-Json $Ctx @{ ok = $true; job = $j.id }
            }
            'GET /api/fwupdates' { Send-Json $Ctx @{ items = @(Get-Cached $Shared 'fwupdates' 1800 { @(Get-FrameworkUpdates) }) } }
            'GET /api/check' { Send-Json $Ctx (Test-Install) }
            'GET /api/compat' {
                $lr = try { Get-LaunchCached $Shared } catch { $null }
                Send-Json $Ctx (Test-ModCompat -Loaded (Get-LoadedOkMods $lr))
            }
            'POST /api/compat' {
                if ("$($b.op)" -ne 'ignore') { throw "Unknown op $($b.op)" }
                Send-Json $Ctx @{ ok = $true; ignored = @(Set-CompatIgnore "$($b.key)" ([bool]$b.on)) }
            }
            'GET /api/launch' { Send-Json $Ctx (Get-LaunchCached $Shared -Fresh:([bool]$q['fresh'])) }
            'GET /api/modinfo' { Send-Json $Ctx (Get-ModDetail $q['name']) }
            'GET /api/libfiles' { Send-Json $Ctx @{ mods = @(Get-LibraryFiles) } }
            'GET /api/preview' { Send-Json $Ctx (Get-DownloadPreview $q['file'] $q['sub'] $q['name']) }
            'POST /api/bisect' {
                $op = "$($b.op)"
                if ($op -notin 'start', 'result', 'stop') { throw "Unknown troubleshooting step $op" }
                $title = switch ($op) { 'start' { 'Troubleshooting: turning mods off' } 'result' { 'Troubleshooting: next round' } default { 'Troubleshooting: restoring mods' } }
                $j = Start-CpJob $Shared 'bisect' $title @{ op = $op; names = @($b.names); ok = [bool]$b.ok; keep = [bool]$b.keep }
                Send-Json $Ctx @{ ok = $true; job = $j.id }
            }
            'GET /api/backups' {
                $saves = @(Get-SaveBackups | ForEach-Object { [ordered]@{ id = $_.id; at = $_.at; reason = $_.reason; saves = @($_.saves); size = $_.size } })
                Send-Json $Ctx ([ordered]@{ points = @(Get-RestoreSummaries); saves = $saves; settings = @(Get-SettingsBackups); savesDir = (Get-GameLocations).saves })
            }
            'GET /api/restoreplan' { Send-Json $Ctx (Get-RestorePlan "$($q['id'])") }
            'GET /api/settingsplan' { Send-Json $Ctx (Restore-ModSettings "$($q['id'])" -Preview) }
            'POST /api/backups' {
                $id = "$($b.id)"
                switch ("$($b.op)") {
                    'point' { $r = Save-RestorePoint 'manual' $(if ($b.label) { "$($b.label)".Trim() } else { 'Made by you' }); Send-Json $Ctx @{ ok = $true; id = $r.id } }
                    'point-delete' { Remove-RestorePoint $id; Send-Json $Ctx @{ ok = $true } }
                    'point-restore' { $j = Start-CpJob $Shared 'restore' 'Going back to a restore point' @{ id = $id }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'saves-backup' { $j = Start-CpJob $Shared 'saves' 'Copying your saves' @{ op = 'backup' }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'saves-restore' { $j = Start-CpJob $Shared 'saves' 'Restoring saves' @{ op = 'restore'; id = $id; names = @($b.names) }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'saves-delete' { Remove-SaveBackup $id; Send-Json $Ctx @{ ok = $true } }
                    'settings-backup' { Send-Json $Ctx (Backup-ModSettings 'manual' 'Made by you') }
                    'settings-restore' { Send-Json $Ctx (Use-Lock { Restore-ModSettings $id }) }
                    'settings-delete' { Remove-SettingsBackup $id; Send-Json $Ctx @{ ok = $true } }
                    'settings-import' { Send-Json $Ctx (Import-ModSettings "$($b.data)") }
                    'open' {
                        $d = if ($b.what -eq 'settings') { Get-SettingsBackupDir } elseif ($id) { Assert-SafetyId $id; Join-Path (Get-SavesBackupDir) $id } else { Get-SavesBackupDir }
                        Open-Folder $d; Send-Json $Ctx @{ ok = $true }
                    }
                    default { throw "Unknown backup action $($b.op)" }
                }
            }
            'GET /api/keymap' { Send-Json $Ctx (Get-KeyMap) }
            'POST /api/loadorder' {
                $r = switch ("$($b.op)") {
                    'win' { Use-Lock { Set-ArchiveWinner "$($b.archive)" "$($b.over)" } }
                    'undo' { Use-Lock { Reset-ArchiveName "$($b.archive)" } }
                    default { throw "Unknown load order action $($b.op)" }
                }
                Send-Json $Ctx @{ ok = $true; name = "$r" }
            }
            'POST /api/vanilla' {
                $op = if ("$($b.op)" -eq 'start') { 'start' } else { 'restore' }
                $j = Start-CpJob $Shared 'vanilla' $(if ($op -eq 'start') { 'Launch without mods' } else { 'Bringing your mods back' }) @{ op = $op; mode = "$($b.mode)" }
                Send-Json $Ctx @{ ok = $true; job = $j.id }
            }
            'GET /api/modlist' { Send-Json $Ctx (Export-ModList) }
            'POST /api/pack' {
                switch ("$($b.op)") {
                    'make' {
                        $long = ConvertTo-PackCode "$($b.name)"
                        Send-Json $Ctx @{ code = (ConvertTo-PackCode "$($b.name)" -Short).code; long = $long.code; count = $long.count }
                    }
                    'plan' { Send-Json $Ctx (Get-PackPlan (Read-ModPack "$($b.code)" $b.list)) }
                    'apply' {
                        $pk = Read-ModPack "$($b.code)" $b.list
                        $j = Start-CpJob $Shared 'pack' "Getting the modpack$(if ($pk.name) { " $($pk.name)" })" @{ pack = $pk; use = @($b.use | ForEach-Object { "$_" }) }
                        Send-Json $Ctx @{ ok = $true; job = $j.id }
                    }
                    default { throw "Unknown op $($b.op)" }
                }
            }
            'GET /api/discover' { Send-Json $Ctx (Find-ExistingMods) }
            'GET /api/log' {
                $lines = @(Get-Content -LiteralPath (Get-CpPaths).log -Tail 200 -ErrorAction SilentlyContinue)
                Send-Json $Ctx @{ lines = $lines }
            }
            'GET /api/archive' { Send-Json $Ctx (Get-ArchiveCandidates (Resolve-DownloadFile $q['file'])) }
            'POST /api/get' {
                $mid = [int]$b.modId; $fid = [int]$b.fileId
                if ($mid -le 0 -or $fid -le 0) { throw 'modId and fileId required' }
                if ($b.name) { $Shared.intents["$fid"] = @{ name = "$($b.name)"; at = [datetime]::UtcNow } }
                [void](Open-UrlInFront (Get-NexusPageUrl $mid $fid))
                Send-Json $Ctx @{ ok = $true }
            }
            'POST /api/nxm' {
                $l = Resolve-NxmLink $b.url
                $job = Start-CpJob $Shared 'nxm' "Nexus file $($l.fileId)" @{ url = "$($b.url)"; modId = $l.modId; fileId = $l.fileId }
                $job.modId = $l.modId; $job.fileId = $l.fileId
                Request-CpWindow $Shared -IfClosed
                Send-Json $Ctx @{ ok = $true; job = $job.id }
            }
            'POST /api/queue' {
                $res = Use-Lock {
                    $qq = [Collections.Generic.List[object]]::new([object[]]@(Get-Queue))
                    switch ("$($b.op)") {
                        'add' { $r = Add-QueueItems $b.items 'Added'; "added $($r.added), skipped $($r.skipped)" }
                        'remove' { foreach ($x in @($qq | Where-Object { [int]$_.fileId -eq [int]$b.fileId })) { [void]$qq.Remove($x) }; Save-Queue $qq; 'removed' }
                        'skip' { foreach ($x in $qq) { if ([int]$x.fileId -eq [int]$b.fileId) { $x.done = $true } }; Save-Queue $qq; 'skipped' }
                        'clear' { $keep = @(if ($b.all) { } else { $qq | Where-Object { -not $_.done } }); Save-Queue $keep; 'cleared' }
                        'next' { 'next' }
                        default { throw "Unknown queue op $($b.op)" }
                    }
                }
                $opened = $null
                if ($b.op -eq 'next' -or ($b.op -eq 'add' -and $b.start)) { $n = Open-NextQueue; if ($n) { $opened = $n.name } }
                Send-Json $Ctx @{ ok = $true; result = "$res"; opened = $opened }
            }
            'POST /api/action' {
                $op = "$($b.op)"
                switch ($op) {
                    'install' { $j = Start-CpJob $Shared 'install' "Install $($b.archive)" @{ archive = "$($b.archive)"; name = "$($b.name)"; sub = "$($b.sub)"; conflict = "$($b.conflict)" }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'remove' { $j = Start-CpJob $Shared 'remove' "Remove $($b.name)" @{ name = "$($b.name)"; purge = [bool]$b.purge }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'disable' { $j = Start-CpJob $Shared 'disable' "Disable $($b.name)" @{ name = "$($b.name)" }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'enable' { $j = Start-CpJob $Shared 'enable' "Enable $($b.name)" @{ name = "$($b.name)" }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'frameworks' { $j = Start-CpJob $Shared 'frameworks' 'Update frameworks' @{ names = @($b.names | ForEach-Object { "$_" }) }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'adopt' { $j = Start-CpJob $Shared 'adopt' "Adopt $(@($b.items).Count) existing mods" @{ items = @($b.items) }; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'sync' { $j = Start-CpJob $Shared 'sync' 'Install frameworks and waiting mods' @{}; Send-Json $Ctx @{ ok = $true; job = $j.id } }
                    'dismiss' { $n = Use-Lock { Remove-Deferred "$($b.name)" }; Send-Json $Ctx @{ ok = $true; removed = $n } }
                    'deleteDownload' {
                        $p = Resolve-DownloadFile "$($b.file)"
                        Remove-Item -LiteralPath $p -Force
                        Write-Note "Deleted download $($b.file)"
                        Send-Json $Ctx @{ ok = $true }
                    }
                    'cancelJob' { $j = $Shared.jobs["$($b.id)"]; if ($j -and $j.status -eq 'running') { $j.cancel = $true }; Send-Json $Ctx @{ ok = $true } }
                    'clearJobs' { foreach ($k in @($Shared.jobs.Clone().Keys)) { if ($Shared.jobs[$k].status -ne 'running') { $Shared.jobs.Remove($k) } }; Send-Json $Ctx @{ ok = $true } }
                    default { throw "Unknown action $op" }
                }
            }
            'POST /api/settings' { Send-Json $Ctx (Save-CpSettings $b) }
            'POST /api/system' {
                switch ("$($b.op)") {
                    'play' { Invoke-GameLaunch "$($b.mode)" }
                    'package' {
                        $set = if ($b.settings) { Join-Path (Get-SettingsBackupDir) "$((Backup-ModSettings 'manual' 'For the share package').id).zip" } else { $null }
                        $zip = New-CpPackage -NoModList:([bool]$b.appOnly) -SettingsZip $set
                        Open-Folder (Split-Path $zip) $zip
                        Send-Json $Ctx @{ ok = $true; path = $zip }; return
                    }
                    'folder' { Open-Folder (Get-CpPaths).game }
                    'downloads' { Open-Folder (Get-CpPaths).downloads }
                    'openLoc' {
                        $locs = Get-GameLocations
                        $k = "$($b.loc)"
                        if (-not $locs.Contains($k)) { throw "Unknown folder $k" }
                        $p = $locs[$k]
                        if (-not (Test-Path -LiteralPath $p)) { throw "That folder does not exist yet: $p" }
                        Open-Folder $p
                    }
                    'reveal' {
                        # opens the folder of a game-relative path, download name or crash report id
                        if ($b.file) { $t = Resolve-DownloadFile "$($b.file)" }
                        elseif ($b.crash) {
                            if ("$($b.crash)" -notmatch '^Cyberpunk2077-[\w\-]+$') { throw 'Invalid crash report' }
                            $t = Join-Path (Get-GameLocations).crashes "$($b.crash)"
                        }
                        else {
                            $rel = "$($b.path)" -replace '/', '\'
                            if (-not $rel -or [IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)') { throw 'Invalid path' }
                            $t = Join-Path (Get-CpPaths).game $rel
                        }
                        if (Test-Path -LiteralPath $t -PathType Leaf) { Open-Folder (Split-Path $t) $t }
                        else {
                            while ($t -and -not (Test-Path -LiteralPath $t)) { $t = Split-Path $t }
                            if (-not $t) { throw 'Not found' }
                            Open-Folder $t
                        }
                    }
                    'openFile' {
                        # a log of the game folder in its usual app (Notepad for .log); text logs only
                        $rel = "$($b.path)" -replace '/', '\'
                        if (-not $rel -or [IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)' -or [IO.Path]::GetExtension($rel) -notin '.log', '.txt') { throw 'Invalid path' }
                        $t = Join-Path (Get-CpPaths).game $rel
                        if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { throw "That log is gone (the game writes a new one at each launch): $rel" }
                        $pr = Start-Process -FilePath $t -PassThru
                        if ($pr) { [void](Show-AppWindow $pr.ProcessName) }
                    }
                    'kill' { $r = Stop-GameProcesses; Send-Json $Ctx @{ ok = $true; stopped = @($r.stopped); left = @($r.left) }; return }
                    'steam' {
                        $u = switch ("$($b.what)") { 'validate' { 'steam://validate/1091500' } 'page' { 'steam://nav/games/details/1091500' } default { throw 'Unknown Steam action' } }
                        Start-Process explorer.exe -ArgumentList $u
                    }
                    'register' { Register-NxmHandler }
                    'open' { $u = "$($b.url)"; if ($u -match '^https?://[^\s"]+$') { [void](Open-UrlInFront $u) } else { throw 'Invalid URL' } }
                    'quit' { $Shared.stop = $true }
                    default { throw "Unknown op $($b.op)" }
                }
                Send-Json $Ctx @{ ok = $true }
            }
            default { Send-Json $Ctx @{ error = "Unknown endpoint $($req.HttpMethod) $path" } 404 }
        }
    }
    catch {
        $msg = $_.Exception.Message
        try { Write-Note "API $($req.HttpMethod) $($req.Url.AbsolutePath): $msg" } catch { }
        try { Send-Json $Ctx @{ error = $msg } 500 } catch { }
    }
}

# shared lists are walked through a copy taken under their lock (Clone, ToArray): other threads add jobs and cache entries meanwhile
function Clear-CpWorkers($Shared, $Reqs) {
    foreach ($r in @($Reqs)) {
        if ($r.h.IsCompleted) { try { [void]$r.ps.EndInvoke($r.h) } catch { }; $r.ps.Dispose(); [void]$Reqs.Remove($r) }
    }
    foreach ($w in @($Shared.workers.ToArray())) {
        if ($w.h.IsCompleted) { try { [void]$w.ps.EndInvoke($w.h) } catch { }; $w.ps.Dispose(); $w.rs.Dispose(); $Shared.workers.Remove($w) }
    }
    $cut = [datetime]::UtcNow.AddMinutes(-30)
    foreach ($k in @($Shared.jobs.Clone().Keys)) {
        $j = $Shared.jobs[$k]
        if ($j.status -ne 'running' -and $j.finished -and [datetime]::Parse($j.finished).ToUniversalTime() -lt $cut) { $Shared.jobs.Remove($k) }
    }
}

function Test-CpShouldExit($Shared) {
    if (@($Shared.jobs.Clone().Values | Where-Object { $_.status -eq 'running' }).Count) { return $false }
    if ($Shared.stop) { return $true }
    # a launch without mods is under way: stay to bring the mods back when the game closes (gameRun: server.ps1)
    $vf = Join-Path (Get-CpPaths).state 'vanilla.json'
    if ([IO.File]::Exists($vf)) {
        $v = try { Read-JsonFile $vf } catch { $null }
        if ($v -and ($Shared.gameRun -or (-not $v.gameSeen -and ((Get-Date) - [datetime]$v.started).TotalMinutes -lt 10))) { return $false }
    }
    # a mouse profile to put back (Sync-CpMouse): stay while the game runs with the game profile on, and until it is back
    $mo = $Shared.mouse
    if ($mo -and ($mo.busy -or "$($mo.want)" -eq 'back' -or ($Shared.gameRun -and [IO.File]::Exists((Join-Path (Get-CpPaths).state 'mouse.json'))))) { return $false }
    # the built-in window may be suspended (minimized) and silent: it ends the server when it closes
    if ($Shared.winOpen) { return $false }
    $now = [datetime]::UtcNow
    if ($Shared.byeAt -and $Shared.lastSeen -le $Shared.byeAt -and ($now - $Shared.byeAt).TotalSeconds -gt 10) { return $true }
    if (($now - $Shared.lastSeen).TotalMinutes -gt 30) { return $true }
    $false
}

# ---------- Logitech mouse onboard profiles (HID++ 2.0 over the receiver or the cable) ----------
# Only switches the active profile (feature 0x8100): nothing is written to the mouse's memory
function Add-CpHidType {
    if ('CpHid' -as [type]) { return }
    Import-CpType 'CpHid' @'
using System; using System.IO; using System.Threading; using System.Collections.Generic; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public sealed class CpHid : IDisposable {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
  [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, out Caps c);
  [DllImport("setupapi.dll", SetLastError = true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
  [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref Ifd r);
  [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref Ifd r, IntPtr b, int n, out int need, IntPtr d);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
  [StructLayout(LayoutKind.Sequential)] struct Ifd { public int cb; public Guid g; public int f; public IntPtr r; }
  [StructLayout(LayoutKind.Sequential)] struct Caps { public ushort Usage, UsagePage, InLen, OutLen, FeatLen; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 27)] public ushort[] Rest; }
  static int swNext;

  // HID++ long-report interfaces (usage page FF00, usage 2) of Logitech devices
  public static string[] Find() {
    var list = new List<string>(); Guid g; HidD_GetHidGuid(out g);
    IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    if (set == new IntPtr(-1)) return list.ToArray();
    try {
      var d = new Ifd(); d.cb = Marshal.SizeOf(typeof(Ifd));
      for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d); i++) {
        int need; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out need, IntPtr.Zero);
        if (need <= 0) continue;
        IntPtr buf = Marshal.AllocHGlobal(need);
        try {
          Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
          if (!SetupDiGetDeviceInterfaceDetail(set, ref d, buf, need, out need, IntPtr.Zero)) continue;
          string path = Marshal.PtrToStringUni(buf + 4);
          if (path.IndexOf("vid_046d", StringComparison.OrdinalIgnoreCase) < 0) continue;
          using (var h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            IntPtr p; if (h.IsInvalid || !HidD_GetPreparsedData(h, out p)) continue;
            Caps c; HidP_GetCaps(p, out c); HidD_FreePreparsedData(p);
            if (c.UsagePage == 0xFF00 && c.Usage == 2 && c.OutLen == 20) list.Add(path);
          }
        } finally { Marshal.FreeHGlobal(buf); }
      }
    } finally { SetupDiDestroyDeviceInfoList(set); }
    return list.ToArray();
  }

  // plain overlapped I/O with own events: no thread pool (a busy server's pool answered too late)
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, IntPtr b, int n, IntPtr done, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, IntPtr b, int n, IntPtr done, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetOverlappedResult(SafeFileHandle h, IntPtr ov, out int n, bool wait);
  [DllImport("kernel32.dll")] static extern bool CancelIoEx(SafeFileHandle h, IntPtr ov);
  [DllImport("kernel32.dll")] static extern IntPtr CreateEvent(IntPtr a, bool manual, bool init, IntPtr name);
  [DllImport("kernel32.dll")] static extern bool ResetEvent(IntPtr e);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  SafeFileHandle hf; IntPtr rov, wov, rmem, wmem, rev, wev; bool reading; readonly byte[] rbuf = new byte[20]; readonly byte sw;
  public CpHid(string path) {
    hf = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
    if (hf.IsInvalid) throw new IOException("could not open the mouse (error " + Marshal.GetLastWin32Error() + ")");
    rev = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero); wev = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
    int os = Marshal.SizeOf(typeof(NativeOverlapped));
    rov = Marshal.AllocHGlobal(os); wov = Marshal.AllocHGlobal(os); rmem = Marshal.AllocHGlobal(20); wmem = Marshal.AllocHGlobal(20);
    sw = (byte)(1 + (Interlocked.Increment(ref swNext) & 0x7FFFFFFF) % 15);   // own id per handle: replies to another handle are skipped
  }
  public void Dispose() {
    if (hf == null) return;
    int n; if (reading) { CancelIoEx(hf, rov); GetOverlappedResult(hf, rov, out n, true); }
    hf.Dispose(); hf = null;
    CloseHandle(rev); CloseHandle(wev);
    Marshal.FreeHGlobal(rov); Marshal.FreeHGlobal(wov); Marshal.FreeHGlobal(rmem); Marshal.FreeHGlobal(wmem);
  }
  static void Arm(IntPtr ov, IntPtr ev) { ResetEvent(ev); var o = new NativeOverlapped(); o.EventHandle = ev; Marshal.StructureToPtr(o, ov, false); }
  void Send(byte[] req) {
    Marshal.Copy(req, 0, wmem, 20); Arm(wov, wev);
    int n;
    if (!WriteFile(hf, wmem, 20, IntPtr.Zero, wov) && Marshal.GetLastWin32Error() != 997) throw new IOException("could not send to the mouse (error " + Marshal.GetLastWin32Error() + ")");
    if (WaitForSingleObject(wev, 1000) != 0) { CancelIoEx(hf, wov); GetOverlappedResult(hf, wov, out n, true); throw new TimeoutException("the mouse did not take the request"); }
    if (!GetOverlappedResult(hf, wov, out n, false)) throw new IOException("could not send to the mouse (error " + Marshal.GetLastWin32Error() + ")");
  }
  // next input report into rbuf: its length, or -1 when none came in time (the read stays queued for the next call)
  int Receive(int ms) {
    int n;
    if (!reading) {
      Arm(rov, rev);
      if (!ReadFile(hf, rmem, 20, IntPtr.Zero, rov) && Marshal.GetLastWin32Error() != 997) throw new IOException("could not read from the mouse (error " + Marshal.GetLastWin32Error() + ")");
      reading = true;
    }
    if (WaitForSingleObject(rev, (uint)ms) != 0) return -1;
    reading = false;
    if (!GetOverlappedResult(hf, rov, out n, false)) throw new IOException("could not read from the mouse (error " + Marshal.GetLastWin32Error() + ")");
    Marshal.Copy(rmem, rbuf, 0, 20);
    return n;
  }

  // HID++ 2.0 request: the 16 reply parameter bytes; throws on an error reply or no answer
  public byte[] Call(byte dev, byte feat, byte func, byte[] args, int ms) {
    var req = new byte[20];
    req[0] = 0x11; req[1] = dev; req[2] = feat; req[3] = (byte)((func << 4) | sw);
    if (args != null) Array.Copy(args, 0, req, 4, Math.Min(args.Length, 16));
    Send(req);
    var until = DateTime.UtcNow.AddMilliseconds(ms);
    while (true) {
      int left = (int)(until - DateTime.UtcNow).TotalMilliseconds;
      if (left <= 0) throw new TimeoutException("the mouse did not answer");
      int n = Receive(left);
      if (n < 0) throw new TimeoutException("the mouse did not answer");
      if (n < 7 || rbuf[1] != dev) continue;
      if (rbuf[0] == 0x11 && rbuf[2] == feat && rbuf[3] == req[3]) { var r = new byte[16]; Array.Copy(rbuf, 4, r, 0, 16); return r; }
      if (rbuf[0] == 0x11 && rbuf[2] == 0xFF && rbuf[3] == feat && rbuf[4] == req[3]) throw new InvalidOperationException("the mouse refused (HID++ error " + rbuf[5] + ")");
      if (rbuf[0] == 0x10 && rbuf[2] == 0x8F && rbuf[3] == feat) throw new InvalidOperationException("no device at this slot (error " + rbuf[5] + ")");
    }
  }
  // index of a feature on the device, 0 when it has none
  public byte Feature(byte dev, ushort id, int ms) { return Call(dev, 0, 0, new byte[] { (byte)(id >> 8), (byte)id }, ms)[0]; }
}
'@
}

# Profile directory (onboard memory sector 0): 4-byte entries (sector hi, lo, enabled, 0) until FFFF; user profiles only
function ConvertFrom-CpProfileDir([byte[]]$Dir) {
    for ($i = 0; $i + 3 -lt $Dir.Length; $i += 4) {
        $n = $Dir[$i] * 256 + $Dir[$i + 1]
        if ($n -eq 0xFFFF) { break }
        if ($n -ge 1 -and $n -le 0xFF) { [pscustomobject]@{ n = $n; on = $Dir[$i + 2] -ne 0 } }
    }
}
# A profile's first byte: with feature 0x8061 an index (125 Hz doubled per step, 6 = 8000 Hz), otherwise milliseconds
function Get-CpRateHz([int]$B, [bool]$Ext) {
    if ($Ext) { if ($B -le 6) { return 125 * [int][Math]::Pow(2, $B) } }
    elseif ($B -ge 1) { return [int](1000 / $B) }
    $null
}

# First Logitech mouse with onboard profiles and an adjustable report rate (G keyboards can have both, so the device type is checked).
# The slot that answered last time (else receiver slot 1) waits 2 s: a sleeping mouse wakes on the request.
# Other slots and the cable (FF) get 300 ms: a receiver reports empty slots on another channel, so they just time out.
function Open-CpMouse {
    Add-CpHidType
    $script:MouseWhy = 'no Logitech receiver or mouse is connected'
    $first = if ($script:MouseSlot) { $script:MouseSlot } else { 1 }
    foreach ($path in [CpHid]::Find()) {
        $h = $null
        try {
            $h = [CpHid]::new($path)
            foreach ($dev in @($first) + @(1, 0xFF, 2, 3, 4, 5, 6 | Where-Object { $_ -ne $first })) {
                $p = try { $h.Feature($dev, 0x8100, $(if ($dev -eq $first) { 2000 } else { 300 })) } catch { $script:MouseWhy = "$($_.Exception.InnerException.Message ?? $_.Exception.Message)"; 0 }
                if (-not $p) { continue }
                $x = $h.Feature($dev, 0x8061, 500)
                if (-not $x -and -not $h.Feature($dev, 0x8060, 500)) { continue }
                $nf = $h.Feature($dev, 0x0005, 500)
                if ($nf -and $h.Call($dev, $nf, 2, $null, 300)[0] -ne 3) { continue }   # 0x0005 getDeviceType: 3 = mouse
                $script:MouseSlot = $dev
                $name = ''
                if ($nf) {
                    $len = $h.Call($dev, $nf, 0, $null, 300)[0]
                    for ($o = 0; $o -lt $len; $o += 16) { $name += [Text.Encoding]::ASCII.GetString($h.Call($dev, $nf, 1, [byte[]]@($o), 300)) }
                    $name = $name.Substring(0, [Math]::Min($len, $name.Length)).TrimEnd([char]0)
                }
                return @{ h = $h; dev = [byte]$dev; prof = $p; ext = [bool]$x; name = $name }
            }
        }
        catch { $script:MouseWhy = "$($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
        if ($h) { $h.Dispose() }
    }
    $null
}
function Read-CpMouseMem($M, [int]$Sector, [int]$Offset) {
    $M.h.Call($M.dev, $M.prof, 5, [byte[]]@(($Sector -shr 8), ($Sector -band 255), ($Offset -shr 8), ($Offset -band 255)), 500)
}
function Get-CpMouseProfiles($M) { @(ConvertFrom-CpProfileDir ((Read-CpMouseMem $M 0 0) + (Read-CpMouseMem $M 0 16))) }
function Get-CpMouseCurrent($M) { $c = $M.h.Call($M.dev, $M.prof, 4, $null, 500); $c[0] * 256 + $c[1] }

# For Settings: the mouse, its profiles with their wireless polling rate, and the active one
function Get-CpMouseInfo {
    $m = Open-CpMouse
    if (-not $m) { return @{ found = $false; why = $script:MouseWhy } }
    try {
        $list = foreach ($p in Get-CpMouseProfiles $m) { [ordered]@{ n = $p.n; on = $p.on; hz = Get-CpRateHz (Read-CpMouseMem $m $p.n 0)[0] $m.ext } }
        [ordered]@{ found = $true; name = $m.name; onboard = $m.h.Call($m.dev, $m.prof, 2, $null, 500)[0] -eq 1; current = Get-CpMouseCurrent $m; profiles = @($list) }
    }
    finally { $m.h.Dispose() }
}

# Makes onboard profile N active; returns the profile that was active before
function Set-CpMouseProfile([int]$N) {
    $m = Open-CpMouse
    if (-not $m) { throw "no Logitech mouse with onboard profiles answered ($script:MouseWhy)" }
    try {
        if ($m.h.Call($m.dev, $m.prof, 2, $null, 500)[0] -ne 1) { throw 'the mouse is in software mode (G HUB controls it), so its onboard profiles are not used' }
        if (-not (Get-CpMouseProfiles $m | Where-Object { $_.n -eq $N -and $_.on })) { throw "profile $N is not turned on in the mouse's onboard memory" }
        $prev = Get-CpMouseCurrent $m
        if ($prev -ne $N) { [void]$m.h.Call($m.dev, $m.prof, 3, [byte[]]@(($N -shr 8), ($N -band 255)), 500) }
        $prev
    }
    finally { $m.h.Dispose() }
}

# Game watch (server worker): $Shared.mouse.want = profile number while playing, 'back' after the game closed.
# state\mouse.json keeps the previous profile until it is back, also across a cpmods restart. Retried for 10 minutes.
function Sync-CpMouse($Shared) {
    Set-CpContext 'server' $true
    $m = $Shared.mouse; $want = $m.want
    $f = Join-Path (Get-CpPaths).state 'mouse.json'
    try {
        if ("$want" -eq 'back') {
            $j = try { Read-JsonFile $f } catch { $null }
            if ($j -and [int]$j.prev -gt 0) { [void](Set-CpMouseProfile ([int]$j.prev)); Write-Note "Mouse: profile $($j.prev) is back" }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
        elseif ([int]$want -gt 0) {
            $prev = Set-CpMouseProfile ([int]$want)
            if ($prev -ne [int]$want) { Write-JsonFile $f ([ordered]@{ prev = $prev; game = [int]$want }) }
            Write-Note "Mouse: profile $want while playing (was $prev)"
        }
        # the game may have started or closed meanwhile: that newer wish stays
        if ("$($m.want)" -eq "$want") { $m.want = $null }
    }
    catch {
        $m.tries++
        if ($m.tries -eq 1) { Write-Note "Mouse: $($_.Exception.Message) (trying again every 20 s)" }
        if ($m.tries -ge 30 -and "$($m.want)" -eq "$want") { $m.want = $null; Write-Note 'Mouse: gave up after 10 minutes' }
        $m.retry = [datetime]::UtcNow.AddSeconds(20)
    }
    finally { $m.busy = $false }
}

Export-ModuleMember -Function *
