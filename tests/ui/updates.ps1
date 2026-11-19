# Batch updates in the hidden -Dev window on a sandbox copy (fake game folder; Nexus answers stubbed in the page; links logged, never opened)
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
$lib = "$Sb\lib\cpmods.psm1"
[IO.File]::WriteAllText($lib, [IO.File]::ReadAllText($lib).Replace('function Open-UrlInFront([string]$Url) {', 'function Open-UrlInFront([string]$Url) { Add-Content -LiteralPath (Join-Path $script:Root ''opened.txt'') $Url; return $true'))
$inst = {
    param($Sb, $n, $mid, $fid, $v)
    Import-Module "$Sb\lib\cpmods.psm1" -Force -DisableNameChecking; Set-CpContext 'uisb' $true
    $d = "$Sb\src\$n$fid"; New-Item -ItemType Directory -Force "$d\archive\pc\mod" | Out-Null; Set-Content "$d\archive\pc\mod\$n.archive" "$n $v" -NoNewline
    Compress-Archive "$d\*" "$Sb\downloads\$n$fid.zip" -Force
    Install-ModArchive "$Sb\downloads\$n$fid.zip" ([ordered]@{ name = $n; version = $v; source = "nexus:$mid/$fid"; modId = $mid; fileId = $fid; fileName = "$n main" }) | Out-Null
}
foreach ($x in @('UpA', 9101, 10), @('UpB', 9102, 20), @('UpC', 9103, 30)) { pwsh -NoProfile -Command $inst -args $Sb, $x[0], $x[1], $x[2], '1' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U13 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function Q([string]$s) { ConvertTo-Json $s -Compress }
function Click([string]$Sel) { Js "(() => { const e = document.querySelector($(Q $Sel)); if (!e) return 'missing'; e.click(); return 'ok'; })()" }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Api([string]$Path) { $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json; Invoke-RestMethod "http://localhost:$($j.port)$Path" -Headers @{ 'X-Cp-Token' = $j.token } }
function Shot([string]$Name) { [void](Save-Shot (Join-Path ([IO.Path]::GetTempPath()) $Name) 0.6) }
function Tick([string]$Sel, [bool]$On) { [void](Js "(() => { const c = document.querySelector($(Q $Sel)); c.checked = $(if ($On) { 'true' } else { 'false' }); c.dispatchEvent(new Event('change', { bubbles: true })); })()") }
$bar = '(document.querySelector("#lib-list .action-card") ? document.querySelector("#lib-list .action-card").innerText : "")'
function BarHas([string]$Rx, [string]$More = 'true') {
    $e = "/$Rx/.test($bar) && $More"
    $ok = [bool](WaitJs $e 8000)
    if (-not $ok) { Write-Host "  bar text: [$(Js $bar)] expr result: [$(Js $e)] js sent: [$bar] list starts: [$(Js 'document.querySelector("#lib-list").innerHTML.slice(0, 160)')]" -ForegroundColor Yellow }
    $ok
}
# Nexus files per mod: UpA and UpB have a newer main file, UpC is current
$stub = @'
(() => { const F = { m9101: [{ fileId: 10, name: 'UpA main', version: '1', category: 'OLD_VERSION', date: 1000 }, { fileId: 11, name: 'UpA main', version: '2', category: 'MAIN', date: 2000 }],
  m9102: [{ fileId: 20, name: 'UpB main', version: '1', category: 'MAIN', date: 1000 }, { fileId: 21, name: 'UpB main', version: '2', category: 'MAIN', date: 2000 }],
  m9103: [{ fileId: 30, name: 'UpC main', version: '1', category: 'MAIN', date: 1000 }] };
  const real = window.fetch;
  window.fetch = (u, o) => /\/api\/gql/.test(String(u)) && o && /modFiles/.test(o.body) ? Promise.resolve(new Response(JSON.stringify({ data: Object.fromEntries((JSON.parse(o.body).query.match(/m\d+(?=:)/g) || []).map(k => [k, F[k] || []])) }), { headers: { 'Content-Type': 'application/json' } })) : real(u, o); })();
'@
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' + $stub })
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false })
    # the stub goes in before the Library opens: opening it starts a background check
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' }); [void](WaitJs 'document.querySelector("#nav [data-page=library]")')
    [void](Js $stub)
    Check ((Js 'String(window.fetch).includes("modFiles")') -eq $true) 'setup: Nexus answers stubbed in the page'
    [void](Click '#nav [data-page=library]'); [void](WaitJs '!!document.querySelector("#page [data-act=lib-updates]") && !document.querySelector("#page [data-act=lib-updates]").disabled')
    [void](Click '#page [data-act=lib-updates]')
    Check (BarHas '2 of 2 updates selected') 'check: Updates view with a bar, both updates selected'
    Check ((Js '!!document.querySelector("[data-act=upd-batch]") && /Update all/.test(document.querySelector("[data-act=upd-batch]").innerText) && document.querySelectorAll("#lib-list [data-usel]").length === 2 && !document.querySelector("#lib-list [data-usel=UpC]")') -eq $true) 'check: one checkbox per update, Update all button'
    Tick '#lib-list [data-usel=UpB]' $false
    Check (BarHas '1 of 2 updates selected' '/Update 1 selected/.test(document.querySelector("[data-act=upd-batch]").innerText) && !document.getElementById("upd-all").checked') 'select: unticking UpB updates the count and the button'
    Tick '#upd-all' $true
    Check (BarHas '2 of 2') 'select: the all box ticks every update'
    Tick '#upd-all' $false
    Check (BarHas '0 of 2' 'document.querySelector("[data-act=upd-batch]").disabled') 'select: nothing ticked -> button off'
    Tick '#lib-list [data-usel=UpA]' $true
    Shot 'ui-updates-bar.jpg'
    [void](Click '[data-act=upd-batch]'); [void](WaitJs '!document.getElementById("modal").hidden')
    $mt = Js 'document.getElementById("modal").innerText'
    Check ($mt -match 'Update 1 mod' -and $mt -match 'UpA: 1 to 2' -and $mt -notmatch 'UpB') "confirm: lists only the ticked update"
    Shot 'ui-updates-confirm.jpg'
    [void](Click '#modal [data-m="1"]')
    [void](WaitJs '[...document.querySelectorAll(".toast")].some(t => /Queue started/.test(t.innerText))')
    $st = Api '/api/state'; $q = @($st.queue | Where-Object { -not $_.done })
    Check ((@($q | ForEach-Object { "$($_.fileId)=$($_.name)" }) -join ',') -eq '11=UpA') "apply: queue holds UpA's new file under its name: $(($q | ForEach-Object { "$($_.fileId)=$($_.name)" }) -join ', ')"
    Check (@((Api '/api/backups').points | Where-Object label -eq 'Before updating 1 mod').Count -eq 1) 'apply: restore point made first'
    Check ((Get-Content "$Sb\opened.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -match 'mods/9101\?tab=files&file_id=11') 'apply: the first Nexus page was requested (logged, not opened)'
    Check (BarHas '0 of 1 update selected' '/v2 queued/.test(document.querySelector("#lib-list").innerText) && !document.querySelector("#lib-list [data-usel=UpA]")') 'after: UpA shows as queued and leaves the batch'
    # the download arrives and installs: UpA is on the new file and no longer listed as an update
    pwsh -NoProfile -Command $inst -args $Sb, 'UpA', 9101, 11, '2'
    Check ([bool](WaitJs '!/UpA/.test(document.querySelector("#lib-list").innerText) && /1 update available/.test(document.getElementById("lib-sum").innerText)' 20000)) 'after install: UpA drops out of Updates'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' || ')"
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U13.W]::PostMessage([U13.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
