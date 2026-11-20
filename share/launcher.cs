// cpmods.exe: starts the app (server.ps1 next to it) hidden with PowerShell 7. Built by New-CpLauncher (cpmods.psm1)
// with the .NET Framework compiler; CPMODS_VERSION is replaced with the app version at build time.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Cyberpunk Mods")]
[assembly: AssemblyProduct("cpmods")]
[assembly: AssemblyVersion("CPMODS_VERSION")]
[assembly: AssemblyFileVersion("CPMODS_VERSION")]

static class Launcher
{
    [STAThread]
    static void Main()
    {
        string app = AppDomain.CurrentDomain.BaseDirectory;
        string pw = FindPwsh();
        if (pw == null)
        {
            MessageBox.Show("cpmods needs PowerShell 7 (free, made by Microsoft). Run Install.cmd from the cpmods zip again, or install PowerShell 7 from the page that opens now.", "Cyberpunk Mods", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Process.Start("https://github.com/PowerShell/PowerShell/releases/latest");
            return;
        }
        var psi = new ProcessStartInfo(pw, "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + Path.Combine(app, "server.ps1") + "\" -Open");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = app;
        Process.Start(psi);
    }

    // the Store/winget alias first (its path survives updates), then the usual install folder, then PATH
    static string FindPwsh()
    {
        var list = new System.Collections.Generic.List<string>();
        list.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe"));
        list.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"));
        foreach (string d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try { if (d.Trim().Length > 0) list.Add(Path.Combine(d.Trim(), "pwsh.exe")); } catch (ArgumentException) { }
        }
        foreach (string p in list) if (File.Exists(p)) return p;
        return null;
    }
}
