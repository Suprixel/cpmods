# Modpacks in the hidden -Dev window on a sandbox copy (fake game folder, Nexus stand-in; links are logged, never opened)
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
# sandbox only: Nexus pages go to opened.txt; mod lookups read fake-nexus.json
$lib = "$Sb\lib\cpmods.psm1"
$t = [IO.File]::ReadAllText($lib).Replace('function Open-UrlInFront([string]$Url) {', 'function Open-UrlInFront([string]$Url) { Add-Content -LiteralPath (Join-Path $script:Root ''opened.txt'') $Url; return $true')
$stub = @'
function Invoke-NexusGql([string]$Query, $Variables) {
    if ($Query -match 'modFiles\(') {
        $F = Read-JsonFile (Join-Path $script:Root 'fake-nexus.json')
        $d = @{ legacyModsByDomain = @{ nodes = @(foreach ($m in [regex]::Matches($Query, 'modId: (\d+)\}')) { $x = $F["$($m.Groups[1].Value)"]; if ($x) { @{ modId = [int]$m.Groups[1].Value; name = $x.name } } }) } }
        foreach ($m in [regex]::Matches($Query, 'm(\d+): modFiles')) { $x = $F["$($m.Groups[1].Value)"]; $d["m$($m.Groups[1].Value)"] = $(if ($x) { @($x.files) } else { @() }) }
        return $d
    }
    if ($Query -match 'modFilesByUid') {
        $F = Read-JsonFile (Join-Path $script:Root 'fake-nexus.json')
        return @{ modFilesByUid = @{ nodes = @(foreach ($m in [regex]::Matches($Query, '"(\d+)"')) { $fid = [long]$m.Groups[1].Value - ([long]3333 -shl 32); foreach ($k in $F.Keys) { if (@($F[$k].files | Where-Object { $_.fileId -eq $fid }).Count) { @{ fileId = $fid; modId = [int]$k } } } }) } }
    }
'@
$t = $t.Replace("function Invoke-NexusGql([string]`$Query, `$Variables) {", $stub)
[IO.File]::WriteAllText($lib, $t)
@{
    '9001' = @{ name = 'ModN1'; files = @(@{ fileId = 1; name = 'ModN1 main'; version = '1.0'; category = 'OLD_VERSION' }, @{ fileId = 2; name = 'ModN1 main'; version = '1.1'; category = 'MAIN' }) }
    '9002' = @{ name = 'ModN2'; files = @(@{ fileId = 19; name = 'ModN2 main'; version = '0.9'; category = 'OLD_VERSION' }, @{ fileId = 20; name = 'ModN2 main'; version = '1.0'; category = 'MAIN' }) }
    '9005' = @{ name = 'Brand new'; files = @(@{ fileId = 50; name = 'Brand new'; version = '3.1'; category = 'MAIN' }) }
} | ConvertTo-Json -Depth 6 | Set-Content "$Sb\fake-nexus.json"
# two Nexus mods here; codes made with the sandbox's own encoder
$codes = pwsh -NoProfile -Command {
    param($Sb)
    Import-Module "$Sb\lib\cpmods.psm1" -Force -DisableNameChecking; Set-CpContext 'uisb' $true
    function Z([string]$n, [string]$f) { $d = "$Sb\src\$n"; New-Item -ItemType Directory -Force (Split-Path "$d\$f") | Out-Null; Set-Content "$d\$f" $n -NoNewline; Compress-Archive "$d\*" "$Sb\downloads\$n.zip" -Force; "$Sb\downloads\$n.zip" }
    Install-ModArchive (Z 'ModN1' 'archive\pc\mod\n1.archive') ([ordered]@{ name = 'ModN1'; version = '1.0'; source = 'nexus:9001/1'; modId = 9001; fileId = 1; fileName = 'ModN1 main' }) | Out-Null
    Install-ModArchive (Z 'ModN2' 'archive\pc\mod\n2.archive') ([ordered]@{ name = 'ModN2'; version = '1.0'; source = 'nexus:9002/20'; modId = 9002; fileId = 20; fileName = 'ModN2 main' }) | Out-Null
    (ConvertTo-PackCode 'Night City <b>pack</b>' @(@{ modId = 9001; fileId = 2 }, @{ modId = 9002; fileId = 19 }, @{ modId = 9005; fileId = 50 }, @{ modId = 9007; fileId = 70 }) -Short).code
    (ConvertTo-PackCode 'Old one' @(@{ modId = 9002; fileId = 19 })).code
} -args $Sb
$friend, $oldOnly = $codes
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U12 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function Q([string]$s) { ConvertTo-Json $s -Compress }
function Click([string]$Sel) { Js "(() => { const e = document.querySelector($(Q $Sel)); if (!e) return 'missing'; e.click(); return 'ok'; })()" }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Api([string]$Path) { $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json; Invoke-RestMethod "http://localhost:$($j.port)$Path" -Headers @{ 'X-Cp-Token' = $j.token } }
function WaitJobs { Start-Sleep -Milliseconds 500; for ($i = 0; $i -lt 80; $i++) { if (-not @((Api '/api/state').jobs | Where-Object status -eq 'running').Count) { return }; Start-Sleep -Milliseconds 400 } }
function Shot([string]$Name) { [void](Save-Shot (Join-Path ([IO.Path]::GetTempPath()) $Name) 0.6) }
function Set-Text([string]$Id, [string]$V) { [void](Js "(() => { const i = document.getElementById($(Q $Id)); i.value = $(Q $V); i.dispatchEvent(new Event('input', { bubbles: true })); })()") }
function Toast([string]$Rx) { [bool](WaitJs "[...document.querySelectorAll('.toast')].some(t => /$Rx/.test(t.innerText))") }
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/downloads' }); [void](WaitJs 'document.querySelector("#page [data-tool=packs]")')
    Check ((Js 'document.querySelector("#page [data-tool=packs]").innerText.trim()') -eq 'Modpacks') 'downloads: Modpacks button'
    [void](Click '#page [data-tool=packs]'); [void](WaitJs '!!document.getElementById("pack-code")')
    Check ([bool](Js 'location.hash === "#/downloads/tool/packs" && /Get a modpack/.test(document.getElementById("pane").innerText)')) 'pane: opens with its route'

    # share: make a code
    Set-Text 'pack-name' 'My test pack'
    [void](Click '#pane [data-act=pack-make]'); $code = WaitJs '(document.getElementById("pack-out") || {}).value'
    Check ("$code" -cmatch '^CPMODS[0-9A-Za-z]+$' -and "$code".Length -lt 60 -and [bool](Js '/2 mods, \d+ characters/.test(document.getElementById("pane").innerText)')) "share: code made ($code)"
    Check ([bool](Js 'document.getElementById("pack-name").value === "My test pack"')) 'share: the name stays after the pane redraws'
    Check ([bool](Js '!!document.querySelector("#pane [data-act=pack-copy][data-long]") && /long code: \d+\)/.test(document.getElementById("pane").innerText)')) 'share: the long code can be copied too'
    [void](Click '#pane [data-act=pack-copy][data-long]'); Check (Toast 'Long code copied|Press Ctrl\+C') 'share: copying the long code answers'
    Shot 'ui-packs-pane.jpg'

    # get: own code changes nothing; a mistyped one is refused
    Set-Text 'pack-code' $code
    [void](Click '#pane [data-act=pack-check]'); Check (Toast 'Nothing to get') 'get: your own code has nothing to get'
    Set-Text 'pack-code' ($friend.Substring(0, 15) + $(if ($friend[15] -ceq 'x') { 'y' } else { 'x' }) + $friend.Substring(16))
    [void](Click '#pane [data-act=pack-check]'); Check ([bool](WaitJs '[...document.querySelectorAll(".toast.bad")].some(t => /Could not read the modpack/.test(t.innerText) && /damaged or cut short/.test(t.innerText))')) 'get: a mistyped code is refused'
    # get: the friend's short code inside a chat message -> plan dialog
    Set-Text 'pack-code' "yo here's my setup: $friend enjoy"
    [void](Click '#pane [data-act=pack-check]'); [void](WaitJs '!document.getElementById("modal").hidden')
    $mt = Js 'document.getElementById("modal").innerText'
    Check ($mt -match 'Downloaded \(1\)' -and $mt -match 'Brand new' -and $mt -match 'another version \(2\)' -and $mt -match 'yours 1\.0, the pack.s 1\.1' -and $mt -match 'yours 1\.0, the pack.s 0\.9' -and $mt -match 'No longer on Nexus, skipped \(1\)' -and $mt -match 'Nexus file 70') 'dialog: new, two other versions, one gone (short code)'
    Check ($mt -match 'newer in the pack' -and $mt -match 'older in the pack') 'dialog: says which side is newer'
    Check ([bool](Js 'document.querySelector("#modal h3").textContent === "Get the modpack Night City <b>pack</b>?"')) 'dialog: the pack name is shown as text, not HTML'
    Check ((Js 'document.querySelectorAll("#modal .choice").length') -eq 4 -and [bool](Js '/Update my mods/.test(document.querySelector("#modal .choice.rec").innerText) && document.activeElement === document.querySelector("#modal .choice.rec")')) 'dialog: Update my mods is the recommended, focused choice'
    Check ([bool](Js 'document.querySelector("#modal [data-pick=ModN1]").checked && !document.querySelector("#modal [data-pick=ModN2]").checked')) 'dialog: only the newer one is ticked'
    Shot 'ui-packs-dialog.jpg'
    [void](Click '#modal .choice.rec'); WaitJobs
    $st = Api '/api/state'
    $q = @($st.queue | Where-Object { -not $_.done })
    Check ((@($q | ForEach-Object { "$($_.fileId)=$($_.name)" }) -join ',') -eq '50=Brand new,2=ModN1') "apply: queue has the new mod and the ModN1 update, not the ModN2 downgrade: $(($q | ForEach-Object { "$($_.fileId)=$($_.name)" }) -join ', ')"
    $job = $st.jobs | Where-Object kind -eq 'pack' | Select-Object -First 1
    Check ($job.status -eq 'done' -and $job.detail -match '2 download\(s\) queued, the first Nexus page is open' -and $job.detail -match '1 no longer on Nexus' -and $job.detail -match 'Restore point: Before the modpack Night City') "apply: job done: $($job.detail) $($job.error)"
    Check ((Get-Content "$Sb\opened.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -match 'mods/9005\?tab=files&file_id=50') 'apply: the first queued Nexus page was requested (logged, not opened)'
    $bk = Api '/api/backups'
    Check (@($bk.points | Where-Object { $_.label -eq 'Before the modpack Night City <b>pack</b>' }).Count -eq 1 -and @($bk.settings | Where-Object { $_.reason -like 'Before the modpack*' }).Count -eq 1) 'apply: restore point and mod settings backup exist'

    # only an older version in the pack: keep is the default, and keeping changes nothing
    $jobs = @($st.jobs).Count
    Check ([bool](WaitJs '!document.querySelector("#pane [data-act=pack-check]").disabled')) 'pane: the check button comes back when the job ends'
    Set-Text 'pack-code' $oldOnly
    [void](Click '#pane [data-act=pack-check]'); [void](WaitJs '!document.getElementById("modal").hidden')
    Check ((Js 'document.querySelectorAll("#modal .choice").length') -eq 2 -and [bool](Js '/Keep my version/.test(document.querySelector("#modal .choice.rec").innerText)')) 'dialog: pack only older -> Keep my version is recommended'
    [void](Click '#modal .choice.rec'); Check (Toast 'Nothing changes') 'keep with nothing else: no job, says nothing changes'
    Start-Sleep -Milliseconds 800; Check (@((Api '/api/state').jobs).Count -eq $jobs) 'keep with nothing else: no restore point job started'

    # the Library menu entry opens the same pane
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/library' }); [void](WaitJs 'document.querySelector("#page [data-act=lib-more]")')
    [void](Click '#page [data-act=lib-more]'); [void](WaitJs '!document.getElementById("menu").hidden')
    [void](Click '#menu [data-tool=packs]'); Check ([bool](WaitJs '!!document.getElementById("pack-code")')) 'library: "..." menu opens Modpacks'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' || ')"
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U12.W]::PostMessage([U12.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
