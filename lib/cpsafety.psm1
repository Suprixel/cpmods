# cpmods safety nets: restore points, save backups, mod settings backups, launch without mods, key bindings map, disk space
# Uses functions exported by cpmods.psm1 and cpinsight.psm1 (import those first). Data lives in cpmods\safety.
$ErrorActionPreference = 'Stop'

function Get-SafetyDir([string]$Sub) {
    $d = Join-Path (Get-CpPaths).root 'safety'
    if ($Sub) { $d = Join-Path $d $Sub }
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Force -Path $d) }
    $d
}
function New-SafetyId([string]$Dir, [string]$Ext) {
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $n = 1; $try = $id
    while (Test-Path -LiteralPath (Join-Path $Dir "$try$Ext")) { $n++; $try = "$id-$n" }
    $try
}
function Assert-SafetyId([string]$Id) { if ($Id -notmatch '^\d{8}-\d{6}(-\d+)?$') { throw 'Unknown backup' } }

#region restore points: which mods (and versions) were installed and on at a moment
function Get-RestoreFile { Join-Path (Get-SafetyDir) 'points.json' }
function Get-RestorePoints { $f = Get-RestoreFile; if (Test-Path -LiteralPath $f) { @(Read-JsonFile $f | Where-Object { $_ }) } else { @() } }
function Get-SetupItems($S) {
    $pick = { param($m, $on) [ordered]@{ name = $m.name; version = "$($m.version)"; modId = $m.modId; fileId = $m.fileId; fileName = $m.fileName; source = $m.source; archive = $m.archive; sub = $m.sub; sha256 = $m.sha256; adopted = [bool]$m.adopted; keepOthers = $m.keepOthers; merged = $m.merged; on = $on } }
    @(@($S.mods | ForEach-Object { & $pick $_ $true }) + @($S.disabled | ForEach-Object { & $pick $_ $false }) | Sort-Object { $_.name })
}
function Get-SetupSig($Items) { (@($Items) | ForEach-Object { "$($_.name)|$($_.fileId)|$($_.version)|$($_.on)" }) -join "`n" }

function Save-RestorePoint([string]$Kind = 'manual', [string]$Label = '', [string]$Launch) {
    Use-Lock {
        $items = Get-SetupItems (Get-State)
        $list = [Collections.Generic.List[object]]::new([object[]]@(Get-RestorePoints))
        $id = (Get-Date).ToString('yyyyMMdd-HHmmss'); $n = 1; $base = $id
        while (@($list | Where-Object { $_.id -eq $id }).Count) { $n++; $id = "$base-$n" }
        $p = [ordered]@{ id = $id; at = (Get-Date).ToString('s'); kind = $Kind; label = $Label; launch = $Launch; sig = (Get-SetupSig $items); mods = $items }
        $list.Insert(0, $p)
        # every manual point (up to 20) and the newest 12 automatic ones
        $man = 0; $auto = 0
        $keep = foreach ($x in $list) { if ($x.kind -eq 'manual') { if (++$man -le 20) { $x } } elseif (++$auto -le 12) { $x } }
        Write-JsonFile (Get-RestoreFile) @($keep)
        Write-Note "Restore point: $Label"
        $p
    }
}
function Remove-RestorePoint([string]$Id) {
    Use-Lock { Write-JsonFile (Get-RestoreFile) @(Get-RestorePoints | Where-Object { $_.id -ne $Id }) }
}

# before installs, removals and switches: one restore point and one settings backup per batch (changes under 10 minutes apart)
function Save-AutoSafety([string]$Why) {
    try {
        if (-not (Get-CpSettings).autoRestore) { return }
        $last = @(Get-RestorePoints) | Select-Object -First 1
        if ($last -and $last.sig -eq (Get-SetupSig (Get-SetupItems (Get-State)))) { return }
        $sf = Join-Path (Get-CpPaths).state 'mods.json'
        $busy = (Test-Path -LiteralPath $sf) -and ((Get-Date) - (Get-Item -LiteralPath $sf).LastWriteTime).TotalMinutes -lt 10
        if ($busy -and $last -and $last.kind -eq 'auto' -and ((Get-Date) - [datetime]$last.at).TotalHours -lt 3) { return }
        [void](Save-RestorePoint 'auto' $Why)
        [void](Backup-ModSettings 'auto' $Why)
    }
    catch { Write-Note "Automatic restore point failed: $($_.Exception.Message)" }
}

# after a launch that closed normally: that setup is known good (skipped when mods changed after the game closed)
function Save-CleanRestorePoint($Brief) {
    if (-not $Brief.end -or -not (Get-CpSettings).autoRestore) { return }
    $sf = Join-Path (Get-CpPaths).state 'mods.json'
    if ((Test-Path -LiteralPath $sf) -and (Get-Item -LiteralPath $sf).LastWriteTime -gt [datetime]$Brief.end) { return }
    $sig = Get-SetupSig (Get-SetupItems (Get-State))
    if (@(Get-RestorePoints | Where-Object { $_.kind -eq 'clean' -and ($_.launch -eq $Brief.start -or $_.sig -eq $sig) }).Count) { return }
    [void](Save-RestorePoint 'clean' 'Your mods at a launch that closed normally' $Brief.start)
}

# what switching to a saved setup ($Mods: setup items) changes; frameworks are never switched off.
# -SameVersions (profiles): only on, off and reinstalls; the versions installed now stay
function Get-SetupPlan($Mods, [switch]$SameVersions) {
    $fw = @(Get-Frameworks | ForEach-Object { "$($_.name)" })
    $now = @{}; foreach ($x in Get-SetupItems (Get-State)) { $now[$x.name] = $x }
    $then = @{}; foreach ($x in @($Mods)) { $then[$x.name] = $x }
    $plan = [ordered]@{ off = @(); on = @(); install = @(); version = @(); missing = @(); same = 0 }
    $has = { param($t) [bool]($t.archive -and (Test-Path -LiteralPath $t.archive)) }
    foreach ($n in @($now.Keys | Sort-Object)) {
        $c = $now[$n]; $t = $then[$n]
        $isFw = $fw -contains $n -or "$($c.source)" -like 'github:*'
        if (-not $t) { if ($c.on -and -not $isFw) { $plan.off += $n }; continue }
        if (-not $SameVersions -and "$($c.fileId)|$($c.version)" -ne "$($t.fileId)|$($t.version)") {
            if (-not $t.on) { if ($c.on -and -not $isFw) { $plan.off += $n } }
            elseif (& $has $t) { $plan.version += [ordered]@{ name = $n; from = $c.version; to = $t.version } }
            else { $plan.missing += [ordered]@{ name = $n; why = "version $($t.version) is no longer in Downloads" } }
            continue
        }
        if ($c.on -ne $t.on) { if ($t.on) { $plan.on += $n } elseif (-not $isFw) { $plan.off += $n }; continue }
        $plan.same++
    }
    foreach ($n in @($then.Keys | Sort-Object)) {
        $t = $then[$n]
        if ($now.ContainsKey($n) -or -not $t.on) { continue }
        if (& $has $t) { $plan.install += $n }
        else { $plan.missing += [ordered]@{ name = $n; why = $(if ($t.adopted) { 'it was installed before cpmods and its files were removed' } else { 'its download is no longer in Downloads' }) } }
    }
    $plan
}
# what going back to a point changes
function Get-RestorePlan([string]$Id) {
    $p = @(Get-RestorePoints) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw 'That restore point no longer exists' }
    $plan = [ordered]@{ id = $p.id; at = $p.at; label = $p.label; kind = $p.kind }
    $sp = Get-SetupPlan $p.mods
    foreach ($k in $sp.Keys) { $plan[$k] = $sp[$k] }
    $plan
}

