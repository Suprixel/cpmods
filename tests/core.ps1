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
}
catch { $script:fails++; Write-Host "FAIL (stopped): $($_.Exception.Message)" -ForegroundColor Red }
finally {
    Remove-Module cpsafety, cpinsight, cpmods -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Sb -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:fails) -ForegroundColor $(if ($script:fails) { 'Red' } else { 'Green' })
}
exit [int][bool]$script:fails
