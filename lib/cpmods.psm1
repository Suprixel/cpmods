# cpmods core: game state, tracked install/remove, frameworks, Nexus API
$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.11.0'
# App: the program files. Root: the data (config, state, downloads, backups). They share a folder in a git or older copy
# (config.json beside the program); an installed copy keeps data in %LOCALAPPDATA%\cpmods, so an update can swap the app folder whole
$script:App = Split-Path -Parent $PSScriptRoot
$script:Root = if ([IO.File]::Exists((Join-Path $script:App 'config.json'))) { $script:App } else { Join-Path $env:LOCALAPPDATA 'cpmods' }
$script:Cfg = [IO.File]::ReadAllText((Join-Path $script:Root 'config.json')) | ConvertFrom-Json
$script:Game = $script:Cfg.gamePath
$script:NexusGame = $script:Cfg.nexusGame
$script:StateDir = Join-Path $script:Root 'state'
$script:StateFile = Join-Path $script:StateDir 'mods.json'
$script:SettingsFile = Join-Path $script:StateDir 'settings.json'
$script:ServerFile = Join-Path $script:StateDir 'server.json'
$script:KeyFile = Join-Path $script:StateDir 'nexus.key'
$script:QueueFile = Join-Path $script:Root 'queue.json'
$script:FwFile = Join-Path $script:App 'frameworks.json'
$script:DlDir = Join-Path $script:Root 'downloads'
$script:BkDir = Join-Path $script:Root 'backup'
$script:TmpDir = Join-Path $script:Root 'tmp'
$script:LogFile = Join-Path $script:Root 'cpmods.log'
$script:Known = @('archive', 'bin', 'r6', 'red4ext', 'engine', 'mods')
$script:LogTag = 'cp'
$script:Quiet = $false
foreach ($d in $script:StateDir, $script:DlDir, $script:BkDir, $script:TmpDir) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d) }
}

#region basics
function Set-CpContext([string]$Tag, [bool]$Quiet = $false) { $script:LogTag = $Tag; $script:Quiet = $Quiet }
function Get-CpPaths { [ordered]@{ root = $script:Root; app = $script:App; game = $script:Game; downloads = $script:DlDir; state = $script:StateDir; log = $script:LogFile } }

function Write-Note([string]$Msg, [string]$Color = 'Gray') {
    if (-not $script:Quiet) { Write-Host $Msg -ForegroundColor $Color }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}{3}' -f (Get-Date), $script:LogTag, $Msg, [Environment]::NewLine
    for ($i = 0; $i -lt 8; $i++) { try { [IO.File]::AppendAllText($script:LogFile, $line); break } catch { Start-Sleep -Milliseconds 40 } }
}

# a name of only dots and spaces (possible in a shared mod list) would turn into '.' or '..' inside a path
function Get-SafeName([string]$N) { $s = $N -replace '[^\w\-. ]', '_'; if ($s -notmatch '\w') { $s = "_$s" }; $s }
function Get-SafeFileName([string]$N) {
    $bad = [IO.Path]::GetInvalidFileNameChars()
    -join ("$N".ToCharArray() | ForEach-Object { if ($bad -contains $_) { '_' } else { $_ } })
}
function Get-NormName([string]$N) { ("$N".ToLower() -replace '\bv?\d+(\.\d+)+[a-z]?\b', ' ' -replace '[^a-z0-9]+', ' ').Trim() }

function Read-JsonFile([string]$Path) {
    for ($i = 0; ; $i++) {
        try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable) }
        # a missing file is no lock that clears: fail now instead of after 20 retries (1.3 s)
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { throw }
        catch [IO.IOException] { if ($i -ge 20) { throw }; Start-Sleep -Milliseconds 50 }
    }
}

# Atomic replace so concurrent readers never see a half-written file
function Write-JsonFile([string]$Path, $Obj) {
    $tmp = '{0}.{1}.{2}.tmp' -f $Path, $PID, [Threading.Thread]::CurrentThread.ManagedThreadId
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Obj -Depth 12), [Text.UTF8Encoding]::new($false))
    for ($i = 0; ; $i++) {
        try { [IO.File]::Move($tmp, $Path, $true); return }
        catch { if ($i -ge 40) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }; Start-Sleep -Milliseconds 50 }
    }
}

# Cross-process lock shared by CLI, nxm handler and server jobs
function Use-Lock([scriptblock]$Body) {
    $mtx = [Threading.Mutex]::new($false, 'Local\cpmods')
    try { [void]$mtx.WaitOne() } catch [Threading.AbandonedMutexException] { }
    try { & $Body } finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
}

# first entry (full path) of a folder, or $null. Get-ChildItem | Select-Object -First 1 leaves its listing open
# until .NET cleans up, and an open listing stops Windows from moving the folder
function Get-FirstEntry([string]$Path, [string]$Filter = '*', [switch]$Recurse, [switch]$File) {
    if (-not [IO.Directory]::Exists($Path)) { return $null }
    $o = [IO.EnumerationOptions]::new(); $o.RecurseSubdirectories = [bool]$Recurse; $o.AttributesToSkip = 0
    # assigned per branch: $( ) or an if-expression would make PowerShell run the whole listing
    if ($File) { $en = [IO.Directory]::EnumerateFiles($Path, $Filter, $o) } else { $en = [IO.Directory]::EnumerateFileSystemEntries($Path, $Filter, $o) }
    $e = $en.GetEnumerator()
    try { if ($e.MoveNext()) { $e.Current } else { $null } } finally { $e.Dispose() }
}

function Get-7z {
    $c = Get-Command 7z -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") { if (Test-Path -LiteralPath $p) { return $p } }
    $null
}

# 7-Zip when available; plain .zip also works without it
function Expand-ModArchive([string]$Archive, [string]$Dest) {
    $z = Get-7z
    if ($z) {
        $o = & $z x -y "-o$Dest" -- $Archive 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed ($LASTEXITCODE): $(($o | Select-Object -Last 3) -join ' ')" }
        return
    }
    if ([IO.Path]::GetExtension($Archive) -ieq '.zip') { Expand-Archive -LiteralPath $Archive -DestinationPath $Dest -Force; return }
    throw "This mod is a $([IO.Path]::GetExtension($Archive)) archive and needs 7-Zip: winget install 7zip.7zip"
}

