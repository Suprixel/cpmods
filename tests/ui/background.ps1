# Library update check in the background + Game page box alignment (hidden -Dev window, sandbox copy, Nexus answers stubbed in the page)
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
$inst = {
    param($Sb, $n, $mid, $fid, $v)
    Import-Module "$Sb\lib\cpmods.psm1" -Force -DisableNameChecking; Set-CpContext 'uisb' $true
    $d = "$Sb\src\$n$fid"; New-Item -ItemType Directory -Force "$d\archive\pc\mod" | Out-Null; Set-Content "$d\archive\pc\mod\$n.archive" "$n $v" -NoNewline
    Compress-Archive "$d\*" "$Sb\downloads\$n$fid.zip" -Force
    Install-ModArchive "$Sb\downloads\$n$fid.zip" ([ordered]@{ name = $n; version = $v; source = "nexus:$mid/$fid"; modId = $mid; fileId = $fid; fileName = "$n main" }) | Out-Null
}
foreach ($x in @('UpA', 9101, 10), @('UpB', 9102, 20)) { pwsh -NoProfile -Command $inst -args $Sb, $x[0], $x[1], $x[2], '1' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U16 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function Q([string]$s) { ConvertTo-Json $s -Compress }
function Click([string]$Sel) { Js "(() => { const e = document.querySelector($(Q $Sel)); if (!e) return 'missing'; e.click(); return 'ok'; })()" }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -eq $true -or ($v -and "$v" -notlike 'JS ERROR*' -and $v -isnot [bool])) { return $v }; Start-Sleep -Milliseconds 200 }; $null }
function Yes([string]$Expr, [int]$Ms = 12000) { (WaitJs $Expr $Ms) -eq $true }
function Shot([string]$Name) { [void](Save-Shot (Join-Path ([IO.Path]::GetTempPath()) $Name) 0.6) }
# slow Nexus answers (1.5 s) so the check is visibly running while the page is used
$stub = @'
(() => { window.__gql = 0; const F = { m9101: [{ fileId: 10, name: 'UpA main', version: '1', category: 'OLD_VERSION', date: 1000 }, { fileId: 11, name: 'UpA main', version: '2', category: 'MAIN', date: 2000 }],
  m9102: [{ fileId: 20, name: 'UpB main', version: '1', category: 'MAIN', date: 1000 }, { fileId: 21, name: 'UpB main', version: '2', category: 'MAIN', date: 2000 }] };
  const real = window.fetch;
  window.fetch = (u, o) => /\/api\/gql/.test(String(u)) && o && /modFiles/.test(o.body) ? new Promise(r => { window.__gql++; setTimeout(() => r(new Response(JSON.stringify({ data: Object.fromEntries((JSON.parse(o.body).query.match(/m\d+(?=:)/g) || []).map(k => [k, F[k] || []])) }), { headers: { 'Content-Type': 'application/json' } })), 1500); }) : real(u, o); })();
'@
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' }); [void](WaitJs 'document.querySelector("#nav [data-page=library]")')
    [void](Js $stub)
    [void](Click '#nav [data-page=library]')
    Check (Yes '/Checking for updates/.test(document.getElementById("lib-sum").innerText) && document.querySelector("#page [data-act=lib-updates]").disabled' 3000) 'library: the check starts by itself and shows it is running'
    Check (Yes '!!document.querySelector("#lib-list [data-name=UpA]") && document.querySelector("[data-act=lib-filter].on").dataset.v === "all"' 2000) 'library: the list is usable while it runs'
    [void](Js 'document.getElementById("lib-q").focus()')
    Check (Yes '/2 updates available/.test(document.getElementById("lib-sum").innerText)' 15000) 'library: the result appears in the status line'
    Check (Yes 'document.querySelector("[data-act=lib-filter].on").dataset.v === "all" && ![...document.querySelectorAll(".toast")].some(t => /updates? available/.test(t.innerText))') 'library: the view stays on All and no toast pops up'
    Check (Yes '!document.querySelector("#page [data-act=lib-updates]").disabled && /v2 available/.test(document.querySelector("#lib-list [data-name=UpA]").innerText)') 'library: button ready again, rows show the update'
    $calls = Js 'window.__gql'
    [void](Click '#nav [data-page=game]'); [void](WaitJs '!!document.getElementById("g-backups")'); [void](Click '#nav [data-page=library]'); [void](WaitJs '!!document.querySelector("#lib-list .lib-row")')
    Start-Sleep -Milliseconds 800
    Check ((Js 'window.__gql') -eq $calls) "library: coming back within 30 minutes does not check again ($calls request(s))"
    [void](Click '#nav [data-page=game]'); [void](WaitJs '!!document.getElementById("g-backups")')
    foreach ($w in 1500, 1100) {
        [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = 1000; deviceScaleFactor = 1; mobile = $false }); Start-Sleep -Milliseconds 300
        $r = Js '(() => { const a = document.getElementById("g-launch").getBoundingClientRect(), b = document.getElementById("g-backups").getBoundingClientRect(); return [Math.round(a.top), Math.round(b.top), Math.round(a.height), Math.round(b.height), Math.round(a.left), Math.round(b.left)].join(","); })()'
        $v = "$r" -split ','
        $side = [int]$v[4] -ne [int]$v[5]
        Check ($(if ($side) { $v[0] -eq $v[1] -and $v[2] -eq $v[3] } else { [int]$v[1] - ([int]$v[0] + [int]$v[2]) -eq 16 })) "game page at $w px: boxes aligned (top a,b / height a,b / left a,b = $r)"
    }
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false }); Start-Sleep -Milliseconds 300
    Shot 'ui-game-aligned.jpg'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' || ')"
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U16.W]::PostMessage([U16.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
