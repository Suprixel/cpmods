# Built-in app window on the WebView2 runtime that ships with Windows (no browser needed).
# Runs on its own STA thread inside the server and talks to it only through $Shared flags.
param($Shared, [string]$Root, [string]$DataDir, [string]$IconPath)
$ErrorActionPreference = 'Stop'
$global:CpShared = $Shared

try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $wv2 = Join-Path $Root 'lib\webview2'
    Add-Type -Path (Join-Path $wv2 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $wv2 'Microsoft.Web.WebView2.WinForms.dll')
    [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($wv2)
    [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    [void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2)
    [Windows.Forms.Application]::EnableVisualStyles()
}
catch { $Shared.winFail = "WebView2: $($_.Exception.Message)"; $Shared.winFallback = $true; return }

# Frameless window that keeps Windows' resize edges, shadow, rounded corners and snapping; the page draws the title bar.
# Compiled once to state\bin; without it the window keeps the normal Windows title bar.
$global:CpFrameOk = $false
$frameSrc = @'
using System; using System.Runtime.InteropServices;
public static class CpFrame {
  public delegate IntPtr SubProc(IntPtr h, uint m, IntPtr w, IntPtr l, UIntPtr id, UIntPtr data);
  [DllImport("comctl32.dll")] static extern bool SetWindowSubclass(IntPtr h, SubProc p, UIntPtr id, UIntPtr data);
  [DllImport("comctl32.dll")] static extern bool RemoveWindowSubclass(IntPtr h, SubProc p, UIntPtr id);
  [DllImport("comctl32.dll")] static extern IntPtr DefSubclassProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int i, uint dpi);
  [DllImport("user32.dll")] static extern bool ReleaseCapture();
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  static readonly SubProc proc = Proc;
  static readonly UIntPtr Id = (UIntPtr)0xC9;
  static int Frame(IntPtr h) { uint d = GetDpiForWindow(h); return GetSystemMetricsForDpi(33, d) + GetSystemMetricsForDpi(92, d); }
  static void Recalc(IntPtr h) { SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x37); }
  public static void Attach(IntPtr h) { SetWindowSubclass(h, proc, Id, UIntPtr.Zero); int on = 1; DwmSetWindowAttribute(h, 20, ref on, 4); Recalc(h); }
  public static void Detach(IntPtr h) { RemoveWindowSubclass(h, proc, Id); Recalc(h); }
  // Windows 11 window border colour
  public static void Border(IntPtr h, int r, int g, int b) { int c = r | (g << 8) | (b << 16); DwmSetWindowAttribute(h, 34, ref c, 4); }
  // fallback drag: hand the mouse to Windows' own move loop (snapping included)
  public static void Drag(IntPtr h) { ReleaseCapture(); SendMessage(h, 0xA1, (IntPtr)2, IntPtr.Zero); }
  static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l, UIntPtr id, UIntPtr data) {
    if (m == 0x0083 && w != IntPtr.Zero) {
      // client area starts at the window top: caption gone, side and bottom resize borders kept
      int top = Marshal.PtrToStructure<RECT>(l).T;
      IntPtr res = DefSubclassProc(h, m, w, l);
      RECT r = Marshal.PtrToStructure<RECT>(l);
      r.T = top + (IsZoomed(h) ? Frame(h) : 0);
      Marshal.StructureToPtr(r, l, false);
      return res;
    }
    if (m == 0x0084) {
      // the thin strip above the page resizes from the top edge and corners
      IntPtr res = DefSubclassProc(h, m, w, l);
      if (res == (IntPtr)1 && !IsZoomed(h)) {
        RECT wr; GetWindowRect(h, out wr);
        long v = l.ToInt64(); int x = (short)(v & 0xFFFF), y = (short)((v >> 16) & 0xFFFF), f = Frame(h);
        if (y < wr.T + f) return (IntPtr)(x < wr.L + 2 * f ? 13 : x >= wr.R - 2 * f ? 14 : 12);
      }
      return res;
    }
    return DefSubclassProc(h, m, w, l);
  }
}
// Own taskbar identity: the button shows this window's icon instead of the host's (Store PowerShell),
// and pinning it relaunches cpmods. Null values clear the properties, as Windows asks before a window closes.
public static class CpAppId {
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore { void GetCount(out uint c); void GetAt(uint i, out PK k); void GetValue(ref PK k, out PV v); void SetValue(ref PK k, ref PV v); void Commit(); }
  [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PK { public Guid f; public uint p; }
  [StructLayout(LayoutKind.Sequential)] struct PV { public ushort vt; ushort a, b, c; public IntPtr p; IntPtr q; }
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore s);
  static void Set(IPropertyStore s, uint pid, string v) {
    var k = new PK { f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), p = pid };
    bool none = string.IsNullOrEmpty(v);
    var pv = new PV { vt = (ushort)(none ? 0 : 31), p = none ? IntPtr.Zero : Marshal.StringToCoTaskMemUni(v) };
    try { s.SetValue(ref k, ref pv); } finally { if (pv.p != IntPtr.Zero) Marshal.FreeCoTaskMem(pv.p); }
  }
  // System.AppUserModel: 2 RelaunchCommand, 3 RelaunchIconResource, 4 RelaunchDisplayNameResource, 5 ID; empty = not set
  // (3 and 4 only count when 2 is set)
  public static void Apply(IntPtr h, string id, string cmd, string icon, string name) {
    Guid iid = typeof(IPropertyStore).GUID; IPropertyStore s;
    if (SHGetPropertyStoreForWindow(h, ref iid, out s) != 0) return;
    try { Set(s, 2, cmd); Set(s, 3, icon); Set(s, 4, name); Set(s, 5, id); s.Commit(); }
    finally { Marshal.ReleaseComObject(s); }
  }
}
'@
try {
    $binDir = Join-Path $Root 'state\bin'
    $tag = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$frameSrc|$([Environment]::Version)"))).Substring(0, 12)
    $dll = Join-Path $binDir "CpFrame-$tag.dll"
    if (-not ('CpFrame' -as [type])) {
        if (-not (Test-Path -LiteralPath $dll)) {
            [void](New-Item -ItemType Directory -Force -Path $binDir)
            $tmp = Join-Path $binDir "CpFrame-$tag.$PID.dll"
            Add-Type -TypeDefinition $frameSrc -OutputAssembly $tmp -OutputType Library
            try { [IO.File]::Move($tmp, $dll) } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Get-ChildItem -LiteralPath $binDir -Filter 'CpFrame-*.dll' | Where-Object { $_.FullName -ne $dll } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Add-Type -Path $dll
    }
    $global:CpFrameOk = $true
}
catch { $Shared.winFrameErr = $_.Exception.Message }

# the server is started hidden, and Windows applies that to the first window it shows: spend it on a throwaway one
# (test runs with CPMODS_CDP keep the dev window hidden on purpose)
if (-not ($env:CPMODS_CDP -and -not $env:CPMODS_VISIBLE -and $Shared.winTitle -like '*(dev)')) {
    try {
        $d = [Windows.Forms.Form]::new(); $d.ShowInTaskbar = $false; $d.Opacity = 0; $d.FormBorderStyle = 'None'
        $d.StartPosition = 'Manual'; $d.Bounds = [Drawing.Rectangle]::new(-32000, -32000, 1, 1)
        $d.Show(); $d.Close(); $d.Dispose()
    }
    catch { }
}

# first start after the Edge window: carry its stored page data over once
$oldLs = Join-Path $Root 'state\edge\Default\Local Storage'
if (-not (Test-Path -LiteralPath $DataDir) -and (Test-Path -LiteralPath $oldLs)) {
    try { $newLs = Join-Path $DataDir 'EBWebView\Default'; [void](New-Item -ItemType Directory -Force -Path $newLs); Copy-Item -LiteralPath $oldLs -Destination $newLs -Recurse -Force } catch { }
}

function Read-Json([string]$Path) { try { if (Test-Path -LiteralPath $Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } } catch { }; $null }
# hands the resident memory of every WebView2 process of this window back to Windows (our processes only, never the game)
# Windows frame off: the page draws its own title bar; the strip above the page is the top resize edge
function global:Set-CpFrame([bool]$On) {
    $W = $global:CpW
    if (-not $W -or -not $global:CpFrameOk) { return }
    if ($On -ne $W.framed) { $W.framed = $On; if ($On) { [CpFrame]::Attach($W.form.Handle) } else { [CpFrame]::Detach($W.form.Handle) } }
    $top = if ($On -and $W.form.WindowState -ne 'Maximized') { $W.strip } else { 0 }
    if ($W.form.Padding.Top -ne $top) { $W.form.Padding = [Windows.Forms.Padding]::new(0, $top, 0, 0) }
}
# maximized/normal and active/inactive, for the page's title bar buttons
function global:Send-CpWinState($Active = $null) {
    $W = $global:CpW
    if (-not $W -or -not $W.wv.CoreWebView2) { return }
    $f = $W.form
    if ($null -eq $Active) { $Active = [Windows.Forms.Form]::ActiveForm -eq $f }
    $s = "$(if ($f.WindowState -eq 'Maximized') { 'max' } else { 'normal' })|$(if ($Active) { 'active' } else { 'inactive' })"
    if ($s -eq $W.state) { return }
    $W.state = $s
    try { foreach ($p in $s.Split('|')) { $W.wv.CoreWebView2.PostWebMessageAsString($p) } } catch { }
}
function global:Clear-CpWinSet($Core) {
    try { $infos = $Core.Environment.GetProcessInfos() } catch { return }
    foreach ($i in $infos) { try { $p = [Diagnostics.Process]::GetProcessById($i.ProcessId); $p.MaxWorkingSet = $p.MaxWorkingSet; $p.Dispose() } catch { } }
}

function Show-CpWindow {
    $S = $global:CpShared
    $wp = Read-Json $S.winFile
    $ui = Read-Json $S.uiFile
    $form = [Windows.Forms.Form]::new()
    $form.Text = $S.winTitle
    $form.BackColor = [Drawing.Color]::FromArgb(18, 22, 28)
    $form.StartPosition = 'Manual'
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($IconPath) } catch { } }
    $sc = $form.DeviceDpi / 96.0
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $lw = if ($wp -and [int]$wp.w -ge 900) { [int]$wp.w } else { 1440 }
    $lh = if ($wp -and [int]$wp.h -ge 600) { [int]$wp.h } else { 920 }
    $w = [Math]::Min([int]($lw * $sc), $wa.Width); $h = [Math]::Min([int]($lh * $sc), $wa.Height)
    $form.Bounds = [Drawing.Rectangle]::new($wa.X + [int](($wa.Width - $w) / 2), $wa.Y + [int](($wa.Height - $h) / 2), $w, $h)
    $form.MinimumSize = [Drawing.Size]::new([int](900 * $sc), [int](600 * $sc))
    if ($wp -and $wp.max) { $form.WindowState = 'Maximized' }

    $wv = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
    $wv.Dock = 'Fill'
    $wv.DefaultBackgroundColor = $form.BackColor
    $cp = [Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties]::new()
    $cp.UserDataFolder = $DataDir
    # no background services; picture cache on disk capped at 50 MB
    $a = '--disable-background-networking --disable-component-update --disable-breakpad --disable-domain-reliability --disk-cache-size=52428800 --disable-features=msSmartScreenProtection,msWebOOUI,msPdfOOUI'
    if ($ui -and $ui.perf -and $ui.perf.gpu -eq $false) { $a += ' --disable-gpu --disable-gpu-compositing' }
    # test hook: -Dev window only, port from CPMODS_CDP
    if ($env:CPMODS_CDP -and $S.winTitle -like '*(dev)') { $a += " --remote-debugging-port=$([int]$env:CPMODS_CDP)" }
    $cp.AdditionalBrowserArguments = $a
    $wv.CreationProperties = $cp
    $form.Controls.Add($wv)
    $global:CpW = @{ form = $form; wv = $wv; min = $false; minAt = $null; susp = $false; trimAt = $null; last = 'Normal'; low = $null; freeAt = $null; framed = $false; strip = [Math]::Max(3, [int][Math]::Round(4 * $sc)); state = '' }

    $wv.add_CoreWebView2InitializationCompleted({
            param($s, $e)
            $W = $global:CpW; $S = $global:CpShared
            if (-not $e.IsSuccess) { $S.winFail = "WebView2: $($e.InitializationException.Message)"; $S.winFallback = $true; $W.form.Close(); return }
            $c = $W.wv.CoreWebView2
            $c.Settings.AreDevToolsEnabled = $false
            $c.Settings.IsStatusBarEnabled = $false
            $c.Settings.IsGeneralAutofillEnabled = $false
            $c.Settings.IsPasswordAutosaveEnabled = $false
            # title bar drawn by the page: CSS app-region: drag moves the window; the page knows it from the user agent
            try { $c.Settings.IsNonClientRegionSupportEnabled = $true } catch { }
            if ($global:CpFrameOk) { $c.Settings.UserAgent = "$($c.Settings.UserAgent) cpmods-frame" }
            $c.add_WebMessageReceived({
                    param($x, $a)
                    $W = $global:CpW; $f = $W.form
                    $m = try { $a.TryGetWebMessageAsString() } catch { '' }
                    if ($m -eq 'min') { $f.WindowState = 'Minimized' }
                    elseif ($m -eq 'max') { $f.WindowState = $(if ($f.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) }
                    elseif ($m -eq 'close') { $f.Close() }
                    elseif ($m -eq 'drag') { if ($W.framed) { [CpFrame]::Drag($f.Handle) } }
                    elseif ($m -eq 'hello') { $W.state = ''; Send-CpWinState }
                    elseif ($m -match '^theme:(\d+),(\d+),(\d+)\|(\d+),(\d+),(\d+)$') {
                        $f.BackColor = [Drawing.Color]::FromArgb([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
                        if ($global:CpFrameOk) { [CpFrame]::Border($f.Handle, [int]$Matches[4], [int]$Matches[5], [int]$Matches[6]) }
                    }
                })
            # the page sends links to the user's browser itself; anything else that tries to leave goes there too
            $c.add_NewWindowRequested({ param($x, $a) $a.Handled = $true; [void]$global:CpShared.urls.Add("$($a.Uri)") })
            $c.add_NavigationStarting({ param($x, $a) if ("$($a.Uri)" -notmatch '^http://(localhost|127\.0\.0\.1):\d+/') { $a.Cancel = $true; if ("$($a.Uri)" -match '^https?://') { [void]$global:CpShared.urls.Add("$($a.Uri)") } } })
            $c.add_ProcessFailed({ param($x, $a) if ("$($a.ProcessFailedKind)" -match 'RenderProcess') { try { $global:CpW.wv.CoreWebView2.Reload() } catch { } } })
            $S.winPid = $c.BrowserProcessId
            $c.Navigate($S.winUrl)
        })
    $form.add_Shown({ [void]$global:CpW.wv.EnsureCoreWebView2Async($null) })
    # minimized: hide the page; the timer then frees memory and suspends it (no scripts, no CPU) until restored
    $form.add_Resize({
            $W = $global:CpW; $f = $W.form
            $min = $f.WindowState -eq [Windows.Forms.FormWindowState]::Minimized
            if (-not $min) { $W.last = $f.WindowState; Set-CpFrame $W.framed; Send-CpWinState }
            if ($min -eq $W.min) { return }
            $W.min = $min; $W.minAt = [datetime]::UtcNow; $W.susp = $false; $W.trimAt = $null
            $W.wv.Visible = -not $min
        })
    $form.add_FormClosing({
            $f = $global:CpW.form; $sc = $f.DeviceDpi / 96.0
            if ($global:CpFrameOk) { try { [CpAppId]::Apply($f.Handle, '', '', '', '') } catch { } }
            $b = if ($f.WindowState -eq 'Normal') { $f.Bounds } else { $f.RestoreBounds }
            try { [IO.File]::WriteAllText($global:CpShared.winFile, (@{ w = [int]($b.Width / $sc); h = [int]($b.Height / $sc); max = ($f.WindowState -eq 'Maximized') } | ConvertTo-Json -Compress)) } catch { }
        })
    # requests from the server: show, quit, free memory, list window processes; memory saver while the game runs
    $t = [Windows.Forms.Timer]::new()
    $t.Interval = 1000
    $t.add_Tick({
            $W = $global:CpW; $S = $global:CpShared; $f = $W.form
            if ($S.stop) { $f.Close(); return }
            if ($S.winShow) {
                $S.winShow = $false
                if ($f.WindowState -eq 'Minimized') { $f.WindowState = $W.last }
                $f.TopMost = $true; $f.TopMost = $false; $f.Activate(); $S.winFocus = $true
            }
            $c = $W.wv.CoreWebView2
            if (-not $c) { return }
            $now = [datetime]::UtcNow
            if ($S.winFree) { $S.winFree = $false; $W.freeAt = $now; Clear-CpWinSet $c }
            $low = [bool]($S.lean -or $W.min -or ($W.freeAt -and ($now - $W.freeAt).TotalSeconds -lt 8))
            if ($low -ne $W.low) { $W.low = $low; try { $c.MemoryUsageTargetLevel = $(if ($low) { 'Low' } else { 'Normal' }) } catch { } }
            # minimized for 3 s, or the game in front: memory back to Windows (again every 5 min), then suspend if minimized
            $away = $W.min -or ($S.lean -and [Windows.Forms.Form]::ActiveForm -ne $f)
            if (-not $away) { $W.trimAt = $null }
            elseif ((-not $W.min -or ($now - $W.minAt).TotalSeconds -ge 3) -and (-not $W.trimAt -or ($now - $W.trimAt).TotalSeconds -ge 300)) {
                Clear-CpWinSet $c; $S.trimNow = $true; $W.trimAt = $now
                if ($W.min -and -not $W.susp) { $W.susp = $true; try { [void]$c.TrySuspendAsync() } catch { } }
            }
            if ($S.winProcReq) {
                try { $S.winPids = @($c.Environment.GetProcessInfos() | ForEach-Object { $_.ProcessId }) } catch { $S.winPids = @($c.BrowserProcessId) }
                $S.winProcReq = $false
            }
        })
    $t.Start()
    $form.add_Activated({ Send-CpWinState $true })
    $form.add_Deactivate({ Send-CpWinState $false })
    $S.winHwnd = [long]$form.Handle
    if ($global:CpFrameOk -and $S.winAppId) {
        try { [CpAppId]::Apply($form.Handle, $S.winAppId, $S.winRelaunch, "$IconPath,0", 'Cyberpunk Mods') } catch { }
    }
    Set-CpFrame $true
    $S.winOpen = $true
    try { [Windows.Forms.Application]::Run($form) }
    finally {
        $t.Stop(); $t.Dispose()
        try { $wv.Dispose() } catch { }
        try { $form.Dispose() } catch { }
        $global:CpW = $null
        $S.winOpen = $false; $S.winPid = 0; $S.winHwnd = 0
        # closed by the user: the server leaves ~10 s later unless jobs run (not after a failed start)
        if (-not $S.winFallback) { $S.byeAt = [datetime]::UtcNow }
    }
}

while (-not $Shared.stop) {
    [void]$Shared.winEvt.WaitOne()
    if ($Shared.stop) { break }
    if (-not $Shared.winShow -or $Shared.winFail) { continue }
    $Shared.winShow = $false
    try { Show-CpWindow }
    catch { $Shared.winFail = "Window: $($_.Exception.Message)"; $Shared.winFallback = $true; $Shared.winOpen = $false }
}
