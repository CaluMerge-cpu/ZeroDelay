// ZeroDelay.exe: asks Windows for administrator rights (so the permission prompt shows ZeroDelay's name and icon
// instead of "Windows PowerShell"), then runs ZeroDelay.ps1 from the same folder without a console window.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("ZeroDelay")]
[assembly: AssemblyProduct("ZeroDelay")]
[assembly: AssemblyDescription("ZeroDelay - Fortnite latency optimizer")]
[assembly: AssemblyCompany("ZeroDelay contributors")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("1.15.1.0")]
[assembly: AssemblyFileVersion("1.15.1.0")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "ZeroDelay.ps1");
        if (!File.Exists(script)) script = Path.Combine(dir, "FortniteOptimizer.ps1");   // installs from before 1.2
        if (!File.Exists(script))
        {
            MessageBox.Show("ZeroDelay.ps1 is missing next to ZeroDelay.exe. Please reinstall ZeroDelay.", "ZeroDelay", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        // only ZeroDelay's own switches (like -Tray) are passed on
        string extra = "";
        foreach (var a in args) if (a.StartsWith("-") && a.IndexOfAny(new[] { '"', ' ', '&', '|' }) < 0) extra += " " + a;
        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File \"" + script + "\"" + extra,
            WorkingDirectory = dir,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        try { Process.Start(psi); return 0; }
        catch (Exception ex)
        {
            MessageBox.Show("ZeroDelay could not start:\n\n" + ex.Message, "ZeroDelay", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }
}
