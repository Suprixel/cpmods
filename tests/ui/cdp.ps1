# Minimal CDP client for the -Dev built-in window (dot-source). Js 'expr' evaluates in the page.
$script:cdpId = 0; $script:pending = $null; $script:events = [Collections.Generic.List[object]]::new()
function Connect-Cdp([int]$Port = 9339) {
    $t = $null
    for ($i = 0; $i -lt 60 -and -not $t; $i++) {
        try { $t = Invoke-RestMethod "http://localhost:$Port/json" -TimeoutSec 2 | Where-Object { $_.type -eq 'page' -and $_.url -match 'localhost:7078' } | Select-Object -First 1 } catch { }
        if (-not $t) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $t) { throw 'no CDP page' }
    # the debug port listens on 127.0.0.1 only ("localhost" may try IPv6 first), and a fresh window can take ~20 s to accept
    $url = [Uri]("$($t.webSocketDebuggerUrl)" -replace '^ws://localhost:', 'ws://127.0.0.1:')
    for ($i = 0; ; $i++) {
        try { $script:ws = [Net.WebSockets.ClientWebSocket]::new(); $script:ws.ConnectAsync($url, [Threading.CancellationToken]::None).Wait(); break }
        catch { $script:ws.Dispose(); if ($i -ge 30) { throw }; Start-Sleep -Milliseconds 700 }
    }
}
function Receive-Cdp([int]$Ms) {
    $buf = [IO.MemoryStream]::new()
    while ($true) {
        if (-not $script:pending) { $script:seg = [ArraySegment[byte]]::new([byte[]]::new(262144)); $script:pending = $script:ws.ReceiveAsync($script:seg, [Threading.CancellationToken]::None) }
        if (-not $script:pending.Wait($Ms)) { if ($buf.Length -eq 0) { return $null } else { continue } }
        $r = $script:pending.Result; $script:pending = $null
        $buf.Write($script:seg.Array, 0, $r.Count)
        if ($r.EndOfMessage) { return ([Text.Encoding]::UTF8.GetString($buf.ToArray()) | ConvertFrom-Json -Depth 60) }
    }
}
function Invoke-Cdp([string]$Method, $Params = @{}, [int]$TimeoutMs = 30000) {
    $script:cdpId++; $id = $script:cdpId
    $b = [Text.Encoding]::UTF8.GetBytes((@{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress))
    $script:ws.SendAsync([ArraySegment[byte]]::new($b), 'Text', $true, [Threading.CancellationToken]::None).Wait()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $m = Receive-Cdp 500
        if (-not $m) { continue }
        if ($m.id -eq $id) { return $m }
        if ($m.method) { $script:events.Add($m) }
    }
    throw "CDP timeout: $Method"
}
function Js([string]$Expr) {
    $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = $Expr; returnByValue = $true; awaitPromise = $true }
    if ($r.result.exceptionDetails) { return 'JS ERROR: ' + $r.result.exceptionDetails.exception.description }
    $r.result.result.value
}
function Get-CdpErrors {
    while ($m = Receive-Cdp 200) { if ($m.method) { $script:events.Add($m) } }
    $script:events | Where-Object { $_.method -eq 'Runtime.exceptionThrown' -or ($_.method -eq 'Runtime.consoleAPICalled' -and $_.params.type -eq 'error') } | ForEach-Object {
        if ($_.params.exceptionDetails) { $_.params.exceptionDetails.exception.description } else { ($_.params.args | ForEach-Object { $_.value }) -join ' ' }
    }
}
function Save-Shot([string]$Path, [double]$Scale = 0.5) {
    $m = Js '({w: innerWidth, h: innerHeight})'
    $r = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'jpeg'; quality = 70; clip = @{ x = 0; y = 0; width = $m.w; height = $m.h; scale = $Scale } }
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($r.result.data)); $Path
}
function Get-DevPerf {
    $j = Get-Content $script:devInfo -Raw | ConvertFrom-Json
    Invoke-RestMethod "http://localhost:$($j.port)/api/perf" -Headers @{ 'X-Cp-Token' = $j.token }
}

