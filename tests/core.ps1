# Backend self-check in a throwaway copy of the app pointed at a fake game folder (never the real one).
# Run from the app folder: pwsh -NoProfile -File tests\core.ps1   Touches nothing outside a temp folder.
$ErrorActionPreference = 'Stop'
$Sb = Join-Path ([IO.Path]::GetTempPath()) "cpmods-core-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$g = Join-Path $Sb 'game'
$env:CPMODS_CONFIG = Join-Path $Sb 'config'; $env:CPMODS_SAVES = Join-Path $Sb 'savedgames'
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
    'dll' | Set-Content "$g\red4ext\plugins\X\x.dll"; 'asi' | Set-Content "$g\bin\x64\plugins\cet.asi"; 'reshade' | Set-Content "$g\bin\x64\dxgi.dll"
    Install-ModArchive $zB (& $meta 'ModB') -OnConflict overwrite | Out-Null   # base file replaced by B (vanilla backup with B)
    Check ((& $cont $cfgRel) -eq 'B') 'T12 setup B on base file'
    New-Item -ItemType Directory -Force $env:CPMODS_CONFIG | Out-Null; 'MINE' | Set-Content "$env:CPMODS_CONFIG\UserSettings.json"
    [void](Start-VanillaSession)
    'RESET BY THE GAME' | Set-Content "$env:CPMODS_CONFIG\UserSettings.json"
    Check (-not (Test-Path "$g\archive\pc\mod") -and -not (Test-Path "$g\red4ext") -and -not (Test-Path "$g\bin\x64\plugins") -and -not (Test-Path "$g\bin\x64\version.dll") -and -not (Test-Path "$g\engine\config\base\scripts.ini") -and -not (Test-Path "$g\bin\x64\dxgi.dll")) 'T12 mod folders, loaders and DLL injectors (ReShade) set aside'
    Check ((& $cont $cfgRel) -eq 'VANILLA') 'T12 original base file in place'
    $threw = $false; try { Install-ModArchive $zE (& $meta 'ModE') | Out-Null } catch { $threw = $_.Exception.Message -like '*set aside*' }
    Check $threw 'T12 installs blocked while mods are set aside'
    [void](Restore-VanillaSession)
    Check ((Test-Path "$g\archive\pc\mod\bbb.archive") -and (Test-Path "$g\red4ext\plugins\X\x.dll") -and (Test-Path "$g\bin\x64\plugins\cet.asi") -and (Test-Path "$g\bin\x64\version.dll") -and (Test-Path "$g\engine\config\base\scripts.ini") -and (Test-Path "$g\bin\x64\dxgi.dll")) 'T12 everything back'
    Check ((& $cont $cfgRel) -eq 'B') 'T12 mod copy of the base file back'
    Check (-not (Test-Path "$g\_cpmods_vanilla") -and -not (Get-VanillaState)) 'T12 park folder and journal gone'
    Check ((Get-Content "$env:CPMODS_CONFIG\UserSettings.json" -Raw).Trim() -eq 'MINE' -and -not (Test-Path "$Sb\state\vanilla-usersettings.json")) 'T12 the game settings from before the launch are back'

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

    Write-Host '--- T27: a stalled download can be cancelled'
    $tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $port = $tl.LocalEndpoint.Port
    $sj = [hashtable]::Synchronized(@{ done = 0 })
    $srv = [powershell]::Create().AddScript({
            param($tl, $sj)
            $c = $tl.AcceptTcpClient(); $st = $c.GetStream(); [void]$st.Read([byte[]]::new(4096), 0, 4096)
            $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 1000`r`n`r`n0123456789"); $st.Write($b, 0, $b.Length); $st.Flush()
            Start-Sleep -Milliseconds 1500; $sj.cancel = $true; Start-Sleep -Seconds 20; $c.Dispose()
        }).AddArgument($tl).AddArgument($sj)
    $h = $srv.BeginInvoke()
    $out = Join-Path $Sb 'stall.bin'; $sw = [Diagnostics.Stopwatch]::StartNew()
    $err = try { Save-UrlToFile "http://127.0.0.1:$port/f" $out $sj; '' } catch { $_.Exception.Message }
    Check ($err -eq 'Cancelled' -and $sw.Elapsed.TotalSeconds -lt 10 -and $sj.done -eq 10 -and -not (Test-Path $out) -and -not (Test-Path "$out.part")) "T27 stops on Cancel and leaves no file ($err, $([int]$sw.Elapsed.TotalSeconds) s)"
    $srv.Stop(); $srv.Dispose(); $tl.Stop()

    Write-Host '--- T28: modpack code: short, safe to paste, refused when damaged; plan from Nexus data; update or keep; backups first'
    $nx = { param($n, $mid, $fid, $v, $z) Install-ModArchive $z ([ordered]@{ name = $n; version = $v; source = "nexus:$mid/$fid"; modId = $mid; fileId = $fid; fileName = "$n main" }) | Out-Null }
    & $nx 'PackSame' 9001 1 '1.0' (New-TestMod 'PackSame' @{ 'archive\pc\mod\psame.archive' = 's' })
    & $nx 'PackOld' 9002 20 '1.0' (New-TestMod 'PackOld' @{ 'archive\pc\mod\pold.archive' = 'o' })
    & $nx 'PackKeep' 9003 30 '1.0' (New-TestMod 'PackKeep' @{ 'archive\pc\mod\pkeep.archive' = 'k' })
    & $nx 'PackOff' 9004 40 '1.0' (New-TestMod 'PackOff' @{ 'archive\pc\mod\poff.archive' = 'f' })
    Disable-InstalledMod 'PackOff'
    $made = ConvertTo-PackCode 'Test pack'
    $back = Read-ModPack $made.code
    Check ($made.code -cmatch '^CPMODS[0-9A-Za-z]+$' -and $back.name -eq 'Test pack' -and $back.game -eq "$((Get-GameState).version)" -and (@($back.mods | ForEach-Object { "$($_.modId)/$($_.fileId)" }) -join ',') -eq '9001/1,9002/20,9003/30') "T28 code round trip: $($made.code)"
    $big = @(1..125 | ForEach-Object { [ordered]@{ modId = $_ * 299; fileId = 30000 + $_ * 1200; sub = $(if ($_ -eq 7) { 'Variant B\files' } else { $null }) } })
    $bc = (ConvertTo-PackCode 'Big' $big).code; $bb = Read-ModPack $bc
    Check ($bc.Length -lt 1000 -and @($bb.mods).Count -eq 125 -and $bb.mods[6].sub -eq 'Variant B\files' -and $bb.mods[124].fileId -eq 180000) "T28 125 mods fit in a chat message: $($bc.Length) characters"
    $sc = (ConvertTo-PackCode 'Big' $big -Short).code; $sb2 = Read-ModPack $sc
    Check ($sc.Length -lt 0.45 * $bc.Length -and @($sb2.mods).Count -eq 125 -and -not @($sb2.mods | Where-Object { $_.modId }).Count -and $sb2.mods[6].sub -eq 'Variant B\files' -and $sb2.mods[124].fileId -eq 180000) "T28 short code holds only file ids: $($sc.Length) characters (long: $($bc.Length))"
    Check (@((Read-ModPack "here is my pack: $($made.code) have fun").mods).Count -eq 3) 'T28 the code is found inside a pasted message'
    Check (@((Read-ModPack (($made.code -split '(.{20})' | Where-Object { $_ }) -join "`r`n")).mods).Count -eq 3) 'T28 a code wrapped over lines still reads'
    $typo = $made.code.ToCharArray(); $typo[12] = $(if ($typo[12] -ceq 'a') { 'b' } else { 'a' })
    foreach ($bad in @{ c = 'hello'; m = 'No modpack code*' }, @{ c = [string]::new($typo); m = '*damaged or cut short*' }, @{ c = $made.code.Substring(0, $made.code.Length - 5); m = '*damaged or cut short*' }) {
        $err = try { [void](Read-ModPack $bad.c); '' } catch { $_.Exception.Message }
        Check ($err -like $bad.m) "T28 refused ($($bad.m)): $err"
    }
    $hp = Read-ModPack '' @{ format = 'cpmods-modlist'; name = 'x' * 80; mods = @(
            @{ name = '..'; modId = 9100; fileId = 100; sub = '..\..\Windows' }, @{ name = 'Fine'; modId = 9101; fileId = 101; sub = 'C:\x' },
            @{ name = 'NoIds'; modId = 'abc'; fileId = 5 }, @{ name = 'Dup'; modId = 9101; fileId = 101 }, 'not an object') }
    Check (@($hp.mods).Count -eq 2 -and -not $hp.mods[0].sub -and -not $hp.mods[1].sub -and $hp.name.Length -eq 60) "T28 hostile list cleaned: $(ConvertTo-Json $hp -Compress -Depth 4)"
    Check ((Get-SafeName '..') -eq '_..' -and (Get-SafeName ' . ') -eq '_ . ' -and (Get-SafeName 'Mod 1.2') -eq 'Mod 1.2') 'T28 a name of dots never becomes a parent folder'
    $err = try { Install-ModArchive $zD ([ordered]@{ name = 'Escape'; version = '1'; source = 'manual'; sub = '..\..' }) | Out-Null; '' } catch { $_.Exception.Message }
    Check ($err -like 'Invalid folder*') "T28 install refuses a folder outside the archive: $err"

    # Nexus stand-in: mod name and files per mod id (a code holds only ids)
    $fake = @{
        9001 = 'PackSame', @(@{ fileId = 1; name = 'PackSame main'; version = '1.0'; category = 'MAIN' })
        9002 = 'PackOld', @(@{ fileId = 20; name = 'PackOld main'; version = '1.0'; category = 'OLD_VERSION' }, @{ fileId = 21; name = 'PackOld main'; version = '2.0'; category = 'MAIN' })
        9003 = 'Keep renamed', @(@{ fileId = 29; name = 'PackKeep main 0.9'; version = '0.9'; category = 'OLD_VERSION' }, @{ fileId = 30; name = 'PackKeep main'; version = '1.0'; category = 'MAIN' })
        9004 = 'PackOff', @(@{ fileId = 40; name = 'PackOff main'; version = '1.0'; category = 'MAIN' })
        9005 = 'Brand new', @(@{ fileId = 50; name = 'Brand new'; version = '3.1'; category = 'MAIN' })
        9006 = 'ModD', @(@{ fileId = 60; name = 'Other ModD'; version = '1.0'; category = 'MAIN' })
        9007 = 'Was removed', @(@{ fileId = 70; name = 'x'; version = '1'; category = 'REMOVED' })
        9008 = 'Twin', @(@{ fileId = 80; name = 'Twin A'; version = '1'; category = 'MAIN' }, @{ fileId = 81; name = 'Twin B'; version = '1'; category = 'OPTIONAL' })
        9010 = 'Lut', @(@{ fileId = 100; name = 'Lut main'; version = '1.0'; category = 'MAIN' }, @{ fileId = 101; name = 'Lut Neutral'; version = '1.0'; category = 'OPTIONAL' })
        9011 = 'Same Name', @(@{ fileId = 110; name = 'Main'; version = '1'; category = 'MAIN' })
        9012 = 'Same Name', @(@{ fileId = 120; name = 'Main'; version = '1'; category = 'MAIN' })
    }
    $origGql = & (Get-Module cpmods) { ${function:Invoke-NexusGql} }
    & (Get-Module cpmods) {
        param($f) $script:FakeNx = $f
        function script:Invoke-NexusGql([string]$Query) {
            $d = @{ legacyModsByDomain = @{ nodes = @(foreach ($m in [regex]::Matches($Query, 'modId: (\d+)\}')) { $x = $script:FakeNx[[int]$m.Groups[1].Value]; if ($x) { @{ modId = [int]$m.Groups[1].Value; name = $x[0] } } }) } }
            foreach ($m in [regex]::Matches($Query, 'm(\d+): modFiles')) { $x = $script:FakeNx[[int]$m.Groups[1].Value]; $d["m$($m.Groups[1].Value)"] = $(if ($x) { $x[1] } else { @() }) }
            # file uid = game id << 32 | file id
            $d.modFilesByUid = @{ nodes = @(foreach ($m in [regex]::Matches($Query, '"(\d+)"')) {
                        $fid = [long]$m.Groups[1].Value - ([long]3333 -shl 32)
                        foreach ($k in $script:FakeNx.Keys) { if (@($script:FakeNx[$k][1] | Where-Object { $_.fileId -eq $fid }).Count) { @{ fileId = $fid; modId = $k } } }
                    }) }
            $d
        }
    } $fake
    try {
        $fl = @(@{ modId = 9001; fileId = 1 }, @{ modId = 9002; fileId = 21 }, @{ modId = 9003; fileId = 29 }, @{ modId = 9004; fileId = 40 }, @{ modId = 9005; fileId = 50 },
            @{ modId = 9006; fileId = 60 }, @{ modId = 9007; fileId = 70 }, @{ modId = 9008; fileId = 80 }, @{ modId = 9008; fileId = 81 }, @{ modId = 9009; fileId = 90 })
        $code = (ConvertTo-PackCode 'Friends' $fl).code
        $sp = Get-PackPlan (Read-ModPack (ConvertTo-PackCode 'Friends' $fl -Short).code)
        $sig = { param($x) "$(@($x.have) -join ',')|$(@($x.turnOn) -join ',')|$(@($x.versions | ForEach-Object { "$($_.name)>$($_.fileId)" }) -join ',')|$(@($x.new | ForEach-Object { "$($_.name)>$($_.modId)/$($_.fileId)" } | Sort-Object) -join ',')" }
        '[{"name":"FwX","repo":"none/none","asset":"x"}]' | Set-Content "$Sb\frameworks.json"
        $pl = Get-PackPlan (Read-ModPack $code)
        '[]' | Set-Content "$Sb\frameworks.json"
        $vs = { param($n) $pl.versions | Where-Object name -eq $n }
        Check ((@($pl.have) -join ',') -eq 'PackSame' -and (@($pl.turnOn) -join ',') -eq 'PackOff' -and (@($pl.versions | ForEach-Object name) -join ',') -eq 'PackOld,PackKeep' -and (@($pl.frameworks) -join ',') -eq 'FwX') "T28 plan: have, turn on, other versions, frameworks: $(ConvertTo-Json $pl -Compress -Depth 4)"
        Check ((& $vs 'PackOld').newer -and -not (& $vs 'PackOld').older -and (& $vs 'PackOld').pack -eq '2.0' -and (& $vs 'PackKeep').older -and -not (& $vs 'PackKeep').newer) 'T28 plan: the pack has PackOld newer, PackKeep older (matched by its file name)'
        Check ((@($pl.new | ForEach-Object name) -join ',') -eq 'Brand new,ModD (9006),Twin - Twin A,Twin - Twin B' -and ($pl.new | Where-Object fileId -eq 50).version -eq '3.1') "T28 plan: new mods named from Nexus, a clashing name kept apart, two files of one mod: $(($pl.new | ForEach-Object name) -join ', ')"
        Check ((@($pl.gone) -join ',') -eq 'Was removed (file 70),Nexus mod 9009') "T28 plan: removed and unknown files are skipped: $(@($pl.gone) -join ', ')"
        Check ((& $sig $sp) -eq (& $sig $pl) -and (@($sp.gone) -join ',') -eq 'Was removed (file 70),Nexus file 90') "T28 a short code plans the same as the long one: $(& $sig $sp) / gone $(@($sp.gone) -join ', ')"
        # "Update my mods": the pack's version only where it is newer
        $pts = @(Get-RestorePoints).Count
        [void](Invoke-ModPack (Read-ModPack $code) @(@($pl.versions | Where-Object newer | ForEach-Object name)))
        $q = @(Get-Queue | Where-Object { -not $_.done }); $st = Get-State
        Check (@(Get-RestorePoints)[0].label -eq 'Before the modpack Friends' -and @(Get-RestorePoints).Count -eq $pts + 1) 'T28 restore point made first'
        Check (@(Get-SettingsBackups | Where-Object { $_.reason -eq 'Before the modpack Friends' }).Count -eq 1) 'T28 mod settings backup made first'
        Check ((@($q | ForEach-Object { "$($_.fileId)=$($_.name)" }) -join ',') -eq '50=Brand new,60=ModD (9006),80=Twin - Twin A,81=Twin - Twin B,21=PackOld') "T28 queue: new mods, then PackOld updated under its name; PackKeep not downgraded: $(($q | ForEach-Object { "$($_.fileId)=$($_.name)" }) -join ', ')"
        Check (($st.mods | Where-Object name -eq 'PackOff') -and ($st.mods | Where-Object name -eq 'PackKeep').fileId -eq 30) 'T28 PackOff turned back on, PackKeep unchanged'
        # an optional file of a mod you have is not "another version" of your main file; two mods named alike stay apart
        & $nx 'Lut' 9010 100 '1.0' (New-TestMod 'Lut' @{ 'archive\pc\mod\lut.archive' = 'l' })
        $ep = Get-PackPlan (Read-ModPack (ConvertTo-PackCode 'Edge' @(@{ modId = 9010; fileId = 101 }, @{ modId = 9011; fileId = 110 }, @{ modId = 9012; fileId = 120 })).code)
        Check (-not @($ep.versions).Count -and (@($ep.new | ForEach-Object name) -join ',') -eq 'Lut (9010),Same Name,Same Name (9012)') "T28 optional file is new beside your main file; same-named mods get distinct names: $(($ep.new | ForEach-Object name) -join ', ')"
    }
    finally { & (Get-Module cpmods) { param($f) Set-Item function:script:Invoke-NexusGql $f } $origGql }
    & $nx 'PackOld' 9002 21 '2.0' (New-TestMod 'PackOld2' @{ 'archive\pc\mod\pold.archive' = 'o2' })
    $po = (Get-State).mods | Where-Object name -eq 'PackOld'
    Check ($po.fileId -eq 21 -and @($po.older).Count -eq 1 -and @((Get-State).mods | Where-Object modId -eq 9002).Count -eq 1 -and (& $cont 'archive\pc\mod\pold.archive') -eq 'o2') 'T28 the pack version replaced yours in place; your download is kept'
    $rp = Get-RestorePlan (@(Get-RestorePoints | Where-Object label -eq 'Before the modpack Friends')[0].id)
    Check (@($rp.version | Where-Object { $_.name -eq 'PackOld' -and $_.to -eq '1.0' }).Count -eq 1) 'T28 the restore point brings your version back'
    Disable-InstalledMod 'PackKeep'
    & $nx 'PackKeep' 9003 31 '3.0' (New-TestMod 'PackKeep3' @{ 'archive\pc\mod\pkeep.archive' = 'k3' })
    $pk = (Get-State).mods | Where-Object name -eq 'PackKeep'
    Check ($pk.fileId -eq 31 -and @($pk.older) -contains "$Sb\src\PackKeep.zip" -and -not ((Get-State).disabled | Where-Object name -eq 'PackKeep')) 'T28 replacing a turned-off mod keeps its download for going back'

    Write-Host '--- T29: updating chosen frameworks only'
    '[{"name":"FwA","repo":"a/a","asset":"x"},{"name":"FwB","repo":"b/b","asset":"x"}]' | Set-Content "$Sb\frameworks.json"
    $origFw = & (Get-Module cpmods) { ${function:Install-GitHubFramework} }
    & (Get-Module cpmods) { function script:Install-GitHubFramework($Fw) { "did $($Fw.name)" } }
    try {
        Check ((@(Invoke-Frameworks -Names 'FwB') -join ',') -eq 'did FwB' -and (@(Invoke-Frameworks) -join ',') -eq 'did FwA,did FwB' -and (@(Invoke-Frameworks -Names @()) -join ',') -eq 'did FwA,did FwB') 'T29 -Names limits the update; none named = all'
    }
    finally { & (Get-Module cpmods) { param($f) Set-Item function:script:Install-GitHubFramework $f } $origFw; '[]' | Set-Content "$Sb\frameworks.json" }

    Write-Host '--- T30: choosing the winner that already wins renames nothing and is remembered; known log messages'
    Install-ModArchive (New-TestMod 'Win1' @{ 'archive\pc\mod\aaa_win.archive' = 'w1' }) (& $meta 'Win1') | Out-Null
    Install-ModArchive (New-TestMod 'Win2' @{ 'archive\pc\mod\bbb_win.archive' = 'w2' }) (& $meta 'Win2') | Out-Null
    $n = Set-ArchiveWinner 'aaa_win.archive' 'bbb_win.archive'
    Check ($n -eq 'aaa_win.archive' -and (Test-Path "$g\archive\pc\mod\aaa_win.archive") -and (@((Get-LoadOrderRules)['aaa_win.archive'].over) -join ',') -eq 'bbb_win.archive') 'T30 the winner keeps its name; the choice is recorded'
    [void](Set-ArchiveWinner 'aaa_win.archive' 'ccc.archive')
    Check ((@((Get-LoadOrderRules)['aaa_win.archive'].over) -join ',') -eq 'bbb_win.archive,ccc.archive') 'T30 a second choice adds to it'
    [void](Reset-ArchiveName 'aaa_win.archive')
    Check ((Test-Path "$g\archive\pc\mod\aaa_win.archive") -and -not (Get-LoadOrderRules).Contains('aaa_win.archive')) 'T30 undoing a choice that renamed nothing works'
    Check ((Set-ArchiveWinner 'bbb_win.archive' 'aaa_win.archive') -eq '!bbb_win.archive' -and (Test-Path "$g\archive\pc\mod\!bbb_win.archive")) 'T30 the other one still gets the ! prefix to win'
    [void](Reset-ArchiveName '!bbb_win.archive')
    Remove-Item "$Sb\state\known-messages.json" -ErrorAction SilentlyContinue
    $mk = { param($t) [ordered]@{ source = 'Cyber Engine Tweaks'; mod = 'M'; text = $t; level = 'error' } }
    $t0 = (Get-Date).AddDays(-3); $t1 = $t0.AddDays(1); $t2 = $t1.AddDays(1)
    $a = @(& $mk 'init.lua:87: nil value at 0x1234')
    Set-KnownMessages $a $t0 $true
    Check (-not $a[0].known -and (Test-Path "$Sb\state\known-messages.json")) 'T30 first clean launch, no record yet: its messages are flagged once and remembered'
    $b = @((& $mk 'init.lua:90: nil value at 0x9F9F'), (& $mk 'brand new error'))
    Set-KnownMessages $b $t1 $true
    Check ($b[0].known -and -not $b[1].known) 'T30 the same message with other numbers is known; a new one is flagged'
    Set-KnownMessages $b $t1 $true
    Check (-not $b[1].known) 'T30 rebuilding the same report still flags the new one'
    $c = @((& $mk 'brand new error'), (& $mk 'only after a crash'))
    Set-KnownMessages $c $t2 $false
    Check ($c[0].known -and -not $c[1].known) 'T30 the next launch knows it; a crash launch teaches nothing'
    Set-KnownMessages @($c[1]) $t2.AddHours(1) $true
    Check (-not $c[1].known -and (Get-Content "$Sb\state\known-messages.json" -Raw) -match 'only after a crash') 'T30 a clean launch learns it (flagged this once)'

    Write-Host '--- T31: the server stays while a launch without mods runs; cleanup keeps what profiles need'
    $sh = [hashtable]::Synchronized(@{ jobs = [hashtable]::Synchronized(@{}); stop = $false; winOpen = $false; byeAt = [datetime]::UtcNow.AddMinutes(-1); lastSeen = [datetime]::UtcNow.AddMinutes(-2); gameRun = $false })
    Check (Test-CpShouldExit $sh) 'T31 window closed, nothing running: the server leaves'
    try {
        Write-JsonFile (Get-VanillaFile) ([ordered]@{ started = (Get-Date).AddMinutes(-30).ToString('s'); gameSeen = $true; moves = @() })
        $sh.gameRun = $true
        Check (-not (Test-CpShouldExit $sh)) 'T31 mods set aside and the game running: it stays to bring them back'
        $sh.gameRun = $false
        Check (Test-CpShouldExit $sh) 'T31 the game closed (the restore job keeps it running meanwhile): it may leave'
        Write-JsonFile (Get-VanillaFile) ([ordered]@{ started = (Get-Date).AddMinutes(-2).ToString('s'); gameSeen = $false; moves = @() })
        Check (-not (Test-CpShouldExit $sh)) 'T31 the game is still starting: it stays'
    }
    finally { Remove-Item (Get-VanillaFile) -Force -ErrorAction SilentlyContinue }
    $zPr = New-TestMod 'ProfMod' @{ 'archive\pc\mod\prof.archive' = 'p' }
    Copy-Item $zPr "$dl\prof.zip"
    Install-ModArchive "$dl\prof.zip" (& $meta 'ProfMod') | Out-Null
    [void](Save-Profile 'WithProf')
    Remove-InstalledMod 'ProfMod'
    (Get-Item "$dl\prof.zip").LastWriteTime = (Get-Date).AddHours(-2)
    Check (-not (@(Get-SpareDownloads) | Where-Object file -eq 'prof.zip') -and (@(Get-SpareDownloads -Old) | Where-Object file -eq 'prof.zip')) 'T31 a removed mod a profile still has: kept by the cleanup (only "older versions too" may delete it)'
}
catch { $script:fails++; Write-Host "FAIL (stopped): $($_.Exception.Message)" -ForegroundColor Red }
finally {
    Remove-Module cpserver, cpsafety, cpinsight, cpmods -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Sb -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:fails) -ForegroundColor $(if ($script:fails) { 'Red' } else { 'Green' })
}
exit [int][bool]$script:fails
