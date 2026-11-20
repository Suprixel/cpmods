# Reports (actionable problems, hide, turn off), Game page, Settings (backgrounds, disk space) in the hidden -Dev window
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'; $g = "$Sb\game"
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
# two script mods replacing the same function, a fake launch that logged it, an old unused download
$rf = "@replaceMethod(FooController)`nprotected cb func OnBar() -> Bool {`n  return true;`n}"
foreach ($n in 'R1', 'R2') { $d = "$Sb\src\Mod$n\r6\scripts\$n"; New-Item -ItemType Directory -Force $d | Out-Null; [IO.File]::WriteAllText("$d\$($n.ToLower()).reds", $rf); Compress-Archive -Path "$Sb\src\Mod$n\*" -DestinationPath "$Sb\downloads\Mod$n.zip" -Force }
pwsh -NoProfile -Command "Import-Module '$Sb\lib\cpmods.psm1' -DisableNameChecking; Set-CpContext 't' `$true; if ((Get-CpPaths).game -ne '$g') { throw 'not isolated' }; foreach (`$n in 'ModR1', 'ModR2') { [void](Install-ModArchive `"$Sb\downloads\`$n.zip`" ([ordered]@{ name = `$n; version = '1'; source = 'manual' })); Start-Sleep -Milliseconds 300 }" | Out-Null
$t0 = (Get-Date).AddMinutes(-20); $t1 = $t0.AddMinutes(5); $fmt = { param($d) $d.ToString('yyyy-MM-dd HH:mm:ss.fff') }
New-Item -ItemType Directory -Force "$g\red4ext\logs", "$g\r6\logs" | Out-Null
@("[$(& $fmt $t0)] [info    ] [ 1] [RED4ext] RED4ext (v1.31.1) is initializing...", "[$(& $fmt $t0)] [info    ] [ 1] [RED4ext] Product version: 2.50", "[$(& $fmt $t0)] [info    ] [ 1] [RED4ext] 0 plugin(s) loaded",
    "[$(& $fmt $t1)] [info    ] [ 1] [RED4ext] RED4ext is shutting down...", "[$(& $fmt $t1)] [info    ] [ 1] [RED4ext] RED4ext has been shut down") | Set-Content "$g\red4ext\logs\red4ext-$($t0.ToString('yyyy-MM-dd-HH-mm-ss')).log"
