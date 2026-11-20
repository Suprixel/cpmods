# cpmods CLI. GUI: cpmods ui (or the "Cyberpunk Mods" shortcut)
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Arg,
    [string]$Name,
    [string]$Version,
    [string]$Sub,
    [switch]$Force,
    [switch]$Purge,
    [switch]$Inline
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\cpmods.psm1') -Force -DisableNameChecking
$cmd = $Command.ToLower()
Set-CpContext $cmd $false
if ($cmd -ne 'nxm') { $ProgressPreference = 'SilentlyContinue' }

# Hands an nxm link to the running app; $false when no server answers
function Send-ToServer([string]$Url) {
    $info = Get-ServerInfo
    if (-not $info) { return $false }
    try {
        Invoke-RestMethod -Method Post -Uri "http://localhost:$($info.port)/api/nxm" -Headers @{ 'X-Cp-Token' = $info.token } -ContentType 'application/json' -Body (ConvertTo-Json @{ url = $Url }) -TimeoutSec 5 | Out-Null
        $true
    }
    catch { $false }
}

function Invoke-InlineNxm([string]$Url) {
    $st = @{ queued = $false }
    $cb = { param($l) $st.queued = Set-QueueItemDone $l.modId $l.fileId }.GetNewClosure()
    $res = Invoke-NxmDownload -Url $Url -OnLinkReady $cb
    $r = Complete-NexusDownload $res.archive $res.meta
    Write-Note "$($res.meta.name): $r" Green
    if ($st.queued -and (Get-CpSettings).autoNext) { [void](Open-NextQueue) }
}

