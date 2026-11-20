# Swaps the installed app folder for a new version once the old cpmods has quit, then starts the new one.
# Started by Start-CpUpdate (cpmods.psm1) from a copy outside both folders. A failed swap keeps the old version.
param([string]$From, [string]$To, [int]$WaitPid, [string]$Version, [string]$Log)
function Say([string]$M) { try { [IO.File]::AppendAllText($Log, ('{0:yyyy-MM-dd HH:mm:ss} [update] {1}{2}' -f (Get-Date), $M, [Environment]::NewLine)) } catch { } }
if ($WaitPid) { Wait-Process -Id $WaitPid -Timeout 120 -ErrorAction SilentlyContinue }
$old = "$To.old"
try {
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    # whole-folder renames: one complete version is in place at every moment; a virus scan may hold a file for a moment
    for ($i = 0; ; $i++) { try { [IO.Directory]::Move($To, $old); break } catch { if ($i -ge 20) { throw }; Start-Sleep -Milliseconds 500 } }
    try { [IO.Directory]::Move($From, $To) } catch { [IO.Directory]::Move($old, $To); throw }
    Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\cpmods'
    if ($Version -and (Test-Path -LiteralPath $k)) { Set-ItemProperty -LiteralPath $k -Name DisplayVersion -Value $Version }
    Say "Updated to $Version"
}
catch { Say "Update to $Version failed, the version you had stays: $($_.Exception.Message)" }
$exe = Join-Path $To 'cpmods.exe'
if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