function Invoke-RestorePoint([string]$Id, $Job) {
    Assert-GameReady
    if (Get-BisectState) { throw 'Troubleshooting is running: finish it first, then go back to a restore point' }
    $plan = Get-RestorePlan $Id
    $p = @(Get-RestorePoints) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    [void](Save-RestorePoint 'auto' "Before going back to $(([datetime]$p.at).ToString('d MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture))")
    $r = Invoke-SetupPlan $plan $p.mods $Job
    $msg = "Went back: $($r.done) change(s)"
    if ($plan.missing.Count) { $msg += "; $($plan.missing.Count) mod(s) could not come back" }
    if ($r.fail.Count) { $msg += ". Problems: $($r.fail -join '; ')" }
    Write-Note $msg
    $msg
}
# switches mods off and on and installs from the saved items, in that order; one failing mod does not stop the others
function Invoke-SetupPlan($Plan, $Mods, $Job) {
    $then = @{}; foreach ($x in @($Mods)) { $then[$x.name] = $x }
    $steps = @(@($plan.off | ForEach-Object { @{ op = 'off'; name = $_ } }) + @($plan.on | ForEach-Object { @{ op = 'on'; name = $_ } }) +
        @($plan.install | ForEach-Object { @{ op = 'install'; name = $_ } }) + @($plan.version | ForEach-Object { @{ op = 'install'; name = $_.name } }))
    $fail = [Collections.Generic.List[string]]::new()
    $i = 0
    foreach ($st in $steps) {
        if ($Job) { $Job.phase = "$($st.op) $($st.name)"; $Job.total = $steps.Count; $Job.done = $i }
        try {
            switch ($st.op) {
                'off' { Disable-InstalledMod -Name $st.name }
                'on' { Enable-InstalledMod -Name $st.name }
                default { $t = $then[$st.name]; Install-ModArchive -Archive $t.archive -Meta (Copy-Meta $t) | Out-Null }
            }
        }
        catch { $fail.Add("$($st.name): $($_.Exception.Message)") }
        $i++
    }
    if ($Job) { $Job.done = $i }
    @{ done = $steps.Count - $fail.Count; fail = $fail }
}

# list for the UI: points without their mod lists, with what differs from now
function Get-RestoreSummaries {
    $now = @{}; foreach ($x in Get-SetupItems (Get-State)) { $now[$x.name] = $x }
    @(Get-RestorePoints | ForEach-Object {
            $p = $_; $then = @{}; foreach ($x in @($p.mods)) { $then[$x.name] = $x }
            $added = @($now.Keys | Where-Object { $now[$_].on -and -not ($then[$_] -and $then[$_].on) }).Count
            $gone = @($then.Keys | Where-Object { $then[$_].on -and -not ($now[$_] -and $now[$_].on) }).Count
            $changed = @($then.Keys | Where-Object { $now[$_] -and "$($now[$_].fileId)|$($now[$_].version)" -ne "$($then[$_].fileId)|$($then[$_].version)" }).Count
            [ordered]@{ id = $p.id; at = $p.at; kind = $p.kind; label = $p.label; launch = $p.launch; mods = @($p.mods | Where-Object { $_.on }).Count; added = $added; gone = $gone; changed = $changed }
        })
}
#endregion

#region profiles: named sets of mods that are on; switching keeps the versions installed now and never turns frameworks off
function Get-ProfileFile { Join-Path (Get-CpPaths).state 'profiles.json' }
function Get-Profiles { $f = Get-ProfileFile; if (Test-Path -LiteralPath $f) { @(Read-JsonFile $f | Where-Object { $_ }) } else { @() } }
function Save-Profile([string]$Name) {
    $Name = "$Name".Trim()
    if (-not $Name -or $Name.Length -gt 60) { throw 'Give the profile a name of 1 to 60 characters' }
    Use-Lock {
        $p = [ordered]@{ name = $Name; at = (Get-Date).ToString('s'); mods = @(Get-SetupItems (Get-State) | Where-Object { $_.on }) }
        Write-JsonFile (Get-ProfileFile) @(@(Get-Profiles | Where-Object { $_.name -ne $Name }) + $p | Sort-Object { $_.name })
        Write-Note "Profile saved: $Name ($(@($p.mods).Count) mods on)"
        $p
    }
}
function Remove-Profile([string]$Name) {
    Use-Lock { Write-JsonFile (Get-ProfileFile) @(Get-Profiles | Where-Object { $_.name -ne $Name }) }
}
# the profile whose mods are exactly the ones on now (frameworks left out), or $null
function Get-ProfileInUse($S) {
    $fw = @(Get-Frameworks | ForEach-Object { "$($_.name)" })
    $key = { param($items) @($items | Where-Object { $_ -and $fw -notcontains $_.name -and "$($_.source)" -notlike 'github:*' } | ForEach-Object { "$($_.name)" } | Sort-Object -Unique) -join "`n" }
    $now = & $key $S.mods
    foreach ($p in Get-Profiles) { if ((& $key @($p.mods)) -ceq $now) { return $p.name } }
    $null
}
function Get-ProfileSummaries {
    $use = Get-ProfileInUse (Get-State)
    @(foreach ($p in Get-Profiles) {
            $pl = Get-SetupPlan $p.mods -SameVersions
            [ordered]@{ name = $p.name; at = $p.at; mods = @($p.mods).Count; inUse = $p.name -eq $use; off = @($pl.off); on = @($pl.on); install = @($pl.install); missing = @($pl.missing) }
        })
}
function Invoke-Profile([string]$Name, $Job) {
    Assert-GameReady
    if (Get-BisectState) { throw 'Troubleshooting is running: finish it first, then switch profiles' }
    $p = @(Get-Profiles) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $p) { throw 'That profile no longer exists' }
    $plan = Get-SetupPlan $p.mods -SameVersions
    [void](Save-RestorePoint 'auto' "Before switching to the profile $Name")
    $r = Invoke-SetupPlan $plan $p.mods $Job
    $msg = "Switched to $($Name): $($r.done) change(s)"
    if ($plan.missing.Count) { $msg += "; $($plan.missing.Count) mod(s) could not come back" }
    if ($r.fail.Count) { $msg += ". Problems: $($r.fail -join '; ')" }
    Write-Note $msg
    $msg
}
#endregion