function Show-Status {
    $g = Get-GameState
    $s = Get-State
    $upd = if ($g.updatePending) { "  UPDATE PENDING -> build $($g.target)" } else { '' }
    Write-Host "Game $($g.version) (build $($g.build))$upd"
    Write-Host ("Nexus key: {0}   nxm handler: {1}" -f $(if (Test-NexusKey) { 'set' } else { 'NOT SET (cpmods setkey)' }), $(if (Test-NxmHandler) { 'cpmods' } else { 'not registered' }))
    Write-Host "`nInstalled ($($s.mods.Count)):"
    $s.mods | ForEach-Object { [pscustomobject]@{ Name = $_.name; Version = $_.version; Source = $_.source; Files = @($_.files).Count } } | Format-Table -AutoSize | Out-String | Write-Host
    if ($s.disabled.Count) { Write-Host "Disabled: $(($s.disabled | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor DarkGray }
    if ($s.pending.Count) { Write-Host "Waiting to install: $(($s.pending | ForEach-Object { $_.meta.name }) -join ', ')" -ForegroundColor Yellow }
    foreach ($f in $s.failed) { Write-Host "Needs attention: $($f.meta.name): $($f.error)" -ForegroundColor Red }
    $q = Get-Queue
    Write-Host "Nexus queue: $(@($q | Where-Object { -not $_.done }).Count) of $($q.Count) left"
}

try {
    switch ($cmd) {
        'status' { Show-Status }
        'ui' { Start-CpServer -Open }
        'queue' { Get-Queue | ForEach-Object { [pscustomobject]@{ Done = [bool]$_.done; Name = $_.name; Mod = $_.modId; File = $_.fileId; Why = $_.why } } | Format-Table -AutoSize -Wrap }
        'next' { $n = Open-NextQueue; if ($n) { Write-Note "Opened $($n.name): click 'Slow download'." Cyan } else { Write-Note 'Queue complete.' Green } }
        'skip' {
            Use-Lock {
                $q = Get-Queue
                $hit = @($q | Where-Object { $_.name -like "*$Arg*" -and -not $_.done })
                if ($hit.Count -ne 1) { throw "Match '$Arg' -> $($hit.Count) open queue items" }
                $hit[0].done = $true
                Save-Queue $q
                Write-Note "Skipped $($hit[0].name)"
            }
        }
        'setkey' {
            $sec = Read-Host 'Paste your Nexus API key (input hidden)' -AsSecureString
            $v = Set-NexusKey ([Net.NetworkCredential]::new('', $sec).Password)
            Write-Note "Key OK (premium: $($v.is_premium)). Stored encrypted for this Windows user." Green
        }
        'register' { Register-NxmHandler; Write-Note 'nxm:// links now open cpmods.' Green }
        'unregister' { Remove-Item 'HKCU:\Software\Classes\nxm' -Recurse -Force; Write-Note 'nxm handler removed.' }
        'shortcuts' { New-CpShortcuts | ForEach-Object { Write-Note "Shortcut: $_" Green } }
        'package' { Write-Note "Created $(New-CpPackage)" Green }
        'compat' {
            Import-Module (Join-Path $PSScriptRoot 'lib\cpinsight.psm1') -Force -DisableNameChecking
            $r = Test-ModCompat
            foreach ($i in $r.issues) {
                $c = switch ($i.risk) { 'high' { 'Red' } 'medium' { 'Yellow' } 'ok' { 'DarkGreen' } default { 'Gray' } }
                Write-Host ("[{0}{1}] {2}" -f $i.risk, $(if ($i.ignored) { ', marked fine' } else { '' }), $i.title) -ForegroundColor $c
                foreach ($w in @($i.why)) { Write-Host "    - $w" -ForegroundColor DarkGray }
            }
            Write-Note "$(@($r.issues).Count) findings across $($r.mods) mods, $($r.archives) archives."
        }
        'frameworks' { Use-Lock { Invoke-Frameworks -Force:$Force } | Out-Null }
        'sync' { Use-Lock { Invoke-Sync -Force:$Force } | Out-Null }
        'check' {
            $r = Test-Install
            foreach ($m in $r.missing) { Write-Note "$($m.name): $($m.count) files missing, e.g. $($m.sample)" Red }
            foreach ($l in $r.logs) { Write-Host "`n== $($l.file)" -ForegroundColor Yellow; $l.lines | ForEach-Object { Write-Host "  $_" } }
            Write-Note "Checked $($r.checkedLogs) logs."
        }
        'nxm' {
            # a link the app would refuse (another game, broken) shows its error now, not after 15 s of retries
            [void](Resolve-NxmLink $Arg)
            if ($Inline) { Invoke-InlineNxm $Arg; Start-Sleep -Seconds 3; break }
            if (Send-ToServer $Arg) { break }
            Start-CpServer -Open
            $ok = $false
            for ($i = 0; $i -lt 60 -and -not $ok; $i++) { Start-Sleep -Milliseconds 250; $ok = Send-ToServer $Arg }
            if (-not $ok) { Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), 'nxm', ('"{0}"' -f $Arg), '-Inline') }
        }
        'install' {
            Use-Lock {
                $a = (Resolve-Path -LiteralPath $Arg).Path
                $meta = Get-DeferredMeta $a
                if (-not $meta) { $meta = [ordered]@{ name = [IO.Path]::GetFileNameWithoutExtension($a); version = $Version; source = 'manual' } }
                if ($Name) { $meta.name = $Name }
                if ($Version) { $meta.version = $Version }
                if ($Sub) { $meta.sub = $Sub }
                Install-ModArchive -Archive $a -Meta $meta -Force:$Force | Out-Null
            }
        }
        'remove' { Use-Lock { Remove-InstalledMod -Name $Arg -Purge:$Purge -Force:$Force } }
        'disable' { Use-Lock { Disable-InstalledMod -Name $Arg } }
        'enable' { Use-Lock { Enable-InstalledMod -Name $Arg } }
        'mods-back' {
            # brings mods back after a launch without mods (the app normally does this when the game closes)
            Import-Module (Join-Path $PSScriptRoot 'lib\cpinsight.psm1') -Force -DisableNameChecking
            Import-Module (Join-Path $PSScriptRoot 'lib\cpsafety.psm1') -Force -DisableNameChecking
            Write-Host (Use-Lock { Restore-VanillaSession })
        }
        default {
            @'
cpmods <command>
  ui                     open the mod manager window
  status                 game version, installed mods, queue
  sync                   install/update GitHub frameworks + mods waiting to install
  next | queue | skip <name>
  install <archive> [-Name n] [-Version v] [-Sub folder]
  remove <name> [-Purge]   uninstall, restoring any game files it replaced
  disable <name> | enable <name>
  mods-back              bring mods back after a launch without mods
  check                 verify files + scan RED4ext/redscript/CET logs for errors
  setkey | register | unregister | shortcuts
'@ | Write-Host
        }
    }
}
catch {
    Write-Note "ERROR: $($_.Exception.Message)" Red
    if ($cmd -eq 'nxm') {
        if ($Inline) { Read-Host 'Press Enter to close' | Out-Null }
        else { Start-Process -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), 'nxm', ('"{0}"' -f $Arg), '-Inline') }
    }
    exit 1
}
