# cpmods local server: serves the UI on http://localhost:<Port>/ and runs install jobs
# -Dev: separate test instance (own mutex, port 7078, state\server-dev.json, window only with -Open)
param([switch]$Open, [int]$Port = 7077, [switch]$Dev)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# The window is hidden, so startup failures would be invisible: log them and show a message box
function Show-Fatal([string]$Msg) {
    $log = Join-Path $Root 'cpmods.log'
    try { [IO.File]::AppendAllText($log, ('{0:yyyy-MM-dd HH:mm:ss} [server] {1}{2}' -f (Get-Date), $Msg, [Environment]::NewLine)) } catch { }
    if ($Dev) { Write-Host $Msg; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show("cpmods could not start.`n`n$Msg`n`nDetails: $log", 'Cyberpunk Mods', 'OK', 'Error', 'Button1', 'DefaultDesktopOnly')
    }
    catch { }
}

try {
    Import-Module (Join-Path $Root 'lib\cpmods.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $Root 'lib\cpinsight.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $Root 'lib\cpsafety.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $Root 'lib\cpserver.psm1') -Force -DisableNameChecking
}
catch { Show-Fatal "Loading the app failed: $($_.Exception.Message)"; exit 1 }
Set-CpContext $(if ($Dev) { 'server-dev' } else { 'server' }) $true
if ($Dev -and -not $PSBoundParameters.ContainsKey('Port')) { $Port = 7078 }
$infoFile = Join-Path (Get-CpPaths).state $(if ($Dev) { 'server-dev.json' } else { 'server.json' })

function Read-Info { if (Test-Path -LiteralPath $infoFile) { try { Read-JsonFile $infoFile } catch { $null } } }
function Test-Alive($I) {
    try { [void](Invoke-RestMethod "http://localhost:$($I.port)/api/ping" -Headers @{ 'X-Cp-Token' = "$($I.token)" } -TimeoutSec 2); $true } catch { $false }
}

# Single instance: a second launch only opens the window; a hung owner is replaced
$mtx = [Threading.Mutex]::new($false, $(if ($Dev) { 'Local\cpmods-server-dev' } else { 'Local\cpmods-server' }))
$owned = $false
try { $owned = $mtx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    $until = [datetime]::UtcNow.AddSeconds(10)
    while ([datetime]::UtcNow -lt $until) {
        $i = Read-Info
        if ($i -and (Test-Alive $i)) { if ($Open) { Open-CpWindow ([int]$i.port) "$($i.token)" }; exit 0 }
        Start-Sleep -Milliseconds 500
    }
    $i = Read-Info
    if ($i -and $i.pid) {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$i.pid)" -ErrorAction SilentlyContinue
        if ($cim -and "$($cim.CommandLine)" -match 'server\.ps1') {
            Write-Note "Replacing an unresponsive server (pid $($i.pid))"
            Stop-Process -Id ([int]$i.pid) -Force -ErrorAction SilentlyContinue
        }
    }
    try { $owned = $mtx.WaitOne(8000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Show-Fatal 'Another copy of cpmods is running but does not answer. Restart Windows, then open cpmods again.'; exit 1 }
}

# First free port from the requested one (another program may hold 7077)
$listener = $null
$first = $Port
foreach ($p in $first..($first + 9)) {
    $l = [Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { try { $l.Close() } catch { } }
}
if (-not $listener) {
    Show-Fatal "No free local port between $first and $($first + 9). Another program may be using them."
    $mtx.ReleaseMutex(); exit 1
}

$token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$shared = [hashtable]::Synchronized(@{
        token = $token; port = $Port; stop = $false; lastSeen = [datetime]::UtcNow; lastUi = $null; byeAt = $null
        jobs = [hashtable]::Synchronized(@{}); cache = [hashtable]::Synchronized(@{}); intents = [hashtable]::Synchronized(@{})
        workers = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())
    })
$iss = [initialsessionstate]::CreateDefault2()
$iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
$iss.ImportPSModule([string[]]@((Join-Path $Root 'lib\cpmods.psm1'), (Join-Path $Root 'lib\cpinsight.psm1'), (Join-Path $Root 'lib\cpsafety.psm1'), (Join-Path $Root 'lib\cpserver.psm1')))
$shared.iss = $iss
# built-in window (lib\cpwindow.ps1): own STA thread, started on first use, driven by these flags
$shared.winEvt = [Threading.AutoResetEvent]::new($false)
$shared.urls = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())
$shared.winUrl = "http://localhost:$Port/"
$shared.winFile = Join-Path (Get-CpPaths).state 'window.json'
$shared.uiFile = Join-Path (Get-CpPaths).state 'ui.json'
$shared.winTitle = if ($Dev) { 'Cyberpunk Mods (dev)' } else { 'Cyberpunk Mods' }
# taskbar: own button with the window's icon (not PowerShell's); pinning it starts cpmods like the shortcut
$shared.winAppId = if ($Dev) { 'cpmods.CyberpunkMods.Dev' } else { 'cpmods.CyberpunkMods' }
$shared.winRelaunch = if ($Dev) { $null } else { '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Open' -f (Get-PwshPath), (Join-Path $Root 'server.ps1') }
$shared.winOpen = $false; $shared.winShow = $false; $shared.lean = $false