#region modpacks: gets the mods of a code or mod list. A restore point and a mod settings backup come first;
# $UsePack names your mods that take the pack's version (the others keep yours). Downloads go through the queue
# (-Start opens its first Nexus page).
function Invoke-ModPack($Pack, [string[]]$UsePack, $Job, [switch]$Start) {
    Assert-GameReady
    if (Get-BisectState) { throw 'Troubleshooting is running: finish it first, then get the modpack' }
    $plan = Get-PackPlan $Pack
    $label = "Before the modpack $(if ($Pack.name) { $Pack.name } else { 'from a code' })"
    [void](Save-RestorePoint 'manual' $label)
    [void](Backup-ModSettings 'manual' $label)
    $notes = [Collections.Generic.List[string]]::new()
    foreach ($fw in @(Get-Frameworks | Where-Object { $plan.frameworks -contains $_.name })) {
        if ($Job) { $Job.phase = "installing $($fw.name)" }
        try { [void](Install-GitHubFramework $fw) } catch { $notes.Add("$($fw.name) not installed: $($_.Exception.Message)") }
    }
    # your mods that are off come back on, also the ones whose version you keep
    $on = 0
    foreach ($n in @(@($plan.turnOn) + @($plan.versions | Where-Object { -not $_.on -and $UsePack -notcontains $_.name } | ForEach-Object { $_.name }))) {
        if ($Job) { $Job.phase = "turning on $n" }
        try {
            $r = Enable-InstalledMod -Name $n -Ask:(Test-AskOverwrite)
            if (-not $r.conflict) { $on++; continue }
            $d = (Get-State).disabled | Where-Object { $_.name -eq $n } | Select-Object -First 1
            Add-Deferred 'pending' $d.archive (Copy-Meta $d) '' $r.conflict
            $notes.Add("$n waits for your choice")
        }
        catch { $notes.Add("$n not turned on: $($_.Exception.Message)") }
    }
    $q = Add-QueueItems (@($plan.new) + @($plan.versions | Where-Object { $UsePack -contains $_.name })) "Modpack$(if ($Pack.name) { ": $($Pack.name)" })"
    $msg = "$($q.added) download(s) queued"
    if ($q.added -and $Start -and (Open-NextQueue)) { $msg += ', the first Nexus page is open' }
    if ($on) { $msg += "; $on mod(s) turned back on" }
    if ($plan.frameworks.Count) { $msg += "; frameworks: $($plan.frameworks -join ', ')" }
    if ($plan.gone.Count) { $msg += "; $($plan.gone.Count) no longer on Nexus" }
    $msg += ". Restore point: $label"
    if ($notes.Count) { $msg += ". Problems: $($notes -join '; ')" }
    Write-Note $msg
    $msg
}
#endregion

