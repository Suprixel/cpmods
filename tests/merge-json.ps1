# Self-check of "Combine both" (merging a JSON game file two mods change), in a throwaway copy of the app with a fake game.
# Run from the app folder: pwsh -NoProfile -File tests\merge-json.ps1   Touches nothing outside a temp folder.
$ErrorActionPreference = 'Stop'
$sb = Join-Path ([IO.Path]::GetTempPath()) "cpmods-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$g = Join-Path $sb 'game'; $rel = 'r6\config\test.json'
$script:f = 0; $script:p = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:p++ } else { $script:f++; Write-Host "FAIL: $Msg" -ForegroundColor Red } }
function C([string]$J) { ConvertTo-Json -InputObject (ConvertFrom-Json $J -AsHashtable) -Compress -Depth 20 }
try {
    New-Item -ItemType Directory -Force "$sb\lib", "$g\bin\x64", (Split-Path "$g\$rel") | Out-Null
    Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'lib\*.psm1') "$sb\lib"
    @{ gamePath = $g; nexusGame = 'cyberpunk2077'; steamManifest = '' } | ConvertTo-Json | Set-Content "$sb\config.json"
    '[]' | Set-Content "$sb\frameworks.json"; 'exe' | Set-Content "$g\bin\x64\Cyberpunk2077.exe"
    Import-Module "$sb\lib\cpmods.psm1", "$sb\lib\cpinsight.psm1", "$sb\lib\cpsafety.psm1" -Force -DisableNameChecking
    Set-CpContext 'test' $true
    if ((Get-CpPaths).game -ne $g) { throw 'not isolated' }

    # merge rules
    $r = Merge-JsonText '{"a":1,"b":1}' '{"a":2,"b":1}' '{"a":1,"b":3}'
    Check ((C $r.text) -ceq '{"a":2,"b":3}' -and -not $r.clashes.Count) 'changes made by each side are both kept'
    $r = Merge-JsonText '{"o":{"max":80}}' '{"o":{"max":100}}' '{"o":{"max":140}}'
    Check ((C $r.text) -ceq '{"o":{"max":140}}' -and "$($r.clashes)" -eq 'o.max') 'value both changed: new copy wins and is listed'
    $r = Merge-JsonText '{"l":[{"name":"A","v":1}]}' '{"l":[{"name":"A","v":2}]}' '{"l":[{"name":"A","v":1},{"name":"B","v":1}]}'
    Check ((C $r.text) -ceq '{"l":[{"name":"A","v":2},{"name":"B","v":1}]}' -and -not $r.clashes.Count) 'named list: an added item and an edited item are both kept'
    $r = Merge-JsonText '{"l":[{"name":"S","u":"kmh","max":100}]}' '{"l":[{"name":"S","u":"kmh","max":120}]}' '{"l":[{"name":"S","u":"KMH","max":100}]}'
    Check ((C $r.text) -ceq '{"l":[{"name":"S","u":"KMH","max":120}]}') 'a change of letter case only is kept'
    $r = Merge-JsonText '{"a":1,"b":1}' '{"a":2,"b":1}' '{"a":1}'
    Check ((C $r.text) -ceq '{"a":2}') 'a value removed by one side stays removed'

    # installs: A and B combined, updates of each, restore point
    [IO.File]::WriteAllText("$g\$rel", '{"a":1,"b":1,"c":1}')
    $zip = { param($n, $j) $d = "$sb\src\$n"; New-Item -ItemType Directory -Force (Split-Path "$d\$rel") | Out-Null; [IO.File]::WriteAllText("$d\$rel", $j); Compress-Archive "$d\*" "$sb\src\$n.zip" -Force; "$sb\src\$n.zip" }
    $meta = { param($n) [ordered]@{ name = $n; version = '1'; source = 'manual' } }
    $disk = { C ([IO.File]::ReadAllText("$g\$rel")) }
    $zA1 = & $zip 'A1' '{"a":2,"b":1,"c":1}'; $zA2 = & $zip 'A2' '{"a":3,"b":9,"c":1}'
    $zB1 = & $zip 'B1' '{"a":1,"b":2,"c":1}'; $zB2 = & $zip 'B2' '{"a":1,"b":3,"c":1}'
    Install-ModArchive $zA1 (& $meta 'A') | Out-Null; Start-Sleep -Milliseconds 1100
    Install-ModArchive $zB1 (& $meta 'B') -OnConflict merge | Out-Null
    Check ((& $disk) -ceq '{"a":2,"b":2,"c":1}') 'combined install has both mods'' changes'
    $r = Install-ModArchive $zB2 (& $meta 'B') -Ask
    Check ($r.conflict -and $r.conflict[0].merge -and -not @($r.conflict[0].merge.clashes).Count) "updating the mod on top lists no false conflict ($(@($r.conflict[0].merge.clashes)))"
    Install-ModArchive $zB2 (& $meta 'B') -OnConflict merge | Out-Null
    Check ((& $disk) -ceq '{"a":2,"b":3,"c":1}') 'updated mod on top is combined again'
    $r = Install-ModArchive $zA2 (& $meta 'A') -Ask
    Check ("$(@($r.conflict[0].merge.clashes))" -eq 'b') "updating the mod underneath lists only the real conflict ($(@($r.conflict[0].merge.clashes)))"
    $rp = Save-RestorePoint 'manual' 'test'
    Remove-InstalledMod 'B'
    Check ((& $disk) -ceq '{"a":2,"b":1,"c":1}') 'removing the mod on top leaves the other mod''s own copy'
    Invoke-RestorePoint $rp.id | Out-Null
    Check ((& $disk) -ceq '{"a":2,"b":3,"c":1}' -and @(((Get-State).mods | Where-Object name -eq 'B').merged) -contains $rel) 'going back to a restore point combines again'
}
catch { $script:f++; Write-Host "FAIL (stopped): $($_.Exception.Message)" -ForegroundColor Red }
finally {
    Remove-Module cpmods, cpsafety -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:p, $script:f) -ForegroundColor $(if ($script:f) { 'Red' } else { 'Green' })
}
exit [int][bool]$script:f