if ($Dev) { Write-JsonFile $infoFile ([ordered]@{ port = $Port; token = $token; pid = $PID; started = (Get-Date).ToString('s') }) }
else { Write-ServerInfo $Port $token }
Write-Note "Server started on port $Port (pid $PID)"

# Each runspace compiles its own copy of the modules (~25 MB once used), so keep the pool small; jobs get their own runspace
$pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
$pool.CleanupInterval = [TimeSpan]::FromMinutes(5)
$pool.Open()
$reqs = [Collections.Generic.List[object]]::new()

# .NET keeps memory it no longer needs (~100 MB after reports or the compatibility check);
# an aggressive collection (~25 ms) hands it back to Windows once things are quiet
$me = [Diagnostics.Process]::GetCurrentProcess()
$trim = @{ at = [datetime]::UtcNow; check = [datetime]::UtcNow; base = 0L; heavy = [datetime]::UtcNow }
function Invoke-Trim {
    try { [GC]::Collect(2, [GCCollectionMode]::Aggressive, $true, $true) }
    catch { [Runtime.GCSettings]::LargeObjectHeapCompactionMode = 'CompactOnce'; [GC]::Collect(2, [GCCollectionMode]::Forced, $true, $true) }
}
# re-applying the working-set limit makes Windows take back the resident pages (no P/Invoke needed)
function Clear-WorkingSet { try { $me.Refresh(); $me.MaxWorkingSet = $me.MaxWorkingSet } catch { } }

$win = $null
function Start-WinThread {
    $rs = [runspacefactory]::CreateRunspace([initialsessionstate]::CreateDefault2())
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $data = Join-Path (Get-CpPaths).state $(if ($Dev) { 'webview-dev' } else { 'webview' })
    $icon = Join-Path (Get-CpPaths).game 'bin\x64\Cyberpunk2077.exe'
    [void]$ps.AddScript([IO.File]::ReadAllText((Join-Path $Root 'lib\cpwindow.ps1'))).AddArgument($shared).AddArgument($Root).AddArgument($data).AddArgument($icon)
    [pscustomobject]@{ ps = $ps; rs = $rs; h = $ps.BeginInvoke() }
}
# links the window could not hand to the page: plain start in the chosen browser (no focus wait on this thread)
function Open-CpLink([string]$U) {
    if ($U -notmatch '^https?://[^\s"]+$') { return }
    $b = "$((Get-CpSettings).browser)"
    if ($b -and (Test-Path -LiteralPath $b)) { Start-Process -FilePath $b -ArgumentList ('"{0}"' -f $U) } else { Start-Process $U }
}
# light mode while the game runs: lower priority, idle runspaces freed fast, memory handed back
$lean = @{ check = [datetime]::MinValue; run = $false }
function Update-GameLean {
    $now = [datetime]::UtcNow
    if (($now - $lean.check).TotalSeconds -lt 3) { return }
    $lean.check = $now
    $ps = [Diagnostics.Process]::GetProcessesByName('Cyberpunk2077'); $run = $ps.Length -gt 0; foreach ($x in $ps) { $x.Dispose() }
    if ($run -eq $lean.run) { return }
    $lean.run = $run
    # game started (also from Steam): saves are copied when the mod setup changed; game closed: a launch without mods ends
    try {
        if ($run) { Set-VanillaSeen; if (Test-SaveBackupDue) { [void](Start-CpJob $shared 'saves' 'Copying your saves' @{ op = 'auto' }) } }
        elseif ((Get-VanillaState).gameSeen) { [void](Start-CpJob $shared 'vanilla' 'Bringing your mods back' @{ op = 'restore' }) }
    }
    catch { Write-Note "Game watch: $($_.Exception.Message)" }
    $on = $run -and (Get-UiPerf).lean -ne $false
    $shared.lean = $on
    try { $me.PriorityClass = $(if ($on) { 'BelowNormal' } else { 'Normal' }) } catch { }
    $pool.CleanupInterval = if ($on) { [TimeSpan]::FromSeconds(30) } else { [TimeSpan]::FromMinutes(5) }
    if ($on) { Invoke-Trim; Clear-WorkingSet; Write-Note 'Game started: light mode on' } else { Write-Note 'Game closed: light mode off' }
}

if ($Open) { Request-CpWindow $shared; if ($shared.winShow) { $win = Start-WinThread } }
# a launch without mods that never ended properly: mods come back (not within 3 minutes: the game may still be starting)
try {
    $vj = Get-VanillaState
    if ($vj -and -not (Get-GameState).running -and ((Get-Date) - [datetime]$vj.started).TotalMinutes -ge 3) { [void](Start-CpJob $shared 'vanilla' 'Bringing your mods back' @{ op = 'restore' }) }
}
catch { Write-Note "Could not check the launch without mods: $($_.Exception.Message)" }