#region save backups: copies of the newest saves (never moved), before launches with a changed mod setup
function Get-SavesBackupDir { Get-SafetyDir 'saves' }
function Get-SaveBackups {
    $d = Get-SavesBackupDir
    @(Get-ChildItem -LiteralPath $d -Directory | Sort-Object Name -Descending | ForEach-Object {
            $i = try { Read-JsonFile (Join-Path $_.FullName 'info.json') } catch { $null }
            if ($i -is [Collections.IDictionary]) { $i.id = $_.Name; $i }
        })
}
# -Names: these save folders; otherwise the $Count newest. -NoPrune: keep every older copy (a restore reads one of them)
function Backup-Saves([string]$Reason, [string]$SavesDir, [string[]]$Names, [int]$Count = 12, [switch]$NoPrune) {
    if (-not $SavesDir) { $SavesDir = (Get-GameLocations).saves }
    if (-not (Test-Path -LiteralPath $SavesDir)) { throw "No save folder at $SavesDir" }
    $all = @(Get-ChildItem -LiteralPath $SavesDir -Directory | ForEach-Object { $d = Join-Path $_.FullName 'sav.dat'; if (Test-Path -LiteralPath $d) { Add-Member -InputObject $_ -NotePropertyName SavedAt -NotePropertyValue (Get-Item -LiteralPath $d).LastWriteTime -PassThru } } | Sort-Object SavedAt -Descending)
    $saves = if ($Names) { @($all | Where-Object { $Names -contains $_.Name }) } else { @($all | Select-Object -First $Count) }
    if (-not $saves) { return $null }
    $root = Get-SavesBackupDir
    $id = New-SafetyId $root ''
    $dest = Join-Path $root $id
    [void](New-Item -ItemType Directory -Force -Path $dest)
    foreach ($sv in $saves) { Copy-Item -LiteralPath $sv.FullName -Destination (Join-Path $dest $sv.Name) -Recurse -Force }
    $size = [long](Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object Length -Sum).Sum
    $info = [ordered]@{ at = (Get-Date).ToString('s'); reason = $Reason; saves = @($saves | ForEach-Object { [ordered]@{ name = $_.Name; time = $_.SavedAt.ToString('s') } }); size = $size
        # only a copy of the newest saves stands for the setup; a few picked saves must not make the next automatic copy look done
        sig = $(if ($Names) { $null } else { Get-SetupSig (Get-SetupItems (Get-State)) })
    }
    Write-JsonFile (Join-Path $dest 'info.json') $info
    # oldest copies beyond the limit go (cpmods' own copies only)
    $keep = [Math]::Max(1, [int](Get-CpSettings).saveKeep)
    if (-not $NoPrune) { foreach ($old in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending | Select-Object -Skip $keep)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force } }
    Write-Note "Backed up $($saves.Count) saves ($Reason)"
    $info.id = $id
    $info
}
# a copy is due when the setting is on and the mod setup changed since the last copy
function Test-SaveBackupDue {
    if (-not (Get-CpSettings).saveBackup) { return $false }
    $last = @(Get-SaveBackups | Where-Object { $_.sig }) | Select-Object -First 1
    -not ($last -and $last.sig -eq (Get-SetupSig (Get-SetupItems (Get-State))))
}
function Invoke-AutoSaveBackup([string]$Reason, [string]$SavesDir) {
    try { if (Test-SaveBackupDue) { Backup-Saves $Reason $SavesDir } else { $null } }
    catch { Write-Note "Save backup failed: $($_.Exception.Message)"; $null }
}
# copies saves back; the current versions of those saves are copied aside first, so this can be undone
function Restore-Saves([string]$Id, [string[]]$Names, [string]$SavesDir) {
    Assert-SafetyId $Id
    if ((Get-GameState).running) { throw 'Close the game first' }
    if (-not $SavesDir) { $SavesDir = (Get-GameLocations).saves }
    $src = Join-Path (Get-SavesBackupDir) $Id
    if (-not (Test-Path -LiteralPath $src)) { throw 'That backup no longer exists' }
    $avail = @(Get-ChildItem -LiteralPath $src -Directory | ForEach-Object { $_.Name })
    $want = @(if ($Names) { $Names | Where-Object { $avail -contains $_ } } else { $avail })
    if (-not $want) { throw 'Nothing to restore' }
    $cur = @($want | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $SavesDir $_) 'sav.dat') })
    if ($cur) {
        $when = ([datetime](Read-JsonFile (Join-Path $src 'info.json')).at).ToString('d MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $pre = Backup-Saves "Before restoring saves from $when" $SavesDir $cur -NoPrune
        if (-not $pre -or @($pre.saves).Count -ne $cur.Count) { throw 'Could not copy your current saves aside, so nothing was changed' }
    }
    # exact copies: the current folder goes (its copy was just made) and the backed-up one comes back
    foreach ($n in $want) {
        $dst = Join-Path $SavesDir $n
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $src $n) -Destination $dst -Recurse
    }
    Write-Note "Restored $($want.Count) save(s) from backup $Id"
    "Restored $($want.Count) save(s)"
}
function Remove-SaveBackup([string]$Id) {
    Assert-SafetyId $Id
    $p = Join-Path (Get-SavesBackupDir) $Id
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
#endregion

#region mod settings: files mods write for themselves (CET, Mod Settings, plugin configs) and config files changed after install
$script:UntrackedExt = '.json', '.ini', '.toml', '.yaml', '.yml', '.sqlite3', '.sqlite', '.db', '.cfg', '.conf', '.lua'
$script:EditedExt = '.json', '.ini', '.toml', '.yaml', '.yml', '.cfg', '.conf', '.reds', '.lua', '.xml', '.txt'
$script:SettingsRoots = 'bin\x64\plugins\cyber_engine_tweaks', 'red4ext\plugins', 'r6\scripts', 'r6\tweaks', 'r6\input', 'engine\config'
function Get-SettingsBackupDir { Get-SafetyDir 'settings' }
# a settings file may only live in mod folders: guards restores and imported zips
function Test-SettingsPath([string]$Rel) {
    $r = "$Rel" -replace '/', '\'
    if (-not $r -or [IO.Path]::IsPathRooted($r) -or $r -match '(^|\\)\.\.(\\|$)' -or $r -match '[<>:"|?*]') { return $false }
    # settings file types only: a .dll or .asi in a "settings" zip would run with the game (.lua and .reds can be
    # settings too; Import-ModSettings leaves out the code ones from other people's zips)
    $ext = [IO.Path]::GetExtension($r).ToLower()
    if ($script:UntrackedExt -notcontains $ext -and $script:EditedExt -notcontains $ext) { return $false }
    foreach ($root in $script:SettingsRoots) { if ($r.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}
function Get-ModSettingsFiles {
    $g = (Get-CpPaths).game
    $own = @{}
    foreach ($m in (Get-State).mods) { foreach ($f in @($m.files)) { $own["$f".ToLower()] = $m } }
    $edited = { param($fi, $m) $script:EditedExt -contains $fi.Extension.ToLower() -and $m.installed -and $fi.LastWriteTime -gt ([datetime]$m.installed).AddMinutes(1) }
    $out = [ordered]@{}
    $add = { param($rel, $m, $tracked) $out[$rel.ToLower()] = [ordered]@{ path = $rel; mod = $(if ($m) { $m.name } else { $null }); version = $(if ($m) { "$($m.version)" } else { $null }); tracked = $tracked } }
    # whole folders of CET mods and RED4ext plugins: they write their settings next to themselves
    $roots = @{}
    foreach ($k in $own.Keys) { if ($k -match '^(bin\\x64\\plugins\\cyber_engine_tweaks\\mods\\[^\\]+|red4ext\\plugins\\[^\\]+)\\') { $roots[$Matches[1]] = $own[$k] } }
    foreach ($r in $roots.Keys) {
        $full = Join-Path $g $r
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        foreach ($fi in Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue) {
            $rel = [IO.Path]::GetRelativePath($g, $fi.FullName); $lk = $rel.ToLower()
            if ($fi.Length -gt 4MB -or $lk -match '\\(logs?|cache)\\') { continue }
            $m = $own[$lk]
            if ($m) { if (& $edited $fi $m) { & $add $rel $m $true } }
            elseif ($script:UntrackedExt -contains $fi.Extension.ToLower()) { & $add $rel $roots[$r] $false }
        }
    }
    # CET's own hotkeys and overlay settings
    $cetOwner = $own['bin\x64\plugins\cyber_engine_tweaks.asi']
    foreach ($n in 'bindings.json', 'config.json', 'persistent.json', 'layout.ini') {
        $rel = "bin\x64\plugins\cyber_engine_tweaks\$n"
        if (Test-Path -LiteralPath (Join-Path $g $rel) -PathType Leaf) { & $add $rel $cetOwner $false }
    }
    # config files you edited in other mod folders (config.reds, tweaks, key files, engine ini)
    foreach ($k in $own.Keys) {
        if ($k -notmatch '^(r6\\(scripts|tweaks|input)|engine\\config)\\') { continue }
        $fi = Get-Item -LiteralPath (Join-Path $g $k) -ErrorAction SilentlyContinue
        if ($fi -and (& $edited $fi $own[$k])) { & $add ([IO.Path]::GetRelativePath($g, $fi.FullName)) $own[$k] $true }
    }
    @($out.Values)
}

function Backup-ModSettings([string]$Kind = 'manual', [string]$Reason = '') {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $g = (Get-CpPaths).game
    $files = @(Get-ModSettingsFiles)
    $dir = Get-SettingsBackupDir
    $id = New-SafetyId $dir '.zip'
    $zipPath = Join-Path $dir "$id.zip"
    $done = [Collections.Generic.List[object]]::new()
    $z = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($f in $files) {
            try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $g $f.path), ($f.path -replace '\\', '/')); $done.Add($f) }
            catch { Write-Note "  settings backup skipped $($f.path): $($_.Exception.Message)" DarkGray }
        }
        $man = [ordered]@{ format = 'cpmods-settings'; version = 1; at = (Get-Date).ToString('s'); kind = $Kind; reason = $Reason; files = @($done) }
        $sw = [IO.StreamWriter]::new($z.CreateEntry('manifest.json').Open(), [Text.UTF8Encoding]::new($false))
        try { $sw.Write((ConvertTo-Json -InputObject $man -Depth 6)) } finally { $sw.Dispose() }
    }
    finally { $z.Dispose() }
    # keep 10 automatic and 20 other backups
    $man2 = 0; $auto = 0
    foreach ($b in @(Get-SettingsBackups)) {
        $over = if ($b.kind -eq 'auto') { ++$auto -gt 10 } else { ++$man2 -gt 20 }
        if ($over) { Remove-Item -LiteralPath (Join-Path $dir "$($b.id).zip") -Force -ErrorAction SilentlyContinue }
    }
    Write-Note "Mod settings backup: $($done.Count) files ($Reason)"
    [ordered]@{ id = $id; count = $done.Count }
}

