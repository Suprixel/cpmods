# Question turned off: waiting conflicts become ordinary waiting installs, newest wins, older copy kept underneath
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'; $g = "$Sb\game"
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U5 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
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
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/settings' })
    [void](WaitJs 'document.querySelector("[data-setting=askOverwrite]")')
    Check ((Js 'document.querySelector("#sx-downloads .sx-body").innerText') -match 'Ask when two mods have the same file') 'setting has the new wording'
    [void](Js '(() => { const e = document.querySelector("[data-setting=askOverwrite]"); e.checked = false; e.dispatchEvent(new Event("change", { bubbles: true })); })()')
    Check ([bool](WaitJs '/last installed mod wins shared files/.test(document.querySelector("#sx-downloads .sx-t span").textContent)')) 'switched off: header says the last installed mod wins'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/downloads' })
    [void](WaitJs '/Waiting to install/.test(document.body.innerText)')
    Check (-not (Js '/Needs your choice/.test(document.body.innerText)') -and -not (Js '/need your choice/i.test(document.getElementById("activity").innerText)')) 'no "needs your choice" card or pill'
    Check ((Js '/ModB/.test([...document.querySelectorAll(".card")].find(c => /Waiting to install/.test(c.innerText)).innerText)') -eq $true) 'ModB is listed as waiting to install'
    [void](Js '[...document.querySelectorAll(''[data-act="fw-sync"]'')].pop().click()'); WaitJobs
    Check ([bool]((Api '/api/state').mods | Where-Object name -eq 'ModB')) 'Install now installed ModB'
    Check ((Get-Content (Join-Path $g $cfg) -Raw) -eq 'B') 'the mod installed last is used for the shared file'
    Check ((Get-Content "$Sb\backup\ModB\$cfg" -Raw) -eq 'A') 'the other mod''s copy is kept underneath'
    pwsh -NoProfile -Command "Import-Module '$Sb\lib\cpmods.psm1' -DisableNameChecking; Set-CpContext 't' `$true; Remove-InstalledMod 'ModB'" | Out-Null
    Check ((Get-Content (Join-Path $g $cfg) -Raw) -eq 'A') 'removing the newer mod brings the other copy back'
    Check (-not @(Get-CdpErrors).Count) 'no page errors'
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U5.W]::PostMessage([U5.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