try {
    $tick = 1000
    while ($true) {
        $task = $listener.GetContextAsync()
        $exit = $false
        while (-not $task.Wait($tick)) {
            Clear-CpWorkers $shared $reqs
            if (Test-CpShouldExit $shared) { $exit = $true; break }
            if ($shared.winShow -and -not $win -and -not $shared.winFail) { $win = Start-WinThread }
            # the window thread only ends on quit: anything else is a failure, so use the browser from now on
            if ($win -and $win.h.IsCompleted -and -not $shared.stop) {
                $err = try { [void]$win.ps.EndInvoke($win.h); "$($win.ps.Streams.Error | Select-Object -First 1)" } catch { $_.Exception.Message }
                if (-not $shared.winFail) { $shared.winFail = "window thread ended: $err" }
                $pending = $shared.winShow -or $shared.winOpen
                $shared.winOpen = $false; $shared.winShow = $false
                try { $win.ps.Dispose(); $win.rs.Dispose() } catch { }
                $win = $null
                if ($pending) { $shared.winFallback = $true } else { Write-Note "Built-in window stopped: $($shared.winFail)" }
            }
            if ($shared.winFallback) { $shared.winFallback = $false; Write-Note "Built-in window unavailable ($($shared.winFail)); opening the browser instead"; Open-CpWindow $Port -Browser }
            if ($shared.winFocus) { $shared.winFocus = $false; try { Add-CpFgType; [void][CpFg]::Focus([IntPtr][long]$shared.winHwnd) } catch { } }
            while ($shared.urls.Count) { $u = "$($shared.urls[0])"; $shared.urls.RemoveAt(0); try { Open-CpLink $u } catch { } }
            Update-GameLean
            $now = [datetime]::UtcNow
            if ($shared.trimNow) { $shared.trimNow = $false; Invoke-Trim; Clear-WorkingSet; $me.Refresh(); $trim.base = $me.PrivateMemorySize64; $trim.at = $now }
            if (($now - $trim.check).TotalSeconds -ge 5) {
                $trim.check = $now
                if ($reqs.Count -eq 0 -and $shared.workers.Count -eq 0 -and ($now - $trim.heavy).TotalSeconds -ge 8 -and ($now - $trim.at).TotalSeconds -ge 60) {
                    $me.Refresh()
                    if ($me.PrivateMemorySize64 -gt $trim.base + 40MB) { Invoke-Trim; if ($shared.lean) { Clear-WorkingSet }; $me.Refresh(); $trim.base = $me.PrivateMemorySize64; $trim.at = $now }
                }
            }
            # quick wake-ups only while requests or jobs are in flight
            $tick = if ($reqs.Count -or $shared.workers.Count) { 250 } else { 1000 }
        }
        if ($exit) { break }
        $ctx = $task.Result
        $path = $ctx.Request.Url.AbsolutePath
        # liveness check answered here, so it works even while every worker is busy
        if ($path -eq '/api/ping' -and $ctx.Request.Headers['X-Cp-Token'] -eq $token) {
            try { Send-Json $ctx @{ ok = $true; pid = $PID } } catch { }
            continue
        }
        # most polls: nothing changed since the page's copy, so answer here without a worker runspace
        if ($path -eq '/api/state' -and $ctx.Request.Headers['X-Cp-Token'] -eq $token -and $ctx.Request.Headers['Host'] -in "localhost:$Port", "127.0.0.1:$Port") {
            $c = $shared.cache['ui']; $have = $ctx.Request.QueryString['have']
            if ($c -and $have -and $have -eq $c.sig -and ([datetime]::UtcNow - $c.t).TotalSeconds -le 60) {
                $same = $false
                try { $same = (Get-UiStateKey $shared) -eq $c.k } catch { }
                if ($same) { $shared.lastSeen = $shared.lastUi = [datetime]::UtcNow; try { Send-Json $ctx "{`"same`":true,`"sig`":`"$($c.sig)`"}" } catch { }; continue }
            }
        }
        if ($path.StartsWith('/api/') -and $path -ne '/api/state') { $trim.heavy = [datetime]::UtcNow }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddCommand('Invoke-CpRequest').AddParameter('Ctx', $ctx).AddParameter('Shared', $shared)
        $reqs.Add([pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke() })
        Clear-CpWorkers $shared $reqs
    }
}
catch { Write-Note "Server loop error: $($_.Exception.Message)" }
finally {
    $shared.stop = $true
    try { [void]$shared.winEvt.Set() } catch { }
    if ($win) { try { [void]$win.h.AsyncWaitHandle.WaitOne(6000); $win.ps.Dispose(); $win.rs.Dispose() } catch { } }
    Write-Note 'Server stopped'
    if ($Dev) { Remove-Item -LiteralPath $infoFile -Force -ErrorAction SilentlyContinue } else { Remove-ServerInfo }
    try { $listener.Stop(); $listener.Close() } catch { }
    foreach ($r in $reqs) { try { $r.ps.Dispose() } catch { } }
    try { $pool.Close(); $pool.Dispose() } catch { }
    try { $mtx.ReleaseMutex() } catch { }
    $mtx.Dispose()
}