function Read-SettingsManifest([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $e = $z.GetEntry('manifest.json')
        if (-not $e) { throw 'Not a cpmods settings backup (no manifest)' }
        $sr = [IO.StreamReader]::new($e.Open())
        try { $m = $sr.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $sr.Dispose() }
        if ($m.format -ne 'cpmods-settings') { throw 'Not a cpmods settings backup' }
        $m
    }
    finally { $z.Dispose() }
}
function Get-SettingsBackups {
    $dir = Get-SettingsBackupDir
    @(Get-ChildItem -LiteralPath $dir -Filter *.zip -File | Sort-Object Name -Descending | ForEach-Object {
            $m = try { Read-SettingsManifest $_.FullName } catch { $null }
            if ($m) { [ordered]@{ id = $_.BaseName; at = $m.at; kind = $m.kind; reason = $m.reason; count = @($m.files).Count; size = $_.Length } }
        })
}

# -Preview: what would be written and what is skipped (mod gone, or a newer version whose config may differ)
function Restore-ModSettings([string]$Id, [switch]$Preview) {
    Assert-SafetyId $Id
    $zipPath = Join-Path (Get-SettingsBackupDir) "$Id.zip"
    if (-not (Test-Path -LiteralPath $zipPath)) { throw 'That backup no longer exists' }
    $g = (Get-CpPaths).game
    $man = Read-SettingsManifest $zipPath
    $mods = @{}; foreach ($m in (Get-State).mods) { $mods[$m.name] = $m }
    $write = [Collections.Generic.List[object]]::new(); $skip = [Collections.Generic.List[object]]::new()
    foreach ($f in @($man.files)) {
        $rel = "$($f.path)" -replace '/', '\'
        $why = if (-not (Test-SettingsPath $rel)) { 'not in a mod folder' }
        elseif ($f.mod -and -not $mods.ContainsKey($f.mod)) { "$($f.mod) is not installed" }
        elseif ($f.tracked -and $f.mod -and "$($mods[$f.mod].version)" -ne "$($f.version)") { "$($f.mod) changed from $($f.version) to $($mods[$f.mod].version), so the old file may not fit" }
        elseif (-not (Test-Path -LiteralPath (Split-Path (Join-Path $g $rel)) -PathType Container)) { 'its folder is gone' }
        else { $null }
        if ($why) { $skip.Add([ordered]@{ path = $rel; why = $why }) } else { $write.Add([ordered]@{ path = $rel; mod = $f.mod }) }
    }
    $res = [ordered]@{ id = $Id; at = $man.at; write = @($write); skip = @($skip) }
    if ($Preview) { return $res }
    if ((Get-GameState).running) { throw 'Close the game first' }
    [void](Backup-ModSettings 'auto' "Before restoring settings from $(([datetime]$man.at).ToString('d MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture))")
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($w in $write) {
            $e = $z.GetEntry(($w.path -replace '\\', '/'))
            if ($e) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $g $w.path), $true) }
        }
    }
    finally { $z.Dispose() }
    Write-Note "Restored $($write.Count) mod settings files from $Id ($($skip.Count) skipped)"
    $res
}
function Remove-SettingsBackup([string]$Id) {
    Assert-SafetyId $Id
    Remove-Item -LiteralPath (Join-Path (Get-SettingsBackupDir) "$Id.zip") -Force -ErrorAction SilentlyContinue
}
# a settings zip from a friend (base64): kept as an "imported" backup after its paths are checked
function Import-ModSettings([string]$Base64) {
    $bytes = [Convert]::FromBase64String($Base64)
    if ($bytes.Length -gt 50MB) { throw 'That file is too big for a settings backup' }
    $dir = Get-SettingsBackupDir
    $id = New-SafetyId $dir '.zip'
    $tmp = Join-Path $dir "$id.tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    try {
        $man = Read-SettingsManifest $tmp
        $bad = @(@($man.files) | Where-Object { -not (Test-SettingsPath $_.path) })
        if ($bad) { throw "It holds files outside mod folders ($($bad[0].path))" }
        # someone else's file: any .lua (CET mods load more than init.lua) or .reds script is mod code, not a setting; left out
        $all = @($man.files)
        $man.files = @($all | Where-Object { "$($_.path)" -notmatch '(?i)\.(lua|reds)$' })
        $code = $all.Count - @($man.files).Count
        $man.kind = 'imported'; $man.reason = 'Imported file'
        $z = [IO.Compression.ZipFile]::Open($tmp, 'Update')
        try {
            $z.GetEntry('manifest.json').Delete()
            $sw = [IO.StreamWriter]::new($z.CreateEntry('manifest.json').Open(), [Text.UTF8Encoding]::new($false))
            try { $sw.Write((ConvertTo-Json -InputObject $man -Depth 6)) } finally { $sw.Dispose() }
        }
        finally { $z.Dispose() }
        Move-Item -LiteralPath $tmp -Destination (Join-Path $dir "$id.zip")
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-Note "Imported a mod settings backup ($(@($man.files).Count) files$(if ($code) { ", $code code files left out" }))"
    [ordered]@{ id = $id; count = @($man.files).Count; code = $code }
}
#endregion

#region launch without mods: mod folders and loader files move into <game>\_cpmods_vanilla (same drive: instant) and come back after
$script:VanillaDirs = 'archive\pc\mod', 'r6\scripts', 'r6\tweaks', 'r6\input', 'red4ext', 'bin\x64\plugins', 'mods'
# loaders and DLL injectors (ReShade, ASI loaders): the game ships none of these in bin\x64; moved only when present
$script:VanillaFiles = 'bin\x64\version.dll', 'bin\x64\winmm.dll', 'bin\x64\global.ini', 'engine\config\base\scripts.ini', 'bin\x64\dxgi.dll', 'bin\x64\d3d11.dll', 'bin\x64\d3d12.dll', 'bin\x64\dinput8.dll'
# an antivirus scan of fresh files blocks a move for a moment: try again for a few seconds
function Move-Retry([string]$From, [string]$To, [bool]$Dir, [bool]$Overwrite = $false) {
    for ($i = 0; ; $i++) {
        try { if ($Dir) { [IO.Directory]::Move($From, $To) } else { [IO.File]::Move($From, $To, $Overwrite) }; return }
        catch [UnauthorizedAccessException], [IO.IOException] {
            if ($i -ge 15) { throw }
            # folder listings this process left open (any module) are closed by the finalizers
            if ($i -eq 0) { [GC]::Collect(); [GC]::WaitForPendingFinalizers() }
            Start-Sleep -Milliseconds 300
        }
    }
}
function Get-VanillaFile { Join-Path (Get-CpPaths).state 'vanilla.json' }
function Get-VanillaState { $f = Get-VanillaFile; if (Test-Path -LiteralPath $f) { Read-JsonFile $f } else { $null } }
function Set-VanillaSeen { $j = Get-VanillaState; if ($j -and -not $j.gameSeen) { $j.gameSeen = $true; Write-JsonFile (Get-VanillaFile) $j } }

