# Full copy of the app on a fake game folder, prepared with every new feature's data, for UI tests
param([string]$Sb = (Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'))
$ErrorActionPreference = 'Stop'
# the previous run's hidden WebView2 processes can hold the folder for a few seconds after the window closes
for ($i = 0; (Test-Path $Sb) -and $i -lt 60; $i++) { try { Remove-Item $Sb -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 500 } }
if (Test-Path $Sb) { throw "Old UI sandbox still locked: $Sb" }
$app = Split-Path (Split-Path $PSScriptRoot)
$g = Join-Path $Sb 'game'
New-Item -ItemType Directory -Force $Sb, "$g\bin\x64", "$g\r6\config", "$g\archive\pc\content", "$g\engine\config\base", "$Sb\src", "$Sb\downloads" | Out-Null
foreach ($d in 'lib', 'ui') { Copy-Item "$app\$d" $Sb -Recurse }
foreach ($f in 'server.ps1', 'cpmods.ps1') { Copy-Item "$app\$f" $Sb }
'{"gamePath":"' + ($g -replace '\\', '\\') + '","nexusGame":"cyberpunk2077","steamManifest":""}' | Set-Content "$Sb\config.json"
'[]' | Set-Content "$Sb\frameworks.json"
'exe' | Set-Content "$g\bin\x64\Cyberpunk2077.exe"
'VANILLA' | Set-Content "$g\r6\config\inputUserMappings.xml" -NoNewline
'CETLOADER' | Set-Content "$g\bin\x64\version.dll"
"[Scripts]`nEnableCompilation = `"true`"" | Set-Content "$g\engine\config\base\scripts.ini"
# fake saves, reached through the CPMODS_SAVES hook
$sv = Join-Path $Sb 'savedgames\CD Projekt Red\Cyberpunk 2077'
foreach ($i in 1..3) { New-Item -ItemType Directory -Force "$sv\ManualSave-$i" | Out-Null; "save$i" | Set-Content "$sv\ManualSave-$i\sav.dat" -NoNewline }

function New-TestMod([string]$Name, [hashtable]$Files) {
    $d = Join-Path $Sb "src\$Name"
    foreach ($k in $Files.Keys) { $p = Join-Path $d $k; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Set-Content -LiteralPath $p -Value $Files[$k] -NoNewline }
    $z = Join-Path $Sb "downloads\$Name.zip"
    Compress-Archive -Path "$d\*" -DestinationPath $z -Force
    $z
}
$zA = New-TestMod 'ModA' @{ 'r6\config\inputUserMappings.xml' = 'A'; 'archive\pc\mod\aaa.archive' = 'A-arch' }
$zB = New-TestMod 'ModB' @{ 'r6\config\inputUserMappings.xml' = 'B'; 'archive\pc\mod\bbb.archive' = 'B-arch' }
$zD = New-TestMod 'ModD' @{ 'archive\pc\mod\zzz.archive' = 'D' }
$zE = New-TestMod 'ModE' @{ 'archive\pc\mod\mmm.archive' = 'E' }
$zF = New-TestMod 'ModF' @{ 'bin\x64\plugins\cyber_engine_tweaks\mods\ModF\init.lua' = 'lua' }

Import-Module "$Sb\lib\cpmods.psm1" -Force -DisableNameChecking
Import-Module "$Sb\lib\cpinsight.psm1" -Force -DisableNameChecking
Import-Module "$Sb\lib\cpsafety.psm1" -Force -DisableNameChecking
Set-CpContext 'uisb' $true
if ((Get-CpPaths).game -ne $g) { throw 'sandbox not isolated' }
[void](Save-CpSettings @{ askOverwrite = $true; saveKeep = 5 })
$m = { param($n) [ordered]@{ name = $n; version = '1'; source = 'manual' } }
foreach ($x in @(@($zA, 'ModA'), @($zD, 'ModD'), @($zE, 'ModE'), @($zF, 'ModF'))) { Install-ModArchive $x[0] (& $m $x[1]) | Out-Null; Start-Sleep -Milliseconds 300 }
'{"setting":1}' | Set-Content "$g\bin\x64\plugins\cyber_engine_tweaks\mods\ModF\settings.json" -NoNewline
[void](Save-RestorePoint 'manual' 'Before the UI test')
Disable-InstalledMod 'ModD'
$r = Install-ModArchive $zB (& $m 'ModB') -Ask
if (-not $r.conflict) { throw 'expected a conflict for ModB' }
Add-Deferred 'pending' $zB (& $m 'ModB') '' $r.conflict
[void](Backup-ModSettings 'manual' 'Before the UI test')
[void](Backup-Saves 'Before the UI test' $sv)
[void](Set-ArchiveWinner 'mmm.archive' 'aaa.archive')
'UI sandbox ready: ' + $Sb
