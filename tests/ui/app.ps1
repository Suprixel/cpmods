# Drives the hidden -Dev window of the UI sandbox (fake game, fake saves, launches disabled) through every new feature
$Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'; $g = "$Sb\game"; $sv = "$Sb\savedgames\CD Projekt Red\Cyberpunk 2077"
pwsh -NoProfile -File "$PSScriptRoot\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$PSScriptRoot\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U1 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
# the key map reads the game's controls: a copy, so the real file is never written
New-Item -ItemType Directory -Force "$Sb\gameconfig" | Out-Null; Copy-Item (Join-Path $env:LOCALAPPDATA 'CD Projekt Red\Cyberpunk 2077\UserSettings.json') "$Sb\gameconfig\UserSettings.json" -ErrorAction SilentlyContinue
Remove-Item $script:devInfo -ErrorAction SilentlyContinue
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:fails = 0; $script:passes = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:passes++; Write-Host "ok   $Msg" } else { $script:fails++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function Q([string]$s) { ConvertTo-Json $s -Compress }
function Click([string]$Sel) { Js "(() => { const e = document.querySelector($(Q $Sel)); if (!e) return 'missing'; e.click(); return 'ok' })()" }
function WaitJs([string]$Expr, [int]$Ms = 10000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Api([string]$Path) { $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json; Invoke-RestMethod "http://localhost:$($j.port)$Path" -Headers @{ 'X-Cp-Token' = $j.token } }
function WaitJobs([int]$Ms = 30000) { $sw = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 400; while ($sw.ElapsedMilliseconds -lt $Ms) { $s = Api '/api/state'; if (-not @($s.jobs | Where-Object { $_.status -eq 'running' }).Count) { return $s }; Start-Sleep -Milliseconds 400 }; throw 'jobs did not finish' }
function Mod([string]$n) { (Api '/api/state').mods | Where-Object { $_.name -eq $n } }
function Shot([string]$Name) { [void](Save-Shot (Join-Path ([IO.Path]::GetTempPath()) $Name) 0.6) }
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    # the hidden test window counts as a background tab (20 s polls): make every page load see itself as visible
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' })
    Check ([bool](WaitJs 'document.querySelectorAll(".sx").length === 7')) 'settings: 7 sections (launch and backups moved to the Game page)'
    Check ((Js 'document.querySelectorAll(".sx.open").length') -eq 1) 'settings: only Downloads open at first'
    Check ((Js 'document.querySelector("#sx-downloads .sx-t span").textContent') -like '*asks when two mods share a file*') 'settings: closed header shows values'
    [void](Click '[data-act="sx"][data-k="perf"]')
    Check ([bool](WaitJs '/Server/.test((document.getElementById("perf-now") || {}).innerText || "")' 12000)) 'settings: performance numbers load when opened'
    Check ((Js 'document.querySelectorAll(".perf-est").length') -eq 0) 'settings: memory numbers hidden by default'
    [void](Click '[data-act="perf-info"]')
    Check ((Js 'document.querySelectorAll(".perf-est").length') -gt 3) 'settings: memory numbers on request'
    [void](Js '(() => { const e = document.querySelector("[data-setting=askOverwrite]"); e.checked = false; e.dispatchEvent(new Event("change", { bubbles: true })); })()'); Start-Sleep -Milliseconds 1500
    Check ((Api '/api/state').settings.askOverwrite -eq $false) 'settings: ask switch saved'
    # the page may redraw Settings after the first save: flip the switch again until the server has it on
    for ($i = 0; $i -lt 20 -and -not (Api '/api/state').settings.askOverwrite; $i++) { [void](Js '(() => { const e = document.querySelector("[data-setting=askOverwrite]"); if (!e.checked) { e.checked = true; e.dispatchEvent(new Event("change", { bubbles: true })); } })()'); Start-Sleep -Milliseconds 500 }
    Check ((Api '/api/state').settings.askOverwrite -eq $true) 'settings: ask switch back on'
    [void](Click '[data-act="sx-all"]'); Start-Sleep -Milliseconds 300
    Check ((Js 'document.querySelectorAll(".sx.open").length') -eq 7) 'settings: expand all'
    Shot 'ui-settings.jpg'
    [void](Click '[data-act="sx-all"]'); Start-Sleep -Milliseconds 300
    Check ((Js 'document.querySelectorAll(".sx.open").length') -eq 0) 'settings: collapse all'
    [void](Click '[data-act="sx"][data-k="downloads"]'); [void](Click '[data-act="sx"][data-k="look"]'); Start-Sleep -Milliseconds 300
    Shot 'ui-settings2.jpg'

    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/downloads' })
    Check ([bool](WaitJs '/Needs your choice/.test(document.body.innerText)')) 'downloads: conflict card'
    Check ((Js '/needs your choice/i.test(document.getElementById("activity").innerText)') -eq $true) 'activity bar: conflict pill'
    [void](Click '#dl-body [data-act="conflict-open"]')
    Check ([bool](WaitJs '!document.getElementById("modal").hidden && document.querySelectorAll("#modal button[data-m]").length === 4')) 'conflict: dialog with 3 choices and later'
    Check ((Js 'document.querySelector("#modal").innerText') -like '*ModA*') 'conflict: names the other mod'
    Shot 'ui-conflict.jpg'
    [void](Click '#modal button[data-m="keep"]'); [void](WaitJobs)
    $b = Mod 'ModB'
    Check ([bool]$b) 'conflict keep: ModB installed'
    Check ((Get-Content "$g\r6\config\inputUserMappings.xml" -Raw) -eq 'A' -and (Test-Path "$g\archive\pc\mod\bbb.archive")) 'conflict keep: the other copy stays, the rest installed'

    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/library' })
    [void](WaitJs 'document.querySelector(''[data-act="tool"][data-tool="backups"]'')')
    [void](Click '[data-act="tool"][data-tool="backups"]')
    Check ([bool](WaitJs 'document.querySelector("#pane .bk-tabs")')) 'backups: pane opens'
    $n = Js '[...document.querySelectorAll("#pane .bk-row .t")].findIndex(e => e.textContent === "Before the UI test")'
    Check ($n -ge 0) 'backups: manual restore point listed'
    [void](Js "document.querySelectorAll('#pane [data-act=bk-plan]')[$n].click()")
    Check ([bool](WaitJs '/Turned back on/i.test(document.querySelector("#pane .bk-plan") ? document.querySelector("#pane .bk-plan").innerText : "")')) 'backups: plan preview'
    Check ((Js 'Math.round(document.querySelector(".ph-actions").getBoundingClientRect().height)') -le 80) 'library: header buttons stay in rows with the pane open'
    Shot 'ui-library.jpg'
    Check ((Js 'document.querySelector("#pane .bk-plan").innerText') -match 'ModB' -and (Js 'document.querySelector("#pane .bk-plan").innerText') -match 'ModD') 'backups: plan names ModB off and ModD on'
    Shot 'ui-backups.jpg'
    [void](Click '#pane [data-act="bk-restore"]')
    [void](WaitJs '!document.getElementById("modal").hidden'); [void](Click '#modal [data-m="1"]'); [void](WaitJobs)
    $s = Api '/api/state'
    Check ([bool]($s.mods | Where-Object name -eq 'ModD') -and [bool]($s.disabled | Where-Object name -eq 'ModB')) 'backups: went back (ModD on, ModB off)'

    [void](Click '#pane [data-act="bk-tab"][data-v="saves"]'); Start-Sleep -Milliseconds 500
    $before = Js 'document.querySelectorAll("#pane .bk-row").length'
    [void](Click '#pane [data-act="bk-saves-now"]'); [void](WaitJobs)
    Check ([bool](WaitJs "document.querySelectorAll('#pane .bk-row').length === $($before + 1)" 12000)) 'saves: copy now adds a row'
    'changed' | Set-Content "$sv\ManualSave-2\sav.dat" -NoNewline
    [void](Js '[...document.querySelectorAll("#pane [data-act=bk-saves-restore]")].pop().click()')
    Check ([bool](WaitJs 'document.querySelectorAll("#modal [data-pick]").length === 3')) 'saves: restore dialog lists the saves'
    Shot 'ui-saves.jpg'
    [void](Click '#modal .btn.primary'); [void](WaitJobs)
    Check ((Get-Content "$sv\ManualSave-2\sav.dat" -Raw) -eq 'save2') 'saves: restored from the oldest copy'

    [void](Click '#pane [data-act="bk-tab"][data-v="settings"]'); Start-Sleep -Milliseconds 500
    $set = "$g\bin\x64\plugins\cyber_engine_tweaks\mods\ModF\settings.json"
    '{"setting":99}' | Set-Content $set -NoNewline
    [void](Js '[...document.querySelectorAll("#pane [data-act=bk-set-restore]")].pop().click()')
    [void](WaitJs '!document.getElementById("modal").hidden'); [void](Click '#modal [data-m="1"]'); Start-Sleep -Milliseconds 1500
    Check ((Get-Content $set -Raw) -eq '{"setting":1}') 'mod settings: restored'

    [void](Click '[data-act="lib-more"]'); [void](Click '#menu [data-tool="keys"]')
    Check ([bool](WaitJs 'document.querySelector("#pane #keyrows")')) 'keys: pane opens'
    [void](Click '#pane [data-act="keys-filter"][data-v="all"]'); Start-Sleep -Milliseconds 300
    Check ((Js 'document.querySelectorAll("#pane .key-row").length') -gt 10) 'keys: game keys listed'
    [void](Js '(() => { const i = document.getElementById("keys-q"); i.focus(); i.value = "Space"; i.dispatchEvent(new Event("input", { bubbles: true })); })()'); Start-Sleep -Milliseconds 300
    Check ((Js 'document.querySelectorAll("#pane .key-row").length') -ge 1 -and (Js 'document.activeElement.id') -eq 'keys-q') 'keys: search filters and keeps focus'
    Shot 'ui-keys.jpg'

    [void](Click '#nav [data-page="compat"]')
    Check ([bool](WaitJs 'document.querySelector("#page .lo-card")' 30000)) 'compat: load order changes listed'
    [void](Click '#page [data-act="lo-undo"]')
    Check ([bool](WaitJs '!document.querySelector("#page .lo-card") && document.querySelector("#page .issue, #page .callout")' 30000)) 'compat: undo removes the change'
    Check ((Test-Path "$g\archive\pc\mod\mmm.archive") -and -not (Test-Path "$g\archive\pc\mod\!mmm.archive")) 'compat: archive has its own name again'

    [void](Click '[data-act="play-menu"]'); [void](Click '#menu [data-act="vanilla-start"]')
    [void](WaitJs '!document.getElementById("modal").hidden'); [void](Click '#modal [data-m="1"]'); [void](WaitJobs)
    $j = (Api '/api/state').jobs | Where-Object { $_.kind -eq 'vanilla' } | Select-Object -First 1
    Check ($j.status -eq 'error' -and $j.error -like '*put back*') "vanilla: launch failure puts mods back ($($j.error))"
    Check ((Test-Path "$g\archive\pc\mod") -and -not (Test-Path "$g\_cpmods_vanilla") -and -not (Test-Path "$Sb\state\vanilla.json")) 'vanilla: nothing left set aside'
    $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"
    pwsh -NoProfile -Command "Import-Module '$Sb\lib\cpmods.psm1' -DisableNameChecking; Import-Module '$Sb\lib\cpinsight.psm1' -DisableNameChecking; Import-Module '$Sb\lib\cpsafety.psm1' -DisableNameChecking; Set-CpContext 't' `$true; [void](Start-VanillaSession)" 2>&1 | Out-Null
    Check ([bool](WaitJs '/Playing without mods/.test(document.getElementById("banner").innerText)' 12000)) 'vanilla: banner while mods are set aside'
    Shot 'ui-vanilla.jpg'
    [void](Click '#banner [data-act="vanilla-back"]'); [void](WaitJobs)
    Check ((Test-Path "$g\archive\pc\mod") -and -not (Test-Path "$Sb\state\vanilla.json")) 'vanilla: bring back now'
    Check ([bool](WaitJs '!/Playing without mods/.test(document.getElementById("banner").innerText)' 12000)) 'vanilla: banner gone'

    Check (-not (Js '!!document.querySelector("[data-act=channel], [data-uiver], .beta-tag")') -and $null -eq (Api '/api/state').settings.uiChannel) 'single UI: no beta switch or setting'
    $errs = @(Get-CdpErrors)
    Check (-not $errs.Count) "no page errors $($errs -join ' || ')"
}
catch { $script:fails++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U1.W]::PostMessage([U1.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; 'dev server had to be stopped' } else { 'dev window closed, server exited' }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:fails)
}
