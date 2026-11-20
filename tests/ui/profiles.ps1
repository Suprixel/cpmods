# Profiles in the hidden -Dev window: save from the Library, switch back after a change; the old-downloads setting shows
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U11 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
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
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1500; height = 1000; deviceScaleFactor = 1; mobile = $false })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/library' }); [void](WaitJs 'document.querySelector("#page [data-tool=profiles]")')
    Check ((Js 'document.querySelector("#page [data-tool=profiles]").innerText.trim()') -eq 'Profiles') 'library: Profiles button'
    [void](Click '#page [data-tool=profiles]'); [void](WaitJs '!!document.getElementById("prof-name")')
    Check ([bool](Js '/No profiles yet/.test(document.getElementById("pane").innerText)')) 'pane: empty state explains profiles'
    [void](Js '(() => { const i = document.getElementById("prof-name"); i.value = "Story"; i.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); })()')
    Check ([bool](WaitJs '/Story/.test(document.getElementById("pane").innerText) && /In use/.test(document.getElementById("pane").innerText)')) 'pane: saved with Enter and shown as in use'
    Check ([bool](WaitJs 'document.querySelector("#page [data-tool=profiles]").innerText.trim() === "Profile: Story"')) 'library: the button names the profile in use'
    [void](Js '(() => { const e = document.querySelector("[data-toggle=ModE]"); e.checked = false; e.dispatchEvent(new Event("change", { bubbles: true })); })()'); WaitJobs
    Check ([bool](WaitJs 'document.querySelector("#page [data-tool=profiles]").innerText.trim() === "Profiles"')) 'library: after turning a mod off no profile is in use'
    [void](Click '#page [data-tool=profiles]'); [void](WaitJs '/Switching: 1 on/.test(document.getElementById("pane").innerText)')
    Check ([bool](Js '/Switching: 1 on/.test(document.getElementById("pane").innerText)')) 'pane: says what switching would change'
    Shot 'ui-profiles.jpg'
    [void](Click '#pane [data-act=prof-apply][data-name=Story]'); [void](WaitJs '!document.getElementById("modal").hidden')
    Check ([bool](Js '/ModE/.test(document.getElementById("modal").innerText)')) 'switch: the confirmation lists the mod turned back on'
    [void](Click '#modal [data-m="1"]'); WaitJobs
    Check ([bool]((Api '/api/state').mods | Where-Object name -eq 'ModE') -and (Api '/api/state').profile -eq 'Story') 'switch: ModE is back on and Story is in use'
    Check ([bool](WaitJs '/In use/.test(document.getElementById("pane").innerText)')) 'pane: refreshed after the switch'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' }); [void](WaitJs 'document.querySelectorAll(".sx").length === 8')
    Check ([bool](Js '!!document.querySelector("[data-setting=pruneOld]") && document.querySelector("[data-setting=pruneOld]").checked')) 'settings: old downloads switch, on by default'
    Check (-not @(Get-CdpErrors).Count) "no page errors $(@(Get-CdpErrors) -join ' || ')"
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U11.W]::PostMessage([U11.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
