// ZeroDelay setup: unpacks the embedded app files to a temporary folder and runs install.ps1.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("ZeroDelay Setup")]
[assembly: AssemblyProduct("ZeroDelay")]
[assembly: AssemblyDescription("Installer for ZeroDelay, a Fortnite latency optimizer for Windows")]
[assembly: AssemblyCompany("ZeroDelay contributors")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]

static class Setup
{
    static readonly string[] Files = { "ZeroDelay.ps1", "ZeroDelay.exe", "ZeroDelay.ico", "install.ps1", "uninstall.ps1", "LICENSE.txt",
                                              "Microsoft.Web.WebView2.Core.dll", "Microsoft.Web.WebView2.Wpf.dll", "WebView2Loader.dll" };

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        // "/update" is passed by ZeroDelay's own Update now button: the user already confirmed there.
        bool update = Array.Exists(args, a => a.Equals("/update", StringComparison.OrdinalIgnoreCase));
        if (!update)
        {
            var answer = MessageBox.Show(
                "Install ZeroDelay, the Fortnite latency optimizer?\n\n" +
                "It is installed to Program Files and adds Desktop and Start menu shortcuts. " +
                "ZeroDelay is free software under the MIT License and comes with no warranty.",
                "ZeroDelay Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return 1;
        }

        // Unpack into Windows' own temp folder, in a new folder only administrators can change. The user's %TEMP% is
        // writable by every program the user runs, so a file there could be swapped before install.ps1 copies it
        // into Program Files.
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp", "ZeroDelaySetup_" + Guid.NewGuid().ToString("N"));
        try
        {
            if (Directory.Exists(dir)) throw new Exception("The setup folder already exists: " + dir);
            Directory.CreateDirectory(dir, AdminOnlyDirectory());
            var asm = Assembly.GetExecutingAssembly();
            foreach (var name in Files)
            {
                using (var res = asm.GetManifestResourceStream(name))
                {
                    if (res == null) throw new Exception("Missing file in setup: " + name);
                    using (var outFile = File.Create(Path.Combine(dir, name))) res.CopyTo(outFile);
                }
            }
            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(dir, "install.ps1") + "\"" + (update ? " -Update" : ""),
                WorkingDirectory = dir,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (var p = Process.Start(psi)) { p.WaitForExit(); return p.ExitCode; }
        }
        catch (Exception ex)
        {
            MessageBox.Show("Setup failed:\n\n" + ex.Message, "ZeroDelay Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    // SYSTEM and Administrators: full control; nobody else: no access. Not inherited from the parent folder.
    static DirectorySecurity AdminOnlyDirectory()
    {
        var sec = new DirectorySecurity();
        sec.SetAccessRuleProtection(true, false);
        var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                                                       inherit, PropagationFlags.None, AccessControlType.Allow));
        sec.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        return sec;
    }
}
