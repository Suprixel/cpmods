# Compatibility page, Library crash warning, both winner choices, Reports "Turn off" per mod: hidden -Dev window on a sandbox copy.
# /api/compat and /api/launch are answered in the page; the load order clicks run for real on the sandbox files.
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U15 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function Q([string]$s) { ConvertTo-Json $s -Compress }
function Click([string]$Sel) { Js "(() => { const e = document.querySelector($(Q $Sel)); if (!e) return 'missing'; e.click(); return 'ok'; })()" }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -eq $true -or ($v -and "$v" -notlike 'JS ERROR*' -and $v -isnot [bool])) { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Yes([string]$Expr, [int]$Ms = 12000) { (WaitJs $Expr $Ms) -eq $true }
function Shot([string]$Name) { [void](Save-Shot (Join-Path ([IO.Path]::GetTempPath()) $Name) 0.6) }
# ModE (sandbox) gets a crash-capable problem; ModA (aaa.archive) and ModD (zzz.archive) overlap, ModA wins now; ModB/ModE overlap already settled
$stub = @'
(() => {
  const compat = { checked: new Date().toISOString(), mods: 5, archives: 3, assets: 10, loadOrder: [], issues: [
    { kind: 'requirement', risk: 'high', mods: ['ModE'], title: 'ModE needs SomeFramework', why: ['It is missing.'], key: 'requirement|ModE|1' },
    { kind: 'archive', risk: 'low', mods: ['ModE', 'ModA'], files: ['!mmm.archive', 'aaa.archive'], winner: 'ModE', chosen: null, title: 'ModE and ModA change the same game assets', why: ['2 shared assets.'], key: 'archive|ModA|ModE|' },
    { kind: 'archive', risk: 'ok', mods: ['ModF', 'ModE'], files: ['fff.archive', 'mmm.archive'], winner: 'ModF', chosen: 'ModF', title: 'ModF and ModE change the same game assets', why: ['You chose ModF to win.'], key: 'archive|ModE|ModF|' },
    { kind: 'script', risk: 'medium', mods: ['ModA', 'ModF'], title: 'ModA and ModF replace the same script function', why: ['Only one is used.'], key: 'script|ModA|ModF|' }] };
  const launch = { checked: new Date().toISOString(), none: false, session: { start: new Date(Date.now() - 3600e3).toISOString(), end: new Date().toISOString(), seconds: 1100, result: 'clean', product: '2.50', red4ext: '1.31.1' },
    stages: [{ key: 'end', title: 'Closed normally', status: 'ok', detail: 'After 18 min' }], mods: [], crashes: [], history: [], untested: [],
    issues: [{ level: 'warn', kind: 'mod', title: 'Check ModA', detail: 'redscript: replaces a method another mod replaces', msg: 'replaces a method', mods: ['ModA'], links: [{ mod: 'ModE', why: 'also replaces Foo.Bar; only one of the two is used' }, { mod: 'ModD', why: 'turned off, so no button' }] }] };
  const real = window.fetch;
  window.__compatCalls = window.__compatCalls || 0;
  window.fetch = (u, o) => { const s = String(u), getCompat = /\/api\/compat$/.test(s) && !(o && o.method === 'POST');
    if (getCompat) { window.__compatCalls++; if (window.__compatFail) return Promise.resolve(new Response(JSON.stringify({ error: 'Nexus did not answer' }), { status: 500, headers: { 'Content-Type': 'application/json' } })); }
    const j = getCompat ? compat : /\/api\/launch/.test(s) ? launch : null;
    return j ? Promise.resolve(new Response(JSON.stringify(j), { headers: { 'Content-Type': 'application/json' } })) : real(u, o); };
})();
'@
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' }); [void](WaitJs 'document.querySelector("#nav [data-page=compat]")')
    [void](Js "window.__compatFail = true; $stub")
    Check (Yes '!!document.querySelector("#nav [data-page=compat]") && /Compatibility/.test(document.querySelector("#nav [data-page=compat]").innerText)') 'nav: Compatibility page in the sidebar'
    # a failed check shows its error and waits for Run again (it used to retry itself in a loop)
    [void](Click '#nav [data-page=compat]')
    Check (Yes '/Nexus did not answer/.test(document.getElementById("page").innerText)') 'compat: a failed check shows why'
    Start-Sleep -Seconds 4
    Check ((Js 'window.__compatCalls') -eq 1) "compat: a failed check is not retried by itself ($(Js 'window.__compatCalls') call(s) in 4 s)"
    [void](Js 'window.__compatFail = false'); [void](Click '[data-act=compat-run]')
    Check (Yes '!!document.querySelector(".issue")') 'compat: Run again loads it'
    [void](Click '#nav [data-page=settings]'); [void](WaitJs '!!document.querySelector(".sx")')
    [void](Click '#nav [data-page=library]'); [void](WaitJs 'document.querySelector("#lib-list .lib-row")')
    Check (Yes '!document.querySelector("#page [data-tool=compat]") && !document.querySelector("[data-act=lib-filter][data-v=issues]")') 'library: no Compatibility button, no Conflicts filter'
    Check (Yes '/1 problem that can crash the game/.test(document.getElementById("lib-sum").innerText)') 'library: one line about what can crash'
    Check (Yes '/May crash/.test(document.querySelector("#lib-list [data-name=ModE]").innerText) && !/May crash|conflict/i.test(document.querySelector("#lib-list [data-name=ModA]").innerText)') 'library: May crash only on ModE; no conflict pill on ModA (it has two other conflicts)'
    Check (Yes '/1/.test((document.querySelector("#nav [data-page=compat] .nav-count") || {}).innerText || "")') 'nav: the crash count shows on Compatibility'
    Shot 'ui-compat-library.jpg'
    [void](Click '#lib-sum [data-page=compat]'); [void](WaitJs 'location.hash === "#/compat" && !!document.querySelector(".issue")')
    $acts = Js '[...document.querySelectorAll(".issue")].find(x => /ModE and ModA/.test(x.innerText)).querySelector(".issue-acts").innerText'
    Check ($acts -match 'Let ModE win' -and $acts -match 'Let ModA win' -and $acts -match 'Mark as fine') "page: both winners offered: $($acts -replace '\s+', ' ')"
    [void](Js 'document.querySelectorAll("details.risk-group").forEach(d => d.open = true)')
    Check (Yes '/ModF wins, your choice/.test([...document.querySelectorAll(".issue")].find(x => /ModF and ModE/.test(x.innerText)).innerText)') 'page: a settled overlap shows the choice'
    # a group you opened stays open: after an app state change (a mod turned off) and after Mark as fine redraws the page
    $grp = 'document.querySelector("details[data-grp=\"Intended overlaps and your choices\"]")'
    [void](Js "fetch('/api/action', { method: 'POST', headers: { 'X-Cp-Token': window.CP_TOKEN, 'Content-Type': 'application/json' }, body: JSON.stringify({ op: 'disable', name: 'ModF' }) })")
    Check (Yes "!!(document.querySelector('.toast') && [...document.querySelectorAll('.toast')].some(t => /Disable ModF/.test(t.innerText)))" 15000) 'state change: the job finished (toast)'
    Check (Yes "$grp && $grp.open") 'compat: the opened group is still open after a state change'
    [void](Js '[...document.querySelectorAll("[data-act=compat-ignore]")].find(b => /Mark as fine/.test(b.innerText)).click()')
    Check (Yes "[...document.querySelectorAll('.toast')].some(t => /Marked as fine/.test(t.innerText)) && $grp && $grp.open") 'compat: still open after Mark as fine redraws the page'
    Shot 'ui-compat-page.jpg'
    [void](Js '[...document.querySelectorAll("[data-act=lo-win]")].find(b => /Let ModE win/.test(b.innerText)).click()')
    Check (Yes '[...document.querySelectorAll(".toast")].some(t => /ModE wins, as you chose/.test(t.innerText) && /already loads first/.test(t.innerText))') 'choose the current winner: toast says nothing was renamed'
    $lo = Get-Content "$Sb\state\loadorder.json" -Raw | ConvertFrom-Json -AsHashtable
    Check ((Test-Path "$Sb\game\archive\pc\mod\!mmm.archive") -and (@($lo['mmm.archive'].over) -join ',') -eq 'aaa.archive') 'choose the current winner: file kept, choice recorded once'
    [void](WaitJs '!!document.querySelector("[data-act=lo-win]")')
    [void](Js '[...document.querySelectorAll("[data-act=lo-win]")].find(b => /Let ModA win/.test(b.innerText)).click()')
    Check (Yes '[...document.querySelectorAll(".toast")].some(t => /ModA wins, as you chose/.test(t.innerText) && /!aaa.archive/.test(t.innerText))') 'choose the other one: it is renamed to win'
    Check ((Test-Path "$Sb\game\archive\pc\mod\!aaa.archive") -and -not (Test-Path "$Sb\game\archive\pc\mod\aaa.archive")) 'choose the other one: !aaa.archive on disk'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/library/tool/compat' }); [void](Js $stub)
    Check (Yes 'location.hash === "#/compat"') 'old link #/library/tool/compat opens the page'
    [void](Js $stub)
    [void](Click '#nav [data-page=reports]')
    Check (Yes '/Turn off ModA/.test(document.getElementById("page").innerText) && /Turn off ModE/.test(document.getElementById("page").innerText) && !/Turn off ModD/.test(document.getElementById("page").innerText)') 'reports: a turn-off for each mod involved that is on'
    Shot 'ui-compat-reports.jpg'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' || ')"
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U15.W]::PostMessage([U15.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
