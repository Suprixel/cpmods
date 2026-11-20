# Removes an installed cpmods (Windows Settings, Apps): the app folder, its shortcuts, its Nexus link handler and its entry.
# Your mods stay in the game, and your mod list, downloads and backups stay in %LOCALAPPDATA%\cpmods.
$app = $PSScriptRoot
$data = Join-Path $env:LOCALAPPDATA 'cpmods'
Set-Location -LiteralPath $env:TEMP
Write-Host 'Removing cpmods...' -ForegroundColor Cyan
# an open cpmods quits first, so its folder can go
$i = try { Get-Content -LiteralPath (Join-Path $data 'state\server.json') -Raw | ConvertFrom-Json } catch { $null }
if ($i) {
    try { [void](Invoke-RestMethod -Method Post "http://localhost:$($i.port)/api/system" -Headers @{ 'X-Cp-Token' = "$($i.token)" } -ContentType 'application/json' -Body '{"op":"quit"}' -TimeoutSec 5) } catch { }
    for ($n = 0; $n -lt 30 -and (Get-Process -Id ([int]$i.pid) -ErrorAction SilentlyContinue); $n++) { Start-Sleep -Milliseconds 500 }
}
$ws = New-Object -ComObject WScript.Shell
foreach ($d in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    $l = Join-Path $d 'Cyberpunk Mods.lnk'
    if (-not (Test-Path -LiteralPath $l)) { continue }
    $s = $ws.CreateShortcut($l)
    if ("$($s.TargetPath) $($s.Arguments)".Contains($app, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $l -Force }
}
if ("$((Get-ItemProperty 'HKCU:\Software\Classes\nxm\shell\open\command' -ErrorAction SilentlyContinue).'(default)')".Contains($app, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item 'HKCU:\Software\Classes\nxm' -Recurse -Force }
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\cpmods' -Recurse -Force -ErrorAction SilentlyContinue
try { Remove-Item -LiteralPath $app -Recurse -Force; Write-Host 'cpmods is removed.' -ForegroundColor Green }
catch { Write-Host "Some files could not be removed ($($_.Exception.Message)). Delete $app by hand." -ForegroundColor Yellow }
Write-Host "Your mods stay in the game. Your mod list, downloads and backups stay in $data; delete that folder to remove them too."
Read-Host 'Press Enter to close' | Out-Null
