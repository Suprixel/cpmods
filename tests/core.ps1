# Backend self-check in a throwaway copy of the app pointed at a fake game folder (never the real one).
# Run from the app folder: pwsh -NoProfile -File tests\core.ps1   Touches nothing outside a temp folder.
$ErrorActionPreference = 'Stop'
$Sb = Join-Path ([IO.Path]::GetTempPath()) "cpmods-core-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$g = Join-Path $Sb 'game'
$script:fails = 0; $script:passes = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:passes++ } else { $script:fails++; Write-Host "FAIL: $Msg" -ForegroundColor Red } }
try {
    New-Item -ItemType Directory -Force "$Sb\lib", "$g\bin\x64", "$g\r6\config", "$g\archive\pc\content", "$g\engine\config\base", "$Sb\src" | Out-Null
    Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'lib\*.psm1') "$Sb\lib"
    @{ gamePath = $g; nexusGame = 'cyberpunk2077'; steamManifest = '' } | ConvertTo-Json | Set-Content "$Sb\config.json"
    '[]' | Set-Content "$Sb\frameworks.json"
    'exe' | Set-Content "$g\bin\x64\Cyberpunk2077.exe"
    'VANILLA' | Set-Content "$g\r6\config\inputUserMappings.xml" -NoNewline
    'CETLOADER' | Set-Content "$g\bin\x64\version.dll"; 'R4LOADER' | Set-Content "$g\bin\x64\winmm.dll"
    "[Scripts]`nEnableCompilation = `"true`"" | Set-Content "$g\engine\config\base\scripts.ini"

    function New-TestMod([string]$Name, [hashtable]$Files) {
        $d = Join-Path $Sb "src\$Name"
        foreach ($k in $Files.Keys) { $p = Join-Path $d $k; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Set-Content -LiteralPath $p -Value $Files[$k] -NoNewline }
        $z = Join-Path $Sb "src\$Name.zip"
        Compress-Archive -Path "$d\*" -DestinationPath $z -Force
        $z
    }
    $zA = New-TestMod 'ModA' @{ 'r6\config\inputUserMappings.xml' = 'A'; 'archive\pc\mod\aaa.archive' = 'A-arch'; 'r6\scripts\ModA\a.reds' = 'module ModA' }
    $zB = New-TestMod 'ModB' @{ 'r6\config\inputUserMappings.xml' = 'B'; 'archive\pc\mod\bbb.archive' = 'B-arch' }
    $zD = New-TestMod 'ModD' @{ 'archive\pc\mod\zzz.archive' = 'D' }
    $zE = New-TestMod 'ModE' @{ 'archive\pc\mod\mmm.archive' = 'E' }
    $zF = New-TestMod 'ModF' @{ 'bin\x64\plugins\cyber_engine_tweaks\mods\ModF\init.lua' = 'lua'; 'bin\x64\plugins\cyber_engine_tweaks\mods\ModF\config.json' = '{"v":1}' }
    $zG = New-TestMod 'ModG' @{ 'init.lua' = 'lua'; 'settings.json' = '{}' }

    Import-Module "$Sb\lib\cpmods.psm1", "$Sb\lib\cpinsight.psm1", "$Sb\lib\cpsafety.psm1" -Force -DisableNameChecking
    Set-CpContext 'sandbox' $true
    if ((Get-CpPaths).game -ne $g) { throw "sandbox not isolated: $((Get-CpPaths).game)" }

    $cont = { param($rel) $p = Join-Path $g $rel; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } else { '<missing>' } }
    $mod = { param($n) (Get-State).mods | Where-Object { $_.name -eq $n } | Select-Object -First 1 }
    $meta = { param($n) [ordered]@{ name = $n; version = '1'; source = 'manual' } }
    $cfgRel = 'r6\config\inputUserMappings.xml'

    Write-Host '--- T1-T5: ask, keep, removal hands the file to the waiting mod, vanilla comes back last'
    Install-ModArchive $zA (& $meta 'ModA') | Out-Null
    Check ((& $cont $cfgRel) -eq 'A') 'T1 A installed its copy'
    Check (@((& $mod 'ModA').backups) -contains $cfgRel) 'T1 A kept the vanilla backup'
    Start-Sleep -Milliseconds 1100
    $r = Install-ModArchive $zB (& $meta 'ModB') -Ask
    Check ([bool]$r.conflict -and $r.conflict[0].path -eq $cfgRel -and $r.conflict[0].owners -contains 'ModA') 'T2 ask returns the conflict'
    Check (-not (& $mod 'ModB')) 'T2 nothing installed while asking'
    Install-ModArchive $zB (& $meta 'ModB') -OnConflict keep | Out-Null
    Check ((& $cont $cfgRel) -eq 'A') 'T3 keep left the copy of A'
    Check (@((& $mod 'ModB').keepOthers) -contains $cfgRel -and @((& $mod 'ModB').files) -notcontains $cfgRel) 'T3 B records the kept file'
    Check ((& $cont 'archive\pc\mod\bbb.archive') -eq 'B-arch') 'T3 B installed its other files'
    Remove-InstalledMod 'ModA'
    Check ((& $cont $cfgRel) -eq 'B') 'T4 removing A puts in the copy of B'
    Check (@((& $mod 'ModB').files) -contains $cfgRel -and -not @((& $mod 'ModB').keepOthers).Count) 'T4 B owns it now'
    Check (@((& $mod 'ModB').backups) -contains $cfgRel) 'T4 vanilla backup moved to B'
    Remove-InstalledMod 'ModB'
    Check ((& $cont $cfgRel) -eq 'VANILLA') 'T5 vanilla restored at the end'

    Write-Host '--- T6: overwrite keeps the replaced copy; removing the top mod puts it back without the archive'
    Install-ModArchive $zA (& $meta 'ModA') | Out-Null; Start-Sleep -Milliseconds 1100
    Install-ModArchive $zB (& $meta 'ModB') -OnConflict overwrite | Out-Null
    Check ((& $cont $cfgRel) -eq 'B') 'T6 B on top'
    Check (@((& $mod 'ModB').under | Where-Object { $_.path -eq $cfgRel -and $_.owner -eq 'ModA' }).Count -eq 1) 'T6 under copy recorded'
    Rename-Item $zA "$zA.hidden"   # proves the copy comes from the saved one, not the download
    Remove-InstalledMod 'ModB'
    Rename-Item "$zA.hidden" $zA
    Check ((& $cont $cfgRel) -eq 'A') 'T6 copy of A back without its download'
    Remove-InstalledMod 'ModA'
    Check ((& $cont $cfgRel) -eq 'VANILLA') 'T6 vanilla at the end'

    Write-Host '--- T7: removing the mod underneath keeps the top copy and passes the vanilla backup up'
    Install-ModArchive $zA (& $meta 'ModA') | Out-Null; Start-Sleep -Milliseconds 1100
    Install-ModArchive $zB (& $meta 'ModB') | Out-Null
    Remove-InstalledMod 'ModA'
    Check ((& $cont $cfgRel) -eq 'B') 'T7 copy of B stays'
    Check (@((& $mod 'ModB').backups) -contains $cfgRel) 'T7 vanilla backup moved to B'
    Remove-InstalledMod 'ModB'
    Check ((& $cont $cfgRel) -eq 'VANILLA') 'T7 vanilla at the end'

    Write-Host '--- T8: load order rename survives an update and can be undone'
    Install-ModArchive $zD (& $meta 'ModD') | Out-Null
    Install-ModArchive $zE (& $meta 'ModE') | Out-Null
    $n = Set-ArchiveWinner 'zzz.archive' 'mmm.archive'
    Check ($n -eq '!zzz.archive' -and (Test-Path "$g\archive\pc\mod\!zzz.archive") -and -not (Test-Path "$g\archive\pc\mod\zzz.archive")) 'T8 renamed with !'
    Check (@((& $mod 'ModD').files) -contains 'archive\pc\mod\!zzz.archive') 'T8 tracked under the new name'
    Install-ModArchive $zD ([ordered]@{ name = 'ModD'; version = '2'; source = 'manual' }) | Out-Null
    Check ((Test-Path "$g\archive\pc\mod\!zzz.archive") -and -not (Test-Path "$g\archive\pc\mod\zzz.archive")) 'T8 update keeps the new name'
    $n2 = Set-ArchiveWinner '!zzz.archive' '!!!x.archive'
    Check ($n2 -eq '!!!!zzz.archive') 'T8 more ! when the loser starts with !'
    [void](Reset-ArchiveName '!!!!zzz.archive')
    Check ((Test-Path "$g\archive\pc\mod\zzz.archive") -and @((& $mod 'ModD').files) -contains 'archive\pc\mod\zzz.archive' -and -not (Get-LoadOrderRules).Count) 'T8 undo restores the name'

    Write-Host '--- T9: restore points'
    $p = Save-RestorePoint 'manual' 'test'
    Disable-InstalledMod 'ModD'
    Install-ModArchive $zA (& $meta 'ModA') | Out-Null
    $plan = Get-RestorePlan $p.id
    Check ($plan.off -contains 'ModA' -and $plan.on -contains 'ModD' -and $plan.same -eq 1) "T9 plan off/on/same: $($plan | ConvertTo-Json -Compress -Depth 4)"
    [void](Invoke-RestorePoint $p.id)
    $st = Get-State
    Check (-not ($st.mods | Where-Object name -eq 'ModA') -and ($st.disabled | Where-Object name -eq 'ModA') -and ($st.mods | Where-Object name -eq 'ModD')) 'T9 back to the point (A off, D on)'
    Check (@(Get-RestorePoints | Where-Object { $_.label -like 'Before going back*' }).Count -eq 1) 'T9 point made before going back'
    $plan2 = Get-RestorePlan $p.id
    Check (-not $plan2.off.Count -and -not $plan2.on.Count -and -not $plan2.install.Count -and -not $plan2.version.Count) 'T9 nothing left to change'

    Write-Host '--- T10: save backups and exact restore'
    $sv = Join-Path $Sb 'saves'
    foreach ($i in 1..3) { New-Item -ItemType Directory -Force "$sv\ManualSave-$i" | Out-Null; "save$i" | Set-Content "$sv\ManualSave-$i\sav.dat" -NoNewline; 'meta' | Set-Content "$sv\ManualSave-$i\metadata.9.json" }
    [void](Save-CpSettings @{ saveKeep = 1 })
    $b1 = Backup-Saves 'test' $sv
    Check ($b1 -and @($b1.saves).Count -eq 3) 'T10 copied 3 saves'
    'changed' | Set-Content "$sv\ManualSave-2\sav.dat" -NoNewline; 'junk' | Set-Content "$sv\ManualSave-2\extra.tmp"
    [void](Restore-Saves $b1.id @('ManualSave-2') $sv)
    Check ((Get-Content "$sv\ManualSave-2\sav.dat" -Raw) -eq 'save2' -and -not (Test-Path "$sv\ManualSave-2\extra.tmp")) 'T10 exact copy back'
    $all = @(Get-SaveBackups)
    Check (@($all | Where-Object { $_.reason -like 'Before restoring*' }).Count -eq 1 -and @($all | Where-Object { $_.id -eq $b1.id }).Count -eq 1) 'T10 current copy saved first, source kept despite keep=1'
    $pre = $all | Where-Object { $_.reason -like 'Before restoring*' }
    Check ((Get-Content (Join-Path (Get-SavesBackupDir) "$($pre.id)\ManualSave-2\sav.dat") -Raw) -eq 'changed') 'T10 the replaced save is in the before copy'
    Check (-not (Test-SaveBackupDue)) 'T10 setup unchanged since the full copy: no new copy due'
    Disable-InstalledMod 'ModE'
    [void](Restore-Saves $b1.id @('ManualSave-2') $sv)
    Check (Test-SaveBackupDue) 'T10 mods changed, then a save restored: the full copy is still due'
    Enable-InstalledMod 'ModE'

    Write-Host '--- T11: mod settings backups'
    Install-ModArchive $zF (& $meta 'ModF') | Out-Null
    $cet = "$g\bin\x64\plugins\cyber_engine_tweaks\mods\ModF"
    '{"user":1}' | Set-Content "$cet\settings.json" -NoNewline
    Start-Sleep -Milliseconds 200
    (Get-Item "$cet\config.json").LastWriteTime = (Get-Date).AddMinutes(5); '{"v":2}' | Set-Content "$cet\config.json" -NoNewline; (Get-Item "$cet\config.json").LastWriteTime = (Get-Date).AddMinutes(5)
    $files = @(Get-ModSettingsFiles)
    Check (@($files | Where-Object { $_.path -like '*ModF\settings.json' -and -not $_.tracked }).Count -eq 1) 'T11 untracked settings found'
    Check (@($files | Where-Object { $_.path -like '*ModF\config.json' -and $_.tracked }).Count -eq 1) 'T11 edited config found'
    Check (-not @($files | Where-Object { $_.path -like '*init.lua' }).Count) 'T11 untouched mod files skipped'
    $bk = Backup-ModSettings 'manual' 'test'
    '{"user":99}' | Set-Content "$cet\settings.json" -NoNewline
    $pv = Restore-ModSettings $bk.id -Preview
    Check (@($pv.write).Count -eq 2 -and -not @($pv.skip).Count) "T11 preview writes 2: $($pv | ConvertTo-Json -Compress -Depth 4)"
    [void](Restore-ModSettings $bk.id)
    Check ((Get-Content "$cet\settings.json" -Raw) -eq '{"user":1}') 'T11 settings restored'
    Install-ModArchive $zF ([ordered]@{ name = 'ModF'; version = '2'; source = 'manual' }) | Out-Null
    $pv2 = Restore-ModSettings $bk.id -Preview
    Check (@($pv2.skip | Where-Object { $_.path -like '*config.json' -and $_.why -like '*changed from 1 to 2*' }).Count -eq 1) 'T11 edited config of an updated mod is skipped'
    $zip = Join-Path (Get-SettingsBackupDir) "$($bk.id).zip"
    $imp = Import-ModSettings ([Convert]::ToBase64String([IO.File]::ReadAllBytes($zip)))
    Check ((@(Get-SettingsBackups) | Where-Object id -eq $imp.id).kind -eq 'imported') 'T11 import marked as imported'
    Check (-not (Test-SettingsPath '..\x.json') -and -not (Test-SettingsPath 'C:\x.json') -and -not (Test-SettingsPath 'bin\x64\evil.dll') -and (Test-SettingsPath 'red4ext\plugins\a\b.ini')) 'T11 path guard'
    Check (-not (Test-SettingsPath 'red4ext\plugins\ArchiveXL\ArchiveXL.dll') -and -not (Test-SettingsPath 'bin\x64\plugins\cyber_engine_tweaks\x.asi')) 'T11 programs are never settings'

    Write-Host '--- T12: launch without mods (park and bring back)'
    New-Item -ItemType Directory -Force "$g\red4ext\plugins\X", "$g\bin\x64\plugins" | Out-Null
    'dll' | Set-Content "$g\red4ext\plugins\X\x.dll"; 'asi' | Set-Content "$g\bin\x64\plugins\cet.asi"
    Install-ModArchive $zB (& $meta 'ModB') -OnConflict overwrite | Out-Null   # base file replaced by B (vanilla backup with B)
    Check ((& $cont $cfgRel) -eq 'B') 'T12 setup B on base file'
    [void](Start-VanillaSession)
    Check (-not (Test-Path "$g\archive\pc\mod") -and -not (Test-Path "$g\red4ext") -and -not (Test-Path "$g\bin\x64\plugins") -and -not (Test-Path "$g\bin\x64\version.dll") -and -not (Test-Path "$g\engine\config\base\scripts.ini")) 'T12 mod folders and loaders set aside'
    Check ((& $cont $cfgRel) -eq 'VANILLA') 'T12 original base file in place'
    $threw = $false; try { Install-ModArchive $zE (& $meta 'ModE') | Out-Null } catch { $threw = $_.Exception.Message -like '*set aside*' }
    Check $threw 'T12 installs blocked while mods are set aside'
    [void](Restore-VanillaSession)
    Check ((Test-Path "$g\archive\pc\mod\bbb.archive") -and (Test-Path "$g\red4ext\plugins\X\x.dll") -and (Test-Path "$g\bin\x64\plugins\cet.asi") -and (Test-Path "$g\bin\x64\version.dll") -and (Test-Path "$g\engine\config\base\scripts.ini")) 'T12 everything back'
    Check ((& $cont $cfgRel) -eq 'B') 'T12 mod copy of the base file back'
    Check (-not (Test-Path "$g\_cpmods_vanilla") -and -not (Get-VanillaState)) 'T12 park folder and journal gone'

    Write-Host '--- T13: a failed park puts everything back'
    $lock = [IO.File]::Open("$g\red4ext\plugins\X\x.dll", 'Open', 'Read', 'None')
    try { $err = $null; try { [void](Start-VanillaSession) } catch { $err = $_.Exception.Message } } finally { $lock.Dispose() }
    Check ($err -like '*put back*') "T13 error says it was put back: $err"
    Check ((Test-Path "$g\archive\pc\mod\bbb.archive") -and (Test-Path "$g\bin\x64\version.dll") -and -not (Get-VanillaState)) 'T13 nothing left set aside'

    Write-Host '--- T14: a CET mod zipped without a folder: named after the mod, preview and install agree'
    Copy-Item $zG (Get-CpPaths).downloads
    $prev = @((Get-DownloadPreview 'ModG.zip' '' 'Night Mode').files | ForEach-Object { $_.path } | Sort-Object)
    Install-ModArchive $zG (& $meta 'Night Mode') | Out-Null
    $inst = @((& $mod 'Night Mode').files | Sort-Object)
    Check ($inst -contains 'bin\x64\plugins\cyber_engine_tweaks\mods\Night Mode\init.lua') "T14 installed in mods\Night Mode: $($inst -join ', ')"
    Check (($prev -join '|') -eq ($inst -join '|')) "T14 preview matches the install: $($prev -join ', ')"
    Install-ModArchive $zG ([ordered]@{ name = 'Night Mode'; version = '2'; source = 'manual' }) | Out-Null
    Check ((@((& $mod 'Night Mode').files | Sort-Object) -join '|') -eq ($inst -join '|')) 'T14 an update keeps the same folder'

    Write-Host '--- T15: a base game file whose saved original is gone is kept, never deleted'
    Remove-Item (Join-Path (Get-CpPaths).root "backup\ModB\$cfgRel") -Force
    Remove-InstalledMod 'ModB'
    Check ((& $cont $cfgRel) -eq 'B') 'T15 the file stays (the copy of B) instead of being deleted'

    Write-Host '--- T16: the window C# (title bar, taskbar ID) compiles; a typo would silently drop both'
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot) 'lib\cpwindow.ps1'), [ref]$null, [ref]$null)
    Add-Type -TypeDefinition $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$frameSrc' }, $true).Right.Expression.Value
    Check (('CpFrame' -as [type]) -and ('CpAppId' -as [type])) 'T16 CpFrame and CpAppId compile'

    Write-Host '--- T17: troubleshooting finds the mod behind a problem and turns the others back on'
    $ks = foreach ($k in 'K1', 'K2', 'K3', 'K4') { Install-ModArchive (New-TestMod $k @{ "archive\pc\mod\$k.archive" = $k }) (& $meta $k) | Out-Null; $k }
    [void](Start-Bisect -Names $ks)
    # each "launch" has the problem only while K3 is on
    for ($i = 0; $i -lt 6 -and (Get-BisectState).phase -ne 'done'; $i++) { [void](Submit-BisectResult -Ok (-not ((Get-State).mods | Where-Object name -eq 'K3'))) }
    $b = Get-BisectState; $on = @((Get-State).mods | ForEach-Object { $_.name })
    Check ($b.outcome -eq 'found' -and $b.culprit -eq 'K3') "T17 found K3: $($b.outcome) $($b.culprit)"
    Check ($on -contains 'K1' -and $on -contains 'K2' -and $on -contains 'K4' -and $on -notcontains 'K3') "T17 the others are on, K3 off: $($on -join ', ')"
    [void](Stop-Bisect -KeepCulprit $true)
    Check (-not (Get-BisectState) -and ((Get-State).disabled | Where-Object name -eq 'K3')) 'T17 finished, K3 stays off'

    Write-Host '--- T18: turning a mod back on asks when another mod has its files now'
    $shared = 'r6\config\shared.xml'
    Install-ModArchive (New-TestMod 'ModP' @{ $shared = 'P' }) (& $meta 'ModP') | Out-Null
    Disable-InstalledMod 'ModP'
    Install-ModArchive (New-TestMod 'ModQ' @{ $shared = 'Q' }) (& $meta 'ModQ') | Out-Null
    $r = Enable-InstalledMod 'ModP' -Ask
    Check ($r.conflict -and (& $cont $shared) -eq 'Q' -and ((Get-State).disabled | Where-Object name -eq 'ModP')) 'T18 asks and changes nothing'
    Check ($null -eq (Enable-InstalledMod 'ModP') -and (& $cont $shared) -eq 'P') 'T18 without -Ask it turns on as before (troubleshooting, restore points)'

    Write-Host '--- T19: a CET mod log: lines of an earlier session stay out, the real error shows (not "stack traceback:")'
    $cetDir = "$g\bin\x64\plugins\cyber_engine_tweaks"
    New-Item -ItemType Directory -Force "$cetDir\mods\ModX" | Out-Null
    $now = Get-Date; $ts = { param($d) $d.ToString('yyyy-MM-dd HH:mm:ss') }
    "[$(& $ts $now)] CET version v1.0.0" | Set-Content "$cetDir\cyber_engine_tweaks.log"
    @("[$(& $ts $now.AddDays(-1))] [1] init.lua:5: attempt to index a nil value", 'stack traceback:', "`tinit.lua:5: in function <init.lua:1>",
        "[$(& $ts $now)] [1] init.lua:87: attempt to index field 'x' (a nil value)", 'stack traceback:', "`tinit.lua:87: in function <init.lua:78>") | Set-Content "$cetDir\mods\ModX\ModX.log"
    $ce = @((Read-CetSession $now.AddMinutes(-1) $now.AddMinutes(5)).errors)
    Check ($ce.Count -eq 1 -and $ce[0].text -eq "init.lua:87: attempt to index field 'x' (a nil value)" -and $ce[0].log -like '*mods\ModX\ModX.log') "T19 only this session's error: $(($ce | ForEach-Object { $_.text }) -join ' | ')"

    Write-Host '--- T20: problem links: the mod a named file comes from, and mods replacing the same script function'
    $rf = "@replaceMethod(FooController)`nprotected cb func OnBar() -> Bool {`n  return true;`n}"
    Install-ModArchive (New-TestMod 'ModR1' @{ 'r6\scripts\R1\a.reds' = $rf }) (& $meta 'ModR1') | Out-Null
    Install-ModArchive (New-TestMod 'ModR2' @{ 'r6\scripts\R2\b.reds' = $rf; 'r6\scripts\R2\c.reds' = "@replaceMethod(FooController)`nfunc OnOther() {}" }) (& $meta 'ModR2') | Out-Null
    $maps = Get-OwnerMaps (Get-State)
    $rv = @(Get-ReplaceRivals 'r6\scripts\R2\b.reds' 1 'ModR2' $maps @{})
    Check ($rv.Count -eq 1 -and $rv[0].mod -eq 'ModR1' -and $rv[0].why -like '*FooController.OnBar*') "T20 the other replacement of FooController.OnBar: $(($rv | ForEach-Object { $_.mod }) -join ', ')"
    $fl = @(Get-FileLinks "input_loader: 'r6/scripts/R1/a.reds' is not a known file" 'Input Loader' $maps)
    Check ($fl.Count -eq 1 -and $fl[0].mod -eq 'ModR1') 'T20 a file named in a message points to its mod'

    Write-Host '--- T21: freeing disk space deletes only downloads no mod or restore point uses (and old leftovers)'
    $dl = (Get-CpPaths).downloads; $old = (Get-Date).AddHours(-2)
    $zPt = New-TestMod 'PtMod' @{ 'archive\pc\mod\pt.archive' = 'pt' }
    Copy-Item $zPt "$dl\pt.zip"; Copy-Item $zPt "$dl\pt2.zip"; Copy-Item $zPt "$dl\spare.zip"; Copy-Item $zPt "$dl\fresh.zip"
    Install-ModArchive "$dl\pt.zip" (& $meta 'PtMod') | Out-Null
    [void](Save-RestorePoint 'manual' 'T21')
    Install-ModArchive "$dl\pt2.zip" ([ordered]@{ name = 'PtMod'; version = '2'; source = 'manual' }) | Out-Null
    foreach ($f in 'pt.zip', 'spare.zip') { (Get-Item "$dl\$f").LastWriteTime = $old }
    New-Item -ItemType Directory -Force "$Sb\tmp\stale", "$Sb\tmp\recent" | Out-Null; 'x' | Set-Content "$Sb\tmp\stale\f.txt"; (Get-Item "$Sb\tmp\stale").LastWriteTime = $old
    Check ((@(Get-SpareDownloads | ForEach-Object file) -join ',') -eq 'spare.zip' -and (@(Get-SpareDownloads -Old | ForEach-Object file | Sort-Object) -join ',') -eq 'pt.zip,spare.zip') 'T21 spare: unused and old; -Old adds the version only a restore point uses'
    $si = Get-StorageInfo
    Check ($si.mods.count -eq @((Get-State).mods).Count -and $si.spare.free.Count -eq 1 -and $si.spare.old.Count -eq 1 -and $si.data.downloads.files -ge 4) 'T21 storage summary'
    [void](Invoke-StorageCleanup $false)
    Check (-not (Test-Path "$dl\spare.zip") -and (Test-Path "$dl\pt.zip") -and (Test-Path "$dl\pt2.zip") -and (Test-Path "$dl\fresh.zip")) 'T21 only the unused old download is deleted'
    Check (-not (Test-Path "$Sb\tmp\stale") -and (Test-Path "$Sb\tmp\recent")) 'T21 old leftovers in tmp go, recent ones stay'

    Write-Host '--- T22: turning a mod on through the app (job script): a conflict waits for a choice; removing the mod drops it'
    Import-Module "$Sb\lib\cpserver.psm1" -Force -DisableNameChecking
    $jobScripts = & (Get-Module cpserver) { $script:JobScripts }
    $runJob = { param($k, $P) & ([scriptblock]::Create($jobScripts[$k])) ([hashtable]::Synchronized(@{})) $P @{ cache = @{} } }
    Disable-InstalledMod 'ModP'
    $out = & $runJob 'enable' @{ name = 'ModP' }; $st = Get-State
    $pend = $st.pending | Where-Object { $_.meta.name -eq 'ModP' } | Select-Object -First 1
    Check ("$out" -like '*waiting for your choice*' -and ($st.disabled | Where-Object name -eq 'ModP') -and $pend -and (& $cont $shared) -eq 'Q') 'T22 the enable job parks the conflict and changes nothing'
    Install-ModArchive $pend.archive (Get-DeferredMeta $pend.archive) -OnConflict overwrite | Out-Null; $st = Get-State
    Check (($st.mods | Where-Object name -eq 'ModP') -and -not ($st.disabled | Where-Object name -eq 'ModP') -and -not ($st.pending | Where-Object { $_.meta.name -eq 'ModP' }) -and (& $cont $shared) -eq 'P') 'T22 choosing turns it on and clears both lists'
    Disable-InstalledMod 'ModP'; [void](& $runJob 'enable' @{ name = 'ModP' })
    Remove-InstalledMod 'ModP'
    Check (-not ((Get-State).pending | Where-Object { $_.meta.name -eq 'ModP' })) 'T22 removing the turned-off mod drops its waiting choice'

    Write-Host '--- T23: after updates a mod keeps its two previous downloads; older ones are deleted (setting)'
    $zV = New-TestMod 'VerMod' @{ 'archive\pc\mod\ver.archive' = 'v' }
    foreach ($i in 1..5) { Copy-Item $zV "$dl\ver$i.zip" }
    foreach ($i in 1..4) { Install-ModArchive "$dl\ver$i.zip" ([ordered]@{ name = 'VerMod'; version = "$i"; source = 'manual' }) | Out-Null }
    $older = { (@(((Get-State).mods | Where-Object name -eq 'VerMod').older) | ForEach-Object { Split-Path $_ -Leaf }) -join ',' }
    Check ((& $older) -eq 'ver3.zip,ver2.zip' -and -not (Test-Path "$dl\ver1.zip") -and (Test-Path "$dl\ver2.zip") -and (Test-Path "$dl\ver3.zip")) "T23 the two previous versions stay, the oldest is deleted: $(& $older)"
    Disable-InstalledMod 'VerMod'; Enable-InstalledMod 'VerMod'
    Check ((& $older) -eq 'ver3.zip,ver2.zip') 'T23 turning it off and on keeps that list'
    [void](Save-CpSettings @{ pruneOld = $false })
    Install-ModArchive "$dl\ver5.zip" ([ordered]@{ name = 'VerMod'; version = '5'; source = 'manual' }) | Out-Null
    Check ((Test-Path "$dl\ver2.zip") -and (& $older) -eq 'ver4.zip,ver3.zip') 'T23 with the setting off nothing is deleted'
    [void](Save-CpSettings @{ pruneOld = $true })

    Write-Host '--- T24: profiles: save the mods on now, switch both ways, a removed mod comes back from its download'
    [void](Save-Profile 'All')
    Check ((Get-ProfileInUse (Get-State)) -eq 'All') 'T24 a saved profile is in use'
    Disable-InstalledMod 'ModR1'
    Check (-not (Get-ProfileInUse (Get-State))) 'T24 after a change no profile is in use'
    [void](Save-Profile 'NoR1')
    $sum = @(Get-ProfileSummaries)
    Check (@(($sum | Where-Object name -eq 'All').on) -contains 'ModR1' -and ($sum | Where-Object name -eq 'NoR1').inUse) 'T24 summaries: All would turn ModR1 on, NoR1 is in use'
    Remove-InstalledMod 'ModR2'
    [void](Invoke-Profile 'All')
    $st = Get-State
    Check ((Get-ProfileInUse $st) -eq 'All' -and ($st.mods | Where-Object name -eq 'ModR1') -and ($st.mods | Where-Object name -eq 'ModR2')) 'T24 switching to All turns ModR1 on and reinstalls ModR2'
    [void](Invoke-Profile 'NoR1')
    Check ((Get-ProfileInUse (Get-State)) -eq 'NoR1' -and ((Get-State).disabled | Where-Object name -eq 'ModR1')) 'T24 switching back turns ModR1 off'
    Remove-Profile 'NoR1'
    Check ((@(Get-Profiles | ForEach-Object name) -join ',') -eq 'All') 'T24 a profile can be deleted'

    Write-Host '--- T25: Nexus details: one failed request loses only its 40 mods'
    $orig = & (Get-Module cpmods) { ${function:Invoke-NexusGql} }
    & (Get-Module cpmods) { function script:Invoke-NexusGql([string]$Query) { if ($Query -match 'modId: 1\b') { throw 'Nexus down' }; @{ legacyModsByDomain = @{ nodes = @([regex]::Matches($Query, 'modId: (\d+)') | ForEach-Object { @{ modId = [int]$_.Groups[1].Value; name = "m$($_.Groups[1].Value)" } }) } } } }
    try {
        $info = Get-NexusModInfo (1..80)
        Check ($info.Count -eq 40 -and $info[41].name -eq 'm41') "T25 the other request still comes back ($($info.Count))"
        $threw = try { [void](Get-NexusModInfo 1); $false } catch { $true }
        Check $threw 'T25 nothing came back at all: the error is passed on'
    }
    finally { & (Get-Module cpmods) { param($f) Set-Item function:script:Invoke-NexusGql $f } $orig }

    Write-Host '--- T26: the known-good restore point waits while a job runs'
    $sh = [hashtable]::Synchronized(@{ cache = [hashtable]::Synchronized(@{}); jobs = [hashtable]::Synchronized(@{ j1 = [hashtable]::Synchronized(@{ id = 'j1'; status = 'running' }) }); cleanDue = @{ result = 'clean'; start = (Get-Date).AddHours(-1).ToString('s'); end = (Get-Date).AddMinutes(-30).ToString('s') } })
    [void](Get-UiState $sh)
    Check ([bool]$sh.cleanDue) 'T26 kept for later while a job runs'
    $sh.jobs.j1.status = 'done'
    [void](Get-UiState $sh)
    Check (-not $sh.cleanDue) 'T26 handled once no job runs'
}
catch { $script:fails++; Write-Host "FAIL (stopped): $($_.Exception.Message)" -ForegroundColor Red }
finally {
    Remove-Module cpserver, cpsafety, cpinsight, cpmods -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Sb -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:fails) -ForegroundColor $(if ($script:fails) { 'Red' } else { 'Green' })
}
exit [int][bool]$script:fails