function Start-VanillaSession {
    Assert-GameReady
    $p = Get-CpPaths; $g = $p.game
    $park = Join-Path $g '_cpmods_vanilla'
    if (Get-FirstEntry $park -Recurse -File) { throw "$park still holds files from an earlier launch without mods. Move them back into the game folder first." }
    $s = Get-State
    # base game files a mod replaced: the original copy goes in while the mod's copy is set aside
    $orig = @{}
    foreach ($m in $s.mods) { foreach ($b in @($m.backups)) { $bp = Join-Path $p.root (Join-Path 'backup' (Join-Path (Get-SafeName $m.name) $b)); if (Test-Path -LiteralPath $bp) { $orig["$b".ToLower()] = $bp } } }
    $moves = [Collections.Generic.List[object]]::new()
    foreach ($d in $script:VanillaDirs) { if (Test-Path -LiteralPath (Join-Path $g $d) -PathType Container) { $moves.Add([ordered]@{ rel = $d; dir = $true; orig = $null; done = $false }) } }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($script:VanillaFiles) + @($s.mods | ForEach-Object { @($_.files) })) {
        $f = "$f"
        if (-not $f -or -not $seen.Add($f)) { continue }
        if (@($script:VanillaDirs | Where-Object { $f.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $g $f) -PathType Leaf)) { continue }
        $moves.Add([ordered]@{ rel = $f; dir = $false; orig = $orig[$f.ToLower()]; done = $false })
    }
    $j = [ordered]@{ started = (Get-Date).ToString('s'); park = $park; moves = $moves; gameSeen = $false; settings = $null }
    # the game resets every setting when it finds options only mods know: keep a copy to put back
    $us = Join-Path (Get-GameLocations).config 'UserSettings.json'
    if (Test-Path -LiteralPath $us) { $j.settings = Join-Path $p.state 'vanilla-usersettings.json'; Copy-Item -LiteralPath $us -Destination $j.settings -Force }
    Write-JsonFile (Get-VanillaFile) $j
    try {
        foreach ($mv in $moves) {
            $from = Join-Path $g $mv.rel; $to = Join-Path $park $mv.rel
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $to))
            Move-Retry $from $to $mv.dir
            $mv.done = $true
            if ($mv.orig) { Copy-Item -LiteralPath $mv.orig -Destination $from -Force }
            Write-JsonFile (Get-VanillaFile) $j
        }
    }
    catch {
        $err = $_.Exception.Message
        try { [void](Restore-VanillaSession) } catch { }
        throw "Could not set the mods aside ($err). Everything was put back."
    }
    Write-Note "Launch without mods: set aside $($moves.Count) mod folders and files"
    "Set aside $($moves.Count) mod folders and files"
}

function Restore-VanillaSession {
    $j = Get-VanillaState
    if (-not $j) { return 'Nothing to bring back' }
    if ((Get-GameState).running) { throw 'Close the game first' }
    $g = (Get-CpPaths).game; $park = "$($j.park)"
    $fail = [Collections.Generic.List[string]]::new()
    $list = @($j.moves); [array]::Reverse($list)
    foreach ($mv in $list) {
        if (-not $mv.done) { continue }
        $from = Join-Path $g $mv.rel; $to = Join-Path $park $mv.rel
        try {
            if (-not (Test-Path -LiteralPath $to)) { $mv.done = $false; continue }
            if (-not $mv.dir) { Move-Retry $to $from $false $true }
            elseif (-not (Test-Path -LiteralPath $from)) { Move-Retry $to $from $true }
            else {
                # something made the folder again meanwhile: move the parked items into it
                foreach ($c in Get-ChildItem -LiteralPath $to -Force) {
                    $dst = Join-Path $from $c.Name
                    if (Test-Path -LiteralPath $dst) { throw "$($mv.rel)\$($c.Name) exists in both places" }
                    Move-Item -LiteralPath $c.FullName -Destination $dst
                }
                Remove-Item -LiteralPath $to -Force
            }
            $mv.done = $false
        }
        catch { $fail.Add("$($mv.rel): $($_.Exception.Message)") }
    }
    if ($fail.Count) {
        Write-JsonFile (Get-VanillaFile) $j
        throw "Some mod files could not be put back: $($fail -join '; '). They are in $park."
    }
    if ($j.settings -and (Test-Path -LiteralPath $j.settings)) { Copy-Item -LiteralPath $j.settings -Destination (Join-Path (Get-GameLocations).config 'UserSettings.json') -Force; Remove-Item -LiteralPath $j.settings -Force }
    Remove-Item -LiteralPath (Get-VanillaFile) -Force
    if ((Test-Path -LiteralPath $park) -and -not (Get-FirstEntry $park -Recurse -File)) { Remove-Item -LiteralPath $park -Recurse -Force }
    Write-Note 'Launch without mods: mods are back'
    'Your mods are back'
}
#endregion

#region key bindings: game controls as you set them, Input Loader files, Mod Settings and CET hotkeys
$script:VkIk = @{ 0x01 = 'IK_LeftMouse'; 0x02 = 'IK_RightMouse'; 0x04 = 'IK_MiddleMouse'; 0x05 = 'IK_MouseX1'; 0x06 = 'IK_MouseX2'; 0x08 = 'IK_Backspace'; 0x09 = 'IK_Tab'; 0x0D = 'IK_Enter'
    0x10 = 'IK_Shift'; 0x11 = 'IK_Ctrl'; 0x12 = 'IK_Alt'; 0x13 = 'IK_Pause'; 0x14 = 'IK_CapsLock'; 0x1B = 'IK_Escape'; 0x20 = 'IK_Space'; 0x21 = 'IK_PageUp'; 0x22 = 'IK_PageDown'
    0x23 = 'IK_End'; 0x24 = 'IK_Home'; 0x25 = 'IK_Left'; 0x26 = 'IK_Up'; 0x27 = 'IK_Right'; 0x28 = 'IK_Down'; 0x2D = 'IK_Insert'; 0x2E = 'IK_Delete'; 0xA0 = 'IK_LShift'; 0xA1 = 'IK_RShift'
    0xA2 = 'IK_LControl'; 0xA3 = 'IK_RControl'; 0xA4 = 'IK_LAlt'; 0xA5 = 'IK_RAlt'; 0xBA = 'IK_Semicolon'; 0xBB = 'IK_Equals'; 0xBC = 'IK_Comma'; 0xBD = 'IK_Minus'; 0xBE = 'IK_Period'
    0xBF = 'IK_Slash'; 0xC0 = 'IK_Tilde'; 0xDB = 'IK_LeftBracket'; 0xDC = 'IK_Backslash'; 0xDD = 'IK_RightBracket'; 0xDE = 'IK_SingleQuote'
}
function ConvertFrom-VirtualKey([int]$Vk) {
    if (($Vk -ge 0x30 -and $Vk -le 0x39) -or ($Vk -ge 0x41 -and $Vk -le 0x5A)) { return "IK_$([char]$Vk)" }
    if ($Vk -ge 0x60 -and $Vk -le 0x69) { return "IK_NumPad$($Vk - 0x60)" }
    if ($Vk -ge 0x70 -and $Vk -le 0x87) { return "IK_F$($Vk - 0x6F)" }
    if ($script:VkIk.ContainsKey($Vk)) { return $script:VkIk[$Vk] }
    'IK_0x{0:X2}' -f $Vk
}