$rt = $t0.AddSeconds(30).ToString('ddd, d MMM yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
@("[INFO - $rt +0100] Compiling files in $g\r6\scripts:", 'R1\r1.reds', 'R2\r2.reds', "[WARN - $rt +0100] At $g\r6\scripts\R2\r2.reds:1:1:", '@replaceMethod(FooController)', '^^^',
    'this method replacement overwrites a previous annotation targeting the same method, only one replacement per method can be active at a time', '', "[INFO - $rt +0100] Compilation complete") | Set-Content "$g\r6\logs\redscript_rCURRENT.log"
Copy-Item "$Sb\downloads\ModR1.zip" "$Sb\downloads\old-unused.zip"; (Get-Item "$Sb\downloads\old-unused.zip").LastWriteTime = (Get-Date).AddHours(-3)

. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U9 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function Q([string]$s) { ConvertTo-Json $s -Compress }
function Click([string]$Sel) { Js "(() => { const e = document.querySelector($(Q $Sel)); if (!e) return 'missing'; e.click(); return 'ok'; })()" }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Api([string]$Path, $Body) {
    for ($i = 0; $i -lt 40 -and -not (Test-Path $script:devInfo); $i++) { Start-Sleep -Milliseconds 250 }
    $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json; $h = @{ 'X-Cp-Token' = $j.token }
    if ($null -eq $Body) { Invoke-RestMethod "http://localhost:$($j.port)$Path" -Headers $h } else { Invoke-RestMethod -Method Post "http://localhost:$($j.port)$Path" -Headers $h -ContentType 'application/json' -Body (ConvertTo-Json $Body) }
}
function WaitJobs { Start-Sleep -Milliseconds 500; for ($i = 0; $i -lt 80; $i++) { if (-not @((Api '/api/state').jobs | Where-Object status -eq 'running').Count) { return }; Start-Sleep -Milliseconds 400 } }
function Shot([string]$Name) { [void](Save-Shot (Join-Path ([IO.Path]::GetTempPath()) $Name) 0.6) }
function Prefs { Get-Content "$Sb\state\ui.json" -Raw | ConvertFrom-Json }
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false })

    # Reports: the card names the other mod, offers actions, can be hidden and turned off
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/reports' })
    Check ([bool](WaitJs '/Check ModR2/.test((document.getElementById("rep-body") || {}).innerText || "")' 20000)) 'reports: the problem card shows'
    Check ((Js '[...document.querySelectorAll("#nav .nav-item span:first-of-type")].map(e => e.textContent).join(",")') -eq 'Discover,Collections,Library,Compatibility,Downloads,Game,Reports,Settings') 'nav: Game and Reports pages'
    $card = 'document.querySelector("#rep-body .callout.warn").innerText'
    Check ((Js $card) -match 'ModR1' -and (Js $card) -match 'also replaces FooController\.OnBar') 'reports: names the other mod replacing the same function'
    Check ((Js $card) -match 'R2\\r2\.reds line 1') 'reports: message first, then file and line'
    Check ([bool](Js '!!document.querySelector("#rep-body .callout.warn [data-act=open-log][data-path=\"r6\\\\logs\\\\redscript_rCURRENT.log\"]") && !!document.querySelector("#rep-body .callout.warn [data-act=reveal][data-path=\"r6\\\\scripts\\\\R2\\\\r2.reds\"]")')) 'reports: Open log and Show file point at the right files'
    Check ([bool](Js '!!document.querySelector("#rep-body .callout.warn [data-act=issue-off][data-name=ModR2]")')) 'reports: Turn off offered'
    Check (-not (Js '[...document.querySelectorAll("#rep-body .tabbar-btn")].some(b => /Folders/.test(b.textContent))')) 'reports: folders moved off this page'
    Shot 'ui-reports.jpg'
    [void](Click '#rep-body .callout.warn [data-act=issue-hide]')
    Check ([bool](WaitJs '!/Check ModR2/.test(document.getElementById("rep-body").innerText) && /1 hidden problem/.test(document.getElementById("rep-body").innerText)')) 'reports: Hide moves it out of the list'
    Check ([bool](WaitJs '/To check\s+0/.test(document.querySelector("#rep-body .seg").innerText)')) 'reports: a hidden problem no longer counts as one to check'
    Start-Sleep -Milliseconds 800
    Check (@((Prefs).hideIssues).Count -eq 1) 'reports: hidden list saved with the preferences'
    [void](Click '[data-act=rep-hidden]'); Start-Sleep -Milliseconds 300
    Check ([bool](Js '/Show again/.test(document.querySelector("#rep-body .callout.warn").innerText)')) 'reports: "Show them" lists it with Show again'
    [void](Click '#rep-body .callout.warn [data-act=issue-hide]'); Start-Sleep -Milliseconds 300
    [void](Click '#rep-body .callout.warn [data-act=issue-off]'); [void](WaitJs '!document.getElementById("modal").hidden')
    [void](Click '#modal [data-m="1"]'); WaitJobs
    Check ([bool]((Api '/api/state').disabled | Where-Object name -eq 'ModR2')) 'reports: Turn off disabled the mod'
    Check ([bool](WaitJs '!/Check ModR2/.test(document.getElementById("rep-body").innerText) || /Off now/.test(document.getElementById("rep-body").innerText)')) 'reports: the card goes (the report only covers mods that are on)'
    $bad = try { [void](Api '/api/system' @{ op = 'openFile'; path = '..\x.log' }); 'opened' } catch { 'refused' }
    $exe = try { [void](Api '/api/system' @{ op = 'openFile'; path = 'bin\x64\Cyberpunk2077.exe' }); 'opened' } catch { 'refused' }
    Check ($bad -eq 'refused' -and $exe -eq 'refused') 'openFile refuses paths outside the game folder and non-log files'

    # Game page: status, launch options, saves and backups, folders
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/game' })
    Check ([bool](WaitJs '!!document.querySelector(".gm-hero") && /Ready to play/.test(document.querySelector(".gm-hero").innerText)')) 'game: status card'
    Check ((Js 'document.querySelectorAll("#g-folders .folder-btn").length') -eq 11 -and [bool](Js '!!document.querySelector("#g-launch [data-setsel=launchMode]") && !!document.querySelector("#g-backups [data-setting=autoRestore]")')) 'game: folders, launch options, backups'
    Check ([bool](Js '/Last launch/.test(document.querySelector(".gm-foot").innerText)')) 'game: last launch links to the report'
    Shot 'ui-game.jpg'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/library' }); [void](WaitJs 'document.querySelector("[data-act=play-menu]")')
    [void](Click '[data-act=play-menu]'); [void](WaitJs '!document.getElementById("menu").hidden')
    [void](Click '#menu [data-act=game-at][data-k=launch]')
    Check ([bool](WaitJs 'location.hash.startsWith("#/game") && !!document.getElementById("g-launch")')) 'play menu: Launch settings opens the Game page'

    # Settings: 7 sections, backgrounds (White, Custom), disk space and cleanup
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' })
    Check ([bool](WaitJs 'document.querySelectorAll(".sx").length === 8 && !!document.querySelector(".sx-note [data-page=game]")')) 'settings: 8 sections and a pointer to the Game page'
    [void](Click '[data-act="sx"][data-k="look"]'); [void](WaitJs 'document.querySelectorAll("[data-bg-opt]").length === 6')
    Check ((Js 'document.querySelectorAll("[data-bg-opt]").length') -eq 6) 'appearance: 6 backgrounds'
    [void](Js '(() => { const i = document.querySelector("input[name=bg][value=white]"); i.checked = true; i.dispatchEvent(new Event("change", { bubbles: true })); })()'); Start-Sleep -Milliseconds 900
    Check ((Js 'document.documentElement.getAttribute("data-bg")') -eq 'white' -and (Js 'getComputedStyle(document.body).backgroundColor') -eq 'rgb(238, 240, 243)') 'appearance: White applies'
    Check ((Prefs).bg -eq 'white' -and (Prefs).themeVars.'--surface' -eq '#ffffff') 'appearance: background saved for the first paint'
    [void](Js 'document.querySelector("[data-bg-opt]").scrollIntoView({ block: "start" })'); Start-Sleep -Milliseconds 300
    Shot 'ui-look-white.jpg'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/reports' }); [void](WaitJs '/Check ModR2/.test((document.getElementById("rep-body") || {}).innerText || "")' 15000)
    Check ((Js 'document.documentElement.getAttribute("data-bg")') -eq 'white') 'appearance: White is there right after a reload'
    Shot 'ui-reports-white.jpg'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/game' }); [void](WaitJs '!!document.querySelector(".gm-hero")')
    Shot 'ui-game-white.jpg'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' }); [void](WaitJs 'document.querySelectorAll("[data-bg-opt]").length === 6')
    [void](Js '(() => { const i = document.querySelector("input[name=bg][value=custom]"); i.checked = true; i.dispatchEvent(new Event("change", { bubbles: true })); })()')
    Check ([bool](WaitJs '!!document.getElementById("bw-box") && !document.getElementById("bw-box").classList.contains("idle")')) 'appearance: Custom shows the background picker'
    [void](Click '[data-act=pick-preset][data-k=bw][data-v="#10292c"]'); Start-Sleep -Milliseconds 800
    Check ((Prefs).customBg -eq '#10292c' -and (Js 'document.documentElement.getAttribute("data-bg")') -eq 'custom') 'appearance: a background dot applies and saves'
    [void](Js 'document.querySelector("[data-bg-opt]").scrollIntoView({ block: "start" })'); Start-Sleep -Milliseconds 300
    Check ((Js 'document.querySelector("#sx-look .sx-t span").textContent') -like '*custom background*') 'appearance: the section summary follows the background'
    Shot 'ui-look-custom.jpg'
    foreach ($b in 'oled', 'grey', 'black') { [void](Js "(() => { const i = document.querySelector('input[name=bg][value=$b]'); i.checked = true; i.dispatchEvent(new Event('change', { bubbles: true })); })()"); Start-Sleep -Milliseconds 300 }
    Check ((Js 'getComputedStyle(document.body).backgroundColor') -eq 'rgb(9, 9, 9)') 'appearance: Black applies'
    [void](Js '(() => { const i = document.querySelector("input[name=bg][value=match]"); i.checked = true; i.dispatchEvent(new Event("change", { bubbles: true })); })()'); Start-Sleep -Milliseconds 800
    Check (-not (Js 'document.documentElement.getAttribute("data-bg")') -and -not (Prefs).bg) 'appearance: Matching goes back to the default look'
    [void](Click '[data-act="sx"][data-k="perf"]')
    Check ([bool](WaitJs '/in the game folder for/.test((document.getElementById("disk-now") || {}).innerText || "")' 15000)) 'disk space: shown in Performance'
    Check ([bool](Js '/1 download/.test(document.querySelector(".du-clean").innerText)')) 'disk space: the old unused download is found'
    [void](Js 'document.getElementById("disk-now").scrollIntoView({ block: "center" })'); Start-Sleep -Milliseconds 300
    Shot 'ui-disk.jpg'
    [void](Click '[data-act=disk-clean]'); [void](WaitJs '!document.getElementById("modal").hidden')
    Check ([bool](Js '/old-unused\.zip/.test(document.getElementById("modal").innerText)')) 'disk space: the cleanup lists what it deletes'
    [void](Click '#modal [data-m="go"]'); WaitJobs
    Check (-not (Test-Path "$Sb\downloads\old-unused.zip") -and (Test-Path "$Sb\downloads\ModR1.zip") -and (Test-Path "$Sb\downloads\ModA.zip")) 'disk space: only the unused download was deleted'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' || ')"
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U9.W]::PostMessage([U9.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
