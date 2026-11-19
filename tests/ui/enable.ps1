# Turning a mod back on asks when another mod has its file now (server job end to end, hidden dev window)
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'; $g = "$Sb\game"
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U7 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
function Api([string]$Path, $Body) {
    for ($i = 0; $i -lt 40 -and -not (Test-Path $script:devInfo); $i++) { Start-Sleep -Milliseconds 250 }
    $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json; $h = @{ 'X-Cp-Token' = $j.token }
    if ($null -eq $Body) { Invoke-RestMethod "http://localhost:$($j.port)$Path" -Headers $h }
    else { Invoke-RestMethod -Method Post "http://localhost:$($j.port)$Path" -Headers $h -ContentType 'application/json' -Body (ConvertTo-Json $Body) }
}
function WaitJobs { Start-Sleep -Milliseconds 500; for ($i = 0; $i -lt 80; $i++) { if (-not @((Api '/api/state').jobs | Where-Object status -eq 'running').Count) { return }; Start-Sleep -Milliseconds 400 } }
$cfg = Join-Path $g 'r6\config\inputUserMappings.xml'
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Api '/api/action' @{ op = 'disable'; name = 'ModA' }); WaitJobs
    [void](Api '/api/action' @{ op = 'install'; archive = 'ModB.zip'; name = ''; sub = ''; conflict = '' }); WaitJobs
    Check ((Get-Content $cfg -Raw) -eq 'B' -and ((Api '/api/state').mods | Where-Object name -eq 'ModB')) 'setup: A off, B installed its copy'
    [void](Api '/api/action' @{ op = 'enable'; name = 'ModA' }); WaitJobs
    $st = Api '/api/state'
    $job = @($st.jobs | Where-Object { $_.kind -eq 'enable' -and $_.title -like '*ModA' })[0]
    Check ($job.status -eq 'done' -and $job.detail -like '*waiting for your choice*') "enable job waits for a choice: $($job.status) $($job.detail) $($job.error)"
    Check ((Get-Content $cfg -Raw) -eq 'B' -and ($st.disabled | Where-Object name -eq 'ModA') -and ($st.pending | Where-Object { $_.name -eq 'ModA' -and @($_.conflict).Count })) 'nothing changed; A is off and waiting with the conflict'
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/downloads' })
    Check ([bool](WaitJs '/Needs your choice/.test(document.body.innerText) && /ModA/.test(document.body.innerText)')) 'the choice card shows ModA'
    [void](Api '/api/action' @{ op = 'install'; archive = 'ModA.zip'; name = ''; sub = ''; conflict = 'overwrite' }); WaitJobs
    $st = Api '/api/state'
    Check ((Get-Content $cfg -Raw) -eq 'A' -and ($st.mods | Where-Object name -eq 'ModA') -and -not ($st.disabled | Where-Object name -eq 'ModA') -and -not ($st.pending | Where-Object name -eq 'ModA')) 'choosing "use the new copy" turns A on (no longer off or waiting)'
    [void](Api '/api/action' @{ op = 'enable'; name = 'ModD' }); WaitJobs
    $job = @((Api '/api/state').jobs | Where-Object { $_.kind -eq 'enable' -and $_.title -like '*ModD' })[0]
    Check ($job.detail -eq 'Enabled ModD' -and ((Api '/api/state').mods | Where-Object name -eq 'ModD')) "no shared file: turns on at once ($($job.detail))"
    Check (-not @(Get-CdpErrors).Count) 'no page errors'
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    try { $script:ws.Dispose() } catch { }
    [void][U7.W]::PostMessage([U7.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