function Get-KeyMap([string]$UserSettings) {
    if (-not $UserSettings) { $UserSettings = Join-Path (Get-GameLocations).config 'UserSettings.json' }
    $g = (Get-CpPaths).game
    $s = Get-State
    $maps = Get-OwnerMaps $s
    $ownerOf = { param($rel) $r = "$rel"; if ($maps.file.ContainsKey($r)) { return $maps.file[$r] }; $d = [IO.Path]::GetDirectoryName($r); while ($d) { if ($maps.dir.ContainsKey($d)) { return $maps.dir[$d] }; $d = [IO.Path]::GetDirectoryName($d) }; $null }
    $uses = [Collections.Generic.List[object]]::new()
    $add = { param($key, $src, $who, $action, $ctx, $link) if ($key -and "$key" -notmatch '^IK_(Pad|PS4|Touch|None)') { $uses.Add([ordered]@{ key = "$key"; src = $src; who = $who; action = $action; ctx = $ctx; link = $link }) } }
    # 1. game controls (Settings > Controls), from the game's own settings file
    $game = @{}
    if (Test-Path -LiteralPath $UserSettings) {
        foreach ($grp in @((Read-JsonFile $UserSettings).data)) {
            if ("$($grp.group_name)" -notlike '/key_bindings/*') { continue }
            $ctx = "$($grp.group_name)" -replace '^/key_bindings/(Settings)?', ''
            foreach ($o in @($grp.options)) { if ($o.type -eq 'name' -and "$($o.value)" -like 'IK_*') { $game["$($o.name)"] = "$($o.value)"; & $add "$($o.value)" 'game' 'Game' "$($o.name)" $ctx $null } }
        }
    }
    # 2. Input Loader files (r6\input and plugin inputs.xml); a rebindable button follows your setting
    $xmls = @(Get-ChildItem -LiteralPath (Join-Path $g 'r6\input') -Recurse -Filter *.xml -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath (Join-Path $g 'red4ext\plugins') -Recurse -Filter inputs.xml -File -ErrorAction SilentlyContinue)
    foreach ($f in $xmls) {
        $rel = Get-RelGamePath $f.FullName
        $who = & $ownerOf $rel; if (-not $who) { $who = $f.BaseName }
        try { $x = [xml]([IO.File]::ReadAllText($f.FullName)) } catch { continue }
        foreach ($mp in $x.SelectNodes('//mapping')) {
            foreach ($b in $mp.SelectNodes('button')) {
                $ov = "$($b.GetAttribute('overridableUI'))"
                $k = if ($ov -and $game.ContainsKey($ov)) { $game[$ov] } else { "$($b.GetAttribute('id'))" }
                & $add $k 'input' $who "$($mp.GetAttribute('name'))" $null $(if ($ov) { $ov } else { $null })
            }
        }
    }
    # 3. Mod Settings hotkeys; sections are named after the mod's script module or class
    $ini = Join-Path $g 'red4ext\plugins\mod_settings\user.ini'
    if (Test-Path -LiteralPath $ini) {
        $mod = @{}; $reds = @()
        foreach ($m in $s.mods) { foreach ($f in @($m.files)) { if ("$f" -like '*.reds') { $reds += , @("$f", $m.name) } } }
        foreach ($r in $reds) {
            $p = Join-Path $g $r[0]
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $mm = [regex]::Match([IO.File]::ReadAllText($p), '(?m)^\s*module\s+([\w.]+)')
            if ($mm.Success -and -not $mod.ContainsKey($mm.Groups[1].Value)) { $mod[$mm.Groups[1].Value] = $r[1] }
        }
        $whoOf = {
            param($sec)
            if ($sec -match '^(.+)\.[^.]+$' -and $mod.ContainsKey($Matches[1])) { return $mod[$Matches[1]] }
            $hit = $reds | Where-Object { (Test-Path -LiteralPath (Join-Path $g $_[0])) -and (Select-String -LiteralPath (Join-Path $g $_[0]) -Pattern "class\s+$([regex]::Escape(($sec -split '\.')[-1]))\b" -Quiet) } | Select-Object -First 1
            if ($hit) { $hit[1] } else { $sec }
        }
        $sec = ''; $secWho = @{}
        foreach ($ln in [IO.File]::ReadAllLines($ini)) {
            if ($ln -match '^\s*\[(.+)\]\s*$') { $sec = $Matches[1]; continue }
            if ($ln -match '^\s*([^=;#\[]+?)\s*=\s*(IK_\w+)\s*$') {
                if (-not $secWho.ContainsKey($sec)) { $secWho[$sec] = & $whoOf $sec }
                & $add $Matches[2] 'modsettings' $secWho[$sec] $Matches[1] $null $null
            }
        }
    }
    # 4. CET hotkeys: one 64-bit number per hotkey, a key code in each 16 bits (first key in the top bits)
    $bj = Join-Path $g 'bin\x64\plugins\cyber_engine_tweaks\bindings.json'
    if (Test-Path -LiteralPath $bj) {
        $b = Read-JsonFile $bj
        foreach ($folder in @($b.Keys)) {
            $who = if ($folder -eq 'cet') { 'Cyber Engine Tweaks' } else { $o = & $ownerOf "bin\x64\plugins\cyber_engine_tweaks\mods\$folder\init.lua"; if ($o) { $o } else { $folder } }
            foreach ($hk in @($b[$folder].Keys)) {
                $v = [uint64]$b[$folder][$hk]
                if (-not $v) { continue }
                $keys = @(48, 32, 16, 0 | ForEach-Object { [int](($v -shr $_) -band 0xFFFF) } | Where-Object { $_ } | ForEach-Object { ConvertFrom-VirtualKey $_ })
                if (-not $keys) { continue }
                & $add $keys[-1] 'cet' $who $(if ($folder -eq 'cet' -and $hk -eq 'overlay_key') { 'open the overlay' } else { $hk }) $(if ($keys.Count -gt 1) { ($keys -replace '^IK_', '') -join ' + ' } else { $null }) $null
            }
        }
    }
    # a key two mods use is a clash; a mod key the game also uses is shared (often fine: other context)
    $by = [ordered]@{}
    foreach ($u in $uses) { if (-not $by.Contains($u.key)) { $by[$u.key] = [Collections.Generic.List[object]]::new() }; $by[$u.key].Add($u) }
    $keys = foreach ($k in $by.Keys) {
        $l = $by[$k]
        $gameActs = @($l | Where-Object { $_.src -eq 'game' } | ForEach-Object { $_.action })
        $modUses = @($l | Where-Object { $_.src -ne 'game' -and -not ($_.link -and $gameActs -contains $_.link) })
        $who = @($modUses | ForEach-Object { $_.who } | Sort-Object -Unique)
        $state = if ($who.Count -ge 2) { 'clash' } elseif ($who.Count -eq 1 -and $gameActs.Count) { 'shared' } elseif ($who.Count -eq 1) { 'mod' } else { 'game' }
        [ordered]@{ key = $k; state = $state; mods = $who; uses = @($l) }
    }
    $keys = @($keys)
    [ordered]@{
        keys = $keys; userSettings = (Test-Path -LiteralPath $UserSettings)
        counts = [ordered]@{ clash = @($keys | Where-Object { $_.state -eq 'clash' }).Count; shared = @($keys | Where-Object { $_.state -eq 'shared' }).Count; mod = @($keys | Where-Object { $_.state -in 'mod', 'shared', 'clash' }).Count; game = $game.Count }
    }
}
#endregion