# The files inside an archive (path with "\", size), folders left out; 7-Zip when available, plain .zip without it
function Get-ArchiveFileList([string]$Archive) {
    $out = [Collections.Generic.List[object]]::new()
    $z = Get-7z
    if ($z) {
        $lines = & $z l -slt -- $Archive 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cannot read archive: $([IO.Path]::GetFileName($Archive))" }
        # the block before the ----- line describes the archive itself
        $body = $false; $cur = $null
        foreach ($ln in $lines) {
            $t = "$ln"
            if (-not $body) { if ($t -match '^-{5,}\s*$') { $body = $true }; continue }
            if ($t -match '^Path = (.+)$') { if ($cur) { $out.Add($cur) }; $cur = @{ path = $Matches[1]; size = [long]0; dir = $false } }
            elseif ($cur -and $t -match '^Size = (\d+)') { $cur.size = [long]$Matches[1] }
            elseif ($cur -and ($t -match '^Folder = \+' -or $t -match '^Attributes = D')) { $cur.dir = $true }
        }
        if ($cur) { $out.Add($cur) }
    }
    elseif ([IO.Path]::GetExtension($Archive) -ieq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zf = [IO.Compression.ZipFile]::OpenRead($Archive)
        try { foreach ($e in $zf.Entries) { $out.Add(@{ path = $e.FullName.TrimEnd('/'); size = [long]$e.Length; dir = $e.FullName.EndsWith('/') }) } }
        finally { $zf.Dispose() }
    }
    else { throw '7-Zip is required to read this archive' }
    @($out | Where-Object { -not $_.dir -and $_.path } | ForEach-Object { [pscustomobject]@{ path = ($_.path -replace '/', '\'); size = $_.size } })
}
#endregion

#region settings / state / queue
function Get-CpSettings {
    $s = [ordered]@{ patchLabel = '2.5'; patchDate = '2026-10-22'; autoInstall = $true; autoNext = $true; browser = ''; launchMode = 'steam'; reportOnExit = $true; warnRisk = $true
        askOverwrite = $true; saveBackup = $true; saveKeep = 5; autoRestore = $true; pruneOld = $true
    }
    if (Test-Path -LiteralPath $script:SettingsFile) {
        $j = Read-JsonFile $script:SettingsFile
        foreach ($k in @($j.Keys)) { if ($s.Contains($k)) { $s[$k] = $j[$k] } }
    }
    $dt = [datetime]::ParseExact("$($s.patchDate)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $s.patchEpoch = [DateTimeOffset]::new($dt, [TimeSpan]::Zero).ToUnixTimeSeconds()
    $s
}

function Save-CpSettings($Changes) {
    $cur = Get-CpSettings
    $cur.Remove('patchEpoch')
    foreach ($k in @($Changes.Keys)) {
        if (-not $cur.Contains($k)) { continue }
        $v = $Changes[$k]
        if ($k -eq 'patchDate') { [void][datetime]::ParseExact("$v", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); $v = "$v" }
        elseif ($k -in 'autoInstall', 'autoNext', 'reportOnExit', 'warnRisk', 'askOverwrite', 'saveBackup', 'autoRestore', 'pruneOld') { $v = [bool]$v }
        elseif ($k -eq 'saveKeep') { $v = [int]$v; if ($v -lt 1 -or $v -gt 30) { throw 'saveKeep must be 1 to 30' } }
        elseif ($k -eq 'launchMode') { $v = "$v"; if ($v -notin 'steam', 'direct') { throw 'launchMode must be steam or direct' } }
        elseif ($k -eq 'browser') { $v = "$v".Trim(); if ($v -and -not (Test-Path -LiteralPath $v -PathType Leaf)) { throw "Browser not found: $v" } }
        else { $v = "$v".Trim(); if (-not $v) { continue } }
        $cur[$k] = $v
    }
    Write-JsonFile $script:SettingsFile $cur
    Get-CpSettings
}

function Get-Frameworks { @(Read-JsonFile $script:FwFile) }

function Get-State {
    $s = if (Test-Path -LiteralPath $script:StateFile) { Read-JsonFile $script:StateFile } else { $null }
    if ($null -eq $s) { $s = [ordered]@{} }
    foreach ($k in 'mods', 'pending', 'failed', 'disabled') {
        $s[$k] = [Collections.Generic.List[object]]::new([object[]]@($s[$k] | Where-Object { $_ }))
    }
    $fws = $null
    foreach ($m in $s.mods) {
        if (-not $m.modId -and "$($m.source)".StartsWith('github:')) {
            if (-not $fws) { $fws = Get-Frameworks }
            $f = $fws | Where-Object { "github:$($_.repo)" -eq $m.source } | Select-Object -First 1
            if ($f -and $f.nexusId) { $m.modId = [int]$f.nexusId }
        }
    }
    $s
}
function Save-State($S) { Write-JsonFile $script:StateFile $S }

function Get-Queue { if (Test-Path -LiteralPath $script:QueueFile) { @(Read-JsonFile $script:QueueFile | Where-Object { $_ }) } else { @() } }
function Save-Queue($Q) { Write-JsonFile $script:QueueFile @($Q) }

function Get-NexusPageUrl([int]$ModId, [int]$FileId) { "https://www.nexusmods.com/$($script:NexusGame)/mods/$ModId`?tab=files&file_id=$FileId&nmm=1" }

# Marks a queue entry done; returns $true when it was an open queue item
function Set-QueueItemDone([int]$ModId, [int]$FileId) {
    Use-Lock {
        $q = Get-Queue
        $hit = $false
        foreach ($x in $q) { if ([int]$x.modId -eq $ModId -and [int]$x.fileId -eq $FileId -and -not $x.done) { $x.done = $true; $hit = $true } }
        if ($hit) { Save-Queue $q }
        $hit
    }
}

function Open-NextQueue {
    $n = Get-Queue | Where-Object { -not $_.done } | Select-Object -First 1
    if (-not $n) { return $null }
    [void](Open-UrlInFront (Get-NexusPageUrl ([int]$n.modId) ([int]$n.fileId)))
    Write-Note "Opened download page: $($n.name)"
    $n
}
#endregion

#region game
# The game plus the helpers it leaves behind (launcher, crash reporter); any of them keeps Steam on "Running"
$script:GameProcs = 'Cyberpunk2077', 'REDEngineErrorReporter', 'REDprelauncher'
function Get-GameProcesses { @(Get-Process -Name $script:GameProcs -ErrorAction SilentlyContinue) }

function Get-GameState {
    $exe = Join-Path $script:Game 'bin\x64\Cyberpunk2077.exe'
    $man = if ($script:Cfg.steamManifest -and (Test-Path -LiteralPath $script:Cfg.steamManifest)) { [IO.File]::ReadAllText($script:Cfg.steamManifest) } else { '' }
    $flags = 0
    [void][int]::TryParse([regex]::Match($man, '"StateFlags"\s+"(\d+)"').Groups[1].Value, [ref]$flags)
    $build = [regex]::Match($man, '"buildid"\s+"(\d+)"').Groups[1].Value
    $target = [regex]::Match($man, '"TargetBuildID"\s+"(\d+)"').Groups[1].Value
    $vi = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).VersionInfo } else { $null }
    $procs = @(Get-GameProcesses | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    [ordered]@{
        version       = $(if ($vi) { $vi.ProductVersion } else { $null })
        fileVersion   = $(if ($vi) { $vi.FileVersion } else { $null })
        build         = $build
        target        = $target
        updatePending = (($flags -band 2) -ne 0) -or ($target -and $target -ne '0' -and $target -ne $build)
        running       = $procs -contains 'Cyberpunk2077'
        procs         = $procs
        missing       = -not $vi
    }
}

# Force-closes the game and its launcher/crash reporter; waits until they are gone
function Stop-GameProcesses {
    $ps = @(Get-GameProcesses)
    $names = @($ps | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    foreach ($p in $ps) { try { $p.Kill() } catch { Write-Note "Could not close $($p.ProcessName) (pid $($p.Id)): $($_.Exception.Message)" } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-GameProcesses).Count -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 250 }
    $left = @(Get-GameProcesses | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    if ($names) { Write-Note "Force-closed $($names -join ', ')$(if ($left) { "; still open: $($left -join ', ')" })" }
    [ordered]@{ stopped = $names; left = $left }
}

function Assert-GameReady([switch]$Force) {
    $g = Get-GameState
    if ($g.running) { throw 'Cyberpunk is running; close the game first' }
    if ($g.updatePending -and -not $Force) { throw "Steam update pending (build $($g.build) -> $($g.target)); update the game first" }
    if (Test-Path -LiteralPath (Join-Path $script:StateDir 'vanilla.json')) { throw 'Your mods are set aside for a launch without mods. Bring them back first.' }
}

function Test-AskOverwrite { [bool](Get-CpSettings).askOverwrite }
#endregion

#region install / remove
# Where each file of a mod goes in the game folder, from its paths inside the archive (relative, "\").
# The one rule for both the install (extracted files) and the Downloads preview (archive listing).
function Get-LayoutPlan([string[]]$Paths, [string]$ModName) {
    $r = [ordered]@{ files = [Collections.Generic.List[object]]::new(); skipped = [Collections.Generic.List[string]]::new(); variants = @(); fomod = $false }
    if ($Paths | Where-Object { $_ -match '(^|\\)fomod\\ModuleConfig\.xml$' }) { $r.fomod = $true; return $r }
    # folders holding a game root folder (archive, bin, r6...): '' = the archive's top
    $cands = @{}
    foreach ($p in $Paths) {
        $parts = $p -split '\\'
        for ($i = 0; $i -lt $parts.Count - 1; $i++) { if ($script:Known -contains $parts[$i]) { $cands[$(if ($i -eq 0) { '' } else { $parts[0..($i - 1)] -join '\' })] = $true } }
    }
    if ($cands.Count) {
        $depth = @{}; foreach ($k in $cands.Keys) { $depth[$k] = if ($k) { ($k -split '\\').Count } else { 0 } }
        $min = ($depth.Values | Measure-Object -Minimum).Minimum
        $top = @($cands.Keys | Where-Object { $depth[$_] -eq $min } | Sort-Object)
        if ($top.Count -gt 1) { $r.variants = $top; return $r }
        $pre = if ($top[0]) { $top[0] + '\' } else { '' }
        foreach ($p in $Paths) {
            $rel = if (-not $pre) { $p } elseif ($p.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($pre.Length) } else { '' }
            if ($rel.Contains('\') -and $script:Known -contains ($rel -split '\\')[0]) { $r.files.Add(@{ From = $p; Rel = $rel }) } else { $r.skipped.Add($p) }
        }
        return $r
    }
    $safe = Get-SafeName $ModName
    $cet = $Paths | Where-Object { [IO.Path]::GetFileName($_) -ieq 'init.lua' } | Sort-Object Length | Select-Object -First 1
    $cetDir = if ($cet) { [IO.Path]::GetDirectoryName($cet) } else { '' }
    # init.lua at the archive's top: the CET folder is named after the mod
    $cetName = if ($cetDir) { [IO.Path]::GetFileName($cetDir) } else { $safe }
    foreach ($p in $Paths) {
        $ext = [IO.Path]::GetExtension($p).ToLower()
        if ($cet -and (-not $cetDir -or $p.StartsWith("$cetDir\", [StringComparison]::OrdinalIgnoreCase))) {
            $rel = "bin\x64\plugins\cyber_engine_tweaks\mods\$cetName\" + $(if ($cetDir) { $p.Substring($cetDir.Length + 1) } else { $p })
        }
        elseif ($ext -in '.archive', '.xl', '.archivexl') { $rel = "archive\pc\mod\$([IO.Path]::GetFileName($p))" }
        elseif ($ext -eq '.reds') { $rel = "r6\scripts\$safe\$p" }
        elseif ($ext -in '.yaml', '.yml') { $rel = "r6\tweaks\$safe\$p" }
        else { $r.skipped.Add($p); continue }
        $r.files.Add(@{ From = $p; Rel = $rel })
    }
    $r
}

# Maps extracted files to game-relative paths; throws on FOMOD or ambiguous variants
function Get-ModLayout([string]$Dir, [string]$ModName) {
    $plan = Get-LayoutPlan @(Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($Dir, $_.FullName) }) $ModName
    if ($plan.fomod) { throw 'FOMOD installer: pick an option folder' }
    if ($plan.variants) { throw ('Multiple variants, pick one: ' + (($plan.variants | ForEach-Object { if ($_) { $_ } else { '.' } }) -join ' | ')) }
    foreach ($p in $plan.skipped) { Write-Note "  skip $p" DarkGray }
    if (-not $plan.files.Count) { throw 'Unrecognized archive layout' }
    $map = [Collections.Generic.List[object]]::new()
    foreach ($f in $plan.files) { $map.Add(@{ Src = (Join-Path $Dir $f.From); Rel = $f.Rel }) }
    , $map
}

# Adopted mods have no archive to reinstall from, so their files go to the Recycle Bin
function Remove-ToRecycleBin([string]$Path, [switch]$Directory) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
    $rc = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    if ($Directory) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $rc) }
    else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $rc) }
}

# Copies a mod's own version of some files back from its download; returns the files restored
function Restore-ModFiles($Mod, [string[]]$Rels, [string]$To = $script:Game) {
    if (-not $Rels -or -not $Mod -or -not $Mod.archive -or -not (Test-Path -LiteralPath $Mod.archive)) { return @() }
    $tmp = Join-Path $script:TmpDir ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp)
    try {
        Expand-ModArchive $Mod.archive $tmp
        $map = Get-ModLayout $(if ($Mod.sub) { Join-Path $tmp $Mod.sub } else { $tmp }) $Mod.name
        Set-LoadOrderNames $map
        @(foreach ($e in $map) {
                if ($Rels -notcontains $e.Rel) { continue }
                $d = Join-Path $To $e.Rel
                [void](New-Item -ItemType Directory -Force -Path (Split-Path $d))
                Copy-Item -LiteralPath $e.Src -Destination $d -Force; $e.Rel
            })
    }
    catch { Write-Note "  could not read the download of $($Mod.name): $($_.Exception.Message)" DarkYellow; @() }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# 3-way merge of a JSON file two mods changed: each mod's changes against the original game file are kept. Objects merge
# key by key, lists of named items ("name"/"group_name"/"id") item by item; where both changed the same value, $Theirs
# wins and the spot ("FieldOfView.max_value") is listed in clashes. Formatting is not kept (the game reads JSON, not layout).
function Merge-JsonText([string]$Base, [string]$Ours, [string]$Theirs) {
    # values are passed by plain assignment, never through $( ) or if-expressions, which unwrap one-item lists
    $p = @{ AsHashtable = $true; Depth = 200; NoEnumerate = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $p.DateKind = 'String' }
    $none = [object]::new()
    $js = { param($v) if ([object]::ReferenceEquals($v, $none)) { '<none>' } else { ConvertTo-Json -InputObject $v -Compress -Depth 100 } }
    $keyOf = { param($v) if ($v -is [Collections.IDictionary]) { foreach ($k in 'name', 'group_name', 'id') { if ($v.Contains($k) -and $v[$k] -is [string]) { return "$($v[$k])" } } }; '' }
    $clash = [Collections.Generic.List[string]]::new()
    # results are wrapped in a hashtable so PowerShell never unrolls a list on return
    function Merge-Value($b, $x, $y, [string]$at) {
        $sb = & $js $b; $sx = & $js $x; $sy = & $js $y
        # case-sensitive: "kmh" -> "KMH" is a change
        if ($sx -ceq $sy -or $sb -ceq $sy) { return @{ v = $x } }
        if ($sb -ceq $sx) { return @{ v = $y } }
        if ($x -is [Collections.IDictionary] -and $y -is [Collections.IDictionary]) {
            $bo = if ($b -is [Collections.IDictionary]) { $b } else { @{} }
            $r = [ordered]@{}
            foreach ($k in @(@($x.Keys) + @($y.Keys | Where-Object { -not $x.Contains($_) }))) {
                $vb = $none; $vx = $none; $vy = $none
                if ($bo.Contains($k)) { $vb = $bo[$k] }; if ($x.Contains($k)) { $vx = $x[$k] }; if ($y.Contains($k)) { $vy = $y[$k] }
                $m = Merge-Value $vb $vx $vy $(if ($at) { "$at.$k" } else { $k })
                if (-not [object]::ReferenceEquals($m.v, $none)) { $r[$k] = $m.v }
            }
            return @{ v = $r }
        }
        if ($x -is [array] -and $y -is [array]) {
            $ba = @(); if ($b -is [array]) { $ba = $b }
            $kb = @($ba | ForEach-Object { & $keyOf $_ }); $kx = @($x | ForEach-Object { & $keyOf $_ }); $ky = @($y | ForEach-Object { & $keyOf $_ })
            $uniq = { param($l) $l.Count -eq @($l | Sort-Object -Unique).Count -and $l -notcontains '' }
            if ((& $uniq $kb) -and (& $uniq $kx) -and (& $uniq $ky)) {
                $mb = @{}; $mx = @{}; $my = @{}
                for ($i = 0; $i -lt $kb.Count; $i++) { $mb[$kb[$i]] = $ba[$i] }
                for ($i = 0; $i -lt $kx.Count; $i++) { $mx[$kx[$i]] = $x[$i] }
                for ($i = 0; $i -lt $ky.Count; $i++) { $my[$ky[$i]] = $y[$i] }
                $out = [Collections.Generic.List[object]]::new()
                foreach ($k in @(@($kx) + @($ky | Where-Object { $kx -notcontains $_ }))) {
                    $vb = $none; $vx = $none; $vy = $none
                    if ($mb.ContainsKey($k)) { $vb = $mb[$k] }; if ($mx.ContainsKey($k)) { $vx = $mx[$k] }; if ($my.ContainsKey($k)) { $vy = $my[$k] }
                    $m = Merge-Value $vb $vx $vy $k
                    if (-not [object]::ReferenceEquals($m.v, $none)) { $out.Add($m.v) }
                }
                return @{ v = $out.ToArray() }
            }
        }
        $clash.Add($(if ($at) { $at } else { '(whole file)' }))
        @{ v = $y }
    }
    $m = Merge-Value (ConvertFrom-Json $Base @p) (ConvertFrom-Json $Ours @p) (ConvertFrom-Json $Theirs @p) ''
    [ordered]@{ text = (ConvertTo-Json -InputObject $m.v -Depth 100); clashes = @($clash | Select-Object -Unique) }
}
# the original game file of a path some mod replaced (its vanilla backup), or $null
function Get-BaseCopy($S, [string]$Rel) {
    foreach ($m in $S.mods) { if (@($m.backups) -contains $Rel) { $p = Join-Path $script:BkDir (Join-Path (Get-SafeName $m.name) $Rel); if (Test-Path -LiteralPath $p) { return $p } } }
    $null
}
# the copy of $Rel the other mods keep once $Old (the version being replaced) is removed, as Remove-ModCore leaves it:
# Old on top: the copy it replaced (saved, or from the other mod's download); Old below a combined copy: the other mod's own copy
function Get-CopyWithout($S, $Old, [string]$Rel, [string]$Tmp) {
    $disk = Join-Path $script:Game $Rel
    $next = @($S.mods | Where-Object { -not [object]::ReferenceEquals($_, $Old) -and @($_.files) -contains $Rel } | Sort-Object { "$($_.installed)" }) | Select-Object -Last 1
    if (-not $next) { return $disk }
    $onTop = "$($Old.installed)" -gt "$($next.installed)"
    if ($onTop -and (@($Old.under) | Where-Object { $_ -and $_.path -eq $Rel -and $_.owner -eq $next.name })) {
        $bk = Join-Path $script:BkDir (Join-Path (Get-SafeName $Old.name) $Rel)
        if (Test-Path -LiteralPath $bk) { return $bk }
    }
    if ($onTop -or @($next.merged) -contains $Rel) {
        $to = Join-Path $Tmp '.cpmods-below'
        if (@(Restore-ModFiles $next @($Rel) $to).Count) { return (Join-Path $to $Rel) }
    }
    $disk
}
# merged text of the copy on disk and a new copy, or $null when they cannot be combined (no original, not JSON, unreadable).
# $Old: for an update, the installed version; its changes are left out of the copy on disk
function Get-MergedFile($S, [string]$Rel, [string]$NewCopy, $Old, [string]$Tmp) {
    $base = Get-BaseCopy $S $Rel
    if (-not $base -or $Rel -notlike '*.json') { return $null }
    $ours = if ($Old -and @($Old.files) -contains $Rel) { Get-CopyWithout $S $Old $Rel $Tmp } else { Join-Path $script:Game $Rel }
    try { Merge-JsonText ([IO.File]::ReadAllText($base)) ([IO.File]::ReadAllText($ours)) ([IO.File]::ReadAllText($NewCopy)) } catch { $null }
}

# Shared files go back to the mod that stays: its copy replaces this one, and the original game file moves to it
function Remove-ModCore($S, $M, [switch]$Purge) {
    $others = @($S.mods | Where-Object { -not [object]::ReferenceEquals($_, $M) })
    $safe = Get-SafeName $M.name
    $plain = [Collections.Generic.List[string]]::new()
    $fetch = @{}
    $heir = @{}
    foreach ($rel in @($M.files)) {
        $dest = Join-Path $script:Game $rel
        $bk = Join-Path $script:BkDir (Join-Path $safe $rel)
        $owners = @($others | Where-Object { @($_.files) -contains $rel } | Sort-Object { "$($_.installed)" })
        $waiting = @($others | Where-Object { @($_.keepOthers) -contains $rel } | Sort-Object { "$($_.installed)" })
        $next = if ($owners) { $owners[-1] } elseif ($waiting) { $waiting[-1] } else { $null }
        if ($next) { $heir[$rel] = $next }
        # the copy on disk belongs to whichever owner installed last
        if ($owners -and "$($M.installed)" -lt "$($owners[-1].installed)") {
            # the copy in use was combined with this mod's changes: the mod on top gets its own copy back
            if (@($next.merged) -contains $rel) { if (-not $fetch.ContainsKey($next.name)) { $fetch[$next.name] = [Collections.Generic.List[string]]::new() }; $fetch[$next.name].Add($rel) }
            else { Write-Note "  kept (the copy of $($next.name) is in use): $rel" DarkGray }
            continue
        }
        if (-not $next) { $plain.Add($rel); continue }
        $u = @($M.under) | Where-Object { $_ -and $_.path -eq $rel -and $_.owner -eq $next.name } | Select-Object -First 1
        if ($u -and (Test-Path -LiteralPath $bk)) { Copy-Item -LiteralPath $bk -Destination $dest -Force; Write-Note "  put back the copy of $($next.name): $rel" DarkYellow; continue }
        if (-not $fetch.ContainsKey($next.name)) { $fetch[$next.name] = [Collections.Generic.List[string]]::new() }
        $fetch[$next.name].Add($rel)
    }
    foreach ($n in @($fetch.Keys)) {
        $mm = $others | Where-Object { $_.name -eq $n } | Select-Object -First 1
        $done = @(Restore-ModFiles $mm @($fetch[$n]))
        if ($done) { Write-Note "  put back the copy of $n for $($done.Count) file(s)" DarkYellow }
        foreach ($rel in @($fetch[$n])) {
            if ($done -contains $rel) {
                if (@($mm.keepOthers) -contains $rel) { $mm.keepOthers = @($mm.keepOthers | Where-Object { $_ -ne $rel }); $mm.files = @(@($mm.files) + $rel) }
                if (@($mm.merged) -contains $rel) { $mm.merged = @($mm.merged | Where-Object { $_ -ne $rel }) }
            }
            elseif (@($mm.files) -contains $rel) { Write-Note "  the download of $n is gone: its copy of $rel could not be put back (this mod's copy stays)" Yellow }
            else { $heir.Remove($rel); $plain.Add($rel) }
        }
    }
    foreach ($rel in @($heir.Keys)) {
        $bk = Join-Path $script:BkDir (Join-Path $safe $rel)
        if (-not (@($M.backups) -contains $rel -and (Test-Path -LiteralPath $bk))) { continue }
        $nx = $heir[$rel]
        $nb = Join-Path $script:BkDir (Join-Path (Get-SafeName $nx.name) $rel)
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $nb))
        Copy-Item -LiteralPath $bk -Destination $nb -Force
        $nx.backups = @(@($nx.backups) + $rel | Select-Object -Unique)
    }
    foreach ($rel in $plain) {
        $dest = Join-Path $script:Game $rel
        $bk = Join-Path $script:BkDir (Join-Path $safe $rel)
        if (@($M.backups) -contains $rel) {
            # a base game file: never deleted, even when its saved original is gone
            if (Test-Path -LiteralPath $bk) { Copy-Item -LiteralPath $bk -Destination $dest -Force }
            else { Write-Note "  kept $rel (its original game file copy is missing; Steam 'Verify integrity' restores the original)" Yellow }
        }
        elseif (Test-Path -LiteralPath $dest) { if ($M.adopted) { Remove-ToRecycleBin $dest } else { Remove-Item -LiteralPath $dest -Force } }
    }
    foreach ($d in (@($M.dirs) | Sort-Object { $_.Length } -Descending)) {
        $p = Join-Path $script:Game $d
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $empty = -not (Get-FirstEntry $p)
        $foreign = $others | ForEach-Object { @($_.files) } | Where-Object { $_.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($empty) { Remove-Item -LiteralPath $p -Force }
        elseif ($Purge -and -not $foreign) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Note "  purged $d" DarkYellow }
    }
    Remove-Item -LiteralPath (Join-Path $script:BkDir $safe) -Recurse -Force -ErrorAction SilentlyContinue
    [void]$S.mods.Remove($M)
}

# -Ask: when other mods already installed some of the files, return @{ conflict } and install nothing.
# -OnConflict keep: leave their files alone; overwrite: replace them. Neither: earlier "keep" choices (meta keepOthers) still hold.
function Install-ModArchive {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][Collections.IDictionary]$Meta, [switch]$Force, [switch]$Ask, [string]$OnConflict)
    Assert-GameReady -Force:$Force
    if ($OnConflict -and $OnConflict -notin 'keep', 'overwrite', 'merge') { throw "Unknown choice $OnConflict" }
    if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
    if ($Meta.sub -and ([IO.Path]::IsPathRooted("$($Meta.sub)") -or "$($Meta.sub)" -match '(^|[\\/])\.\.([\\/]|$)')) { throw "Invalid folder in the archive: $($Meta.sub)" }
    $tmp = Join-Path $script:TmpDir ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp)
    try {
        Expand-ModArchive $Archive $tmp
        $src = if ($Meta.sub) { Join-Path $tmp $Meta.sub } else { $tmp }
        if (-not (Test-Path -LiteralPath $src)) { throw "Folder not found in archive: $($Meta.sub)" }
        $map = Get-ModLayout $src $Meta.name
        Set-LoadOrderNames $map
        $s = Get-State
        # files other mods installed; another file of the same Nexus mod is meant to replace them
        $mid = [int]$Meta.modId
        $old = $s.mods | Where-Object { $_.name -eq $Meta.name } | Select-Object -First 1
        $clash = @(foreach ($e in $map) {
                $o = @($s.mods | Where-Object { $_.name -ne $Meta.name -and -not ($mid -and [int]$_.modId -eq $mid) -and @($_.files) -contains $e.Rel })
                if (-not $o) { continue }
                $c = [ordered]@{ path = $e.Rel; owners = @($o | ForEach-Object { $_.name }) }
                # can both be kept? (a JSON game file both mods edited); the values both changed are listed
                if ($Ask) { $mg = Get-MergedFile $s $e.Rel $e.Src $old $tmp; if ($mg) { $c.merge = [ordered]@{ clashes = @($mg.clashes) } } }
                $c
            })
        $prev = @($Meta.keepOthers); $prevMerged = @($Meta.merged)
        if ($Ask -and -not $OnConflict -and @($clash | Where-Object { $prev -notcontains $_.path -and $prevMerged -notcontains $_.path }).Count) { return [pscustomobject]@{ conflict = $clash } }
        $keep = @($clash | ForEach-Object { $_.path } | Where-Object { $OnConflict -eq 'keep' -or (-not $OnConflict -and $prev -contains $_) })
        $mergeSet = @($clash | ForEach-Object { $_.path } | Where-Object { $OnConflict -eq 'merge' -or (-not $OnConflict -and $prevMerged -contains $_) })
        $merged = [Collections.Generic.List[string]]::new()
        if ($old) { Write-Note "Replacing $($old.name) $($old.version)"; Remove-ModCore $s $old }
        $safe = Get-SafeName $Meta.name
        $files = [Collections.Generic.List[string]]::new()
        $backups = [Collections.Generic.List[string]]::new()
        $under = [Collections.Generic.List[object]]::new()
        $dirs = [Collections.Generic.List[string]]::new()
        $copyError = $null
        try {
            foreach ($e in $map) {
                $dest = Join-Path $script:Game $e.Rel
                if ($keep -contains $e.Rel) { Write-Note "  kept the other mod's copy: $($e.Rel)" DarkYellow; continue }
                $owners = @($s.mods | Where-Object { @($_.files) -contains $e.Rel } | Sort-Object { "$($_.installed)" })
                if ($owners) {
                    Write-Note "  overwrites file from $($owners.name -join ', '): $($e.Rel)" DarkYellow
                    # the replaced copy comes back when this mod is removed, without reading the other download again
                    if ((Test-Path -LiteralPath $dest) -and -not ($under | Where-Object { $_.path -eq $e.Rel })) {
                        $bk = Join-Path $script:BkDir (Join-Path $safe $e.Rel)
                        [void](New-Item -ItemType Directory -Force -Path (Split-Path $bk))
                        Copy-Item -LiteralPath $dest -Destination $bk -Force
                        $under.Add([ordered]@{ path = $e.Rel; owner = $owners[-1].name })
                    }
                }
                elseif ((Test-Path -LiteralPath $dest) -and -not $backups.Contains($e.Rel)) {
                    $bk = Join-Path $script:BkDir (Join-Path $safe $e.Rel)
                    [void](New-Item -ItemType Directory -Force -Path (Split-Path $bk))
                    Copy-Item -LiteralPath $dest -Destination $bk -Force
                    $backups.Add($e.Rel)
                    Write-Note "  backed up existing $($e.Rel)" DarkYellow
                }
                $p = Split-Path $dest
                while (-not (Test-Path -LiteralPath $p)) { $dirs.Add([IO.Path]::GetRelativePath($script:Game, $p)); $p = Split-Path $p }
                [void](New-Item -ItemType Directory -Force -Path (Split-Path $dest))
                # combined with the other mod's copy when asked (falls back to replacing it when they cannot be combined)
                $mt = if ($mergeSet -contains $e.Rel) { Get-MergedFile $s $e.Rel $e.Src } else { $null }
                if ($mt) { [IO.File]::WriteAllText($dest, $mt.text, [Text.UTF8Encoding]::new($false)); $merged.Add($e.Rel); Write-Note "  combined with the other mod's copy: $($e.Rel)" DarkYellow }
                else { Copy-Item -LiteralPath $e.Src -Destination $dest -Force }
                if (-not $files.Contains($e.Rel)) { $files.Add($e.Rel) }
            }
        }
        catch { $copyError = $_.Exception.Message }
        $rec = [ordered]@{
            name = $Meta.name; version = $Meta.version; source = $Meta.source; modId = $Meta.modId; fileId = $Meta.fileId
            fileName = $Meta.fileName; sha256 = $Meta.sha256; archive = $Archive; sub = $Meta.sub
            installed = (Get-Date).ToString('s'); files = $files; backups = $backups; dirs = $dirs
        }
        if ($keep) { $rec.keepOthers = $keep }
        if ($merged.Count) { $rec.merged = $merged }
        if ($under.Count) { $rec.under = $under }
        if ($copyError) { $rec.broken = $copyError }
        # its earlier downloads, newest first: the last two stay for going back (Remove-OldDownloads deletes the rest)
        $older = [Collections.Generic.List[string]]::new()
        # a turned-off copy of this mod is replaced too: its downloads stay for going back
        $off = $s.disabled | Where-Object { $_.name -eq $Meta.name } | Select-Object -First 1
        foreach ($a in @($old.archive) + @($old.older) + @($off.archive) + @($off.older) + @($Meta.older)) { if ($a -and "$a" -ne $Archive -and -not $older.Contains("$a")) { $older.Add("$a") } }
        if ($older.Count) { $rec.older = @($older | Select-Object -First 2) }
        $s.mods.Add($rec)
        foreach ($k in 'pending', 'failed', 'disabled') {
            foreach ($x in @($s[$k] | Where-Object { $(if ($k -eq 'disabled') { $_.name } else { $_.meta.name }) -eq $Meta.name })) { [void]$s[$k].Remove($x) }
        }
        Save-State $s
        # its set-aside files (a mod found before cpmods) would be left behind unseen
        if ($off.parked -and (Test-Path -LiteralPath $off.parked)) { Remove-ToRecycleBin $off.parked -Directory }
        if ($copyError) { throw "Copy failed after $($files.Count) files: $copyError" }
        if ($older.Count -gt 2 -and (Get-CpSettings).pruneOld) { Remove-OldDownloads $s @($older | Select-Object -Skip 2) }
        Write-Note "Installed $($Meta.name) $($Meta.version) ($($files.Count) files)" Green
        $Meta.name
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# deletes downloads of earlier versions that no mod (on, off or waiting) still uses; only files in Downloads
function Remove-OldDownloads($S, [string[]]$Paths) {
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in 'mods', 'disabled') { foreach ($m in $S[$k]) { foreach ($a in @($m.archive) + @($m.older)) { if ($a) { [void]$used.Add("$a") } } } }
    foreach ($k in 'pending', 'failed') { foreach ($x in $S[$k]) { if ($x.archive) { [void]$used.Add("$($x.archive)") } } }
    foreach ($p in $Paths) {
        if ($used.Contains($p) -or [IO.Path]::GetDirectoryName($p) -ine $script:DlDir -or -not (Test-Path -LiteralPath $p)) { continue }
        try { Remove-Item -LiteralPath $p -Force; Write-Note "  deleted the old download $([IO.Path]::GetFileName($p))" DarkGray }
        catch { Write-Note "  could not delete the old download $([IO.Path]::GetFileName($p)) ($($_.Exception.Message))" DarkYellow }
    }
}

function Find-InstalledMod($S, [string]$N) {
    $hit = @($S.mods | Where-Object { $_.name -eq $N })
    if (-not $hit) { $hit = @($S.mods | Where-Object { $_.name -like "*$N*" }) }
    if ($hit.Count -ne 1) { throw "Match '$N' -> $($hit.Count) mods: $(($hit | ForEach-Object { $_.name }) -join ', ')" }
    $hit[0]
}

function Remove-InstalledMod([string]$Name, [switch]$Purge, [switch]$Force) {
    Assert-GameReady -Force:$Force
    $s = Get-State
    $d = $s.disabled | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($d) {
        if ($d.parked -and (Test-Path -LiteralPath $d.parked)) { Remove-ToRecycleBin $d.parked -Directory }
        [void]$s.disabled.Remove($d); Save-State $s
        # a "waiting for your choice" left by turning it back on would bring it back
        [void](Remove-Deferred $Name)
        Write-Note "Removed disabled entry $Name" Green; return
    }
    $m = Find-InstalledMod $s $Name
    Remove-ModCore $s $m -Purge:$Purge
    Save-State $s
    Write-Note "Removed $($m.name)" Green
}

function Disable-InstalledMod([string]$Name) {
    Assert-GameReady
    $s = Get-State
    $m = Find-InstalledMod $s $Name
    if ($m.adopted) {
        # no archive: move the files aside so Enable can put them back
        $park = Join-Path $script:Root ('parked\' + (Get-SafeName $m.name))
        $others = @($s.mods | Where-Object { -not [object]::ReferenceEquals($_, $m) })
        $moved = [Collections.Generic.List[string]]::new()
        foreach ($rel in @($m.files)) {
            $src = Join-Path $script:Game $rel
            if (-not (Test-Path -LiteralPath $src) -or ($others | Where-Object { @($_.files) -contains $rel })) { continue }
            $dst = Join-Path $park $rel
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $dst))
            Move-Item -LiteralPath $src -Destination $dst -Force
            $moved.Add($rel)
        }
        foreach ($d in (@($m.dirs) | Sort-Object { $_.Length } -Descending)) {
            $p = Join-Path $script:Game $d
            if ((Test-Path -LiteralPath $p) -and -not (Get-FirstEntry $p -Recurse -File)) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        [void]$s.mods.Remove($m)
        $s.disabled.Add([ordered]@{
                name = $m.name; version = $m.version; source = $m.source; modId = $m.modId; fileId = $null; fileName = $null
                adopted = $true; parked = $park; files = $moved; dirs = @($m.dirs); archive = $null; disabledAt = (Get-Date).ToString('s')
            })
        Save-State $s
        Write-Note "Disabled $($m.name) (files moved to $park)" Green
        return
    }
    if (-not $m.archive -or -not (Test-Path -LiteralPath $m.archive)) { throw "The archive for $($m.name) was deleted, so it could not be re-enabled. Use Remove instead." }
    $was = @($m.files)
    Remove-ModCore $s $m
    $s.disabled.Add([ordered]@{
            name = $m.name; version = $m.version; source = $m.source; modId = $m.modId; fileId = $m.fileId; fileName = $m.fileName
            sha256 = $m.sha256; sub = $m.sub; archive = $m.archive; disabledAt = (Get-Date).ToString('s'); files = $was; keepOthers = $m.keepOthers; merged = $m.merged; older = $m.older
        })
    Save-State $s
    Write-Note "Disabled $($m.name)" Green
}

# -Ask: when other mods now have some of its files, nothing changes and the conflict is returned (like an install)
function Enable-InstalledMod([string]$Name, [switch]$Ask) {
    $s = Get-State
    $d = $s.disabled | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $d) { throw "No disabled mod named $Name" }
    if ($d.parked) {
        Assert-GameReady
        $clash = @(@($d.files) | Where-Object { Test-Path -LiteralPath (Join-Path $script:Game $_) })
        if ($clash) { throw "Cannot enable $($d.name): $($clash.Count) of its files now exist in the game folder (e.g. $($clash[0]))" }
        foreach ($rel in @($d.files)) {
            $src = Join-Path $d.parked $rel
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $dst = Join-Path $script:Game $rel
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $dst))
            Move-Item -LiteralPath $src -Destination $dst
        }
        Remove-Item -LiteralPath $d.parked -Recurse -Force -ErrorAction SilentlyContinue
        [void]$s.disabled.Remove($d)
        $s.mods.Add([ordered]@{
                name = $d.name; version = $d.version; source = $d.source; modId = $d.modId; fileId = $null; fileName = $null; sha256 = $null
                archive = $null; sub = $null; adopted = $true; installed = (Get-Date).ToString('s'); files = @($d.files); backups = @(); dirs = @($d.dirs)
            })
        Save-State $s
        Write-Note "Enabled $($d.name)" Green
        return
    }
    $r = Install-ModArchive -Archive $d.archive -Meta (Copy-Meta $d) -Ask:$Ask
    if ($r.conflict) { $r }
}

function Copy-Meta($Src) {
    $o = [ordered]@{}
    foreach ($k in 'name', 'version', 'source', 'modId', 'fileId', 'fileName', 'sha256', 'sub', 'keepOthers', 'merged', 'older') { if ($null -ne $Src[$k]) { $o[$k] = $Src[$k] } }
    $o
}

function Add-Deferred([string]$Kind, [string]$Archive, [Collections.IDictionary]$Meta, [string]$Err, $Conflict) {
    $s = Get-State
    foreach ($x in @($s[$Kind] | Where-Object { $_.meta.name -eq $Meta.name })) { [void]$s[$Kind].Remove($x) }
    $e = [ordered]@{ archive = $Archive; meta = $Meta; error = $Err; at = (Get-Date).ToString('s') }
    if ($Conflict) { $e.conflict = @($Conflict) }
    $s[$Kind].Add($e)
    Save-State $s
}

function Remove-Deferred([string]$Name) {
    $s = Get-State
    $n = 0
    foreach ($k in 'pending', 'failed') { foreach ($x in @($s[$k] | Where-Object { $_.meta.name -eq $Name })) { [void]$s[$k].Remove($x); $n++ } }
    if ($n) { Save-State $s }
    $n
}

function Get-DeferredMeta([string]$Archive) {
    $s = Get-State
    foreach ($k in 'failed', 'pending') {
        $e = $s[$k] | Where-Object { "$($_.archive)" -eq $Archive } | Select-Object -First 1
        if ($e) { return (Copy-Meta $e.meta) }
    }
    foreach ($k in 'disabled', 'mods') {
        $e = $s[$k] | Where-Object { "$($_.archive)" -eq $Archive } | Select-Object -First 1
        if ($e) { return (Copy-Meta $e) }
    }
    $null
}

function Resolve-DownloadFile([string]$Leaf) {
    $n = [IO.Path]::GetFileName("$Leaf")
    # "." and ".." pass GetFileName unchanged but mean the downloads folder and the app folder
    if (-not $n -or $n -ne "$Leaf" -or $n -match '^\.+$') { throw 'Invalid file name' }
    $p = Join-Path $script:DlDir $n
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found in downloads: $n" }
    $p
}

function Get-DownloadsInfo($S) {
    if (-not $S) { $S = Get-State }
    $ref = @{}
    foreach ($m in $S.mods) { if ($m.archive) { $ref["$($m.archive)".ToLower()] = @('installed', $m.name, $m) } }
    foreach ($d in $S.disabled) { if ($d.archive) { $ref["$($d.archive)".ToLower()] = @('disabled', $d.name, $d) } }
    foreach ($p in $S.pending) { $ref["$($p.archive)".ToLower()] = @('pending', $p.meta.name, $p.meta) }
    foreach ($f in $S.failed) { $ref["$($f.archive)".ToLower()] = @('failed', $f.meta.name, $f.meta) }
    foreach ($f in Get-ChildItem -LiteralPath $script:DlDir -File | Where-Object { $_.Extension -ne '.part' } | Sort-Object LastWriteTime -Descending) {
        $r = $ref[$f.FullName.ToLower()]
        $x = if ($r) { $r[2] } else { $null }
        $mid = if ($x -and $x.modId) { [int]$x.modId } else { 0 }
        $fid = if ($x -and $x.fileId) { [int]$x.fileId } else { 0 }
        $ver = if ($x) { "$($x.version)" } else { '' }
        # Nexus file names carry the mod id: "Name 1234 1.0 2026-01-02T03-04Z abc.zip" or "Name-1234-1-0-1700000000.zip"
        if (-not $mid -and ($f.Name -match '^.+? (\d{2,7}) (\S+) \d{4}-\d{2}-\d{2}T\d{2}-\d{2}Z' -or $f.Name -match '^.+?-(\d{2,7})-([\w\-]+?)-\d{9,11}\.\w+$')) { $mid = [int]$Matches[1]; if (-not $ver) { $ver = $Matches[2] -replace '-', '.' } }
        [ordered]@{ file = $f.Name; size = $f.Length; date = $f.LastWriteTime.ToString('s'); status = $(if ($r) { $r[0] } else { 'unused' }); name = $(if ($r) { $r[1] } else { $null }); modId = $mid; fileId = $fid; version = $ver }
    }
}

# Lists folders inside an archive that look like a game root (for variant / FOMOD choice)
function Get-ArchiveCandidates([string]$Archive) {
    $paths = @(Get-ArchiveFileList $Archive | ForEach-Object { $_.path })
    $c = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $top = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $paths) {
        $parts = $p -split '[\\/]'
        [void]$top.Add($parts[0])
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if ($script:Known -contains $parts[$i]) { [void]$c.Add($(if ($i -eq 0) { '.' } else { $parts[0..($i - 1)] -join '\' })) }
        }
    }
    $list = @($c | Sort-Object { ($_ -split '\\').Count }, { $_ })
    $roots = @($list | Where-Object { $x = $_; -not ($list | Where-Object { $_ -ne $x -and ($_ -eq '.' -or $x.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase)) }) })
    [ordered]@{ candidates = $roots; fomod = [bool]($paths | Where-Object { $_ -match '(^|[\\/])fomod[\\/]ModuleConfig\.xml$' }); top = @($top); count = $paths.Count }
}
#endregion

#region load order: archive\pc\mod loads in ASCII name order and the first archive loaded wins a conflict
# rules (state\loadorder.json, key = original name in lower case) keep a renamed archive renamed after reinstalls and updates
function Get-LoadOrderRules {
    $f = Join-Path $script:StateDir 'loadorder.json'
    if (Test-Path -LiteralPath $f) { $r = Read-JsonFile $f; if ($r -is [Collections.IDictionary]) { return $r } }
    @{}
}
function Set-LoadOrderNames($Map) {
    $r = Get-LoadOrderRules
    if (-not $r.Count) { return }
    foreach ($e in $Map) { if ($e.Rel -like 'archive\pc\mod\*') { $x = $r[[IO.Path]::GetFileName($e.Rel).ToLower()]; if ($x) { $e.Rel = "archive\pc\mod\$($x.name)" } } }
}
function Rename-ModArchive($S, [string]$From, [string]$To) {
    $dir = Join-Path $script:Game 'archive\pc\mod'
    if (Test-Path -LiteralPath (Join-Path $dir $To)) { throw "$To already exists" }
    Move-Item -LiteralPath (Join-Path $dir $From) -Destination (Join-Path $dir $To)
    foreach ($m in $S.mods) { $m.files = @(@($m.files) | ForEach-Object { if ($_ -eq "archive\pc\mod\$From") { "archive\pc\mod\$To" } else { $_ } }) }
}
# makes $Archive load before $Over by adding "!" in front of its name ("!" sorts before letters, digits and #)
function Set-ArchiveWinner([string]$Archive, [string]$Over) {
    Assert-GameReady
    $r = Get-LoadOrderRules
    $k = @($r.Keys | Where-Object { $r[$_].name -eq $Archive }) | Select-Object -First 1
    $orig = if ($k) { "$($r[$k].orig)" } else { $Archive }
    $s = Get-State
    $m = $s.mods | Where-Object { @($_.files) -contains "archive\pc\mod\$Archive" } | Select-Object -First 1
    if (-not $m) { throw "$Archive is not managed by cpmods" }
    $first = { param($n) [string]::CompareOrdinal($n, $Over) -lt 0 -and [StringComparer]::OrdinalIgnoreCase.Compare($n, $Over) -lt 0 }
    # already loading first: nothing is renamed, the choice is only remembered
    if (& $first $Archive) { $to = $Archive }
    else {
        $p = '!'
        while (-not (& $first "$p$orig")) { $p += '!'; if ($p.Length -gt 16) { throw "No name sorts before $Over" } }
        $to = "$p$orig"
        Rename-ModArchive $s $Archive $to
    }
    # every archive it was chosen over (one per settled overlap)
    $beaten = @(@($(if ($k) { $r[$k].over })) + $Over | Where-Object { $_ } | Select-Object -Unique)
    $r[$orig.ToLower()] = [ordered]@{ orig = $orig; name = $to; over = $beaten; mod = $m.name; at = (Get-Date).ToString('s') }
    Write-JsonFile (Join-Path $script:StateDir 'loadorder.json') $r
    Save-State $s
    Write-Note "Load order: $to $(if ($to -eq $Archive -and $to -eq $orig) { 'already loads' } else { 'now loads' }) before $Over ($($m.name) wins, your choice)"
    $to
}
function Reset-ArchiveName([string]$Archive) {
    Assert-GameReady
    $r = Get-LoadOrderRules
    $k = @($r.Keys | Where-Object { $r[$_].name -eq $Archive -or $_ -eq $Archive.ToLower() }) | Select-Object -First 1
    if (-not $k) { throw "No load order change for $Archive" }
    $x = $r[$k]
    $s = Get-State
    if ($x.name -ne $x.orig -and (Test-Path -LiteralPath (Join-Path $script:Game "archive\pc\mod\$($x.name)"))) { Rename-ModArchive $s $x.name $x.orig; Save-State $s }
    $r.Remove($k)
    Write-JsonFile (Join-Path $script:StateDir 'loadorder.json') $r
    Write-Note "Load order: $($x.orig) has its own name again"
    "$($x.orig)"
}
#endregion

#region frameworks
function Install-GitHubFramework($Fw, [switch]$DownloadOnly, [switch]$Force) {
    $api = if ($Fw.tag) { "https://api.github.com/repos/$($Fw.repo)/releases/tags/$($Fw.tag)" } else { "https://api.github.com/repos/$($Fw.repo)/releases/latest" }
    $rel = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'cpmods' } -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -match $Fw.asset } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching $($Fw.asset) in $($Fw.repo) $($rel.tag_name)" }
    $cur = (Get-State).mods | Where-Object { $_.name -eq $Fw.name } | Select-Object -First 1
    if ($cur -and $cur.version -eq $rel.tag_name -and -not $Force) { Write-Note "$($Fw.name) $($rel.tag_name) up to date" DarkGray; return "$($Fw.name) up to date" }
    $out = Join-Path $script:DlDir $asset.name
    if (-not (Test-Path -LiteralPath $out)) {
        # .part until complete: an interrupted download never leaves a broken zip to reuse
        Save-UrlToFile $asset.browser_download_url $out
        if ($asset.digest -match '^sha256:([0-9a-f]+)$' -and (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -ne $Matches[1]) {
            Remove-Item -LiteralPath $out; throw "SHA256 mismatch: $($asset.name)"
        }
        Write-Note "Downloaded $($asset.name)"
    }
    if ($DownloadOnly) { return "$($Fw.name) downloaded" }
    Install-ModArchive -Archive $out -Meta ([ordered]@{ name = $Fw.name; version = $rel.tag_name; source = "github:$($Fw.repo)"; modId = $Fw.nexusId }) -Force:$Force | Out-Null
    "$($Fw.name) $($rel.tag_name) installed"
}

# -Names: only these frameworks (none = all)
function Invoke-Frameworks([switch]$Force, [string[]]$Names) {
    $pending = (Get-GameState).updatePending -and -not $Force
    if ($pending) { Write-Note 'Steam update pending: downloading frameworks only.' Yellow }
    # one framework failing (GitHub down or rate-limited) must not stop the others or the waiting mods after them
    foreach ($fw in @(Get-Frameworks | Where-Object { -not $Names -or $Names -contains $_.name })) {
        try { Install-GitHubFramework $fw -DownloadOnly:$pending -Force:$Force }
        catch { Write-Note "  $($fw.name) not updated: $($_.Exception.Message)" Yellow; "$($fw.name) not updated: $($_.Exception.Message)" }
    }
}

function Invoke-Sync([switch]$Force) {
    Invoke-Frameworks -Force:$Force
    if ((Get-GameState).updatePending -and -not $Force) { return }
    $ask = Test-AskOverwrite
    foreach ($p in @((Get-State).pending)) {
        if ($ask -and $p.conflict) { "Waiting for your choice: $($p.meta.name)"; continue }
        try {
            $r = Install-ModArchive -Archive $p.archive -Meta $p.meta -Ask:$ask
            if ($r.conflict) { Add-Deferred 'pending' $p.archive $p.meta '' $r.conflict; "Waiting for your choice: $($p.meta.name)" } else { "Installed $($p.meta.name)" }
        }
        catch { Write-Note "FAILED $($p.meta.name): $($_.Exception.Message)" Red; Add-Deferred 'failed' $p.archive $p.meta $_.Exception.Message; "Failed $($p.meta.name)" }
    }
}

function Get-FrameworkUpdates {
    $s = Get-State
    foreach ($fw in Get-Frameworks) {
        $cur = $s.mods | Where-Object { $_.name -eq $fw.name } | Select-Object -First 1
        $latest = $null; $err = $null
        try {
            $api = if ($fw.tag) { "https://api.github.com/repos/$($fw.repo)/releases/tags/$($fw.tag)" } else { "https://api.github.com/repos/$($fw.repo)/releases/latest" }
            $latest = (Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'cpmods' } -TimeoutSec 20).tag_name
        }
        catch { $err = $_.Exception.Message }
        [ordered]@{ name = $fw.name; nexusId = $fw.nexusId; installed = $cur.version; latest = $latest; pinned = [bool]$fw.tag; update = [bool]($latest -and $cur -and $cur.version -ne $latest); missing = (-not $cur); error = $err }
    }
}
#endregion

#region nexus
function Test-NexusKey { Test-Path -LiteralPath $script:KeyFile }

function Get-NexusKey {
    if (-not (Test-NexusKey)) { throw 'No Nexus API key. Run: cpmods setkey' }
    [Net.NetworkCredential]::new('', ([IO.File]::ReadAllText($script:KeyFile).Trim() | ConvertTo-SecureString)).Password
}

function Get-NexusHeaders([string]$Key) {
    if (-not $Key) { $Key = Get-NexusKey }
    @{ apikey = $Key; 'Application-Name' = 'cpmods'; 'Application-Version' = '2.0'; 'User-Agent' = 'cpmods/2.0' }
}

function Set-NexusKey([string]$Plain) {
    $Plain = "$Plain".Trim().Trim('"', "'").Trim()
    if ($Plain.Length -lt 20) { throw 'That is too short to be a Nexus API key. Copy the whole key from the Nexus page.' }
    try { $v = Invoke-RestMethod 'https://api.nexusmods.com/v1/users/validate.json' -Headers (Get-NexusHeaders $Plain) -TimeoutSec 20 }
    catch { throw "Nexus did not accept it: $(Get-HttpErrorText $_)" }
    [IO.File]::WriteAllText($script:KeyFile, ($Plain | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString))
    $v
}

# Readable message from a failed web request (Nexus returns {"message": ...})
function Get-HttpErrorText($Err) {
    $body = "$($Err.ErrorDetails.Message)"
    $code = try { [int]$Err.Exception.Response.StatusCode } catch { 0 }
    $msg = $null
    if ($body) { try { $j = $body | ConvertFrom-Json; $msg = if ($j.message) { $j.message } elseif ($j.error) { $j.error } } catch { $msg = $body.Substring(0, [Math]::Min(200, $body.Length)) } }
    if (-not $msg) { $msg = $Err.Exception.Message }
    if ($code) { "$msg (HTTP $code)" } else { $msg }
}

function Invoke-NexusV1([string]$Path) {
    try { Invoke-RestMethod "https://api.nexusmods.com/v1/$Path" -Headers (Get-NexusHeaders) -TimeoutSec 30 }
    catch { throw "Nexus API: $(Get-HttpErrorText $_)" }
}

# File details plus the archive manifest (file list, SHA256) Nexus publishes per upload
function Get-NexusFileInfo([int]$ModId, [int]$FileId) {
    $fi = Invoke-NexusV1 "games/$($script:NexusGame)/mods/$ModId/files/$FileId.json"
    $files = @(); $sha = $null
    if ($fi.content_preview_link) {
        try { $man = Invoke-RestMethod $fi.content_preview_link -TimeoutSec 20; $sha = $man.archive.hashes.SHA256; $files = @($man.files | ForEach-Object { $_.file_path }) } catch { }
    }
    $kinds = [ordered]@{}
    foreach ($p in $files) {
        $k = switch ([IO.Path]::GetExtension("$p").ToLower()) {
            '.reds' { 'redscript' } '.lua' { 'cet' } '.dll' { 'native' } '.asi' { 'native' }
            '.yaml' { 'tweak' } '.yml' { 'tweak' } '.tweak' { 'tweak' } '.xl' { 'archivexl' } '.archive' { 'archive' }
            '.ini' { 'config' } '.xml' { 'input' } '.json' { 'data' } default { 'other' }
        }
        $kinds[$k] = 1 + [int]$kinds[$k]
    }
    [ordered]@{
        name = $fi.name; version = $fi.version; fileName = $fi.file_name; size = $fi.size_in_bytes; uploaded = $fi.uploaded_timestamp
        category = $fi.category_name; sha256 = $sha; fileCount = $files.Count; files = @($files | Select-Object -First 400); kinds = $kinds
        fomod = [bool]($files | Where-Object { $_ -match '(^|/)fomod/ModuleConfig\.xml$' })
    }
}

function Resolve-NxmLink([string]$Url) {
    $m = [regex]::Match("$Url", '^nxm://(?<game>[^/]+)/mods/(?<mod>\d+)/files/(?<file>\d+)\?(?<q>.+)$', 'IgnoreCase')
    if (-not $m.Success) { throw "Unrecognized nxm link: $Url" }
    if ($m.Groups['game'].Value -ne $script:NexusGame) { throw "Link is for '$($m.Groups['game'].Value)', not $($script:NexusGame)" }
    $qs = @{}
    foreach ($kv in $m.Groups['q'].Value -split '&') { $k, $v = $kv -split '=', 2; $qs[$k] = [uri]::UnescapeDataString("$v") }
    [ordered]@{ modId = [int]$m.Groups['mod'].Value; fileId = [int]$m.Groups['file'].Value; key = $qs['key']; expires = $qs['expires'] }
}

function Save-UrlToFile([string]$Url, [string]$OutFile, $Job) {
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromHours(3)
    [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd('cpmods/2.0')
    $part = "$OutFile.part"
    try {
        $resp = $client.GetAsync($Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$resp.EnsureSuccessStatusCode()
        if ($Job) { $Job.total = $resp.Content.Headers.ContentLength; $Job.done = 0 }
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Create($part)
        try {
            $buf = [byte[]]::new(1MB)
            $sum = [long]0
            # a stalled connection never ends a plain Read: wait in steps, stop on Cancel or 60 s without data
            $cts = [Threading.CancellationTokenSource]::new()
            while ($true) {
                $t = $in.ReadAsync($buf, 0, $buf.Length, $cts.Token); $idle = [Diagnostics.Stopwatch]::StartNew()
                while (-not $t.Wait(500)) {
                    if ($Job -and $Job.cancel) { $cts.Cancel(); throw 'Cancelled' }
                    if ($idle.Elapsed.TotalSeconds -gt 60) { $cts.Cancel(); throw 'Download stalled: no data for 60 seconds. Try again from Nexus.' }
                }
                $n = $t.Result
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n); $sum += $n; if ($Job) { $Job.done = $sum }
            }
        }
        finally { $out.Dispose(); $in.Dispose(); $resp.Dispose() }
        [IO.File]::Move($part, $OutFile, $true)
    }
    catch { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue; throw }
    finally { $client.Dispose() }
}

# Picks the tracked name: explicit intent, queue entry, update of an installed file, or the mod name
function Resolve-InstallName([int]$ModId, [int]$FileId, [string]$FileDisplayName, [string]$IntentName) {
    if ($IntentName) { return $IntentName }
    $qi = Get-Queue | Where-Object { [int]$_.modId -eq $ModId -and [int]$_.fileId -eq $FileId } | Select-Object -First 1
    if ($qi) { return $qi.name }
    $s = Get-State
    $same = @(@($s.mods) + @($s.disabled) | Where-Object { $_ -and [int]$_.modId -eq $ModId })
    $match = @($same | Where-Object { $_.fileName -and (Get-NormName $_.fileName) -eq (Get-NormName $FileDisplayName) })
    if ($match.Count -eq 1) { return $match[0].name }
    if ($same.Count -eq 1 -and -not $same[0].fileName) { return $same[0].name }
    $modName = try { (Invoke-NexusV1 "games/$($script:NexusGame)/mods/$ModId.json").name } catch { $FileDisplayName }
    if (-not $modName) { $modName = $FileDisplayName }
    if ($same | Where-Object { $_.name -eq $modName }) { return "$modName - $FileDisplayName" }
    $modName
}

function Invoke-NxmDownload {
    param([string]$Url, $Job, [string]$IntentName, [scriptblock]$OnLinkReady)
    $l = Resolve-NxmLink $Url
    $base = "games/$($script:NexusGame)/mods/$($l.modId)/files/$($l.fileId)"
    if ($Job) { $Job.phase = 'resolving' }
    try { $fi = Invoke-NexusV1 "$base.json" }
    catch { throw "Nexus has no file $($l.fileId) for mod $($l.modId). $($_.Exception.Message)" }
    if ($Job) { $Job.title = "$($fi.name) $($fi.version)".Trim() }
    try {
        $links = Invoke-RestMethod ("https://api.nexusmods.com/v1/$base/download_link.json?key={0}&expires={1}" -f [uri]::EscapeDataString("$($l.key)"), [uri]::EscapeDataString("$($l.expires)")) -Headers (Get-NexusHeaders) -TimeoutSec 30
    }
    catch { throw "Nexus refused the download link: $(Get-HttpErrorText $_). Links expire after a few minutes; click Slow download again." }
    $uri = @($links)[0].URI
    if (-not $uri) { throw 'Nexus returned no download link' }
    if ($OnLinkReady) { & $OnLinkReady $l }
    $sha = $null
    try { if ($fi.content_preview_link) { $sha = (Invoke-RestMethod $fi.content_preview_link -TimeoutSec 20).archive.hashes.SHA256 } } catch { }
    $out = Join-Path $script:DlDir (Get-SafeFileName $fi.file_name)
    $reuse = (Test-Path -LiteralPath $out) -and $sha -and ((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -eq $sha)
    if (-not $reuse) {
        if ($Job) { $Job.phase = 'downloading' }
        Save-UrlToFile $uri $out $Job
        if ($sha -and (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -ne $sha) {
            Remove-Item -LiteralPath $out -Force
            throw "Checksum mismatch for $($fi.file_name): the download was corrupted, try again"
        }
    }
    Write-Note ("Downloaded {0}{1}" -f $fi.file_name, $(if ($sha) { ' (SHA256 verified)' } else { '' }))
    $name = Resolve-InstallName -ModId $l.modId -FileId $l.fileId -FileDisplayName $fi.name -IntentName $IntentName
    $meta = [ordered]@{ name = $name; version = "$($fi.version)"; source = "nexus:$($l.modId)/$($l.fileId)"; modId = $l.modId; fileId = $l.fileId; fileName = $fi.name; sha256 = $sha }
    $qi = Get-Queue | Where-Object { [int]$_.fileId -eq $l.fileId -and $_.sub } | Select-Object -First 1
    if ($qi) { $meta.sub = "$($qi.sub)" }
    @{ archive = $out; meta = $meta; link = $l }
}

# Installs now when possible, otherwise parks the archive in pending / failed
function Complete-NexusDownload([string]$Archive, [Collections.IDictionary]$Meta) {
    Use-Lock {
        $g = Get-GameState
        $set = Get-CpSettings
        $why = if ($g.updatePending) { 'game update pending' } elseif ($g.running) { 'game is running' } elseif (-not $set.autoInstall) { 'auto-install is off' } else { $null }
        if ($why) { Add-Deferred 'pending' $Archive $Meta ''; Write-Note "Waiting to install $($Meta.name) ($why)" Yellow; return "waiting to install ($why)" }
        try {
            $r = Install-ModArchive -Archive $Archive -Meta $Meta -Ask:(Test-AskOverwrite)
            if ($r.conflict) { Add-Deferred 'pending' $Archive $Meta '' $r.conflict; Write-Note "Waiting for your choice: $($Meta.name) has files another mod installed" Yellow; return 'waiting for your choice (another mod has some of the same files)' }
            'installed'
        }
        catch {
            $msg = $_.Exception.Message
            Add-Deferred 'failed' $Archive $Meta $msg
            Write-Note "Install of $($Meta.name) needs attention: $msg" Red
            throw "Downloaded, but the install needs attention: $msg"
        }
    }
}
#endregion

#region diagnostics
function Test-Install {
    $s = Get-State
    $missing = foreach ($m in $s.mods) {
        $miss = @(@($m.files) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:Game $_)) })
        if ($miss) { [ordered]@{ name = $m.name; count = $miss.Count; sample = $miss[0] } }
    }
    $logs = @(Get-ChildItem -LiteralPath (Join-Path $script:Game 'red4ext\logs'), (Join-Path $script:Game 'r6\logs') -File -Filter *.log -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath (Join-Path $script:Game 'bin\x64\plugins\cyber_engine_tweaks') -Recurse -Depth 4 -File -Filter *.log -ErrorAction SilentlyContinue)
    $since = (Get-Date).AddHours(-24)
    $found = foreach ($l in ($logs | Where-Object LastWriteTime -GT $since | Sort-Object FullName)) {
        # "doesn't match the expected bytes" etc: a plugin found the game code already patched by another mod
        $hits = @(Select-String -LiteralPath $l.FullName -Pattern '(?i)\[(error|critical)\]|\berror\b|exception|failed to|could not|unable to|(doesn''t|does not) match the expected|not installed|hook failed|signature not found|pattern not found' -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { $_.Line.Trim() })
        if ($hits) { [ordered]@{ file = [IO.Path]::GetRelativePath($script:Game, $l.FullName); modified = $l.LastWriteTime.ToString('s'); lines = $hits } }
    }
    $latest = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    [ordered]@{ missing = @($missing); logs = @($found); checkedLogs = @($logs).Count; lastLog = $(if ($latest) { $latest.LastWriteTime.ToString('s') } else { $null }) }
}
#endregion

#region Nexus GraphQL and compiled C# helpers (cpinsight uses them too)
function Invoke-NexusGql([string]$Query, $Variables) {
    $body = @{ query = $Query }
    if ($Variables) { $body.variables = $Variables }
    $json = ConvertTo-Json -InputObject $body -Depth 20 -Compress
    $r = Invoke-RestMethod -Method Post -Uri 'https://api.nexusmods.com/v2/graphql' -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -Headers @{ 'User-Agent' = 'cpmods/2.0' } -TimeoutSec 45
    if ($r.errors) { throw "Nexus: $($r.errors[0].message)" }
    $r.data
}

# Compiles C# once per source and runtime version into state\bin, then loads that DLL (keeps the compiler out of memory)
function Import-CpType([string]$Name, [string]$Source) {
    if ($Name -as [type]) { return }
    $dir = Join-Path $script:StateDir 'bin'
    $tag = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Source|$([Environment]::Version)"))).Substring(0, 12)
    $dll = Join-Path $dir "$Name-$tag.dll"
    try {
        if (-not (Test-Path -LiteralPath $dll)) {
            [void](New-Item -ItemType Directory -Force -Path $dir)
            $tmp = Join-Path $dir ('{0}-{1}.{2}.{3}.dll' -f $Name, $tag, $PID, [Threading.Thread]::CurrentThread.ManagedThreadId)
            Add-Type -TypeDefinition $Source -OutputAssembly $tmp -OutputType Library
            try { [IO.File]::Move($tmp, $dll) } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Get-ChildItem -LiteralPath $dir -Filter "$Name-*.dll" | Where-Object { $_.FullName -ne $dll } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Add-Type -Path $dll
    }
    catch { if (-not ($Name -as [type])) { Add-Type -TypeDefinition $Source } }
}
#endregion

#region discovery of mods installed outside cpmods
$script:FwRules = @(
    @{ name = 'RED4ext'; marker = 'red4ext\RED4ext.dll'; owns = @('bin\x64\winmm.dll', 'red4ext\RED4ext.dll', 'red4ext\LICENSE.txt', 'red4ext\THIRD_PARTY_LICENSES.txt') }
    @{ name = 'Cyber Engine Tweaks'; marker = 'bin\x64\plugins\cyber_engine_tweaks.asi'; owns = @('bin\x64\version.dll', 'bin\x64\global.ini', 'bin\x64\LICENSE', 'bin\x64\plugins\cyber_engine_tweaks.asi') }
    @{ name = 'redscript'; marker = 'engine\tools\scc.exe'; owns = @() }
    @{ name = 'ArchiveXL'; marker = 'red4ext\plugins\ArchiveXL'; owns = @() }
    @{ name = 'TweakXL'; marker = 'red4ext\plugins\TweakXL'; owns = @() }
    @{ name = 'Codeware'; marker = 'red4ext\plugins\Codeware'; owns = @() }
    @{ name = 'Mod Settings'; marker = 'red4ext\plugins\mod_settings'; owns = @() }
    @{ name = 'Input Loader'; marker = 'red4ext\plugins\input_loader'; owns = @() }
)
$script:FwPluginDirs = @('archivexl', 'tweakxl', 'codeware', 'mod_settings', 'input_loader')

function Get-NameWords([string]$N) {
    $t = ([IO.Path]::GetFileName("$N") -replace '\.(archive|xl|reds|lua|xml|yaml|yml|asi|dll)$', '' -replace '^[#!_\-\s0-9]+', '' -creplace '([a-z])([A-Z])', '$1 $2') -replace '[^A-Za-z0-9]+', ' '
    @($t.ToLower().Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.Length -ge 3 -and $_ -notin 'mod', 'mods', 'the', 'and', 'for', 'archive' })
}

function Get-NameSim($Words, [string]$Name) {
    $w = @($Words)
    if (-not $w.Count) { return 0 }
    $c = ("$Name".ToLower() -replace '[^a-z0-9]', '')
    @($w | Where-Object { $c.Contains($_) }).Count / $w.Count
}

# Nexus details per mod id (40 per request); a failed request loses only its 40, and it throws only when nothing came back
function Get-NexusModInfo([int[]]$Ids, [string]$Fields = 'modId name version updatedAt thumbnailUrl') {
    $info = @{}; $err = $null
    $Ids = @($Ids | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    for ($i = 0; $i -lt $Ids.Count; $i += 40) {
        $chunk = $Ids[$i..([Math]::Min($i + 39, $Ids.Count - 1))]
        $list = ($chunk | ForEach-Object { "{gameDomain: `"$($script:NexusGame)`", modId: $_}" }) -join ', '
        try { $d = Invoke-NexusGql "{ legacyModsByDomain(ids: [$list], count: 50) { nodes { $Fields } } }"; foreach ($n in $d.legacyModsByDomain.nodes) { $info[[int]$n.modId] = $n } }
        catch { if (-not $err) { $err = $_ } }
    }
    if ($err -and -not $info.Count) { throw $err }
    $info
}

function Get-UnitKey([string]$N) {
    $b = [IO.Path]::GetFileName($N)
    while ([IO.Path]::GetExtension($b) -match '^\.(archive|xl|reds|lua|xml|yaml|yml|asi|dll|toml)$') { $b = [IO.Path]::GetFileNameWithoutExtension($b) }
    ($b.ToLower() -replace '^[#!_\-\s0-9]+', '' -replace '[^a-z0-9]', '')
}

# Groups untracked mod files into mods and identifies them on Nexus by exact file path
function Find-ExistingMods([switch]$IncludeTracked) {
    $g = $script:Game
    $s = Get-State
    $tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $IncludeTracked) { foreach ($m in $s.mods) { foreach ($f in @($m.files)) { [void]$tracked.Add("$f") } } }
    # folders that hold tracked files: anything else inside them is that mod's own runtime data (settings, db)
    $ownedDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $tracked) { $p = Split-Path $t; while ($p) { if (-not $ownedDirs.Add($p)) { break }; $p = Split-Path $p } }
    $rel = { param($p) [IO.Path]::GetRelativePath($g, $p) }
    $skip = { param($r) $r -match '(?i)\.log$|\\logs?\\|\.part$|\\__pycache__\\' -or $tracked.Contains($r) }
    $units = [ordered]@{}
    $add = {
        param([string]$Key, [string]$Display, [string]$Root, [string[]]$Files)
        if ($Root -and $ownedDirs.Contains($Root)) { return }
        $Files = @($Files | Where-Object { -not (& $skip $_) })
        if (-not $Files -or -not $Key) { return }
        if (-not $units.Contains($Key)) { $units[$Key] = [ordered]@{ key = $Key; display = $Display; roots = [Collections.Generic.List[string]]::new(); files = [Collections.Generic.List[string]]::new() } }
        $u = $units[$Key]
        if ($Root -and -not $u.roots.Contains($Root)) { $u.roots.Add($Root) }
        foreach ($f in $Files) { if (-not $u.files.Contains($f)) { $u.files.Add($f) } }
    }
    $filesUnder = { param($d) @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { & $rel $_.FullName }) }

    $frameworks = foreach ($r in $script:FwRules) {
        $present = Test-Path -LiteralPath (Join-Path $g $r.marker)
        $managed = [bool]($s.mods | Where-Object { $_.name -eq $r.name })
        if ($present) { [ordered]@{ name = $r.name; managed = $managed } }
    }
    $fwOwned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $script:FwRules) { foreach ($o in $r.owns) { [void]$fwOwned.Add($o) } }

    $am = Join-Path $g 'archive\pc\mod'
    foreach ($f in Get-ChildItem -LiteralPath $am -File -ErrorAction SilentlyContinue) {
        $r = & $rel $f.FullName
        & $add (Get-UnitKey $f.Name) ([IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '\.archive$', '') $r @($r)
    }
    foreach ($sub in 'r6\scripts', 'r6\tweaks', 'r6\input') {
        foreach ($e in Get-ChildItem -LiteralPath (Join-Path $g $sub) -Force -ErrorAction SilentlyContinue) {
            $r = & $rel $e.FullName
            $files = if ($e.PSIsContainer) { & $filesUnder $e.FullName } else { @($r) }
            & $add (Get-UnitKey $e.Name) ($e.Name -replace '\.(reds|yaml|yml|xml)$', '') $r $files
        }
    }
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $g 'bin\x64\plugins\cyber_engine_tweaks\mods') -Directory -ErrorAction SilentlyContinue) {
        & $add (Get-UnitKey $d.Name) $d.Name (& $rel $d.FullName) (& $filesUnder $d.FullName)
    }
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $g 'red4ext\plugins') -Directory -ErrorAction SilentlyContinue) {
        if ($script:FwPluginDirs -contains $d.Name.ToLower()) { continue }
        & $add (Get-UnitKey $d.Name) $d.Name (& $rel $d.FullName) (& $filesUnder $d.FullName)
    }
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $g 'mods') -Directory -ErrorAction SilentlyContinue) {
        & $add ('redmod' + (Get-UnitKey $d.Name)) $d.Name (& $rel $d.FullName) (& $filesUnder $d.FullName)
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $g 'bin\x64\plugins') -Filter *.asi -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath (Join-Path $g 'bin\x64') -Filter *.asi -File -ErrorAction SilentlyContinue)) {
        $r = & $rel $f.FullName
        if ($fwOwned.Contains($r)) { continue }
        & $add (Get-UnitKey $f.Name) $f.BaseName $r @($r)
    }

    # Vortex deployment manifest: those files stay with Vortex
    $vortex = @{}
    $vf = Join-Path $g 'vortex.deployment.json'
    if (Test-Path -LiteralPath $vf) {
        try { foreach ($e in @(([IO.File]::ReadAllText($vf) | ConvertFrom-Json).files)) { if ($e.relPath) { $vortex["$($e.relPath)".ToLower()] = "$($e.source)" } } } catch { }
    }

    # identify on Nexus: up to 3 distinctive files per mod, exact path lookups batched with aliases
    $order = @('.archive', '.reds', '.lua', '.dll', '.asi', '.yaml', '.yml', '.xl', '.xml', '.json')
    $probes = [Collections.Generic.List[object]]::new()
    foreach ($u in $units.Values) {
        $pool = @($u.files | Where-Object { [IO.Path]::GetExtension($_).ToLower() -notin '.sqlite3', '.json', '.log', '.txt', '.md', '.ini' })
        if (-not $pool) { $pool = @($u.files) }
        $pick = @($pool | Sort-Object { $i = [array]::IndexOf($order, [IO.Path]::GetExtension($_).ToLower()); if ($i -lt 0) { 99 } else { $i } }, { $_.Length } | Select-Object -First 3)
        foreach ($p in $pick) { $probes.Add(@{ key = $u.key; path = ($p -replace '\\', '/') }) }
    }
    $votes = @{}
    for ($i = 0; $i -lt $probes.Count; $i += 20) {
        $chunk = @($probes[$i..([Math]::Min($i + 19, $probes.Count - 1))])
        $defs = @(); $sel = @(); $vars = @{}
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            $defs += "`$f$j`: ModFileContentSearchFilter"
            $sel += "p$j`: modFileContents(filter: `$f$j, count: 60) { nodes { modId } }"
            $vars["f$j"] = @{ gameId = @{ value = 3333; op = 'EQUALS' }; filePathWildcard = @{ value = $chunk[$j].path; op = 'EQUALS' } }
        }
        try { $d = Invoke-NexusGql ("query(" + ($defs -join ', ') + ") { " + ($sel -join ' ') + " }") $vars } catch { Write-Note "Identify batch failed: $($_.Exception.Message)"; continue }
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            foreach ($n in @($d."p$j".nodes)) {
                if (-not $n) { continue }
                $k = $chunk[$j].key
                if (-not $votes[$k]) { $votes[$k] = @{} }
                $votes[$k][[int]$n.modId] = 1 + [int]$votes[$k][[int]$n.modId]
            }
        }
    }

    # pick per unit: file votes, name similarity breaks ties against modlist/config uploads that re-bundle files
    $bundleRx = '(?i)\b(config|configuration|modlist|mod list|collections?|repack|compilation|bundle|merged|settings files|repository|deleted)\b'
    $cand = @{}
    foreach ($k in $votes.Keys) { $cand[$k] = @($votes[$k].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6) }
    $info = try { Get-NexusModInfo @($cand.Values | ForEach-Object { $_ } | ForEach-Object { [int]$_.Key } | Sort-Object -Unique) } catch { @{} }
    $groups = [Collections.Generic.List[object]]::new()
    foreach ($u in $units.Values) {
        $best = 0; $bestScore = -1e9
        $c = $cand[$u.key]
        if ($c) {
            $words = Get-NameWords $u.display
            $max = [double]($c | Measure-Object Value -Maximum).Maximum
            foreach ($e in $c) {
                $nm = "$($info[[int]$e.Key].name)"
                $score = 100 * (Get-NameSim $words $nm) + 20 * $e.Value / $max - $(if ($nm -match $bundleRx) { 60 } else { 0 })
                if ($score -gt $bestScore) { $bestScore = $score; $best = [int]$e.Key }
            }
        }
        $vsrc = $null
        foreach ($f in $u.files) { $x = $vortex[$f.ToLower()]; if ($x) { $vsrc = $x; break } }
        $groups.Add([ordered]@{ modId = $best; match = $(if ($best) { 'files' } else { '' }); name = ($u.display -replace '^[#!_\-\s0-9]+', ''); vortex = $vsrc; roots = @($u.roots); files = @($u.files) })
    }

    # fallback: search Nexus by name (newest uploads are not in the file index yet)
    $tries = 0
    foreach ($e in @($groups | Where-Object { -not $_.modId })) {
        $words = Get-NameWords $e.name
        if (-not $words -or $tries -ge 30) { continue }
        $tries++
        try {
            $d = Invoke-NexusGql 'query($f: ModsFilter) { mods(filter: $f, count: 6, sort: [{endorsements: {direction: DESC}}]) { nodes { modId name version updatedAt thumbnailUrl } } }' @{ f = @{ gameDomainName = @(@{ value = $script:NexusGame; op = 'EQUALS' }); nameStemmed = @(@{ value = ($words -join ' '); op = 'MATCHES' }); tag = @(@{ value = 'Translation'; op = 'NOT_EQUALS' }) } }
        }
        catch { continue }
        $hit = @($d.mods.nodes) | Where-Object { $_ -and (Get-NameSim $words "$($_.name)") -ge 1 -and "$($_.name)" -notmatch $bundleRx } | Select-Object -First 1
        if ($hit) { $e.modId = [int]$hit.modId; $e.match = 'name'; $info[[int]$hit.modId] = $hit }
    }

    # merge pieces that belong to the same Nexus mod
    $byMod = [ordered]@{}
    foreach ($e in $groups) {
        $gk = if ($e.modId) { "m$($e.modId)" } else { 'u' + (Get-UnitKey $e.name) + $byMod.Count }
        if (-not $byMod.Contains($gk)) { $byMod[$gk] = [ordered]@{ id = $gk; modId = $e.modId; match = $e.match; name = $e.name; vortex = $e.vortex; roots = [Collections.Generic.List[string]]::new(); files = [Collections.Generic.List[string]]::new() } }
        $t = $byMod[$gk]
        if ($e.match -eq 'files') { $t.match = 'files' }
        if ($e.vortex -and -not $t.vortex) { $t.vortex = $e.vortex }
        foreach ($r in $e.roots) { if (-not $t.roots.Contains($r)) { $t.roots.Add($r) } }
        foreach ($f in $e.files) { if (-not $t.files.Contains($f)) { $t.files.Add($f) } }
    }
    $missing = @($byMod.Values | Where-Object { $_.modId -and -not $info[$_.modId] } | ForEach-Object { $_.modId })
    if ($missing) { $more = try { Get-NexusModInfo $missing } catch { @{} }; foreach ($k in $more.Keys) { $info[$k] = $more[$k] } }
    $fwIds = @(Get-Frameworks | ForEach-Object { [int]$_.nexusId })
    $mods = foreach ($e in $byMod.Values) {
        $n = if ($e.modId) { $info[$e.modId] }
        [ordered]@{
            id = $e.id; modId = $e.modId; name = $(if ($n) { "$($n.name)" } else { $e.name }); guess = $e.name; match = $e.match
            identified = [bool]$n; framework = [bool]($e.modId -and $fwIds -contains $e.modId); latest = $(if ($n) { "$($n.version)" }); updatedAt = $(if ($n) { $n.updatedAt })
            thumb = $(if ($n) { $n.thumbnailUrl }); vortex = $e.vortex; roots = @($e.roots); files = @($e.files); fileCount = $e.files.Count
        }
    }
    [ordered]@{ scanned = (Get-Date).ToString('s'); frameworks = @($frameworks); mods = @($mods | Sort-Object { -not $_.identified }, { $_.name }) }
}

# Starts tracking mods found by Find-ExistingMods (files only, nothing is copied)
function Add-AdoptedMods($Items) {
    Assert-GameReady
    $s = Get-State
    $tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $s.mods) { foreach ($f in @($m.files)) { [void]$tracked.Add("$f") } }
    $done = @()
    foreach ($it in @($Items)) {
        $files = [Collections.Generic.List[string]]::new()
        foreach ($f in @($it.files)) {
            $r = "$f"
            if ($r -match '\.\.|^[\\/]|:' ) { continue }
            if ($tracked.Contains($r) -or -not (Test-Path -LiteralPath (Join-Path $script:Game $r) -PathType Leaf)) { continue }
            $files.Add($r); [void]$tracked.Add($r)
        }
        if (-not $files.Count) { continue }
        $name = "$($it.name)".Trim()
        if (-not $name) { $name = 'Existing mod' }
        $base = $name; $n = 2
        while ($s.mods | Where-Object { $_.name -eq $name }) { $name = "$base ($n)"; $n++ }
        $dirs = @($it.roots | Where-Object { $_ -and $_ -notmatch '\.\.' -and (Test-Path -LiteralPath (Join-Path $script:Game $_) -PathType Container) })
        $mid = [int]$it.modId
        $s.mods.Add([ordered]@{
                name = $name; version = $null; source = $(if ($mid) { "adopted:nexus:$mid" } else { 'adopted' }); modId = $(if ($mid) { $mid } else { $null }); fileId = $null
                fileName = $null; sha256 = $null; archive = $null; sub = $null; adopted = $true; installed = (Get-Date).ToString('s')
                files = $files; backups = @(); dirs = $dirs
            })
        $done += $name
    }
    Save-State $s
    Write-Note "Adopted $($done.Count) existing mod(s): $($done -join ', ')" Green
    $done
}
#endregion

#region sharing
function Export-ModList {
    $s = Get-State
    [ordered]@{
        format = 'cpmods-modlist'; version = 1; game = (Get-GameState).version; created = (Get-Date).ToString('s')
        mods = @($s.mods | Where-Object { "$($_.source)".StartsWith('nexus:') -and $_.fileId } | Sort-Object { $_.name } | ForEach-Object {
                [ordered]@{ name = $_.name; modId = [int]$_.modId; fileId = [int]$_.fileId; version = $_.version; sub = $_.sub } })
    }
}

# Modpack code: "CPMODS" + base62 (letters and digits only: chats cannot reformat it, a double-click selects all of it).
# Bytes: format 2, name, game version, count, then per mod (sorted) the modId gap * 2 (+1 when a sub folder follows) and
# the fileId as varints, then 2 bytes of SHA-256 (a mistyped code is refused) and 0x01 (keeps leading zero bytes).
# -Short (format 3): only fileId gaps (about a third of the length); Resolve-PackMods asks Nexus for each file's mod.
# Names and versions are not in the code: Resolve-PackMods reads them from Nexus.
$script:PackTag = 'CPMODS'
$script:B62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
function ConvertTo-PackCode([string]$Name, $Mods = (Export-ModList).mods, [switch]$Short) {
    $Name = "$Name".Trim()
    if ($Name.Length -gt 60) { throw 'Give the modpack a name of up to 60 characters' }
    $key = if ($Short) { 'fileId' } else { 'modId' }
    $Mods = @($Mods | Sort-Object { [int]$_.$key }, { [int]$_.fileId })
    if (-not $Mods.Count) { throw 'No Nexus mods are on, so there is nothing to share' }
    $w = [IO.MemoryStream]::new()
    $num = { param([long]$v) do { $b = [byte]($v -band 0x7F); $v = $v -shr 7; if ($v) { $b = $b -bor 0x80 }; $w.WriteByte($b) } while ($v) }
    $str = { param([string]$s) $b = [Text.Encoding]::UTF8.GetBytes($s); & $num $b.Length; $w.Write($b, 0, $b.Length) }
    $w.WriteByte($(if ($Short) { 3 } else { 2 })); & $str $Name; & $str "$((Get-GameState).version)"; & $num $Mods.Count
    $prev = 0
    foreach ($m in $Mods) {
        & $num (((([long]$m.$key) - $prev) -shl 1) -bor [long][bool]$m.sub)
        if (-not $Short) { & $num ([long]$m.fileId) }
        if ($m.sub) { & $str "$($m.sub)" }
        $prev = [long]$m.$key
    }
    $body = $w.ToArray()
    $n = [Numerics.BigInteger]::new([byte[]]($body + [Security.Cryptography.SHA256]::HashData($body)[0..1] + 1))
    $sb = [Text.StringBuilder]::new(); $r = [Numerics.BigInteger]::Zero
    while ($n.Sign -gt 0) { $n = [Numerics.BigInteger]::DivRem($n, 62, [ref]$r); [void]$sb.Append($script:B62[[int]$r]) }
    $c = $sb.ToString().ToCharArray(); [array]::Reverse($c)
    [ordered]@{ code = $script:PackTag + [string]::new($c); count = $Mods.Count }
}

# A modpack from someone else (code, also inside a pasted message, or a mod list file): only well-formed Nexus entries get through
function Read-ModPack([string]$Code, $List) {
    if ($Code) {
        $t = $Code.Trim()
        # just the code (maybe wrapped over lines), or a message with the code in it
        $c = if ($t.StartsWith($script:PackTag, [StringComparison]::Ordinal)) { $t -replace '\s', '' } else { [regex]::Match($t, "$($script:PackTag)[0-9A-Za-z]+").Value }
        if ($c -notmatch "^$($script:PackTag)[0-9A-Za-z]{4,10000}$") { throw "No modpack code found: a code starts with $($script:PackTag)" }
        $n = [Numerics.BigInteger]::Zero
        foreach ($ch in $c.Substring($script:PackTag.Length).ToCharArray()) { $n = $n * 62 + $script:B62.IndexOf($ch) }
        $all = $n.ToByteArray()
        $bad = "This code is damaged or cut short: copy all of it, from $($script:PackTag) to the end"
        if ($all.Length -lt 5 -or $all[-1] -ne 1) { throw $bad }
        $body = [byte[]]$all[0..($all.Length - 4)]
        $h = [Security.Cryptography.SHA256]::HashData($body)
        if ($h[0] -ne $all[-3] -or $h[1] -ne $all[-2]) { throw $bad }
        $short = $body[0] -eq 3
        if ($body[0] -ne 2 -and -not $short) { throw 'This code was made by a newer cpmods: update cpmods first' }
        $p = @{ i = 1 }
        $num = { $v = [long]0; $sh = 0; do { if ($p.i -ge $body.Length -or $sh -gt 35) { throw $bad }; $b = $body[$p.i]; $p.i++; $v = $v -bor ([long]($b -band 0x7F) -shl $sh); $sh += 7 } while ($b -band 0x80); $v }
        $str = { $len = & $num; if ($p.i + $len -gt $body.Length) { throw $bad }; $s = [Text.Encoding]::UTF8.GetString($body, $p.i, $len); $p.i += $len; $s }
        $pn = & $str; $pg = & $str
        $List = @{ format = 'cpmods-modlist'; name = $pn; game = $pg; mods = [Collections.Generic.List[object]]::new() }
        $count = & $num; $id = [long]0
        for ($k = 0; $k -lt $count; $k++) {
            $x = & $num; $id += $x -shr 1
            # a short code has no mod ids: 0 = ask Nexus
            if ($short) { $mid = 0; $fid = $id } else { $mid = $id; $fid = & $num }
            $sub = if ($x -band 1) { & $str } else { $null }
            $List.mods.Add(@{ modId = $mid; fileId = $fid; sub = $sub })
        }
    }
    if ($List -isnot [Collections.IDictionary] -or $List.format -ne 'cpmods-modlist' -or $null -eq $List.mods) { throw 'This is not a cpmods modpack or mod list' }
    $mods = [Collections.Generic.List[object]]::new(); $seen = @{}
    foreach ($m in @($List.mods)) {
        $mid = 0; $fid = 0
        if ($m -isnot [Collections.IDictionary] -or -not [int]::TryParse("$($m.modId)", [ref]$mid) -or -not [int]::TryParse("$($m.fileId)", [ref]$fid) -or $mid -lt 0 -or $fid -le 0 -or $seen[$fid]) { continue }
        $seen[$fid] = $true
        $sub = "$($m.sub)"
        if ([IO.Path]::IsPathRooted($sub) -or $sub -match '(^|[\\/])\.\.([\\/]|$)') { $sub = '' }
        $mods.Add([ordered]@{ modId = $mid; fileId = $fid; sub = $(if ($sub) { $sub } else { $null }) })
    }
    if (-not $mods.Count) { throw 'This modpack holds no Nexus mods' }
    $pn = "$($List.name)".Trim()
    [ordered]@{ name = $(if ($pn.Length -gt 60) { $pn.Substring(0, 60) } else { $pn }); game = "$($List.game)"; mods = @($mods) }
}

# Nexus mods with their files (one request per 40 mods): meta = modId -> name, summary, picture, requirements; files = modId -> files
function Get-NexusModFiles([int[]]$Ids) {
    $meta = @{}; $files = @{}
    $Ids = @($Ids | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    for ($i = 0; $i -lt $Ids.Count; $i += 40) {
        $chunk = $Ids[$i..([Math]::Min($i + 39, $Ids.Count - 1))]
        $list = ($chunk | ForEach-Object { "{gameDomain: `"$($script:NexusGame)`", modId: $_}" }) -join ', '
        $q = "{ legacyModsByDomain(ids: [$list], count: 50) { nodes { modId name summary thumbnailUrl modRequirements { nexusRequirements { nodes { modId notes externalRequirement } } } } } " + (($chunk | ForEach-Object { "m$($_): modFiles(modId: $_, gameId: 3333) { fileId name version category }" }) -join ' ') + ' }'
        $d = try { Invoke-NexusGql $q } catch { throw "Nexus did not answer, try again in a moment ($($_.Exception.Message))" }
        foreach ($n in @($d.legacyModsByDomain.nodes)) { if ($n) { $meta[[int]$n.modId] = $n } }
        foreach ($id in $chunk) { $files[$id] = @($d."m$id" | Where-Object { $_ }) }
    }
    @{ meta = $meta; files = $files }
}

# Nexus mods a mod needs: not external, not marked optional (same rule as the compatibility check), not a framework
function Get-ModNeeds($Node, [int[]]$Skip) {
    @(@($Node.modRequirements.nexusRequirements.nodes) | Where-Object { $_ -and -not $_.externalRequirement -and [int]$_.modId -gt 0 -and $Skip -notcontains [int]$_.modId -and "$($_.notes)" -notmatch '(?i)optional|only (if|for|needed|required)|not required|recommended' } | ForEach-Object { [int]$_.modId } | Sort-Object -Unique)
}

# Names, file names and versions of pack entries from Nexus, with what each mod needs. Two files of one mod are
# named "Mod - File", like a second download of a mod. Files Nexus no longer has come back in gone.
function Resolve-PackMods($Mods) {
    # entries without a mod id (short codes): Nexus finds each file's mod (uid = game id << 32 | file id, 50 per request)
    $need = @($Mods | Where-Object { -not $_.modId })
    for ($i = 0; $i -lt $need.Count; $i += 50) {
        $chunk = $need[$i..([Math]::Min($i + 49, $need.Count - 1))]
        $q = '{ modFilesByUid(uids: [' + (($chunk | ForEach-Object { "`"$(([long]3333 -shl 32) + [long]$_.fileId)`"" }) -join ', ') + '], count: 50) { nodes { fileId modId } } }'
        $d = try { Invoke-NexusGql $q } catch { throw "Nexus did not answer, try again in a moment ($($_.Exception.Message))" }
        $owner = @{}; foreach ($n in @($d.modFilesByUid.nodes)) { if ($n) { $owner[[long]$n.fileId] = [int]$n.modId } }
        # a file Nexus does not know keeps 0 and is reported as gone
        foreach ($e in $chunk) { $e.modId = [int]$owner[[long]$e.fileId] }
    }
    $nx = Get-NexusModFiles @($Mods | ForEach-Object { [int]$_.modId })
    $files = @{}; foreach ($l in $nx.files.Values) { foreach ($f in $l) { $files[[int]$f.fileId] = $f } }
    $fw = @(Get-Frameworks | ForEach-Object { [int]$_.nexusId })
    $ok = [Collections.Generic.List[object]]::new(); $gone = [Collections.Generic.List[string]]::new()
    foreach ($e in $Mods) {
        $f = $files[[int]$e.fileId]; $n = $nx.meta[[int]$e.modId]; $mn = if ($n) { "$($n.name)" }
        if (-not $f -or -not $mn -or $f.category -eq 'REMOVED') { $gone.Add($(if ($mn) { "$mn (file $($e.fileId))" } elseif ($e.modId) { "Nexus mod $($e.modId)" } else { "Nexus file $($e.fileId)" })); continue }
        $ok.Add([ordered]@{ name = $mn; modId = [int]$e.modId; fileId = [int]$e.fileId; version = "$($f.version)"; fileName = "$($f.name)"; sub = $e.sub
                thumb = "$($n.thumbnailUrl)"; summary = "$($n.summary)"; needs = @(Get-ModNeeds $n $fw) })
    }
    foreach ($g in @($ok | Group-Object { $_.modId } | Where-Object Count -gt 1)) { foreach ($e in $g.Group) { $e.name = "$($e.name) - $($e.fileName)" } }
    @{ mods = @($ok); gone = @($gone) }
}

# What getting a modpack changes here: new mods, mods you have (same file, on or off), mods you have in another
# version (the same file of that Nexus mod by file name; newer = the pack's file was uploaded later), frameworks you lack
function Get-PackPlan($Pack) {
    $s = Get-State
    $local = @(@($s.mods | ForEach-Object { @{ m = $_; on = $true } }) + @($s.disabled | ForEach-Object { @{ m = $_; on = $false } }))
    $names = @($local | ForEach-Object { "$($_.m.name)" })
    $res = Resolve-PackMods $Pack.mods
    $plan = [ordered]@{ name = $Pack.name; game = $Pack.game; total = @($Pack.mods).Count; new = @(); have = @(); turnOn = @(); versions = @(); gone = $res.gone; missing = @()
        frameworks = @(Get-Frameworks | Where-Object { $names -notcontains $_.name } | ForEach-Object { "$($_.name)" })
    }
    $used = @{}
    foreach ($e in $res.mods) {
        $hit = $local | Where-Object { [int]$_.m.fileId -eq $e.fileId } | Select-Object -First 1
        if ($hit) { $used[$hit.m.name] = $true; if ($hit.on) { $plan.have += $hit.m.name } else { $e.name = $hit.m.name; $plan.turnOn += $e }; continue }
        # one mod's files share its name (main, optional...): with file names on both sides only they decide
        $hit = $local | Where-Object { [int]$_.m.modId -eq $e.modId -and -not $used[$_.m.name] -and $(if ($e.fileName -and $_.m.fileName) { (Get-NormName $_.m.fileName) -eq (Get-NormName $e.fileName) } else { $_.m.name -eq $e.name }) } | Select-Object -First 1
        if ($hit) {
            $m = $hit.m; $used[$m.name] = $true
            # queued under your name, so the download replaces your version instead of landing beside it
            $plan.versions += [ordered]@{ name = $m.name; mine = "$($m.version)"; pack = $e.version; newer = [bool]($m.fileId -and $e.fileId -gt [int]$m.fileId); older = [bool]($m.fileId -and $e.fileId -lt [int]$m.fileId); on = $hit.on; back = [bool]($m.archive -and (Test-Path -LiteralPath $m.archive)); modId = $e.modId; fileId = $e.fileId; sub = $e.sub
                thumb = $e.thumb; summary = $e.summary; needs = $e.needs }
            continue
        }
        # another mod here (or earlier in the pack) has the same name: a distinct name keeps the install from replacing it
        if ($names -contains $e.name) { $e.name = "$($e.name) ($($e.modId))" }
        $names += $e.name
        $plan.new += $e
    }
    # mods the pack's mods need that are neither on here nor in the pack: one of yours turned off comes back on,
    # a Nexus mod with a single main file is downloaded (extra), others are listed as missing
    # shortcut: what those extra mods need in turn is not looked up, deeper chains show on the Compatibility page
    $known = @(@($s.mods | ForEach-Object { [int]$_.modId }) + @($res.mods | ForEach-Object { $_.modId }))
    $want = @(@($plan.new) + @($plan.turnOn) + @($plan.versions) | ForEach-Object { $_.needs } | Where-Object { $known -notcontains $_ } | Sort-Object -Unique)
    if ($want) {
        $nx = Get-NexusModFiles $want
        foreach ($id in $want) {
            $n = $nx.meta[$id]; $mn = if ($n) { "$($n.name)" } else { "Nexus mod $id" }
            $x = [ordered]@{ name = $mn; modId = $id; thumb = "$($n.thumbnailUrl)"; summary = "$($n.summary)"; needs = @(); extra = $true }
            $off = @($s.disabled | Where-Object { [int]$_.modId -eq $id } | Select-Object -First 1)
            $main = @($nx.files[$id] | Where-Object category -eq 'MAIN')
            if ($off) { $x.name = $off[0].name; $x.fileId = [int]$off[0].fileId; $x.version = "$($off[0].version)"; $plan.turnOn += $x }
            elseif ($n -and $main.Count -eq 1) {
                $x.fileId = [int]$main[0].fileId; $x.version = "$($main[0].version)"; $x.fileName = "$($main[0].name)"
                if ($names -contains $x.name) { $x.name = "$($x.name) ($id)" }
                $names += $x.name; $plan.new += $x
            }
            else { $plan.missing += [ordered]@{ modId = $id; name = $mn; why = $(if (-not $n) { 'Not in the modpack and not on Nexus any more' } elseif ($main.Count) { 'Not in the modpack, and it has several main files: pick the one you need on Nexus' } else { 'Not in the modpack, and Nexus has no main file for it' }) } }
        }
    }
    $plan
}

# Adds Nexus files to the queue, skipping ones already installed or queued
function Add-QueueItems($Items, [string]$Why) {
    Use-Lock {
        $s = Get-State
        $q = [Collections.Generic.List[object]]::new([object[]]@(Get-Queue))
        $added = 0; $skipped = 0
        foreach ($it in @($Items)) {
            if (-not $it) { continue }
            $fid = [int]$it.fileId; $mid = [int]$it.modId
            if ($fid -le 0 -or $mid -le 0) { continue }
            if ($s.mods | Where-Object { [int]$_.fileId -eq $fid }) { $skipped++; continue }
            foreach ($old in @($q | Where-Object { [int]$_.fileId -eq $fid -and $_.done })) { [void]$q.Remove($old) }
            if ($q | Where-Object { [int]$_.fileId -eq $fid }) { $skipped++; continue }
            $q.Add([ordered]@{ modId = $mid; fileId = $fid; name = "$($it.name)"; why = $(if ($it.why) { "$($it.why)" } else { $Why }); sub = $(if ($it.sub) { "$($it.sub)" } else { $null }); done = $false })
            $added++
        }
        Save-Queue $q
        [ordered]@{ added = $added; skipped = $skipped }
    }
}

# Zip for friends: app files (no keys, state or downloads) + Install.cmd + your mod list
function New-CpPackage([string]$OutDir, [switch]$NoModList, [string]$SettingsZip) {
    if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
    $stage = Join-Path $script:TmpDir ('pkg-' + [guid]::NewGuid().ToString('N'))
    $app = Join-Path $stage 'cpmods'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $app 'lib'), (Join-Path $app 'ui'))
    try {
        Copy-Item -Path (Join-Path $script:App 'lib\*.psm1'), (Join-Path $script:App 'lib\*.ps1') -Destination (Join-Path $app 'lib')
        Copy-Item -LiteralPath (Join-Path $script:App 'lib\webview2') -Destination (Join-Path $app 'lib') -Recurse
        Copy-Item -Path (Join-Path $script:App 'ui\*') -Destination (Join-Path $app 'ui')
        foreach ($f in 'server.ps1', 'cpmods.ps1', 'cpmods.cmd', 'frameworks.json', 'setup.ps1', 'bootstrap.ps1', 'uninstall.ps1') { Copy-Item -LiteralPath (Join-Path $script:App $f) -Destination $app }
        # without it the app still runs (setup then makes PowerShell shortcuts)
        try { New-CpLauncher (Join-Path $app 'cpmods.exe') } catch { Write-Note "Share package without cpmods.exe: $($_.Exception.Message)" Yellow }
        Copy-Item -LiteralPath (Join-Path $script:App 'share\Install.cmd'), (Join-Path $script:App 'share\README.txt') -Destination $stage
        if (-not $NoModList) { Write-JsonFile (Join-Path $stage 'modlist.json') (Export-ModList) }
        if ($SettingsZip) { Copy-Item -LiteralPath $SettingsZip -Destination (Join-Path $stage 'mod-settings.zip') }
        $zip = Join-Path $OutDir $(if ($NoModList) { 'cpmods-app.zip' } else { 'cpmods-share.zip' })
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
        Write-Note "Share package created: $zip"
        $zip
    }
    finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
#endregion

#region system integration
#region browser foreground
function Add-CpFgType {
    if ('CpFg' -as [type]) { return }
    Import-CpType 'CpFg' @'
using System; using System.Text; using System.Diagnostics; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class CpFg {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

  // Topmost visible top-level window of the given process name, skipping one title (the cpmods window)
  public static IntPtr FindTop(string exe, string skipTitle) {
    var pids = new HashSet<uint>();
    foreach (var p in Process.GetProcessesByName(exe)) pids.Add((uint)p.Id);
    IntPtr found = IntPtr.Zero;
    if (pids.Count == 0) return found;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (!pids.Contains(pid)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      var sb = new StringBuilder(len + 1); GetWindowText(h, sb, sb.Capacity);
      if (!string.IsNullOrEmpty(skipTitle) && sb.ToString().IndexOf(skipTitle, StringComparison.OrdinalIgnoreCase) >= 0) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }

  // Foreground lock workaround: share input state with the current foreground thread, Alt tap as fallback
  public static bool Focus(IntPtr h) {
    if (h == IntPtr.Zero) return false;
    if (IsIconic(h)) ShowWindow(h, 9);
    uint dummy, me = GetCurrentThreadId();
    uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out dummy);
    bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    if (attached) AttachThreadInput(me, fgThread, false);
    if (GetForegroundWindow() != h) { keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); SetForegroundWindow(h); }
    return GetForegroundWindow() == h;
  }
}
'@
}

function Get-DefaultBrowserExe {
    $prog = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue).ProgId
    $cmd = if ($prog) { "$((Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$prog\shell\open\command" -ErrorAction SilentlyContinue).'(default)')" } else { '' }
    if ($cmd -match '^\s*"([^"]+)"' -or $cmd -match '^\s*(\S+)') { return [IO.Path]::GetFileNameWithoutExtension($Matches[1]) }
    'msedge'
}

function Get-InstalledBrowsers {
    $seen = @{}
    foreach ($n in 'firefox', 'chrome', 'msedge', 'brave', 'opera', 'vivaldi', 'librewolf', 'waterfox') {
        $p = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$n.exe" -ErrorAction SilentlyContinue).'(default)'
        if (-not $p) { $p = (Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$n.exe" -ErrorAction SilentlyContinue).'(default)' }
        if ($p) { $p = $p.Trim('"') }
        if ($p -and (Test-Path -LiteralPath $p) -and -not $seen[$p]) {
            $seen[$p] = 1
            $label = @{ firefox = 'Firefox'; chrome = 'Chrome'; msedge = 'Edge'; brave = 'Brave'; opera = 'Opera'; vivaldi = 'Vivaldi'; librewolf = 'LibreWolf'; waterfox = 'Waterfox' }[$n]
            [ordered]@{ name = $label; path = $p }
        }
    }
}

# Brings the top window of a process to the front (programs started by the hidden server open behind others)
function Show-AppWindow([string]$Exe, [int]$WaitMs = 4000) {
    try {
        Add-CpFgType
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 300
        do {
            $h = [CpFg]::FindTop($Exe, 'Cyberpunk Mods')
            if ($h -ne [IntPtr]::Zero -and [CpFg]::Focus($h)) { return $true }
            Start-Sleep -Milliseconds 250
        } while ($sw.ElapsedMilliseconds -lt $WaitMs)
    }
    catch { Write-Note "Could not bring $Exe to the front: $($_.Exception.Message)" }
    $false
}

# Opens a link in the chosen (or Windows default) browser and brings that browser window to the front
function Open-UrlInFront([string]$Url) {
    $b = (Get-CpSettings).browser
    if ($b -and (Test-Path -LiteralPath $b)) { Start-Process -FilePath $b -ArgumentList ('"{0}"' -f $Url); $exe = [IO.Path]::GetFileNameWithoutExtension($b) }
    else { Start-Process $Url; $exe = Get-DefaultBrowserExe }
    Show-AppWindow $exe 6000
}

# Default folder app (File Pilot, Directory Opus...) from Directory\shell; empty when folders open in Explorer
function Get-FolderAppCommand {
    foreach ($root in 'HKCU:\Software\Classes\Directory\shell', 'Registry::HKEY_CLASSES_ROOT\Directory\shell') {
        $verb = "$((Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue).'(default)')"
        if (-not $verb -or $verb -eq 'none') { $verb = 'open' }
        $cmd = "$((Get-ItemProperty -LiteralPath "$root\$verb\command" -ErrorAction SilentlyContinue).'(default)')"
        if ($cmd) { return $(if ($cmd -match '(?i)(^|[\\"\s])explorer(\.exe)?("|\s|$)') { '' } else { $cmd }) }
    }
    ''
}

# Opens a folder with the default folder app; only Explorer can also highlight a file in it
function Open-Folder([string]$Path, [string]$SelectFile) {
    $app = Get-FolderAppCommand
    if (-not $app) {
        if ($SelectFile) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $SelectFile) }
        else { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Path) }
        return
    }
    $psi = [Diagnostics.ProcessStartInfo]::new($Path)
    $psi.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($psi)
    if ($app -match '^\s*"([^"]+)"' -or $app -match '^\s*(\S+)') { [void](Show-AppWindow ([IO.Path]::GetFileNameWithoutExtension($Matches[1]))) }
}
#endregion

# Programs started by the game (e.g. a folder opened by its crash reporter) carry the Steam overlay and keep the game "Running"
function Get-SteamGameBlockers {
    $skip = 'Cyberpunk2077', 'REDEngineErrorReporter', 'REDprelauncher', 'steam', 'steamwebhelper', 'GameOverlayUI', 'GameOverlayUI64'
    Get-Process | Where-Object { $skip -notcontains $_.ProcessName } | ForEach-Object {
        $p = $_
        try { if ($p.Modules | Where-Object { $_.ModuleName -like 'gameoverlayrenderer*' }) { $p } } catch { }
    }
}

# Clears a stale "Running" state: names blocking programs instead of restarting Steam when one exists
function Repair-SteamRunningFlag {
    $running = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).RunningAppID
    if ("$running" -ne '1091500') { return [ordered]@{ restarted = $false; blockers = @() } }
    if (Get-Process -Name Cyberpunk2077, REDEngineErrorReporter, REDprelauncher -ErrorAction SilentlyContinue) { return [ordered]@{ restarted = $false; blockers = @() } }
    $block = @(Get-SteamGameBlockers | ForEach-Object { "$($_.ProcessName) (pid $($_.Id))" })
    if ($block) { return [ordered]@{ restarted = $false; blockers = $block } }
    $steam = Join-Path (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath 'steam.exe'
    & $steam -shutdown
    for ($i = 0; $i -lt 60 -and (Get-Process steam -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    if (Get-Process steam -ErrorAction SilentlyContinue) { Stop-Process -Name steam -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    Start-Process explorer.exe -ArgumentList 'steam://open/main'
    for ($i = 0; $i -lt 60 -and -not (Get-Process steam -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Seconds 6
    [ordered]@{ restarted = $true; blockers = @() }
}

function Get-PwshPath {
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    (Get-Process -Id $PID).Path
}

function Register-NxmHandler {
    $cmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" nxm "%1"' -f (Get-PwshPath), (Join-Path $script:App 'cpmods.ps1')
    $base = 'HKCU:\Software\Classes\nxm'
    [void](New-Item -Path "$base\shell\open\command" -Force)
    Set-ItemProperty -Path $base -Name '(default)' -Value 'URL:NXM Protocol'
    Set-ItemProperty -Path $base -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path "$base\shell\open\command" -Name '(default)' -Value $cmd
}

function Test-NxmHandler { "$((Get-ItemProperty 'HKCU:\Software\Classes\nxm\shell\open\command' -ErrorAction SilentlyContinue).'(default)')" -match 'cpmods' }

function Get-ServerInfo { if (Test-Path -LiteralPath $script:ServerFile) { try { Read-JsonFile $script:ServerFile } catch { $null } } }
function Write-ServerInfo([int]$Port, [string]$Token) { Write-JsonFile $script:ServerFile ([ordered]@{ port = $Port; token = $Token; pid = $PID; started = (Get-Date).ToString('s') }) }
function Remove-ServerInfo { $i = Get-ServerInfo; if ($i -and [int]$i.pid -eq $PID) { Remove-Item -LiteralPath $script:ServerFile -Force -ErrorAction SilentlyContinue } }

function Start-CpServer([switch]$Open) {
    $a = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $script:App 'server.ps1')))
    if ($Open) { $a += '-Open' }
    Start-Process -FilePath (Get-PwshPath) -ArgumentList $a -WindowStyle Hidden
}

# App window: the server shows its built-in WebView2 window (lib\cpwindow.ps1, no browser needed).
# With a token, ask the running server; -Browser (or no answer) opens the "Open links in" browser instead.
function Open-CpWindow([int]$Port = 7077, [string]$Token, [switch]$Browser) {
    if (-not $Browser -and $Token) {
        try { [void](Invoke-RestMethod -Method Post "http://localhost:$Port/api/window" -Headers @{ 'X-Cp-Token' = $Token } -TimeoutSec 5); return } catch { }
    }
    $url = "http://localhost:$Port/"
    $s = try { Get-CpSettings } catch { @{} }
    $b = "$($s.browser)"
    if (-not $b -or -not (Test-Path -LiteralPath $b)) { Start-Process $url; return }
    $n = [IO.Path]::GetFileNameWithoutExtension($b).ToLower()
    # Chromium browsers can show an app window from the user's own profile; Firefox-family gets a new window
    $a = if ($n -in 'chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'chromium', 'thorium') { @("--app=$url", '--window-size=1440,920') }
    elseif ($n -in 'firefox', 'librewolf', 'waterfox', 'floorp', 'zen') { @('-new-window', $url) }
    else { @($url) }
    Start-Process -FilePath $b -ArgumentList $a
}

function New-CpShortcuts {
    $ws = New-Object -ComObject WScript.Shell
    $icon = Join-Path $script:Game 'bin\x64\Cyberpunk2077.exe'
    $exe = Join-Path $script:App 'cpmods.exe'
    foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
        $path = Join-Path $dir 'Cyberpunk Mods.lnk'
        $lnk = $ws.CreateShortcut($path)
        if (Test-Path -LiteralPath $exe) { $lnk.TargetPath = $exe; $lnk.Arguments = '' }
        else { $lnk.TargetPath = Get-PwshPath; $lnk.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Open' -f (Join-Path $script:App 'server.ps1') }
        $lnk.WorkingDirectory = $script:App
        $lnk.IconLocation = "$icon,0"
        $lnk.Description = 'Cyberpunk 2077 mod manager (cpmods)'
        $lnk.WindowStyle = 7
        $lnk.Save()
        $path
    }
}

# cpmods.exe: starts the app hidden with PowerShell 7; built with the .NET Framework compiler every Windows 10/11 has
function New-CpLauncher([string]$OutFile) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $src = Join-Path $script:TmpDir "launcher-$PID.cs"
    [IO.File]::WriteAllText($src, [IO.File]::ReadAllText((Join-Path $script:App 'share\launcher.cs')).Replace('CPMODS_VERSION', $script:AppVersion))
    try {
        $o = & $csc /nologo /target:winexe /optimize "/out:$OutFile" "/win32icon:$(Join-Path $script:App 'share\cpmods.ico')" /r:System.Windows.Forms.dll $src 2>&1
        if ($LASTEXITCODE) { throw "cpmods.exe did not compile: $(($o | Select-Object -Last 3) -join ' ')" }
    }
    finally { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
}
#endregion

#region updates: an installed copy (data outside the app folder, no git) updates from the GitHub releases when you say so
$script:Repo = 'Suprixel/cpmods'
function Get-CpVersion { $script:AppVersion }
function Test-CpCanUpdate { $script:App -ne $script:Root -and -not (Test-Path -LiteralPath (Join-Path $script:App '.git')) }
function Test-NewerVersion([string]$A, [string]$B) { $x = $null; $y = $null; [version]::TryParse($A, [ref]$x) -and [version]::TryParse($B, [ref]$y) -and $x -gt $y }

# the latest release: version, notes, the app zip and its SHA-256 (GitHub's own digest). A copy that cannot update asks GitHub nothing
function Get-CpUpdate {
    $u = [ordered]@{ current = $script:AppVersion; can = (Test-CpCanUpdate); latest = $null; newer = $false; notes = ''; page = "https://github.com/$($script:Repo)/releases"; zip = $null; sha256 = $null }
    if (-not $u.can) { return $u }
    $r = Invoke-RestMethod "https://api.github.com/repos/$($script:Repo)/releases/latest" -Headers @{ 'User-Agent' = 'cpmods' } -TimeoutSec 20
    $a = @($r.assets | Where-Object { $_.name -like 'cpmods-*.zip' }) | Select-Object -First 1
    $u.latest = "$($r.tag_name)".TrimStart('v'); $u.notes = "$($r.body)"; $u.page = "$($r.html_url)"
    $u.newer = [bool]($a -and (Test-NewerVersion $u.latest $script:AppVersion))
    if ($a) { $u.zip = "$($a.browser_download_url)"; if ("$($a.digest)" -match '^sha256:([0-9a-f]{64})$') { $u.sha256 = $Matches[1] } }
    $u
}

# downloads and checks the new version, unpacks it beside the data and hands over to its cpupdate.ps1, which swaps the
# app folder once this server has quit (the caller stops it) and starts the new version. Nothing changes when a check fails
function Start-CpUpdate($Job) {
    $u = Get-CpUpdate
    if (-not $u.can) { throw 'This copy of cpmods does not update itself' }
    if (-not $u.newer) { throw 'cpmods is up to date' }
    if (-not $u.sha256) { throw 'The release has no checksum, so it was not installed' }
    if ($u.zip -notmatch '^https://github\.com/') { throw "Unexpected download address: $($u.zip)" }
    $stage = Join-Path $script:TmpDir "update-$($u.latest)"
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Force -Path $stage)
    $zip = Join-Path $stage 'cpmods.zip'
    if ($Job) { $Job.phase = 'downloading' }
    Save-UrlToFile $u.zip $zip $Job
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $u.sha256) { throw 'The download does not match its checksum; nothing was changed' }
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
    $new = Join-Path $stage 'cpmods'
    foreach ($f in 'server.ps1', 'cpmods.exe', 'lib\cpmods.psm1', 'lib\cpupdate.ps1') { if (-not (Test-Path -LiteralPath (Join-Path $new $f))) { throw "The new version is incomplete ($f is missing); nothing was changed" } }
    # the swap runs from a copy outside both folders
    $runner = Join-Path $script:TmpDir 'cpupdate.ps1'
    Copy-Item -LiteralPath (Join-Path $new 'lib\cpupdate.ps1') -Destination $runner -Force
    $a = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"", '-From', "`"$new`"", '-To', "`"$($script:App)`"", '-WaitPid', $PID, '-Version', $u.latest, '-Log', "`"$($script:LogFile)`"")
    Start-Process -FilePath (Get-PwshPath) -ArgumentList $a -WindowStyle Hidden -WorkingDirectory $script:TmpDir
    Write-Note "Updating to $($u.latest): cpmods closes and opens again"
    "Updating to $($u.latest)"
}
#endregion

Export-ModuleMember -Function *
