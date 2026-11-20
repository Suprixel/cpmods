# cpmods insight: last-launch report, crash dumps, per-mod file details, archive install preview, crash bisect helper
# Uses functions exported by cpmods.psm1 (import that first)
$ErrorActionPreference = 'Stop'

#region helpers
function Read-SharedText([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try { $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false), $true); $sr.ReadToEnd() }
    finally { $fs.Dispose() }
}
function Read-SharedLines([string]$Path) { @((Read-SharedText $Path) -split "\r?\n") }

$script:TsRx = [regex]'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
function Get-LineTime([string]$Line) {
    $m = $script:TsRx.Match($Line)
    if (-not $m.Success) { return $null }
    [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}
function ConvertTo-Iso($D) { if ($D) { ([datetime]$D).ToString('s') } else { $null } }

# What a game-relative path is for: decides icons, labels and which framework loads it
function Get-FileKind([string]$Rel) {
    $r = "$Rel".ToLower() -replace '/', '\'
    $ext = [IO.Path]::GetExtension($r)
    $leaf = [IO.Path]::GetFileName($r)
    if ($leaf -match '^(license|licence|readme|changelog|third_party_licenses|credits)([\._ -].*)?$' -or $ext -in '.md', '.url') { return 'docs' }
    if ($r.StartsWith('archive\pc\mod\')) { if ($ext -eq '.archive') { return 'archive' } elseif ($ext -in '.xl', '.archivexl') { return 'xl' } else { return 'other' } }
    if ($r.StartsWith('archive\')) { return 'archive' }
    if ($r.StartsWith('mods\')) { return 'redmod' }
    if ($r.StartsWith('r6\scripts\')) { if ($ext -eq '.reds') { return 'redscript' } else { return 'config' } }
    if ($r.StartsWith('r6\tweaks\')) { return 'tweak' }
    if ($r.StartsWith('r6\input\')) { return 'input' }
    if ($r.StartsWith('r6\')) { return 'config' }
    if ($r.StartsWith('bin\x64\plugins\cyber_engine_tweaks\mods\')) { return 'cet' }
    if ($r.StartsWith('red4ext\plugins\')) { if ($ext -eq '.dll') { return 'native' } else { return 'plugindata' } }
    if ($r.StartsWith('red4ext\')) { return 'framework' }
    if ($ext -eq '.asi') { return 'native' }
    if ($r.StartsWith('bin\x64\')) { if ($ext -eq '.dll') { return 'loader' } elseif ($ext -in '.ini', '.json', '.toml') { return 'config' } else { return 'framework' } }
    if ($r.StartsWith('engine\config\')) { return 'config' }
    if ($r.StartsWith('engine\')) { return 'framework' }
    'other'
}
function Get-ModKinds($Files) { @(@($Files) | Where-Object { $_ } | ForEach-Object { Get-FileKind $_ } | Where-Object { $_ -notin 'docs', 'other' } | Sort-Object -Unique) }

# file / folder / file name -> owning mod, for attributing log lines and crash modules
function Get-OwnerMaps($S) {
    $file = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dir = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $leaf = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $S.mods) {
        foreach ($f in @($m.files)) {
            $f = "$f"
            if (-not $f) { continue }
            if (-not $file.ContainsKey($f)) { $file[$f] = $m.name }
            $l = [IO.Path]::GetFileName($f)
            if (-not $leaf.ContainsKey($l)) { $leaf[$l] = $m.name }
            $p = [IO.Path]::GetDirectoryName($f)
            while ($p) { if (-not $dir.ContainsKey($p)) { $dir[$p] = $m.name }; $p = [IO.Path]::GetDirectoryName($p) }
        }
    }
    [ordered]@{ file = $file; dir = $dir; leaf = $leaf }
}
function Get-RelGamePath([string]$Full) {
    $g = (Get-CpPaths).game
    $f = "$Full" -replace '/', '\'
    if ($f.StartsWith($g + '\', [StringComparison]::OrdinalIgnoreCase)) { $f.Substring($g.Length + 1) } else { $null }
}

function Get-SavedGamesDir {
    # test hook: a sandbox server must never write to the real saves
    if ($env:CPMODS_SAVES) { return $env:CPMODS_SAVES }
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue).'{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}'
    if ($v) { [Environment]::ExpandEnvironmentVariables($v) } else { Join-Path $env:USERPROFILE 'Saved Games' }
}

# Named folders the UI can open
function Get-GameLocations {
    $p = Get-CpPaths; $g = $p.game
    [ordered]@{
        game      = $g
        mods      = Join-Path $g 'archive\pc\mod'
        scripts   = Join-Path $g 'r6\scripts'
        tweaks    = Join-Path $g 'r6\tweaks'
        input     = Join-Path $g 'r6\input'
        cet       = Join-Path $g 'bin\x64\plugins\cyber_engine_tweaks\mods'
        red4ext   = Join-Path $g 'red4ext\plugins'
        logs      = Join-Path $g 'red4ext\logs'
        crashes   = Join-Path $env:LOCALAPPDATA 'REDEngine\ReportQueue'
        saves     = Join-Path (Get-SavedGamesDir) 'CD Projekt Red\Cyberpunk 2077'
        config    = $(if ($env:CPMODS_CONFIG) { $env:CPMODS_CONFIG } else { Join-Path $env:LOCALAPPDATA 'CD Projekt Red\Cyberpunk 2077' })
        downloads = $p.downloads
        cpmods    = $p.root
    }
}

# Steam keeps per-game launch options in userdata\<id>\config\localconfig.vdf (read-only here)
function Get-SteamLaunchOptions {
    try {
        $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        $cfgs = @(Get-ChildItem -LiteralPath (Join-Path $sp 'userdata') -Directory -ErrorAction Stop | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'config\localconfig.vdf') -ErrorAction SilentlyContinue } | Where-Object { $_ } | Sort-Object LastWriteTime -Descending)
        foreach ($c in $cfgs) {
            $t = Read-SharedText $c.FullName
            foreach ($m in [regex]::Matches($t, '"1091500"\s*\{')) {
                $i = $m.Index + $m.Length; $depth = 1; $start = $i
                while ($i -lt $t.Length -and $depth -gt 0) {
                    $ch = $t[$i]
                    if ($ch -eq '"') { $i++; while ($i -lt $t.Length -and $t[$i] -ne '"') { if ($t[$i] -eq '\') { $i++ }; $i++ } }
                    elseif ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') { $depth-- }
                    $i++
                }
                $lo = [regex]::Match($t.Substring($start, $i - $start), '"LaunchOptions"\s*"((?:[^"\\]|\\.)*)"')
                if ($lo.Success) { return [ordered]@{ found = $true; value = ($lo.Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\') } }
            }
        }
        [ordered]@{ found = $false; value = '' }
    }
    catch { $null }
}
#endregion

#region install preview (archive contents: Get-ArchiveFileList in cpmods.psm1)
# Where each file of an archive would be installed (same rule as the install: Get-LayoutPlan), without extracting
function Get-ArchivePlan([string]$Archive, [string]$Sub, [string]$ModName) {
    $all = @(Get-ArchiveFileList $Archive)
    $res = [ordered]@{ archive = [IO.Path]::GetFileName($Archive); count = $all.Count; size = [long](($all | Measure-Object size -Sum).Sum); files = @(); skipped = @(); fomod = $false; variants = @(); error = $null }
    $ents = $all
    if ($Sub) {
        $pre = $Sub.TrimEnd('\') + '\'
        $ents = @($all | Where-Object { $_.path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [pscustomobject]@{ path = $_.path.Substring($pre.Length); size = $_.size } })
    }
    $size = @{}; foreach ($e in $ents) { $size[$e.path] = $e.size }
    $plan = Get-LayoutPlan @($ents | ForEach-Object { $_.path }) $ModName
    if ($plan.fomod) { $res.fomod = $true; $res.error = 'This archive has an installer with options. Pick an option folder in Downloads first.'; return $res }
    if ($plan.variants) { $res.variants = $plan.variants; $res.error = 'This archive holds several versions. Pick one in Downloads first.'; return $res }
    $res.files = @($plan.files | ForEach-Object { [ordered]@{ src = $_.From; path = $_.Rel; size = $size[$_.From] } })
    $res.skipped = @($plan.skipped | Select-Object -First 200)
    if (-not $res.files.Count) { $res.error = 'cpmods does not recognize the layout of this archive.' }
    $res
}

# Archive preview for the Downloads page: planned files plus clashes with what is already installed
function Get-DownloadPreview([string]$Leaf, [string]$Sub, [string]$Name) {
    $a = Resolve-DownloadFile $Leaf
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($a) }
    $s = Get-State
    $maps = Get-OwnerMaps $s
    $g = (Get-CpPaths).game
    $plan = Get-ArchivePlan $a $Sub $Name
    $plan.files = @(foreach ($f in $plan.files) {
            $f.kind = Get-FileKind $f.path
            $f.exists = Test-Path -LiteralPath (Join-Path $g $f.path)
            $f.owner = if ($maps.file.ContainsKey($f.path)) { $maps.file[$f.path] } else { $null }
            $f
        })
    $plan
}
#endregion

#region mod details
function Get-ModDetail([string]$Name) {
    $s = Get-State
    $g = (Get-CpPaths).game
    $m = $s.mods | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    $on = [bool]$m
    if (-not $m) { $m = $s.disabled | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
    if (-not $m) { throw "Not in the library: $Name" }
    $others = @{}
    foreach ($o in $s.mods) {
        if ($o.name -eq $m.name) { continue }
        foreach ($f in @($o.files)) { $k = "$f".ToLower(); if (-not $others[$k]) { $others[$k] = [Collections.Generic.List[string]]::new() }; $others[$k].Add($o.name) }
    }
    $list = @($m.files | Where-Object { $_ })
    $planned = $false; $plan = $null; $sizes = @{}
    if (-not $on -and -not $list.Count -and $m.archive -and (Test-Path -LiteralPath $m.archive)) {
        try { $plan = Get-ArchivePlan $m.archive $m.sub $m.name; $list = @($plan.files | ForEach-Object { $_.path }); foreach ($f in $plan.files) { $sizes[$f.path] = $f.size }; $planned = $true } catch { }
    }
    $total = [long]0
    $files = foreach ($f in $list) {
        $fi = [IO.FileInfo]::new((Join-Path $g $f))
        $size = if ($fi.Exists) { $fi.Length } elseif ($sizes.ContainsKey($f)) { [long]$sizes[$f] } else { $null }
        if ($size) { $total += $size }
        $sh = $others["$f".ToLower()]
        [ordered]@{ path = $f; kind = Get-FileKind $f; size = $size; exists = $fi.Exists; shared = @(if ($sh) { $sh }); backup = (@($m.backups) -contains $f) }
    }
    $arch = $null
    if ($m.archive) {
        $ai = [IO.FileInfo]::new("$($m.archive)")
        $arch = [ordered]@{ file = $ai.Name; exists = $ai.Exists; size = $(if ($ai.Exists) { $ai.Length } else { $null }); date = $(if ($ai.Exists) { $ai.LastWriteTime.ToString('s') } else { $null }) }
    }
    [ordered]@{
        name = $m.name; version = $m.version; source = $m.source; modId = $m.modId; fileId = $m.fileId; fileName = $m.fileName
        on = $on; adopted = [bool]$m.adopted; installed = $m.installed; disabledAt = $m.disabledAt; sub = $m.sub; broken = $m.broken
        archive = $arch; files = @($files); planned = $planned; total = $total; backups = @($m.backups); parked = $m.parked; sha256 = $m.sha256
    }
}

# Every enabled mod's file list (Library map view)
function Get-LibraryFiles {
    $s = Get-State
    @(foreach ($m in $s.mods) { [ordered]@{ name = $m.name; modId = $m.modId; files = @($m.files) } })
}
#endregion

#region game sessions (RED4ext log = one file per launch)
function Read-R4Session([IO.FileInfo]$File) {
    $o = [ordered]@{ log = $File.Name; start = $null; end = $null; exitAt = $null; clean = $false; version = $null; product = $null; fileVersion = $null
        plugins = [Collections.Generic.List[object]]::new(); count = $null; problems = [Collections.Generic.List[object]]::new(); scc = $null; sccText = $null
    }
    $cur = $null
    foreach ($l in (Read-SharedLines $File.FullName)) {
        if (-not $l) { continue }
        $m = [regex]::Match($l, '^\[([^\]]*)\]\s*\[([^\]]*)\]\s*\[([^\]]*)\]\s*\[([^\]]*)\]\s*(.*)$')
        if (-not $m.Success) { continue }
        $t = Get-LineTime $l
        if ($t) { if (-not $o.start) { $o.start = $t }; $o.end = $t }
        $lvl = $m.Groups[2].Value.Trim().ToLower(); $msg = $m.Groups[5].Value
        if ($msg -match '^RED4ext \(v([\w.\-]+)\) is initializing') { $o.version = $Matches[1] }
        elseif ($msg -match '^Product version: (.+)$') { $o.product = $Matches[1].Trim() }
        elseif ($msg -match '^File version: (.+)$') { $o.fileVersion = $Matches[1].Trim() }
        elseif ($msg -match "^Loading plugin from '(.+)'") { $cur = $Matches[1] }
        elseif ($msg -match '^(.+) \(version: (.*?), author\(s\): (.*)\) has been loaded') { $o.plugins.Add([ordered]@{ name = $Matches[1]; version = $Matches[2]; author = $Matches[3]; path = $cur }) }
        elseif ($msg -match '^(\d+) plugin\(s\) loaded') { $o.count = [int]$Matches[1] }
        elseif ($msg -match '^scc invoked successfully') { $o.scc = 'ok' }
        elseif ($msg -match '(?i)\bscc\b' -and $lvl -match 'err|warn|crit') { $o.scc = 'failed'; $o.sccText = $msg }
        elseif ($msg -match 'is shutting down') { $o.exitAt = $t }
        elseif ($msg -match 'has been shut down') { $o.clean = $true }
        if ($lvl -match '^(warn|warning|error|err|critical|crit)$') {
            $pp = if ($msg -match "'([^']+\.dll)'") { $Matches[1] } else { $cur }
            $o.problems.Add([ordered]@{ level = $(if ($lvl -like 'warn*') { 'warn' } else { 'error' }); text = $msg; path = $pp })
        }
    }
    $o
}

function Get-R4Sessions {
    $dir = Join-Path (Get-CpPaths).game 'red4ext\logs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'red4ext-*.log' -File | Sort-Object Name)) {
        $x = try { Read-R4Session $f } catch { $null }
        if ($x -and $x.start) { $x }
    }
}

function Get-CrashFolders {
    $dir = Join-Path $env:LOCALAPPDATA 'REDEngine\ReportQueue'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object Name -Match '^Cyberpunk2077-(\d{8})-(\d{6})' | Sort-Object Name -Descending)) {
        $null = $d.Name -match '^Cyberpunk2077-(\d{8})-(\d{6})'
        [pscustomobject]@{ id = $d.Name; dir = $d.FullName; time = [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture) }
    }
}

# clean / crash / running / ended (log stops without a crash report: killed, or crashed before reporting)
function Get-SessionResult($Ses, $Crashes, $NextStart, [bool]$IsLast, [bool]$Running) {
    $limit = if ($NextStart) { $NextStart } else { $Ses.end.AddMinutes(5) }
    $cr = @($Crashes | Where-Object { $_.time -ge $Ses.start.AddSeconds(-5) -and $_.time -le $limit } | Sort-Object time)[0]
    $res = if ($Ses.clean) { 'clean' } elseif ($cr) { 'crash' } elseif ($IsLast -and $Running) { 'running' } else { 'ended' }
    $endAt = switch ($res) { 'clean' { if ($Ses.exitAt) { $Ses.exitAt } else { $Ses.end } } 'crash' { $cr.time } 'running' { Get-Date } default { $Ses.end } }
    [ordered]@{ result = $res; crash = $(if ($cr) { $cr.id } else { $null }); endAt = $endAt; seconds = [int]([Math]::Max(0, ($endAt - $Ses.start).TotalSeconds)) }
}

# Cheap summary for the state poll: last launch start / result
function Get-LaunchBrief {
    $g = (Get-CpPaths).game
    $f = Get-ChildItem -LiteralPath (Join-Path $g 'red4ext\logs') -Filter 'red4ext-*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    $crashes = @(Get-CrashFolders)
    $running = [bool](Get-Process -Name Cyberpunk2077 -ErrorAction SilentlyContinue)
    $o = [ordered]@{ log = $null; start = $null; end = $null; result = $null; seconds = $null; crash = $null; lastCrash = $(if ($crashes.Count) { $crashes[0].id } else { $null }); lastCrashAt = $(if ($crashes.Count) { ConvertTo-Iso $crashes[0].time } else { $null }); running = $running }
    if (-not $f) { return $o }
    $ses = Read-R4Session $f
    if (-not $ses.start) { return $o }
    $r = Get-SessionResult $ses $crashes $null $true $running
    $o.log = $f.Name; $o.start = ConvertTo-Iso $ses.start; $o.result = $r.result; $o.crash = $r.crash
    # while the game runs these change every second: left empty so polls see nothing new (no rebuild, no redraw)
    if ($r.result -ne 'running') { $o.end = ConvertTo-Iso $r.endAt; $o.seconds = $r.seconds }
    $o
}
#endregion

#region crash reports
# Exception, faulting module and modules found on the crashed thread's stack (scan residue: hints only)
function Read-MiniDump([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 64 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'MDMP') { return $null }
    $n = [BitConverter]::ToUInt32($b, 8); $dr = [int][BitConverter]::ToUInt32($b, 12)
    $st = @{}
    for ($i = 0; $i -lt $n; $i++) {
        $o = $dr + $i * 12
        $t = [int][BitConverter]::ToUInt32($b, $o)
        if ($t -and -not $st.ContainsKey($t)) { $st[$t] = @([int][BitConverter]::ToUInt32($b, $o + 4), [int][BitConverter]::ToUInt32($b, $o + 8)) }
    }
    if (-not $st.ContainsKey(4) -or -not $st.ContainsKey(6)) { return $null }
    $mods = [Collections.Generic.List[object]]::new()
    $r = $st[4][1]; $mn = [BitConverter]::ToUInt32($b, $r)
    $lo = [uint64]::MaxValue; $hi = [uint64]0
    for ($i = 0; $i -lt $mn; $i++) {
        $o = $r + 4 + $i * 108
        $base = [BitConverter]::ToUInt64($b, $o)
        $end = $base + [uint64][BitConverter]::ToUInt32($b, $o + 8)
        $nr = [int][BitConverter]::ToUInt32($b, $o + 20)
        $len = [int][BitConverter]::ToUInt32($b, $nr)
        $mods.Add([pscustomobject]@{ base = $base; end = $end; path = [Text.Encoding]::Unicode.GetString($b, $nr + 4, $len) })
        if ($base -lt $lo) { $lo = $base }; if ($end -gt $hi) { $hi = $end }
    }
    $find = { param([uint64]$a) foreach ($x in $mods) { if ($a -ge $x.base -and $a -lt $x.end) { return $x } }; $null }
    $e = $st[6][1]
    $tid = [BitConverter]::ToUInt32($b, $e)
    $code = [BitConverter]::ToUInt32($b, $e + 8)
    $addr = [BitConverter]::ToUInt64($b, $e + 24)
    $np = [BitConverter]::ToUInt32($b, $e + 32)
    $p0 = if ($np -ge 1) { [BitConverter]::ToUInt64($b, $e + 40) } else { $null }
    $p1 = if ($np -ge 2) { [BitConverter]::ToUInt64($b, $e + 48) } else { $null }
    $ctx = [int][BitConverter]::ToUInt32($b, $e + 164)
    $rsp = [BitConverter]::ToUInt64($b, $ctx + 0x98)
    $fm = & $find $addr
    $res = [ordered]@{
        code = ('0x{0:X8}' -f $code); address = ('0x{0:X}' -f $addr)
        module = $(if ($fm) { [IO.Path]::GetFileName($fm.path) } else { $null }); modulePath = $(if ($fm) { $fm.path } else { $null })
        offset = $(if ($fm) { '0x{0:X}' -f ($addr - $fm.base) } else { $null })
        access = $(if ($code -eq [uint32]3221225477 -and $null -ne $p0) { @{ 0 = 'read'; 1 = 'write'; 8 = 'execute' }[[int]$p0] } else { $null })
        target = $(if ($null -ne $p1) { '0x{0:X}' -f $p1 } else { $null })
        stack = @(); modules = @()
    }
    # every loaded module (REDEngine dumps often store bare file names, so owners are matched by name later)
    $res.modules = @($mods | ForEach-Object { $_.path })
    # stack of the crashed thread: thread list, then memory lists
    $sStart = [uint64]0; $sSize = [uint64]0; $sRva = [uint64]0
    if ($st.ContainsKey(3)) {
        $t = $st[3][1]; $tn = [BitConverter]::ToUInt32($b, $t)
        for ($i = 0; $i -lt $tn; $i++) {
            $o = $t + 4 + $i * 48
            if ([BitConverter]::ToUInt32($b, $o) -eq $tid) { $sStart = [BitConverter]::ToUInt64($b, $o + 24); $sSize = [BitConverter]::ToUInt32($b, $o + 32); $sRva = [BitConverter]::ToUInt32($b, $o + 36); break }
        }
    }
    if (-not $sRva -and $st.ContainsKey(5)) {
        $ml = $st[5][1]; $cnt = [BitConverter]::ToUInt32($b, $ml)
        for ($j = 0; $j -lt $cnt; $j++) {
            $d = $ml + 4 + $j * 16
            $ms = [BitConverter]::ToUInt64($b, $d); $mz = [uint64][BitConverter]::ToUInt32($b, $d + 8)
            if ($rsp -ge $ms -and $rsp -lt $ms + $mz) { $sStart = $ms; $sSize = $mz; $sRva = [BitConverter]::ToUInt32($b, $d + 12); break }
        }
    }
    if (-not $sRva -and $st.ContainsKey(9)) {
        $ml = $st[9][1]; $cnt = [BitConverter]::ToUInt64($b, $ml); $cur = [BitConverter]::ToUInt64($b, $ml + 8)
        for ($j = 0; $j -lt $cnt; $j++) {
            $d = $ml + 16 + $j * 16
            $ms = [BitConverter]::ToUInt64($b, $d); $mz = [BitConverter]::ToUInt64($b, $d + 8)
            if ($rsp -ge $ms -and $rsp -lt $ms + $mz) { $sStart = $ms; $sSize = $mz; $sRva = $cur; break }
            $cur += $mz
        }
    }
    if ($sRva -and $rsp -ge $sStart) {
        $off = [long]($rsp - $sStart)
        $stop = [long][Math]::Min([double]$sSize, [double]($off + 0x3000)) - 8
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $frames = [Collections.Generic.List[object]]::new()
        for ($q = $off; $q -le $stop -and ([long]$sRva + $q + 8) -le $b.Length; $q += 8) {
            $v = [BitConverter]::ToUInt64($b, [int]([long]$sRva + $q))
            if ($v -lt $lo -or $v -ge $hi) { continue }
            $x = & $find $v
            if (-not $x) { continue }
            $leaf = [IO.Path]::GetFileName($x.path)
            if ($seen.Add($leaf)) { $frames.Add([ordered]@{ module = $leaf; path = $x.path; offset = ('0x{0:X}' -f ($v - $x.base)) }) }
            if ($frames.Count -ge 24) { break }
        }
        $res.stack = @($frames)
    }
    $res
}

function Read-CrashText([string]$Dir) {
    $o = [ordered]@{ reason = $null; expression = $null; message = $null; uptime = $null; stage = $null; world = $null; loadingSave = $null; gpu = $null; driver = $null; oom = $null; patch = $null }
    $stp = Join-Path $Dir 'stacktrace.txt'
    if (Test-Path -LiteralPath $stp) {
        foreach ($l in (Read-SharedLines $stp)) {
            if ($l -match '^Error reason: (.+)$') { $o.reason = $Matches[1].Trim() }
            elseif ($l -match '^Expression: (.+)$') { $o.expression = $Matches[1].Trim() }
            elseif ($l -match '^Message: (.+)$') { $o.message = $Matches[1].Trim() }
        }
    }
    $att = Get-FirstEntry (Join-Path $Dir 'attch') '*.txt' -File
    if ($att) {
        foreach ($l in (Read-SharedLines $att)) {
            if ($l -notmatch '^"([^"@]+)(?:@[^"]*)?":"?(.*?)"?\s*$') { continue }
            $k = $Matches[1]; $v = $Matches[2]
            switch ($k) {
                'uptimeSeconds' { $o.uptime = [int]$v }
                'Game/LoadingStage' { $o.stage = $v }
                'Game/SessionDesc/WorldName' { $o.world = $v }
                'Game/SessionDesc/IsLoadingSavedSession' { $o.loadingSave = $v }
                'Gpu/Device/Name' { $o.gpu = $v }
                'Gpu/Device/DriverVersion' { $o.driver = $v }
                'Engine/OOM' { $o.oom = $v }
                'Game/Patch' { $o.patch = $v }
            }
        }
    }
    $o
}

# Parsed crash reports, cached in state\crashes.json (a dump is read once)
function Get-CrashList([int]$Max = 12) {
    $folders = @(Get-CrashFolders | Select-Object -First $Max)
    $cf = Join-Path (Get-CpPaths).state 'crashes.json'
    $cache = @{}
    if (Test-Path -LiteralPath $cf) { try { $cache = Read-JsonFile $cf } catch { $cache = @{} } }
    if ($cache -isnot [Collections.IDictionary]) { $cache = @{} }
    $dirty = $false
    foreach ($f in $folders) {
        if ($cache.Contains($f.id) -and $cache[$f.id].v -eq 3) { continue }
        $info = [ordered]@{ v = 3; id = $f.id; time = ConvertTo-Iso $f.time }
        $txt = try { Read-CrashText $f.dir } catch { $null }
        if ($txt) { foreach ($k in $txt.Keys) { $info[$k] = $txt[$k] } }
        $dmp = Get-FirstEntry $f.dir '*.dmp' -File
        if ($dmp) { $d = try { Read-MiniDump $dmp } catch { $null }; if ($d) { $info.dump = $d } }
        $cache[$f.id] = $info
        $dirty = $true
    }
    if ($dirty) { try { Write-JsonFile $cf $cache } catch { } }
    $s = Get-State
    $maps = Get-OwnerMaps $s
    # module -> owning mod: by game-relative path when the dump has full paths, else by file name of a mod's .dll / .asi
    $own = {
        param($p)
        $rel = Get-RelGamePath $p
        if ($rel) { if ($maps.file.ContainsKey($rel)) { return $maps.file[$rel] } else { return $null } }
        $leaf = [IO.Path]::GetFileName("$p")
        if ($leaf -match '(?i)\.(dll|asi)$' -and $maps.leaf.ContainsKey($leaf)) { return $maps.leaf[$leaf] }
        $null
    }
    $list = foreach ($f in $folders) {
        $c = $cache[$f.id]
        $d = $c.dump
        $sig = if ($d -and $d.module) { "$($d.module)+$($d.offset)" } else { $null }
        $when = if ("$($c.world)" -match 'main_menu') { 'at the main menu' } elseif ("$($c.loadingSave)" -eq 'true') { 'while a save was loading' } elseif ($c.uptime -and $c.uptime -lt 90) { 'during startup' } else { 'during play' }
        [ordered]@{
            id = $f.id; time = $c.time; reason = $c.reason; expression = $c.expression; message = $c.message; uptime = $c.uptime; stage = $c.stage; world = $c.world; when = $when
            gpu = $c.gpu; driver = $c.driver; oom = $c.oom; patch = $c.patch; signature = $sig
            module = $(if ($d) { $d.module } else { $null }); offset = $(if ($d) { $d.offset } else { $null }); access = $(if ($d) { $d.access } else { $null }); target = $(if ($d) { $d.target } else { $null })
            moduleMod = $(if ($d -and $d.modulePath) { & $own $d.modulePath } else { $null })
            stack = @(if ($d) { foreach ($x in @($d.stack)) { [ordered]@{ module = $x.module; offset = $x.offset; mod = (& $own $x.path); game = [bool](Get-RelGamePath $x.path) } } })
            plugins = @(if ($d) { foreach ($p in @($d.modules)) { $o = & $own $p; if ($o) { [ordered]@{ file = [IO.Path]::GetFileName($p); mod = $o } } } })
            same = 0
        }
    }
    $list = @($list)
    foreach ($c in $list) { if ($c.signature) { $c.same = @($list | Where-Object { $_.signature -eq $c.signature }).Count - 1 } }
    $list
}
#endregion

#region launch report
function Get-ProblemLines([string]$Path, [int]$Max = 25) {
    $out = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($l in (Read-SharedLines $Path)) {
        if ($l -notmatch '(?i)\[\s*(warn|warning|error|err|critical|crit|fatal)\s*\]') { continue }
        $lvl = if ($Matches[1] -like 'warn*') { 'warn' } else { 'error' }
        $msg = ($l -replace '^(\s*\[[^\]]*\])+\s*', '').Trim()
        if (-not $msg -or -not $seen.Add($msg)) { continue }
        $out.Add([ordered]@{ level = $lvl; text = $msg })
        if ($out.Count -ge $Max) { break }
    }
    , $out
}

function Read-RedscriptLog([datetime]$Start, [datetime]$End) {
    $p = Join-Path (Get-CpPaths).game 'r6\logs\redscript_rCURRENT.log'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $lines = Read-SharedLines $p
    $first = $null
    foreach ($l in $lines) { if ($l -match '^\[\w+ - \w+, (\d+ \w+ \d{4} \d{2}:\d{2}:\d{2})') { $first = [datetime]::ParseExact($Matches[1], 'd MMM yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); break } }
    $o = [ordered]@{ thisLaunch = $false; at = (ConvertTo-Iso $first); status = 'unknown'; files = @(); errors = @(); warnings = @() }
    if (-not $first -or $first -lt $Start.AddMinutes(-2) -or $first -gt $End.AddMinutes(2)) { return $o }
    $o.thisLaunch = $true
    $files = [Collections.Generic.List[string]]::new()
    $errs = [Collections.Generic.List[object]]::new(); $warns = [Collections.Generic.List[object]]::new()
    $inList = $false; $blk = $null
    foreach ($l in $lines) {
        if ($l -match '^\[(INFO|WARN|WARNING|ERROR|DEBUG) - [^\]]*\]\s*(.*)$') {
            $lv = $Matches[1]; $msg = $Matches[2]
            $inList = $msg -match '^Compiling files in'
            $blk = $null
            if ($lv -eq 'ERROR') { $blk = [ordered]@{ level = 'error'; text = $msg; more = [Collections.Generic.List[string]]::new() }; $errs.Add($blk) }
            elseif ($lv -like 'WARN*') { $blk = [ordered]@{ level = 'warn'; text = $msg; more = [Collections.Generic.List[string]]::new() }; $warns.Add($blk) }
            if ($msg -match '^Compilation complete') { $o.status = 'ok' }
            elseif ($msg -match '(?i)compilation failed|failed to compile') { $o.status = 'failed' }
            continue
        }
        if ($inList -and $l.Trim()) { $files.Add('r6\scripts\' + $l.Trim()); continue }
        if ($blk -and $l.Trim() -and $blk.more.Count -lt 8) { $blk.more.Add($l.TrimEnd()) }
    }
    if ($o.status -eq 'unknown' -and $errs.Count) { $o.status = 'failed' }
    $o.files = @($files)
    $fix = { param($b) $all = (@($b.text) + @($b.more)) -join "`n"
        $f = $null
        if ($all -match '(?i)([a-z]:\\[^\r\n:]+?\.reds)') { $f = Get-RelGamePath $Matches[1] }
        elseif ($all -match '(?i)(r6\\scripts\\[^\r\n:]+?\.reds)') { $f = $Matches[1] }
        [ordered]@{ level = $b.level; text = $b.text; more = @($b.more); file = $f } }
    $o.errors = @($errs | ForEach-Object { & $fix $_ })
    $o.warnings = @($warns | Select-Object -First 30 | ForEach-Object { & $fix $_ })
    $o
}

function Read-CetSession([datetime]$Start, [datetime]$End) {
    $dir = Join-Path (Get-CpPaths).game 'bin\x64\plugins\cyber_engine_tweaks'
    $main = Join-Path $dir 'cyber_engine_tweaks.log'
    if (-not (Test-Path -LiteralPath $main)) { return $null }
    $o = [ordered]@{ version = $null; ran = $false; loaded = @(); errors = @() }
    $lines = Read-SharedLines $main
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'CET version (v[\w.\-]+)') {
            $t = Get-LineTime $lines[$i]
            if ($t -and $t -ge $Start.AddSeconds(-20) -and $t -le $End.AddMinutes(1)) { $o.version = $Matches[1]; $o.ran = $true }
            break
        }
    }
    $sl = Join-Path $dir 'scripting.log'
    $loaded = [Collections.Generic.List[string]]::new()
    $errs = [Collections.Generic.List[object]]::new()
    $rx = '(?i)\berror\b|attempt to (index|call|compare|perform|concatenate)|stack traceback|\bfailed\b|exception|unable to|could not'
    if (Test-Path -LiteralPath $sl) {
        $sLines = Read-SharedLines $sl
        $from = $sLines.Count
        # a session that ended mid-write leaves its last line unfinished, so the next launch's first line is glued onto it: use the last time stamp in a line
        for ($i = $sLines.Count - 1; $i -ge 0; $i--) {
            $all = [regex]::Matches($sLines[$i], '\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
            if ($all.Count) { $t = [datetime]::ParseExact($all[$all.Count - 1].Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); if ($t -lt $Start.AddSeconds(-5)) { break } }
            $from = $i
        }
        $seen = [Collections.Generic.HashSet[string]]::new()
        for ($i = $from; $i -lt $sLines.Count; $i++) {
            $l = $sLines[$i]
            $t = Get-LineTime $l
            if ($t -and $t -gt $End.AddMinutes(1)) { break }
            if ($l -match "Mod (.+?) loaded! \('(.+?)'\)") { $loaded.Add([IO.Path]::GetFileName($Matches[2].TrimEnd('\'))); $o.ran = $true; continue }
            if ($i -eq $from -and ([regex]::Matches($l, '\[\d{4}-\d{2}-\d{2} ')).Count -gt 1) { continue }
            if ($l -match $rx) {
                $msg = ($l -replace '^(\s*\[[^\]]*\])+\s*', '').Trim()
                # "stack traceback:" only announces the frames below the real error line
                if ($msg -and $msg -ne 'stack traceback:' -and $seen.Add($msg) -and $errs.Count -lt 30) { $errs.Add([ordered]@{ level = 'error'; text = $msg; log = 'bin\x64\plugins\cyber_engine_tweaks\scripting.log'; dir = $(if ($l -match '(?i)\\mods\\([^\\]+)\\') { $Matches[1] } elseif ($msg -match '^\[([^\]]+)\]') { $Matches[1] } else { $null }) }) }
            }
        }
    }
    $md = Join-Path $dir 'mods'
    if (Test-Path -LiteralPath $md) {
        foreach ($f in @(Get-ChildItem -LiteralPath $md -Directory | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName "$($_.Name).log") -ErrorAction SilentlyContinue } | Where-Object { $_ -and $_.Length -gt 0 -and $_.LastWriteTime -ge $Start.AddSeconds(-5) })) {
            $n = 0; $cur = $null
            $rel = "bin\x64\plugins\cyber_engine_tweaks\mods\$($f.Directory.Name)\$($f.Name)"
            foreach ($l in (Read-SharedLines $f.FullName)) {
                # lines without a time stamp (traceback frames) belong to the last stamped line, so old sessions stay out
                $t = Get-LineTime $l
                if ($t) { $cur = $t }
                if ($l -notmatch $rx -or ($cur -and $cur -lt $Start.AddSeconds(-5))) { continue }
                $msg = ($l -replace '^(\s*\[[^\]]*\])+\s*', '').Trim()
                if ($msg -and $msg -ne 'stack traceback:') { $errs.Add([ordered]@{ level = 'error'; text = $msg; log = $rel; dir = $f.Directory.Name }); $n++ }
                if ($n -ge 8) { break }
            }
        }
    }
    $o.loaded = @($loaded | Sort-Object -Unique)
    $o.errors = @($errs)
    $o
}

# Problems in plugin logs written during the launch, with the plugin folder each log belongs to
function Read-PluginLogs([datetime]$Start, [datetime]$End) {
    $g = (Get-CpPaths).game
    $plugDir = Join-Path $g 'red4ext\plugins'
    $folders = @(Get-ChildItem -LiteralPath $plugDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    $norm = { param($x) ("$x".ToLower() -replace '[^a-z0-9]', '') }
    $byNorm = @{}
    foreach ($f in $folders) { $byNorm[(& $norm $f)] = $f }
    $out = [Collections.Generic.List[object]]::new()
    $cands = @(Get-ChildItem -LiteralPath (Join-Path $g 'red4ext\logs') -File -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'red4ext-*' }) + @(Get-ChildItem -LiteralPath $plugDir -Recurse -Depth 2 -File -Filter *.log -ErrorAction SilentlyContinue)
    foreach ($f in $cands) {
        if ($f.LastWriteTime -lt $Start.AddSeconds(-5)) { continue }
        if ($f.BaseName -match '(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})$') {
            $ft = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
            if ($ft -lt $Start.AddSeconds(-10) -or $ft -gt $End.AddMinutes(1)) { continue }
        }
        $rel = [IO.Path]::GetRelativePath($g, $f.FullName)
        $folder = if ($rel -like 'red4ext\plugins\*') { ($rel -split '\\')[2] } else { $byNorm[(& $norm ($f.BaseName -replace '-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$', ''))] }
        $probs = Get-ProblemLines $f.FullName
        $out.Add([ordered]@{ log = $rel; name = $f.Name; folder = $folder; problems = @($probs); path = $f.FullName })
    }
    , $out
}

# Known messages that look alarming but do not need action
function Get-ProblemNote([string]$Folder, [string]$Text) {
    if ($Folder -eq 'TweakXL' -and $Text -match 'has hash collision with') { return 'Harmless: two database entries share a short internal name. TweakXL only notes it.' }
    if ($Folder -eq 'TweakXL' -and $Text -match 'Unknown property') { return 'A tweak sets a property this game version does not have, so that one edit is skipped. Usually harmless; the mod may be slightly outdated.' }
    if ($Folder -eq 'ArchiveXL' -and $Text -match "(?i)(\[QuestPhase\]|^Phase ).*doesn't exist") { return 'Harmless: a mod has an optional add-on for another mod you do not have, so ArchiveXL skips it.' }
    if ($Folder -eq 'ArchiveXL' -and $Text -match '(?i)skipped') { return 'ArchiveXL skipped one entry; the rest of the mod still loads.' }
    $null
}

# one log message across launches: source, mod and text without numbers (sizes, ids, addresses, line numbers change)
function Get-MessageSig($P) { "$($P.source)|$($P.mod)|" + ("$($P.text)".ToLower() -replace '0x[0-9a-f]+|[0-9a-f]{16,}|\d+', '#') }

# Sets .known on each problem: it also showed up in an earlier launch that closed normally, so it did not stop the
# game and is not flagged again; a new message is flagged once. Only clean launches teach.
# Record: state\known-messages.json, signature -> start of the first clean launch that had it.
# shortcut: the record only grows (one line per distinct message); prune it if it ever reaches thousands of entries
function Set-KnownMessages($Probs, [datetime]$Start, [bool]$Clean) {
    $f = Join-Path (Get-CpPaths).state 'known-messages.json'
    $known = if (Test-Path -LiteralPath $f) { try { Read-JsonFile $f } catch { $null } } else { $null }
    if ($known -isnot [Collections.IDictionary]) { $known = @{} }
    # launch start as ticks (JSON would turn ISO date strings back into dates)
    $at = $Start.Ticks; $learned = $false
    foreach ($p in $Probs) {
        $sig = Get-MessageSig $p
        if ($Clean -and -not $known.ContainsKey($sig)) { $known[$sig] = $at; $learned = $true }
        $p.known = $known.ContainsKey($sig) -and [long]$known[$sig] -lt $at
    }
    if ($learned) { try { Write-JsonFile $f $known } catch { } }
}

# other mods a log message points to: the mod a game file it names comes from
function Get-FileLinks([string]$Text, [string]$Mod, $Maps) {
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($x in [regex]::Matches($Text, '(?i)(?<![\w\\/])((?:r6|archive|bin|red4ext|engine|mods)[\\/][^\s''"():,]+\.[a-z0-9]{1,8})')) {
        $rel = $x.Groups[1].Value -replace '/', '\'
        $m = if ($Maps.file.ContainsKey($rel)) { $Maps.file[$rel] } else { $null }
        if ($m -and $m -ne $Mod -and $seen.Add($m)) { [ordered]@{ mod = $m; why = "$([IO.Path]::GetFileName($rel)) comes from this mod" } }
    }
}

# mods whose scripts also @replaceMethod the function annotated at $Rel:$Line (redscript keeps only one of them)
function Get-ReplaceRivals([string]$Rel, [int]$Line, [string]$Mod, $Maps, [hashtable]$Cache) {
    $g = (Get-CpPaths).game
    $read = { param($r) if (-not $Cache.ContainsKey($r)) { $Cache[$r] = try { Read-SharedText (Join-Path $g $r) } catch { '' } }; $Cache[$r] }
    $lines = (& $read $Rel) -split '\r?\n'
    $cls = $null; $fn = $null
    for ($i = [Math]::Max(0, $Line - 1); $i -lt [Math]::Min($lines.Count, $Line + 6); $i++) {
        if (-not $cls) { if ($lines[$i] -match '@replaceMethod\((\w+)\)') { $cls = $Matches[1] } }
        elseif ($lines[$i] -match '\bfunc\s+(\w+)') { $fn = $Matches[1]; break }
    }
    if (-not $fn) { return }
    $rx = '@replaceMethod\(' + [regex]::Escape($cls) + '\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*?func\s+' + [regex]::Escape($fn) + '\b'
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($k in @($Maps.file.Keys)) {
        if ($k -notlike 'r6\scripts\*.reds' -or $k -eq $Rel) { continue }
        $m = $Maps.file[$k]
        if ($m -ne $Mod -and -not $seen.Contains($m) -and (& $read $k) -match $rx) { [void]$seen.Add($m); [ordered]@{ mod = $m; why = "also replaces $cls.$fn; only one of the two is used" } }
    }
}

function Get-LaunchReport {
    $paths = Get-CpPaths; $g = $paths.game
    $s = Get-State
    $maps = Get-OwnerMaps $s
    $gameSt = try { Get-GameState } catch { $null }
    $running = [bool]($gameSt -and $gameSt.running)
    $sessions = @(Get-R4Sessions)
    $crashFolders = @(Get-CrashFolders)
    $crashes = @(Get-CrashList)
    $rep = [ordered]@{
        checked = (Get-Date).ToString('s'); game = $gameSt; none = (-not $sessions.Count); session = $null; history = @(); crashes = $crashes
        stages = @(); frameworks = [ordered]@{}; plugins = @(); scripts = $null; cet = $null; xl = $null; tweak = $null; input = $null
        mods = @(); issues = @(); untested = @(); steam = (Get-SteamLaunchOptions); logs = @()
    }
    $hist = for ($i = $sessions.Count - 1; $i -ge 0; $i--) {
        $x = $sessions[$i]
        $nextStart = if ($i -lt $sessions.Count - 1) { $sessions[$i + 1].start } else { $null }
        $r = Get-SessionResult $x $crashFolders $nextStart ($i -eq $sessions.Count - 1) $running
        [ordered]@{ log = $x.log; start = ConvertTo-Iso $x.start; end = ConvertTo-Iso $r.endAt; seconds = $r.seconds; result = $r.result; crash = $r.crash; plugins = $x.plugins.Count; version = $x.product }
    }
    $rep.history = @($hist)
    if (-not $sessions.Count) { return $rep }

    $last = $sessions[-1]
    $res = Get-SessionResult $last $crashFolders $null $true $running
    $start = $last.start
    $end = if ($res.result -eq 'running') { Get-Date } else { $last.end }
    $crash = if ($res.crash) { $crashes | Where-Object { $_.id -eq $res.crash } | Select-Object -First 1 } else { $null }
    $rep.session = [ordered]@{ log = $last.log; start = ConvertTo-Iso $start; end = ConvertTo-Iso $res.endAt; seconds = $res.seconds; result = $res.result; crash = $crash; red4ext = $last.version; product = $last.product; fileVersion = $last.fileVersion }

    # RED4ext plugins
    $loadedRel = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rep.plugins = @(foreach ($p in $last.plugins) {
            $rel = Get-RelGamePath $p.path
            if ($rel) { [void]$loadedRel.Add($rel) }
            [ordered]@{ name = $p.name; version = $p.version; author = $p.author; file = $rel; mod = $(if ($rel -and $maps.file.ContainsKey($rel)) { $maps.file[$rel] } else { $null }) }
        })
    $fwv = $rep.frameworks
    $fwv['RED4ext'] = $last.version
    foreach ($p in $last.plugins) { if ($p.name -in 'ArchiveXL', 'TweakXL', 'Codeware', 'Mod Settings', 'Input Loader') { $fwv[$p.name] = $p.version } }
    $rsMod = $s.mods | Where-Object { $_.name -eq 'redscript' } | Select-Object -First 1
    if ($rsMod) { $fwv['redscript'] = "$($rsMod.version)".TrimStart('v') }

    # every log problem becomes { source, level, text, mod, note, file it names, log it came from, other mods involved }
    $probs = [Collections.Generic.List[object]]::new()
    $addProb = { param($src, $lvl, $txt, $mod, $note, $file, $log, $links)
        if ($null -eq $links) { $links = @(Get-FileLinks $txt $mod $maps) }
        $probs.Add([ordered]@{ source = $src; level = $lvl; text = $txt; mod = $mod; note = $note; file = $file; log = $log; links = @($links) }) }
    $r4log = "red4ext\logs\$($last.log)"
    foreach ($p in $last.problems) {
        $rel = Get-RelGamePath $p.path
        $mod = if ($rel -and $maps.file.ContainsKey($rel)) { $maps.file[$rel] } else { $null }
        & $addProb 'RED4ext' $p.level $p.text $mod $null $rel $r4log
    }

    # plugin logs (ArchiveXL / TweakXL lines get attributed by content)
    $plugLogs = Read-PluginLogs $start $end
    $xlText = $null; $tweakText = $null
    $xlLoaded = [Collections.Generic.List[string]]::new()
    $inputDocs = [Collections.Generic.List[string]]::new()
    foreach ($lg in $plugLogs) {
        $folderMod = if ($lg.folder -and $maps.dir.ContainsKey("red4ext\plugins\$($lg.folder)")) { $maps.dir["red4ext\plugins\$($lg.folder)"] } else { $null }
        if ($lg.folder -eq 'ArchiveXL') { foreach ($l in (Read-SharedLines $lg.path)) { if ($l -match 'Loading "(.+?)"') { $xlLoaded.Add($Matches[1]) } } }
        if ($lg.folder -eq 'input_loader') { foreach ($l in (Read-SharedLines $lg.path)) { if ($l -match 'Loading document: (.+\.xml)\s*$') { $r = Get-RelGamePath ($Matches[1] -replace '/', '\'); if ($r) { $inputDocs.Add($r) } } } }
        foreach ($p in $lg.problems) {
            $mod = $folderMod
            if ($lg.folder -eq 'ArchiveXL') {
                if ($null -eq $xlText) { $xlText = @{}; foreach ($k in @($maps.file.Keys | Where-Object { $_ -match '\.(xl|archivexl)$' })) { try { $xlText[$k] = (Read-SharedText (Join-Path $g $k)) } catch { } } }
                $qs = @([regex]::Matches($p.text, '"([^"]{4,})"') | ForEach-Object { $_.Groups[1].Value })
                $hit = $null
                foreach ($q in $qs) { foreach ($k in $xlText.Keys) { if ($xlText[$k].IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $xlText[$k].IndexOf(($q -replace '\\', '/'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $maps.file[$k]; break } }; if ($hit) { break } }
                if ($hit) { $mod = $hit }
            }
            elseif ($lg.folder -eq 'TweakXL' -and $p.text -match '^([A-Za-z_][\w]*\.[\w.]+?)(?::| has )') {
                $rec = $Matches[1]
                if ($null -eq $tweakText) { $tweakText = @{}; foreach ($k in @($maps.file.Keys | Where-Object { $_ -match '\.(yaml|yml|tweak)$' })) { try { $tweakText[$k] = (Read-SharedText (Join-Path $g $k)) } catch { } } }
                $hit = $null
                # templated tweaks only spell the short record name (e.g. "- { v: v_bike_name }")
                $short = ($rec -split '\.', 2)[1]
                foreach ($needle in @($rec, $short)) {
                    if (-not $needle -or $needle.Length -lt 8) { continue }
                    foreach ($k in $tweakText.Keys) { if ($tweakText[$k].Contains($needle)) { $hit = $maps.file[$k]; break } }
                    if ($hit) { break }
                }
                $mod = $hit
            }
            & $addProb $(if ($lg.folder) { $lg.folder } else { $lg.name }) $p.level $p.text $mod (Get-ProblemNote $lg.folder $p.text) $null $lg.log
        }
    }
    $rep.logs = @($plugLogs | ForEach-Object { [ordered]@{ log = $_.log; folder = $_.folder; problems = @($_.problems).Count } })
    $rep.xl = [ordered]@{ extensions = @($xlLoaded | Sort-Object -Unique) }
    $rep.input = [ordered]@{ docs = @($inputDocs | Sort-Object -Unique) }

    # redscript
    $rs = Read-RedscriptLog $start $end
    $rep.scripts = $rs
    if ($rs -and $rs.thisLaunch) {
        $rsLog = 'r6\logs\redscript_rCURRENT.log'; $rsText = @{}
        foreach ($e in @($rs.errors) + @($rs.warnings)) {
            $mod = if ($e.file -and $maps.file.ContainsKey($e.file)) { $maps.file[$e.file] } else { $null }
            # "At <file>:<line>:<col>:", the code line, a ^^^ marker, then the message: shown message first, then where
            $more = @($e.more); $ci = -1; $ln = 0
            for ($k = 0; $k -lt $more.Count; $k++) { if ($more[$k] -match '^\s*\^+\s*$') { $ci = $k; break } }
            if ($e.text -match ':(\d+):\d+:\s*$' -and $ci -ge 1 -and $ci + 1 -lt $more.Count) {
                $ln = [int]$Matches[1]; $msg = $more[$ci + 1].Trim()
                $txt = "$($msg.Substring(0, 1).ToUpper())$($msg.Substring(1)) ($(if ($e.file) { $e.file -replace '^r6\\scripts\\', '' } else { 'script' }) line ${ln}: $($more[$ci - 1].Trim()))"
            }
            else { $txt = (@($e.text) + @($more | Select-Object -First 3) -join ' ') -replace [regex]::Escape("$g\"), '' }
            $links = if ($ln -and $e.file -and ($more -join ' ') -match '@replaceMethod\(') { @(Get-ReplaceRivals $e.file $ln $mod $maps $rsText) } else { $null }
            & $addProb 'redscript' $e.level $txt $mod $null $e.file $rsLog $links
        }
    }
    if ($last.scc -eq 'failed') { & $addProb 'RED4ext' 'error' "Script compiler: $($last.sccText)" $null $null $null $r4log }

    # Cyber Engine Tweaks
    $cet = Read-CetSession $start $end
    $rep.cet = $cet
    if ($cet) {
        if ($cet.version) { $fwv['Cyber Engine Tweaks'] = $cet.version.TrimStart('v') }
        foreach ($e in $cet.errors) {
            $mod = if ($e.dir -and $maps.dir.ContainsKey("bin\x64\plugins\cyber_engine_tweaks\mods\$($e.dir)")) { $maps.dir["bin\x64\plugins\cyber_engine_tweaks\mods\$($e.dir)"] } else { $null }
            & $addProb 'Cyber Engine Tweaks' $e.level $e.text $mod $null $null $e.log
        }
    }
    $rep.tweak = [ordered]@{ problems = @($probs | Where-Object { $_.source -eq 'TweakXL' }).Count }

    Set-KnownMessages $probs $start ($res.result -eq 'clean')

    # per-mod status
    $cetLoaded = [Collections.Generic.HashSet[string]]::new([string[]]@($(if ($cet) { $cet.loaded } else { @() })), [StringComparer]::OrdinalIgnoreCase)
    $xlSet = [Collections.Generic.HashSet[string]]::new([string[]]@($xlLoaded), [StringComparer]::OrdinalIgnoreCase)
    $compiled = [Collections.Generic.HashSet[string]]::new([string[]]@($(if ($rs -and $rs.thisLaunch) { $rs.files } else { @() })), [StringComparer]::OrdinalIgnoreCase)
    $docSet = [Collections.Generic.HashSet[string]]::new([string[]]@($inputDocs), [StringComparer]::OrdinalIgnoreCase)
    $untested = [Collections.Generic.List[string]]::new()
    $plugFail = [Collections.Generic.List[string]]::new()
    $order = @{ error = 0; warn = 1; new = 2; ok = 3; assets = 4 }
    $modsOut = foreach ($m in $s.mods) {
        $files = @($m.files | Where-Object { $_ })
        $kinds = @(Get-ModKinds $files)
        $notes = [Collections.Generic.List[object]]::new()
        $lvl = 'ok'
        $verified = $false
        $isNew = $false
        if ($m.installed) { try { $isNew = ([datetime]$m.installed) -gt $start } catch { } }
        $dlls = @($files | Where-Object { $_ -like 'red4ext\plugins\*.dll' })
        if ($dlls) {
            $hit = @($rep.plugins | Where-Object { $_.file -and $dlls -contains $_.file })
            if ($hit) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "RED4ext loaded $($hit[0].name) $($hit[0].version)" }) }
            elseif (-not $isNew -and $last.plugins.Count) { $lvl = 'error'; $plugFail.Add($m.name); $notes.Add([ordered]@{ level = 'error'; text = 'RED4ext did not load its plugin (.dll). It may need an update for this game version, or a requirement is missing.'; file = $dlls[0]; log = $r4log }) }
        }
        $reds = @($files | Where-Object { $_ -like 'r6\scripts\*.reds' })
        if ($reds -and $rs -and $rs.thisLaunch) {
            $n = @($reds | Where-Object { $compiled.Contains($_) }).Count
            if ($rs.status -eq 'failed') { $lvl = 'error'; $notes.Add([ordered]@{ level = 'error'; text = 'Scripts failed to compile, so the game ran without any script mods.' }) }
            elseif ($n) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "redscript compiled $n script file$(if ($n -ne 1) { 's' })" }) }
            elseif (-not $isNew) { if ($order['warn'] -lt $order[$lvl]) { $lvl = 'warn' }; $notes.Add([ordered]@{ level = 'warn'; text = 'Its scripts were not in the last compile.'; log = 'r6\logs\redscript_rCURRENT.log' }) }
        }
        $cetDirs = @($files | Where-Object { $_ -like 'bin\x64\plugins\cyber_engine_tweaks\mods\*\*' } | ForEach-Object { ($_ -split '\\')[5] } | Sort-Object -Unique)
        if ($cetDirs -and $cet -and $cet.ran) {
            $ok = @($cetDirs | Where-Object { $cetLoaded.Contains($_) })
            if ($ok) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "Cyber Engine Tweaks loaded it ($($ok -join ', '))" }) }
            elseif (-not $isNew -and $cetLoaded.Count) { if ($order['warn'] -lt $order[$lvl]) { $lvl = 'warn' }; $notes.Add([ordered]@{ level = 'warn'; text = 'Cyber Engine Tweaks did not report loading it.'; log = 'bin\x64\plugins\cyber_engine_tweaks\scripting.log' }) }
        }
        $xlAll = @($files | Where-Object { $_ -match '\.(xl|archivexl)$' })
        $xls = @($xlAll | ForEach-Object { [IO.Path]::GetFileName($_) })
        if ($xls -and $xlSet.Count) {
            $ok = @($xls | Where-Object { $xlSet.Contains($_) })
            if ($ok) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "ArchiveXL loaded $($ok.Count) rule file$(if ($ok.Count -ne 1) { 's' })" }) }
            elseif (-not $isNew -and ($xlAll | Where-Object { $_ -like 'archive\pc\mod\*' })) { if ($order['warn'] -lt $order[$lvl]) { $lvl = 'warn' }; $notes.Add([ordered]@{ level = 'warn'; text = 'ArchiveXL did not list its .xl file.' }) }
        }
        switch ($m.name) {
            'RED4ext' { if ($last.version) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "RED4ext $($last.version) started and loaded $($last.plugins.Count) plugins" }) } }
            'Cyber Engine Tweaks' { if ($cet -and $cet.ran) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "Cyber Engine Tweaks $($cet.version) started and loaded $(@($cet.loaded).Count) Lua mods" }) } }
            'redscript' { if ($rs -and $rs.thisLaunch -and $rs.status -eq 'ok') { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = "The script compiler ran: $(@($rs.files).Count) files compiled" }) } }
        }
        $xmls = @($files | Where-Object { $_ -like 'r6\input\*.xml' })
        if ($xmls -and $docSet.Count) { $ok = @($xmls | Where-Object { $docSet.Contains($_) }); if ($ok) { $verified = $true; $notes.Add([ordered]@{ level = 'ok'; text = 'Input Loader loaded its key bindings' }) } }
        foreach ($p in @($probs | Where-Object { $_.mod -eq $m.name })) {
            # a message seen before in a clean launch, or a harmless one, is only noted; an explained one is at most worth a check
            $pl = if ($p.known -or ($p.note -and $p.note -like 'Harmless*')) { 'info' } elseif ($p.note) { 'warn' } else { $p.level }
            $nt = if ($p.known -and -not $p.note) { 'Also in an earlier launch that closed normally.' } else { $p.note }
            $notes.Add([ordered]@{ level = $pl; text = "$($p.source): $($p.text)"; note = $nt; file = $p.file; log = $p.log; links = @($p.links) })
            if ($pl -eq 'error' -and $order['error'] -lt $order[$lvl]) { $lvl = 'error' }
            elseif ($pl -eq 'warn' -and $order['warn'] -lt $order[$lvl]) { $lvl = 'warn' }
        }
        if ($isNew) { $untested.Add($m.name); if ($lvl -eq 'ok') { $lvl = 'new' }; $notes.Insert(0, [ordered]@{ level = 'info'; text = 'Added after this launch, so it has not been tested yet.' }) }
        elseif ($lvl -eq 'ok' -and -not $verified) { $lvl = 'assets'; if (-not $notes.Count) { $notes.Add([ordered]@{ level = 'info'; text = $(if ($kinds -contains 'archive') { 'Assets: the game loads these itself without logging each file.' } else { 'Nothing in the logs mentions it (no log for this type of file).' }) }) } }
        [ordered]@{ name = $m.name; modId = $m.modId; kinds = $kinds; status = $lvl; notes = @($notes) }
    }
    $rep.mods = @($modsOut | Sort-Object { $order[$_.status] }, { $_.name })
    $rep.untested = @($untested)

    # suggestions, most important first
    $iss = [Collections.Generic.List[object]]::new()
    if ($res.result -eq 'crash' -and $crash) {
        $who = if ($crash.moduleMod) { " The crash happened inside $($crash.module), which belongs to $($crash.moduleMod)." } elseif ($crash.module -and $crash.module -notmatch '^Cyberpunk2077\.exe$') { " The crash happened inside $($crash.module)." } else { ' It happened inside the game''s own code, which does not name a mod by itself.' }
        $again = if ($crash.same -gt 0) { " This is the same crash spot as $($crash.same) earlier report$(if ($crash.same -ne 1) { 's' }), so it is likely to come back." } else { ' Earlier crash reports show a different spot.' }
        $iss.Add([ordered]@{ level = 'bad'; title = "The game crashed $($crash.when) after $($crash.uptime) s"; detail = "$($crash.message)$who$again"; act = 'crash'; crash = $crash.id; mods = @(if ($crash.moduleMod) { $crash.moduleMod }) })
        if ($crash.oom -eq 'true') { $iss.Add([ordered]@{ level = 'bad'; title = 'The game ran out of memory'; detail = 'Close other programs, lower texture quality, or remove large texture mods.' }) }
    }
    elseif ($res.result -eq 'ended') { $iss.Add([ordered]@{ level = 'warn'; title = 'The game stopped without closing normally'; detail = 'No crash report was written. It may have been closed from Task Manager or crashed too hard to report.' }) }
    if ($last.scc -eq 'failed' -or ($rs -and $rs.thisLaunch -and $rs.status -eq 'failed')) {
        $bad = @($probs | Where-Object { $_.source -eq 'redscript' -and $_.level -eq 'error' -and $_.mod } | ForEach-Object mod | Sort-Object -Unique)
        $iss.Add([ordered]@{ level = 'bad'; title = 'Scripts did not compile'; detail = "When that happens the game runs without any script mods.$(if ($bad) { " Errors point to: $($bad -join ', '). Update or disable it." } else { ' See the script errors below.' })"; mods = $bad; log = 'r6\logs\redscript_rCURRENT.log' })
    }
    # one card per mod: its first problem, with where it was logged, the file it names and other mods involved
    foreach ($m in @($rep.mods | Where-Object { $_.status -eq 'error' })) {
        $first = @($m.notes | Where-Object { $_.level -eq 'error' })[0]
        $iss.Add([ordered]@{ level = 'bad'; kind = 'mod'; title = "$($m.name) has a problem"; detail = $first.text; msg = $first.text; mods = @($m.name); log = $first.log; file = $first.file; links = @($first.links) })
    }
    foreach ($m in @($rep.mods | Where-Object { $_.status -eq 'warn' })) {
        $first = @($m.notes | Where-Object { $_.level -eq 'warn' })[0]
        $iss.Add([ordered]@{ level = 'warn'; kind = 'mod'; title = "Check $($m.name)"; detail = "$($first.text)$(if ($first.note) { " $($first.note)" })"; msg = $first.text; mods = @($m.name); log = $first.log; file = $first.file; links = @($first.links) })
    }
    $orphan = @($probs | Where-Object { -not $_.mod -and $_.level -eq 'error' -and -not $_.note -and -not $_.known })
    if ($orphan.Count) { $iss.Add([ordered]@{ level = 'warn'; title = "$($orphan.Count) error$(if ($orphan.Count -ne 1) { 's' }) not linked to a mod"; detail = (@($orphan | Select-Object -First 3 | ForEach-Object { "$($_.source): $($_.text)" }) -join ' | '); log = $orphan[0].log }) }
    $harmless = @($probs | Where-Object { $_.note -like 'Harmless*' })
    if ($harmless.Count) { $iss.Add([ordered]@{ level = 'info'; title = "$($harmless.Count) harmless warning$(if ($harmless.Count -ne 1) { 's' })"; detail = 'Messages that look scary in the logs but need no action (for example optional add-ons for mods you do not have).' }) }
    $seen = @($probs | Where-Object { $_.known -and -not ($_.note -like 'Harmless*') })
    if ($seen.Count) { $iss.Add([ordered]@{ level = 'info'; title = "$($seen.Count) known message$(if ($seen.Count -ne 1) { 's' })"; detail = 'They also showed up in an earlier launch that closed normally, so they are not flagged again. Each mod still lists them on the Mods tab.' }) }
    if ($untested.Count) { $iss.Add([ordered]@{ level = 'info'; title = "$($untested.Count) mod$(if ($untested.Count -ne 1) { 's' }) added since this launch"; detail = 'Launch once to test them: ' + (@($untested | Select-Object -First 6) -join ', ') + $(if ($untested.Count -gt 6) { ', ...' } else { '' }); mods = @($untested) }) }
    if ($res.result -eq 'clean' -and -not ($iss | Where-Object { $_.level -in 'bad', 'warn' })) { $iss.Insert(0, [ordered]@{ level = 'ok'; title = 'Everything loaded and the game closed normally'; detail = $(if ($seen.Count) { 'No new messages in the mod logs.' } else { 'No errors in the mod logs.' }) }) }
    $rep.issues = @($iss)
    $rep.problems = @($probs)

    # launch flow, in the order things happen
    $stg = [Collections.Generic.List[object]]::new()
    $stg.Add([ordered]@{ key = 'start'; title = 'Game started'; status = 'ok'; detail = "Version $($last.product) at $($start.ToString('HH:mm, d MMM'))" })
    $pluginMods = @($s.mods | Where-Object { @($_.files) -like 'red4ext\plugins\*.dll' }).Count
    $plugErr = $plugFail.Count
    $stg.Add([ordered]@{ key = 'red4ext'; title = 'RED4ext loaded native plugins'; status = $(if (-not $last.version) { 'skip' } elseif ($plugErr) { 'bad' } elseif (@($probs | Where-Object { $_.source -eq 'RED4ext' -and -not $_.known }).Count) { 'warn' } else { 'ok' }); detail = "$($last.plugins.Count) plugin$(if ($last.plugins.Count -ne 1) { 's' }) loaded$(if ($pluginMods) { " ($pluginMods installed with plugins)" })$(if ($plugErr) { ", $plugErr failed" })" })
    $cetErr = @($probs | Where-Object { $_.source -eq 'Cyber Engine Tweaks' -and -not $_.known }).Count
    $stg.Add([ordered]@{ key = 'cet'; title = 'Cyber Engine Tweaks loaded Lua mods'; status = $(if (-not $cet -or -not $cet.ran) { 'skip' } elseif ($cetErr) { 'warn' } else { 'ok' }); detail = $(if ($cet -and $cet.ran) { "$(@($cet.loaded).Count) mods loaded$(if ($cetErr) { ", $cetErr error line$(if ($cetErr -ne 1) { 's' })" })" } else { 'Not seen in this launch' }) })
    $rsErr = @($probs | Where-Object { $_.source -eq 'redscript' -and $_.level -eq 'error' }).Count
    $stg.Add([ordered]@{ key = 'scripts'; title = 'redscript compiled script mods'; status = $(if (-not $rs -or -not $rs.thisLaunch) { 'skip' } elseif ($rs.status -eq 'failed' -or $last.scc -eq 'failed') { 'bad' } elseif (@($probs | Where-Object { $_.source -eq 'redscript' -and -not $_.known }).Count) { 'warn' } else { 'ok' }); detail = $(if ($rs -and $rs.thisLaunch) { "$(@($rs.files).Count) files$(if ($rs.status -eq 'ok') { ', compiled fine' } elseif ($rsErr) { ", $rsErr error$(if ($rsErr -ne 1) { 's' })" })$(if (@($rs.warnings).Count) { ", $(@($rs.warnings).Count) warning$(if (@($rs.warnings).Count -ne 1) { 's' })" })" } else { 'No compile log from this launch' }) })
    $twBad = @($probs | Where-Object { $_.source -eq 'TweakXL' -and -not ($_.note -like 'Harmless*') -and -not $_.known })
    $stg.Add([ordered]@{ key = 'tweaks'; title = 'TweakXL applied database edits'; status = $(if (-not $fwv.Contains('TweakXL')) { 'skip' } elseif (@($twBad | Where-Object level -EQ 'error').Count) { 'warn' } else { 'ok' }); detail = $(if ($twBad.Count) { "$($twBad.Count) message$(if ($twBad.Count -ne 1) { 's' }) to check" } else { 'No problems' }) })
    $xlBad = @($probs | Where-Object { $_.source -eq 'ArchiveXL' -and -not ($_.note -like 'Harmless*') -and -not $_.known })
    $modArch = @(Get-ChildItem -LiteralPath (Join-Path $g 'archive\pc\mod') -Filter *.archive -File -ErrorAction SilentlyContinue).Count
    $stg.Add([ordered]@{ key = 'archives'; title = 'Game loaded asset mods (ArchiveXL added its rules)'; status = $(if ($xlBad.Count) { 'warn' } else { 'ok' }); detail = "$modArch .archive files in archive\pc\mod, $($xlLoaded.Count) ArchiveXL rule files$(if ($xlBad.Count) { ", $($xlBad.Count) to check" })" })
    $endTitle = switch ($res.result) { 'clean' { 'Closed normally' } 'crash' { 'Crashed' } 'running' { 'Still running' } default { 'Stopped without a normal exit' } }
    $endDetail = switch ($res.result) {
        'clean' { "After $([Math]::Round($res.seconds / 60, 1)) min" }
        'crash' { "$($crash.when)$(if ($crash.stage) { " (stage: $($crash.stage))" }) after $($crash.uptime) s" }
        # a clock time: the report is not rebuilt while the game runs, so a duration would stand still
        'running' { "Running since $($start.ToString('HH:mm'))" }
        default { 'The log stops without a shutdown and there is no crash report' }
    }
    $stg.Add([ordered]@{ key = 'end'; title = $endTitle; status = $(switch ($res.result) { 'clean' { 'ok' } 'crash' { 'bad' } 'running' { 'run' } default { 'warn' } }); detail = $endDetail })
    $rep.stages = @($stg)
    $rep
}

# Mods that loaded with no errors on the last launch (lowers "outdated" risk in the compatibility check)
function Get-LoadedOkMods($Report) {
    $h = @{}
    if ($Report -and $Report.mods) { foreach ($m in $Report.mods) { if ($m.status -eq 'ok') { $h[$m.name] = $true } } }
    $h
}
#endregion

#region compatibility
# Compiled RDAR index reader: PowerShell loops are too slow for the 600k entries of the base game archives
function Add-CpRdarType {
    if ('CpRdar' -as [type]) { return }
    Import-CpType 'CpRdar' @'
using System; using System.IO; using System.Collections.Generic;
public static class CpRdar {
  public static ulong[] Hashes(string path) {
    using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
      if (fs.Length < 40) return new ulong[0];
      var br = new BinaryReader(fs);
      var magic = br.ReadBytes(4);
      if (magic[0] != 'R' || magic[1] != 'D' || magic[2] != 'A' || magic[3] != 'R') return new ulong[0];
      br.ReadUInt32();
      long ip = (long)br.ReadUInt64();
      if (ip <= 0 || ip + 28 > fs.Length) return new ulong[0];
      fs.Position = ip + 16;
      long n = br.ReadUInt32();
      if (n <= 0 || n > 4000000) return new ulong[0];
      br.ReadUInt32(); br.ReadUInt32();
      var buf = br.ReadBytes((int)(n * 56));
      int count = buf.Length / 56;
      var outp = new ulong[count];
      for (int i = 0; i < count; i++) outp[i] = BitConverter.ToUInt64(buf, i * 56);
      return outp;
    }
  }
  // archive file name holding each wanted hash (first archive in the given order wins)
  public static Dictionary<ulong, string> Locate(string[] archives, ulong[] targets) {
    var want = new HashSet<ulong>(targets);
    var res = new Dictionary<ulong, string>();
    foreach (var a in archives) {
      if (res.Count >= want.Count) break;
      ulong[] hs;
      try { hs = Hashes(a); } catch { continue; }
      var name = Path.GetFileName(a);
      foreach (var h in hs) if (want.Contains(h) && !res.ContainsKey(h)) res[h] = name;
    }
    return res;
  }
}
'@
}

# Resource path hashes from a Cyberpunk .archive (RDAR) index; an unreadable archive has none
function Get-ArchiveHashes([string]$Path) { Add-CpRdarType; try { , [CpRdar]::Hashes($Path) } catch { , [uint64[]]@() } }

function Get-CompatIgnore {
    $f = Join-Path (Get-CpPaths).state 'compat-ignore.json'
    if (Test-Path -LiteralPath $f) { @(Read-JsonFile $f | Where-Object { $_ }) } else { @() }
}
function Set-CompatIgnore([string]$Key, [bool]$On) {
    if (-not $Key) { throw 'Missing issue key' }
    $l = [Collections.Generic.List[string]]::new([string[]]@(Get-CompatIgnore))
    if ($On) { if (-not $l.Contains($Key)) { $l.Add($Key) } } else { [void]$l.Remove($Key) }
    Write-JsonFile (Join-Path (Get-CpPaths).state 'compat-ignore.json') @($l)
    @($l)
}

$script:RiskNames = @('ok', 'low', 'medium', 'high')
function Step-Risk([string]$Risk, [int]$By) {
    $i = [array]::IndexOf($script:RiskNames, $Risk)
    if ($i -lt 0) { $i = 1 }
    $script:RiskNames[[Math]::Max(0, [Math]::Min(3, $i + $By))]
}

# What part of the game a base archive holds, and how much a clash there tends to matter
function Get-ArchiveArea([string]$Name) {
    $n = "$Name".ToLower() -replace '\.archive$', ''
    $a = switch -Regex ($n) {
        'nightcity_gi' { @('world lighting', 'low'); break }
        'nightcity_terrain' { @('terrain', 'low'); break }
        'nightcity' { @('the world map (placed objects, buildings)', 'mid'); break }
        'appearance' { @('character and item looks (models, textures)', 'low'); break }
        'gamedata' { @('game data (quests, scenes, menus, gameplay)', 'high'); break }
        'animation' { @('animations', 'mid'); break }
        'engine' { @('engine and interface resources', 'high'); break }
        'mainmenu' { @('the main menu', 'mid'); break }
        'video' { @('videos', 'low'); break }
        '^lang_.*voice' { @('voice lines', 'low'); break }
        '^lang_' { @('text and translations', 'mid'); break }
        '^audio' { @('sounds and music', 'low'); break }
        'memoryresident' { @('core resources loaded at startup', 'high'); break }
        default { @('other game resources', 'mid') }
    }
    [ordered]@{ label = $(if ($n.StartsWith('ep1_')) { "Phantom Liberty $($a[0])" } else { $a[0] }); sens = $a[1] }
}

# Missing requirements, shared files, asset overlaps, replaced script functions, shared tweak records, outdated script mods,
# author notes; each issue gets a risk (high/medium/low/ok) with the reasons behind it. $Loaded: mod names that loaded cleanly last launch
function Test-ModCompat([hashtable]$Loaded) {
    $game = (Get-CpPaths).game
    $s = Get-State
    $set = Get-CpSettings
    $issues = [Collections.Generic.List[object]]::new()
    $fws = @(Get-Frameworks)
    $fwIds = @($fws | ForEach-Object { [int]$_.nexusId })
    $fwNames = @($fws | ForEach-Object { "$($_.name)" })
    $byName = @{}
    foreach ($m in $s.mods) { $byName[$m.name] = $m }

    $owner = @{}
    foreach ($m in $s.mods) {
        foreach ($f in @($m.files)) {
            $k = "$f".ToLower()
            if (-not $owner.ContainsKey($k)) { $owner[$k] = [Collections.Generic.List[string]]::new() }
            if (-not $owner[$k].Contains($m.name)) { $owner[$k].Add($m.name) }
        }
    }

    # Nexus details first: authors, requirements and descriptions decide how risky an overlap is
    $ids = @($s.mods | Where-Object { $_.modId } | ForEach-Object { [int]$_.modId } | Sort-Object -Unique)
    $installed = [Collections.Generic.HashSet[int]]::new([int[]]$ids)
    $disabledIds = @($s.disabled | Where-Object { $_.modId } | ForEach-Object { [int]$_.modId })
    # these change rarely: kept 30 min (per worker) and only mods not in it yet are asked for (saves ~2 s a check)
    if ($null -eq $script:NxInfo -or ([datetime]::UtcNow - $script:NxInfoAt).TotalMinutes -ge 30) { $script:NxInfo = @{}; $script:NxInfoAt = [datetime]::UtcNow }
    $more = Get-NexusModInfo @($ids | Where-Object { -not $script:NxInfo.ContainsKey($_) }) 'modId name author updatedAt uploader { name } description modRequirements { nexusRequirements { nodes { modId modName notes externalRequirement } } }'
    foreach ($k in $more.Keys) { $script:NxInfo[$k] = $more[$k] }
    $info = $script:NxInfo
    $nx = { param($name) $m = $byName[$name]; if ($m -and $m.modId) { $info[[int]$m.modId] } else { $null } }
    $plain = @{}
    foreach ($k in $info.Keys) { $plain[$k] = [Net.WebUtility]::HtmlDecode(("$($info[$k].description)" -replace '<br\s*/?>', "`n" -replace '\[/?[a-z\*]+[^\]]{0,60}\]', ' ')) }
    $texts = @{}
    foreach ($m in $s.mods) {
        $c = @($m.name)
        $n = & $nx $m.name
        if ($n) { $c += "$($n.name)"; $c += ("$($n.name)" -split ' [\(\[\-]')[0] }
        $texts[$m.name] = @($c | ForEach-Object { "$_".Trim() } | Where-Object { $_.Length -ge 6 } | Sort-Object -Unique)
    }
    # reasons two managed mods are meant to coexist: same author, one requires the other, one mentions the other
    $relation = {
        param([string]$A, [string]$B)
        $r = [ordered]@{ same = $null; requires = $null; mention = $null }
        $na = & $nx $A; $nb = & $nx $B
        if ($na -and $nb) {
            $wa = @("$($na.author)", "$($na.uploader.name)") | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() }
            $wb = @("$($nb.author)", "$($nb.uploader.name)") | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() }
            $hit = @($wa | Where-Object { $wb -contains $_ })
            if ($hit) { $r.same = $(if ($na.author) { "$($na.author)" } else { "$($na.uploader.name)" }) }
            foreach ($pair in @(@($na, $nb, $A, $B), @($nb, $na, $B, $A))) {
                $req = @($pair[0].modRequirements.nexusRequirements.nodes | Where-Object { $_ -and [int]$_.modId -eq [int]$pair[1].modId })
                if ($req) { $r.requires = "$($pair[2]) lists $($pair[3]) as a requirement, so it is built to sit on top of it." }
            }
        }
        foreach ($pair in @(@($A, $B), @($B, $A))) {
            $n = & $nx $pair[0]
            if (-not $n -or $r.mention) { continue }
            $txt = $plain[[int]$n.modId]
            foreach ($t in $texts[$pair[1]]) { if ($txt -and $txt.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $r.mention = "The page of $($pair[0]) mentions $($pair[1]) (often a compatibility note)."; break } }
        }
        $r
    }
    $kindOf = { param([string]$p) $e = [IO.Path]::GetExtension($p).ToLower(); $leaf = [IO.Path]::GetFileName($p).ToLower()
        if ($leaf -match '^(license|licence|readme|changelog|third_party_licenses|credits)([\._ -].*)?$' -or $e -in '.md', '.txt', '.url', '.pdf', '.png', '.jpg') { 'doc' }
        elseif ($e -in '.dll', '.asi', '.exe') { 'code' } elseif ($e -in '.reds', '.lua') { 'script' } elseif ($e -in '.ini', '.json', '.toml', '.xml', '.yaml', '.yml', '.cfg') { 'config' } else { 'data' } }

    # 1. same file installed by several mods
    # a vanilla backup means the file is a base game file, not a mod's own
    $base = @{}
    foreach ($m in $s.mods) { foreach ($b in @($m.backups)) { $base["$b".ToLower()] = $true } }
    $pairs = @{}
    foreach ($k in $owner.Keys) {
        $o = $owner[$k]
        if ($o.Count -lt 2) { continue }
        $key = (@($o) | Sort-Object) -join '|'
        if (-not $pairs.ContainsKey($key)) { $pairs[$key] = [Collections.Generic.List[string]]::new() }
        $pairs[$key].Add($k)
    }
    foreach ($key in $pairs.Keys) {
        $mods = @($key -split '\|')
        $files = @($pairs[$key])
        $kinds = @($files | ForEach-Object { & $kindOf $_ } | Sort-Object -Unique)
        $why = [Collections.Generic.List[string]]::new()
        $mids = @($mods | ForEach-Object { $m = $byName[$_]; if ($m -and $m.modId) { [int]$m.modId } else { 0 } } | Sort-Object -Unique)
        if ($mids.Count -eq 1 -and $mids[0] -gt 0) { $risk = 'ok'; $why.Add('All of them come from the same Nexus mod (for example a main file plus an optional or update file), which is built to replace these files.') }
        elseif (-not ($kinds | Where-Object { $_ -ne 'doc' })) { $risk = 'ok'; $why.Add('Only documentation such as LICENSE or readme files: nothing the game uses.') }
        elseif ($kinds -contains 'code') { $risk = 'high'; $why.Add('A program file (.dll or .asi) is shared: only the copy installed last runs, so the other mod may lose part of how it works.') }
        elseif (@($files | Where-Object { $base.ContainsKey($_) }).Count) { $risk = 'medium'; $why.Add('A base game file is replaced whole by both (for example r6\config input files): only the copy installed last is used, so the other mod loses all its changes to it, such as its key bindings.') }
        elseif ($kinds -contains 'script') { $risk = 'medium'; $why.Add('A script file is shared: only the copy installed last is used.') }
        elseif ($kinds -contains 'data') { $risk = 'medium'; $why.Add('A game data file is shared: only the copy installed last is used.') }
        else { $risk = 'low'; $why.Add('Only settings files are shared: the copy installed last is used, which usually just changes defaults.') }
        if ($risk -ne 'ok' -and $mods.Count -eq 2) {
            $rel = & $relation $mods[0] $mods[1]
            if ($rel.same) { $risk = Step-Risk $risk -1; $why.Add("Same author ($($rel.same)): the overlap is probably on purpose.") }
        }
        $issues.Add([ordered]@{ kind = 'files'; level = 'warn'; mods = $mods; risk = $risk; why = @($why); title = "$($mods -join ' and ') install the same file$(if ($files.Count -gt 1) { 's' })"
                detail = "$($files.Count) file(s), e.g. $($files[0]). The copy installed last is the one in use."; files = @($files | Select-Object -First 8) })
    }

    # 2. archives replacing the same game assets (load order: alphabetical, first one wins)
    $archives = @(Get-ChildItem -LiteralPath (Join-Path $game 'archive\pc\mod') -Filter *.archive -File -ErrorAction SilentlyContinue)
    $archives += @(Get-ChildItem -LiteralPath (Join-Path $game 'mods') -Recurse -Filter *.archive -File -ErrorAction SilentlyContinue)
    $label = @{}
    $byHash = [Collections.Generic.Dictionary[uint64, Collections.Generic.List[string]]]::new()
    foreach ($a in $archives) {
        $rel = [IO.Path]::GetRelativePath($game, $a.FullName).ToLower()
        $label[$a.Name] = if ($owner.ContainsKey($rel)) { $owner[$rel][0] } else { "$($a.Name) (not managed by cpmods)" }
        try { $hs = Get-ArchiveHashes $a.FullName } catch { continue }
        foreach ($x in $hs) {
            $l = $null
            if ($byHash.TryGetValue($x, [ref]$l)) { if (-not $l.Contains($a.Name)) { $l.Add($a.Name) } }
            else { $byHash[$x] = [Collections.Generic.List[string]]::new([string[]]@($a.Name)) }
        }
    }
    $ov = @{}
    $ovH = @{}
    foreach ($kv in $byHash.GetEnumerator()) {
        if ($kv.Value.Count -lt 2) { continue }
        $names = [string[]]$kv.Value.ToArray()
        [Array]::Sort($names, [StringComparer]::Ordinal)
        for ($i = 0; $i -lt $names.Count; $i++) {
            for ($j = $i + 1; $j -lt $names.Count; $j++) {
                if ($label[$names[$i]] -eq $label[$names[$j]]) { continue }
                $key = "$($names[$i])|$($names[$j])"
                $ov[$key] = 1 + [int]$ov[$key]
                if (-not $ovH.ContainsKey($key)) { $ovH[$key] = [Collections.Generic.List[uint64]]::new() }
                if ($ovH[$key].Count -lt 400) { $ovH[$key].Add($kv.Key) }
            }
        }
    }
    # which base game archive each shared asset comes from tells what kind of content the two mods fight over
    $where = @{}
    if ($ovH.Count) {
        $want = [Collections.Generic.HashSet[uint64]]::new()
        foreach ($l in $ovH.Values) { foreach ($x in $l) { [void]$want.Add($x) } }
        $base = @(Get-ChildItem -LiteralPath (Join-Path $game 'archive\pc') -Recurse -Filter *.archive -File -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -notlike '*\archive\pc\mod' } | Sort-Object { if ($_.Name -like 'ep1_*') { 1 } else { 0 } }, Name | ForEach-Object FullName)
        try { Add-CpRdarType; $loc = [CpRdar]::Locate([string[]]$base, [uint64[]]@($want)); foreach ($kv in $loc.GetEnumerator()) { $where[$kv.Key] = $kv.Value } } catch { }
    }
    $prefixRx = '^(#+|!+|_+|\d+[\s_\-.]|z{1,3}(?=[A-Z_\-\s])|z{2,})'
    # overlaps you settled with "Let X win": "winner file|loser file"
    $chosen = @{}
    foreach ($x in (Get-LoadOrderRules).Values) { foreach ($o in @($x.over)) { if ($o) { $chosen["$($x.name)|$o"] = $true } } }
    foreach ($key in $ov.Keys) {
        $win, $lose = $key -split '\|'
        $A = $label[$win]; $B = $label[$lose]
        $n = $ov[$key]
        $why = [Collections.Generic.List[string]]::new()
        $risk = if ($n -le 2) { 'low' } elseif ($n -le 40) { 'medium' } else { 'high' }
        $why.Add("$n shared asset$(if ($n -ne 1) { 's' }). $win loads first, so $A wins for $(if ($n -eq 1) { 'it' } else { 'those' }) and $B loses its version.")
        $areas = @{}; $newOnes = 0
        foreach ($x in $ovH[$key]) {
            $an = $where[$x]
            if (-not $an) { $newOnes++; continue }
            $ar = Get-ArchiveArea $an
            $prev = $areas[$ar.label]
            $areas[$ar.label] = @($(if ($prev) { $prev[0] + 1 } else { 1 }), $ar.sens)
        }
        $areaList = @($areas.Keys | Sort-Object { - $areas[$_][0] })
        if ($ovH[$key].Count -and -not $areaList.Count) { $risk = Step-Risk $risk -1; $why.Add('The shared files are not part of the base game: both mods ship the same extra file, often a common resource.') }
        elseif ($areaList.Count) {
            $sens = @($areaList | ForEach-Object { $areas[$_][1] })
            $txt = ($areaList | Select-Object -First 2) -join ' and '
            if ($sens -contains 'high') { $why.Add("They touch $txt, so a quest, scene, menu or gameplay value follows one mod instead of the other.") }
            elseif (-not ($sens | Where-Object { $_ -ne 'low' })) { $risk = Step-Risk $risk -1; $why.Add("They only touch ${txt}: at worst you see one mod's version instead of the other's.") }
            else { $why.Add("They touch ${txt}: objects can look or sit differently than one of the mods intends.") }
        }
        $managed = $byName.ContainsKey($A) -and $byName.ContainsKey($B)
        if ($managed) {
            $rel = & $relation $A $B
            if ($rel.same) { $risk = 'ok'; $why.Add("Same author ($($rel.same)): the overlap is almost certainly on purpose.") }
            if ($rel.requires) { $risk = 'ok'; $why.Add($rel.requires) }
            if ($rel.mention -and $risk -ne 'ok') { $risk = Step-Risk $risk -1; $why.Add($rel.mention) }
        }
        $pref = @($win, $lose | Where-Object { $_ -cmatch $prefixRx })
        if ($pref -and $risk -ne 'ok') { $risk = Step-Risk $risk -1; $why.Add("$($pref[0]) starts with a load-order prefix (#, !, z), a sign the author chose on purpose which one wins.") }
        elseif ($pref) { $why.Add("$($pref[0]) starts with a load-order prefix, so the author chose which one wins.") }
        $pick = [bool]$chosen["$win|$lose"]
        if ($pick) { $risk = 'ok'; $why.Add("You chose $A to win.") }
        $issues.Add([ordered]@{ kind = 'archive'; level = 'warn'; mods = @($A, $B); risk = $risk; why = @($why); winner = $A; chosen = $(if ($pick) { $A } else { $null }); files = @($win, $lose); areas = $areaList
                title = "$A and $B change the same game assets"
                detail = "$n shared asset(s). $win loads first, so $A probably wins for those and $B loses its version of them." })
    }

    # 3. Nexus requirements
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($m in $s.mods | Where-Object { "$($_.source)" -match 'nexus:' }) {
        $n = $info[[int]$m.modId]
        if (-not $n) { continue }
        foreach ($r in @($n.modRequirements.nexusRequirements.nodes)) {
            if (-not $r -or $r.externalRequirement -or -not $r.modId) { continue }
            $rid = [int]$r.modId
            if ($installed.Contains($rid) -or -not $seen.Add("$($m.modId)-$rid")) { continue }
            $notes = "$($r.notes)".Trim()
            $optional = $notes -match '(?i)optional|only (if|for|needed|required)|not required|recommended'
            $lvl = if ($disabledIds -contains $rid) { 'warn' } elseif ($optional) { 'info' } else { 'error' }
            $risk = @{ error = 'high'; warn = 'medium'; info = 'low' }[$lvl]
            $why = switch ($lvl) {
                'error' { 'The mod (or part of it) does not work without it.' }
                'warn' { 'It is installed but switched off.' }
                default { 'The author marks it as optional or only needed for some features.' }
            }
            $det = if ($lvl -eq 'warn') { 'It is installed but disabled.' } elseif ($optional) { "Author note: $notes" } else { 'Not installed. The mod (or part of it) will not work without it.' + $(if ($notes) { " Author note: $notes" } else { '' }) }
            $issues.Add([ordered]@{ kind = 'requirement'; level = $lvl; mods = @($m.name); reqId = $rid; reqName = "$($r.modName)"; risk = $risk; why = @($why); title = "$($m.name) needs $($r.modName)"; detail = $det })
        }
    }

    # 4. two mods replacing the same script function: only one replacement can be active
    $repl = @{}
    $tweakRec = @{}
    # redscript modules present (parents included), for @if(ModuleExists("X")) guards
    $modules = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in 'r6\scripts', 'red4ext\plugins') {
        Get-ChildItem -LiteralPath (Join-Path $game $d) -Recurse -Filter *.reds -File -ErrorAction SilentlyContinue | Select-String -Pattern '^\s*module\s+([\w.]+)' -List |
            ForEach-Object { $n = $_.Matches[0].Groups[1].Value; while ($n) { [void]$modules.Add($n); $n = $n -replace '\.?[^.]*$', '' } }
    }
    $guardOn = { param([string]$g) foreach ($c in [regex]::Matches($g, '(!?)\s*ModuleExists\(\s*"([^"]+)"')) { if ($modules.Contains($c.Groups[2].Value) -eq [bool]$c.Groups[1].Value) { return $false } }; $true }
    $guard = '((?:@if\(\s*!?\s*ModuleExists\(\s*"[^"]+"\s*\)\s*\)\s*)*)'
    foreach ($m in $s.mods) {
        foreach ($f in @($m.files)) {
            $fl = "$f".ToLower()
            $p = Join-Path $game $f
            if ($fl.EndsWith('.reds') -and $fl.StartsWith('r6\scripts\')) {
                try { $txt = [IO.File]::ReadAllText($p) } catch { continue }
                $txt = $txt -replace '(?s)/\*.*?\*/', '' -replace '(?m)//.*$', ''
                foreach ($x in [regex]::Matches($txt, $guard + '@replaceMethod\(\s*(\w+)\s*\)\s*(?:(?:public|private|protected|final|static|native|cb|exec|quest|const|importonly)\s+)*func\s+(\w+)')) {
                    if (-not (& $guardOn $x.Groups[1].Value)) { continue }
                    $k = "$($x.Groups[2].Value).$($x.Groups[3].Value)"
                    if (-not $repl[$k]) { $repl[$k] = [Collections.Generic.List[string]]::new() }
                    if (-not $repl[$k].Contains($m.name)) { $repl[$k].Add($m.name) }
                }
                foreach ($x in [regex]::Matches($txt, $guard + '@replaceGlobal\(\s*\)\s*(?:(?:public|private|protected|final|static|native|exec|quest)\s+)*func\s+(\w+)')) {
                    if (-not (& $guardOn $x.Groups[1].Value)) { continue }
                    $k = "$($x.Groups[2].Value)"
                    if (-not $repl[$k]) { $repl[$k] = [Collections.Generic.List[string]]::new() }
                    if (-not $repl[$k].Contains($m.name)) { $repl[$k].Add($m.name) }
                }
            }
            elseif (($fl.StartsWith('r6\tweaks\') -or $fl.StartsWith('red4ext\plugins\')) -and $fl -match '\.(yaml|yml)$') {
                try { $lines = [IO.File]::ReadAllLines($p) } catch { continue }
                foreach ($ln in $lines) {
                    if ($ln -match '^([A-Za-z_][\w.]*)\s*:') {
                        $k = $Matches[1]
                        if (-not $tweakRec[$k]) { $tweakRec[$k] = [Collections.Generic.List[string]]::new() }
                        if (-not $tweakRec[$k].Contains($m.name)) { $tweakRec[$k].Add($m.name) }
                    }
                }
            }
        }
    }
    $rp = @{}
    foreach ($k in $repl.Keys) { if ($repl[$k].Count -ge 2) { $pk = (@($repl[$k]) | Sort-Object) -join '|'; if (-not $rp[$pk]) { $rp[$pk] = [Collections.Generic.List[string]]::new() }; $rp[$pk].Add($k) } }
    foreach ($pk in $rp.Keys) {
        $mods = @($pk -split '\|'); $fns = @($rp[$pk])
        $why = [Collections.Generic.List[string]]::new()
        $why.Add("Both replace $($fns.Count) game function$(if ($fns.Count -gt 1) { 's' }) completely ($(($fns | Select-Object -First 3 | ForEach-Object { "$_()" }) -join ', ')$(if ($fns.Count -gt 3) { ', ...' })). Only one replacement can be active, so one mod loses that change.")
        $risk = 'high'
        if ($mods.Count -eq 2) { $rel = & $relation $mods[0] $mods[1]; if ($rel.same) { $risk = 'low'; $why.Add("Same author ($($rel.same)): probably designed to work together.") } elseif ($rel.mention) { $risk = 'medium'; $why.Add($rel.mention) } }
        $issues.Add([ordered]@{ kind = 'script'; level = 'warn'; mods = $mods; risk = $risk; why = @($why); functions = $fns; title = "$($mods -join ' and ') replace the same script function$(if ($fns.Count -gt 1) { 's' })"
                detail = "Keep the one you care about more, or look for a compatibility patch on Nexus." })
    }

    # 5. tweak files editing the same game database records
    $tp = @{}
    foreach ($k in $tweakRec.Keys) { if ($tweakRec[$k].Count -ge 2) { $pk = (@($tweakRec[$k]) | Sort-Object) -join '|'; if (-not $tp[$pk]) { $tp[$pk] = [Collections.Generic.List[string]]::new() }; $tp[$pk].Add($k) } }
    foreach ($pk in $tp.Keys) {
        $mods = @($pk -split '\|'); $recs = @($tp[$pk])
        $risk = if ($recs.Count -gt 25) { 'medium' } else { 'low' }
        $why = [Collections.Generic.List[string]]::new()
        $why.Add("$($recs.Count) shared database entr$(if ($recs.Count -eq 1) { 'y' } else { 'ies' }), e.g. $($recs[0]). When both set the same value, only one wins; added list items are usually merged.")
        if ($mods.Count -eq 2) { $rel = & $relation $mods[0] $mods[1]; if ($rel.same -or $rel.requires) { $risk = 'ok'; $why.Add($(if ($rel.same) { "Same author ($($rel.same))." } else { $rel.requires })) } }
        $issues.Add([ordered]@{ kind = 'tweak'; level = 'info'; mods = $mods; risk = $risk; why = @($why); records = @($recs | Select-Object -First 12); title = "$($mods -join ' and ') edit the same game database entries"
                detail = 'TweakXL applies both; usually fine unless both change the exact same stat.' })
    }

    # 6. script and plugin mods not updated since the current patch
    $epoch = [DateTimeOffset]::FromUnixTimeSeconds([long]$set.patchEpoch).UtcDateTime
    foreach ($m in $s.mods) {
        if (-not $m.modId -or $fwIds -contains [int]$m.modId -or $fwNames -contains $m.name -or "$($m.source)" -notmatch '^nexus:') { continue }
        $n = $info[[int]$m.modId]
        if (-not $n -or -not $n.updatedAt) { continue }
        $upd = try { ([datetimeoffset]"$($n.updatedAt)").UtcDateTime } catch { $null }
        if (-not $upd -or $upd -ge $epoch) { continue }
        $fl = @($m.files | ForEach-Object { "$_".ToLower() })
        $native = [bool]($fl | Where-Object { ($_.StartsWith('red4ext\plugins\') -and $_.EndsWith('.dll')) -or $_.EndsWith('.asi') })
        $code = $native -or [bool]($fl | Where-Object { $_.EndsWith('.reds') -or ($_.StartsWith('bin\x64\plugins\cyber_engine_tweaks\mods\') -and $_.EndsWith('.lua')) })
        if (-not $code) { continue }
        $risk = if ($native) { 'high' } else { 'medium' }
        $why = [Collections.Generic.List[string]]::new()
        $why.Add("Last updated $($upd.ToLocalTime().ToString('d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture)), before $($set.patchLabel) came out.")
        $why.Add($(if ($native) { 'It has a native plugin (.dll): these hook into the game''s code and usually break when the game updates.' } else { 'It runs scripts: many keep working after a patch, some break.' }))
        if ($Loaded -and $Loaded.ContainsKey($m.name)) { $risk = Step-Risk $risk -1; $why.Add('It loaded without errors on your last launch.') }
        $issues.Add([ordered]@{ kind = 'outdated'; level = 'info'; mods = @($m.name); risk = $risk; why = @($why); version = "$($m.version)"; title = "$($m.name) was not updated for $($set.patchLabel)"
                detail = 'Check the Posts and Bugs tabs on its Nexus page if something misbehaves.' })
    }

    # 7. author notes mentioning another installed mod near compatibility words
    $noted = [Collections.Generic.HashSet[string]]::new()
    foreach ($m in $s.mods | Where-Object { "$($_.source)" -match 'nexus:' }) {
        $n = $info[[int]$m.modId]
        if (-not $n -or -not $n.description) { continue }
        $lines = $plain[[int]$m.modId] -split '[\r\n]+|(?<=[\.!?])\s+' | Where-Object { $_ -match '(?i)incompatib|not compatible|conflicts? with|do not use (it |this )?with|don''t use (it |this )?with|(won''t|does not|doesn''t) work with' }
        foreach ($line in $lines) {
            foreach ($other in $s.mods) {
                if ($other.name -eq $m.name -or ($other.modId -and [int]$other.modId -eq [int]$m.modId) -or ($other.modId -and $fwIds -contains [int]$other.modId)) { continue }
                $hitText = $texts[$other.name] | Where-Object { $line -match [regex]::Escape($_) } | Select-Object -First 1
                if (-not $hitText -or -not $noted.Add("$($m.name)|$($other.name)")) { continue }
                $q = $line.Trim(); if ($q.Length -gt 280) { $q = $q.Substring(0, 280) + '...' }
                $positive = $q -match '(?i)\b(is|are|now|fully)\s+compatible|works? (fine |well )?with|patch for|compatibility patch'
                $negative = $q -match '(?i)incompatib|not compatible|do not use|don''t use|won''t work|does not work|doesn''t work'
                $risk = if ($positive -and -not $negative) { 'low' } else { 'medium' }
                $why = @("The author of $($m.name) writes about $($other.name) in a sentence about compatibility. Read it to see whether it is a warning or a note that they work together.")
                $issues.Add([ordered]@{ kind = 'note'; level = 'info'; mods = @($m.name, $other.name); risk = $risk; why = $why; title = "The author of $($m.name) mentions $($other.name)"; detail = "`"$q`"" })
            }
        }
    }

    $ign = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-CompatIgnore))
    foreach ($it in $issues) {
        $tail = switch ($it.kind) { 'requirement' { "$($it.reqId)" } 'outdated' { "$($it.version)" } default { '' } }
        $it.key = "$($it.kind)|$((@($it.mods) | Sort-Object) -join '|')|$tail"
        $it.ignored = $ign.Contains($it.key)
    }
    $lo = Get-LoadOrderRules
    [ordered]@{ checked = (Get-Date).ToString('s'); mods = $s.mods.Count; archives = $archives.Count; assets = $byHash.Count; issues = @($issues); loadOrder = @($lo.Values) }
}
#endregion

#region crash bisect: halve the suspect list each launch until one mod is left
function Get-BisectFile { Join-Path (Get-CpPaths).state 'bisect.json' }
function Get-BisectState { $f = Get-BisectFile; if (Test-Path -LiteralPath $f) { Read-JsonFile $f } else { $null } }
function Save-BisectState($B) { Write-JsonFile (Get-BisectFile) $B }

function Set-ModsEnabled([string[]]$Names, [bool]$On, $Job) {
    $done = 0; $fail = [Collections.Generic.List[string]]::new()
    foreach ($n in @($Names)) {
        if ($Job) { $Job.phase = "$(if ($On) { 'turning on' } else { 'turning off' }) $n"; $Job.total = @($Names).Count; $Job.done = $done }
        try { if ($On) { Enable-InstalledMod -Name $n } else { Disable-InstalledMod -Name $n } }
        catch { $fail.Add("${n}: $($_.Exception.Message)"); Write-Note "troubleshoot: $n $($_.Exception.Message)" }
        $done++
    }
    if ($Job) { $Job.done = $done }
    , $fail
}

function Get-Half($List) { $l = @($List | Sort-Object); $k = [int][Math]::Ceiling($l.Count / 2); @($l[0..($k - 1)]) }

function Start-Bisect([string[]]$Names, $Job) {
    Assert-GameReady
    if (Get-BisectState) { throw 'Troubleshooting is already running. Finish or stop it first.' }
    $s = Get-State
    $fwNames = @(Get-Frameworks | ForEach-Object { "$($_.name)" })
    $ok = @(foreach ($n in @($Names)) {
            $m = $s.mods | Where-Object { $_.name -eq $n } | Select-Object -First 1
            if (-not $m -or $fwNames -contains $m.name -or "$($m.source)" -like 'github:*') { continue }
            if (-not $m.adopted -and -not ($m.archive -and (Test-Path -LiteralPath $m.archive))) { continue }
            $m.name
        })
    $ok = @($ok | Sort-Object -Unique)
    if (-not $ok.Count) { throw 'Pick at least one enabled mod that cpmods can switch off (frameworks and mods without their download stay on).' }
    $brief = try { Get-LaunchBrief } catch { $null }
    $b = [ordered]@{ active = $true; started = (Get-Date).ToString('s'); scope = $ok; suspects = $ok; testing = @(); off = @(); round = 1; phase = 'verify'
        history = @(); culprit = $null; outcome = $null; stepAt = (Get-Date).ToString('s'); baseLog = $(if ($brief) { $brief.log } else { $null }); errors = @()
    }
    Save-BisectState $b
    $fail = Set-ModsEnabled $ok $false $Job
    $b.off = @($ok); $b.errors = @($fail); $b.stepAt = (Get-Date).ToString('s')
    Save-BisectState $b
    "Turned off $($ok.Count) mod(s). Launch the game and report what happened."
}

function Submit-BisectResult([bool]$Ok, $Job) {
    $b = Get-BisectState
    if (-not $b -or $b.phase -eq 'done') { throw 'No troubleshooting step is waiting for a result' }
    Assert-GameReady
    $sus = @($b.suspects); $test = @($b.testing)
    $hist = [Collections.Generic.List[object]]::new([object[]]@($b.history))
    $hist.Add([ordered]@{ round = $b.round; phase = $b.phase; on = $test; off = @($sus | Where-Object { $test -notcontains $_ }); result = $(if ($Ok) { 'ok' } else { 'problem' }); at = (Get-Date).ToString('s') })
    $b.history = @($hist)
    $toOn = @(); $toOff = @()
    if ($b.phase -eq 'verify') {
        if (-not $Ok) { $b.phase = 'done'; $b.outcome = 'notInScope' }
        elseif ($sus.Count -eq 1) { $b.phase = 'done'; $b.outcome = 'found'; $b.culprit = $sus[0] }
        else { $b.testing = @(Get-Half $sus); $toOn = @($b.testing); $b.phase = 'test'; $b.round++ }
    }
    elseif (-not $Ok) {
        # the problem happened with only the tested half on: the half that was off is innocent and comes back
        $toOn = @($sus | Where-Object { $test -notcontains $_ })
        $sus = $test
        if ($sus.Count -le 1) { $b.phase = 'done'; $b.outcome = $(if ($sus.Count) { 'found' } else { 'inconsistent' }); $b.culprit = $(if ($sus.Count) { $sus[0] } else { $null }); $toOff = $sus }
        else { $b.testing = @(Get-Half $sus); $toOff = @($sus | Where-Object { $b.testing -notcontains $_ }); $b.round++ }
        $b.suspects = $sus
    }
    else {
        $sus = @($sus | Where-Object { $test -notcontains $_ })
        $b.suspects = $sus
        if ($sus.Count -eq 0) { $b.phase = 'done'; $b.outcome = 'inconsistent'; $b.testing = @() }
        elseif ($sus.Count -eq 1) { $b.phase = 'done'; $b.outcome = 'found'; $b.culprit = $sus[0]; $b.testing = @() }
        else { $b.testing = @(Get-Half $sus); $toOn = @($b.testing); $b.round++ }
    }
    Save-BisectState $b
    $fail = [Collections.Generic.List[string]]::new()
    if ($toOn.Count) { $fail.AddRange([string[]]@(Set-ModsEnabled $toOn $true $Job)) }
    if ($toOff.Count) { $fail.AddRange([string[]]@(Set-ModsEnabled $toOff $false $Job)) }
    $disNow = @((Get-State).disabled | ForEach-Object { $_.name })
    $b.off = @($b.scope | Where-Object { $disNow -contains $_ })
    if ($b.phase -eq 'done') { $b.testing = @() }
    $b.errors = @($fail); $b.stepAt = (Get-Date).ToString('s')
    $brief = try { Get-LaunchBrief } catch { $null }
    $b.baseLog = $(if ($brief) { $brief.log } else { $null })
    Save-BisectState $b
    switch ($b.outcome) {
        'found' { "Found it: $($b.culprit). It stays off; everything else is back on." }
        'notInScope' { 'The problem happens even with all of them off, so it is not one of these mods.' }
        'inconsistent' { 'The results do not point to a single mod. It may need two mods together, or the problem does not happen every time.' }
        default { "Round $($b.round): $(@($b.suspects).Count) mods left to check. Launch the game again." }
    }
}

function Stop-Bisect([bool]$KeepCulprit, $Job) {
    $b = Get-BisectState
    if (-not $b) { throw 'Troubleshooting is not running' }
    Assert-GameReady
    $s = Get-State
    $dis = @($s.disabled | ForEach-Object { $_.name })
    $back = @($b.scope | Where-Object { $dis -contains $_ -and -not ($KeepCulprit -and $_ -eq $b.culprit) })
    $fail = Set-ModsEnabled $back $true $Job
    Remove-Item -LiteralPath (Get-BisectFile) -Force -ErrorAction SilentlyContinue
    $msg = "Turned $($back.Count) mod(s) back on"
    if ($KeepCulprit -and $b.culprit) { $msg += "; $($b.culprit) stays off" }
    if ($fail.Count) { $msg += ". Problems: $($fail -join '; ')" }
    $msg
}
#endregion

Export-ModuleMember -Function *