#region disk space: what mods and cpmods' own data take, and a cleanup that never deletes what a mod or restore point uses
function Get-DirUse([string]$Path) {
    $b = 0L; $n = 0
    if ([IO.Directory]::Exists($Path)) {
        $o = [IO.EnumerationOptions]::new(); $o.RecurseSubdirectories = $true; $o.AttributesToSkip = 0
        foreach ($f in [IO.DirectoryInfo]::new($Path).EnumerateFiles('*', $o)) { $b += $f.Length; $n++ }
    }
    [ordered]@{ bytes = $b; files = $n }
}
# downloads a cleanup may delete: used by no mod (installed, off or waiting), not 30 minutes old (an install may be about
# to start), and with -Old also the older versions kept for going back (restore points, the two previous downloads of a mod)
function Get-SpareDownloads([switch]$Old) {
    $pts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # restore points and profiles both reinstall mods from these downloads
    foreach ($p in @(Get-RestorePoints) + @(Get-Profiles)) { foreach ($m in @($p.mods)) { if ($m.archive) { [void]$pts.Add([IO.Path]::GetFileName("$($m.archive)")) } } }
    $s = Get-State
    foreach ($m in @($s.mods) + @($s.disabled)) { foreach ($o in @($m.older)) { if ($o) { [void]$pts.Add([IO.Path]::GetFileName("$o")) } } }
    $cut = (Get-Date).AddMinutes(-30)
    foreach ($d in @(Get-DownloadsInfo $s)) {
        if ($d.status -ne 'unused' -or [datetime]$d.date -gt $cut) { continue }
        $d.points = $pts.Contains($d.file)
        if ($Old -or -not $d.points) { $d }
    }
}
function Get-StorageInfo {
    $p = Get-CpPaths; $s = Get-State
    $mods = @(foreach ($m in $s.mods) { $b = 0L; foreach ($f in @($m.files)) { $fi = [IO.FileInfo]::new((Join-Path $p.game $f)); if ($fi.Exists) { $b += $fi.Length } }; [ordered]@{ name = $m.name; bytes = $b } })
    $spare = @(Get-SpareDownloads -Old)
    $sum = { param($l, $k = 'size') $t = 0L; foreach ($x in @($l)) { $t += [long]$x[$k] }; $t }
    $data = [ordered]@{
        downloads = Get-DirUse $p.downloads; backup = Get-DirUse (Join-Path $p.root 'backup'); saves = Get-DirUse (Get-SavesBackupDir)
        settings = Get-DirUse (Get-SettingsBackupDir); parked = Get-DirUse (Join-Path $p.root 'parked'); tmp = Get-DirUse (Join-Path $p.root 'tmp'); app = Get-DirUse $p.state
    }
    $log = [IO.FileInfo]::new($p.log); if ($log.Exists) { $data.app.bytes += $log.Length }
    $drives = foreach ($d in @([IO.Path]::GetPathRoot($p.game), [IO.Path]::GetPathRoot($p.root)) | Select-Object -Unique) {
        try { $i = [IO.DriveInfo]::new($d); [ordered]@{ name = $i.Name.TrimEnd('\'); free = $i.AvailableFreeSpace; total = $i.TotalSize; game = $d -eq [IO.Path]::GetPathRoot($p.game); cpmods = $d -eq [IO.Path]::GetPathRoot($p.root) } } catch { }
    }
    [ordered]@{
        mods = [ordered]@{ bytes = & $sum $mods 'bytes'; count = $mods.Count; top = @($mods | Sort-Object { $_.bytes } -Descending | Select-Object -First 5) }
        data = $data; drives = @($drives); saveCopies = @(Get-SaveBackups).Count
        spare = [ordered]@{ free = @($spare | Where-Object { -not $_.points } | ForEach-Object { [ordered]@{ file = $_.file; size = $_.size } }); old = @($spare | Where-Object { $_.points } | ForEach-Object { [ordered]@{ file = $_.file; size = $_.size } })
            freeBytes = & $sum @($spare | Where-Object { -not $_.points }); oldBytes = & $sum @($spare | Where-Object { $_.points }) }
    }
}
function Invoke-StorageCleanup([bool]$Old) {
    $n = 0; $b = 0L
    foreach ($d in @(Get-SpareDownloads -Old:$Old)) {
        try { Remove-Item -LiteralPath (Join-Path (Get-CpPaths).downloads $d.file) -Force; $n++; $b += $d.size } catch { Write-Note "  cleanup kept $($d.file): $($_.Exception.Message)" }
    }
    # leftovers of interrupted installs; installs run under the same lock and the share package is done within the hour
    $cut = (Get-Date).AddHours(-1)
    foreach ($e in @(Get-ChildItem -LiteralPath (Join-Path (Get-CpPaths).root 'tmp') -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })) {
        $u = if ($e.PSIsContainer) { (Get-DirUse $e.FullName).bytes } else { $e.Length }
        try { Remove-Item -LiteralPath $e.FullName -Recurse -Force; $b += $u } catch { }
    }
    $mb = [Math]::Round($b / 1MB)
    Write-Note "Disk cleanup: deleted $n download(s), $mb MB freed"
    "Deleted $n download$(if ($n -ne 1) { 's' }), $mb MB freed"
}
#endregion

Export-ModuleMember -Function *
