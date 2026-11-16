# First step of Install.cmd, runs on the built-in Windows PowerShell 5.1:
# finds or installs PowerShell 7.2+, then runs setup.ps1 with it
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $env:LOCALAPPDATA 'cpmods-setup.log'
function Say([string]$M, [string]$C = 'Gray') { Write-Host $M -ForegroundColor $C; try { Add-Content -LiteralPath $log -Value $M } catch { } }

function Test-Pwsh([string]$P) {
    if (-not $P -or -not (Test-Path -LiteralPath $P)) { return $false }
    try {
        & $P -NoProfile -NonInteractive -Command 'if ($PSVersionTable.PSVersion -lt [version]''7.2'') { exit 3 }' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

# winget puts PowerShell either in Program Files (MSI) or behind the WindowsApps alias (Store/MSIX)
function Find-Pwsh {
    $list = @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe")
    $list += @(Get-Command pwsh -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    foreach ($p in $list) { if (Test-Pwsh $p) { return $p } }
    $null
}

try { Set-Content -LiteralPath $log -Value ("cpmods setup log {0:yyyy-MM-dd HH:mm:ss}, Windows {1}" -f (Get-Date), [Environment]::OSVersion.Version) } catch { }
$pw = Find-Pwsh
if (-not $pw) {
    Say 'cpmods needs PowerShell 7 (free, made by Microsoft). Installing it now...' Cyan
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say 'If Windows asks for permission, click Yes.'
        try { & winget install --id Microsoft.PowerShell -e --source winget --accept-source-agreements --accept-package-agreements } catch { Say "winget: $($_.Exception.Message)" Yellow }
        $pw = Find-Pwsh
    }
}
if (-not $pw) {
    Say 'Downloading the PowerShell 7 installer from Microsoft (GitHub)...' Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'cpmods-setup' } -UseBasicParsing -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -like "PowerShell-*-win-$arch.msi" } | Select-Object -First 1
        if (-not $asset) { throw 'no installer found in the latest release' }
        $msi = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing -TimeoutSec 300
        Say 'Windows asks for permission to install it: click Yes.'
        $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/passive', 'ADD_PATH=1') -Wait -PassThru
        Say "Installer finished (code $($p.ExitCode))."
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        $pw = Find-Pwsh
    }
    catch { Say "The download did not work: $($_.Exception.Message)" Yellow }
}
if (-not $pw) {
    Say ''
    Say 'PowerShell 7 could not be installed automatically.' Red
    Say 'A page opens where you can download it: run the file that ends in "win-x64.msi", then double-click Install.cmd again.'
    Start-Process 'https://github.com/PowerShell/PowerShell/releases/latest'
    exit 1
}
Say "Using PowerShell 7: $pw" DarkGray
& $pw -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'setup.ps1')
exit $LASTEXITCODE
