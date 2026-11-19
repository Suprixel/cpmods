# A clean launch shows up while a job holds the install lock: the server must keep answering (its main loop never waits)
$sp = $PSScriptRoot; $Sb = Join-Path ([IO.Path]::GetTempPath()) 'cpmods-uisb'; $g = "$Sb\game"
pwsh -NoProfile -File "$sp\sandbox.ps1" -Sb $Sb | Out-Null; if ($LASTEXITCODE) { throw 'UI sandbox setup failed' }
. "$sp\cdp.ps1"
$script:devInfo = "$Sb\state\server-dev.json"
Add-Type -Namespace U8 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t);'
$env:CPMODS_CDP = '9339'; $env:CPMODS_SAVES = "$Sb\savedgames"; $env:CPMODS_CONFIG = "$Sb\gameconfig"; $env:CPMODS_NOLAUNCH = '1'
$p = Start-Process (Get-Command pwsh).Source -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Sb\server.ps1`"", '-Dev', '-Open' -WindowStyle Hidden -PassThru
$script:f = 0; $script:n = 0
function Check([bool]$Ok, [string]$Msg) { if ($Ok) { $script:n++; Write-Host "ok   $Msg" } else { $script:f++; Write-Host "FAIL $Msg" -ForegroundColor Red } }
function WaitJs([string]$Expr, [int]$Ms = 12000) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { $v = Js $Expr; if ($v -and "$v" -notlike 'JS ERROR*') { return $v }; Start-Sleep -Milliseconds 250 }; $null }
$clean = { @(if (Test-Path "$Sb\safety\points.json") { Get-Content "$Sb\safety\points.json" -Raw | ConvertFrom-Json | Where-Object kind -eq 'clean' }).Count }
$mtx = $null; $held = $false
try {
    Connect-Cdp 9339; [void](Invoke-Cdp 'Runtime.enable'); [void](Invoke-Cdp 'Page.enable')
    [void](Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = 'Object.defineProperty(document, "hidden", { get: () => false }); Object.defineProperty(document, "visibilityState", { get: () => "visible" });' })
    [void](Invoke-Cdp 'Page.navigate' @{ url = 'http://localhost:7078/#/library' })
    [void](WaitJs 'document.querySelector("#nav .nav-item")'); Start-Sleep -Seconds 9   # a few polls: the page holds the latest state
    $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json
    $mtx = [Threading.Mutex]::new($false, 'Local\cpmods'); $held = $mtx.WaitOne(10000)
    Check $held 'test holds the install lock (like a long job)'
    # a launch that closed normally appears (times after the setup, so its restore point is due)
    $t1 = (Get-Date).AddMinutes(1).ToString('yyyy-MM-dd HH:mm:ss.fff'); $t2 = (Get-Date).AddMinutes(2).ToString('yyyy-MM-dd HH:mm:ss.fff')
    New-Item -ItemType Directory -Force "$g\red4ext\logs" | Out-Null
    @("[$t1] [info] [1] [RED4ext] RED4ext (v1.31.1) is initializing", "[$t2] [info] [1] [RED4ext] RED4ext is shutting down", "[$t2] [info] [1] [RED4ext] RED4ext has been shut down") | Set-Content "$g\red4ext\logs\red4ext-test.log"
    $miss = 0
    foreach ($i in 1..16) { try { [void](Invoke-RestMethod "http://localhost:$($j.port)/api/ping" -Headers @{ 'X-Cp-Token' = $j.token } -TimeoutSec 2) } catch { $miss++ }; Start-Sleep -Milliseconds 700 }
    Check ($miss -eq 0) "server answered every check while the lock was held ($miss of 16 missed)"
    Check ((& $clean) -eq 0) 'no clean restore point yet (it waits for the lock in a worker)'
    $mtx.ReleaseMutex(); $held = $false
    $ok = $false; for ($i = 0; $i -lt 30 -and -not $ok; $i++) { Start-Sleep -Milliseconds 500; $ok = (& $clean) -eq 1 }
    Check $ok 'after the lock is free the clean restore point is saved, once'
}
catch { $script:f++; Write-Host "FAIL (stopped) $($_.Exception.Message)" -ForegroundColor Red }
finally {
    if ($held) { try { $mtx.ReleaseMutex() } catch { } }
    if ($mtx) { $mtx.Dispose() }
    try { $script:ws.Dispose() } catch { }
    [void][U8.W]::PostMessage([U8.W]::FindWindow([NullString]::Value, 'Cyberpunk Mods (dev)'), 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:n, $script:f)
}
