# Release channel (beta promoted) and the Discover search for parts of words
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'; $g = "$Sb\game"
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U6 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Api([string]$Path) { $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json; Invoke-RestMethod "http://localhost:$($j.port)$Path" -Headers @{ 'X-Cp-Token' = $j.token } }
function WaitJobs { Start-Sleep -Milliseconds 500; for ($i = 0; $i -lt 80; $i++) { if (-not @((Api '/api/state').jobs | Where-Object status -eq 'running').Count) { return }; Start-Sleep -Milliseconds 400 } }
$cfg = 'r6\config\inputUserMappings.xml'
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/downloads' })
    Check ([bool](WaitJs '/Needs your choice/.test(document.body.innerText)')) 'release: conflict card shows (the question no longer needs the beta)'
    Check ((Js 'document.querySelector(''link[rel=stylesheet]'').getAttribute("href")') -eq '/app.css' -and -not (Js 'document.querySelector(".beta-tag")')) 'release: own files, no beta tag'
    Check ((Js '/Try the beta/.test(document.querySelector(".side-links").innerText)') -eq $false) 'single UI: no beta link'
    Check ((Js '(async () => (await fetch("/beta/")).status)()') -eq 404) 'single UI: /beta/ is gone'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/discover' })
    [void](WaitJs 'document.getElementById("b-q")')
    [void](Js '(() => { const e = document.getElementById("b-q"); e.value = "misce"; e.dispatchEvent(new Event("input", { bubbles: true })); })()')
    Check ([bool](WaitJs '/Miscellaneous Settings Unlocker/.test(document.getElementById("page").innerText)' 20000)) 'search: "misce" finds Miscellaneous Settings Unlocker'
    [void](Js '(() => { const e = document.getElementById("b-q"); e.value = "misce*"; e.dispatchEvent(new Event("input", { bubbles: true })); })()'); Start-Sleep -Milliseconds 600
    Check ([bool](WaitJs '/Miscellaneous Settings Unlocker/.test(document.getElementById("page").innerText) && !/No mods match/.test(document.getElementById("page").innerText)' 20000)) 'search: "misce*" (with a star) too'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' | ')"
}catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U6.W]::PostMessage([U6.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
