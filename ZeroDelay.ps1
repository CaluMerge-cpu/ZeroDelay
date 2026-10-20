#Requires -Version 5.1
<#
  ZeroDelay - Fortnite low-latency optimizer
  Card-based toggles for Windows, input, graphics, network and Fortnite tweaks.
  Every toggle is reversible: the first time a setting is changed, its original value is
  saved to %LOCALAPPDATA%\FortniteLatencyOptimizer\backup-v2.json and switching the card
  off (or "Restore all") puts it back.
#>

param(
    [switch]$NoElevate,   # dev: open read-only without admin
    [string]$Snapshot,    # dev: render the window to this PNG and exit
    [string]$Page,        # dev: category to show first
    [switch]$Tray         # start hidden in the system tray (used by "Start with Windows")
)

# --- Self-elevate (HKLM tweaks, powercfg and network adapters need admin) ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $NoElevate -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # ZeroDelay.exe makes Windows' permission prompt show ZeroDelay's name and icon instead of PowerShell's
    $launcher = Join-Path $PSScriptRoot 'ZeroDelay.exe'
    if (Test-Path $launcher) {
        try { if ($Tray) { Start-Process $launcher -ArgumentList '-Tray' } else { Start-Process $launcher } } catch {}
        exit
    }
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$(if ($Tray) { ' -Tray' })"
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
try { [Windows.Media.Animation.Timeline]::DesiredFrameRateProperty.OverrideMetadata([Windows.Media.Animation.Timeline], (New-Object Windows.FrameworkPropertyMetadata ([object][int]240))) } catch {}
if (-not $Snapshot) {
    $created = $false
    $script:AppMutex = New-Object System.Threading.Mutex($true, 'Local\ZeroDelayApp', [ref]$created)
    $script:ShowSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\ZeroDelayShow')
    if (-not $created) { [void]$script:ShowSignal.Set(); exit }
}
$AppVersion = '1.9.1'

# --- Loading screen. Runs on its own thread with its own dispatcher, so it keeps animating while the app loads.
$script:Splash = $null
if (-not $Snapshot -and -not $Tray) {
    $script:Splash = [hashtable]::Synchronized(@{ Status = 'Starting'; Close = $false })
    $splashRs = [runspacefactory]::CreateRunspace(); $splashRs.ApartmentState = 'STA'; $splashRs.ThreadOptions = 'ReuseThread'; $splashRs.Open()
    $splashRs.SessionStateProxy.SetVariable('S', $script:Splash)
    $splashPs = [powershell]::Create(); $splashPs.Runspace = $splashRs
    [void]$splashPs.AddScript({
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $w = [Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZeroDelay" Width="420" Height="260" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen" ShowInTaskbar="True" Opacity="0">
  <Border CornerRadius="24" Background="#050507" BorderBrush="#26FFFFFF" BorderThickness="1" ClipToBounds="True">
    <Border.Clip><RectangleGeometry Rect="0,0,420,260" RadiusX="24" RadiusY="24"/></Border.Clip>
    <Grid>
      <Ellipse x:Name="G1" Width="420" Height="420" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-170,-240,0,0">
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#552EE6A6" Offset="0"/><GradientStop Color="#002EE6A6" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform x:Name="G1T"/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse Width="460" Height="460" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-200,-280">
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#555E5CE6" Offset="0"/><GradientStop Color="#005E5CE6" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform x:Name="G2T"/></Ellipse.RenderTransform>
      </Ellipse>
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <Border x:Name="Logo" Width="64" Height="64" CornerRadius="16" HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
          <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#4BF0BA" Offset="0"/><GradientStop Color="#22CF93" Offset="1"/></LinearGradientBrush></Border.Background>
          <Border.Effect><DropShadowEffect x:Name="LogoGlow" Color="#2EE6A6" BlurRadius="36" ShadowDepth="0" Opacity="0.7"/></Border.Effect>
          <Border.RenderTransform><ScaleTransform x:Name="LogoScale"/></Border.RenderTransform>
          <TextBlock Text="&#xE945;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="30" Foreground="#06281C" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock Text="ZeroDelay" FontFamily="Segoe UI" FontSize="24" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,18,0,0"/>
        <TextBlock x:Name="Status" Text="Starting" FontFamily="Segoe UI" FontSize="12.5" Foreground="#9A9AA5" HorizontalAlignment="Center" Margin="0,4,0,0"/>
        <Border Width="180" Height="4" CornerRadius="2" Background="#1FFFFFFF" Margin="0,18,0,0" ClipToBounds="True">
          <Border Width="70" Height="4" CornerRadius="2" HorizontalAlignment="Left">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#002EE6A6" Offset="0"/><GradientStop Color="#FF2EE6A6" Offset="0.5"/><GradientStop Color="#002EE6A6" Offset="1"/></LinearGradientBrush></Border.Background>
            <Border.RenderTransform><TranslateTransform x:Name="Shimmer" X="-70"/></Border.RenderTransform>
          </Border>
        </Border>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@)
        function Loop($target, $prop, $from, $to, [double]$sec, [bool]$rev = $true) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation $from, $to, ([Windows.Duration][TimeSpan]::FromSeconds($sec))
            $a.AutoReverse = $rev; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $e = New-Object Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
            $target.BeginAnimation($prop, $a)
        }
        $sc = $w.FindName('LogoScale')
        Loop $sc ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 1.07 0.9
        Loop $sc ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 1.07 0.9
        Loop $w.FindName('LogoGlow') ([Windows.Media.Effects.DropShadowEffect]::OpacityProperty) 0.45 0.95 0.9
        Loop $w.FindName('Shimmer') ([Windows.Media.TranslateTransform]::XProperty) -70 180 1.1 $false
        Loop $w.FindName('G1T') ([Windows.Media.TranslateTransform]::XProperty) 0 60 3
        Loop $w.FindName('G2T') ([Windows.Media.TranslateTransform]::YProperty) 0 -50 3.6
        $fade = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, ([Windows.Duration][TimeSpan]::FromMilliseconds(260))
        $w.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $status = $w.FindName('Status')
        $tm = New-Object Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromMilliseconds(120)
        $tm.Add_Tick({
            if ($status.Text -ne $S.Status) { $status.Text = $S.Status }
            if ($S.Close) {
                $tm.Stop()
                $out = New-Object Windows.Media.Animation.DoubleAnimation 0, ([Windows.Duration][TimeSpan]::FromMilliseconds(220))
                $out.Add_Completed({ $w.Close(); $w.Dispatcher.InvokeShutdown() })
                $w.BeginAnimation([Windows.UIElement]::OpacityProperty, $out)
            }
        })
        $tm.Start()
        $w.Show()
        [Windows.Threading.Dispatcher]::Run()
    })
    $script:SplashHandle = $splashPs.BeginInvoke()
}
function Set-SplashStatus([string]$Text) { if ($script:Splash) { $script:Splash.Status = $Text } }
function Close-Splash { if ($script:Splash) { $script:Splash.Close = $true } }
$UpdateRepo = 'CaluMerge-cpu/ZeroDelay'

# --- Theme. The UI is written in the dark palette; every XAML string and brush goes through [ZdTheme],
#     which swaps those colours for light mode and the chosen accent colour as the window is built.
Add-Type -AssemblyName System.Xaml
Add-Type -ReferencedAssemblies ([Windows.Markup.XamlReader].Assembly.Location), ([Windows.Media.Brush].Assembly.Location),
    ([Windows.DependencyObject].Assembly.Location), ([System.Xaml.XamlReader].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
public static class ZdTheme {
    public static readonly Dictionary<string, string> Map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    // exact text swaps done before colours (used by the glass look to point card fills/edges at gradient resources)
    public static readonly List<KeyValuePair<string, string>> Literal = new List<KeyValuePair<string, string>>();
    static readonly Regex Hex = new Regex("#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6})(?![0-9A-Fa-f])");
    public static string Apply(string s) {
        if (s == null) return s;
        foreach (var kv in Literal) s = s.Replace(kv.Key, kv.Value);
        if (Map.Count == 0) return s;
        return Hex.Replace(s, m => {
            string h = m.Groups[1].Value, a = "";
            if (h.Length == 8) { a = h.Substring(0, 2); h = h.Substring(2); }
            string t;
            if (!Map.TryGetValue(h, out t)) return m.Value;
            return t.Length == 8 ? "#" + t : "#" + a + t;   // a mapped colour with its own alpha wins
        });
    }
    public static object Parse(string xaml) { return System.Windows.Markup.XamlReader.Parse(Apply(xaml)); }
    public static System.Windows.Media.Brush Brush(string c) {
        return (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFrom(Apply(c));
    }
}

// CPU load from GetSystemTimes (works even when performance counters are switched off)
public static class CpuLoad {
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    static long li, lk, lu;
    public static int Sample() {
        long i, k, u; if (!GetSystemTimes(out i, out k, out u)) return -1;
        long di = i - li, dt = (k - lk) + (u - lu); bool first = li == 0; li = i; lk = k; lu = u;
        if (first || dt <= 0) return -1;
        return (int)System.Math.Round(100.0 * (dt - di) / dt);
    }
}

// Sticky / Filter / Toggle Keys hotkeys: read and set the live values, so the change works without signing out.
public static class AccessKeys {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct SK { public uint cb; public uint flags; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct FK { public uint cb; public uint flags; public uint wait; public uint delay; public uint repeat; public uint bounce; }
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint a, uint b, ref SK c, uint d);
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint a, uint b, ref FK c, uint d);
    const uint GetSticky = 0x3A, SetSticky = 0x3B, GetFilter = 0x32, SetFilter = 0x33, GetToggle = 0x34, SetToggle = 0x35, Send = 3;
    // flags as Windows uses them right now: sticky, filter, toggle; -1 on error
    public static long[] Read() {
        var a = new SK(); a.cb = 8; var f = new FK(); f.cb = 24; var t = new SK(); t.cb = 8;
        if (!SystemParametersInfo(GetSticky, 8, ref a, 0) || !SystemParametersInfo(GetFilter, 24, ref f, 0) || !SystemParametersInfo(GetToggle, 8, ref t, 0)) return new long[] { -1, -1, -1 };
        return new long[] { a.flags, f.flags, t.flags };
    }
    public static bool Write(uint sticky, uint filter, uint toggle) {
        var a = new SK(); a.cb = 8; a.flags = sticky;
        var f = new FK(); f.cb = 24; SystemParametersInfo(GetFilter, 24, ref f, 0); f.cb = 24; f.flags = filter;
        var t = new SK(); t.cb = 8; t.flags = toggle;
        return SystemParametersInfo(SetSticky, 8, ref a, Send) & SystemParametersInfo(SetFilter, 24, ref f, Send) & SystemParametersInfo(SetToggle, 8, ref t, Send);
    }
}

// Which monitor (PnP instance path) is on which Windows display (\\.\DISPLAYn), and which one is the main screen.
public static class DisplayMap {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    struct DD { public int cb; [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string String; public int Flags;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string Key; }
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DD dd, uint flags);
    // "\\.\DISPLAY1|DISPLAY\XMI2001\5&...&UID4355|1" per attached monitor (last field 1 = main screen)
    public static string[] List() {
        var res = new System.Collections.Generic.List<string>();
        for (uint i = 0; ; i++) {
            var a = new DD(); a.cb = System.Runtime.InteropServices.Marshal.SizeOf(a);
            if (!EnumDisplayDevices(null, i, ref a, 0)) break;
            if ((a.Flags & 1) == 0) continue;   // not attached to the desktop
            var m = new DD(); m.cb = System.Runtime.InteropServices.Marshal.SizeOf(m);
            if (!EnumDisplayDevices(a.Name, 0, ref m, 1)) continue;   // EDD_GET_DEVICE_INTERFACE_NAME
            // \\?\DISPLAY#XMI2001#5&60f9dea&0&UID4355#{...} -> DISPLAY\XMI2001\5&60f9dea&0&UID4355
            string id = m.Id ?? "";
            if (id.StartsWith("\\\\?\\")) id = id.Substring(4);
            int brace = id.IndexOf("#{"); if (brace > 0) id = id.Substring(0, brace);
            res.Add(a.Name + "|" + id.Replace('#', '\\') + "|" + ((a.Flags & 4) != 0 ? "1" : "0"));
        }
        return res.ToArray();
    }
}

// Mouse polling-rate test: timestamps every raw mouse report (WM_INPUT) sent to the ZeroDelay window.
public static class MouseRate {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);
    static readonly long[] Stamps = new long[400000];
    static int count;
    static System.Windows.Interop.HwndSource source;
    static readonly System.Windows.Interop.HwndSourceHook HookRef = Hook;
    public static bool Running { get; private set; }
    public static int Count { get { return count; } }
    static double TicksPerMs { get { return System.Diagnostics.Stopwatch.Frequency / 1000.0; } }
    static bool Register(uint flags, IntPtr target) {
        var d = new RAWINPUTDEVICE[] { new RAWINPUTDEVICE { UsagePage = 1, Usage = 2, Flags = flags, Target = target } };
        return RegisterRawInputDevices(d, 1, (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
    }
    public static bool Start(IntPtr hwnd) {
        if (Running) return true;
        source = System.Windows.Interop.HwndSource.FromHwnd(hwnd);
        if (source == null || !Register(0, hwnd)) return false;
        count = 0;
        source.AddHook(HookRef);
        Running = true;
        return true;
    }
    public static void Stop() {
        if (!Running) return;
        Running = false;
        source.RemoveHook(HookRef);
        Register(0x1 /* RIDEV_REMOVE */, IntPtr.Zero);
    }
    static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x00FF && count < Stamps.Length) Stamps[count++] = System.Diagnostics.Stopwatch.GetTimestamp();
        return IntPtr.Zero;
    }
    // reports per second over the last `ms` milliseconds
    public static double RecentRate(int ms) {
        int n = count;
        long from = System.Diagnostics.Stopwatch.GetTimestamp() - (long)(ms * TicksPerMs);
        int k = 0;
        for (int i = n - 1; i >= 0 && Stamps[i] >= from; i--) k++;
        return k * 1000.0 / ms;
    }
    // number of reports in each `binMs` slice, from the first report to the last
    public static int[] Bins(int binMs) {
        int n = count;
        if (n < 2) return new int[0];
        long w = (long)(binMs * TicksPerMs), t0 = Stamps[0];
        var b = new int[(int)((Stamps[n - 1] - t0) / w) + 1];
        for (int i = 0; i < n; i++) b[(int)((Stamps[i] - t0) / w)]++;
        return b;
    }
}

// After-match report: frame times from a PresentMon CSV.
public class MatchFrames {
    public int Frames; public double AvgFps; public double Low1Fps; public double TotalMs;
    public int StutterCount; public double[] StutterAtMs; public double[] StutterMs;
}
public static class FrameStats {
    public static System.Threading.Tasks.Task<MatchFrames> AnalyzeAsync(string path) {
        return System.Threading.Tasks.Task.Run(() => Analyze(path));
    }
    public static MatchFrames Analyze(string path) {
        var ft = new List<double>();
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        using (var fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite))
        using (var r = new System.IO.StreamReader(fs)) {
            string header = r.ReadLine();
            if (header == null) return null;
            var cols = header.Split(',');
            int col = Array.IndexOf(cols, "MsBetweenPresents");
            if (col < 0) col = Array.IndexOf(cols, "FrameTime");
            if (col < 0) return null;
            string line;
            while ((line = r.ReadLine()) != null) {
                var f = line.Split(',');
                double v;
                if (f.Length > col && double.TryParse(f[col], System.Globalization.NumberStyles.Float, inv, out v) && v > 0) ft.Add(v);
            }
        }
        int n = ft.Count;
        if (n < 300) return null;
        var m = new MatchFrames { Frames = n };
        // median frame time of each 240-frame block; blocks under 20 FPS are menus or loading screens
        const int B = 240;
        var meds = new double[(n + B - 1) / B];
        for (int b = 0; b < n; b += B) {
            var blk = ft.GetRange(b, Math.Min(n, b + B) - b);
            blk.Sort();
            meds[b / B] = blk[blk.Count / 2];
        }
        // gameplay frames only: no menus, and no frames over 1 s (alt-tab, pauses)
        var play = new List<double>();
        double total = 0, playSum = 0;
        for (int i = 0; i < n; i++) {
            total += ft[i];
            if (meds[i / B] < 50 && ft[i] < 1000) { play.Add(ft[i]); playSum += ft[i]; }
        }
        if (play.Count < 300) return null;
        m.TotalMs = total;
        m.AvgFps = play.Count > 0 ? 1000.0 * play.Count / playSum : 0;
        play.Sort();
        int k = Math.Max(1, (int)Math.Ceiling(play.Count * 0.01));
        double slow = 0;
        for (int i = play.Count - k; i < play.Count; i++) slow += play[i];
        m.Low1Fps = 1000.0 / (slow / k);
        // a stutter is one frame far slower than the frames around it (the median of its block);
        // hitches less than 1 s apart count as one; menu and loading blocks are skipped
        var at = new List<double>(); var ms = new List<double>();
        double cum = 0, lastAt = -1e9;
        bool lastKept = false;
        for (int b = 0; b < n; b += B) {
            int e = Math.Min(n, b + B);
            double med = meds[b / B];
            double thr = Math.Max(med * 2.5, med + 12);
            for (int i = b; i < e; i++) {
                double v = ft[i];
                if (med < 50 && v > thr && v < 1000) {
                    if (cum - lastAt > 1000) {
                        m.StutterCount++;
                        lastKept = at.Count < 30;
                        if (lastKept) { at.Add(cum); ms.Add(v); }
                    } else if (lastKept && v > ms[ms.Count - 1]) ms[ms.Count - 1] = v;
                    lastAt = cum;
                }
                cum += v;
            }
        }
        m.StutterAtMs = at.ToArray();
        m.StutterMs = ms.ToArray();
        return m;
    }
}

// Deep uninstall: files that stay locked are deleted by Windows at the next restart.
public static class FileTools {
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern bool MoveFileEx(string existing, string replacement, int flags);
    public static bool DeleteAtRestart(string path) { return MoveFileEx(path, null, 0x4 /* MOVEFILE_DELAY_UNTIL_REBOOT */); }
}

// The Settings > Power mode slider (Balanced plan only): Best performance / Balanced / Best power efficiency
public static class PowerOverlay {
    [System.Runtime.InteropServices.DllImport("powrprof.dll")] static extern uint PowerGetEffectiveOverlayScheme(out Guid scheme);
    [System.Runtime.InteropServices.DllImport("powrprof.dll")] static extern uint PowerSetActiveOverlayScheme(ref Guid scheme);
    public static readonly Guid BestPerformance = new Guid("ded574b5-45a0-4f42-8737-46345c09c238");
    public static readonly Guid Balanced = Guid.Empty;
    public static readonly Guid BestEfficiency = new Guid("961cc777-2547-4f9d-8174-7d86181b8a7a");
    public static Guid? Get() { Guid g; return PowerGetEffectiveOverlayScheme(out g) == 0 ? (Guid?)g : null; }
    public static uint Set(Guid g) { return PowerSetActiveOverlayScheme(ref g); }
}

// Audio enhancements (system effects) per playback device, the same switch as Settings > Sound > Audio enhancements.
public static class AudioFx {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack = 4)]
    struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit, Size = 24)]
    struct PROPVARIANT { [System.Runtime.InteropServices.FieldOffset(0)] public ushort vt; [System.Runtime.InteropServices.FieldOffset(8)] public uint ulVal; [System.Runtime.InteropServices.FieldOffset(8)] public IntPtr ptr; }
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out uint count);
        int GetAt(uint i, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("D666063F-1587-4E43-81F1-B948E807363F"), System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams, [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(uint stgmAccess, out IPropertyStore store);
        int GetId([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] out string id);
        int GetState(out uint state);
    }
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { int GetCount(out uint count); int Item(uint i, out IMMDevice device); }
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { int EnumAudioEndpoints(int dataFlow, uint stateMask, out IMMDeviceCollection devices); }
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }
    static PROPERTYKEY DisableSysFx = new PROPERTYKEY { fmtid = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e"), pid = 5 };
    static PROPERTYKEY FriendlyName = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
    public class Endpoint { public string Id; public string Name; public int Disabled = -1; }   // 1 = enhancements off, 0 = on, -1 = never set (on)
    public static List<Endpoint> List() {
        var list = new List<Endpoint>();
        var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection col; en.EnumAudioEndpoints(0, 1, out col);
        uint n; col.GetCount(out n);
        for (uint i = 0; i < n; i++) {
            IMMDevice d; col.Item(i, out d);
            var e = new Endpoint(); d.GetId(out e.Id);
            IPropertyStore ps; d.OpenPropertyStore(0, out ps);
            PROPVARIANT v;
            if (ps.GetValue(ref FriendlyName, out v) == 0 && v.vt == 31) e.Name = System.Runtime.InteropServices.Marshal.PtrToStringUni(v.ptr);
            if (ps.GetValue(ref DisableSysFx, out v) == 0 && v.vt == 19) e.Disabled = (int)v.ulVal;
            list.Add(e);
        }
        return list;
    }
    public static int Set(string id, int value) {   // value 1 / 0, or -1 to remove the setting
        var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection col; en.EnumAudioEndpoints(0, 1, out col);
        uint n; col.GetCount(out n);
        for (uint i = 0; i < n; i++) {
            IMMDevice d; col.Item(i, out d);
            string did; d.GetId(out did);
            if (did != id) continue;
            IPropertyStore ps;
            int hr = d.OpenPropertyStore(2, out ps);
            if (hr != 0) return hr;
            var v = new PROPVARIANT();
            if (value < 0) v.vt = 0; else { v.vt = 19; v.ulVal = (uint)value; }
            hr = ps.SetValue(ref DisableSysFx, ref v);
            return hr != 0 ? hr : ps.Commit();
        }
        return -1;
    }
}

// Creator tab: keeps Windows from sleeping while a render runs (released as soon as it ends).
public static class KeepAwake {
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    public static void Hold() { SetThreadExecutionState(0x80000000u | 0x00000001u); }   // ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    public static void Release() { SetThreadExecutionState(0x80000000u); }
}

// Memory page: clears the standby list once. Needs SeProfileSingleProcessPrivilege (admins have it, disabled by default).
public static class MemTools {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attr; }
    [System.Runtime.InteropServices.DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int length, IntPtr previous, IntPtr returnLength);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    public static bool EnablePrivilege(string name) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28 /* ADJUST_PRIVILEGES | QUERY */, out token)) return false;
        try {
            long luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;
            var tp = new TOKEN_PRIVILEGES { Count = 1, Luid = luid, Attr = 2 /* SE_PRIVILEGE_ENABLED */ };
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return System.Runtime.InteropServices.Marshal.GetLastWin32Error() == 0;
        } finally { CloseHandle(token); }
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct PERFORMANCE_INFORMATION {
        public int cb; public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable, SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        public int HandleCount, ProcessCount, ThreadCount;
    }
    [System.Runtime.InteropServices.DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION info, int size);
    // [total, available, system cache] in bytes; works even when Windows' performance counters are switched off
    public static long[] Physical() {
        PERFORMANCE_INFORMATION pi;
        int size = System.Runtime.InteropServices.Marshal.SizeOf(typeof(PERFORMANCE_INFORMATION));
        if (!GetPerformanceInfo(out pi, size)) return null;
        long page = (long)pi.PageSize.ToUInt64();
        return new long[] { (long)pi.PhysicalTotal.ToUInt64() * page, (long)pi.PhysicalAvailable.ToUInt64() * page, (long)pi.SystemCache.ToUInt64() * page };
    }
    // 0 = done, -1 = no permission, anything else = NTSTATUS error
    public static int PurgeStandby() {
        if (!EnablePrivilege("SeProfileSingleProcessPrivilege")) return -1;
        int command = 4;   // MemoryPurgeStandbyList
        return NtSetSystemInformation(80 /* SystemMemoryListInformation */, ref command, 4);
    }
}
'@
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeInput {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}

// Reads and writes DWORD settings on an NVIDIA driver profile, like NVIDIA Profile Inspector does.
public static class AppIdentity {
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
}

public static class NvDrs {
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr QI(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Fn0();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnOutPtr(out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnPtr(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnFind(IntPtr s, [MarshalAs(UnmanagedType.LPArray)] byte[] name, out IntPtr prof);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnGet(IntPtr s, IntPtr prof, uint id, [In, Out] byte[] setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnSet(IntPtr s, IntPtr prof, [In] byte[] setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnDel(IntPtr s, IntPtr prof, uint id);
    const int SettingSize = 0x3020;  // NVDRS_SETTING_V1
    static T F<T>(uint id) { var p = QI(id); if (p == IntPtr.Zero) throw new Exception("nvapi 0x" + id.ToString("X")); return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T)); }
    static byte[] Name(string n) { var b = new byte[4096]; var u = System.Text.Encoding.Unicode.GetBytes(n); Array.Copy(u, b, Math.Min(u.Length, 4094)); return b; }
    // Runs op on the named profile inside a loaded session; saves only when save is true.
    static readonly object Gate = new object();   // the UI thread and the background worker may both ask
    static int With(string profile, bool save, Func<IntPtr, IntPtr, int> op) {
        lock (Gate) { return WithLocked(profile, save, op); }
    }
    static int WithLocked(string profile, bool save, Func<IntPtr, IntPtr, int> op) {
        try {
            if (F<Fn0>(0x0150E828)() != 0) return -2;
            IntPtr s; if (F<FnOutPtr>(0x0694D52E)(out s) != 0) return -2;
            try {
                if (F<FnPtr>(0x375DBD6B)(s) != 0) return -2;
                IntPtr prof; if (F<FnFind>(0x7E4A9A0B)(s, Name(profile), out prof) != 0) return -3;
                int r = op(s, prof);
                if (save && r == 0) r = F<FnPtr>(0xFCBC7E14)(s);
                return r;
            } finally { F<FnPtr>(0xDAD9CFF8)(s); }
        } catch (DllNotFoundException) { return -2; } catch (Exception) { return -2; }
    }
    public static bool Available(string profile) { return With(profile, false, (s, p) => 0) == 0; }
    // Value of a DWORD setting, -1 when the profile does not set it, below -1 on error.
    public static long Get(string profile, uint id) {
        long result = -1;
        int r = With(profile, false, (s, p) => {
            var set = new byte[SettingSize]; BitConverter.GetBytes((uint)(SettingSize | (1 << 16))).CopyTo(set, 0);
            int g = F<FnGet>(0x73BF8338)(s, p, id, set);
            if (g == 0) result = BitConverter.ToUInt32(set, 8220);
            return g == -160 ? 0 : g;  // -160 = NVAPI_SETTING_NOT_FOUND
        });
        return r == 0 ? result : (r < -1 ? r : -2);
    }
    // {rc, value, location, isPredefined}. location 0 = set on this profile, 1+ = inherited (global/base/default).
    public static long[] GetEx(string profile, uint id) {
        long[] res = new long[] { -2, 0, 3, 0 };
        int r = With(profile, false, (s, p) => {
            var set = new byte[SettingSize]; BitConverter.GetBytes((uint)(SettingSize | (1 << 16))).CopyTo(set, 0);
            int g = F<FnGet>(0x73BF8338)(s, p, id, set);
            res[0] = g;
            if (g == 0) { res[1] = BitConverter.ToUInt32(set, 8220); res[2] = BitConverter.ToUInt32(set, 4108); res[3] = BitConverter.ToUInt32(set, 4112); }
            return 0;
        });
        if (r != 0) res[0] = r;
        return res;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnOutU(out uint v);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnVrr(uint displayId, [In, Out] byte[] info);
    // NV_GET_VRR_INFO flags of the primary display: bit0 enabled, bit1 possible, bit2 requested, bit4 in VRR mode now. -1 on error.
    public static int VrrFlags() {
        try {
            if (F<Fn0>(0x0150E828)() != 0) return -1;
            uint disp; if (F<FnOutU>(0x1E9D8A31)(out disp) != 0) return -1;
            var info = new byte[24]; BitConverter.GetBytes((uint)(24 | (1 << 16))).CopyTo(info, 0);
            if (F<FnVrr>(0xDF8FDA57)(disp, info) != 0) return -1;
            return (int)BitConverter.ToUInt32(info, 4);
        } catch (Exception) { return -1; }
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnByName([MarshalAs(UnmanagedType.LPStr)] string name, out uint id);
    // NV_GET_VRR_INFO flags for one display by its Windows name (\\.\DISPLAY1): bit0 G-SYNC on for it, bit1 it can do VRR. -1 on error.
    public static int VrrFlagsFor(string gdiName) {
        try {
            if (F<Fn0>(0x0150E828)() != 0) return -1;
            uint disp; if (F<FnByName>(0xAE457190)(gdiName, out disp) != 0) return -1;
            var info = new byte[24]; BitConverter.GetBytes((uint)(24 | (1 << 16))).CopyTo(info, 0);
            if (F<FnVrr>(0xDF8FDA57)(disp, info) != 0) return -1;
            return (int)BitConverter.ToUInt32(info, 4);
        } catch (Exception) { return -1; }
    }
    public static int Set(string profile, uint id, uint value) {
        return With(profile, true, (s, p) => {
            var set = new byte[SettingSize];
            BitConverter.GetBytes((uint)(SettingSize | (1 << 16))).CopyTo(set, 0);
            BitConverter.GetBytes(id).CopyTo(set, 4100);      // settingId
            BitConverter.GetBytes(0u).CopyTo(set, 4104);      // NVDRS_DWORD_TYPE
            BitConverter.GetBytes(value).CopyTo(set, 8220);   // u32CurrentValue
            return F<FnSet>(0x577DD202)(s, p, set);
        });
    }
    public static int Delete(string profile, uint id) {
        return With(profile, true, (s, p) => { int d = F<FnDel>(0xE4A26362)(s, p, id); return d == -160 ? 0 : d; });
    }
}

public static class NativeDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
    static DEVMODE Current() { var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); EnumDisplaySettings(null, -1, ref dm); return dm; }
    public static int CurrentHz() { return Current().dmDisplayFrequency; }
    // Highest refresh rate the primary display supports at its current resolution.
    public static int MaxHz() {
        var cur = Current(); int best = 0;
        var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        for (int i = 0; EnumDisplaySettings(null, i, ref dm); i++) {
            if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmDisplayFrequency > best) best = dm.dmDisplayFrequency;
        }
        return best;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    // One entry per active display: "monitor|gpu|hz|primary".
    public static string[] ListDisplays() {
        var list = new System.Collections.Generic.List<string>();
        var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++) {
            if ((dd.StateFlags & 1) != 0) {  // attached to desktop
                var mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                string monName = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0) ? mon.DeviceString : dd.DeviceName;
                var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                EnumDisplaySettings(dd.DeviceName, -1, ref dm);
                list.Add(monName + "|" + dd.DeviceString + "|" + dm.dmDisplayFrequency + "|" + ((dd.StateFlags & 4) != 0));
            }
            dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return list.ToArray();
    }
    public static int SetHz(int hz) {
        var dm = Current(); dm.dmDisplayFrequency = hz; dm.dmFields = 0x400000;  // DM_DISPLAYFREQUENCY
        return ChangeDisplaySettings(ref dm, 1);  // CDS_UPDATEREGISTRY, 0 = success
    }
}

'@

try { [void][AppIdentity]::SetCurrentProcessExplicitAppUserModelID('ZeroDelay.FortniteLatencyOptimizer') } catch {}
$FortniteExeName = 'FortniteClient-Win64-Shipping.exe'
$DataDir    = Join-Path $env:LOCALAPPDATA 'FortniteLatencyOptimizer'
$BackupFile = Join-Path $DataDir 'backup-v2.json'
$IniPath    = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini'
$IniSection = '[/Script/FortniteGame.FortGameUserSettings]'
$GuidRx     = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
$UltimateTemplate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGuid     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BalancedGuid     = '381b4222-f694-41f0-9685-ff5bb260df2e'

# Plugged-in (AC) values for the ZeroDelay power plan: @(subgroup, setting, value)
$ZeroDelayPlanValues = @(
    @('54533251-82be-4824-96c1-47b60b740d00', '893dee8e-2bef-41e0-89c6-b55d0929964c', 100)  # CPU minimum state
    @('54533251-82be-4824-96c1-47b60b740d00', 'bc5038f7-23e0-4960-96da-33abaf5935ec', 100)  # CPU maximum state
    @('54533251-82be-4824-96c1-47b60b740d00', '36687f9e-e3a5-4dbf-b1dc-15eb381c6863', 0)    # energy performance preference
    @('54533251-82be-4824-96c1-47b60b740d00', 'be337238-0d82-4146-a960-4f3749d470c7', 2)    # boost mode: aggressive
    @('54533251-82be-4824-96c1-47b60b740d00', '45bcc044-d885-43e2-8605-ee0ec6e96b59', 100)  # boost policy
    @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0)    # USB selective suspend
    @('2a737441-1930-4402-8d77-b2bebba308a3', 'd4e98f31-5ffe-4ce1-be31-1b38b384c009', 0)    # USB 3 link power management
    @('2a737441-1930-4402-8d77-b2bebba308a3', '0853a681-27c8-4100-a2fd-82013e970683', 0)    # USB hub suspend timeout
    @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0)    # PCIe link state power management
    @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0)    # turn off drives: never
    @('19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', 0)    # Wi-Fi: maximum performance
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 0)    # sleep: never
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364', 0)    # hibernate: never
)
# Unparking every core fights the X3D driver, which parks the non-cache die on purpose.
$ZeroDelayCoreParking = @('54533251-82be-4824-96c1-47b60b740d00', '0cc5b647-c1df-4637-891a-dec35c318583', 100)
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# ================================================================ backup ===

function Load-Backup {
    $b = @{ Registry = @(); CreatedKeys = @(); Custom = @{} }
    if (Test-Path $BackupFile) {
        try {
            $j = Get-Content $BackupFile -Raw | ConvertFrom-Json
            $b.Registry    = @($j.Registry | Where-Object { $_ })
            $b.CreatedKeys = @($j.CreatedKeys | Where-Object { $_ })
            if ($j.Custom) { $j.Custom.PSObject.Properties | ForEach-Object { $b.Custom[$_.Name] = $_.Value } }
        } catch {}
    }
    $b
}

function Save-Backup { if ($Snapshot) { return }; $script:Backup | ConvertTo-Json -Depth 8 | Set-Content -Path $BackupFile -Encoding UTF8 }   # dev renders never touch the real file

function Test-TweakHasBackup([string]$Id) {
    [bool]($script:Backup.Registry | Where-Object { $_.Tweak -eq $Id }) -or $script:Backup.Custom.ContainsKey($Id)
}

function Get-RegValue([string]$Path, [string]$Name) {
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($k) { $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } else { $null }
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-RegValue([string]$Path, [string]$Name) {
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
}

# Sets a registry value, saving the original the first time this tweak touches it.
function Set-RegTracked([string]$Tweak, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $already = $script:Backup.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $already) {
        $existed = $false; $old = $null; $oldType = $null
        $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($k -and ($k.GetValueNames() -contains $Name)) {
            $existed = $true
            $old     = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $oldType = $k.GetValueKind($Name).ToString()
        }
        $script:Backup.Registry += [pscustomobject]@{ Tweak = $Tweak; Path = $Path; Name = $Name; Existed = $existed; Value = $old; Type = $oldType }
    }
    $p = $Path
    while (-not (Test-Path -LiteralPath $p)) {
        if (-not ($script:Backup.CreatedKeys | Where-Object { $_.Path -eq $p })) {
            $script:Backup.CreatedKeys += [pscustomobject]@{ Tweak = $Tweak; Path = $p }
        }
        $p = Split-Path $p -Parent
    }
    Set-RegValue $Path $Name $Value $Type
}

# Puts back every registry value a tweak changed. Returns $false if nothing was backed up.
function Restore-RegTweak([string]$Tweak) {
    $entries = @($script:Backup.Registry | Where-Object { $_.Tweak -eq $Tweak })
    if (-not $entries.Count) { return $false }
    foreach ($e in $entries) {
        if ($e.Existed) { Set-RegValue $e.Path $e.Name $e.Value $e.Type } else { Remove-RegValue $e.Path $e.Name }
    }
    foreach ($c in ($script:Backup.CreatedKeys | Where-Object { $_.Tweak -eq $Tweak } | Sort-Object { $_.Path.Length } -Descending)) {
        $k = Get-Item -LiteralPath $c.Path -ErrorAction SilentlyContinue
        if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $c.Path -Force }
    }
    $script:Backup.Registry    = @($script:Backup.Registry | Where-Object { $_.Tweak -ne $Tweak })
    $script:Backup.CreatedKeys = @($script:Backup.CreatedKeys | Where-Object { $_.Tweak -ne $Tweak })
    $true
}

# ============================================================= detection ===

function Find-FortniteExe {
    $roots = @()
    $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
    if (Test-Path $dat) {
        try {
            $roots += (Get-Content $dat -Raw | ConvertFrom-Json).InstallationList |
                Where-Object { $_.AppName -eq 'Fortnite' } | ForEach-Object { $_.InstallLocation }
        } catch {}
    }
    $roots += Join-Path $env:ProgramFiles 'Epic Games\Fortnite'
    foreach ($r in $roots) {
        $exe = Join-Path $r "FortniteGame\Binaries\Win64\$FortniteExeName"
        if (Test-Path $exe) { return $exe }
    }
    $null
}

function Get-ActivePowerScheme {
    $line = "$(powercfg /getactivescheme)"
    if ($line -match "($GuidRx)\s+\((.*)\)\s*$") { return @{ Guid = $Matches[1]; Name = $Matches[2] } }
    @{ Guid = $null; Name = 'unknown' }
}

function Get-RefreshRate {
    $r = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
          Where-Object { $_.CurrentRefreshRate -gt 1 } | Select-Object -First 1).CurrentRefreshRate
    if ($r) { [int]$r } else { 0 }
}

function Test-FortniteRunning { [bool](Get-Process ($FortniteExeName -replace '\.exe$') -ErrorAction SilentlyContinue) }

function Get-UpAdapters { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }

# ========================================================= tweak engines ===

# --- Declarative registry tweaks: Reg = @( @{ P; N; V; T; D = default ($null = delete); M = value Windows assumes when missing } )
function Test-RegTweak($t) {
    foreach ($e in $t.Reg) {
        $v = Get-RegValue $e.P $e.N
        if ($null -eq $v) { $v = $e.M }
        if ("$v" -ne "$($e.V)") { return $false }
    }
    $true
}
function Enable-RegTweak($t) {
    foreach ($e in $t.Reg) { Set-RegTracked $t.Id $e.P $e.N $e.V $(if ($e.T) { $e.T } else { 'DWord' }) }
}
function Disable-RegTweak($t) {
    if (Restore-RegTweak $t.Id) { return }
    foreach ($e in $t.Reg) {
        if ($null -eq $e.D) { Remove-RegValue $e.P $e.N } else { Set-RegValue $e.P $e.N $e.D $(if ($e.T) { $e.T } else { 'DWord' }) }
    }
}

# --- Fortnite GameUserSettings.ini tweaks: Ini = @{ Key = @(desired, default, section) }
#     A $null default removes the line. Section defaults to the main Fortnite settings section.
function Get-IniValue([string[]]$Lines, [string]$Key) {
    foreach ($l in $Lines) { if ($l -match "^\s*$([regex]::Escape($Key))=(.*)$") { return $Matches[1] } }
    $null
}
function Set-IniValue([string[]]$Lines, [string]$Key, $Value, [string]$Section = $IniSection) {
    $rx = "^\s*$([regex]::Escape($Key))="
    if ($null -eq $Value) { return , @($Lines | Where-Object { $_ -notmatch $rx }) }
    $found = $false
    $out = foreach ($l in $Lines) { if ($l -match $rx) { $found = $true; "$Key=$Value" } else { $l } }
    if (-not $found) {
        if ($Lines | Where-Object { $_.Trim() -eq $Section }) {
            $out = foreach ($l in $Lines) { $l; if ($l.Trim() -eq $Section) { "$Key=$Value" } }
        } else {
            $out = @($Lines) + $Section + "$Key=$Value"
        }
    }
    , @($out)
}
function Get-IniSection($entry) { if ($entry.Count -gt 2 -and $entry[2]) { "[$($entry[2])]" } else { $IniSection } }
function Assert-IniWritable {
    if (-not (Test-Path $IniPath)) { throw 'Fortnite settings file not found. Launch Fortnite once first.' }
    if (Test-FortniteRunning) { throw 'Close Fortnite first, it overwrites its settings when it exits.' }
}
function Test-IniTweak($t) {
    if (-not (Test-Path $IniPath)) { return $null }
    $lines = Get-Content $IniPath
    foreach ($k in $t.Ini.Keys) { if ("$(Get-IniValue $lines $k)" -ne "$($t.Ini[$k][0])") { return $false } }
    $true
}
function Enable-IniTweak($t) {
    Assert-IniWritable
    $lines = Get-Content $IniPath
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) {
        $orig = @{}; foreach ($k in $t.Ini.Keys) { $orig[$k] = Get-IniValue $lines $k }
        $script:Backup.Custom[$t.Id] = $orig
    }
    foreach ($k in $t.Ini.Keys) {
        $v = $t.Ini[$k][0]; if ($v -is [scriptblock]) { $v = & $v }
        $lines = Set-IniValue $lines $k $v (Get-IniSection $t.Ini[$k])
    }
    Set-Content -Path $IniPath -Value $lines -Encoding UTF8
}
function Disable-IniTweak($t) {
    Assert-IniWritable
    $lines = Get-Content $IniPath
    $orig = $script:Backup.Custom[$t.Id]
    foreach ($k in $t.Ini.Keys) {
        $v = if ($orig) { $orig.$k } else { $t.Ini[$k][1] }
        $lines = Set-IniValue $lines $k $v (Get-IniSection $t.Ini[$k])
    }
    Set-Content -Path $IniPath -Value $lines -Encoding UTF8
    $script:Backup.Custom.Remove($t.Id)
}

# --- Power plan settings on the active plan (AC / plugged-in value): Power = @{ Sub; Set; V; D }
function Get-PowerIndex([string]$Sub, [string]$Set, [string]$Scheme = 'scheme_current') {
    $o = powercfg /qh $Scheme $Sub $Set 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $hex = @($o | Where-Object { $_ -match ':\s*0x[0-9a-fA-F]+\s*$' } | ForEach-Object { [Convert]::ToInt32(($_ -replace '.*0x', '').Trim(), 16) })
    if ($hex.Count -lt 2) { return $null }
    $hex[-2]
}
function Test-PowerTweak($t) {
    $v = Get-PowerIndex $t.Power.Sub $t.Power.Set
    if ($null -eq $v) { return $null }
    $v -eq $t.Power.V
}
function Enable-PowerTweak($t) {
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) {
        $script:Backup.Custom[$t.Id] = @{ Scheme = (Get-ActivePowerScheme).Guid; Value = (Get-PowerIndex $t.Power.Sub $t.Power.Set) }
    }
    powercfg /setacvalueindex scheme_current $t.Power.Sub $t.Power.Set $t.Power.V
    if ($LASTEXITCODE -ne 0) { throw 'Windows refused the power setting.' }
    powercfg /setactive scheme_current
}
function Disable-PowerTweak($t) {
    $saved = $script:Backup.Custom[$t.Id]
    if ($saved -and $null -ne $saved.Value) { powercfg /setacvalueindex $saved.Scheme $t.Power.Sub $t.Power.Set $saved.Value 2>$null }
    else { powercfg /setacvalueindex scheme_current $t.Power.Sub $t.Power.Set $t.Power.D }
    powercfg /setactive scheme_current
    $script:Backup.Custom.Remove($t.Id)
}

# --- DirectX global graphics settings ("k=v;k=v;" string): Dx = @{ K; V; D; M }
function Get-DxValue([string]$Key) {
    if ("$(Get-RegValue $GpuPrefKey 'DirectXUserGlobalSettings')" -match "(?<=^|;)$Key=([^;]*);") { $Matches[1] } else { $null }
}
function Set-DxValue([string]$Key, $Value) {
    $str = "$(Get-RegValue $GpuPrefKey 'DirectXUserGlobalSettings')" -replace "(?<=^|;)$Key=[^;]*;", ''
    if ($null -ne $Value) { $str += "$Key=$Value;" }
    if ($str) { Set-RegValue $GpuPrefKey 'DirectXUserGlobalSettings' $str 'String' } else { Remove-RegValue $GpuPrefKey 'DirectXUserGlobalSettings' }
}
function Test-DxTweak($t) {
    $v = Get-DxValue $t.Dx.K; if ($null -eq $v) { $v = $t.Dx.M }
    "$v" -eq "$($t.Dx.V)"
}
function Enable-DxTweak($t) {
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = (Get-DxValue $t.Dx.K) } }
    Set-DxValue $t.Dx.K $t.Dx.V
}
function Disable-DxTweak($t) {
    $saved = $script:Backup.Custom[$t.Id]
    if ($saved -and "$($saved.Value)" -match '=') {
        # backup from an older version that stored the whole settings string
        Set-RegValue $GpuPrefKey 'DirectXUserGlobalSettings' $saved.Value 'String'
    } elseif ($saved) { Set-DxValue $t.Dx.K $saved.Value }
    else { Set-DxValue $t.Dx.K $t.Dx.D }
    $script:Backup.Custom.Remove($t.Id)
}

# --- Scheduled tasks: Tasks = @('\Path\To\TaskName', ...)
# --- Read caches: asking Windows once for all tasks / devices / adapter settings instead of once per card.
#     Entries live for 4 seconds, so a refresh is fast but a later check still sees fresh data.
$script:ReadCache = @{}
function Get-Cached([string]$Key, [scriptblock]$Load, [int]$Seconds = 4) {
    $c = $script:ReadCache[$Key]
    if ($c -and ((Get-Date) - $c.Time).TotalSeconds -lt $Seconds) { return $c.Data }
    $data = & $Load
    $script:ReadCache[$Key] = @{ Time = Get-Date; Data = $data }
    $data
}
function Clear-ReadCache { $script:ReadCache = @{} }
function Get-TaskStates {
    Get-Cached 'tasks' {
        $h = @{}
        foreach ($x in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) { $h["$($x.TaskPath)$($x.TaskName)"] = "$($x.State)" }
        $h
    }
}
function Get-PnpStates {
    Get-Cached 'pnp' {
        $h = @{}
        foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue)) { $h[$d.InstanceId] = "$($d.ConfigManagerErrorCode)" }
        $h
    }
}
function Get-AdvPropsAll {
    Get-Cached 'advprops' {
        @(Get-UpAdapters | ForEach-Object { Get-NetAdapterAdvancedProperty -Name $_.Name -AllProperties -ErrorAction SilentlyContinue })
    }
}

function Get-TweakTasks($t) {
    @($t.Tasks | ForEach-Object {
        $i = $_.LastIndexOf('\')
        Get-ScheduledTask -TaskPath $_.Substring(0, $i + 1) -TaskName $_.Substring($i + 1) -ErrorAction SilentlyContinue
    })
}
function Test-TaskTweak($t) {
    $all = Get-TaskStates
    $states = @($t.Tasks | Where-Object { $all.ContainsKey($_) } | ForEach-Object { $all[$_] })
    if (-not $states.Count) { return $null }
    -not ($states | Where-Object { $_ -ne 'Disabled' })
}
function Enable-TaskTweak($t) {
    $tasks = Get-TweakTasks $t
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) {
        $script:Backup.Custom[$t.Id] = @($tasks | Where-Object { "$($_.State)" -ne 'Disabled' } | ForEach-Object { $_.TaskPath + $_.TaskName })
    }
    $failed = 0
    foreach ($task in $tasks) { try { $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null } catch { $failed++ } }
    if ($failed -and $failed -eq $tasks.Count) { throw 'Windows protects these tasks on this PC.' }
}
function Disable-TaskTweak($t) {
    $names = if ($script:Backup.Custom.ContainsKey($t.Id)) { @($script:Backup.Custom[$t.Id]) } else { $t.Tasks }
    foreach ($n in $names) {
        $i = $n.LastIndexOf('\')
        Enable-ScheduledTask -TaskPath $n.Substring(0, $i + 1) -TaskName $n.Substring($i + 1) -ErrorAction SilentlyContinue | Out-Null
    }
    $script:Backup.Custom.Remove($t.Id)
}

# --- Several power settings in one card: Powers = @( @{ Sub; Set; V; D } ). Each value is saved before it changes.
function Test-PowerSet($t) {
    foreach ($p in $t.Powers) { $v = Get-PowerIndex $p.Sub $p.Set; if ($null -eq $v) { return $null }; if ($v -ne $p.V) { return $false } }
    $true
}
function Enable-PowerSet($t) {
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) {
        $script:Backup.Custom[$t.Id] = @{ Scheme = (Get-ActivePowerScheme).Guid; Values = @($t.Powers | ForEach-Object { Get-PowerIndex $_.Sub $_.Set }) }
    }
    foreach ($p in $t.Powers) {
        powercfg /setacvalueindex scheme_current $p.Sub $p.Set $p.V
        if ($LASTEXITCODE -ne 0) { throw 'Windows refused the power setting.' }
    }
    powercfg /setactive scheme_current
}
function Disable-PowerSet($t) {
    $saved = $script:Backup.Custom[$t.Id]
    for ($i = 0; $i -lt $t.Powers.Count; $i++) {
        $p = $t.Powers[$i]
        $v = if ($saved -and $null -ne @($saved.Values)[$i]) { @($saved.Values)[$i] } else { $p.D }
        $scheme = if ($saved) { $saved.Scheme } else { 'scheme_current' }
        powercfg /setacvalueindex $scheme $p.Sub $p.Set $v 2>$null
    }
    powercfg /setactive scheme_current
    $script:Backup.Custom.Remove($t.Id)
}

# --- Graphics card interrupts (MSI). Only offered when the driver has not turned MSI on itself.
function Get-GpuMsiKeys {
    @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } |
        ForEach-Object { "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" })
}
function Test-GpuMsi { $k = Get-GpuMsiKeys; if (-not $k) { return $null }; -not ($k | Where-Object { (Get-RegValue $_ 'MSISupported') -ne 1 }) }

# --- Hypervisor launch (bcdedit). The value is often absent, which means "Auto".
function Get-HypervisorLaunch {
    $line = (bcdedit /enum '{current}' 2>$null) | Where-Object { $_ -match '^\s*hypervisorlaunchtype\s' } | Select-Object -First 1
    if ($line) { ($line -split '\s+', 2)[1].Trim() } else { $null }
}

# --- Epic Games Launcher: the "Additional Command Line Arguments" switch for Fortnite (only read/written while the launcher is closed)
function Get-EpicLauncherIni {
    foreach ($d in 'Windows', 'WindowsEditor') { $f = "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Config\$d\GameUserSettings.ini"; if ((Test-Path $f) -and (Select-String -Path $f -Pattern 'Fortnite_AdditionalCommands=' -Quiet)) { return $f } }
    $null
}
function Get-FnLaunchArgs {
    $f = Get-EpicLauncherIni; if (-not $f) { return $null }
    $lines = Get-Content $f
    [pscustomobject]@{
        File = $f
        Enabled = ($lines | Where-Object { $_ -match 'Fortnite_AdditionalCommandsEnabled=' } | Select-Object -First 1) -replace '^.*?=', ''
        Args = ($lines | Where-Object { $_ -match 'Fortnite_AdditionalCommands=' } | Select-Object -First 1) -replace '^.*?=', ''
    }
}
function Set-FnLaunchArgsEnabled([string]$Value) {
    if (Get-Process EpicGamesLauncher -ErrorAction SilentlyContinue) { throw 'Close the Epic Games Launcher first (it rewrites this setting when it closes).' }
    $f = Get-EpicLauncherIni; if (-not $f) { throw 'Epic launcher settings not found.' }
    $lines = Get-Content $f
    $i = 0; $done = $false
    $out = foreach ($ln in $lines) {
        if ($ln -match '^(fn:[0-9a-f]+:Fortnite_AdditionalCommandsEnabled)=') { $done = $true; "$($Matches[1])=$Value" } else { $ln }
    }
    if (-not $done) {
        # add the switch right after the arguments line, with the same prefix
        $out = foreach ($ln in $lines) { $ln; if ($ln -match '^(fn:[0-9a-f]+:Fortnite_AdditionalCommands)=') { "$($Matches[1])Enabled=$Value" } }
    }
    Set-Content -Path $f -Value $out -Encoding UTF8
}

# --- Several services in one card (vendor software): Svcs = @( @{ N = 'name'; D = defaultStart } ). Only the services
#     that exist on this PC are touched; each one's start type is saved before it changes.
function Get-SvcSetPresent($t) { @($t.Svcs | Where-Object { Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.N)" }) }
function Test-SvcSet($t) {
    $present = Get-SvcSetPresent $t
    if (-not $present.Count) { return $null }
    -not ($present | Where-Object { (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.N)" 'Start') -ne 4 })
}
function Enable-SvcSet($t) {
    $present = Get-SvcSetPresent $t
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) {
        $script:Backup.Custom[$t.Id] = @($present | ForEach-Object { @{ N = $_.N; Start = (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.N)" 'Start') } })
    }
    foreach ($sv in $present) {
        Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($sv.N)" 'Start' 4 'DWord'
        Stop-Service -Name $sv.N -Force -ErrorAction SilentlyContinue
    }
}
function Disable-SvcSet($t) {
    $saved = @($script:Backup.Custom[$t.Id])
    foreach ($sv in Get-SvcSetPresent $t) {
        $b = $saved | Where-Object { $_.N -eq $sv.N } | Select-Object -First 1
        $start = if ($b -and $null -ne $b.Start) { [int]$b.Start } else { [int]$sv.D }
        Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($sv.N)" 'Start' $start 'DWord'
        if ($start -eq 2) { Start-Service -Name $sv.N -ErrorAction SilentlyContinue }
    }
    $script:Backup.Custom.Remove($t.Id)
}
function New-VendorTweak([string]$Id, [string]$Title, [string]$Desc, [string]$Warn, $Svcs, [string]$Badge) {
    @{ Id = $Id; Cat = 'Vendor'; Icon = [char]0xE74C; Rec = $false; Badge = $Badge; Svcs = $Svcs
       Title = $Title; Desc = $Desc; Warn = $Warn
       Requires = { @(Get-SvcSetPresent $t).Count -gt 0 }
       Test = { Test-SvcSet $t }; On = { Enable-SvcSet $t }; Off = { Disable-SvcSet $t } }
}

# --- Is a desktop app installed? (Windows "App Paths" entry or a known file)
function Test-AppInstalled([string]$Exe, [string[]]$Paths = @()) {
    foreach ($h in 'HKLM:', 'HKCU:') { if (Test-Path "$h\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Exe") { return $true } }
    foreach ($p in $Paths) { if ($p -and (Test-Path $p)) { return $true } }
    $false
}

# --- Opera GX keeps its settings in Chromium's "Local State" JSON. Only the one key is edited, as text, while Opera is closed.
$OperaLocalState = "$env:APPDATA\Opera Software\Opera GX Stable\Local State"
function Get-OperaHwAccel {
    if (-not (Test-Path $OperaLocalState)) { return $null }
    $txt = [IO.File]::ReadAllText($OperaLocalState)
    if ($txt -match '"hardware_acceleration_mode"\s*:\s*\{[^{}]*"enabled"\s*:\s*(true|false)') { $Matches[1] -eq 'true' } else { 'absent' }
}
function Set-OperaHwAccel($Value) {   # $true / $false / 'absent' (remove the key)
    if (Get-Process opera -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Opera GX*' }) { throw 'Close Opera GX first (it rewrites its settings when it closes).' }
    $txt = [IO.File]::ReadAllText($OperaLocalState)
    $txt = [regex]::Replace($txt, '"hardware_acceleration_mode"\s*:\s*\{[^{}]*\}\s*,?', '')
    if ($Value -ne 'absent') { $txt = $txt -replace '^\s*\{', "{`"hardware_acceleration_mode`":{`"enabled`":$("$Value".ToLower())}," }
    $txt = $txt -replace ',\s*\}', '}'
    [IO.File]::WriteAllText($OperaLocalState, $txt, (New-Object Text.UTF8Encoding $false))
}

# --- Steam's config.vdf (text, tab-separated "key"  "value" lines). Edited only while Steam is closed.
function Get-SteamConfig { $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath; if ($sp) { $f = Join-Path ($sp -replace '/', '\') 'config\config.vdf'; if (Test-Path $f) { return $f } }; $null }
function Get-VdfValue([string[]]$Lines, [string]$Key) { $m = $Lines | Where-Object { $_ -match "^\s*`"$Key`"\s+`"([^`"]*)`"" } | Select-Object -First 1; if ($m -match "`"$Key`"\s+`"([^`"]*)`"") { $Matches[1] } else { $null } }
function Set-SteamAutoUpdateWindow([bool]$On, $Start, $End) {
    if (Get-Process steam -ErrorAction SilentlyContinue) { throw 'Close Steam first (it rewrites its settings when it closes).' }
    $f = Get-SteamConfig; if (-not $f) { throw 'Steam settings not found.' }
    $lines = [IO.File]::ReadAllLines($f)
    $out = New-Object Collections.Generic.List[string]
    $done = $false
    foreach ($ln in $lines) {
        if ($ln -match '^(\s*)"AutoUpdateWindowEnabled"\s+"[^"]*"') {
            $ind = $Matches[1]
            $out.Add("$ind`"AutoUpdateWindowEnabled`"`t`t`"$([int]$On)`"")
            if ($On) { $out.Add("$ind`"AutoUpdateWindowStart`"`t`t`"$Start`""); $out.Add("$ind`"AutoUpdateWindowEnd`"`t`t`"$End`"") }
            $done = $true; continue
        }
        if ($ln -match '^\s*"AutoUpdateWindow(Start|End)"\s+"') { continue }   # rewritten above (or dropped when off and they were absent)
        $out.Add($ln)
    }
    if (-not $done) { throw 'Steam settings file has no auto-update entry yet. Open Steam settings once, then try again.' }
    [IO.File]::WriteAllLines($f, $out)
}

# --- Creator apps (Adobe, OBS). Their settings files are edited one value at a time, as text, only while the app is closed.
function Get-AppPath([string]$Exe) {
    foreach ($h in 'HKLM:', 'HKCU:') { $v = (Get-ItemProperty "$h\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Exe" -ErrorAction SilentlyContinue).'(default)'; if ($v) { $v = "$v".Trim('"'); if (Test-Path -LiteralPath $v) { return $v } } }
    $null
}
function Get-CreatorExes {
    Get-Cached 'creatorexes' {
        $list = @()
        foreach ($e in 'Adobe Premiere Pro.exe', 'AfterFX.exe', 'Photoshop.exe', 'Adobe Media Encoder.exe') { $p = Get-AppPath $e; if ($p) { $list += $p } }
        $ae = $list | Where-Object { $_ -like '*AfterFX.exe' } | Select-Object -First 1
        if ($ae) { $r = Join-Path (Split-Path $ae) 'aerender.exe'; if (Test-Path -LiteralPath $r) { $list += $r } }
        $list += @(Get-Item "$env:ProgramFiles\Adobe\Adobe Photoshop *\Photoshop.exe", "$env:ProgramFiles\Adobe\Adobe Media Encoder *\Adobe Media Encoder.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        @($list | Select-Object -Unique)
    }
}
$ObsIni = "$env:APPDATA\obs-studio\global.ini"
function Get-PrPrefsFile { Get-ChildItem "$env:USERPROFILE\Documents\Adobe\Premiere Pro\*\Profile-*\Adobe Premiere Pro Prefs" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
function Get-AePrefsFile { Get-ChildItem "$env:APPDATA\Adobe\After Effects\*\Adobe After Effects * Prefs.txt" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'indep' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
function Get-MemBalancerFile { Get-ChildItem "$env:APPDATA\Adobe\dynamiclinkmanager\*\memorybalancer*.xml" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
function Test-CreatorPc { @(Get-CreatorExes).Count -gt 0 -or (Test-Path $ObsIni) -or [bool](Get-PrPrefsFile) -or [bool](Get-AePrefsFile) }
function Assert-AppsClosed([string[]]$Names, [string]$App) { if (Get-Process -Name $Names -ErrorAction SilentlyContinue) { throw "Close $App first: it rewrites its settings when it closes." } }
$AdobeVideoProcs = @('Adobe Premiere Pro', 'AfterFX', 'aerender', 'Adobe Media Encoder', 'dynamiclinkmanager', 'Audition')
function Read-KeepText([string]$Path) { $b = [IO.File]::ReadAllBytes($Path); @{ Text = [IO.File]::ReadAllText($Path); Bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) } }
function Write-KeepText([string]$Path, $Doc) { [IO.File]::WriteAllText($Path, $Doc.Text, (New-Object Text.UTF8Encoding ([bool]$Doc.Bom))) }
function Get-XmlTag([string]$Text, [string]$Tag) { if ($Text -match "<$([regex]::Escape($Tag))>([^<]*)</") { $Matches[1] } else { $null } }
function Set-XmlTag([string]$Text, [string]$Tag, [string]$Value) { [regex]::Replace($Text, "(<$([regex]::Escape($Tag))>)[^<]*(</)", { param($m) $m.Groups[1].Value + $Value + $m.Groups[2].Value }) }
# After Effects prefs: tab-indented "key" = value lines inside ["Section"] blocks
function Get-AeValue([string]$Text, [string]$Section, [string]$Key) {
    $i = $Text.IndexOf("[`"$Section`"]"); if ($i -lt 0) { return $null }
    $m = [regex]::Match($Text.Substring($i), "(?m)^\s*`"$([regex]::Escape($Key))`"\s*=\s*(.+?)\s*$"); if ($m.Success) { $m.Groups[1].Value } else { $null }
}
function Set-AeValue([string]$Text, [string]$Section, [string]$Key, [string]$Value) {
    $i = $Text.IndexOf("[`"$Section`"]"); if ($i -lt 0) { throw 'This After Effects setting was not found. Open and close After Effects once, then try again.' }
    $rx = New-Object Text.RegularExpressions.Regex "(?m)^(\s*`"$([regex]::Escape($Key))`"\s*=\s*)(.+?)(\s*)$"
    $m = $rx.Match($Text, $i); if (-not $m.Success) { throw 'This After Effects setting was not found.' }
    $Text.Substring(0, $m.Groups[2].Index) + $Value + $Text.Substring($m.Groups[2].Index + $m.Groups[2].Length)
}
# Adobe's own RAM reserve default for this PC's memory, from the table in memorybalancer.xml
function Get-AdobeReserve {
    $f = Get-MemBalancerFile; if (-not $f) { return $null }
    try {
        [xml]$x = Get-Content $f -Raw
        $pairs = @($x.'prop.map'.'prop.list'.'prop.pair')
        $arr = { param($k) @(($pairs | Where-Object { $_.key -eq $k }).array.int | ForEach-Object { [uint64]"$($_.'#text')" }) }
        $tops = & $arr 'rangeTop'; $defs = & $arr 'defaultReserved'
        $cur = [uint64]"$((($pairs | Where-Object { $_.key -eq 'memorytouseforotherapplications' }).int).'#text')"
        $ram = [uint64](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        $idx = $defs.Count - 1; for ($i = 0; $i -lt $tops.Count; $i++) { if ($tops[$i] -ge $ram) { $idx = $i; break } }
        @{ File = $f; Current = $cur; Default = $defs[[Math]::Min($idx, $defs.Count - 1)] }
    } catch { $null }
}

# --- Builds a card that disables a Windows service (Start = 4) and restores its default start type.
function New-SvcTweak([string]$Id, [string]$Svc, [int]$Default, [string]$Title, [string]$Desc, [string]$Warn, [bool]$Rec, [string]$Badge) {
    @{ Id = $Id; Cat = 'Services'; Icon = [char]0xE912; Rec = $Rec; Badge = $Badge; Svc = $Svc
       Title = $Title; Desc = $Desc; Warn = $Warn
       Reg   = @( @{ P = "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc"; N = 'Start'; V = 4; D = $Default; M = $Default } )
       After = { Sync-Service $t.Svc }
       Requires = { [bool](Get-Service -Name $t.Svc -ErrorAction SilentlyContinue) -or (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($t.Svc)") } }
}

# --- Startup apps: one card per Run-key entry / Startup-folder shortcut, toggled like Task Manager does.
function Get-StartupTweaks {
    $sources = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )
    $items = @()
    foreach ($src in $sources) {
        $k = Get-Item -LiteralPath $src.Run -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($n in $k.GetValueNames()) {
            if (-not $n -or $n -match 'SecurityHealth') { continue }
            $label = ($n -replace '_[0-9A-Fa-f]{16,}$', '' -replace '[\d.]{4,}$', '' -replace 'AutoLaunch$', '').Trim()
            $items += @{ Name = $n; Label = $label; Command = "$($k.GetValue($n))"; Approved = $src.Approved }
        }
    }
    $folder = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    foreach ($f in Get-ChildItem $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
        $items += @{ Name = $f.Name; Label = $f.BaseName; Command = $f.FullName; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    }
    foreach ($it in $items) {
        $exe = if ($it.Command -match '"([^"]+)"') { $Matches[1] } else { ($it.Command -split '\s+')[0] }
        $leaf = try { Split-Path $exe -Leaf } catch { $exe }
        @{ Id = "startup:$($it.Name)@$(Split-Path $it.Approved -Leaf)"; Cat = 'Startup'; Icon = [char]0xE768; Rec = $false
           Title = "Don't auto-start $($it.Label)"
           Desc  = "Stops $leaf launching at sign-in and running in the background while you play."
           Warn  = "You want $($it.Label) ready the moment you sign in. You can still open it normally."
           StartupName = $it.Name; StartupKey = $it.Approved
           Test  = { $v = Get-RegValue $t.StartupKey $t.StartupName; [bool]($v -and ($v[0] -band 1)) }
           On    = { Set-RegValue $t.StartupKey $t.StartupName ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary'; $script:Backup.Custom[$t.Id] = $true }
           Off   = { Set-RegValue $t.StartupKey $t.StartupName ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary'; $script:Backup.Custom.Remove($t.Id) } }
    }
}

# --- Network adapter properties whose numbers differ by driver: pick the value by its display name.
function Get-AdvTargets([string]$Keyword, [string]$DisplayPattern) {
    $cached = Get-AdvPropsAll
    @(Get-UpAdapters | ForEach-Object {
        $an = $_.Name
        $prop = $cached | Where-Object { $_.Name -eq $an -and $_.RegistryKeyword -eq $Keyword } | Select-Object -First 1
        if ($prop) {
            $vals = @($prop.ValidDisplayValues); $i = -1
            for ($j = 0; $j -lt $vals.Count; $j++) { if ($vals[$j] -match $DisplayPattern) { $i = $j; break } }
            if ($i -ge 0) { [pscustomobject]@{ Name = $_.Name; Current = "$($prop.RegistryValue[0])"; Target = "$($prop.ValidRegistryValues[$i])" } }
        }
    })
}
function Test-AdvDisplay([string]$Keyword, [string]$DisplayPattern) {
    $tg = Get-AdvTargets $Keyword $DisplayPattern
    if (-not $tg.Count) { return $null }
    -not ($tg | Where-Object { $_.Current -ne $_.Target })
}
function Set-AdvDisplay([string]$Id, [string]$Keyword, [string]$DisplayPattern) {
    $tg = Get-AdvTargets $Keyword $DisplayPattern
    if (-not $script:Backup.Custom.ContainsKey($Id)) {
        $script:Backup.Custom[$Id] = @($tg | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Current } })
    }
    foreach ($x in $tg) { Set-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword $Keyword -RegistryValue $x.Target }
}

# Deletes a registry value, saving it first so Restore-RegTweak can put it back.
function Remove-RegTracked([string]$Tweak, [string]$Path, [string]$Name) {
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k -or ($k.GetValueNames() -notcontains $Name)) { return }
    if (-not ($script:Backup.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name })) {
        $script:Backup.Registry += [pscustomobject]@{ Tweak = $Tweak; Path = $Path; Name = $Name; Existed = $true
            Value = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); Type = $k.GetValueKind($Name).ToString() }
    }
    Remove-RegValue $Path $Name
}
# --- Cleanup tweaks: Remove = @( @{ P; N } ). "On" means the values are gone.
function Test-RemoveTweak($t) { -not ($t.Remove | Where-Object { $null -ne (Get-RegValue $_.P $_.N) }) }
function Enable-RemoveTweak($t) { foreach ($e in $t.Remove) { Remove-RegTracked $t.Id $e.P $e.N } }
function Disable-RemoveTweak($t) { [void](Restore-RegTweak $t.Id) }

function Get-NvidiaClassKey {
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' -and "$($_.GetValue('DriverDesc'))" -match 'NVIDIA' } |
        Select-Object -First 1 | ForEach-Object { "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\$($_.PSChildName)" }
}

$DiscreteGpuRx = 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Radeon Pro|Arc A\d|Arc B\d'
function Get-Displays {
    @([NativeDisplay]::ListDisplays() | Where-Object { $_ -notmatch 'Virtual|Parsec|Remote Display|Meta ' } | ForEach-Object {
        $f = $_ -split '\|'
        [pscustomobject]@{ Monitor = $f[0]; Gpu = $f[1]; Hz = [int]$f[2]; Primary = ($f[3] -eq 'True'); Discrete = ($f[1] -match $DiscreteGpuRx) }
    })
}
# GTX 1080 Ti (Pascal): gets its own tab. ZD_FAKE_GPU lets a dev render simulate the card.
function Test-Gtx1080Ti {
    if ($null -eq $script:Is1080Ti) {
        $script:Is1080Ti = ("$env:ZD_FAKE_GPU" -match '1080 Ti') -or [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'GTX 1080 Ti' })
    }
    $script:Is1080Ti
}
# NVIDIA ended Game Ready drivers for GTX 10 cards in late 2025; they get security updates on the R580 branch until Oct 2028.
$PascalSecurityDriver = '582.78'

# FPS cap that keeps G-SYNC/FreeSync engaged: refresh - refresh^2/3600 (Blur Busters / NVIDIA Reflex guidance).
function Get-VrrCap {
    $d = Get-Displays
    $hz = ($d | Where-Object Discrete | Measure-Object Hz -Maximum).Maximum
    if (-not $hz) { $hz = ($d | Measure-Object Hz -Maximum).Maximum }
    if (-not $hz) { return $null }
    [int][Math]::Floor($hz - $hz * $hz / 3600)
}

# --- Virtual audio devices and virtual monitors: one card each, disabled/enabled like Device Manager.
function Get-DeviceTweaks {
    $audioRx = 'Oculus|Steam Streaming|Iriun|NVIDIA Virtual Audio|Elgato Virtual|VB-Audio|Virtual Audio|AMD High Definition Audio'
    $devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        ($_.Class -eq 'MEDIA' -and $_.FriendlyName -match $audioRx) -or
        ($_.Class -in 'Display', 'Monitor' -and $_.FriendlyName -match 'Virtual (Monitor|Display)')
    }
    foreach ($d in $devs) {
        $isAudio = $d.Class -eq 'MEDIA'
        @{ Id = "device:$($d.InstanceId)"; Cat = $(if ($isAudio) { 'Input' } else { 'Graphics' }); Icon = $(if ($isAudio) { [char]0xE767 } else { [char]0xE7F4 })
           Rec = $false; Lat = $isAudio; DeviceId = $d.InstanceId
           Title = "Disable $($d.FriendlyName)"
           Desc  = $(if ($isAudio) { 'An extra audio driver that loads even when unused. Fewer audio drivers means fewer latency spikes (DPCs).' }
                     else { 'A virtual screen driver (VR/streaming). Disable it when you are not using that app.' })
           Warn  = $(if ($d.FriendlyName -match 'AMD High Definition') { 'You get sound through a monitor plugged into the motherboard (HDMI/DP on the CPU graphics).' }
                     else { "You use the app that installed it (VR, phone camera, streaming). Re-enable it here when you need it." })
           Test  = { $all = Get-PnpStates; if (-not $all.ContainsKey($t.DeviceId)) { return $null }; $all[$t.DeviceId] -match 'DISABLED|^22$' }
           On    = { Disable-PnpDevice -InstanceId $t.DeviceId -Confirm:$false -ErrorAction Stop; $script:Backup.Custom[$t.Id] = $true }
           Off   = { Enable-PnpDevice -InstanceId $t.DeviceId -Confirm:$false -ErrorAction Stop; $script:Backup.Custom.Remove($t.Id) } }
    }
}

# --- NVIDIA texture LOD bias on the Fortnite driver profile. Positive bias blurs textures; +15 ("Clay") turns them into
#     flat colours. Fortnite now runs DirectX 12 even in Performance mode, so this follows FR33THY's LOD-Bias script:
#     besides the classic DX bias it sets the newer bias setting, turns off driver-controlled bias, enables transparency
#     supersampling (needed for the override to take), and clears shader caches so DX12 recompiles with the bias.
$NvProfile   = 'Fortnite'
$NvLodId     = [uint32]0x00738E8F   # Texture filtering - LOD Bias (DX), in 1/8 steps
$NvLodLevels = @{ 0 = 'Off'; 24 = 'Soft'; 56 = 'Smudged'; 120 = 'Flat' }
function Get-NvLodSettings([int]$Value) {
    [ordered]@{
        ([uint32]0x00738E8F) = [uint32]$Value                          # LOD Bias (DX)
        ([uint32]0x20403F79) = [uint32][Math]::Min(2 * $Value, 120)    # newer LOD bias setting (FR33THY: 48 positive / 120 clay)
        ([uint32]0x00638E8F) = [uint32]0                               # Driver Controlled LOD Bias: Off
        ([uint32]0x0019BB68) = [uint32]0                               # Negative LOD bias: Allow
        ([uint32]0x10D48A85) = [uint32]8                               # Transparency Supersampling
    }
}
# Effective value of a driver setting on a profile, and whether it is the profile's own value or inherited.
function Get-NvEff([string]$Profile, [uint32]$Id) {
    $r = [NvDrs]::GetEx($Profile, $Id)
    [pscustomobject]@{ Found = ($r[0] -eq 0); Value = $r[1]; Own = ($r[0] -eq 0 -and $r[2] -eq 0); Predefined = ($r[3] -ne 0); Rc = $r[0] }
}
# What to save before changing a setting: the profile's own value, or $null when it was inherited/predefined
# (undo then deletes the profile value, which restores inheritance exactly).
function Get-NvBackupValue([string]$Profile, [uint32]$Id) {
    $e = Get-NvEff $Profile $Id
    if (-not $e.Found -and $e.Rc -ne -160) { throw "Could not read the NVIDIA setting (code $($e.Rc)). Nothing was changed." }
    if ($e.Own -and -not $e.Predefined) { $e.Value } else { $null }
}
function Test-VrrDisplayOn { if (-not (Test-NvAvailable)) { return $false }; $f = [NvDrs]::VrrFlags(); $f -ge 0 -and ($f -band 1) }
function Test-VrrActive {
    if (-not (Test-NvAvailable)) { return $null }   # not NVIDIA: G-SYNC/FreeSync state unknown
    $f = [NvDrs]::VrrFlags(); if ($f -lt 0 -or -not ($f -band 1)) { return $false }
    $ov = Get-NvEff $NvProfile ([uint32]0x10A879CF); $ctl = Get-NvEff $NvProfile ([uint32]0x10A879CE)
    $allowed = (-not $ov.Found) -or $ov.Value -eq 0
    $vctl = (-not $ctl.Found) -or $ctl.Value -ne 0
    $allowed -and $vctl
}

function Test-NvAvailable { if ($null -eq $script:NvOk) { $script:NvOk = [NvDrs]::Available($NvProfile) }; $script:NvOk }
function Get-NvLod { $v = [NvDrs]::Get($NvProfile, $NvLodId); if ($v -lt -1) { return $null }; if ($v -lt 0) { 0 } else { [int]$v } }

# Deletes the NVIDIA and DirectX shader caches. They rebuild automatically; the first match afterwards may stutter briefly.
function Clear-ShaderCaches {
    $n = 0
    foreach ($dir in "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache") {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $n++ } catch {}
        }
    }
    $n
}

# Saved originals, keyed by setting id (decimal string). Older backups stored only Value/Ctl.
function Get-NvLodBackup {
    $b = $script:Backup.Custom['nvlod']; if (-not $b) { return $null }
    $h = @{}
    $props = if ($b -is [hashtable]) { $b.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = "$($_.Key)"; Value = $_.Value } } } else { $b.PSObject.Properties }
    foreach ($p in $props) {
        switch ($p.Name) { 'Value' { $h["$([uint32]0x00738E8F)"] = $p.Value } 'Ctl' { $h["$([uint32]0x002ECAF2)"] = $p.Value } default { $h[$p.Name] = $p.Value } }
    }
    $h
}
function Set-NvLod([int]$Value) {
    if (-not (Test-NvAvailable)) { throw 'Needs an NVIDIA graphics card with a Fortnite driver profile.' }
    if ($Value -eq 0) { Restore-NvLod; return }
    if (Test-FortniteRunning) { throw 'Close Fortnite first so the shader cache can be cleared.' }
    $settings = Get-NvLodSettings $Value
    $orig = Get-NvLodBackup; if (-not $orig) { $orig = @{} }
    foreach ($id in $settings.Keys) {
        if (-not $orig.ContainsKey("$id")) { $orig["$id"] = Get-NvBackupValue $NvProfile $id }
    }
    $script:Backup.Custom['nvlod'] = $orig
    $script:Backup.Custom['nvlodvalue'] = $Value
    Save-Backup
    foreach ($id in $settings.Keys) {
        $r = [NvDrs]::Set($NvProfile, $id, $settings[$id])
        if ($r -ne 0 -and $id -eq $NvLodId) { throw "The NVIDIA driver refused the change (code $r)." }
    }
    [void](Clear-ShaderCaches)
}
function Restore-NvLod {
    $orig = Get-NvLodBackup
    if (-not $orig) { foreach ($id in (Get-NvLodSettings 0).Keys) { [void][NvDrs]::Delete($NvProfile, $id) } }
    else {
        foreach ($k in $orig.Keys) {
            $id = [uint32]$k
            if ($null -eq $orig[$k]) { [void][NvDrs]::Delete($NvProfile, $id) } else { [void][NvDrs]::Set($NvProfile, $id, [uint32]$orig[$k]) }
        }
    }
    if (-not (Test-FortniteRunning)) { [void](Clear-ShaderCaches) }
    $script:Backup.Custom.Remove('nvlod'); $script:Backup.Custom.Remove('nvlodvalue')
    foreach ($id in 'nvlod-soft', 'nvlod-smudge', 'nvlod-flat') { $script:Backup.Custom.Remove($id) }
    Save-Backup
}

# --- Fortnite graphics presets. Every preset writes the same keys so switching between them is clean.
$PresetKeys = [ordered]@{
    'sg.ResolutionQuality' = 'ScalabilityGroups'; 'sg.ViewDistanceQuality' = 'ScalabilityGroups'; 'sg.TextureQuality' = 'ScalabilityGroups'
    'sg.ShadowQuality' = 'ScalabilityGroups'; 'sg.EffectsQuality' = 'ScalabilityGroups'; 'sg.PostProcessQuality' = 'ScalabilityGroups'
    'sg.GlobalIlluminationQuality' = 'ScalabilityGroups'; 'sg.ReflectionQuality' = 'ScalabilityGroups'; 'sg.FoliageQuality' = 'ScalabilityGroups'
    'sg.ShadingQuality' = 'ScalabilityGroups'; 'sg.LandscapeQuality' = 'ScalabilityGroups'; 'sg.AntiAliasingQuality' = 'ScalabilityGroups'
    'MeshQuality' = 'PerformanceMode'; 'PreferredFeatureLevel' = 'D3DRHIPreference'
    'bShowGrass' = $null; 'bMotionBlur' = $null; 'bUseDynamicResolution' = $null
    'PotentiallyUpscaledResolutionQuality' = $null; 'NeverUpscaledResolutionQuality' = $null
}
# Res = 3D resolution %, View/Tex/Fx = 0 Low .. 3 Epic, Mesh = 0 Low .. 2 High, Aa = anti-aliasing 0..3
function New-PresetValues([int]$Res, [int]$View, [int]$Tex, [int]$Mesh, [int]$Fx, [int]$Aa, [bool]$Grass, [int]$Lod = 0) {
    $fxs = "$Fx"
    [ordered]@{
        'sg.ResolutionQuality' = "$Res"; 'sg.ViewDistanceQuality' = "$View"; 'sg.TextureQuality' = "$Tex"
        'sg.ShadowQuality' = $(if ($Fx -ge 3) { '3' } else { '0' }); 'sg.EffectsQuality' = $fxs; 'sg.PostProcessQuality' = $fxs
        'sg.GlobalIlluminationQuality' = $(if ($Fx -ge 3) { '3' } else { '0' }); 'sg.ReflectionQuality' = $(if ($Fx -ge 3) { '3' } else { '0' })
        'sg.FoliageQuality' = $fxs; 'sg.ShadingQuality' = $fxs; 'sg.LandscapeQuality' = $fxs; 'sg.AntiAliasingQuality' = "$Aa"
        'MeshQuality' = "$Mesh"; 'PreferredFeatureLevel' = 'es31'
        'bShowGrass' = $(if ($Grass) { 'True' } else { 'False' }); 'bMotionBlur' = 'False'; 'bUseDynamicResolution' = 'False'
        'PotentiallyUpscaledResolutionQuality' = ('{0}.000000' -f $Res); 'NeverUpscaledResolutionQuality' = ('{0}.000000' -f $Res)
        'NvLod' = $Lod
    }
}
function Get-ResBoxValue {
    $v = 0
    if (-not [int]::TryParse($script:ResBox.Text, [ref]$v) -or $v -lt 25 -or $v -gt 99) { throw 'Enter a 3D resolution between 25 and 99.' }
    $v
}
function Test-Preset($t) {
    if (-not (Test-Path $IniPath)) { return $false }
    $lines = Get-Content $IniPath
    foreach ($k in $t.Preset.Keys) {
        if (-not $PresetKeys.Contains($k) -or $k -eq 'sg.ResolutionQuality') { continue }
        $cur = Get-IniValue $lines $k
        if ($null -eq $cur) { continue }   # missing = game default, Fortnite does not save it
        if ([double]::TryParse("$cur", [ref]$null) -and [double]::TryParse("$($t.Preset[$k])", [ref]$null)) {
            if ([double]$cur -ne [double]$t.Preset[$k]) { return $false }
        } elseif ("$cur" -ne "$($t.Preset[$k])") { return $false }
    }
    if ($script:CurrentNvLod -ne $null -and [int]$t.Preset['NvLod'] -ne $script:CurrentNvLod) { return $false }
    $true
}
function Invoke-Preset($t) {
    Assert-IniWritable
    $lines = Get-Content $IniPath
    # Remember the original value of every preset key the first time any preset is applied.
    $orig = $script:Backup.Custom['presets']
    if (-not $orig) { $orig = @{}; foreach ($k in $PresetKeys.Keys) { $orig[$k] = Get-IniValue $lines $k }; $script:Backup.Custom['presets'] = $orig }
    foreach ($k in $t.Preset.Keys) {
        if (-not $PresetKeys.Contains($k)) { continue }
        $sec = $PresetKeys[$k]; $section = if ($sec) { "[$sec]" } else { $IniSection }
        $lines = Set-IniValue $lines $k $t.Preset[$k] $section
    }
    Set-Content -Path $IniPath -Value $lines -Encoding UTF8
    $extra = ''
    if (Test-NvAvailable) { Set-NvLod ([int]$t.Preset['NvLod']) }
    elseif ([int]$t.Preset['NvLod'] -gt 0) { $extra = ' Texture blur skipped: it needs an NVIDIA graphics card.' }
    Save-Backup
    Update-All
    $script:Backup.Custom['lastpreset'] = @{ Title = $t.Title; Values = $t.Preset }
    Save-Backup
    Add-History "Preset: $($t.Title)" 'preset' $null
    "$($t.Title) applied.$extra Launch Fortnite to see it."
}
function Undo-Presets {
    $orig = $script:Backup.Custom['presets']
    if (-not $orig) { return 'No preset has been applied, nothing to undo.' }
    Assert-IniWritable
    $lines = Get-Content $IniPath
    foreach ($k in $PresetKeys.Keys) {
        $sec = $PresetKeys[$k]; $section = if ($sec) { "[$sec]" } else { $IniSection }
        $lines = Set-IniValue $lines $k $orig.$k $section
    }
    Set-Content -Path $IniPath -Value $lines -Encoding UTF8
    if ($script:Backup.Custom.ContainsKey('nvlod')) { Restore-NvLod }
    $script:Backup.Custom.Remove('presets'); $script:Backup.Custom.Remove('lastpreset'); Save-Backup
    Update-All
    'Your graphics settings from before the presets are back.'
}

# --- Game session: close (or pause) background apps while you play, then reopen them afterwards.
$SessionApps = @(
    @{ Key = 'operagx';   Name = 'Opera GX';             PathRx = '\\Opera GX\\';                         Main = 'opera.exe' }
    @{ Key = 'streamdock'; Name = 'Stream Dock';         PathRx = '\\Stream ?Dock\\';                     Main = 'StreamDock.exe' }
    @{ Key = 'adobe';     Name = 'Adobe Creative Cloud'; PathRx = '\\Adobe\\(Adobe )?Creative Cloud';     Main = 'Creative Cloud.exe' }
    @{ Key = 'xbox';      Name = 'Xbox app';             PathRx = '\\XboxPcApp|\\Microsoft\.GamingApp';   Main = $null }
    @{ Key = 'exm';       Name = 'EXM';                  PathRx = '\\EXM\\EXM\.exe$';                     Main = 'EXM.exe' }
    @{ Key = 'onedrive';  Name = 'OneDrive';             PathRx = '\\OneDrive\.exe$';                      Main = 'OneDrive.exe' }
    @{ Key = 'teams';     Name = 'Microsoft Teams';      PathRx = '\\ms-teams\.exe$';                      Main = 'ms-teams.exe' }
    @{ Key = 'phonelink'; Name = 'Phone Link, Widgets, Copilot'; PathRx = '\\(PhoneExperienceHost|CrossDeviceService|CrossDeviceResume|Widgets|WidgetService|Copilot)\.exe$'; Main = $null }
    @{ Key = 'wallpaper'; Name = 'Wallpaper Engine (paused, not closed)'; PathRx = '\\wallpaper_engine\\'; Main = $null; Pause = $true }
    # RGB and monitoring software: polls sensors and lighting chips, a common cause of micro-stutter (the vendor's background
    # service keeps fan curves and colours, so only the window/app is closed)
    @{ Detect = 'SignalRGB'; Key = 'signalrgb';  Name = 'SignalRGB';                   PathRx = '\\SignalRgb(Launcher)?\.exe$';                 Main = 'SignalRgbLauncher.exe' }
    @{ Detect = 'OpenRGB'; Key = 'openrgb';    Name = 'OpenRGB';                     PathRx = '\\OpenRGB\.exe$';                              Main = 'OpenRGB.exe' }
    @{ Detect = 'NZXT CAM'; Key = 'nzxtcam';    Name = 'NZXT CAM';                    PathRx = '\\(NZXT CAM|cam_helper)\.exe$';                 Main = 'NZXT CAM.exe' }
    @{ Detect = 'iCUE'; Key = 'icueui';     Name = 'Corsair iCUE (window)';       PathRx = '\\iCUE\.exe$';                                 Main = 'iCUE.exe' }
    @{ Detect = 'Logitech G HUB'; Key = 'ghubui';     Name = 'Logitech G HUB (window)';     PathRx = '\\lghub\.exe$';                                Main = 'lghub.exe' }
    @{ Detect = 'Armoury Crate'; Key = 'armouryui';  Name = 'Armoury Crate (window)';      PathRx = '\\(ArmouryCrate|ArmourySwAgent|ArmouryCrate\.UserSessionHelper)\.exe$'; Main = 'ArmouryCrate.exe' }
    @{ Detect = 'MSI Center'; Key = 'msicenterui'; Name = 'MSI Center (window)';        PathRx = '\\(MSI Center|MSI\.CentralServer)\.exe$';       Main = 'MSI Center.exe' }
    @{ Detect = 'Gigabyte Control Center|RGB Fusion|APP Center'; Key = 'gigabyte';   Name = 'Gigabyte Control Center / RGB Fusion'; PathRx = '\\(GCC|LEDKeeper2|RGBFusion|AppCenter)\.exe$'; Main = 'GCC.exe' }
    @{ Detect = 'L-Connect'; Key = 'lconnect';   Name = 'Lian Li L-Connect';           PathRx = '\\L-Connect ?3\.exe$';                         Main = $null }
    @{ Detect = 'HWiNFO|HWMonitor|AIDA64|Core Temp'; Key = 'hwmon';      Name = 'Hardware monitors (HWiNFO, HWMonitor, AIDA64, Core Temp)'; PathRx = '\\(HWiNFO64|HWiNFO32|HWMonitor|CoreTemp|aida64)\.exe$'; Main = $null }
    @{ Detect = 'OMEN Gaming Hub'; Key = 'omenhub';    Name = 'Omen Gaming Hub';             PathRx = '\\(OmenCommandCenterBackground|HP\.Omen\.Overlay\.Helper|OMEN Gaming Hub)\.exe$'; Main = $null }
    @{ Detect = 'Lenovo Vantage|Legion Zone'; Key = 'lenovoui';   Name = 'Lenovo Vantage / Legion Zone'; PathRx = '\\(LenovoVantage|LegionZone|Lenovo\.Modern\.ImController\.PluginHost)\.exe$'; Main = $null }
    @{ Detect = 'SupportAssist'; Key = 'dellsa';     Name = 'Dell SupportAssist';          PathRx = '\\(SupportAssistUI|SupportAssistAgent|DDVDataCollector|DDVRulesProcessor)\.exe$'; Main = $null }
    @{ Detect = 'Dropbox|Google Drive|iCloud'; Key = 'cloudsync';  Name = 'Dropbox, Google Drive, iCloud'; PathRx = '\\(Dropbox|GoogleDriveFS|iCloudServices|iCloudDrive|iCloudPhotos)\.exe$'; Main = $null }
    @{ Detect = 'Rainmeter|Lively Wallpaper'; Key = 'desktopfx';  Name = 'Rainmeter / Lively Wallpaper'; PathRx = '\\(Rainmeter|Lively|Lively\.PlayerCefSharp|Lively\.PlayerMpv)\.exe$'; Main = 'Rainmeter.exe' }
    # off by default: these are things many people want running during a match
    @{ Detect = 'Steam|Battle\.net|EA app|Ubisoft Connect|GOG GALAXY|Riot Client'; Key = 'launchers';  Name = 'Idle game launchers (Steam, Battle.net, EA, Ubisoft, GOG, Riot)'; PathRx = '\\(steam|steamwebhelper|Battle\.net|EADesktop|EABackgroundService|UbisoftConnect|upc|GalaxyClient|GalaxyClient Helper|RiotClientServices|RiotClientUx|RiotClientUxRender)\.exe$'; Main = $null }
    @{ Detect = 'Medal'; Key = 'medal';      Name = 'Medal (stops clip recording)'; PathRx = '\\(Medal|MedalEncoder|MedalRecorder)\.exe$';  Main = 'Medal.exe' }
    @{ Detect = 'Overwolf|Outplayed|CurseForge'; Key = 'overwolf';   Name = 'Overwolf / Outplayed / CurseForge (stops clips and overlays)'; PathRx = '\\(Overwolf|OverwolfBrowser|OverwolfHelper|OverwolfHelper64|OverwolfLauncher|OverwolfStarter|CurseForge)\.exe$'; Main = 'OverwolfLauncher.exe' }
    @{ Detect = 'Razer Cortex'; Key = 'razercortex'; Name = 'Razer Cortex';               PathRx = '\\(RazerCortex|Cortex|RzKLService)\.exe$';     Main = $null }
    @{ Detect = 'SteelSeries GG'; Key = 'steelseries'; Name = 'SteelSeries GG (stops Sonar audio)'; PathRx = '\\(SteelSeriesGG|SteelSeriesGGClient|SteelSeriesEngine3)\.exe$'; Main = 'SteelSeriesGG.exe' }
)
$SessionFile = Join-Path $DataDir 'game-session.json'
function Get-SessionPrefs {
    $p = @{}; foreach ($a in $SessionApps) { $p[$a.Key] = $true }
    $p['xbox'] = $true; $p['streamdock'] = $false   # Stream Dock stays open by default: many people use it mid-game
    foreach ($k in 'launchers', 'medal', 'overwolf', 'razercortex', 'steelseries') { $p[$k] = $false }   # clip recorders, Sonar, launchers you may be using
    $saved = $script:Backup.Custom['sessionprefs']
    if ($saved -is [hashtable]) { foreach ($k in @($saved.Keys)) { $p[$k] = [bool]$saved[$k] } }
    elseif ($saved) { $saved.PSObject.Properties | ForEach-Object { $p[$_.Name] = [bool]$_.Value } }
    $p
}
# Display names from Settings > Apps, read once per refresh (used to show only Game Mode apps that exist on this PC)
function Get-InstalledNames {
    Get-Cached 'installednames' {
        @(foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
            foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) { $n = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DisplayName; if ($n) { "$n" } }
        })
    } 120
}
# full paths of running programs, read once and shared by every check that needs them
function Get-ProcessPaths { Get-Cached 'procpaths' { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ }) } }
function Test-SessionAppPresent($app) {
    if (-not $app.Detect) { return $true }
    if ((Get-InstalledNames) -match "^($($app.Detect))") { return $true }
    @((Get-ProcessPaths) -match $app.PathRx).Count -gt 0
}
function Get-AppProcesses($app) {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -match $app.PathRx } catch { $false } })
}
function Get-WallpaperExe {
    $p = Get-Process wallpaper64, wallpaper32 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { try { $p.Path } catch { $null } }
}
function Start-GameSession {
    $prefs = Get-SessionPrefs
    $closed = @(); $names = @()
    $adobeOpen = [bool](Get-Process -Name 'Adobe Premiere Pro', 'AfterFX', 'aerender', 'Photoshop', 'Adobe Media Encoder' -ErrorAction SilentlyContinue)
    foreach ($app in $SessionApps | Where-Object { $prefs[$_.Key] }) {
        if ($app.Key -eq 'adobe' -and $adobeOpen) { continue }   # closing Creative Cloud under Premiere/AE breaks fonts and licensing
        if ($app.Pause) {
            $we = Get-WallpaperExe
            if ($we) { Start-Process $we -ArgumentList '-control', 'pause' -WindowStyle Hidden; $closed += @{ Key = $app.Key; Pause = $we }; $names += 'Wallpaper Engine (paused)' }
            continue
        }
        $procs = Get-AppProcesses $app
        if (-not $procs.Count) { continue }
        $relaunch = $null
        if ($app.Main) { $m = $procs | Where-Object { (Split-Path $_.Path -Leaf) -eq $app.Main } | Select-Object -First 1; if ($m) { $relaunch = $m.Path } }
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        $closed += @{ Key = $app.Key; Relaunch = $relaunch }
        $names += $app.Name
    }
    @{ Started = (Get-Date).ToString('o'); Closed = $closed; SawFortnite = $false } | ConvertTo-Json -Depth 4 | Set-Content $SessionFile -Encoding UTF8
    $script:SessionTimer.Start()
    if ($names) { "Game session on. Closed: $($names -join ', '). Everything reopens when Fortnite closes or you press End." }
    else { 'Game session on. Nothing from your list was running.' }
}
function Stop-GameSession {
    if (-not (Test-Path $SessionFile)) { return 'No game session is running.' }
    $sess = Get-Content $SessionFile -Raw | ConvertFrom-Json
    $back = @()
    foreach ($c in @($sess.Closed)) {
        if ($c.Pause) { if (Test-Path $c.Pause) { Start-Process $c.Pause -ArgumentList '-control', 'play' -WindowStyle Hidden; $back += 'Wallpaper Engine' }; continue }
        if ($c.Relaunch -and (Test-Path $c.Relaunch)) {
            # explorer.exe starts it as you, not as administrator like ZeroDelay
            Start-Process explorer.exe -ArgumentList "`"$($c.Relaunch)`""
            $back += ($SessionApps | Where-Object { $_.Key -eq $c.Key }).Name
        }
    }
    Remove-Item $SessionFile -Force -ErrorAction SilentlyContinue
    $script:SessionTimer.Stop()
    if ($back) { "Game session ended. Reopened: $($back -join ', ')." } else { 'Game session ended.' }
}
function Test-GameSession { Test-Path $SessionFile }

# --- ZeroDelay Game Mode: one switch that prepares the PC for a match and undoes it afterwards.
$GameModeFile = Join-Path $DataDir 'game-mode.json'
$GameModeSteps = [ordered]@{
    apps     = @{ Name = 'Close or pause background apps';            Default = $true }
    plan     = @{ Name = 'Switch to the ZeroDelay power plan';         Default = $true }
    priority = @{ Name = 'Lower priority of apps left open';           Default = $true }
    dnd      = @{ Name = 'Silence Windows notifications';              Default = $true }
    updates  = @{ Name = 'Pause Windows Update downloads';             Default = $true }
    dns      = @{ Name = 'Flush DNS cache';                            Default = $true }
    nvreplay = @{ Name = 'Pause NVIDIA Instant Replay (no clips)';    Default = $false }
    auto     = @{ Name = 'Turn on when Fortnite starts';               Default = $true }
    autooff  = @{ Name = 'Turn off when Fortnite closes';              Default = $true }
}
# Apps that stay open but drop to Below Normal priority while Game Mode is on.
$GameModeLowPriority = 'Discord', 'Steam', 'steamwebhelper', 'EpicGamesLauncher', 'EpicWebHelper', 'Spotify', 'msedge', 'chrome', 'opera',
                       'firefox', 'OneDrive', 'StreamDock', 'CefViewWing', 'Creative Cloud', 'EXM', 'XboxPcApp'
function Get-GameModePrefs {
    $p = @{}; foreach ($k in $GameModeSteps.Keys) { $p[$k] = $GameModeSteps[$k].Default }
    $saved = $script:Backup.Custom['gamemodeprefs']
    if ($saved -is [hashtable]) { foreach ($k in @($saved.Keys)) { $p[$k] = [bool]$saved[$k] } }
    elseif ($saved) { $saved.PSObject.Properties | ForEach-Object { $p[$_.Name] = [bool]$_.Value } }
    $p
}
function Test-ZDGameMode { Test-Path $GameModeFile }
function Get-ZeroDelayPlanGuid {
    $line = powercfg /list | Where-Object { $_ -match 'ZeroDelay' } | Select-Object -First 1
    if ($line -and $line -match $GuidRx) { $Matches[0] } else { $null }
}
function Enable-ZDGameMode {
    if (Test-ZDGameMode) { return 'Game Mode is already on.' }
    $prefs = Get-GameModePrefs
    $state = @{ Started = (Get-Date).ToString('o'); SawFortnite = (Test-FortniteRunning); Done = @(); ClosedCount = 0; FreedMb = 0 }
    $done = @()
    $memBefore = try { [double](Get-MemInfo).Available } catch { 0 }
    if ($prefs.apps) {
        $msg = Start-GameSession
        $script:SessionTimer.Stop()          # Game Mode decides when apps come back
        $state.Session = $true
        if ($msg -match 'Closed: (.+?)\. Everything') { $done += "closed $($Matches[1])"; $state.ClosedCount = @($Matches[1] -split ', ').Count }
        if ($state.ClosedCount -and $memBefore) { Start-Sleep -Milliseconds 700; try { $state.FreedMb = [int][Math]::Max(0, ([double](Get-MemInfo).Available - $memBefore) / 1MB) } catch {} }
    }
    if ($prefs.plan -and -not (Test-BoosterOwnsPlan)) {    # a trusted ping booster that set its own plan keeps it
        $cur = Get-ActivePowerScheme
        if ($cur.Name -notmatch 'ZeroDelay') {
            $zd = Get-ZeroDelayPlanGuid
            if (-not $zd) { Invoke-TweakOn ($Tweaks | Where-Object { $_.Id -eq 'zdplan' }); $zd = Get-ZeroDelayPlanGuid }
            else { powercfg /setactive $zd }
            if ($zd) { $state.PrevPlan = $cur.Guid; $done += 'ZeroDelay power plan' }
        }
        # Other tools (ExitLag, EXM) rewrite the active plan's values, so re-apply ours at the start of every match.
        $values = @($ZeroDelayPlanValues)
        if ((Get-CpuName) -notmatch 'X3D') { $values += , $ZeroDelayCoreParking }
        foreach ($v in $values) { powercfg /setacvalueindex scheme_current $v[0] $v[1] $v[2] 2>$null | Out-Null }
        powercfg /setactive scheme_current 2>$null | Out-Null
    }
    if ($prefs.priority) {
        $changed = @()
        foreach ($proc in Get-Process -Name $GameModeLowPriority -ErrorAction SilentlyContinue) {
            try {
                if ($proc.PriorityClass -in 'Normal', 'AboveNormal', 'High') {
                    $changed += @{ Id = $proc.Id; Prev = "$($proc.PriorityClass)" }
                    $proc.PriorityClass = 'BelowNormal'
                }
            } catch {}
        }
        $state.Priorities = $changed
        if ($changed.Count) { $done += "$($changed.Count) background processes lowered" }
    }
    if ($prefs.dnd) {
        $state.ToastPrev = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 'DWord'
        $done += 'notifications silenced'
    }
    if ($prefs.updates) {
        foreach ($svc in 'wuauserv', 'BITS', 'DoSvc', 'UsoSvc') { Stop-Service $svc -Force -ErrorAction SilentlyContinue }
        $done += 'update downloads paused'
    }
    if ($prefs.dns) { Clear-DnsClientCache -ErrorAction SilentlyContinue; $done += 'DNS flushed' }
    if ($prefs.nvreplay) {
        try {
            $st = Invoke-NvMcp 'nvapp_overlay_get_status'
            if ($st.instantReplayEnabled -eq $true) {
                $state.NvReplayPaused = $true
                $state | ConvertTo-Json -Depth 5 | Set-Content $GameModeFile -Encoding UTF8
                if (Set-NvInstantReplay $false) { $done += 'Instant Replay paused' }
                else { try { if ((Invoke-NvMcp 'nvapp_overlay_get_status').instantReplayEnabled -eq $true) { $state.NvReplayPaused = $false } } catch {} }
            }
        } catch {}   # overlay off or NVIDIA App closed: nothing to pause
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content $GameModeFile -Encoding UTF8
    Add-History 'Game Mode turned on' 'gamemode' $null
    Update-GameModeUi
    "Game Mode on: $($done -join ', ')."
}
function Disable-ZDGameMode {
    if (-not (Test-ZDGameMode)) { return 'Game Mode is already off.' }
    $state = Get-Content $GameModeFile -Raw | ConvertFrom-Json
    $back = @()
    if ($state.Session) { $m = Stop-GameSession; if ($m -match 'Reopened: (.+)\.') { $back += "reopened $($Matches[1])" } }
    if ($state.NvReplayPaused) {
        $ok = $false
        for ($i = 0; $i -lt 3 -and -not $ok; $i++) { try { $ok = Set-NvInstantReplay $true } catch { Start-Sleep -Seconds 3 } }
        if ($ok) { $back += 'Instant Replay' } else { $back += 'NOT Instant Replay (turn it back on with Alt+Z)' }
    }
    if ($state.PrevPlan -and (Get-ActivePowerScheme).Name -match 'ZeroDelay') {
        if (powercfg /list | Where-Object { $_ -match $state.PrevPlan }) { powercfg /setactive $state.PrevPlan; $back += 'previous power plan' }
    }
    foreach ($pp in @($state.Priorities)) {
        try { $proc = Get-Process -Id $pp.Id -ErrorAction Stop; $proc.PriorityClass = $pp.Prev } catch {}
    }
    if ($state.PSObject.Properties.Name -contains 'ToastPrev') {
        if ($null -eq $state.ToastPrev) { Remove-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' }
        else { Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' ([int]$state.ToastPrev) 'DWord' }
        $back += 'notifications'
    }
    Remove-Item $GameModeFile -Force -ErrorAction SilentlyContinue
    Add-History 'Game Mode turned off' 'gamemode' $null
    Update-GameModeUi
    if ($back) { "Game Mode off. Restored: $($back -join ', ')." } else { 'Game Mode off.' }
}

function Get-CpuName {
    if (-not $script:CpuName) { $script:CpuName = "$((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name)" }
    $script:CpuName
}

# --- Starts or stops a service to match its registry Start value (2 = automatic, 3 = manual, 4 = disabled)
function Sync-Service([string]$Name) {
    $start = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" 'Start'
    if ($start -eq 4) { Stop-Service $Name -Force -ErrorAction SilentlyContinue }
    elseif ($start -eq 2) { Start-Service $Name -ErrorAction SilentlyContinue }
}

# --- Network adapter advanced properties (standard *Keywords)
function Test-AdvProp([string]$Keyword, $Value) {
    $props = @(Get-AdvPropsAll | Where-Object { $_.RegistryKeyword -eq $Keyword })
    if (-not $props.Count) { return $null }
    -not ($props | Where-Object { "$($_.RegistryValue[0])" -ne "$Value" })
}
function Set-AdvProp([string]$Id, [string]$Keyword, $Value) {
    $props = @(Get-UpAdapters | ForEach-Object { Get-NetAdapterAdvancedProperty -Name $_.Name -RegistryKeyword $Keyword -ErrorAction SilentlyContinue })
    if (-not $script:Backup.Custom.ContainsKey($Id)) {
        $script:Backup.Custom[$Id] = @($props | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = "$($_.RegistryValue[0])" } })
    }
    foreach ($p in $props) { Set-NetAdapterAdvancedProperty -Name $p.Name -RegistryKeyword $Keyword -RegistryValue $Value }
}
function Reset-AdvProp([string]$Id, [string]$Keyword, $Default) {
    if ($script:Backup.Custom.ContainsKey($Id)) {
        foreach ($o in @($script:Backup.Custom[$Id])) {
            Set-NetAdapterAdvancedProperty -Name $o.Name -RegistryKeyword $Keyword -RegistryValue $o.Value -ErrorAction SilentlyContinue
        }
        $script:Backup.Custom.Remove($Id)
    } else {
        foreach ($a in Get-UpAdapters) { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $Keyword -RegistryValue $Default -ErrorAction SilentlyContinue }
    }
}

# --- Applies registry mouse/keyboard values to the live session without signing out
function Update-InputFromRegistry {
    $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
    [void][NativeInput]::SystemParametersInfo(0x0004, 0, [int[]]@([int]$m.MouseThreshold1, [int]$m.MouseThreshold2, [int]$m.MouseSpeed), 0x02)
    $k = Get-ItemProperty 'HKCU:\Control Panel\Keyboard'
    [void][NativeInput]::SystemParametersInfo(0x0017, [uint32]$k.KeyboardDelay, [IntPtr]::Zero, 0x02)  # SPI_SETKEYBOARDDELAY
    [void][NativeInput]::SystemParametersInfo(0x000B, [uint32]$k.KeyboardSpeed, [IntPtr]::Zero, 0x02)  # SPI_SETKEYBOARDSPEED
}

# ================================================================ tweaks ===

$Mmcss = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$Ifeo  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$FortniteExeName\PerfOptions"
$GpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$LayersKey  = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'

$Tweaks = @(
    # ---------------------------------------------------------------- System
    @{ Id = 'zdplan'; Cat = 'Power'; Icon = [char]0xE945; Rec = $true; Lat = $true
       Title = 'ZeroDelay power plan'
       Desc  = 'Our own plan: Ultimate Performance plus CPU 100%, all cores awake, and no USB, PCIe, drive or network power saving.'
       Warn  = 'You are on a laptop on battery (only plugged-in values are tuned). ExitLag and similar apps may switch plans back.'
       Test  = { (Get-ActivePowerScheme).Name -match 'ZeroDelay' }
       On    = {
           $active = Get-ActivePowerScheme
           if (-not $script:Backup.Custom.ContainsKey('zdplan') -and $active.Name -notmatch 'ZeroDelay') {
               $script:Backup.Custom['zdplan'] = @{ Prev = $active.Guid }
           }
           # Reuse our plan if it already exists, otherwise copy the best built-in template available.
           $plan = $null
           $line = powercfg /list | Where-Object { $_ -match 'ZeroDelay' } | Select-Object -First 1
           if ($line -and $line -match $GuidRx) { $plan = $Matches[0] }
           foreach ($tpl in $UltimateTemplate, $HighPerfGuid, $BalancedGuid) {
               if ($plan) { break }
               $out = powercfg -duplicatescheme $tpl 2>$null
               if ($LASTEXITCODE -eq 0 -and "$out" -match $GuidRx) { $plan = $Matches[0] }
           }
           if (-not $plan) { throw 'Windows would not create a new power plan.' }
           powercfg -changename $plan 'ZeroDelay (Ultimate Performance)' 'Low-latency gaming plan created by ZeroDelay' | Out-Null
           $values = @($ZeroDelayPlanValues)
           if ((Get-CpuName) -notmatch 'X3D') { $values += , $ZeroDelayCoreParking }
           foreach ($v in $values) { powercfg /setacvalueindex $plan $v[0] $v[1] $v[2] 2>$null | Out-Null }
           powercfg /setactive $plan
           if ($LASTEXITCODE -ne 0) { throw 'Windows refused to switch to the ZeroDelay plan.' }
       }
       Off   = {
           $prev = $script:Backup.Custom['zdplan'].Prev
           if (-not $prev -or -not (powercfg /list | Where-Object { $_ -match $prev })) { $prev = $BalancedGuid }
           powercfg /setactive $prev
           # Remove our plan so it does not clutter the list.
           powercfg /list | Where-Object { $_ -match 'ZeroDelay' } | ForEach-Object { if ($_ -match $GuidRx) { powercfg -delete $Matches[0] 2>$null | Out-Null } }
           $script:Backup.Custom.Remove('zdplan')
       } }

    @{ Id = 'power'; Cat = 'Power'; Icon = [char]0xE945; Rec = $true
       Title = 'Ultimate Performance power plan'
       Desc  = 'Keeps CPU cores awake and at full clock so frames are never waiting on power saving.'
       Warn  = 'You are on a laptop running on battery. Battery life and fan noise will get noticeably worse.'
       Test  = { (Get-ActivePowerScheme).Name -match 'Ultimate Performance|High performance' }
       On    = {
           if (-not $script:Backup.Custom.ContainsKey('power')) { $script:Backup.Custom['power'] = (Get-ActivePowerScheme).Guid }
           $target = $null
           $existing = powercfg /list | Where-Object { $_ -match 'Ultimate Performance' } | Select-Object -First 1
           if ($existing -and $existing -match $GuidRx) { $target = $Matches[0] }
           else {
               $out = powercfg -duplicatescheme $UltimateTemplate 2>$null
               if ($LASTEXITCODE -eq 0 -and "$out" -match $GuidRx) { $target = $Matches[0] } else { $target = $HighPerfGuid }
           }
           powercfg /setactive $target 2>$null
           if ($LASTEXITCODE -ne 0) { throw 'Windows refused the plan (common on Modern Standby laptops).' }
       }
       Off   = {
           $prev = $script:Backup.Custom['power']; if (-not $prev) { $prev = $BalancedGuid }
           powercfg /setactive $prev 2>$null
           $script:Backup.Custom.Remove('power')
       } }

    @{ Id = 'gamemode'; Cat = 'System'; Icon = [char]0xE7FC; Rec = $true
       Title = 'Windows Game Mode'
       Desc  = 'Prioritises the game and stops Windows Update from installing or restarting mid-match.'
       Warn  = 'You stream or record with software that stutters when Game Mode is on (rare on current Windows).'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'AutoGameModeEnabled'; V = 1; D = $null; M = 1 } ) }

    @{ Id = 'prioSep'; Cat = 'System'; Icon = [char]0xE9D9; Rec = $true
       Title = 'Foreground boost scheduling'
       Desc  = 'Gives the active window shorter, boosted CPU time slices (Win32PrioritySeparation 0x26).'
       Warn  = 'You run heavy background work (renders, compiles) while gaming. Those tasks will slow down.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; N = 'Win32PrioritySeparation'; V = 38; D = 2; M = 2 } ) }

    @{ Id = 'mmcss'; Cat = 'System'; Icon = [char]0xE916; Rec = $true
       Title = 'Maximum performance for games'
       Desc  = 'Raises the Windows multimedia scheduler priority for games and reserves less CPU for background tasks.'
       Warn  = 'You play music or voice chat through apps that crackle when games get more CPU time.'
       Reg   = @(
           @{ P = $Mmcss; N = 'SystemResponsiveness'; V = 10; D = 20; M = 20 }
           @{ P = "$Mmcss\Tasks\Games"; N = 'Priority'; V = 6; D = 2; M = 2 }
           @{ P = "$Mmcss\Tasks\Games"; N = 'Scheduling Category'; V = 'High'; T = 'String'; D = 'Medium'; M = 'Medium' }
           @{ P = "$Mmcss\Tasks\Games"; N = 'SFIO Priority'; V = 'High'; T = 'String'; D = 'Normal'; M = 'Normal' }
       ) }

    @{ Id = 'throttle'; Cat = 'Power'; Icon = [char]0xE7E8; Rec = $true
       Title = 'Turn off power throttling'
       Desc  = 'Stops Windows from parking background game threads on slow, efficient cores.'
       Warn  = 'You are on a laptop and care about battery life more than frame times.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; N = 'PowerThrottlingOff'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'bgapps'; Cat = 'Background'; Icon = [char]0xE895; Rec = $true
       Title = 'Stop background Store apps'
       Desc  = 'Prevents Microsoft Store apps from running and syncing in the background.'
       Warn  = 'You rely on live notifications from Store apps such as Mail, Calendar or Phone Link.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; N = 'GlobalUserDisabled'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'timer'; Cat = 'System'; Icon = [char]0xE823; Rec = $true; Badge = 'restart'
       Title = 'Consistent timer resolution'
       Desc  = 'Lets games keep their high-precision timer even when another window has focus (Windows 11).'
       Warn  = 'You are on Windows 10, where this does nothing, or on battery where it costs a little power.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; N = 'GlobalTimerResolutionRequests'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'usbsuspend'; Cat = 'Power'; Icon = [char]0xE88E; Rec = $true
       Title = 'Turn off USB power-saving'
       Desc  = 'Stops Windows from putting your mouse, keyboard and headset USB ports to sleep.'
       Warn  = 'You are on a laptop on battery. Only the plugged-in setting of the current power plan is changed.'
       Power = @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; V = 0; D = 1 } }

    @{ Id = 'pcie'; Cat = 'Power'; Icon = [char]0xE964; Rec = $true
       Title = 'Turn off PCIe power-saving'
       Desc  = 'Keeps the link to your graphics card and NVMe drive at full speed (Link State Power Management off).'
       Warn  = 'You are on a laptop on battery. Only the plugged-in setting of the current power plan is changed.'
       Power = @{ Sub = '501a4d13-42af-4429-9fd1-a8218c268e20'; Set = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; V = 0; D = 1 } }

    @{ Id = 'widgets'; Cat = 'Background'; Icon = [char]0xE8A1; Rec = $true
       Title = 'Turn off Widgets'
       Desc  = 'Stops the Widgets board and its news feed from running and refreshing in the background.'
       Warn  = 'You use the Widgets panel for weather or news.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; N = 'AllowNewsAndInterests'; V = 0; D = $null; M = 1 } ) }

    @{ Id = 'toasts'; Cat = 'Background'; Icon = [char]0xE7E7; Rec = $false
       Title = 'Mute Windows notifications'
       Desc  = 'Turns off pop-up notifications so nothing draws over the game or steals focus.'
       Warn  = 'You need to see message or calendar pop-ups. This mutes them all the time, not only in-game.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; N = 'ToastEnabled'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'diagtrack'; Cat = 'Services'; Icon = [char]0xE9F9; Rec = $true
       Title = 'Turn off telemetry service'
       Desc  = 'Disables Connected User Experiences and Telemetry, which periodically uses CPU and network.'
       Warn  = 'Your PC is managed by an IT department that relies on diagnostic data.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\DiagTrack'; N = 'Start'; V = 4; D = 2; M = 2 } )
       After = { Sync-Service 'DiagTrack' } }

    @{ Id = 'sysmain'; Cat = 'Services'; Icon = [char]0xEDA2; Rec = $false; Badge = 'advanced'
       Title = 'Turn off SysMain (Superfetch)'
       Desc  = 'Stops Windows pre-loading apps into memory, which can cause disk and CPU bursts mid-game.'
       Warn  = 'You have a hard drive (HDD) or under 16 GB of RAM. SysMain helps those systems more than it costs.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'; N = 'Start'; V = 4; D = 2; M = 2 } )
       After = { Sync-Service 'SysMain' } }

    @{ Id = 'hvci'; Cat = 'System'; Icon = [char]0xE83D; Rec = $false; Badge = 'restart'
       Title = 'Turn off Memory Integrity'
       Desc  = 'Core isolation adds overhead to every driver call. Microsoft lists turning it off as a gaming boost.'
       Warn  = 'You care about maximum security, or play games whose anti-cheat requires it. This lowers protection against malicious drivers.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; N = 'Enabled'; V = 0; D = 1; M = 0 } ) }

    @{ Id = 'closeapps'; Cat = 'Background'; Icon = [char]0xE711; Action = 'Close now'
       Title = 'Close background apps'
       Desc  = 'Closes OneDrive, Teams, Widgets, Phone Link and Copilot for this session. They come back next sign-in.'
       Warn  = ''
       Run   = {
           $names = 'OneDrive', 'ms-teams', 'Teams', 'Widgets', 'WidgetService', 'PhoneExperienceHost', 'YourPhone', 'Copilot', 'GameBar'
           $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
           $procs | Stop-Process -Force -ErrorAction SilentlyContinue
           if ($procs.Count) { "Closed: $(($procs.Name | Sort-Object -Unique) -join ', ')." } else { 'Nothing to close, already clean.' }
       } }

    # ----------------------------------------------------------------- Input
    @{ Id = 'mouse'; Cat = 'Input'; Icon = [char]0xE962; Rec = $true
       Title = 'Turn off mouse acceleration'
       Desc  = 'Disables "Enhance pointer precision" so the same hand movement always gives the same aim.'
       Warn  = 'You are used to acceleration on desktop. Your cursor will feel slower until you adjust DPI.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseSpeed'; V = '0'; T = 'String'; D = '1'; M = '1' }
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold1'; V = '0'; T = 'String'; D = '6'; M = '6' }
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold2'; V = '0'; T = 'String'; D = '10'; M = '10' }
       )
       After = { Update-InputFromRegistry } }

    @{ Id = 'keyrepeat'; Cat = 'Input'; Icon = [char]0xE765; Rec = $false
       Title = 'Reduce keyboard repeat delay'
       Desc  = 'Shortest delay before a held key starts repeating, at the fastest repeat rate.'
       Warn  = 'You type a lot outside games. Held keys will repeat almost instantly. Does not change in-game input latency.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Keyboard'; N = 'KeyboardDelay'; V = '0'; T = 'String'; D = '1'; M = '1' }
           @{ P = 'HKCU:\Control Panel\Keyboard'; N = 'KeyboardSpeed'; V = '31'; T = 'String'; D = '31'; M = '31' }
       )
       After = { Update-InputFromRegistry } }

    @{ Id = 'sticky'; Cat = 'Input'; Icon = [char]0xE8C9; Rec = $true; Badge = 'signout'
       Live  = { $f = [AccessKeys]::Read(); $f[0] -ge 0 -and -not ($f[0] -band 4) -and -not ($f[1] -band 4) -and -not ($f[2] -band 4) }
       Title = 'Block Sticky Keys pop-ups'
       Desc  = 'Stops the Sticky/Filter/Toggle Keys prompt from stealing focus when you spam Shift mid-fight.'
       Warn  = 'You use these accessibility features. You can still turn them on from Settings.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Accessibility\StickyKeys'; N = 'Flags'; V = '506'; T = 'String'; D = '510'; M = '510' }
           @{ P = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; N = 'Flags'; V = '122'; T = 'String'; D = '126'; M = '126' }
           @{ P = 'HKCU:\Control Panel\Accessibility\ToggleKeys'; N = 'Flags'; V = '58'; T = 'String'; D = '62'; M = '62' }
       ) }

    # -------------------------------------------------------------- Graphics
    @{ Id = 'dvr'; Cat = 'Graphics'; Icon = [char]0xE714; Rec = $true
       Title = 'Turn off Game Bar background recording'
       Desc  = 'Background capture costs GPU time and causes frame-time spikes.'
       Warn  = 'You use Win+Alt+G to clip moments. Use NVIDIA/AMD instant replay instead.'
       Reg   = @(
           @{ P = 'HKCU:\System\GameConfigStore'; N = 'GameDVR_Enabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled'; V = 0; D = 1; M = 1 }
       ) }

    @{ Id = 'hags'; Cat = 'Graphics'; Icon = [char]0xE7F4; Rec = $false; Badge = 'restart'
       Title = 'Hardware-accelerated GPU scheduling'
       Desc  = 'Lets the GPU manage its own memory queue. Can lower latency on RTX 20 / RX 6000 and newer.'
       Warn  = 'You have an older GPU, or you notice stutter after enabling. Results vary, test both ways.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; N = 'HwSchMode'; V = 2; D = 1; M = 1 } ) }

    @{ Id = 'vrr'; Cat = 'Graphics'; Icon = [char]0xE7F4; Rec = $false; Requires = { @(Get-VrrMonitors).Count -gt 0 }
       Title = 'Variable refresh rate for windowed games'
       Desc  = 'The Windows switch that lets a FreeSync / G-SYNC monitor use VRR in borderless and windowed games that do not support it themselves.'
       Warn  = 'An older game flickers or stutters with it (switch it off again). Fullscreen Fortnite uses the NVIDIA or AMD setting instead.'
       Dx    = @{ K = 'VRROptimizeEnable'; V = '1'; D = '0'; M = '0' } }

    @{ Id = 'windowed'; Cat = 'Graphics'; Icon = [char]0xE740; Rec = $true
       Title = 'Optimizations for windowed games'
       Desc  = 'Uses the low-latency flip model for borderless/windowed games, close to true fullscreen latency.'
       Warn  = 'You are on Windows 10 (not available) or an old game breaks in windowed mode.'
       Dx    = @{ K = 'SwapEffectUpgradeEnable'; V = '1'; D = '0'; M = '0' } }

    @{ Id = 'transparency'; Cat = 'Visuals'; Icon = [char]0xE790; Rec = $true
       Title = 'Turn off transparency effects'
       Desc  = 'Removes blur and see-through effects from Windows, freeing a little GPU work for the game.'
       Warn  = 'You prefer the look of the acrylic/mica Windows 11 effects.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'EnableTransparency'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'gamebaroverlay'; Cat = 'Background'; Icon = [char]0xE7FC; Rec = $false
       Title = 'Turn off Xbox Game Bar overlay'
       Desc  = 'Stops Win+G and the controller Xbox button from opening the Game Bar overlay over Fortnite.'
       Warn  = 'You use Game Bar widgets like the performance monitor or Xbox party chat.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'UseNexusForGameBarEnabled'; V = 0; D = 1; M = 1 } ) }

    # --------------------------------------------------------------- Network
    @{ Id = 'nicpower'; Cat = 'Network'; Icon = [char]0xE839; Rec = $true
       Title = 'Turn off network power-saving'
       Desc  = 'Stops Windows from switching your network adapter off to save power, which causes lag spikes.'
       Warn  = 'You are on a laptop and need maximum battery life. Applying briefly reconnects the adapter.'
       Test  = {
           $pm = @(Get-UpAdapters | ForEach-Object { Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue } |
                   Where-Object { "$($_.AllowComputerToTurnOffDevice)" -in 'Enabled', 'Disabled' })
           if (-not $pm.Count) { return $null }
           -not ($pm | Where-Object { "$($_.AllowComputerToTurnOffDevice)" -ne 'Disabled' })
       }
       On    = {
           $pm = @(Get-UpAdapters | ForEach-Object { Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue } |
                   Where-Object { "$($_.AllowComputerToTurnOffDevice)" -in 'Enabled', 'Disabled' })
           if (-not $script:Backup.Custom.ContainsKey('nicpower')) {
               $script:Backup.Custom['nicpower'] = @($pm | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = "$($_.AllowComputerToTurnOffDevice)" } })
           }
           foreach ($p in $pm) { Set-NetAdapterPowerManagement -Name $p.Name -AllowComputerToTurnOffDevice Disabled }
       }
       Off   = {
           if ($script:Backup.Custom.ContainsKey('nicpower')) {
               foreach ($o in @($script:Backup.Custom['nicpower'])) { Set-NetAdapterPowerManagement -Name $o.Name -AllowComputerToTurnOffDevice $o.Value -ErrorAction SilentlyContinue }
               $script:Backup.Custom.Remove('nicpower')
           } else {
               foreach ($a in Get-UpAdapters) { Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Enabled -ErrorAction SilentlyContinue }
           }
       } }

    @{ Id = 'eee'; Cat = 'Network'; Icon = [char]0xE968; Rec = $true
       Title = 'Turn off Energy-Efficient Ethernet'
       Desc  = 'Stops the Ethernet link from dozing between packets, which adds small, random delays.'
       Warn  = 'You only use Wi-Fi (not available). Applying briefly reconnects the adapter.'
       Test  = { Test-AdvProp '*EEE' 0 }
       On    = { Set-AdvProp 'eee' '*EEE' 0 }
       Off   = { Reset-AdvProp 'eee' '*EEE' 1 } }

    @{ Id = 'intmod'; Cat = 'Network'; Icon = [char]0xE81C; Rec = $false; Badge = 'advanced'
       Title = 'Turn off interrupt moderation'
       Desc  = 'The network card reports every packet immediately instead of batching them.'
       Warn  = 'Your CPU is weak or you download a lot while playing. CPU usage rises; test with and without.'
       Test  = { Test-AdvProp '*InterruptModeration' 0 }
       On    = { Set-AdvProp 'intmod' '*InterruptModeration' 0 }
       Off   = { Reset-AdvProp 'intmod' '*InterruptModeration' 1 } }

    @{ Id = 'netthrottle'; Cat = 'Network'; Icon = [char]0xEC4A; Rec = $true
       Title = 'Turn off network throttling'
       Desc  = 'Stops Windows from limiting network processing while media is playing (NetworkThrottlingIndex).'
       Warn  = 'You have audio dropouts afterwards. This trades a little CPU for network priority.'
       Reg   = @( @{ P = $Mmcss; N = 'NetworkThrottlingIndex'; V = -1; D = 10; M = 10 } ) }

    @{ Id = 'wifipower'; Cat = 'Network'; Icon = [char]0xE701; Rec = $true
       Title = 'Wi-Fi maximum performance'
       Desc  = 'Stops the Wi-Fi adapter from dozing between packets, a common cause of ping spikes.'
       Warn  = 'You are on a laptop on battery. Only the plugged-in setting of the current power plan is changed.'
       Power = @{ Sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Set = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; V = 0; D = 1 } }

    @{ Id = 'rss'; Cat = 'Network'; Icon = [char]0xE9F5; Rec = $true
       Title = 'Receive Side Scaling on'
       Desc  = 'Spreads network processing across CPU cores instead of piling it onto one.'
       Warn  = 'Your adapter driver is old and drops the connection with RSS on. Applying briefly reconnects the adapter.'
       Test  = { Test-AdvProp '*RSS' 1 }
       On    = { Set-AdvProp 'rss' '*RSS' 1 }
       Off   = { Reset-AdvProp 'rss' '*RSS' 0 } }

    @{ Id = 'deliveryopt'; Cat = 'Network'; Icon = [char]0xE896; Rec = $true
       Title = 'Stop sharing updates with other PCs'
       Desc  = 'Delivery Optimization uploads Windows updates to strangers in the background, using your upload.'
       Warn  = 'You have several PCs at home and want them to share update downloads over the LAN.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N = 'DODownloadMode'; V = 0; D = $null; M = 1 } ) }

    @{ Id = 'qos'; Cat = 'Network'; Icon = [char]0xE8B1; Rec = $false; Badge = 'advanced'
       Title = 'Prioritise Fortnite traffic (QoS)'
       Desc  = 'Tags Fortnite packets as high-priority gaming traffic (DSCP 46) so supporting routers send them first.'
       Warn  = 'Your router ignores DSCP tags (many do). It is harmless then, but does nothing.'
       Test  = { [bool](Get-NetQosPolicy -Name 'ZeroDelay Fortnite' -ErrorAction SilentlyContinue) }
       On    = {
           Set-RegTracked 'qos' 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS' 'Do not use NLA' '1' 'String'
           if (-not (Get-NetQosPolicy -Name 'ZeroDelay Fortnite' -ErrorAction SilentlyContinue)) {
               New-NetQosPolicy -Name 'ZeroDelay Fortnite' -AppPathNameMatchCondition $FortniteExeName -DSCPAction 46 -NetworkProfile All -IPProtocolMatchCondition Both | Out-Null
           }
           $script:Backup.Custom['qos'] = $true
       }
       Off   = {
           Remove-NetQosPolicy -Name 'ZeroDelay Fortnite' -Confirm:$false -ErrorAction SilentlyContinue
           [void](Restore-RegTweak 'qos')
           $script:Backup.Custom.Remove('qos')
       } }

    @{ Id = 'ping'; Cat = 'Network'; Icon = [char]0xE909; Action = 'Test ping'
       Title = 'Fortnite server ping'
       Desc  = 'Measures your ping to every Fortnite region so you can pick the lowest in matchmaking settings.'
       Warn  = 'Never. This only measures, it changes nothing.' }

    @{ Id = 'dns'; Cat = 'Network'; Icon = [char]0xE72C; Action = 'Flush now'
       Title = 'Flush DNS cache'
       Desc  = 'Clears stale server addresses. Useful if Epic services fail to connect or log-in hangs.'
       Warn  = 'Never. Windows rebuilds the cache automatically.'
       Run   = { Clear-DnsClientCache; 'DNS cache flushed.' } }

    # -------------------------------------------------------------- Fortnite
    @{ Id = 'gm-main'; Cat = 'GameMode'; Icon = [char]0xE768; Action = 'Turn on'; Lat = $true; Extra = 'gamemode'
       Title = 'ZeroDelay Game Mode'
       Desc  = 'One switch for match time. Pick what it does below; everything is put back when you turn it off.'
       Warn  = ''
       Run   = { if (Test-ZDGameMode) { if (Test-FortniteRunning) { $script:GmSuppress = $true }; Disable-ZDGameMode } else { Enable-ZDGameMode } } }

    @{ Id = 'gamesession'; Cat = 'GameMode'; Icon = [char]0xE711; Picker = $true; Lat = $true; Extra = 'session'
       Title = 'Apps Game Mode closes'
       Desc  = 'Switched-on apps are closed when Game Mode starts and reopened when it ends. Wallpaper Engine is paused instead.'
       Warn  = '' }

    @{ Id = 'cpuprio'; Cat = 'Fortnite'; Icon = [char]0xE7FC; Rec = $true
       Title = 'High CPU priority for Fortnite'
       Desc  = 'Fortnite starts at High priority every launch, ahead of background programs.'
       Warn  = 'You stream from the same PC (OBS may drop frames). Gains are unmeasured and anti-cheat may reset the priority.'
       Reg   = @( @{ P = $Ifeo; N = 'CpuPriorityClass'; V = 3; D = $null; M = $null } ) }

    @{ Id = 'gpupref'; Cat = 'Fortnite'; Icon = [char]0xE7F8; Rec = $true
       Title = 'Run Fortnite on the high-performance GPU'
       Desc  = 'Forces your dedicated graphics card. Matters on laptops with two GPUs, harmless otherwise.'
       Warn  = 'Your display is wired to integrated graphics only (rare on desktops).'
       Test  = { if (-not $script:FortniteExe) { return $null }; "$(Get-RegValue $GpuPrefKey $script:FortniteExe)" -match 'GpuPreference=2;' }
       On    = { Set-RegTracked 'gpupref' $GpuPrefKey $script:FortniteExe 'GpuPreference=2;' 'String' }
       Off   = { if (-not (Restore-RegTweak 'gpupref')) { Remove-RegValue $GpuPrefKey $script:FortniteExe } } }

    @{ Id = 'vsync'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $true
       Title = 'Turn off V-Sync'
       Desc  = 'V-Sync holds every frame until the next screen refresh, adding a lot of input delay.'
       Warn  = 'You see heavy screen tearing and have no G-Sync/FreeSync monitor. Fortnite must be closed.'
       Ini   = @{ bUseVSync = @('False', 'True') } }

    @{ Id = 'fullscreen'; Cat = 'Fortnite'; Icon = [char]0xE740; Rec = $true
       Title = 'Use true fullscreen'
       Desc  = 'Exclusive fullscreen gives the game direct control of the display for the lowest latency.'
       Warn  = 'You alt-tab constantly or use a second monitor while playing. Fortnite must be closed.'
       Ini   = @{ FullscreenMode = @('0', '1'); LastConfirmedFullscreenMode = @('0', '1'); PreferredFullscreenMode = @('0', '1') } }

    @{ Id = 'fpscap'; Cat = 'Fortnite'; Icon = [char]0xE9D9; Rec = $true; Extra = 'fps'
       Title = 'Stable FPS cap'
       Desc  = 'A cap your PC can always hit keeps GPU load under 100%, which avoids queued frames.'
       Warn  = 'You prefer completely uncapped FPS. Fortnite must be closed.'
       Ini   = @{ FrameRateLimit = @({ '{0}.000000' -f [int]$script:FpsBox.Text }, '0.000000') }
       Test  = {
           if (-not (Test-Path $IniPath)) { return $null }
           $v = Get-IniValue (Get-Content $IniPath) 'FrameRateLimit'
           [bool]($v -and [double]$v -gt 0)
       } }

    @{ Id = 'reflex'; Cat = 'Fortnite'; Icon = [char]0xE945; Rec = $true
       Title = 'NVIDIA Reflex: On + Boost'
       Desc  = 'The biggest single latency win on NVIDIA GPUs. Keeps the render queue empty and clocks high.'
       Warn  = 'You have an AMD or Intel GPU (use Anti-Lag / XeLL in their driver instead). Fortnite must be closed.'
       Ini   = @{ LatencyTweak2 = @('2', '0') } }

    @{ Id = 'fnmouse'; Cat = 'Fortnite'; Icon = [char]0xE962; Rec = $true
       Title = 'Turn off Fortnite mouse acceleration'
       Desc  = 'Fortnite has its own mouse acceleration separate from Windows. This turns it off for raw aim.'
       Warn  = 'You play on controller only. Fortnite must be closed.'
       Ini   = @{ bDisableMouseAcceleration = @('True', 'False') } }

    @{ Id = 'motionblur'; Cat = 'Fortnite'; Icon = [char]0xE7B3; Rec = $true
       Title = 'Turn off motion blur'
       Desc  = 'Removes blur when turning, so targets stay sharp and the GPU does less work per frame.'
       Warn  = 'You like the cinematic look. Fortnite must be closed.'
       Ini   = @{ bMotionBlur = @('False', 'True') } }

    @{ Id = 'dynres'; Cat = 'Fortnite'; Icon = [char]0xE9A6; Rec = $true
       Title = 'Turn off dynamic resolution'
       Desc  = 'Stops the game rescaling resolution on the fly, which causes uneven frame times.'
       Warn  = 'Your GPU is weak and dynamic resolution is what keeps your FPS up. Fortnite must be closed.'
       Ini   = @{ bUseDynamicResolution = @('False', 'True') } }

    @{ Id = 'nanite'; Cat = 'Fortnite'; Icon = [char]0xE81E; Rec = $true
       Title = 'Turn off Nanite'
       Desc  = 'Nanite geometry is very GPU-heavy. Turning it off raises FPS and lowers GPU latency.'
       Warn  = 'You play for visuals on a high-end GPU. Fortnite must be closed.'
       Ini   = @{ bUseNanite = @('False', 'True') } }

    @{ Id = 'compgfx'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $true
       Title = 'Competitive graphics'
       Desc  = 'Shadows, effects, post-processing, lighting, reflections and foliage to Low. Textures untouched.'
       Warn  = 'You want the game to look its best. Low shadows also make enemies easier to see. Fortnite must be closed.'
       Ini   = @{
           'sg.ShadowQuality'             = @('0', '3', 'ScalabilityGroups')
           'sg.EffectsQuality'            = @('0', '3', 'ScalabilityGroups')
           'sg.PostProcessQuality'        = @('0', '3', 'ScalabilityGroups')
           'sg.GlobalIlluminationQuality' = @('0', '3', 'ScalabilityGroups')
           'sg.ReflectionQuality'         = @('0', '3', 'ScalabilityGroups')
           'sg.FoliageQuality'            = @('0', '3', 'ScalabilityGroups')
       } }

    @{ Id = 'perfmode'; Cat = 'Fortnite'; Icon = [char]0xEC4A; Rec = $false; Badge = 'advanced'
       Title = 'Performance rendering mode'
       Desc  = 'The lightweight renderer most pros use. Much higher FPS and lower CPU load, simpler visuals.'
       Warn  = 'You have a strong GPU and prefer DirectX 12 visuals. Fortnite must be closed.'
       Ini   = @{ PreferredFeatureLevel = @('es31', $null, 'D3DRHIPreference') } }




    # ---------------------------------------------- potato presets
    @{ Id = 'hdr-build'; Cat = 'Potato'; Potato = $true; Header = 'Build your own'; Title = 'Build your own'
       Desc = 'Pick your own 3D resolution, view distance and texture blur. The potato score updates as you drag.' }
    @{ Id = 'builder'; Cat = 'Potato'; Icon = [char]0xE70F; Action = 'Apply'; Potato = $true; Extra = 'builder'
       Title = 'Custom potato'
       Desc  = 'Everything else is set to low. Texture blur needs an NVIDIA card. Fortnite must be closed.'
       Warn  = ''
       Run   = { Invoke-Builder $t } }
    @{ Id = 'hdr-flat'; Cat = 'Potato'; Potato = $true; Header = 'Flat colours  ·  NVIDIA'; Title = 'Flat colours  ·  NVIDIA'
       Desc = 'Textures are blurred away until every surface is a solid colour. Clears shader caches when applied, so the first match may stutter.' }
    @{ Id = 'preset-flatpotato'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Flat potato'
       Desc  = 'The one you tested: flat colours, 67% render, short view distance. Ugly and very fast.'
       Warn  = ''
       Preset = (New-PresetValues 67 0 0 0 0 0 $false 120)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-flatcolours'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Flat colours'
       Desc  = 'Flat colours with a sharp 100% render and full view distance. Clean, readable builds.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 0 0 0 0 $false 120)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-flatfar'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Flat but far'
       Desc  = 'Flat colours, 80% render, full view distance. Faster than sharp, still spots far builds.'
       Warn  = ''
       Preset = (New-PresetValues 80 3 0 0 0 0 $false 120)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-flatcrisp'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Flat crisp'
       Desc  = 'Flat colours and a sharp 100% render, but short view distance for extra FPS.'
       Warn  = ''
       Preset = (New-PresetValues 100 0 0 0 0 0 $false 120)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-flatultra'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Flat ultra potato'
       Desc  = 'Flat colours at 50% render and short view distance. Maximum FPS, very blurry.'
       Warn  = ''
       Preset = (New-PresetValues 50 0 0 0 0 0 $false 120)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'hdr-blur'; Cat = 'Potato'; Potato = $true; Header = 'Blurred textures  ·  NVIDIA'; Title = 'Blurred textures  ·  NVIDIA'
       Desc = 'Textures are softened but not flat. Less distracting surfaces, a little more FPS.' }
    @{ Id = 'preset-smudgedcomp'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Smudged competitive'
       Desc  = 'Competitive settings with heavily smudged textures. Close to flat but surfaces keep some shading.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 0 0 0 0 $false 56)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-softcomp'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Soft competitive'
       Desc  = 'Competitive settings with lightly blurred textures, so walls and floors look cleaner.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 0 0 0 0 $false 24)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-softpotato'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Soft potato'
       Desc  = 'Soft textures, 67% render and short view distance.'
       Warn  = ''
       Preset = (New-PresetValues 67 0 0 0 0 0 $false 24)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'hdr-classic'; Cat = 'Potato'; Potato = $true; Header = 'Classic  ·  any graphics card'; Title = 'Classic  ·  any graphics card'
       Desc = 'Only Fortnite settings, no driver changes. Applying one of these also turns texture blur off.' }
    @{ Id = 'preset-ultrapotato'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Ultra potato'
       Desc  = 'Absolute maximum FPS for very weak PCs and laptops. Very blurry, almost no detail.'
       Warn  = ''
       Preset = (New-PresetValues 50 0 0 0 0 0 $false 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-potato'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Potato'
       Desc  = 'Everything on low with a soft 67% render. Big FPS gain, still easy to read.'
       Warn  = ''
       Preset = (New-PresetValues 67 0 0 0 0 0 $false 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-blurryfar'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Blurry but far'
       Desc  = 'Low everything and 60% render, but full view distance so you still see builds far away.'
       Warn  = ''
       Preset = (New-PresetValues 60 3 0 0 0 0 $false 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-crisppotato'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Crisp potato'
       Desc  = 'Everything low but full 100% resolution: sharp edges, flat look.'
       Warn  = ''
       Preset = (New-PresetValues 100 0 0 0 0 0 $false 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-competitive'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Competitive'
       Desc  = 'The common pro setup: 100% render, far view distance, everything else low, no grass.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 0 0 0 0 $false 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-compclarity'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Competitive clarity'
       Desc  = 'Pro setup with medium textures and models, so the map looks less flat. Needs a decent GPU.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 1 1 0 0 $false 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-balanced'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Balanced'
       Desc  = 'Medium detail with grass and light anti-aliasing. Good FPS on mid-range PCs and looks fine.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 2 1 1 1 $true 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'preset-pretty'; Cat = 'Potato'; Icon = [char]0xE7F4; Action = 'Apply'; Potato = $true; Extra = 'preset'
       Title = 'Best looking (Performance mode)'
       Desc  = 'Highest quality Performance mode can do. Use it to compare how much the presets change.'
       Warn  = ''
       Preset = (New-PresetValues 100 3 3 2 3 3 $true 0)
       Run   = { Invoke-Preset $t } }
    @{ Id = 'presetundo'; Cat = 'Potato'; Icon = [char]0xE7A7; Action = 'Undo'; Potato = $true
       Title = 'Undo graphics presets'
       Desc  = 'Puts back the graphics settings and driver blur you had before you applied any preset. Fortnite must be closed.'
       Warn  = ''
       Run   = { Undo-Presets } }
    @{ Id = 'hdr-single'; Cat = 'Potato'; Potato = $true; Header = 'Individual settings'; Title = 'Individual settings'
       Desc = 'Switch single settings on or off instead of using a whole preset.' }

    # ---------------------------------------------- flat textures (NVIDIA driver)
    @{ Id = 'shadercache'; Cat = 'Potato'; Icon = [char]0xE74D; Action = 'Clear'; Potato = $true
       Title = 'Clear shader caches'
       Desc  = 'Deletes NVIDIA and DirectX shader caches so texture-blur changes take effect. They rebuild on the next launch.'
       Warn  = ''
       Run   = { if (Test-FortniteRunning) { throw 'Close Fortnite first.' }; "Cleared $(Clear-ShaderCaches) shader cache files. The first match may stutter while they rebuild." } }
    @{ Id = 'nvlod-soft'; Cat = 'Potato'; Icon = [char]0xE790; Rec = $false; Potato = $true; LodValue = 24
       Title = 'Soft textures (NVIDIA)'
       Desc  = 'Lightly blurs every texture. Cleaner surfaces, small FPS gain. Restart Fortnite to see it.'
       Warn  = 'You want to see textures. Experimental on DirectX 12: clears shader caches, so the first match may stutter. Close Fortnite first.'
       Requires = { Test-NvAvailable }
       Test  = { $script:CurrentNvLod -eq $t.LodValue }
       On    = { Set-NvLod $t.LodValue; $script:Backup.Custom[$t.Id] = $true; $script:CurrentNvLod = $t.LodValue }
       Off   = { Restore-NvLod; $script:CurrentNvLod = Get-NvLod } }

    @{ Id = 'nvlod-smudge'; Cat = 'Potato'; Icon = [char]0xE790; Rec = $false; Potato = $true; LodValue = 56
       Title = 'Smudged textures (NVIDIA)'
       Desc  = 'Textures become blurry smudges of colour. Restart Fortnite to see it.'
       Warn  = 'You want to see textures. Experimental on DirectX 12: clears shader caches, so the first match may stutter. Close Fortnite first.'
       Requires = { Test-NvAvailable }
       Test  = { $script:CurrentNvLod -eq $t.LodValue }
       On    = { Set-NvLod $t.LodValue; $script:Backup.Custom[$t.Id] = $true; $script:CurrentNvLod = $t.LodValue }
       Off   = { Restore-NvLod; $script:CurrentNvLod = Get-NvLod } }

    @{ Id = 'nvlod-flat'; Cat = 'Potato'; Icon = [char]0xE790; Rec = $false; Potato = $true; LodValue = 120
       Title = 'Flat colours, no textures (NVIDIA)'
       Desc  = 'Every surface becomes a solid colour, like the potato clips. Restart Fortnite to see it.'
       Warn  = 'You want to see textures. Experimental on DirectX 12: clears shader caches, so the first match may stutter. Close Fortnite first.'
       Requires = { Test-NvAvailable }
       Test  = { $script:CurrentNvLod -eq $t.LodValue }
       On    = { Set-NvLod $t.LodValue; $script:Backup.Custom[$t.Id] = $true; $script:CurrentNvLod = $t.LodValue }
       Off   = { Restore-NvLod; $script:CurrentNvLod = Get-NvLod } }

    # ---------------------------------------------- potato graphics
    @{ Id = 'potatopreset'; Cat = 'Potato'; Icon = [char]0xE945; Action = 'Go potato'; Potato = $true
       Title = 'Turn on every potato card'
       Desc  = 'Turns on every card in this tab at once: lowest settings for maximum FPS. Fortnite must be closed.'
       Warn  = ''
       Run   = {
           Assert-IniWritable
           $ok = 0; $failed = @()
           foreach ($t in $Tweaks | Where-Object { $_.Potato -and $_.Toggle -and $_.State -eq $false }) {
               try { Invoke-TweakOn $t; $ok++ } catch { $failed += $t.Title }
               Update-Card $t
           }
           Update-Summary
           $msg = "Potato mode: $ok settings lowered."
           if ($failed) { $msg += " Skipped: $($failed -join ', ')." }
           $msg + ' Launch Fortnite to see it.'
       } }

    @{ Id = 'potatoundo'; Cat = 'Potato'; Icon = [char]0xE7A7; Action = 'Undo'; Potato = $true
       Title = 'Undo potato preset'
       Desc  = 'Puts every setting in this tab back to what it was before ZeroDelay changed it.'
       Warn  = ''
       Run   = {
           Assert-IniWritable
           $n = 0
           foreach ($t in $Tweaks | Where-Object { $_.Potato -and $_.Toggle -and $_.State -and (Test-TweakHasBackup $_.Id) }) {
               try { Invoke-TweakOff $t; $n++ } catch {}
               Update-Card $t
           }
           Update-Summary
           "Restored $n graphics settings."
       } }

    @{ Id = 'res3d'; Cat = 'Potato'; Icon = [char]0xE7F4; Rec = $false; Extra = 'res'
       Title = 'Lower 3D resolution'
       Desc  = 'Renders the game world below your screen resolution while the HUD stays sharp. The biggest FPS lever.'
       Warn  = 'You want a crisp image. Below 70% gets blurry and makes far-away players harder to see. Fortnite must be closed.'
       Ini   = [ordered]@{
           'sg.ResolutionQuality' = @({ "$(Get-ResBoxValue)" }, '100', 'ScalabilityGroups')
           'PotentiallyUpscaledResolutionQuality' = @({ '{0}.000000' -f (Get-ResBoxValue) }, '100.000000')
           'NeverUpscaledResolutionQuality' = @({ '{0}.000000' -f (Get-ResBoxValue) }, '100.000000')
       }
       Test  = {
           if (-not (Test-Path $IniPath)) { return $null }
           $lines = Get-Content $IniPath
           $v = Get-IniValue $lines 'PotentiallyUpscaledResolutionQuality'; if (-not $v) { $v = Get-IniValue $lines 'sg.ResolutionQuality' }
           [bool]($v -and [double]$v -lt 100)
       } }

    @{ Id = 'shadinglow'; Cat = 'Potato'; Icon = [char]0xE790; Rec = $false
       Title = 'Low shading quality'
       Desc  = 'Simplest material shading. Less GPU work on every surface.'
       Warn  = 'You want materials to look detailed. Fortnite must be closed.'
       Ini   = @{ 'sg.ShadingQuality' = @('0', '3', 'ScalabilityGroups') } }

    @{ Id = 'landscapelow'; Cat = 'Potato'; Icon = [char]0xE909; Rec = $false
       Title = 'Low terrain quality'
       Desc  = 'Simpler terrain detail and blending.'
       Warn  = 'You want the ground to look detailed. Fortnite must be closed.'
       Ini   = @{ 'sg.LandscapeQuality' = @('0', '3', 'ScalabilityGroups') } }

    @{ Id = 'viewnear'; Cat = 'Potato'; Icon = [char]0xE909; Rec = $false
       Title = 'Lowest view distance'
       Desc  = 'Draws the fewest distant objects. Big help on weak CPUs; players themselves still render far away.'
       Warn  = 'You want to see far-off builds and terrain. Overrides the "Medium view distance" card. Fortnite must be closed.'
       Ini   = @{ 'sg.ViewDistanceQuality' = @('0', '3', 'ScalabilityGroups') } }

    # ---------------------------------------------- system latency (research round 2)
    @{ Id = 'displaycheck'; Cat = 'Graphics'; Icon = [char]0xE7F4; Action = 'Check'; Lat = $true
       Title = 'Check which GPU drives each monitor'
       Desc  = 'A game on a monitor plugged into the motherboard is copied across GPUs, adding delay. Finds that.'
       Warn  = ''
       Run   = {
           $d = Get-Displays
           $lines = foreach ($x in $d) {
               $where = if ($x.Discrete) { 'graphics card' } else { 'CPU graphics (slower path)' }
               "$($x.Monitor): $($x.Gpu), $($x.Hz) Hz, $where$(if ($x.Primary) { ', main display' })"
           }
           $msg = $lines -join '.  '
           if (($d | Where-Object { -not $_.Discrete }) -and ($d | Where-Object Discrete)) {
               $msg += '.  Play Fortnite on a monitor plugged into the graphics card, and plug the other one into the graphics card too if it has a free port.'
           }
           $msg
       } }

    @{ Id = 'vrrcap'; Cat = 'Fortnite'; Icon = [char]0xE9D9; Action = 'Set cap'; Lat = $true; Rec = $true
       Title = 'G-SYNC / FreeSync FPS cap'
       Desc  = 'Caps FPS just under your refresh rate (171 at 180 Hz) so variable refresh stays on and frames never queue.'
       Warn  = ''
       Run   = {
           if ((Test-VrrActive) -eq $false) { throw 'G-SYNC is off on your PC, so a cap just below the refresh rate does not help. See the NVIDIA page.' }
           $cap = Get-VrrCap
           if (-not $cap) { throw 'Could not read your refresh rate.' }
           $script:FpsBox.Text = "$cap"
           $fps = $Tweaks | Where-Object { $_.Id -eq 'fpscap' }
           Invoke-TweakOn $fps
           Update-Card $fps; Update-Summary
           "Fortnite FPS cap set to $cap."
       } }

    @{ Id = 'ccdpin'; Cat = 'Fortnite'; Icon = [char]0xE964; Action = 'Pin now'; Lat = $true
       Title = 'Keep Fortnite on one CPU die'
       Desc  = 'On 12/16-core Ryzen, keeps game threads on the first CCD to avoid cross-die delay. Run while Fortnite is open.'
       Warn  = ''
       Requires = { (Get-CpuName) -match 'Ryzen 9 \d{4}X' }
       Run   = {
           $p = Get-Process ($FortniteExeName -replace '\.exe$') -ErrorAction SilentlyContinue | Select-Object -First 1
           if (-not $p) { throw 'Start Fortnite first, then press Pin now.' }
           $half = [Environment]::ProcessorCount / 2
           try { $p.ProcessorAffinity = [IntPtr][int64]([Math]::Pow(2, $half) - 1) }
           catch { throw 'Anti-cheat blocked the change. Nothing was modified.' }
           "Fortnite pinned to the first CCD ($half threads) until it closes."
       } }

    @{ Id = 'vbs'; Cat = 'System'; Icon = [char]0xE83D; Rec = $false; Lat = $true; Badge = 'restart'
       Title = 'Turn off Virtualization-based Security'
       Desc  = 'Goes one step past Memory Integrity: stops VBS itself. Measured up to ~5% FPS loss with it on.'
       Warn  = 'Your PC is managed by work/school, you use Credential Guard, or a game''s anti-cheat requires VBS. Lowers security.'
       Test  = {
           if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity') -eq 0) { return $true }
           $g = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
           if ($g) { $g.VirtualizationBasedSecurityStatus -eq 0 } else { $false }
       }
       On    = { Set-RegTracked 'vbs' 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0 }
       Off   = { if (-not (Restore-RegTweak 'vbs')) { Remove-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' } } }

    @{ Id = 'bgpolicy'; Cat = 'Background'; Icon = [char]0xE895; Rec = $false
       Title = 'Block all background Store apps (policy)'
       Desc  = 'Stronger than the per-user switch: a system policy that stops every Store app running in the background.'
       Warn  = 'You rely on notifications or live updates from Store apps like Mail, Calendar or Phone Link.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; N = 'LetAppsRunInBackground'; V = 2; D = $null; M = 0 } ) }

    @{ Id = 'shaderexcl'; Cat = 'Background'; Icon = [char]0xE83D; Rec = $false; Lat = $true
       Title = 'Skip Defender scans of shader caches'
       Desc  = 'Stops real-time scanning of GPU shader-cache writes, a cause of hitches when new effects load.'
       Warn  = 'You want every folder scanned. Excluded folders could hide malware (these hold only GPU caches).'
       Test  = {
           $ex = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
           $want = @("$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\AMD\DxCache") | Where-Object { Test-Path $_ }
           if (-not $want) { return $null }
           -not ($want | Where-Object { $ex -notcontains $_ })
       }
       On    = {
           $ex = @((Get-MpPreference).ExclusionPath)
           $add = @(@("$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\AMD\DxCache") | Where-Object { (Test-Path $_) -and $ex -notcontains $_ })
           if ($add) { Add-MpPreference -ExclusionPath $add }
           $script:Backup.Custom['shaderexcl'] = @(@($script:Backup.Custom['shaderexcl']) + $add | Where-Object { $_ })
       }
       Off   = {
           $paths = @($script:Backup.Custom['shaderexcl'] | Where-Object { $_ })
           if (-not $paths) { $paths = @("$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\AMD\DxCache") }
           Remove-MpPreference -ExclusionPath $paths -ErrorAction SilentlyContinue
           $script:Backup.Custom.Remove('shaderexcl')
       } }


    # ---------------------------------------------- EXM-inspired additions
    @{ Id = 'clicktodo'; Cat = 'Background'; Icon = [char]0xE72E; Rec = $true
       Title = 'Turn off Click to Do'
       Desc  = 'Stops the Windows AI overlay that analyses whatever is on screen when you press Win+click.'
       Warn  = 'You use Click to Do to act on text or images on screen.'
       Reg   = @( @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableClickToDo'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'devicemeta'; Cat = 'Background'; Icon = [char]0xE896; Rec = $true
       Title = 'Block automatic device software'
       Desc  = 'Stops Windows downloading companion apps (Razer, Logitech and others) when you plug in a device.'
       Warn  = 'You want those apps installed automatically. You can still install them yourself.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; N = 'PreventDeviceMetadataFromNetwork'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'discordhw'; Cat = 'Background'; Icon = [char]0xE7F4; Rec = $false; Lat = $true
       Title = 'Discord: hardware acceleration off'
       Desc  = 'Discord stops using your graphics card, so it does not compete with Fortnite for the GPU. Restart Discord after.'
       Warn  = 'Your CPU is weak or you screen-share a lot. Discord then uses more CPU instead. Close Discord before switching.'
       Requires = { Test-Path "$env:APPDATA\discord\settings.json" }
       Test  = { $j = Get-Content "$env:APPDATA\discord\settings.json" -Raw | ConvertFrom-Json; $j.enableHardwareAcceleration -eq $false }
       On    = {
           if (Get-Process Discord -ErrorAction SilentlyContinue) { throw 'Close Discord first (right-click its tray icon, Quit). It rewrites this setting when it exits.' }
           $f = "$env:APPDATA\discord\settings.json"; $j = Get-Content $f -Raw | ConvertFrom-Json
           if (-not $script:Backup.Custom.ContainsKey('discordhw')) { $script:Backup.Custom['discordhw'] = @{ Value = $j.enableHardwareAcceleration } }
           $j | Add-Member -NotePropertyName enableHardwareAcceleration -NotePropertyValue $false -Force
           $j | ConvertTo-Json -Depth 20 | Set-Content $f -Encoding UTF8
       }
       Off   = {
           if (Get-Process Discord -ErrorAction SilentlyContinue) { throw 'Close Discord first (right-click its tray icon, Quit).' }
           $f = "$env:APPDATA\discord\settings.json"; $j = Get-Content $f -Raw | ConvertFrom-Json
           $saved = $script:Backup.Custom['discordhw']
           if ($saved -and $null -ne $saved.Value) { $j | Add-Member -NotePropertyName enableHardwareAcceleration -NotePropertyValue ([bool]$saved.Value) -Force }
           else { $j.PSObject.Properties.Remove('enableHardwareAcceleration') }
           $j | ConvertTo-Json -Depth 20 | Set-Content $f -Encoding UTF8
           $script:Backup.Custom.Remove('discordhw')
       } }

    @{ Id = 'cleanlogs'; Cat = 'Storage'; Icon = [char]0xE74D; Action = 'Clean now'
       Title = 'Clear logs and crash dumps'
       Desc  = 'Deletes old Windows crash dumps and error reports, plus old Fortnite logs and crash folders.'
       Warn  = ''
       Run   = {
           $bytes = 0; $cut = (Get-Date).AddHours(-1)
           $targets = @("$env:WINDIR\Minidump", "$env:WINDIR\LiveKernelReports", "$env:LOCALAPPDATA\CrashDumps",
                        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                        "$env:LOCALAPPDATA\FortniteGame\Saved\Logs", "$env:LOCALAPPDATA\FortniteGame\Saved\Crashes")
           foreach ($dir in $targets | Where-Object { Test-Path $_ }) {
               Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | ForEach-Object {
                   $len = $_.Length; try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $bytes += $len } catch {}
               }
           }
           'Freed {0:N0} MB of logs and crash dumps.' -f ($bytes / 1MB)
       } }

    @{ Id = 'prefetchon'; Cat = 'Repair'; Icon = [char]0xE90F; Rec = $true
       Title = 'Turn the prefetcher back on'
       Desc  = 'Another tool turned off Windows prefetching. Windows loads apps and games slower without it, even on fast SSDs.'
       Warn  = 'You turned it off on purpose and measured a benefit. The old value is backed up.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'; N = 'EnablePrefetcher'; V = 3; D = 0; M = 3 } ) }

    @{ Id = 'idleon'; Cat = 'Repair'; Icon = [char]0xE90F; Rec = $true; Lat = $true
       Title = 'Allow CPU idle states'
       Desc  = 'Turning idle states off (EXM "Disable Idle") stops Ryzen and Intel boosting to full clock on busy cores. This allows them again.'
       Warn  = 'You turned idle states off on purpose and measured lower latency. Only the current power plan changes.'
       Power = @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '5d76a2ca-e8c0-402f-a133-2158492d58ad'; V = 0; D = 1 } }


    # ---------------------------------------------- NVIDIA driver profile extras
    @{ Id = 'nvpower'; Cat = 'Graphics'; Icon = [char]0xE945; Rec = $true; Lat = $true
       Title = 'NVIDIA: prefer maximum performance'
       Desc  = 'Keeps your graphics card at full clocks while Fortnite runs, instead of letting them drop between frames.'
       Warn  = 'You care about power use and heat more than consistent frame times. Only the Fortnite profile changes.'
       Nv    = @{ Profile = 'Fortnite'; Id = 0x1057EB71; V = 1 } }

    @{ Id = 'nvshadercache'; Cat = 'Graphics'; Icon = [char]0xEDA2; Rec = $true; Lat = $true
       Title = 'NVIDIA: unlimited shader cache'
       Desc  = 'Lets the driver keep every compiled shader, so Fortnite stutters less after updates and in new areas.'
       Warn  = 'Your drive is nearly full. The cache can grow to several GB over time.'
       Nv    = @{ Profile = 'Base Profile'; Id = 0x00AC8497; V = 4294967295 } }

    @{ Id = 'nvtexq'; Cat = 'Graphics'; Icon = [char]0xE790; Rec = $false; Lat = $true
       Title = 'NVIDIA: texture filtering high performance'
       Desc  = 'Uses the fastest texture filtering for Fortnite. Tiny FPS gain, slightly softer distant textures.'
       Warn  = 'You want the sharpest textures. Only the Fortnite profile changes.'
       Nv    = @{ Profile = 'Fortnite'; Id = 0x00CE2691; V = 20 } }

    @{ Id = 'smoothmotion'; Cat = 'Graphics'; Icon = [char]0xE740; Rec = $true; Lat = $true
       Title = 'NVIDIA: keep Smooth Motion off'
       Desc  = 'Smooth Motion is driver frame generation and adds delay. This pins it off for Fortnite even if it is turned on globally.'
       Warn  = 'You want generated frames for smoothness in Fortnite. It is already off by default; this is a safeguard.'
       Nv    = @{ Profile = 'Fortnite'; Id = 2966652096; V = 0 } }

    # ---------------------------------------------- repair: undo risky tweaks left by other tools
    @{ Id = 'nvpreempt'; Cat = 'Repair'; Icon = [char]0xE90F; Rec = $true; Badge = 'restart'
       Title = 'Restore NVIDIA GPU preemption'
       Desc  = 'Removes "DisablePreemption" keys some optimizers add. They make GPU hangs more likely with no measured latency gain.'
       Warn  = 'Never really. The keys are backed up and switching this off puts them back.'
       Remove = @(
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters'; N = 'DisablePreemption' }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters'; N = 'DisableCudaContextPreemption' }
       ) }

    @{ Id = 'nvpstate'; Cat = 'Repair'; Icon = [char]0xE90F; Rec = $false; Badge = 'restart'
       Title = 'Restore NVIDIA dynamic clocks'
       Desc  = 'Removes keys that lock the GPU at full clocks. Reflex Boost already raises clocks when it matters; locking only adds heat.'
       Warn  = 'You deliberately locked clocks and measured a benefit. The keys are backed up.'
       Requires = { [bool](Get-NvidiaClassKey) }
       Remove = @(
           @{ P = (Get-NvidiaClassKey); N = 'DisableDynamicPstate' }
           @{ P = (Get-NvidiaClassKey); N = 'PerfLevelSrc' }
       ) }

    @{ Id = 'kernelsched'; Cat = 'Repair'; Icon = [char]0xE90F; Rec = $false; Badge = 'restart'
       Title = 'Remove unproven scheduler tweaks'
       Desc  = 'Deletes undocumented kernel scheduler values written by other tools. None has evidence; wrong values can cause stutter.'
       Warn  = 'You set these yourself and measured an improvement. Every value is backed up and comes back if you switch this off.'
       Remove = @(
           foreach ($n in 'ReadyTimeTicks', 'ScanLatencyTicks', 'ThreadReadyCount', 'BoostingPeriodMultiplier', 'ForceForegroundBoostDecay',
                          'SerializeTimerExpiration', 'ThreadDpcEnable', 'TimerCheckFlags', 'EnableTickAccumulationFromAccountingPeriods', 'EnablePerCpuClockTickScheduling') {
               @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; N = $n }
           }
       ) }

    # ---------------------------------------------- network + Fortnite (research round 2)
    @{ Id = 'framegen'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $true; Lat = $true
       Title = 'Turn off frame generation'
       Desc  = 'DLSS Frame Generation inserts fake frames and adds input delay, even with Reflex on.'
       Warn  = 'You play casually on a weak GPU and prefer smoothness over responsiveness. Fortnite must be closed.'
       Ini   = @{ bEnableDLSSFrameGeneration = @('False', 'False') } }

    @{ Id = 'meshquality'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $true; Lat = $true
       Title = 'Performance mode: low mesh quality'
       Desc  = 'Simpler models in Performance mode cut CPU and memory load, reducing stutter.'
       Warn  = 'You use DirectX 12 instead of Performance mode (no effect then). Fortnite must be closed.'
       Ini   = @{ MeshQuality = @('0', '2', 'PerformanceMode') } }

    @{ Id = 'benchmarklock'; Cat = 'Fortnite'; Icon = [char]0xE72E; Rec = $true
       Title = 'Stop auto-detect overwriting settings'
       Desc  = 'Keeps Fortnite from re-running its quality benchmark and resetting your graphics settings.'
       Warn  = 'You want Fortnite to re-detect settings after a hardware upgrade. Fortnite must be closed.'
       Ini   = @{ InitialBenchmarkState = @('1', '1') } }

    @{ Id = 'viewdistance'; Cat = 'Fortnite'; Icon = [char]0xE909; Rec = $false
       Title = 'Medium view distance'
       Desc  = 'Draws fewer distant objects. Helps CPU-bound PCs hold a steady frame rate.'
       Warn  = 'You want to spot builds and players far away. Most competitive players keep this high. Fortnite must be closed.'
       Ini   = @{ 'sg.ViewDistanceQuality' = @('1', '3', 'ScalabilityGroups') } }

    @{ Id = 'texturelow'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $false
       Title = 'Low textures (under 8 GB VRAM)'
       Desc  = 'Stops hitching when textures overflow your graphics memory. No benefit on 8 GB+ cards.'
       Warn  = 'Your GPU has 8 GB or more of video memory. Textures just look worse then. Fortnite must be closed.'
       Ini   = @{ 'sg.TextureQuality' = @('0', '2', 'ScalabilityGroups') } }

    @{ Id = 'lobbyfps'; Cat = 'Fortnite'; Icon = [char]0xE9D9; Rec = $false
       Title = 'Cap lobby FPS at 60'
       Desc  = 'Less heat and power while in menus, so your PC starts each match cooler. No in-match effect.'
       Warn  = 'You want a smooth lobby. Fortnite must be closed.'
       Ini   = @{ FrontendFrameRateLimit = @('60', '120') } }

    @{ Id = 'uro'; Cat = 'Network'; Icon = [char]0xE839; Rec = $true; Lat = $true
       Title = 'Keep UDP receive batching off'
       Desc  = 'Stops Windows batching incoming UDP packets (URO). Fortnite gameplay runs over UDP.'
       Warn  = 'You download huge files over UDP-based protocols and want maximum throughput.'
       Test  = {
           $o = netsh int udp show global 2>$null
           $line = $o | Where-Object { $_ -match '(?i)receive offload' } | Select-Object -First 1
           if (-not $line) { return $null }
           $line -match '(?i)disabled'
       }
       On    = {
           if (-not $script:Backup.Custom.ContainsKey('uro')) { $script:Backup.Custom['uro'] = 'enabled' }
           netsh int udp set global uro=disabled | Out-Null
       }
       Off   = { netsh int udp set global uro=enabled | Out-Null; $script:Backup.Custom.Remove('uro') } }

    @{ Id = 'itr'; Cat = 'Network'; Icon = [char]0xE839; Rec = $false; Lat = $true; Badge = 'advanced'
       Title = 'Intel: minimal interrupt throttling'
       Desc  = 'Intel Ethernet waits less before reporting packets (Interrupt Moderation Rate: Minimal).'
       Warn  = 'You already turned interrupt moderation off (this is then redundant). Intel adapters only. Briefly reconnects.'
       Test  = { Test-AdvDisplay 'ITR' 'Minimal' }
       On    = { Set-AdvDisplay 'itr' 'ITR' 'Minimal' }
       Off   = { Reset-AdvProp 'itr' 'ITR' 65535 } }

    @{ Id = 'wol'; Cat = 'Network'; Icon = [char]0xE7E8; Rec = $false
       Title = 'Turn off Wake-on-LAN'
       Desc  = 'Stops network traffic waking your PC from sleep. Housekeeping, no effect on ping.'
       Warn  = 'You wake this PC remotely (Parsec, Steam Link, remote desktop). Briefly reconnects the adapter.'
       Test  = { $a = Test-AdvProp '*WakeOnMagicPacket' 0; $b = Test-AdvProp '*WakeOnPattern' 0; if ($null -eq $a -and $null -eq $b) { return $null }; $a -ne $false -and $b -ne $false }
       On    = { Set-AdvProp 'wol-magic' '*WakeOnMagicPacket' 0; Set-AdvProp 'wol-pattern' '*WakeOnPattern' 0; $script:Backup.Custom['wol'] = $true }
       Off   = { Reset-AdvProp 'wol-magic' '*WakeOnMagicPacket' 1; Reset-AdvProp 'wol-pattern' '*WakeOnPattern' 1; $script:Backup.Custom.Remove('wol') } }

    @{ Id = 'onedrivecap'; Cat = 'Network'; Icon = [char]0xE753; Rec = $false; Lat = $true
       Title = 'Cap OneDrive upload speed'
       Desc  = 'Limits OneDrive uploads to 1 MB/s so a sync can not flood your upload and spike your ping.'
       Warn  = 'You have fast upload and need large files to sync quickly.'
       Reg   = @( @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive'; N = 'UploadBandwidthLimit'; V = 1000; D = $null; M = 0 } ) }

    @{ Id = 'metered'; Cat = 'Network'; Icon = [char]0xE968; Action = 'Open setting'
       Title = 'Metered connection'
       Desc  = 'Turn it on while gaming so Windows Update and the Store stop big downloads mid-match.'
       Warn  = ''
       Run   = { Start-Process 'ms-settings:network-ethernet'; 'Turn on "Metered connection" for your network. Turn it off again to get updates.' } }

    @{ Id = 'bufferbloat'; Cat = 'Network'; Icon = [char]0xE909; Action = 'Run test'; Lat = $true
       Title = 'Bufferbloat test'
       Desc  = 'Checks if your router adds lag when the line is busy. Grade C or worse: turn on SQM/QoS in your router.'
       Warn  = ''
       Run   = { Start-Process 'https://www.waveform.com/tools/bufferbloat'; 'Opened the bufferbloat test in your browser.' } }

    # =========================================================== Power & CPU
    @{ Id = 'minstate'; Cat = 'Power'; Icon = [char]0xEC4A; Rec = $true
       Title = 'CPU minimum state 100%'
       Desc  = 'Stops the CPU dropping to low clocks between frames. Some third-party power plans set this to 0%.'
       Warn  = 'You are on a laptop on battery or the PC runs hot. Only the plugged-in value of the current plan changes.'
       Power = @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '893dee8e-2bef-41e0-89c6-b55d0929964c'; V = 100; D = 5 } }

    @{ Id = 'epp'; Cat = 'Power'; Icon = [char]0xE945; Rec = $true
       Title = 'Max performance energy preference'
       Desc  = 'Tells the CPU to ramp clocks up instantly instead of saving energy (EPP 0).'
       Warn  = 'You are on a laptop and care about heat and fan noise. Only the plugged-in value changes.'
       Power = @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; V = 0; D = 33 } }

    @{ Id = 'boostmode'; Cat = 'Power'; Icon = [char]0xE9D9; Rec = $true
       Title = 'Aggressive CPU boost'
       Desc  = 'Lets the CPU boost above base clock as soon as there is load.'
       Warn  = 'Your cooling is weak and the CPU already throttles under load.'
       Power = @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = 'be337238-0d82-4146-a960-4f3749d470c7'; V = 2; D = 1 } }

    @{ Id = 'coreparking'; Cat = 'Power'; Icon = [char]0xE964; Rec = $true
       Title = 'Unpark all CPU cores'
       Desc  = 'Keeps every core awake so game threads never wait for a parked core to wake up.'
       Warn  = 'You have an X3D dual-CCD Ryzen (7950X3D/9950X3D). Their driver parks cores on purpose (hidden on those CPUs).'
       Requires = { (Get-CpuName) -notmatch 'X3D' }
       Power = @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '0cc5b647-c1df-4637-891a-dec35c318583'; V = 100; D = 10 } }

    @{ Id = 'usb3lpm'; Cat = 'Power'; Icon = [char]0xE88E; Rec = $true
       Title = 'Turn off USB 3 link power-saving'
       Desc  = 'Stops USB 3 ports dropping into low-power link states between mouse and keyboard reports.'
       Warn  = 'You are on a laptop on battery. Only the plugged-in value of the current plan changes.'
       Power = @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'; V = 0; D = 2 } }

    @{ Id = 'usbhub'; Cat = 'Power'; Icon = [char]0xE88E; Rec = $true
       Title = 'USB hubs never suspend'
       Desc  = 'Sets the USB hub selective-suspend timeout to off, so hubs never doze.'
       Warn  = 'You are on a laptop on battery. Only the plugged-in value of the current plan changes.'
       Power = @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = '0853a681-27c8-4100-a2fd-82013e970683'; V = 0; D = 50 } }

    @{ Id = 'diskoff'; Cat = 'Power'; Icon = [char]0xEDA2; Rec = $true
       Title = 'Drives never power down'
       Desc  = 'Stops drives spinning down or sleeping, which causes a freeze when the game streams data from them.'
       Warn  = 'You have a hard drive you rarely use and want it quiet.'
       Power = @{ Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Set = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; V = 0; D = 1200 } }

    # ============================================================== Graphics
    @{ Id = 'refreshrate'; Cat = 'Graphics'; Icon = [char]0xE7F4; Rec = $true
       Title = 'Use your monitor''s highest refresh rate'
       Desc  = 'Windows often leaves high-Hz monitors at 60 Hz. This sets your main display to its maximum.'
       Warn  = 'Your cable cannot carry the higher rate (screen goes black: wait 15 s, Windows reverts).'
       Test  = { $max = [NativeDisplay]::MaxHz(); if ($max -le 0) { return $null }; [NativeDisplay]::CurrentHz() -ge $max }
       On    = {
           if (-not $script:Backup.Custom.ContainsKey('refreshrate')) { $script:Backup.Custom['refreshrate'] = [NativeDisplay]::CurrentHz() }
           if ([NativeDisplay]::SetHz([NativeDisplay]::MaxHz()) -ne 0) { throw 'Windows refused the refresh rate.' }
       }
       Off   = {
           $hz = $script:Backup.Custom['refreshrate']
           if ($hz) { [void][NativeDisplay]::SetHz([int]$hz) }
           $script:Backup.Custom.Remove('refreshrate')
       } }

    @{ Id = 'autohdr'; Cat = 'Graphics'; Icon = [char]0xE790; Rec = $true
       Title = 'Turn off Auto HDR'
       Desc  = 'Auto HDR post-processes every frame of SDR games, adding GPU work. Fortnite has its own HDR option.'
       Warn  = 'You play on an HDR monitor and like how Auto HDR looks.'
       Dx    = @{ K = 'AutoHDREnable'; V = '0'; D = '1'; M = '0' } }

    @{ Id = 'gamebartips'; Cat = 'Graphics'; Icon = [char]0xE7FC; Rec = $true
       Title = 'Turn off Game Bar startup tips'
       Desc  = 'Stops the "Press Win+G" pop-up appearing over games when they start.'
       Warn  = 'Never really. It only hides a tip.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'ShowStartupPanel'; V = 0; D = 1; M = 1 } ) }

    # ========================================================= Input & audio
    @{ Id = 'ducking'; Cat = 'Input'; Icon = [char]0xE767; Rec = $true
       Title = 'Stop Windows lowering game volume'
       Desc  = 'Windows turns other sounds down during voice calls. This keeps footsteps at full volume in Discord calls.'
       Warn  = 'You want music and game audio quieter while you are on calls.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Multimedia\Audio'; N = 'UserDuckingPreference'; V = 3; D = 0; M = 0 } ) }

    @{ Id = 'langhotkey'; Cat = 'Input'; Icon = [char]0xE765; Rec = $true; Badge = 'signout'
       Title = 'Block Alt+Shift language switching'
       Desc  = 'Stops Alt+Shift / Ctrl+Shift swapping your keyboard layout mid-fight and breaking your binds.'
       Warn  = 'You type in several languages and switch with Alt+Shift. Win+Space still works.'
       Reg   = @(
           @{ P = 'HKCU:\Keyboard Layout\Toggle'; N = 'Hotkey'; V = '3'; T = 'String'; D = '1'; M = '1' }
           @{ P = 'HKCU:\Keyboard Layout\Toggle'; N = 'Language Hotkey'; V = '3'; T = 'String'; D = '1'; M = '1' }
           @{ P = 'HKCU:\Keyboard Layout\Toggle'; N = 'Layout Hotkey'; V = '3'; T = 'String'; D = '2'; M = '2' }
       ) }

    @{ Id = 'narrator'; Cat = 'Input'; Icon = [char]0xE8C9; Rec = $true
       Title = 'Block the Narrator shortcut'
       Desc  = 'Stops Ctrl+Win+Enter from launching Narrator and talking over your game.'
       Warn  = 'You use Narrator. You can still start it from Settings.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; N = 'WinEnterLaunchEnabled'; V = 0; D = 1; M = 1 } ) }

    # =============================================================== Network
    @{ Id = 'coalescing'; Cat = 'Network'; Icon = [char]0xE839; Rec = $true
       Title = 'Turn off packet coalescing'
       Desc  = 'Stops the adapter holding incoming packets to deliver them in batches.'
       Warn  = 'You are on a laptop on battery. Applying briefly reconnects the adapter.'
       Test  = { Test-AdvProp '*PacketCoalescing' 0 }
       On    = { Set-AdvProp 'coalescing' '*PacketCoalescing' 0 }
       Off   = { Reset-AdvProp 'coalescing' '*PacketCoalescing' 1 } }

    @{ Id = 'flowcontrol'; Cat = 'Network'; Icon = [char]0xE839; Rec = $false; Badge = 'advanced'
       Title = 'Turn off flow control'
       Desc  = 'Stops the adapter pausing traffic when the switch or router signals congestion.'
       Warn  = 'You see packet loss afterwards. Some cheap switches need flow control.'
       Test  = { Test-AdvProp '*FlowControl' 0 }
       On    = { Set-AdvProp 'flowcontrol' '*FlowControl' 0 }
       Off   = { Reset-AdvProp 'flowcontrol' '*FlowControl' 3 } }

    @{ Id = 'greeneth'; Cat = 'Network'; Icon = [char]0xE968; Rec = $true
       Title = 'Turn off Green Ethernet'
       Desc  = 'Realtek power-saving that lowers link power on short cables and can add jitter.'
       Warn  = 'You do not have a Realtek adapter (hidden then). Applying briefly reconnects the adapter.'
       Test  = { Test-AdvProp 'EnableGreenEthernet' 0 }
       On    = { Set-AdvProp 'greeneth' 'EnableGreenEthernet' 0 }
       Off   = { Reset-AdvProp 'greeneth' 'EnableGreenEthernet' 1 } }

    @{ Id = 'advancedeee'; Cat = 'Network'; Icon = [char]0xE968; Rec = $true
       Title = 'Turn off Advanced EEE'
       Desc  = 'Realtek''s extra Energy-Efficient Ethernet mode, separate from standard EEE.'
       Warn  = 'You do not have a Realtek adapter (hidden then). Applying briefly reconnects the adapter.'
       Test  = { Test-AdvProp 'AdvancedEEE' 0 }
       On    = { Set-AdvProp 'advancedeee' 'AdvancedEEE' 0 }
       Off   = { Reset-AdvProp 'advancedeee' 'AdvancedEEE' 1 } }

    @{ Id = 'rtkpower'; Cat = 'Network'; Icon = [char]0xE968; Rec = $true
       Title = 'Turn off adapter power saving mode'
       Desc  = 'Realtek "Power Saving Mode" lets the chip sleep between packets.'
       Warn  = 'You do not have a Realtek adapter (hidden then). Applying briefly reconnects the adapter.'
       Test  = { Test-AdvProp 'PowerSavingMode' 0 }
       On    = { Set-AdvProp 'rtkpower' 'PowerSavingMode' 0 }
       Off   = { Reset-AdvProp 'rtkpower' 'PowerSavingMode' 1 } }

    @{ Id = 'roaming'; Cat = 'Network'; Icon = [char]0xE701; Rec = $true
       Title = 'Wi-Fi: lowest roaming aggressiveness'
       Desc  = 'Stops Intel Wi-Fi scanning for a "better" access point mid-game, a classic cause of ping spikes.'
       Warn  = 'You move around a big home with several access points. Applying briefly reconnects Wi-Fi.'
       Test  = { Test-AdvDisplay 'RoamAggressiveness' 'Lowest' }
       On    = { Set-AdvDisplay 'roaming' 'RoamAggressiveness' 'Lowest' }
       Off   = { Reset-AdvProp 'roaming' 'RoamAggressiveness' 2 } }

    @{ Id = 'mimo'; Cat = 'Network'; Icon = [char]0xE701; Rec = $true
       Title = 'Wi-Fi: no MIMO power saving'
       Desc  = 'Keeps all Intel Wi-Fi antennas active instead of switching some off to save power.'
       Warn  = 'You are on battery. Intel adapters only (hidden otherwise). Applying briefly reconnects Wi-Fi.'
       Test  = { Test-AdvDisplay 'MIMOPowerSaveMode' 'No SMPS' }
       On    = { Set-AdvDisplay 'mimo' 'MIMOPowerSaveMode' 'No SMPS' }
       Off   = { Reset-AdvProp 'mimo' 'MIMOPowerSaveMode' 3 } }

    @{ Id = 'preferipv4'; Cat = 'Network'; Icon = [char]0xE909; Rec = $false; Badge = 'restart'
       Live  = { $pp = @(Get-NetPrefixPolicy -ErrorAction Stop); $v4 = ($pp | Where-Object { $_.Prefix -eq '::ffff:0:0/96' }).Precedence; $v6 = ($pp | Where-Object { $_.Prefix -eq '::/0' }).Precedence; [bool]($v4 -gt $v6) }
       Title = 'Prefer IPv4 over IPv6'
       Desc  = 'Microsoft''s supported way to favour IPv4 without disabling IPv6. Avoids slow IPv6 fallbacks.'
       Warn  = 'Your provider gives you better routes over IPv6. Never disable IPv6 completely instead.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'; N = 'DisabledComponents'; V = 32; D = 0; M = 0 } ) }

    # ================================================== Background & privacy
    @{ Id = 'recall'; Cat = 'Background'; Icon = [char]0xE72E; Rec = $true
       Title = 'Turn off Recall snapshots'
       Desc  = 'Recall saves screenshots of your screen every few seconds on Copilot+ PCs. Stops that work.'
       Warn  = 'You use Recall to search your history. Does nothing on PCs without Recall.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1; D = $null; M = 0 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1; D = $null; M = 0 }
       ) }

    @{ Id = 'websearch'; Cat = 'Background'; Icon = [char]0xE721; Rec = $true; Badge = 'signout'
       Title = 'Turn off web results in Start search'
       Desc  = 'Start menu search stays local instead of sending every keystroke to Bing.'
       Warn  = 'You use Start search to search the web.'
       Reg   = @( @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'searchhl'; Cat = 'Background'; Icon = [char]0xE721; Rec = $true
       Title = 'Turn off search highlights'
       Desc  = 'Stops the search box downloading daily trending content and illustrations.'
       Warn  = 'You like the daily images in the search box.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsDynamicSearchBoxEnabled'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'adid'; Cat = 'Background'; Icon = [char]0xE72E; Rec = $true
       Title = 'Turn off advertising ID'
       Desc  = 'Stops apps using a per-user ID to track you for ads.'
       Warn  = 'Never. Apps just show less personalised ads.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'silentapps'; Cat = 'Background'; Icon = [char]0xE896; Rec = $true
       Title = 'Stop automatic app installs'
       Desc  = 'Stops Windows silently downloading and installing "suggested" apps in the background.'
       Warn  = 'Never. You can still install anything from the Store yourself.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SilentInstalledAppsEnabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'OemPreInstalledAppsEnabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'PreInstalledAppsEnabled'; V = 0; D = 1; M = 1 }
       ) }

    @{ Id = 'tips'; Cat = 'Background'; Icon = [char]0xE946; Rec = $true
       Title = 'Turn off tips and suggestions'
       Desc  = 'Removes Windows tips, Start suggestions and lock-screen promos, and the background work that fetches them.'
       Warn  = 'You find Windows tips useful.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SoftLandingEnabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338389Enabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338388Enabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338387Enabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SystemPaneSuggestionsEnabled'; V = 0; D = 1; M = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'RotatingLockScreenOverlayEnabled'; V = 0; D = 1; M = 1 }
       ) }

    @{ Id = 'activity'; Cat = 'Background'; Icon = [char]0xE81C; Rec = $true
       Title = 'Turn off activity history'
       Desc  = 'Stops Windows logging the apps and files you use and syncing that history.'
       Warn  = 'You use Timeline-style "pick up where you left off" features.'
       Reg   = @(
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; V = 0; D = $null; M = 1 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities'; V = 0; D = $null; M = 1 }
       ) }

    @{ Id = 'telemetrypolicy'; Cat = 'Background'; Icon = [char]0xE9F9; Rec = $true
       Title = 'Minimum diagnostic data'
       Desc  = 'Sets Windows diagnostic data to the lowest level your edition allows (Required on Home/Pro).'
       Warn  = 'Your PC is managed by work or school IT.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = 0; D = $null; M = -1 } ) }

    @{ Id = 'ceip'; Cat = 'Background'; Icon = [char]0xE9F9; Rec = $true
       Title = 'Turn off Customer Experience Program'
       Desc  = 'Opts out of the Customer Experience Improvement Program and its background uploads.'
       Warn  = 'Never. It only stops usage data being sent.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows'; N = 'CEIPEnable'; V = 0; D = $null; M = 1 } ) }

    @{ Id = 'tailored'; Cat = 'Background'; Icon = [char]0xE72E; Rec = $true
       Title = 'Turn off tailored experiences'
       Desc  = 'Stops Microsoft using your diagnostic data to personalise tips and ads.'
       Warn  = 'Never. It only changes personalisation.'
       Reg   = @( @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; N = 'DisableTailoredExperiencesWithDiagnosticData'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'feedback'; Cat = 'Background'; Icon = [char]0xE946; Rec = $true
       Title = 'Stop feedback prompts'
       Desc  = 'Stops Windows asking for feedback with pop-ups.'
       Warn  = 'You are a Windows Insider who wants to send feedback (use Feedback Hub directly).'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; V = 0; D = $null; M = -1 } ) }

    @{ Id = 'wer'; Cat = 'Background'; Icon = [char]0xE7BA; Rec = $false
       Title = 'Turn off Windows Error Reporting'
       Desc  = 'Stops crash dumps being collected and uploaded in the background after an app crashes.'
       Warn  = 'You want Microsoft or app makers to get your crash reports so bugs get fixed.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; N = 'Disabled'; V = 1; D = 0; M = 0 } ) }

    @{ Id = 'mapsupdate'; Cat = 'Background'; Icon = [char]0xE909; Rec = $true
       Title = 'Turn off offline map updates'
       Desc  = 'Stops Windows downloading map updates in the background.'
       Warn  = 'You use offline maps in the Maps app.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\Maps'; N = 'AutoUpdateEnabled'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'edgebg'; Cat = 'Background'; Icon = [char]0xE774; Rec = $true
       Title = 'Stop Edge running in the background'
       Desc  = 'Turns off Edge Startup Boost and background mode, so Edge uses no CPU or RAM when closed.'
       Warn  = 'You want Edge to open instantly. Edge will show "managed by your organization".'
       Reg   = @(
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'StartupBoostEnabled'; V = 0; D = $null; M = 1 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'BackgroundModeEnabled'; V = 0; D = $null; M = 1 }
       ) }

    @{ Id = 'chromebg'; Cat = 'Background'; Icon = [char]0xE774; Rec = $true
       Title = 'Stop Chrome running in the background'
       Desc  = 'Stops Chrome staying alive after you close it.'
       Warn  = 'You rely on Chrome apps or notifications while it is closed. Chrome will show "managed by your organization".'
       Requires = { (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") -or (Test-Path "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; N = 'BackgroundModeEnabled'; V = 0; D = $null; M = 1 } ) }

    @{ Id = 'defendercpu'; Cat = 'Background'; Icon = [char]0xE83D; Rec = $true
       Title = 'Limit Defender scan CPU use'
       Desc  = 'Caps scheduled Defender scans at 20% CPU (default 50%) so a scan cannot tank your FPS.'
       Warn  = 'Never really. Scheduled scans just take longer. Protection is unchanged.'
       Test  = { $mp = Get-MpPreference -ErrorAction Stop; $mp.ScanAvgCPULoadFactor -le 20 }
       On    = {
           if (-not $script:Backup.Custom.ContainsKey('defendercpu')) { $script:Backup.Custom['defendercpu'] = (Get-MpPreference).ScanAvgCPULoadFactor }
           Set-MpPreference -ScanAvgCPULoadFactor 20
       }
       Off   = {
           $v = $script:Backup.Custom['defendercpu']; if (-not $v) { $v = 50 }
           Set-MpPreference -ScanAvgCPULoadFactor ([int]$v)
           $script:Backup.Custom.Remove('defendercpu')
       } }

    # ===================================================== Services & tasks
    (New-SvcTweak 'svc-wsearch' 'WSearch' 2 'Turn off Windows Search indexing' 'Stops the indexer crawling your files in the background, which causes disk and CPU bursts.' 'You search files from Start or Outlook. Search still works, just slower.' $false 'advanced')
    (New-SvcTweak 'svc-spooler' 'Spooler' 2 'Turn off Print Spooler' 'Stops the printer service when you have no printer. Also closes a well-known attack surface.' 'You print, or use "Print to PDF".' $false $null)
    (New-SvcTweak 'svc-fax' 'Fax' 3 'Turn off Fax service' 'Disables the fax service almost nobody uses.' 'You send faxes from this PC.' $true $null)
    (New-SvcTweak 'svc-maps' 'MapsBroker' 2 'Turn off Downloaded Maps Manager' 'Stops the service that manages offline maps.' 'You use offline maps.' $true $null)
    (New-SvcTweak 'svc-retaildemo' 'RetailDemo' 3 'Turn off Retail Demo service' 'Disables the shop-display demo mode service.' 'Never on a home PC.' $true $null)
    (New-SvcTweak 'svc-wappush' 'dmwappushservice' 3 'Turn off WAP Push routing' 'Telemetry companion service that routes device-management push messages.' 'Your PC is managed by work or school IT (Intune/MDM).' $true $null)
    (New-SvcTweak 'svc-geo' 'lfsvc' 3 'Turn off Geolocation service' 'Stops apps polling your location in the background.' 'You use automatic time zone, weather location or Find My Device.' $false $null)
    (New-SvcTweak 'svc-trkwks' 'TrkWks' 2 'Turn off Link Tracking client' 'Tracks moved files on NTFS network shares, which home PCs do not need.' 'You use shortcuts to files on a work network share.' $true $null)
    (New-SvcTweak 'svc-pca' 'PcaSvc' 2 'Turn off Program Compatibility Assistant' 'Stops Windows monitoring every program you run for compatibility problems.' 'You run very old programs that need compatibility fixes.' $false 'advanced')
    (New-SvcTweak 'svc-iphlp' 'iphlpsvc' 2 'Turn off IP Helper' 'IPv6 transition tunnels (Teredo, IP-HTTPS) that Fortnite does not use.' 'You use Xbox party chat on PC or a work VPN that needs IP-HTTPS.' $false 'advanced')
    (New-SvcTweak 'svc-nvtelemetry' 'NvTelemetryContainer' 2 'Turn off NVIDIA telemetry' 'Older NVIDIA drivers run a telemetry container in the background (hidden if you do not have it).' 'Never. Drivers and the NVIDIA app keep working.' $true $null)

    @{ Id = 'task-telemetry'; Cat = 'Services'; Icon = [char]0xE823; Rec = $true
       Title = 'Turn off telemetry tasks'
       Desc  = 'Compatibility Appraiser (CompatTelRunner) and friends can max out a CPU core for minutes at random.'
       Warn  = 'Never really. Feature updates may turn the Appraiser back on, so check after big updates.'
       Tasks = @(
           '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
           '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp'
           '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
           '\Microsoft\Windows\Application Experience\PcaPatchDbTask'
           '\Microsoft\Windows\Autochk\Proxy'
           '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
           '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
           '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
       ) }

    @{ Id = 'task-feedback'; Cat = 'Services'; Icon = [char]0xE823; Rec = $true
       Title = 'Turn off feedback tasks'
       Desc  = 'Stops the scheduled tasks that collect and download feedback scenarios.'
       Warn  = 'You are a Windows Insider sending feedback.'
       Tasks = @( '\Microsoft\Windows\Feedback\Siuf\DmClient', '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload' ) }

    @{ Id = 'task-maps'; Cat = 'Services'; Icon = [char]0xE823; Rec = $true
       Title = 'Turn off map update tasks'
       Desc  = 'Stops the scheduled tasks that check for offline map updates.'
       Warn  = 'You use offline maps.'
       Tasks = @( '\Microsoft\Windows\Maps\MapsUpdateTask', '\Microsoft\Windows\Maps\MapsToastTask' ) }

    @{ Id = 'task-wer'; Cat = 'Services'; Icon = [char]0xE823; Rec = $false
       Title = 'Turn off error report queue task'
       Desc  = 'Stops the task that uploads queued crash reports in the background.'
       Warn  = 'You want your crash reports sent so bugs get fixed.'
       Tasks = @( '\Microsoft\Windows\Windows Error Reporting\QueueReporting' ) }

    @{ Id = 'task-office'; Cat = 'Services'; Icon = [char]0xE823; Rec = $true
       Title = 'Turn off Office telemetry tasks'
       Desc  = 'Stops Office''s telemetry agent running at logon (hidden if Office is not installed).'
       Warn  = 'Your Office is managed by work IT.'
       Tasks = @( '\Microsoft\Office\OfficeTelemetryAgentLogOn2016', '\Microsoft\Office\OfficeTelemetryAgentFallBack2016' ) }

    # ===================================================== Storage & updates
    @{ Id = 'noreboot'; Cat = 'Storage'; Icon = [char]0xE72C; Rec = $true
       Title = 'No forced update restarts'
       Desc  = 'Windows Update will not restart the PC on its own while you are signed in.'
       Warn  = 'You never restart manually. Updates then wait until you do.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'NoAutoRebootWithLoggedOnUsers'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'drivers'; Cat = 'Storage'; Icon = [char]0xE896; Rec = $false
       Title = 'Stop Windows Update replacing drivers'
       Desc  = 'Keeps the GPU and network drivers you installed instead of Windows swapping in older ones.'
       Warn  = 'You never install drivers yourself. Then Windows Update is your only driver source.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'ExcludeWUDriversInQualityUpdate'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'faststartup'; Cat = 'Storage'; Icon = [char]0xE7E8; Rec = $true
       Title = 'Turn off Fast Startup'
       Desc  = 'Shut down then does a real fresh start, clearing stuck driver and memory state.'
       Warn  = 'You want the fastest possible boot from shut down. Restarts are unaffected either way.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; N = 'HiberbootEnabled'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'hibernate'; Cat = 'Storage'; Icon = [char]0xEDA2; Rec = $false
       Title = 'Turn off hibernation'
       Desc  = 'Deletes hiberfil.sys and frees disk space equal to roughly 40% of your RAM.'
       Warn  = 'You hibernate your laptop. This also turns off Fast Startup.'
       Test  = {
           $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
           if ($null -eq $v) { $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabledDefault' }
           if ($null -eq $v) { return $null }; $v -eq 0
       }
       On    = { powercfg /h off; if ($LASTEXITCODE -ne 0) { throw 'powercfg could not turn hibernation off.' }; $script:Backup.Custom['hibernate'] = $true }
       Off   = { powercfg /h on; $script:Backup.Custom.Remove('hibernate') } }

    @{ Id = 'cleantemp'; Cat = 'Storage'; Icon = [char]0xE74D; Action = 'Clean now'
       Title = 'Clear temporary files'
       Desc  = 'Deletes temp files older than a day from your user and Windows temp folders. Files in use are skipped.'
       Warn  = ''
       Run   = {
           $cut = (Get-Date).AddDays(-1); $bytes = 0
           foreach ($dir in @($env:TEMP, "$env:WINDIR\Temp")) {
               Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | ForEach-Object {
                   $len = $_.Length
                   try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $bytes += $len } catch {}
               }
           }
           'Freed {0:N0} MB of temporary files.' -f ($bytes / 1MB)
       } }

    # ======================================================= researched additions (1.4)
    @{ Id = 'hybrid-pcore'; Cat = 'Power'; Icon = [char]0xE964; Rec = $true; Lat = $true
       Title = 'Hybrid CPUs: full speed on performance cores'
       Desc  = 'Intel 12th gen and newer have separate power settings for their fast cores. This gives them the same max-performance, minimum-speed and never-park settings the other power cards give the rest.'
       Warn  = 'Laptops on battery run hotter. Only shown on CPUs with two kinds of core.'
       Requires = { (Get-CpuName) -match 'i[3579]-1[2-4]\d{3}|Core\(TM\) Ultra|Core Ultra|i[3579]-2\d{2}[A-Z]' }
       Powers = @( @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '36687f9e-e3a5-4dbf-b1dc-15eb381c6864'; V = 0; D = 33 }
                   @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '893dee8e-2bef-41e0-89c6-b55d0929964d'; V = 100; D = 5 }
                   @{ Sub = '54533251-82be-4824-96c1-47b60b740d00'; Set = '0cc5b647-c1df-4637-891a-dec35c318584'; V = 100; D = 0 } )
       Test  = { Test-PowerSet $t }; On = { Enable-PowerSet $t }; Off = { Disable-PowerSet $t } }

    @{ Id = 'nvme-idle'; Cat = 'Power'; Icon = [char]0xEDA2; Rec = $true; Lat = $true
       Title = 'Keep NVMe SSDs out of deep sleep'
       Desc  = 'Windows lets NVMe drives doze after 0.2 s idle, and waking them can take milliseconds: a small hitch when the game loads data. Uses the High Performance plan values while plugged in.'
       Warn  = 'Laptops: the SSD uses a little more power when plugged in.'
       Powers = @( @{ Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Set = 'fc95af4d-40e7-4b6d-835a-56d131dbc80e'; V = 0; D = 15 }
                   @{ Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Set = 'dbc9e238-6de9-49e3-92cd-8c2b4946b472'; V = 0; D = 100 } )
       Test  = { Test-PowerSet $t }; On = { Enable-PowerSet $t }; Off = { Disable-PowerSet $t } }

    @{ Id = 'sata-lpm'; Cat = 'Power'; Icon = [char]0xEDA2; Rec = $true; Lat = $true
       Title = 'Turn off SATA link power-saving'
       Desc  = 'Keeps the link to SATA SSDs and hard drives awake instead of letting it sleep between reads, which can cost up to 10 ms on wake.'
       Warn  = 'Laptops: slightly more power use. Does nothing if all your drives are NVMe.'
       Power = @{ Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Set = '0b2d69d7-a2a1-449c-9680-f91c70521c60'; V = 0; D = 1 } }

    @{ Id = 'gpu-msi'; Cat = 'Graphics'; Icon = [char]0xE7F4; Rec = $false; Lat = $true; Badge = 'restart'
       Title = 'Graphics card: message-signalled interrupts'
       Desc  = 'Lets the graphics card signal the CPU without sharing an interrupt line, which lowers driver latency spikes. Only shown when your driver has not already done this itself (most new ones have).'
       Warn  = 'If a device stops working after the restart, turn this off again. A driver reinstall can reset it.'
       Requires = { @(Get-GpuMsiKeys).Count -gt 0 -and ((Test-GpuMsi) -eq $false -or $script:Backup.Custom.ContainsKey('gpu-msi')) }
       Test  = { Test-GpuMsi }
       On    = {
           $keys = Get-GpuMsiKeys
           if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @($keys | ForEach-Object { @{ Key = $_; Value = (Get-RegValue $_ 'MSISupported') } }) }
           foreach ($k in $keys) { if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }; Set-RegValue $k 'MSISupported' 1 'DWord' } }
       Off   = {
           foreach ($b in @($script:Backup.Custom[$t.Id])) { if ($null -eq $b.Value) { Remove-RegValue $b.Key 'MSISupported' } else { Set-RegValue $b.Key 'MSISupported' ([int]$b.Value) 'DWord' } }
           $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'hypervisor'; Cat = 'System'; Icon = [char]0xE83D; Rec = $false; Lat = $true; Badge = 'restart'
       Title = "Don't start the Windows hypervisor"
       Desc  = 'With Hyper-V, WSL2, Sandbox or Memory Integrity installed, Windows itself runs on a hypervisor, which adds overhead to interrupts and memory access. Microsoft''s gaming guide suggests turning it off.'
       Warn  = 'You use WSL2, Docker, Hyper-V, Windows Sandbox or an Android emulator, or your work PC needs Credential Guard. Lowers kernel security protections. If BitLocker is on, keep your recovery key at hand.'
       Requires = { (Get-CimInstance Win32_ComputerSystem -Property HypervisorPresent).HypervisorPresent -or (Get-HypervisorLaunch) -eq 'Off' }
       Test  = { (Get-HypervisorLaunch) -eq 'Off' }
       On    = {
           if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = (Get-HypervisorLaunch) } }
           bcdedit /set '{current}' hypervisorlaunchtype off | Out-Null
           if ($LASTEXITCODE -ne 0) { throw 'Windows refused the boot setting.' } }
       Off   = {
           $v = $script:Backup.Custom[$t.Id].Value
           if ($v) { bcdedit /set '{current}' hypervisorlaunchtype $v | Out-Null } else { bcdedit /deletevalue '{current}' hypervisorlaunchtype | Out-Null }
           $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'mpo-off'; Cat = 'Graphics'; Icon = [char]0xE7F4; Rec = $false; Badge = 'restart'
       Title = 'Turn off multiplane overlay (MPO)'
       Desc  = 'NVIDIA''s official fix for flicker, black flashes and stutter on multi-monitor or mixed-refresh setups, often with a browser or Discord on a second screen. True fullscreen is not affected.'
       Warn  = 'Only use it if you see flicker or stutter with several monitors: it can add delay in borderless mode. Don''t combine with "Keep low-FPS games on overlay planes".'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; N = 'OverlayTestMode'; V = 5; D = $null; M = 0 } ) }

    @{ Id = 'overlay-minfps'; Cat = 'Graphics'; Icon = [char]0xE740; Rec = $false; Lat = $true; Badge = 'restart'
       Title = 'Keep low-FPS games on overlay planes'
       Desc  = 'A Microsoft-documented setting: a borderless game that briefly drops FPS keeps its low-latency direct path to the screen instead of being switched back to slower desktop composition.'
       Warn  = 'Only helps borderless/windowed play on Windows 11. Microsoft may remove it in a future version. Don''t combine with "Turn off multiplane overlay".'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; N = 'OverlayMinFPS'; V = 0; D = $null; M = 15 } ) }

    (New-SvcTweak 'nahimic' 'NahimicService' 2 'Turn off Nahimic audio effects' 'Nahimic (bundled with MSI, Alienware, Legion and some ASUS/Gigabyte boards) is widely reported to cause CPU spikes and game stutter.' 'You lose Nahimic sound and mic effects. Some driver updates turn it back on.' $true 'restart')

    @{ Id = 'fn-launchargs'; Cat = 'Fortnite'; Icon = [char]0xE756; Rec = $true
       Title = 'Switch off fake launch arguments'
       Desc  = 'Turns off the Epic launcher''s "Additional Command Line Arguments" box for Fortnite. Tweak-pack arguments like -useallavailablecores, -nosplash or -lanplay do nothing or cause problems. Your text is kept.'
       Warn  = 'You pass a real argument on purpose (for example for troubleshooting). Close the Epic Games Launcher first.'
       Requires = { [bool](Get-EpicLauncherIni) }
       Test  = { $a = Get-FnLaunchArgs; if (-not $a) { return $null }; $a.Enabled -ne 'True' -or -not $a.Args.Trim() }
       On    = { $a = Get-FnLaunchArgs; if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = $a.Enabled } }; Set-FnLaunchArgsEnabled 'False' }
       Off   = { $v = $script:Backup.Custom[$t.Id].Value; Set-FnLaunchArgsEnabled $(if ($v) { $v } else { 'True' }); $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'audiofx'; Cat = 'Input'; Icon = [char]0xE767; Rec = $true
       Title = 'Turn off audio enhancements'
       Desc  = 'The same as Settings > Sound > Audio enhancements: Off, for every playback device at once. Skips vendor effects (loudness EQ, virtual surround, Nahimic, Sonic Studio, Dolby) that add processing delay and CPU time to game sound.'
       Warn  = 'Laptop speakers can sound thinner, because some makers tune them with these effects. You lose virtual surround and EQ effects you rely on.'
       Requires = { @([AudioFx]::List()).Count -gt 0 }
       Test  = { $eps = @([AudioFx]::List()); if (-not $eps.Count) { return $null }; -not ($eps | Where-Object { $_.Disabled -ne 1 }) }
       On    = {
           $eps = @([AudioFx]::List())
           if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @($eps | ForEach-Object { @{ Id = $_.Id; Value = $_.Disabled } }) }
           $bad = 0; foreach ($e in $eps) { if ([AudioFx]::Set($e.Id, 1) -ne 0) { $bad++ } }
           if ($bad -eq $eps.Count) { throw 'Windows did not let ZeroDelay change the sound devices.' } }
       Off   = {
           foreach ($b in @($script:Backup.Custom[$t.Id])) { [void][AudioFx]::Set($b.Id, [int]$b.Value) }
           $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'activehours'; Cat = 'Storage'; Icon = [char]0xE72C; Rec = $true
       Title = 'Windows Update: no restarts while you play'
       Desc  = 'Sets Windows Update''s active hours to noon until 6 in the morning (the longest window Windows allows), so an update can never restart the PC during a session. Updates restart the PC in the morning instead.'
       Warn  = 'You play in the morning. You can still move the window in Settings > Windows Update > Advanced options.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; N = 'ActiveHoursStart'; V = 12; D = 8; M = 8 }
                  @{ P = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; N = 'ActiveHoursEnd'; V = 6; D = 17; M = 17 }
                  @{ P = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; N = 'SmartActiveHoursState'; V = 0; D = $null; M = 1 } ) }

    @{ Id = 'searchclassic'; Cat = 'Background'; Icon = [char]0xE721; Rec = $true
       Title = 'Search indexer: your folders only, not every drive'
       Desc  = 'Windows Search''s "Enhanced" mode indexes every drive, including game files and shader caches, so it keeps re-reading files you never search for. Classic mode indexes only your Documents, Pictures, Music and Desktop.'
       Warn  = 'You rely on Start search finding files on other drives. Only shown while Enhanced mode is on.'
       Requires = { (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows Search\Gather\Windows\SystemIndex' 'EnableFindMyFiles') -eq 1 -or $script:Backup.Custom.ContainsKey('searchclassic') -or ($script:Backup.Registry | Where-Object { $_.Tweak -eq 'searchclassic' }) }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows Search\Gather\Windows\SystemIndex'; N = 'EnableFindMyFiles'; V = 0; D = 1; M = 0 } )
       After = { Restart-Service WSearch -Force -ErrorAction SilentlyContinue } }

    @{ Id = 'powermode'; Cat = 'Power'; Icon = [char]0xE945; Rec = $true; Lat = $true
       Title = 'Power mode slider: Best performance'
       Desc  = 'On laptops and PCs that only offer the Balanced plan, the Settings "Power mode" slider is the real power plan: it decides CPU boost and background throttling. This moves it to Best performance.'
       Warn  = 'Battery life drops noticeably. Only shown while the Balanced plan is active (the ZeroDelay and Ultimate plans ignore the slider).'
       Requires = { (Get-ActivePowerScheme).Guid -eq '381b4222-f694-41f0-9685-ff5bb260df2e' -or $script:Backup.Custom.ContainsKey('powermode') }
       Test  = { $g = [PowerOverlay]::Get(); if ($null -eq $g) { return $null }; $g -eq [PowerOverlay]::BestPerformance }
       On    = {
           if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = "$([PowerOverlay]::Get())" } }
           if ([PowerOverlay]::Set([PowerOverlay]::BestPerformance) -ne 0) { throw 'Windows refused to change the power mode.' } }
       Off   = { $v = "$($script:Backup.Custom[$t.Id].Value)"; [void][PowerOverlay]::Set($(if ($v) { [Guid]$v } else { [PowerOverlay]::Balanced })); $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'alttab-windows'; Cat = 'Visuals'; Icon = [char]0xE737; Rec = $true
       Title = 'Alt+Tab shows windows only'
       Desc  = 'Stops Windows 11 adding Edge tabs to Alt+Tab, so jumping out of and back into Fortnite takes fewer presses.'
       Warn  = 'You like switching between Edge tabs with Alt+Tab.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'MultiTaskingAltTabFilter'; V = 3; D = $null; M = 1 } ) }

    @{ Id = 'diaglogs'; Cat = 'Background'; Icon = [char]0xE9D9; Rec = $true
       Title = 'Stop diagnostic log and dump uploads'
       Desc  = 'Microsoft''s policies to stop Windows collecting extra diagnostic logs and crash dumps and downloading its OneSettings configuration in the background. Removes occasional disk and network bursts.'
       Warn  = ''
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'LimitDiagnosticLogCollection'; V = 1; D = $null; M = 0 }
                  @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'LimitDumpCollection'; V = 1; D = $null; M = 0 }
                  @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'DisableOneSettingsDownloads'; V = 1; D = $null; M = 0 } ) }

    @{ Id = 'task-diag-extra'; Cat = 'Services'; Icon = [char]0xE823; Rec = $true
       Title = 'Turn off extra diagnostic tasks'
       Desc  = 'Scheduled tasks that collect device inventory, app backup data, power and sustainability statistics, plus the WinSAT benchmark. They wake the CPU and disk in the background.'
       Warn  = ''
       Tasks = @('\Microsoft\Windows\Device Information\Device', '\Microsoft\Windows\Device Information\Device User', '\Microsoft\Windows\Application Experience\MareBackup',
                 '\Microsoft\Windows\Application Experience\StartupAppTask', '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
                 '\Microsoft\Windows\Sustainability\SustainabilityTelemetry', '\Microsoft\Windows\Sustainability\PowerGridForecastTask', '\Microsoft\Windows\Maintenance\WinSAT') }

    @{ Id = 'docap'; Cat = 'Network'; Icon = [char]0xE896; Rec = $false; Lat = $true
       Title = 'Cap background update downloads'
       Desc  = 'Limits Windows Update and Store background downloads to 10% of your bandwidth, so a big update can''t fill your connection and spike your ping mid-match.'
       Warn  = 'You want updates to download as fast as possible.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N = 'DOPercentageMaxBackgroundBandwidth'; V = 10; D = $null; M = 0 } ) }

    @{ Id = 'store-autoupdate'; Cat = 'Background'; Icon = [char]0xE719; Rec = $false
       Title = 'Stop automatic Store app updates'
       Desc  = 'The Microsoft Store stops downloading app updates in the background. You can still update apps by hand. Windows Update is not affected.'
       Warn  = 'You want Store apps (Xbox, Phone Link, Notepad...) to keep updating themselves.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N = 'AutoDownload'; V = 2; D = $null; M = 4 } ) }

    @{ Id = 'onedrive-off'; Cat = 'Background'; Icon = [char]0xE753; Rec = $false; Badge = 'signout'
       Title = 'Turn off OneDrive sync'
       Desc  = 'Microsoft''s policy to stop OneDrive syncing entirely, so it never scans or uploads files in the background. Goes further than the upload-speed cap.'
       Warn  = 'You use OneDrive or back up your Desktop and Documents with it. Nothing syncs until you turn this off.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; N = 'DisableFileSyncNGSC'; V = 1; D = $null; M = 0 } ) }

    (New-SvcTweak 'dps' 'DPS' 2 'Turn off Diagnostic Policy Service' 'Stops problem detection and the hourly resource-usage logging that writes to disk in the background.' 'You use Windows troubleshooters, or the per-app network and battery usage pages in Settings.' $false 'restart')
    (New-SvcTweak 'ndu' 'Ndu' 2 'Turn off network data-usage monitor' 'Turns off the driver that counts every network packet per app. Removes a small per-packet cost; it has a history of memory leaks with some network drivers.' 'You use the Data usage page in Settings or data limits on a metered connection.' $false 'restart')
    (New-SvcTweak 'inventorysvc' 'InventorySvc' 2 'Turn off compatibility inventory service' 'Windows 11 24H2 runs app inventory and compatibility scans for about 5 minutes every 30 to 60 minutes. This stops them.' 'Windows may offer you the next big feature update later. Monthly security updates are not affected.' $false 'restart')

    @{ Id = 'wifi5ghz'; Cat = 'Network'; Icon = [char]0xE701; Rec = $false; Lat = $true
       Title = 'Wi-Fi: prefer the 5 GHz band'
       Desc  = 'Tells Intel Wi-Fi to prefer 5 GHz, which usually has less interference and lower jitter than 2.4 GHz.'
       Warn  = 'You connect on 6 GHz (Wi-Fi 6E/7): this would pull you down to 5 GHz. Or your 5 GHz signal is weak where you play. Applying briefly reconnects Wi-Fi.'
       Test  = { Test-AdvDisplay 'RoamingPreferredBandType' 'Prefer 5' }
       On    = { Set-AdvDisplay 'wifi5ghz' 'RoamingPreferredBandType' 'Prefer 5' }
       Off   = { Reset-AdvProp 'wifi5ghz' 'RoamingPreferredBandType' 0 } }

    # ======================================================= Creator tab (1.7)
    @{ Id = 'cr-autosave'; Cat = 'Creator'; Icon = [char]0xE74E; Rec = $true; Requires = { [bool](Get-PrPrefsFile) }
       Title = 'Premiere: auto-save every 15 minutes'
       Desc  = 'Premiere freezes for a moment every time it auto-saves, which shows up as hitches in playback on big projects. This moves a short interval back to Adobe''s 15-minute default.'
       Warn  = 'You want very frequent backups: save by hand with Ctrl+S instead. Close Premiere first.'
       Test  = { $f = Get-PrPrefsFile; if (-not $f) { return $null }; $v = Get-XmlTag ([IO.File]::ReadAllText($f)) 'BE.Prefs.AutoSave.Interval'; if ($null -eq $v) { return $null }; [int]$v -ge 15 }
       On    = { Assert-AppsClosed 'Adobe Premiere Pro' 'Premiere Pro'; $f = Get-PrPrefsFile; $d = Read-KeepText $f
               if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = (Get-XmlTag $d.Text 'BE.Prefs.AutoSave.Interval') } }
               $d.Text = Set-XmlTag $d.Text 'BE.Prefs.AutoSave.Interval' '15'; Write-KeepText $f $d }
       Off   = { Assert-AppsClosed 'Adobe Premiere Pro' 'Premiere Pro'; $f = Get-PrPrefsFile; $d = Read-KeepText $f
               $d.Text = Set-XmlTag $d.Text 'BE.Prefs.AutoSave.Interval' "$($script:Backup.Custom[$t.Id].Value)"; Write-KeepText $f $d; $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'cr-hwdecode'; Cat = 'Creator'; Icon = [char]0xE7F4; Rec = $true; Requires = { [bool](Get-PrPrefsFile) }
       Title = 'Premiere: hardware decoding and encoding'
       Desc  = 'Decodes H.264/HEVC footage and exports H.264/HEVC on the graphics card: much smoother timeline playback and faster exports. On by default; this keeps it on.'
       Warn  = 'Close Premiere first.'
       Keys  = @('Project.Prefs.Enableh264Acceleration', 'Project.Prefs.EnablehHWAcceleratedEncode', 'Project.Prefs.EnableNvidiaDecode', 'Project.Prefs.EnableIntelDecode', 'Project.Prefs.EnablehAMDDecode')
       Test  = { $f = Get-PrPrefsFile; if (-not $f) { return $null }; $x = [IO.File]::ReadAllText($f); $vals = @($t.Keys | ForEach-Object { Get-XmlTag $x $_ } | Where-Object { $null -ne $_ }); if (-not $vals) { return $null }; -not ($vals | Where-Object { $_ -ne 'true' }) }
       On    = { Assert-AppsClosed 'Adobe Premiere Pro' 'Premiere Pro'; $f = Get-PrPrefsFile; $d = Read-KeepText $f
               if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $b = @{}; foreach ($k in $t.Keys) { $b[$k] = Get-XmlTag $d.Text $k }; $script:Backup.Custom[$t.Id] = $b }
               foreach ($k in $t.Keys) { if ($null -ne (Get-XmlTag $d.Text $k)) { $d.Text = Set-XmlTag $d.Text $k 'true' } }; Write-KeepText $f $d }
       Off   = { Assert-AppsClosed 'Adobe Premiere Pro' 'Premiere Pro'; $f = Get-PrPrefsFile; $d = Read-KeepText $f; $b = $script:Backup.Custom[$t.Id]
               foreach ($k in $t.Keys) { $v = if ($b -is [hashtable]) { $b[$k] } else { $b.$k }; if ($v) { $d.Text = Set-XmlTag $d.Text $k "$v" } }; Write-KeepText $f $d; $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'cr-ramreserve'; Cat = 'Creator'; Icon = [char]0xE964; Rec = $false; Requires = { [bool](Get-MemBalancerFile) }
       Title = 'Adobe RAM reserve: Adobe''s default'
       Desc  = 'Premiere, After Effects and Media Encoder share one "RAM reserved for other applications" setting. This sets it back to Adobe''s own default for how much RAM this PC has, so the video apps get the rest.'
       Warn  = 'You run a game, OBS or a heavy browser next to Premiere and want them to keep more RAM. Close the Adobe video apps first.'
       Test  = { $r = Get-AdobeReserve; if (-not $r) { return $null }; $r.Current -eq $r.Default }
       On    = { Assert-AppsClosed $AdobeVideoProcs 'Premiere Pro, After Effects and Media Encoder'; $r = Get-AdobeReserve; if (-not $r) { throw 'Adobe memory settings not found.' }
               if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = "$($r.Current)" } }
               $d = Read-KeepText $r.File
               $d.Text = [regex]::Replace($d.Text, "(<key>memorytouseforotherapplications</key>\s*<int[^>]*>)\d+(</int>)", { param($m) $m.Groups[1].Value + "$($r.Default)" + $m.Groups[2].Value })
               Write-KeepText $r.File $d }
       Off   = { Assert-AppsClosed $AdobeVideoProcs 'Premiere Pro, After Effects and Media Encoder'; $f = Get-MemBalancerFile; $v = "$($script:Backup.Custom[$t.Id].Value)"
               if ($v -match '^\d+$') { $d = Read-KeepText $f; $d.Text = [regex]::Replace($d.Text, "(<key>memorytouseforotherapplications</key>\s*<int[^>]*>)\d+(</int>)", { param($m) $m.Groups[1].Value + $v + $m.Groups[2].Value }); Write-KeepText $f $d }
               $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'cr-mfr'; Cat = 'Creator'; Icon = [char]0xE9D9; Rec = $true; Requires = { [bool](Get-AePrefsFile) }
       Title = 'After Effects: Multi-Frame Rendering'
       Desc  = 'Renders several frames at once on all CPU cores: 1.2 to 4 times faster previews and exports. On by default since 2022; this turns it back on if it was switched off.'
       Warn  = 'Close After Effects first.'
       Test  = { $f = Get-AePrefsFile; if (-not $f) { return $null }; $v = Get-AeValue ([IO.File]::ReadAllText($f)) 'Concurrent Frame Rendering' 'Enable Concurrent Frame Renders'; if ($null -eq $v) { return $null }; $v -eq '01' }
       On    = { Assert-AppsClosed 'AfterFX', 'aerender' 'After Effects'; $f = Get-AePrefsFile; $d = Read-KeepText $f
               if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = (Get-AeValue $d.Text 'Concurrent Frame Rendering' 'Enable Concurrent Frame Renders') } }
               $d.Text = Set-AeValue $d.Text 'Concurrent Frame Rendering' 'Enable Concurrent Frame Renders' '01'; Write-KeepText $f $d }
       Off   = { Assert-AppsClosed 'AfterFX', 'aerender' 'After Effects'; $f = Get-AePrefsFile; $d = Read-KeepText $f; $v = "$($script:Backup.Custom[$t.Id].Value)"
               if ($v) { $d.Text = Set-AeValue $d.Text 'Concurrent Frame Rendering' 'Enable Concurrent Frame Renders' $v; Write-KeepText $f $d }; $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'cr-gpupref'; Cat = 'Creator'; Icon = [char]0xE7F8; Rec = $true
       Title = 'Adobe apps on the dedicated graphics card'
       Desc  = 'This PC has two graphics chips. Windows can start Premiere, After Effects, Photoshop or Media Encoder on the weaker built-in one. This pins them to the dedicated card, like Settings > Display > Graphics > High performance.'
       Warn  = 'Restart the Adobe apps afterwards.'
       Requires = { @(Get-CreatorExes | Where-Object { $_ -notmatch 'obs' }).Count -gt 0 -and @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Virtual|Parsec|Remote|Basic' }).Count -ge 2 }
       Test  = { $ex = @(Get-CreatorExes); if (-not $ex) { return $null }; -not ($ex | Where-Object { "$(Get-RegValue $GpuPrefKey $_)" -notmatch 'GpuPreference=2;' }) }
       On    = { foreach ($e in Get-CreatorExes) { Set-RegTracked 'cr-gpupref' $GpuPrefKey $e 'GpuPreference=2;' 'String' } }
       Off   = { if (-not (Restore-RegTweak 'cr-gpupref')) { foreach ($e in Get-CreatorExes) { Remove-RegValue $GpuPrefKey $e } } } }

    @{ Id = 'cr-obsprio'; Cat = 'Creator'; Icon = [char]0xE714; Rec = $true; Requires = { Test-Path $ObsIni }
       Title = 'OBS: Above Normal priority'
       Desc  = 'OBS needs a bit more CPU priority than normal apps so recordings and streams do not drop frames, but "High" makes the game itself stutter. Above Normal is the balanced setting.'
       Warn  = 'Close OBS first.'
       Test  = { if (-not (Test-Path $ObsIni)) { return $null }; $l = Get-Content $ObsIni | Where-Object { $_ -match '^ProcessPriority=' } | Select-Object -First 1; "$l" -eq 'ProcessPriority=AboveNormal' }
       On    = { Assert-AppsClosed 'obs64' 'OBS'
               $lines = [IO.File]::ReadAllLines($ObsIni)
               $cur = $lines | Where-Object { $_ -match '^ProcessPriority=' } | Select-Object -First 1
               if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = $(if ($cur) { $cur.Substring(16) } else { '' }) } }
               if ($cur) { $lines = $lines | ForEach-Object { if ($_ -match '^ProcessPriority=') { 'ProcessPriority=AboveNormal' } else { $_ } } }
               else { $out = New-Object Collections.Generic.List[string]; foreach ($x in $lines) { $out.Add($x); if ($x -eq '[General]') { $out.Add('ProcessPriority=AboveNormal') } }; $lines = $out.ToArray() }
               $d = Read-KeepText $ObsIni; [IO.File]::WriteAllLines($ObsIni, $lines, (New-Object Text.UTF8Encoding ([bool]$d.Bom))) }
       Off   = { Assert-AppsClosed 'obs64' 'OBS'; $v = "$($script:Backup.Custom[$t.Id].Value)"
               $d = Read-KeepText $ObsIni
               $lines = [IO.File]::ReadAllLines($ObsIni) | Where-Object { $v -or $_ -notmatch '^ProcessPriority=' } | ForEach-Object { if ($v -and $_ -match '^ProcessPriority=') { "ProcessPriority=$v" } else { $_ } }
               [IO.File]::WriteAllLines($ObsIni, @($lines), (New-Object Text.UTF8Encoding ([bool]$d.Bom))); $script:Backup.Custom.Remove($t.Id) } }

    @{ Id = 'cr-keepawake'; Cat = 'Creator'; Icon = [char]0xE708; Rec = $true; Requires = { Test-CreatorPc }
       Title = 'Stay awake while rendering'
       Desc  = 'While Media Encoder, an After Effects render or a Premiere export is busy, ZeroDelay asks Windows not to sleep, so a long render does not stop halfway. It lets go as soon as the render ends. ZeroDelay must be running (the tray is enough).'
       Warn  = ''
       Test  = { [bool](Get-Setting 'keepawake' $false) }
       On    = { $script:Backup.Custom['keepawake'] = $true; Save-Backup; Start-RenderWatch }
       Off   = { $script:Backup.Custom['keepawake'] = $false; Save-Backup; [KeepAwake]::Release(); $script:RenderAwake = $false } }

    @{ Id = 'cr-adv-premiere'; Cat = 'Creator'; Icon = [char]0xE946; Action = 'Show how'; Requires = { Test-CreatorPc }
       Title = 'Smooth 4K timelines in Premiere (advice)'
       Desc  = 'The GPU renderer, preview at 1/2 resolution and proxies make heavy footage play smoothly without changing export quality. These live inside Premiere, so here is where to find them.'
       Warn  = ''
       Run   = { [void](Show-ZdDialog ("1. GPU renderer: File > Project Settings > General > Renderer: 'Mercury Playback Engine GPU Acceleration (CUDA)' on NVIDIA, '(OpenCL)' on AMD. Never 'Software only'.`n`n2. Playback resolution: Program Monitor > the drop-down at the bottom right > 1/2 (or 1/4 for 6K/8K). Export quality is not affected.`n`n3. Proxies for heavy camera files: Project panel > select clips > right-click > Proxy > Create Proxies, then turn on 'Toggle Proxies' in the Program Monitor.`n`n4. Camera footage in 10-bit 4:2:2 (many Sony, Canon, Panasonic cameras): RTX 50 graphics cards and Intel 11th-gen-or-newer integrated graphics decode it in hardware; RTX 40 and older, and AMD, decode it on the CPU, so use proxies there.") ('Premiere Pro playback') ('OK') ('Information')); 'Shown.' } }

    @{ Id = 'cr-adv-cache'; Cat = 'Creator'; Icon = [char]0xE74D; Action = 'Show how'; Requires = { Test-Path "$env:APPDATA\Adobe\Common" }
       Title = 'Keep the Adobe media cache in check (advice)'
       Desc  = 'Adobe never deletes its media cache by default, so it grows forever. Let Premiere clean files older than 90 days, and move the cache to a fast second SSD if you have one. Clean up files can empty it now.'
       Warn  = ''
       Run   = { [void](Show-ZdDialog ("In Premiere Pro: Edit > Preferences > Media Cache.`n`n- Media Cache Management: choose 'Automatically delete cache files older than 90 days' (or 'when cache exceeds' a size). Restart Premiere.`n- Media Cache Files > Browse: pick a folder on a fast SSD that is not the Windows drive, if you have one.`n`nAfter Effects: Edit > Preferences > Media & Disk Cache: Disk Cache on, on a fast SSD, 100 GB or more.`n`nTo empty the caches now, use Tools > Clean up files with the Adobe apps closed: they rebuild what they need on the next open.") ('Adobe media cache') ('OK') ('Information')); 'Shown.' } }

    @{ Id = 'cr-adv-photoshop'; Cat = 'Creator'; Icon = [char]0xE91B; Action = 'Show how'; Requires = { @(Get-CreatorExes | Where-Object { $_ -like '*Photoshop.exe' }).Count -gt 0 }
       Title = 'Photoshop performance settings (advice)'
       Desc  = 'Photoshop keeps its performance settings in a binary file that is not safe to edit from outside, so here are the values to set yourself.'
       Warn  = ''
       Run   = { [void](Show-ZdDialog ("Edit > Preferences > Performance:`n- Let Photoshop use: 70-80% of RAM.`n- History states: 20-50 (fewer uses less RAM).`n- Cache levels: 4 (5-8 for very large images, 1-2 for small images with many layers).`n- Use Graphics Processor: on; Advanced Settings: Normal.`n`nEdit > Preferences > Scratch Disks: tick a fast SSD that is not the Windows drive first.") ('Photoshop performance') ('OK') ('Information')); 'Shown.' } }

    @{ Id = 'cr-adv-driver'; Cat = 'Creator'; Icon = [char]0xE896; Action = 'Show how'; Requires = { Test-CreatorPc -and (Test-NvAvailable) }
       Title = 'Studio or Game Ready driver? (advice)'
       Desc  = 'Both come from the same code. Studio drivers are released less often and get extra testing in creative apps; no measured speed difference exists. If you mostly game, keep Game Ready.'
       Warn  = ''
       Run   = { [void](Show-ZdDialog ("Game Ready: day-one fixes for new games. Best if you mostly play.`n`nStudio: the same driver code, released less often after extra testing in Premiere, After Effects, DaVinci Resolve and others. Switch to it if an Adobe app crashes or shows GPU errors, or before a big deadline.`n`nSwitch in the NVIDIA App: Drivers > the menu next to the driver > Studio Driver. Choose a clean install. Fortnite and ZeroDelay settings are not affected.") ('NVIDIA driver type') ('OK') ('Information')); 'Shown.' } }

    @{ Id = 'cr-adv-obs'; Cat = 'Creator'; Icon = [char]0xE714; Action = 'Show how'; Requires = { Test-Path $ObsIni }
       Title = 'Record and stream without lag in OBS (advice)'
       Desc  = 'Use the graphics card''s encoder (NVENC), Game Capture instead of Display Capture, and cap your game FPS so the GPU has room for OBS.'
       Warn  = ''
       Run   = { [void](Show-ZdDialog ("Settings > Output > Video Encoder: 'NVIDIA NVENC' (H.264, HEVC or AV1). x264 uses the CPU and competes with the game.`n`nIf OBS says 'Encoding overloaded' or 'Rendering lag':`n- use preset P4 or faster and turn off multipass / Psycho Visual Tuning,`n- cap your game FPS a little below what you reach, so the GPU has room for OBS,`n- use Game Capture for games, not Display Capture,`n- in Game Capture properties, untick 'Multi-adapter Compatibility' on desktops with one graphics card,`n- run OBS as administrator (right-click > Properties > Compatibility): it can then reserve GPU time for itself.") ('OBS performance') ('OK') ('Information')); 'Shown.' } }

    # ======================================================= GTX 1080 Ti tab (1.6)
    @{ Id = 'gtx-preset'; Cat = 'Gtx1080Ti'; Icon = [char]0xE7F4; Action = 'Apply'; Gtx = $true; Extra = 'preset'; Requires = { Test-Gtx1080Ti }
       Title = 'GTX 1080 Ti competitive settings'
       Desc  = 'Everything low except textures: 11 GB of video memory handles High textures at no FPS cost. Medium view distance, no grass, no shadows, no Lumen. Use it with Performance rendering mode.'
       Warn  = 'Fortnite must be closed.'
       Preset = (New-PresetValues 100 1 2 0 0 0 $false 0)
       Run   = { Invoke-Preset $t } }

    @{ Id = 'gtx-driver'; Cat = 'Gtx1080Ti'; Icon = [char]0xE896; Action = 'Driver page'; Gtx = $true; Requires = { Test-Gtx1080Ti }
       Title = 'Stay on the 580 driver branch'
       Desc  = 'NVIDIA stopped making game drivers for GTX 10 cards in late 2025. Your card now gets security updates only, on the 580 branch (582.78 is the newest, October 2026). Drivers 590 and newer do not support it and will not install.'
       Warn  = 'Ignore the NVIDIA App if it offers a 59x or newer driver. Get updates from NVIDIA''s driver search by picking "GeForce GTX 1080 Ti".'
       Run   = { Start-Process 'https://www.nvidia.com/en-us/drivers/'; 'NVIDIA driver search opened. Pick GeForce 10 Series > GTX 1080 Ti.' } }

    @{ Id = 'gtx-undervolt'; Cat = 'Gtx1080Ti'; Icon = [char]0xE945; Action = 'Show how'; Gtx = $true; Requires = { Test-Gtx1080Ti }
       Title = 'Undervolt for steadier clocks (advice)'
       Desc  = 'A 1080 Ti lowers its clock as it heats up. Owners commonly lock it at about 1900-1950 MHz at 0.90-0.95 V in MSI Afterburner: cooler, quieter and steadier than stock. ZeroDelay never changes voltages itself.'
       Warn  = 'Every chip is different: test stability in a few matches and step the voltage up if it crashes.'
       Run   = {
           [void](Show-ZdDialog ("Undervolting a GTX 1080 Ti with MSI Afterburner:`n`n1. Open Afterburner and press Ctrl+F to open the voltage/frequency curve.`n2. Lower the whole curve by about 150 to 200 MHz (Shift+drag), then raise the point at 0.950 V to about 1900 MHz and press L to lock it there. Click Apply.`n3. Play a few matches. If the game crashes, raise the voltage one step (0.962 or 0.975 V), or lower the clock by 13 MHz.`n4. Click the save icon and enable 'Apply at startup' once it is stable.`n`nTypical owner results: about 1900-1950 MHz at 0.90-0.95 V, often 70-75 C instead of 80+ C, with clocks that no longer drop mid-match. These are user reports, not lab data.") ('Undervolting a GTX 1080 Ti') ('OK') ('Information'))
           'Undervolt guide shown.' } }

    @{ Id = 'gtx-cooling'; Cat = 'Gtx1080Ti'; Icon = [char]0xE9CA; Action = 'Show how'; Gtx = $true; Requires = { Test-Gtx1080Ti }
       Title = 'Cool down an 8-year-old card (advice)'
       Desc  = 'The thermal paste on a 2017 card is often dried out. Owners report 3-4 C better temperatures from a fresh repaste, and 15 C or more when the old paste was bad. Match reports show when your GPU slowed down from heat.'
       Warn  = 'Opening the card can void any warranty left. Thermal pads must match the original thickness.'
       Run   = {
           [void](Show-ZdDialog ("Signs the card needs attention: it reaches 83 C or more in matches, the fans run near full speed, or Match reports say the GPU slowed down because it got too hot.`n`nIn order of effort:`n1. Blow the dust out of the cooler and case fans (compressed air, hold the fans still).`n2. Set a stronger fan curve in MSI Afterburner (for example 60% at 65 C, 80% at 75 C).`n3. Undervolt (see the card next to this one).`n4. Repaste: replace the thermal paste on the GPU die, and the memory and VRM pads if they are crumbling. Use pads of the same thickness as the originals.`n`nPascal cards drop their clock about 13 MHz at a time as they warm up, and harder above about 83 C, which makes FPS less steady.") ('Cooling a GTX 1080 Ti') ('OK') ('Information'))
           'Cooling guide shown.' } }

    @{ Id = 'gtx-limits'; Cat = 'Gtx1080Ti'; Icon = [char]0xE946; Action = 'See list'; Gtx = $true; Requires = { Test-Gtx1080Ti }
       Title = 'What this card cannot do'
       Desc  = 'No DLSS, frame generation, Smooth Motion or RTX HDR (they need RTX hardware), no hardware ray tracing, no DSC for very high refresh at 4K, no HDMI VRR. ZeroDelay hides the cards for these on this PC.'
       Warn  = ''
       Run   = {
           [void](Show-ZdDialog ("Not available on a GTX 1080 Ti:`n`n- DLSS and DLSS Frame Generation: need RTX Tensor cores. Use Fortnite's 3D resolution slider instead.`n- NVIDIA Smooth Motion, RTX HDR, RTX Video, Broadcast: RTX only.`n- Hardware ray tracing and Lumen: need an RTX card; keep them off.`n- Resizable BAR: RTX 30 and newer only.`n- DSC (Display Stream Compression): the card cannot drive 4K above 120 Hz or 1440p above 240 Hz at full colour. Pick the highest refresh it offers at full RGB.`n- HDMI VRR: the card has HDMI 2.0b; use G-SYNC or G-SYNC Compatible over DisplayPort.`n- AV1 recording: the card records H.264 and HEVC (ShadowPlay works), not AV1.`n- New Game Ready drivers: only security updates on the 580 branch until October 2028.`n`nReported since spring 2026 (not confirmed by Microsoft or NVIDIA): some Windows 11 users with GTX 10 cards see glitches with Windows HDR on. If that happens, turn Windows HDR off.") ('GTX 1080 Ti limits') ('OK') ('Information'))
           'List shown.' } }

    # ======================================================= vendor software (1.5): shown only when installed
    (New-VendorTweak 'v-armoury' 'ASUS Armoury Crate services' 'Stops the Armoury Crate service stack (device detection, update bridge, system analysis, link apps). Fan curves, performance modes and keyboard lighting live in the firmware, so they keep their last setting.' 'Armoury Crate will not open or apply new profiles; Aura Sync and update checks stop. ROG laptops: the Armoury key and per-app profile switching stop. Armoury updates turn these back on.' @(
        @{ N = 'ArmouryCrateService'; D = 2 }, @{ N = 'ArmouryCrateControlInterface'; D = 2 }, @{ N = 'ROG Live Service'; D = 2 }, @{ N = 'AsusAppService'; D = 2 }, @{ N = 'ASUSOptimization'; D = 2 }, @{ N = 'ASUSSoftwareManager'; D = 2 },
        @{ N = 'ASUSSwitch'; D = 2 }, @{ N = 'ASUSSystemAnalysis'; D = 2 }, @{ N = 'ASUSSystemDiagnosis'; D = 2 }, @{ N = 'ASUSLinkNear'; D = 2 }, @{ N = 'ASUSLinkRemote'; D = 2 }, @{ N = 'AsusROGLSLService'; D = 2 }, @{ N = 'AsusCertService'; D = 2 }, @{ N = 'AsusUpdateCheck'; D = 2 }) '')
    (New-VendorTweak 'v-aura' 'ASUS Aura lighting service' 'Stops LightingService.exe, which polls motherboard, GPU and RAM RGB chips. The single most reported Armoury Crate stutter source (short 100% single-core spikes).' 'RGB freezes on its last colour or falls back to the firmware default; Aura Sync stops. Fans and performance are not affected.' @(@{ N = 'LightingService'; D = 2 }) '')
    (New-VendorTweak 'v-aisuite' 'ASUS AI Suite 3 services' 'Stops the AI Suite services that read voltages, temperatures and fan speeds through the AsIO driver, a well-known DPC-latency source on older ASUS boards.' 'AI Suite (Fan Xpert, TurboV) will not open; fan curves fall back to the BIOS Q-Fan settings.' @(@{ N = 'asComSvc'; D = 2 }, @{ N = 'asHmComSvc'; D = 2 }) '')
    (New-VendorTweak 'v-msicenter' 'MSI Center and Mystic Light services' 'Stops the MSI Center core service and the Mystic Light RGB service, which poll motherboard, GPU and RAM lighting.' 'MSI Center will not open; Mystic Light, Frozr fan control and Game Boost switching stop, and fans fall back to the BIOS curve. RGB keeps its last stored effect.' @(
        @{ N = 'MSI_Center_Service'; D = 2 }, @{ N = 'MSI_Central_Service'; D = 2 }, @{ N = 'Mystic_Light_Service'; D = 2 }, @{ N = 'MSI_VoiceControl_Service'; D = 2 }, @{ N = 'LightKeeperService'; D = 2 }) '')
    (New-VendorTweak 'v-icue' 'Corsair iCUE services' 'Stops the iCUE services that poll Corsair devices and the headset audio service. Reported by Corsair forum users as a cause of periodic 1-3 second freezes.' 'iCUE will not open; AIO and fan curves fall back to the firmware default (safe, but louder), RGB stops animating and headset EQ stops. On-board mouse DPI and keyboard macros keep working.' @(
        @{ N = 'CorsairService'; D = 2 }, @{ N = 'CorsairLLAService'; D = 2 }, @{ N = 'CorsairDeviceControlService'; D = 2 }, @{ N = 'CorsairGamingAudioConfig'; D = 2 }) '')
    (New-VendorTweak 'v-chroma' 'Razer Chroma SDK services' 'Stops the Chroma services that let games drive Razer lighting. Repeatedly reported as the Synapse part that lowers minimum FPS.' 'Game-synced Chroma lighting and Chroma Studio effects stop; static lighting set in Synapse stays.' @(
        @{ N = 'Razer Chroma SDK Service'; D = 2 }, @{ N = 'Razer Chroma SDK Server'; D = 2 }, @{ N = 'Razer Chroma Stream Server'; D = 2 }) '')
    (New-VendorTweak 'v-synapse' 'Razer Synapse core services' 'Stops the Synapse core services. Razer Game Manager is a known memory and CPU leak.' 'Synapse will not launch and cloud profiles stop syncing. On-board DPI stages, polling rate and macros keep working; devices without on-board memory lose custom bindings. Hypershift stops.' @(
        @{ N = 'Razer Synapse Service'; D = 2 }, @{ N = 'Razer Game Manager Service 3'; D = 2 }, @{ N = 'Razer Central Service'; D = 2 }, @{ N = 'RzActionSvc'; D = 2 }, @{ N = 'Razer Elevation Service'; D = 3 }) 'restart')
    (New-VendorTweak 'v-ghub' 'Logitech G HUB updater service' 'Stops the only service G HUB installs: its update checker. Lighting, macros and profiles run in a normal process and keep working.' 'G HUB stops auto-updating and may need this switched back on to start. On-board DPI and macro profiles keep working.' @(@{ N = 'LGHUBUpdaterService'; D = 2 }) '')
    (New-VendorTweak 'v-lamparray' 'Logitech Dynamic Lighting bridge' 'Stops the Logitech LampArray service that re-polls device RGB for Windows Dynamic Lighting. Traced to 3-4 second stutters when a mouse wakes.' 'Windows Dynamic Lighting control of Logitech devices stops; G HUB lighting still works.' @(@{ N = 'logi_lamparray_service'; D = 2 }) '')
    (New-VendorTweak 'v-inteldsa' 'Intel Driver & Support Assistant' 'Stops the Intel DSA background scanner that inventories hardware and checks for driver updates. Intel documents this as the way to disable it.' 'No automatic Intel driver update notifications. Intel DSA updates turn it back on.' @(@{ N = 'DSAService'; D = 2 }, @{ N = 'DSAUpdateService'; D = 3 }) '')
    (New-VendorTweak 'v-intelgcc' 'Intel Graphics Command Center service' 'Stops the background service for Intel''s graphics app (hotkeys, per-app profiles, telemetry). The display driver itself is not affected.' 'The Intel graphics app may not open and its hotkeys stop. Intel driver updates reinstall it.' @(@{ N = 'igccservice'; D = 2 }, @{ N = 'igfxCUIService2.0.0.0'; D = 2 }) '')
    (New-VendorTweak 'v-amdcrash' 'AMD Crash Defender service' 'Stops Adrenalin''s crash-detection and telemetry service, reported to fire false alarms and cause hitches on loading screens.' 'Adrenalin''s driver-timeout recovery and crash reports stop; the GPU driver keeps working. Adrenalin updates turn it back on.' @(@{ N = 'AMD Crash Defender Service'; D = 2 }) '')
    (New-VendorTweak 'v-supportassist' 'Dell SupportAssist and Data Vault' 'Stops SupportAssist and the Dell Data Vault telemetry collectors. Dell forum users traced random audio and video stutter and USB receiver drops to them.' 'No automatic driver or BIOS update notifications and no Dell hardware scans. Nothing hardware-related breaks. Dell''s own scheduled task can turn these back on.' @(
        @{ N = 'SupportAssistAgent'; D = 2 }, @{ N = 'Dell SupportAssist Remediation'; D = 2 }, @{ N = 'DDVDataCollector'; D = 2 }, @{ N = 'DDVRulesProcessor'; D = 2 }, @{ N = 'DDVCollectorSvcApi'; D = 2 }, @{ N = 'DellTechHub'; D = 2 }) '')
    (New-VendorTweak 'v-delloptimizer' 'Dell Optimizer services' 'Stops Dell Optimizer''s app-learning and telemetry service and the client management service it uses.' 'ExpressResponse learning, ExpressConnect network steering, Intelligent Audio and presence detection stop. Battery settings already applied stay in the firmware.' @(@{ N = 'DellOptimizer'; D = 2 }, @{ N = 'DellClientManagementService'; D = 2 }) '')
    (New-VendorTweak 'v-delldd' 'Dell Digital Delivery' 'Stops the service that downloads software bundled with the PC purchase.' 'Re-delivery of purchased software stops; nothing else.' @(@{ N = 'DellDigitalDelivery'; D = 2 }) '')
    (New-VendorTweak 'v-awcc' 'Alienware Command Center service' 'Stops the AlienFX lighting, thermal-profile and overclock backend.' 'AWCC will not open; lighting freezes on the last profile; fan profiles fall back to the firmware default and the Fn+F1 performance key stops on laptops. Keep it on if your Alienware laptop relies on AWCC thermal modes.' @(@{ N = 'AWCCService'; D = 2 }) '')
    (New-VendorTweak 'v-waves' 'Waves MaxxAudio service' 'Stops the Waves audio-effects service bundled with Dell, Alienware and some HP Realtek audio, repeatedly reported at a constant 25% CPU.' 'MaxxAudio EQ and dialog enhancement stop; plain Realtek audio keeps working. Dell audio driver updates reinstall it.' @(@{ N = 'WavesSysSvc'; D = 2 }) '')
    (New-VendorTweak 'v-hpanalytics' 'HP Analytics (Touchpoint)' 'Stops the HP telemetry service.' 'HP telemetry only; nothing breaks. HP Support Assistant updates can turn it back on.' @(@{ N = 'HpTouchpointAnalyticsService'; D = 2 }) '')
    (New-VendorTweak 'v-hphsa' 'HP Support Assistant helper services' 'Stops the HP helper services (App Helper, Diagnostics, Network, System Info) used for scans; HP App Helper is reported for high idle CPU.' 'HP Support Assistant diagnostics and update checks stop; no hardware feature is affected.' @(
        @{ N = 'HPAppHelperCap'; D = 2 }, @{ N = 'HPDiagsCap'; D = 2 }, @{ N = 'HPNetworkCap'; D = 2 }, @{ N = 'HPSysInfoCap'; D = 2 }, @{ N = 'HPSupportSolutionsFrameworkService'; D = 3 }) '')
    (New-VendorTweak 'v-omen' 'Omen Gaming Hub background service' 'Stops the HP Omen service used for fan, performance mode, lighting and the in-game overlay.' 'Omen Gaming Hub shows offline; performance mode, fan control, the Omen key and lighting stop responding (the firmware keeps the last mode).' @(@{ N = 'HPOmenCap'; D = 2 }) '')
    (New-VendorTweak 'v-vantage' 'Lenovo Vantage services' 'Stops Lenovo Vantage and the System Interface Foundation it uses, both reported for high CPU and for respawning after updates.' 'Vantage and Legion features from the app stop: performance-mode switching, battery toggles, Legion lighting and hotkey OSD. Fn+Q firmware mode switching still works. Lenovo System Update turns these back on.' @(@{ N = 'LenovoVantageService'; D = 2 }, @{ N = 'ImControllerService'; D = 2 }) 'restart')
    (New-VendorTweak 'v-acercare' 'Acer Care Center service' 'Stops the Acer Care Center backend (checkups, update checks, telemetry).' 'Acer Care Center and its update notifications stop. PredatorSense is separate and not touched.' @(@{ N = 'ACCSvc'; D = 2 }) '')
    (New-VendorTweak 'v-adobe' 'Adobe background services' 'Stops Adobe Genuine Software, the Creative Cloud update service and the Acrobat updater, all reported for sustained CPU use at idle.' 'Creative Cloud and Acrobat stop auto-updating; a one-time "genuine software" notice may appear. The apps still launch and work.' @(
        @{ N = 'AGSService'; D = 2 }, @{ N = 'AGMService'; D = 2 }, @{ N = 'AdobeUpdateService'; D = 2 }, @{ N = 'AdobeARMservice'; D = 2 }) '')
    (New-VendorTweak 'v-overwolf' 'Overwolf updater service' 'Stops the updater used by Overwolf, Outplayed and CurseForge. The in-game overlay is a separate process (see Game Mode).' 'Overwolf apps stop auto-updating; they re-register the service on their next update.' @(@{ N = 'OverwolfUpdater'; D = 3 }) '')

    # ======================================================= browsers and Steam (1.5): shown only when installed
    @{ Id = 'chrome-bg'; Cat = 'Background'; Icon = [char]0xE774; Rec = $true
       Title = 'Stop Chrome running in the background'
       Desc  = 'Chrome no longer stays alive (tray icon, background extensions) after you close its last window, so it uses no CPU or RAM while you play.'
       Warn  = 'If Chrome is in the tray right now, close it from there once. Chrome will show "managed by your organization".'
       Requires = { Test-AppInstalled 'chrome.exe' @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; N = 'BackgroundModeEnabled'; V = 0; D = $null; M = 1 } ) }
    @{ Id = 'brave-bg'; Cat = 'Background'; Icon = [char]0xE774; Rec = $true
       Title = 'Stop Brave running in the background'
       Desc  = 'Brave quits fully when its last window closes instead of idling in the tray.'
       Warn  = 'Brave will show "managed by your organization".'
       Requires = { Test-AppInstalled 'brave.exe' @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe") }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N = 'BackgroundModeEnabled'; V = 0; D = $null; M = 1 } ) }
    @{ Id = 'chrome-sw'; Cat = 'Background'; Icon = [char]0xE774; Rec = $false
       Title = 'Chrome: no GPU use while open'
       Desc  = 'Chrome renders on the CPU, so a browser left open on a second screen (YouTube, Twitch) stops competing with Fortnite for the graphics card.'
       Warn  = 'Only useful if Chrome stays open while you play. Video uses more CPU. Takes effect after Chrome restarts.'
       Requires = { Test-AppInstalled 'chrome.exe' @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; N = 'HardwareAccelerationModeEnabled'; V = 0; D = $null; M = 1 } ) }
    @{ Id = 'brave-sw'; Cat = 'Background'; Icon = [char]0xE774; Rec = $false
       Title = 'Brave: no GPU use while open'
       Desc  = 'Brave renders on the CPU, so it cannot take frame time from the game while open on another screen.'
       Warn  = 'Only useful if Brave stays open while you play. Video uses more CPU. Takes effect after Brave restarts.'
       Requires = { Test-AppInstalled 'brave.exe' @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe") }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N = 'HardwareAccelerationModeEnabled'; V = 0; D = $null; M = 1 } ) }
    @{ Id = 'edge-sw'; Cat = 'Background'; Icon = [char]0xE774; Rec = $false
       Title = 'Edge: no GPU use while open'
       Desc  = 'Edge renders on the CPU, so it cannot take frame time from the game while open on another screen.'
       Warn  = 'Only useful if Edge stays open while you play. Video uses more CPU. Takes effect after Edge restarts.'
       Requires = { Test-AppInstalled 'msedge.exe' }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'HardwareAccelerationModeEnabled'; V = 0; D = $null; M = 1 } ) }
    @{ Id = 'firefox-sw'; Cat = 'Background'; Icon = [char]0xE774; Rec = $false
       Title = 'Firefox: no GPU use while open'
       Desc  = 'Firefox renders on the CPU, so it cannot take frame time from the game while open on another screen.'
       Warn  = 'Only useful if Firefox stays open while you play. Video uses more CPU. Takes effect after Firefox restarts; the switch is greyed out in Firefox while this is on.'
       Requires = { Test-AppInstalled 'firefox.exe' @("$env:ProgramFiles\Mozilla Firefox\firefox.exe") }
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'; N = 'HardwareAcceleration'; V = 0; D = $null; M = 1 } ) }
    @{ Id = 'operagx-sw'; Cat = 'Background'; Icon = [char]0xE774; Rec = $false
       Title = 'Opera GX: no GPU use while open'
       Desc  = 'Opera GX renders on the CPU, so it cannot take frame time from the game while open on another screen. Opera has no policy support, so its settings file is edited directly.'
       Warn  = 'Only useful if Opera GX stays open while you play. Video uses more CPU. Opera GX must be closed first.'
       Requires = { Test-Path $OperaLocalState }
       Test  = { $v = Get-OperaHwAccel; if ($null -eq $v) { return $null }; $v -eq $false }
       On    = { if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = "$(Get-OperaHwAccel)" } }; Set-OperaHwAccel $false }
       Off   = { $v = "$($script:Backup.Custom[$t.Id].Value)"; Set-OperaHwAccel $(if ($v -eq 'True') { $true } elseif ($v -eq 'False') { $false } else { 'absent' }); $script:Backup.Custom.Remove($t.Id) } }
    @{ Id = 'steam-webviews'; Cat = 'Background'; Icon = [char]0xE7FC; Rec = $false
       Title = 'Steam: no GPU use for its windows'
       Desc  = 'Steam''s store, library and friends windows render on the CPU, so Steam idling in the background takes no GPU time from Fortnite. Same as Steam Settings > Interface > GPU accelerated rendering: off.'
       Warn  = 'Steam''s windows feel less smooth. Restart Steam afterwards.'
       Requires = { [bool](Get-SteamConfig) }
       Reg   = @( @{ P = 'HKCU:\Software\Valve\Steam'; N = 'GPUAccelWebViews'; V = 0; D = 1; M = 1 } ) }
    @{ Id = 'steam-updatewindow'; Cat = 'Network'; Icon = [char]0xE7FC; Rec = $true; Lat = $true
       Title = 'Steam: only update games at night'
       Desc  = 'Steam cannot see that Fortnite is running, so it will start big game updates mid-match. This limits automatic updates to 3 to 6 in the morning. Downloads you start yourself still run at once.'
       Warn  = 'Your PC is off at night and you want Steam games to update on their own. Close Steam before switching.'
       Requires = { [bool](Get-SteamConfig) }
       Test  = { $f = Get-SteamConfig; if (-not $f) { return $null }; $l = [IO.File]::ReadAllLines($f); $v = Get-VdfValue $l 'AutoUpdateWindowEnabled'; if ($null -eq $v) { return $null }; $v -eq '1' }
       On    = {
           $l = [IO.File]::ReadAllLines((Get-SteamConfig))
           if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Enabled = (Get-VdfValue $l 'AutoUpdateWindowEnabled'); Start = (Get-VdfValue $l 'AutoUpdateWindowStart'); End = (Get-VdfValue $l 'AutoUpdateWindowEnd') } }
           Set-SteamAutoUpdateWindow $true 3 6 }
       Off   = {
           $b = $script:Backup.Custom[$t.Id]
           if ($b -and $b.Enabled -eq '1') { Set-SteamAutoUpdateWindow $true $b.Start $b.End } else { Set-SteamAutoUpdateWindow $false 0 0 }
           $script:Backup.Custom.Remove($t.Id) } }

    # ======================================================= Desktop visuals
    @{ Id = 'menudelay'; Cat = 'Visuals'; Icon = [char]0xE700; Rec = $false
       Title = 'Instant menus'
       Desc  = 'Menus open with no 400 ms hover delay. Desktop snappiness only, no in-game effect.'
       Warn  = 'Menus popping open as you move the mouse annoys you.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Desktop'; N = 'MenuShowDelay'; V = '0'; T = 'String'; D = '400'; M = '400' } )
       After = { [void][NativeInput]::SystemParametersInfo(0x006B, [uint32](Get-ItemProperty 'HKCU:\Control Panel\Desktop').MenuShowDelay, [IntPtr]::Zero, 0x02) } }

    @{ Id = 'minanimate'; Cat = 'Visuals'; Icon = [char]0xE740; Rec = $false; Badge = 'signout'
       Title = 'Turn off window animations'
       Desc  = 'Windows minimise and maximise instantly. Makes alt-tabbing back into games feel quicker.'
       Warn  = 'You like the animations.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Desktop\WindowMetrics'; N = 'MinAnimate'; V = '0'; T = 'String'; D = '1'; M = '1' } ) }

    @{ Id = 'taskbaranim'; Cat = 'Visuals'; Icon = [char]0xE7C4; Rec = $false; Badge = 'signout'
       Title = 'Turn off taskbar animations'
       Desc  = 'Removes taskbar button animations. Desktop snappiness only.'
       Warn  = 'You like the animations.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarAnimations'; V = 0; D = 1; M = 1 } ) }

    @{ Id = 'peek'; Cat = 'Visuals'; Icon = [char]0xE7B3; Rec = $false; Badge = 'signout'
       Title = 'Turn off Aero Peek'
       Desc  = 'Stops the desktop preview when you hover the corner of the taskbar.'
       Warn  = 'You use Peek to glance at the desktop.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\DWM'; N = 'EnablePeek'; V = 0; D = 1; M = 1 } ) }

    # ========================================================== Startup apps
    @{ Id = 'startupdelay'; Cat = 'Startup'; Icon = [char]0xE768; Rec = $true
       Title = 'Remove startup app delay'
       Desc  = 'Windows deliberately waits about 10 s before starting startup apps. Removes that wait.'
       Warn  = 'You have many startup apps and a hard drive. Starting them all at once can slow sign-in.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; N = 'StartupDelayInMSec'; V = 0; D = $null; M = -1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; N = 'WaitForIdleState'; V = 0; D = $null; M = -1 }
       ) }

    # ============================================================== Fortnite
    @{ Id = 'grass'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $true
       Title = 'Hide grass'
       Desc  = 'Grass costs GPU time and can hide players lying in it.'
       Warn  = 'You want the full look of the map. Fortnite must be closed.'
       Ini   = @{ bShowGrass = @('False', 'True') } }

    @{ Id = 'antialias'; Cat = 'Fortnite'; Icon = [char]0xE7F4; Rec = $false
       Title = 'Turn off anti-aliasing'
       Desc  = 'Temporal anti-aliasing costs GPU time and smears fast motion. Sharper but jaggier.'
       Warn  = 'Jagged edges bother you more than a few FPS. Fortnite must be closed.'
       Ini   = @{ 'sg.AntiAliasingQuality' = @('0', '3', 'ScalabilityGroups') } }

    @{ Id = 'gpucrashdbg'; Cat = 'Fortnite'; Icon = [char]0xE7BA; Rec = $true
       Title = 'GPU crash debugging off'
       Desc  = 'If left on after a crash it adds heavy GPU overhead every frame. This makes sure it is off.'
       Warn  = 'Epic support asked you to turn it on to diagnose crashes. Fortnite must be closed.'
       Ini   = @{ bUseGPUCrashDebugging = @('False', 'False') } }

    @{ Id = 'fnhdr'; Cat = 'Fortnite'; Icon = [char]0xE790; Rec = $false
       Title = 'Turn off Fortnite HDR'
       Desc  = 'HDR output adds a little GPU work and can raise display latency on some monitors.'
       Warn  = 'You have a good HDR monitor and like how it looks. Fortnite must be closed.'
       Ini   = @{ bUseHDRDisplayOutput = @('False', 'True') } }

    @{ Id = 'ioprio'; Cat = 'Fortnite'; Icon = [char]0xEDA2; Rec = $false; Badge = 'advanced'
       Title = 'High disk priority for Fortnite'
       Desc  = 'Fortnite''s file reads go ahead of background disk activity when streaming textures.'
       Warn  = 'You record gameplay to the same drive. Recordings may stutter.'
       Reg   = @( @{ P = $Ifeo; N = 'IoPriority'; V = 3; D = $null; M = $null } ) }

    @{ Id = 'lowprio'; Cat = 'Fortnite'; Icon = [char]0xE9D9; Rec = $true
       Title = 'Lower priority for background apps'
       Desc  = 'Epic Launcher, OneDrive, Teams and the telemetry runner start at Below Normal priority so they never compete with the game.'
       Warn  = 'You notice these apps feel slower while you game.'
       Reg   = @(
           foreach ($exe in 'EpicGamesLauncher.exe', 'EpicWebHelper.exe', 'OneDrive.exe', 'ms-teams.exe', 'CompatTelRunner.exe') {
               @{ P = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions"; N = 'CpuPriorityClass'; V = 5; D = $null; M = $null }
           }
       ) }

    @{ Id = 'fnfso'; Cat = 'Fortnite'; Icon = [char]0xE740; Rec = $false; Badge = 'advanced'
       Title = 'Disable fullscreen optimizations'
       Desc  = 'Forces legacy exclusive fullscreen for Fortnite only. Some PCs get lower latency, others none.'
       Warn  = 'Alt-tab becomes slow, or you see no difference. Test with and without.'
       Test  = { if (-not $script:FortniteExe) { return $null }; "$(Get-RegValue $LayersKey $script:FortniteExe)" -match 'DISABLEDXMAXIMIZEDWINDOWEDMODE' }
       On    = {
           $cur = Get-RegValue $LayersKey $script:FortniteExe
           $new = if ($cur) { "$cur DISABLEDXMAXIMIZEDWINDOWEDMODE" } else { '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' }
           Set-RegTracked 'fnfso' $LayersKey $script:FortniteExe $new 'String'
       }
       Off   = {
           if (-not (Restore-RegTweak 'fnfso')) {
               $cur = "$(Get-RegValue $LayersKey $script:FortniteExe)" -replace '\s*DISABLEDXMAXIMIZEDWINDOWEDMODE', ''
               if ($cur.Trim() -in '', '~') { Remove-RegValue $LayersKey $script:FortniteExe } else { Set-RegValue $LayersKey $script:FortniteExe $cur 'String' }
           }
       } }
)

# --- NVIDIA driver profile DWORD settings: Nv = @{ Profile; Id; V }. Originals are backed up and restored.
function Test-NvTweak($t) { if (-not (Test-NvAvailable)) { return $null }; $v = [NvDrs]::Get($t.Nv.Profile, [uint32]$t.Nv.Id); if ($v -lt -1) { return $null }; $v -eq [int64][uint32]$t.Nv.V }
function Enable-NvTweak($t) {
    if (-not (Test-NvAvailable)) { throw 'Needs an NVIDIA graphics card.' }
    if (-not $script:Backup.Custom.ContainsKey($t.Id)) { $script:Backup.Custom[$t.Id] = @{ Value = (Get-NvBackupValue $t.Nv.Profile ([uint32]$t.Nv.Id)) } }
    $r = [NvDrs]::Set($t.Nv.Profile, [uint32]$t.Nv.Id, [uint32]$t.Nv.V)
    if ($r -ne 0) { throw "The NVIDIA driver refused the change (code $r)." }
}
function Disable-NvTweak($t) {
    $b = $script:Backup.Custom[$t.Id]
    if ($b -and $null -ne $b.Value) { [void][NvDrs]::Set($t.Nv.Profile, [uint32]$t.Nv.Id, [uint32]$b.Value) } else { [void][NvDrs]::Delete($t.Nv.Profile, [uint32]$t.Nv.Id) }
    $script:Backup.Custom.Remove($t.Id)
}

function Invoke-TweakTest($t) {
    try {
        if ($t.Svc -and -not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($t.Svc)")) { return $null }
        if ($t.Requires -and -not (& $t.Requires)) { return $null }
        if ($t.Test) { $r = & $t.Test } elseif ($t.Reg) { $r = Test-RegTweak $t } elseif ($t.Ini) { $r = Test-IniTweak $t }
        elseif ($t.Power) { $r = Test-PowerTweak $t } elseif ($t.Dx) { $r = Test-DxTweak $t } elseif ($t.Tasks) { $r = Test-TaskTweak $t }
        elseif ($t.Remove) { $r = Test-RemoveTweak $t } elseif ($t.Nv) { $r = Test-NvTweak $t } else { return $null }
        if ($null -eq $r) { return $null }
        [bool]$r
    } catch { $null }
}
# --- Change history (newest first) and the set of cards ZeroDelay switched on, used by drift alerts and profiles.
$HistoryFile = Join-Path $DataDir 'history.json'
# Windows PowerShell's ConvertFrom-Json hands back a JSON array as one object, and @() around it does not unpack
# it, so older versions saved lists nested as {"value": [...], "Count": n}. This reads the items and undoes that.
function Read-JsonList([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    try { $raw = Get-Content $Path -Raw | ConvertFrom-Json } catch { return @() }
    @(Expand-JsonList $raw)
}
function Expand-JsonList($x) {
    foreach ($i in @($x | ForEach-Object { $_ })) {
        if ($null -eq $i) { continue }
        if ($i -is [string]) {
            # a history entry that an older version flattened to text
            if ($i -match '^@\{Time=(.*?); Title=(.*?); Action=(.*?); Id=(.*?)\}$') { [pscustomobject]@{ Time = $Matches[1]; Title = $Matches[2]; Action = $Matches[3]; Id = $Matches[4] } }
            continue
        }
        $names = @($i.PSObject.Properties.Name)
        if ($names -contains 'value' -and $names -contains 'Count' -and $names.Count -eq 2) { Expand-JsonList $i.value; continue }
        $i
    }
}
function Get-History {
    if ($null -eq $script:History) {
        $script:History = @()
        $script:History = @(Read-JsonList $HistoryFile)
    }
    $script:History
}
function Add-History([string]$Title, [string]$Action, [string]$Id) {
    $entry = [pscustomobject]@{ Time = (Get-Date).ToString('o'); Title = $Title; Action = $Action; Id = $Id }
    $script:History = @($entry) + @(Get-History | Select-Object -First 299)
    if (-not $Snapshot) { try { ConvertTo-Json -InputObject @($script:History) -Depth 3 | Set-Content $HistoryFile -Encoding UTF8 } catch {} }
}
function Get-Applied { @($script:Backup.Custom['applied'] | Where-Object { $_ }) }
function Set-Applied([string]$Id, [bool]$On) {
    $list = @(Get-Applied | Where-Object { $_ -ne $Id })
    if ($On) { $list += $Id }
    $script:Backup.Custom['applied'] = $list
}

function Invoke-TweakOn($t) {
    if ($t.Id -eq 'sticky') { try { [void][AccessKeys]::Write(506, 122, 58) } catch {} }
    if ($t.On) { & $t.On } elseif ($t.Reg) { Enable-RegTweak $t } elseif ($t.Ini) { Enable-IniTweak $t }
    elseif ($t.Power) { Enable-PowerTweak $t } elseif ($t.Dx) { Enable-DxTweak $t } elseif ($t.Tasks) { Enable-TaskTweak $t } elseif ($t.Remove) { Enable-RemoveTweak $t } elseif ($t.Nv) { Enable-NvTweak $t }
    if ($t.After) { & $t.After }
    Set-Applied $t.Id $true
    Save-Backup
    Add-PendingRestart $t
    Add-History $t.Title 'on' $t.Id
    Clear-ReadCache
}
function Invoke-TweakOff($t) {
    if ($t.Id -eq 'sticky') { try { [void][AccessKeys]::Write(510, 126, 62) } catch {} }
    if ($t.Off) { & $t.Off } elseif ($t.Reg) { Disable-RegTweak $t } elseif ($t.Ini) { Disable-IniTweak $t }
    elseif ($t.Power) { Disable-PowerTweak $t } elseif ($t.Dx) { Disable-DxTweak $t } elseif ($t.Tasks) { Disable-TaskTweak $t } elseif ($t.Remove) { Disable-RemoveTweak $t } elseif ($t.Nv) { Disable-NvTweak $t }
    if ($t.After) { & $t.After }
    Set-Applied $t.Id $false
    Save-Backup
    Add-PendingRestart $t
    Add-History $t.Title 'off' $t.Id
    Clear-ReadCache
}

# --- Pending restart / sign-out, remembered until the PC actually restarts (keyed on boot time).
$PendingFile = Join-Path $DataDir 'pending-restart.json'
$script:BootId = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime)"
$script:Pending = @{ Kind = $null; Items = @() }
$script:RestartSnoozed = $false
$script:PendingAdded = @{}
$script:VerifyAfterBoot = @()
if (Test-Path $PendingFile) {
    try {
        $p = Get-Content $PendingFile -Raw | ConvertFrom-Json
        if ($p.Boot -eq $script:BootId) {
            $script:Pending = @{ Kind = $p.Kind; Items = @($p.Items) }
            if ($p.Added) { foreach ($q in $p.Added.PSObject.Properties) { $script:PendingAdded[$q.Name] = "$($q.Value)" } }
            else { $mt = (Get-Item $PendingFile).LastWriteTime.ToString('o'); foreach ($i in @($p.Items)) { $script:PendingAdded[$i] = $mt } }
        } elseif (-not $Snapshot) {
            # Windows restarted since: check those changes really took effect once the cards are read
            $script:VerifyAfterBoot = @($p.Items)
            Remove-Item $PendingFile -Force
        }
    } catch {}
}
function Save-PendingRestart {
    if ($Snapshot) { return }
    if (-not @($script:Pending.Items).Count) { Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue; return }
    @{ Kind = $script:Pending.Kind; Items = $script:Pending.Items; Boot = $script:BootId; Added = $script:PendingAdded } | ConvertTo-Json | Set-Content $PendingFile -Encoding UTF8
}
function Add-PendingRestart($t) {
    if ($t.Badge -notin 'restart', 'signout') { return }
    if ($t.Live) { try { if (& $t.Live) { return } } catch {} }    # already working: nothing to wait for
    if ($script:Pending.Items -notcontains $t.Title) { $script:Pending.Items += $t.Title }
    $script:PendingAdded[$t.Title] = (Get-Date).ToString('o')
    if ($t.Badge -eq 'restart' -or -not $script:Pending.Kind) { $script:Pending.Kind = $t.Badge }
    $script:RestartSnoozed = $false
    Save-PendingRestart
}
# Drops changes from the banner that Windows already uses (where that can be checked), and says what a restart is.
function Update-PendingLive {
    $keep = @(foreach ($title in @($script:Pending.Items)) {
        $t = $Tweaks | Where-Object { $_.Title -eq $title } | Select-Object -First 1
        if (-not $t -and $title -eq $GsyncPendingTitle) { $t = @{ Title = $title; Live = { Test-MainVrrOn }; State = $true } }
        $live = $false
        if ($t -and $t.Live) { try { $live = [bool](& $t.Live) } catch {} }
        if ($t -and $t.State -eq $false) { $live = $true }    # switched off again: nothing pending
        if (-not $live) { $title }
    })
    if ($keep.Count -ne @($script:Pending.Items).Count) {
        $script:Pending.Items = $keep
        if (-not $keep.Count) { $script:Pending.Kind = $null }
        elseif (-not ($keep | Where-Object { $tt = $_; ($Tweaks | Where-Object { $_.Title -eq $tt -and $_.Badge -eq 'restart' }) })) { $script:Pending.Kind = 'signout' }
        Save-PendingRestart
    }
}
# After a real Windows restart: anything Windows can confirm and that is still not working gets reported.
function Test-AfterBoot {
    if (-not @($script:VerifyAfterBoot).Count) { return }
    $bad = @(foreach ($title in $script:VerifyAfterBoot) {
        $t = $Tweaks | Where-Object { $_.Title -eq $title } | Select-Object -First 1
        if (-not $t -and $title -eq $GsyncPendingTitle) { $t = @{ Title = $title; Live = { Test-MainVrrOn }; State = $true } }
        if ($t -and $t.Live -and $t.State -eq $true) { try { if (-not (& $t.Live)) { $title } } catch {} }
    })
    $n = @($script:VerifyAfterBoot).Count
    $script:VerifyAfterBoot = @()
    if ($bad.Count) { Show-Toast "After the restart, Windows is still not using: $($bad -join ', '). Switch it off and on again, or use Report a problem." '#FF9F0A' }
    else { Show-Toast "Restart done: $n change$(if ($n -ne 1) { 's are' } else { ' is' }) now in effect." '#30D158' }
}

$Tweaks += @(Get-StartupTweaks)
$Tweaks += @(Get-DeviceTweaks)

# Tweaks that directly affect input delay, frame time or ping. They appear in the "Latency & delay" tab
# as well as their own category. A card can also opt in with Lat = $true.
$LatencyIds = @(
    'reflex', 'vsync', 'fullscreen', 'fpscap', 'fnmouse', 'motionblur', 'dynres', 'nanite', 'compgfx', 'perfmode',
    'gpucrashdbg', 'cpuprio', 'gpupref', 'fnfso', 'ioprio', 'lowprio',
    'power', 'throttle', 'usbsuspend', 'pcie', 'minstate', 'epp', 'boostmode', 'coreparking', 'usb3lpm', 'usbhub',
    'prioSep', 'mmcss', 'timer', 'hvci', 'gamemode', 'mouse',
    'hags', 'windowed', 'refreshrate', 'dvr', 'autohdr',
    'nicpower', 'eee', 'intmod', 'netthrottle', 'wifipower', 'rss', 'coalescing', 'flowcontrol', 'greeneth',
    'advancedeee', 'rtkpower', 'roaming', 'mimo', 'qos', 'deliveryopt', 'ping'
)
foreach ($t in $Tweaks) { if ($LatencyIds -contains $t.Id) { $t.Lat = $true } }

# Lowest-quality Fortnite graphics, shown together in the "Potato graphics" tab.
$PotatoIds = @('shadercache', 'nvlod-soft', 'nvlod-smudge', 'nvlod-flat', 'perfmode', 'meshquality', 'res3d', 'texturelow', 'compgfx', 'shadinglow', 'landscapelow', 'viewnear',
               'grass', 'antialias', 'motionblur', 'nanite', 'fnhdr', 'dynres')
foreach ($t in $Tweaks) { if ($PotatoIds -contains $t.Id) { $t.Potato = $true } }

# Cards shown on the GTX 1080 Ti tab (alongside the ones made for it)
$Gtx1080Ids = @('perfmode', 'meshquality', 'nanite', 'reflex', 'vsync', 'fullscreen', 'fpscap', 'vrrcap', 'motionblur', 'grass', 'nvpower', 'hags', 'gpu-msi', 'shadercache')
foreach ($t in $Tweaks) { if ($Gtx1080Ids -contains $t.Id) { $t.Gtx = $true } }

# ==================================================================== UI ===

$script:Backup = Load-Backup
$script:FortniteExe = Find-FortniteExe

# --- Appearance. Dark is the design palette; light mode maps each dark colour to its light partner.
#     Accent = [text/icon colour, button fill (white text on it), soft tint behind icons].
$Accents = [ordered]@{
    blue     = @{ Name = 'Blue';     Dark = '0A84FF', '0071E3', '273A4F'; Light = '0071E3', '0071E3', 'DCEBFB' }
    indigo   = @{ Name = 'Indigo';   Dark = '7D7AFF', '5856D6', '2E2D52'; Light = '5856D6', '5856D6', 'E6E5FB' }
    purple   = @{ Name = 'Purple';   Dark = 'BF5AF2', '9A3FD0', '3F2A4F'; Light = '9A3FD0', '9A3FD0', 'F1E4FA' }
    pink     = @{ Name = 'Pink';     Dark = 'FF5C7A', 'D6204A', '4F2630'; Light = 'D6204A', 'D6204A', 'FBE1E7' }
    teal     = @{ Name = 'Teal';     Dark = '40C8E0', '0B7F93', '1F4048'; Light = '0B7F93', '0B7F93', 'D9F1F5' }
    graphite = @{ Name = 'Graphite'; Dark = 'AEAEB2', '636366', '3A3A3C'; Light = '6E6E73', '636366', 'E5E5EA' }
}
$LightMap = @{
    '1C1C1E' = 'F2F2F7'; '262628' = 'EBEBF0'; '2C2C2E' = 'FFFFFF'; '3A3A3C' = 'E8E8ED'; '48484A' = 'D2D2D7'; '38383A' = 'E0E0E5'
    'F5F5F7' = '1D1D1F'; 'A1A1A6' = '6E6E73'; '98989D' = '86868B'; '8E8E93' = '86868B'; 'D1D1D6' = '3A3A3C'; 'E5E5EA' = '2C2C2E'
    '5A5A5E' = 'B0B0B5'; '6E6E73' = 'A1A1A6'; '4D4D50' = 'C4C4C9'; '636366' = 'C7C7CC'; '4A4A4D' = 'C7C7CC'; '444446' = 'DADADF'
    '3D3D41' = 'DCDCE1'; '38383B' = 'D8D8DD'; '303033' = 'EDEDF2'; '2C2C2F' = 'FFFFFF'; '3A3A3D' = 'FFFFFF'; '48484B' = 'D2D2D7'
    '30D158' = '1FA34A'; 'FF9F0A' = 'D97706'; 'FF453A' = 'DC2626'; 'FFD60A' = 'B58900'
    '2D4635' = 'D7F2DF'; '22382A' = 'E6F6EA'; '2F5A3D' = 'B9E3C6'; '4E3E28' = 'FCEBD2'
}
function Get-SystemTheme {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme
    if ($v -eq 1) { 'light' } else { 'dark' }
}
$script:ThemeMode = if ($env:ZD_THEME) { $env:ZD_THEME } elseif ($script:Backup.Custom['theme']) { "$($script:Backup.Custom['theme'])" } else { 'dark' }
$script:Theme = switch ($script:ThemeMode) { 'light' { 'light' } 'system' { Get-SystemTheme } default { 'dark' } }
$script:Accent = if ($env:ZD_ACCENT) { $env:ZD_ACCENT } elseif ($script:Backup.Custom['accent']) { "$($script:Backup.Custom['accent'])" } else { 'blue' }
if (-not $Accents.Contains($script:Accent)) { $script:Accent = 'blue' }
[ZdTheme]::Map.Clear()
if ($script:Theme -eq 'light') { foreach ($k in $LightMap.Keys) { [ZdTheme]::Map[$k] = $LightMap[$k] } }
else {
    # Dark is true black: black window, near-black panels, very dark greys for controls
    $DarkMap = @{ '1C1C1E' = '000000'; '262628' = '0A0A0B'; '2C2C2E' = '131314'; '3A3A3C' = '1F1F21'; '48484A' = '2C2C2F'; '38383A' = '1E1E20'
                  '303033' = '18181A'; '38383B' = '121214'; '3D3D41' = '242427'; '444446' = '28282B'; '4D4D50' = '3A3A3D'; '4A4A4D' = '303033'
                  '2C2C2F' = '0F0F10'; '3A3A3D' = '1A1A1C'; '48484B' = '2A2A2D'; '5A5A5E' = '3A3A3E'; '6E6E73' = '4A4A4E' }
    foreach ($k in $DarkMap.Keys) { [ZdTheme]::Map[$k] = $DarkMap[$k] }
}
$acc = if ($script:Theme -eq 'light') { $Accents[$script:Accent].Light } else { $Accents[$script:Accent].Dark }
[ZdTheme]::Map['0A84FF'] = $acc[0]; [ZdTheme]::Map['0071E3'] = $acc[1]; [ZdTheme]::Map['273A4F'] = $acc[2]

# --- Glass: the window shows Windows 11's frosted (acrylic) backdrop and every panel becomes translucent glass with a light
#     top edge. Windows 10 and older Windows 11 builds keep the solid look.
$glassPref = if ($env:ZD_GLASS) { $env:ZD_GLASS -ne '0' } elseif ($script:Backup.Custom.ContainsKey('glass')) { [bool]$script:Backup.Custom['glass'] } else { $true }
$script:GlassSetting = [bool]$glassPref
$script:Glass = $script:GlassSetting -and [Environment]::OSVersion.Version.Build -ge 22621 -and -not [Windows.SystemParameters]::HighContrast
if ($script:Glass) {
    $glassMap = if ($script:Theme -eq 'light') {
        @{ '262628' = '4DFFFFFF'; '2C2C2E' = 'B8FFFFFF'; '1C1C1E' = '66FFFFFF'; '3A3A3C' = '14000000'; '48484A' = '22000000'; '38383A' = '1A000000'
           '303033' = '0A000000'; '38383B' = '12000000'; '3D3D41' = '14000000'; '444446' = '18000000'; '4D4D50' = '33000000'; '4A4A4D' = '26000000' }
    } else {
        @{ '262628' = '66000000'; '2C2C2E' = '12FFFFFF'; '1C1C1E' = '73000000'; '3A3A3C' = '1AFFFFFF'; '48484A' = '29FFFFFF'; '38383A' = '17FFFFFF'
           '303033' = '12FFFFFF'; '38383B' = '0DFFFFFF'; '3D3D41' = '24FFFFFF'; '444446' = '26FFFFFF'; '4D4D50' = '40FFFFFF'; '4A4A4D' = '33FFFFFF' }
    }
    foreach ($k in $glassMap.Keys) { [ZdTheme]::Map[$k] = $glassMap[$k] }
    # cards built from text get the gradient glass fill and the light top edge
    foreach ($q in "'", '"') {
        [ZdTheme]::Literal.Add((New-Object 'Collections.Generic.KeyValuePair[string,string]' "Background=$($q)#2C2C2E$q", "Background=$($q){DynamicResource GlassFill}$q"))
        [ZdTheme]::Literal.Add((New-Object 'Collections.Generic.KeyValuePair[string,string]' "BorderBrush=$($q)#38383A$q", "BorderBrush=$($q){DynamicResource GlassEdge}$q"))
    }
}

[xml]$xaml = [ZdTheme]::Apply(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZeroDelay - Fortnite latency optimizer" Width="1380" Height="880" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#1C1C1E" FontFamily="Inter, Segoe UI Variable Text, Segoe UI" Foreground="#F5F5F7" UseLayoutRounding="True">
  <Window.Resources>
    <!-- ZeroDelay / macOS dark graphite. One job per colour: blue = act, green = on/good, orange = warn, red = problem. -->
    <SolidColorBrush x:Key="BgWindow" Color="#1C1C1E"/>
    <SolidColorBrush x:Key="BgSidebar" Color="#262628"/>
    <SolidColorBrush x:Key="BgCard" Color="#2C2C2E"/>
    <SolidColorBrush x:Key="BgInset" Color="#1C1C1E"/>
    <SolidColorBrush x:Key="Fill" Color="#3A3A3C"/>
    <SolidColorBrush x:Key="FillStrong" Color="#48484A"/>
    <SolidColorBrush x:Key="Separator" Color="#38383A"/>
    <SolidColorBrush x:Key="Label" Color="#F5F5F7"/>
    <SolidColorBrush x:Key="Label2" Color="#A1A1A6"/>
    <SolidColorBrush x:Key="Label3" Color="#98989D"/>
    <SolidColorBrush x:Key="Accent" Color="#0A84FF"/>
    <SolidColorBrush x:Key="AccentFill" Color="#0071E3"/>
    <SolidColorBrush x:Key="Green" Color="#30D158"/>
    <SolidColorBrush x:Key="GreenTint" Color="#2D4635"/>
    <SolidColorBrush x:Key="Orange" Color="#FF9F0A"/>
    <SolidColorBrush x:Key="Red" Color="#FF453A"/>
    <!-- Glass panels: a soft top-to-bottom fill and a lit top edge. Replaced with real gradients when glass is on. -->
    <LinearGradientBrush x:Key="GlassFill" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#2C2C2F" Offset="0"/><GradientStop Color="#2C2C2F" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="GlassEdge" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#3A3A3D" Offset="0"/><GradientStop Color="#3A3A3D" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="GlassEdgeHover" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#48484B" Offset="0"/><GradientStop Color="#48484B" Offset="1"/></LinearGradientBrush>

    <!-- iOS/macOS switch: drawn at 40x24 inside a Viewbox, so Width='34' Height='18' callers scale cleanly. -->
    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle">
        <Setter.Value>
          <Style>
            <Setter Property="Control.Template">
              <Setter.Value>
                <ControlTemplate>
                  <Border Margin="-3" CornerRadius="15" BorderBrush="#990A84FF" BorderThickness="2.5"/>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Viewbox Stretch="Uniform">
              <Grid Width="40" Height="24" Background="Transparent">
                <Border x:Name="Track" CornerRadius="12" Background="{StaticResource FillStrong}"/>
                <Border x:Name="OnTrack" CornerRadius="12" Background="{StaticResource Green}" Opacity="0"/>
                <Grid x:Name="Knob" Width="20" Height="20" HorizontalAlignment="Left" Margin="2,0,0,0">
                  <Grid.RenderTransform><TranslateTransform X="0"/></Grid.RenderTransform>
                  <Ellipse Fill="#40000000" Margin="0,1,0,-1"/>
                  <Ellipse Fill="White"/>
                </Grid>
              </Grid>
            </Viewbox>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="16" Duration="0:0:0.18">
                      <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="OnTrack" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.18">
                      <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="OnTrack" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Grouped box: graphite on graphite, hairline edge. Not clickable, so no hover change (macOS grouped boxes do not highlight). Never put an Effect on it. -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource GlassFill}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource GlassEdge}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource GlassEdgeHover}"/></Trigger>
      </Style.Triggers>
    </Style>

    <!-- Source-list row: soft rounded neutral selection, white label when selected. -->
    <Style x:Key="NavButton" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E5E5EA"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="FocusVisualStyle">
        <Setter.Value>
          <Style>
            <Setter Property="Control.Template">
              <Setter.Value>
                <ControlTemplate>
                  <Border CornerRadius="7" BorderBrush="#990A84FF" BorderThickness="2"/>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bg" CornerRadius="6" Padding="10,6" Background="Transparent">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="#303033"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bg" Property="Background" Value="#38383B"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#3D3D41"/>
                <Setter Property="Foreground" Value="#F5F5F7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Push button. Grey by default; primary actions set Background='#0071E3' Foreground='#FFFFFF' (4.7:1).
         Hover/press are white/black overlays, so they work on any Background the code assigns. -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Label}"/>
      <Setter Property="Background" Value="{StaticResource Fill}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="FocusVisualStyle">
        <Setter.Value>
          <Style>
            <Setter Property="Control.Template">
              <Setter.Value>
                <ControlTemplate>
                  <Border Margin="-3" CornerRadius="11" BorderBrush="#990A84FF" BorderThickness="2.5"/>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="Root">
              <Border x:Name="Bg" CornerRadius="8" Background="{TemplateBinding Background}"/>
              <Border x:Name="Hover" CornerRadius="8" Background="White" Opacity="0"/>
              <Border x:Name="Press" CornerRadius="8" Background="Black" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="0.08"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Press" Property="Opacity" Value="0.2"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Root" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <!-- accent ("do it") buttons glow, brighter under the mouse, none while disabled -->
      <Style.Triggers>
        <DataTrigger Binding="{Binding Background.Color, RelativeSource={RelativeSource Self}}" Value="#0071E3">
          <Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#0071E3" BlurRadius="26" ShadowDepth="0" Opacity="0.7" RenderingBias="Performance"/></Setter.Value></Setter>
        </DataTrigger>
        <MultiDataTrigger>
          <MultiDataTrigger.Conditions>
            <Condition Binding="{Binding Background.Color, RelativeSource={RelativeSource Self}}" Value="#0071E3"/>
            <Condition Binding="{Binding IsMouseOver, RelativeSource={RelativeSource Self}}" Value="True"/>
          </MultiDataTrigger.Conditions>
          <Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#0071E3" BlurRadius="34" ShadowDepth="0" Opacity="1" RenderingBias="Performance"/></Setter.Value></Setter>
        </MultiDataTrigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Effect" Value="{x:Null}"/></Trigger>
      </Style.Triggers>
    </Style>

    <!-- (i) affordance on cards for 'Not recommended if...': quiet grey, brightens on hover. Used by New-Card (x:Name Warn). -->
    <Style x:Key="InfoLink" TargetType="Border">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Help"/>
      <Setter Property="Padding" Value="3"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextElement.Foreground" Value="{StaticResource Label3}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="TextElement.Foreground" Value="{StaticResource Label}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="FlatRepeat" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="{TemplateBinding Background}" CornerRadius="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Overlay-style thumb: graphite pill, never coloured. -->
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" CornerRadius="4" Background="#4D4D50" Margin="3,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#6E6E73"/><Setter TargetName="T" Property="Margin" Value="2,0"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="#8E8E93"/><Setter TargetName="T" Property="Margin" Value="2,0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" Margin="0,4">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource FlatRepeat}" Background="Transparent"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}" MinHeight="40"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource FlatRepeat}" Background="Transparent"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent" Margin="4,0">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource FlatRepeat}" Background="Transparent"/></Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb MinWidth="40">
                        <Thumb.Template>
                          <ControlTemplate TargetType="Thumb">
                            <Border x:Name="T" CornerRadius="4" Background="#4D4D50" Margin="0,3"/>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#6E6E73"/></Trigger>
                              <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="#8E8E93"/></Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource FlatRepeat}" Background="Transparent"/></Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- KEYED overlay scroller (macOS style): the bar floats over the right gutter instead of taking a column.
         Applied only to Scroller, NavScroll, the WizardBody scroller and New-PageScroll, so TextBox/ComboBox hosts keep the stock template. -->
    <Style x:Key="OverlayScroll" TargetType="ScrollViewer">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollViewer">
            <Grid Background="{TemplateBinding Background}">
              <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Margin="{TemplateBinding Padding}"
                                      CanContentScroll="{TemplateBinding CanContentScroll}"/>
              <ScrollBar x:Name="PART_VerticalScrollBar" HorizontalAlignment="Right" Cursor="Arrow"
                         Value="{TemplateBinding VerticalOffset}" Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}"
                         Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
              <ScrollBar x:Name="PART_HorizontalScrollBar" Orientation="Horizontal" VerticalAlignment="Bottom" Cursor="Arrow"
                         Value="{TemplateBinding HorizontalOffset}" Maximum="{TemplateBinding ScrollableWidth}" ViewportSize="{TemplateBinding ViewportWidth}"
                         Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- macOS slider: thin graphite track, blue fill, white knob with a soft shadow layer. -->
    <Style x:Key="ZSlider" TargetType="Slider">
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="TickFrequency" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid x:Name="Root" Height="22" Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{StaticResource FillStrong}" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Style="{StaticResource FlatRepeat}" Background="{StaticResource Accent}" Height="4"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Style="{StaticResource FlatRepeat}" Background="Transparent" Height="4"/></Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="18" Height="18">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid Background="Transparent">
                          <Ellipse Fill="#4D000000" Margin="0,1,0,-1"/>
                          <Ellipse x:Name="K" Fill="White"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsDragging" Value="True"><Setter TargetName="K" Property="Fill" Value="#E5E5EA"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Root" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Rounded tooltip. Shadow is a sibling layer so text keeps ClearType. Popups do not inherit the window font, so it is set here.
         String content uses the wrapping DataTemplate; UIElement content (the rich Warn tooltip) bypasses it. -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#3A3A3D"/>
      <Setter Property="Foreground" Value="#F5F5F7"/>
      <Setter Property="BorderBrush" Value="#48484B"/>
      <Setter Property="FontFamily" Value="Inter, Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="MaxWidth" Value="340"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Grid Margin="0,0,8,10">
              <Border CornerRadius="8" Background="{TemplateBinding Background}">
                <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="3" Direction="270" Opacity="0.4" Color="Black"/></Border.Effect>
              </Border>
              <Border CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                <ContentPresenter/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap" LineHeight="17" LineStackingStrategy="BlockLineHeight"/></DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Implicit control styles so page code gets Apple-style inputs without changes. Local Background/BorderBrush still win. -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource BgInset}"/>
      <Setter Property="Foreground" Value="{StaticResource Label}"/>
      <Setter Property="BorderBrush" Value="{StaticResource FillStrong}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="{StaticResource Label}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Grid>
              <Border CornerRadius="7" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"
                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
              </Border>
              <Border x:Name="Ring" Margin="-3" CornerRadius="10" BorderBrush="#990A84FF" BorderThickness="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Ring" Property="BorderThickness" Value="3"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Label}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="B" CornerRadius="5" Padding="10,5" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource AccentFill}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource Label}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="B" CornerRadius="7" Background="#3A3A3C">
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#A1A1A6"
                                 HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#444446"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="12,0,30,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" VerticalOffset="4" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                     IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <Grid Margin="0,0,10,12" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                      TextElement.FontFamily="Inter, Segoe UI Variable Text, Segoe UI">
                  <Border CornerRadius="8" Background="#2C2C2F">
                    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
                  </Border>
                  <Border CornerRadius="8" Background="#2C2C2F" BorderBrush="#48484B" BorderThickness="1" Padding="4">
                    <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}" VerticalScrollBarVisibility="Auto">
                      <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                    </ScrollViewer>
                  </Border>
                </Grid>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E5E5EA"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="16" Height="16" CornerRadius="4" Background="#3A3A3C" BorderBrush="#5A5A5E" BorderThickness="1" VerticalAlignment="Center">
                <TextBlock x:Name="Mark" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="White"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#8E8E93"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Implicit RadioButton (wizard). Nav items keep their explicit NavButton style. -->
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E5E5EA"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="16" Height="16" VerticalAlignment="Center">
                <Ellipse x:Name="Ring" Fill="#3A3A3C" Stroke="#5A5A5E" StrokeThickness="1"/>
                <Ellipse x:Name="Dot" Width="6" Height="6" Fill="White" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="#8E8E93"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Ring" Property="Fill" Value="{StaticResource Accent}"/>
                <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Accent}"/>
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="230"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Sidebar -->
    <Border Background="#262628" BorderBrush="#38383A" BorderThickness="0,0,1,0">
      <DockPanel Margin="14,20,14,16">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="6,0,0,24">
          <Border Width="32" Height="32" CornerRadius="8">
            <Border.Effect><DropShadowEffect Color="#2EE6A6" BlurRadius="20" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#4BF0BA" Offset="0"/>
                <GradientStop Color="#22CF93" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="&#xE945;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" Foreground="#06281C" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="ZeroDelay" FontSize="15" FontWeight="Bold"/>
            <TextBlock Text="Fortnite latency optimizer" FontSize="11.5" Foreground="#8E8E93"/>
          </StackPanel>
        </StackPanel>
        <Border DockPanel.Dock="Bottom" Background="#2C2C2E" BorderBrush="#38383A" BorderThickness="1" CornerRadius="10">
          <StackPanel>
            <Border x:Name="GmPanel" Background="Transparent" BorderBrush="Transparent" BorderThickness="0" Padding="15,10,12,10" Cursor="Hand">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock Text="Game Mode" FontSize="13" FontWeight="SemiBold"/>
                  <TextBlock x:Name="GmStatus" Text="Off" FontSize="11.5" Foreground="#A1A1A6" TextWrapping="Wrap" Margin="0,1,0,0"/>
                </StackPanel>
                <ToggleButton x:Name="GmSwitch" Grid.Column="1" Style="{StaticResource Switch}" Width="36" Height="22" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </Grid>
            </Border>
            <Border Height="1" Background="#38383A" Margin="15,0,0,0"/>
            <StackPanel x:Name="ActivePanel" Margin="15,10,15,12" Background="Transparent" Cursor="Hand" ToolTip="See every active tweak">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="ActiveCount" FontSize="15" FontWeight="Bold" Typography.NumeralAlignment="Tabular"/>
                <TextBlock Text="active" FontSize="12" Foreground="#A1A1A6" VerticalAlignment="Bottom" Margin="6,0,0,1"/>
              </StackPanel>
              <Border Height="4" CornerRadius="2" Background="#3A3A3C" Margin="0,8,0,0">
                <Border x:Name="ActiveBar" Height="4" CornerRadius="2" Background="#30D158" HorizontalAlignment="Left" Width="0"/>
              </Border>
            </StackPanel>
          </StackPanel>
        </Border>
        <ScrollViewer x:Name="NavScroll" Style="{StaticResource OverlayScroll}" VerticalScrollBarVisibility="Auto" Margin="0,0,0,12">
          <StackPanel x:Name="Nav"/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- Main -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <!-- soft colour glows behind the pages; they drift slowly (see Start-AmbientGlow) -->
      <Grid x:Name="Ambient" Grid.RowSpan="3" IsHitTestVisible="False" ClipToBounds="True">
        <Ellipse x:Name="Glow1" Width="760" Height="760" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-220,-380,0,0">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#5C0A84FF" Offset="0"/><GradientStop Color="#1F0A84FF" Offset="0.55"/><GradientStop Color="#000A84FF" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        </Ellipse>
        <Ellipse x:Name="Glow2" Width="860" Height="860" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-340,-440">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#4D5E5CE6" Offset="0"/><GradientStop Color="#185E5CE6" Offset="0.55"/><GradientStop Color="#005E5CE6" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        </Ellipse>
        <Ellipse x:Name="Glow3" Width="560" Height="560" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-220,-160,0">
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#382EE6A6" Offset="0"/><GradientStop Color="#002EE6A6" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        </Ellipse>
      </Grid>
      <Grid Margin="32,28,32,20">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock x:Name="PageTitle" Text="All optimizations" FontSize="28" FontWeight="Bold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
        <StackPanel Grid.Row="1" Grid.ColumnSpan="2">
          <TextBlock x:Name="LatencyNote" Margin="0,6,0,0" FontSize="13" Foreground="#A1A1A6" TextWrapping="Wrap" MaxWidth="760" HorizontalAlignment="Left" Visibility="Collapsed"
                     Text="Only the tweaks that change input delay, frame time or ping. Green icons mark them in every tab."/>
          <TextBlock x:Name="StatusLine" Margin="0,6,0,0" FontSize="12" Foreground="#98989D" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="24,0,0,0">
          <Grid Width="220" Margin="0,0,8,0">
            <TextBox x:Name="Search" Padding="32,7,10,7" FontSize="13" Background="#2C2C2E" Foreground="#F5F5F7" BorderBrush="#38383A" CaretBrush="#F5F5F7" VerticalContentAlignment="Center"/>
            <TextBlock Text="&#xE721;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Foreground="#98989D" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <TextBlock x:Name="SearchHint" Text="Search" FontSize="13" Foreground="#98989D" Margin="35,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
          <Button x:Name="MoreBtn" Content="&#xE712;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Style="{StaticResource Btn}" Margin="0,0,8,0" Padding="12,8"
                  ToolTip="Restore point and undo everything"/>
          <Popup x:Name="MorePop" PlacementTarget="{Binding ElementName=MoreBtn}" Placement="Bottom" HorizontalOffset="-150" VerticalOffset="6" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
            <Grid Margin="0,0,10,12" TextElement.FontFamily="Inter, Segoe UI Variable Text, Segoe UI">
              <Border CornerRadius="12" Background="#2C2C2F">
                <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="6" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
              </Border>
              <Border CornerRadius="12" Background="#2C2C2F" BorderBrush="#48484B" BorderThickness="1" Padding="6">
                <StackPanel MinWidth="230">
                  <Button x:Name="RestorePoint" Style="{StaticResource Btn}" Background="Transparent" HorizontalContentAlignment="Left" Padding="12,9" Margin="0,0,0,2"
                          ToolTip="A Windows restore point you can roll back to if anything goes wrong.">
                    <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE777;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Margin="0,1,10,0"/><TextBlock Text="Create restore point"/></StackPanel>
                  </Button>
                  <Button x:Name="RestoreAll" Style="{StaticResource Btn}" Background="Transparent" HorizontalContentAlignment="Left" Padding="12,9">
                    <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7A7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Margin="0,1,10,0"/><TextBlock Text="Undo everything (restore all)"/></StackPanel>
                  </Button>
                </StackPanel>
              </Border>
            </Grid>
          </Popup>
          <Button x:Name="ApplyRec" Style="{StaticResource Btn}" Background="#0071E3" Foreground="#FFFFFF" Padding="16,8" ToolTip="Switch on every recommended tweak that fits this PC. Everything can be undone.">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE945;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Margin="0,1,8,0"/><TextBlock Text="Optimize"/></StackPanel>
          </Button>
        </StackPanel>
      </Grid>
      <StackPanel Grid.Row="1">
      <Border x:Name="UpdateBar" Margin="32,0,32,12" Background="#2C2C2E" BorderBrush="#38383A" BorderThickness="1" CornerRadius="12" Padding="12,12,16,12" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border Width="32" Height="32" CornerRadius="8" Background="#273A4F" VerticalAlignment="Center">
            <TextBlock Text="&#xE896;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" Foreground="#0A84FF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,16,0" VerticalAlignment="Center">
            <TextBlock x:Name="UpdateTitle" FontSize="13.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="UpdateText" FontSize="12" Foreground="#A1A1A6" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="UpdateLater" Content="Later" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
            <Button x:Name="UpdateGet" Content="Download" Style="{StaticResource Btn}" Background="#0071E3" Foreground="#FFFFFF"/>
          </StackPanel>
        </Grid>
      </Border>
      <Border x:Name="DriftBar" Margin="32,0,32,12" Background="#2C2C2E" BorderBrush="#38383A" BorderThickness="1" CornerRadius="12" Padding="12,12,16,12" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border Width="32" Height="32" CornerRadius="8" Background="#4E3E28" VerticalAlignment="Center">
            <TextBlock Text="&#xE7BA;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" Foreground="#FF9F0A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,16,0" VerticalAlignment="Center">
            <TextBlock x:Name="DriftTitle" FontSize="13.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="DriftText" FontSize="12" Foreground="#A1A1A6" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="DriftIgnore" Content="Keep their change" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
            <Button x:Name="DriftFix" Content="Re-apply" Style="{StaticResource Btn}" Background="#0071E3" Foreground="#FFFFFF"/>
          </StackPanel>
        </Grid>
      </Border>
      <Border x:Name="RestartBar" Margin="32,0,32,16" Background="#2C2C2E" BorderBrush="#38383A" BorderThickness="1" CornerRadius="12" Padding="12,12,16,12" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border Width="32" Height="32" CornerRadius="8" Background="#273A4F" VerticalAlignment="Center">
            <TextBlock Text="&#xE72C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" Foreground="#0A84FF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,16,0" VerticalAlignment="Center">
            <TextBlock x:Name="RestartTitle" FontSize="13.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="RestartText" FontSize="12" Foreground="#A1A1A6" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="RestartLater" Content="Restart later" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
            <Button x:Name="RestartNow" Content="Restart now" Style="{StaticResource Btn}" Background="#0071E3" Foreground="#FFFFFF"/>
          </StackPanel>
        </Grid>
      </Border>
      </StackPanel>

      <ScrollViewer x:Name="Scroller" Grid.Row="2" Style="{StaticResource OverlayScroll}" VerticalScrollBarVisibility="Auto" Padding="32,0,16,32">
        <WrapPanel x:Name="Cards"/>
      </ScrollViewer>
      <ContentControl x:Name="PageHost" Grid.Row="2" Visibility="Collapsed"/>

      <Grid x:Name="Toast" Grid.Row="2" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,28" Visibility="Collapsed">
        <Border CornerRadius="14" Background="#3A3A3D">
          <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="8" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
        </Border>
        <Border CornerRadius="14" Background="#3A3A3D" BorderBrush="#48484B" BorderThickness="1" Padding="14,10,18,10">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="ToastIcon" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="15" Foreground="#30D158" VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Collapsed"/>
            <TextBlock x:Name="ToastText" FontSize="13" FontWeight="Medium" Foreground="#F5F5F7" TextWrapping="Wrap" MaxWidth="560" VerticalAlignment="Center" LineHeight="18" LineStackingStrategy="BlockLineHeight"/>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
    <Grid x:Name="Wizard" Grid.ColumnSpan="2" Background="#99000000" Visibility="Collapsed">
      <Grid Width="600" Margin="24" VerticalAlignment="Center" HorizontalAlignment="Center">
        <Border CornerRadius="16" Background="#2C2C2F">
          <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="16" Direction="270" Opacity="0.55" Color="Black"/></Border.Effect>
        </Border>
        <Border Background="#2C2C2F" BorderBrush="#48484B" BorderThickness="1" CornerRadius="16" Padding="32,28,20,28">
          <ScrollViewer Style="{StaticResource OverlayScroll}" VerticalScrollBarVisibility="Auto" Padding="0,0,12,0">
            <ContentControl x:Name="WizardBody"/>
          </ScrollViewer>
        </Border>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@)

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

# --- App logo: mint rounded square with a dark lightning bolt (same as the sidebar badge).
function New-LogoBitmap([int]$Size) {
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $mint = [ZdTheme]::Brush('#2EE6A6')
    $dark = [ZdTheme]::Brush('#06281C')
    $r = $Size * 0.26
    $dc.DrawRoundedRectangle($mint, $null, (New-Object Windows.Rect 0, 0, $Size, $Size), $r, $r)
    $face = New-Object Windows.Media.Typeface 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $ft = New-Object Windows.Media.FormattedText ([string][char]0xE945), ([Globalization.CultureInfo]::InvariantCulture),
        ([Windows.FlowDirection]::LeftToRight), $face, ($Size * 0.58), $dark
    $dc.DrawText($ft, (New-Object Windows.Point (($Size - $ft.Width) / 2), (($Size - $ft.Height) / 2)))
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $Size, $Size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $bmp
}
# Writes a multi-size .ico (PNG-compressed entries) for the desktop shortcut and taskbar.
function Save-LogoIco([string]$Path) {
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $pngs = foreach ($sz in $sizes) {
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create((New-LogoBitmap $sz)))
        $ms = New-Object IO.MemoryStream; $enc.Save($ms); , $ms.ToArray()
    }
    $fs = [IO.File]::Create($Path); $w = New-Object IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write($p) }
    $w.Close()
}
$window.Icon = New-LogoBitmap 64
try { Add-Type -Namespace ZD -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);' } catch {}
try { Add-Type -Namespace ZD -Name DwmFrame -MemberDefinition '[StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int L, R, T, B; } [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);' } catch {}
# real gradients for the glass resources
function Set-GlassBrushes {
    if (-not $script:Glass) { return }
    function Grad([string]$top, [string]$bottom) {
        $g = New-Object Windows.Media.LinearGradientBrush; $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($top)), 0))
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($bottom)), 1))
        $g
    }
    if ($script:Theme -eq 'light') {
        $window.Resources['GlassFill'] = [Windows.Media.Brush](Grad '#E6FFFFFF' '#B3FFFFFF'); $window.Resources['GlassEdge'] = [Windows.Media.Brush](Grad '#FFFFFFFF' '#1F000000'); $window.Resources['GlassEdgeHover'] = [Windows.Media.Brush](Grad '#FFFFFFFF' '#33000000')
    } else {
        $window.Resources['GlassFill'] = [Windows.Media.Brush](Grad '#21FFFFFF' '#0AFFFFFF'); $window.Resources['GlassEdge'] = [Windows.Media.Brush](Grad '#47FFFFFF' '#0FFFFFFF'); $window.Resources['GlassEdgeHover'] = [Windows.Media.Brush](Grad '#7AFFFFFF' '#24FFFFFF')
    }
}
Set-GlassBrushes
$window.Add_SourceInitialized({
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        $dk = $script:Theme -ne 'light'
        $v = [int]$dk; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)                         # dark title bar
        if ($script:Glass -and -not $Snapshot) {
            # frosted acrylic backdrop behind the whole window, title bar included (dev renders keep their stand-in)
            $hs = [Windows.Interop.HwndSource]::FromHwnd($h); $hs.CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
            $m = New-Object ZD.DwmFrame+MARGINS; $m.L = -1; $m.R = -1; $m.T = -1; $m.B = -1
            [void][ZD.DwmFrame]::DwmExtendFrameIntoClientArea($h, [ref]$m)
            $v = 3; $hr = [ZD.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$v, 4)                            # DWMSBT_TRANSIENTWINDOW (acrylic)
            if ($hr -eq 0) {
                # dark: almost-black tint over the frost so the window reads as black, with only a hint of glass
                $window.Background = if ($dk) { [ZdTheme]::Brush('#EB000000') } else { [Windows.Media.Brushes]::Transparent }
                $v = if ($dk) { 0x00000000 } else { 0x00F7F2F2 }; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$v, 4)   # black title bar
                return
            }
            $window.Background = [ZdTheme]::Brush('#1C1C1E')   # backdrop refused: solid window, glass panels on top
        }
        $v = if ($dk) { 0x00000000 } else { 0x00F7F2F2 }; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$v, 4)  # caption = window colour
        $v = if ($dk) { 0x003A3838 } else { 0x00E5E0E0 }; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$v, 4)  # border = separator
    } catch {}
})
$LogoIco = Join-Path $PSScriptRoot 'ZeroDelay.ico'
if (-not (Test-Path $LogoIco)) { try { Save-LogoIco $LogoIco } catch {} }
if (Test-Path $LogoIco) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$LogoIco, 'None', 'OnLoad') } catch {}
}
$ui = @{}
foreach ($n in 'MoreBtn', 'MorePop', 'Nav', 'Cards', 'PageTitle', 'StatusLine', 'RestoreAll', 'ApplyRec', 'Toast', 'ToastText', 'ActiveCount', 'ActiveBar', 'Search', 'SearchHint', 'LatencyNote',
            'RestartBar', 'RestartTitle', 'RestartText', 'RestartNow', 'RestartLater', 'Scroller', 'RestorePoint', 'GmPanel', 'GmStatus', 'GmSwitch',
            'PageHost', 'DriftBar', 'DriftTitle', 'DriftText', 'DriftIgnore', 'DriftFix', 'Wizard', 'WizardBody', 'ToastIcon',
            'UpdateBar', 'UpdateTitle', 'UpdateText', 'UpdateLater', 'UpdateGet') { $ui[$n] = $window.FindName($n) }

$BadgeInfo = @{
    restart  = @{ Color = '#0A84FF'; Label = 'Needs restart'; Tip = 'Takes effect after you restart the PC.' }
    signout  = @{ Color = '#0A84FF'; Label = 'Needs sign-out'; Tip = 'Takes effect after you sign out and back in.' }
    advanced = @{ Color = '#FF9F0A'; Label = 'Advanced'; Tip = 'Advanced: benefit depends on your hardware. Test with and without.' }
}

function Esc([string]$s) { [Security.SecurityElement]::Escape(($s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')) }   # control characters (e.g. NULs in registry text) are not valid XAML

# --- Motion. Short ease-out curves like macOS; switched off when Windows "Animation effects" is off.
$script:Anim = [bool][Windows.SystemParameters]::ClientAreaAnimation -and (-not $Snapshot -or $env:ZD_ANIM)
function New-Ease { $e = New-Object Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $e }
function Start-Anim($target, $prop, $from, $to, [int]$ms, [int]$delay = 0, [scriptblock]$Done) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if ($null -ne $from) { $a.From = $from }
    $a.To = $to; $a.Duration = [TimeSpan]::FromMilliseconds($ms); $a.BeginTime = [TimeSpan]::FromMilliseconds($delay); $a.EasingFunction = New-Ease
    if ($Done) { $a.Add_Completed($Done) }
    $target.BeginAnimation($prop, $a)
}
# --- Glow. Accent-coloured light: drifting background glows, glowing main buttons, lit card edges on hover.
function Get-AccentColor { ([ZdTheme]::Brush('#0A84FF')).Color }
function New-Glow($color, [double]$blur, [double]$opacity) {
    $fx = New-Object Windows.Media.Effects.DropShadowEffect
    $fx.Color = $color; $fx.BlurRadius = $blur; $fx.ShadowDepth = 0; $fx.Opacity = $opacity; $fx.RenderingBias = 'Performance'
    $fx
}
# ClipToBounds clips to a square; this clips an element to its rounded corners and follows its size
function Set-RoundClip($el, [double]$radius) {
    $el.ClipToBounds = $false
    $r = $radius
    $el.Add_SizeChanged({ param($s, $e) $s.Clip = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect 0, 0, $s.ActualWidth, $s.ActualHeight), $r, $r }.GetNewClosure())
}
function Start-AmbientGlow {
    $amb = $window.FindName('Ambient'); if (-not $amb) { return }
    $amb.Opacity = if ($script:Theme -eq 'light') { 0.55 } else { 1 }
    $i = 0
    foreach ($n in 'Glow1', 'Glow2', 'Glow3') {
        $el = $window.FindName($n)
        # each glow is drawn once to a half-size bitmap, so moving it costs the GPU almost nothing
        $el.CacheMode = New-Object Windows.Media.BitmapCache 0.5
        $tt = New-Object Windows.Media.TranslateTransform; $el.RenderTransform = $tt
        if (-not $script:Anim) { continue }
        foreach ($axis in @(@([Windows.Media.TranslateTransform]::XProperty, (90, -70, 110)[$i], (19, 23, 17)[$i]), @([Windows.Media.TranslateTransform]::YProperty, (60, -90, 70)[$i], (23, 29, 21)[$i]))) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation 0, $axis[1], ([Windows.Duration][TimeSpan]::FromSeconds($axis[2]))
            $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $e = New-Object Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
            [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 24)   # a slow drift needs few frames
            $tt.BeginAnimation($axis[0], $a)
        }
        $i++
    }
}
# cards: a soft accent halo fades in while the mouse is over them (the edge lights up through GlassEdgeHover)
function Set-HoverGlow($el, [bool]$on) {
    if (-not $script:Anim) { return }
    $fx = $el.Effect
    if (-not ($fx -is [Windows.Media.Effects.DropShadowEffect])) {
        if (-not $on) { return }
        $fx = New-Glow (Get-AccentColor) 30 0; $el.Effect = $fx
    }
    $to = if ($on) { if ($script:Theme -eq 'light') { 0.22 } else { 0.32 } } else { 0 }
    Start-Anim $fx ([Windows.Media.Effects.DropShadowEffect]::OpacityProperty) $null $to $(if ($on) { 200 } else { 280 })
}
# hovered cards get a lit accent edge, bright at the top and fading down
& {
    $ac = Get-AccentColor
    $g = New-Object Windows.Media.LinearGradientBrush; $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
    $top = $ac; $top.A = if ($script:Theme -eq 'light') { 0xAA } else { 0xCC }
    $bot = $ac; $bot.A = if ($script:Theme -eq 'light') { 0x30 } else { 0x40 }
    $g.GradientStops.Add((New-Object Windows.Media.GradientStop $top, 0)); $g.GradientStops.Add((New-Object Windows.Media.GradientStop $bot, 1))
    $window.Resources['GlassEdgeHover'] = [Windows.Media.Brush]$g
}
Start-AmbientGlow

# Fades an element in while sliding it up (or down for a negative distance) into place.
function Show-Animated($el, [double]$dy = 10, [int]$ms = 260, [int]$delay = 0) {
    if (-not $el) { return }
    if (-not $script:Anim) { $el.Opacity = 1; return }
    $tt = New-Object Windows.Media.TranslateTransform 0, $dy
    $el.RenderTransform = $tt
    $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $el.Opacity = 0
    # Start once the new content has been laid out, so no frames are lost to building the page.
    [void]$script:AnimQueue.Add(@{ El = $el; Tt = $tt; Dy = $dy; Ms = $ms; Delay = $delay })
    if (-not $script:AnimPending) {
        $script:AnimPending = $true
        [void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [action] { Start-QueuedAnims })
    }
}
$script:AnimQueue = New-Object Collections.ArrayList
function Start-QueuedAnims {
    $script:AnimPending = $false
    $longest = 0
    foreach ($q in @($script:AnimQueue)) {
        # while it moves, the element is drawn as a cached bitmap: cheap for the GPU to slide and fade
        try { $scale = [Windows.Media.VisualTreeHelper]::GetDpi($q.El).PixelsPerDip } catch { $scale = 1.0 }
        $q.El.CacheMode = New-Object Windows.Media.BitmapCache ([double]$scale)
        [void]$script:Uncache.Add($q.El)
        Start-Anim $q.El ([Windows.UIElement]::OpacityProperty) 0 1 $q.Ms $q.Delay
        Start-Anim $q.Tt ([Windows.Media.TranslateTransform]::YProperty) $q.Dy 0 ($q.Ms + 60) $q.Delay
        $longest = [Math]::Max($longest, $q.Ms + 60 + $q.Delay)
    }
    $script:AnimQueue.Clear()
    # back to sharp, live rendering once everything has landed
    if (-not $script:UncacheTimer) {
        $script:UncacheTimer = New-Object Windows.Threading.DispatcherTimer
        $script:UncacheTimer.Add_Tick({ $script:UncacheTimer.Stop(); foreach ($e in @($script:Uncache)) { $e.CacheMode = $null }; $script:Uncache.Clear() })
    }
    $script:UncacheTimer.Stop()
    $script:UncacheTimer.Interval = [TimeSpan]::FromMilliseconds($longest + 80)
    $script:UncacheTimer.Start()
}
$script:Uncache = New-Object Collections.ArrayList
# Fades an element out, then collapses it.
function Hide-Animated($el, [int]$ms = 200) {
    if (-not $el) { return }
    if (-not $script:Anim) { $el.Visibility = 'Collapsed'; return }
    $script:HideTarget = $el
    Start-Anim $el ([Windows.UIElement]::OpacityProperty) $null 0 $ms 0 { $script:HideTarget.Visibility = 'Collapsed'; $script:HideTarget.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $script:HideTarget.Opacity = 1 }
}
# Counts a number up in a TextBlock, e.g. 0 -> 74 with an optional suffix.
function Start-CountUp($tb, [int]$to, [string]$suffix = '', [int]$ms = 600) {
    if (-not $script:Anim -or $to -le 0) { $tb.Text = "$to$suffix"; return }
    $script:CountJobs = @($script:CountJobs | Where-Object { $_ -and $_.Tb -ne $tb }) + @([pscustomobject]@{ Tb = $tb; To = $to; Suffix = $suffix; Start = Get-Date; Ms = $ms })
    if (-not $script:CountHandler) {
        $script:CountHandler = [EventHandler] {
            $left = @()
            foreach ($j in @($script:CountJobs | Where-Object { $_ })) {
                $t = [Math]::Min(1.0, ((Get-Date) - $j.Start).TotalMilliseconds / $j.Ms)
                $e = 1 - [Math]::Pow(1 - $t, 3)
                $j.Tb.Text = "$([int][Math]::Round($j.To * $e))$($j.Suffix)"
                if ($t -lt 1) { $left += $j }
            }
            $script:CountJobs = $left
            if (-not $left) { [Windows.Media.CompositionTarget]::remove_Rendering($script:CountHandler); $script:CountOn = $false }
        }
    }
    if (-not $script:CountOn) { [Windows.Media.CompositionTarget]::add_Rendering($script:CountHandler); $script:CountOn = $true }
}

function New-SectionHeader($t) {
    $h = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Margin='0,24,16,12'>
  <TextBlock Text='$(Esc $t.Header)' FontSize='20' FontWeight='Bold' Foreground='#F5F5F7'/>
  <TextBlock Text='$(Esc $t.Desc)' FontSize='13' Foreground='#A1A1A6' Margin='0,4,0,0' TextWrapping='Wrap' MaxWidth='720' HorizontalAlignment='Left'/>
</StackPanel>
"@)
    $h.Tag = $t; $t.Card = $h
    $h
}

function New-Card($t) {
    if ($t.Header) { return New-SectionHeader $t }
    if ($t.Extra -eq 'builder') { return New-PotatoStudio $t }
    $badge = ''
    if ($t.Badge) {
        $b = $BadgeInfo[$t.Badge]
        $badge = "<StackPanel Orientation='Horizontal' Margin='0,12,14,0' Background='Transparent' Cursor='Help' ToolTip='$(Esc $b.Tip)'><Ellipse Width='7' Height='7' Fill='$($b.Color)' VerticalAlignment='Center' Margin='0,1,6,0'/><TextBlock Text='$(Esc $b.Label)' FontSize='12' Foreground='#A1A1A6' VerticalAlignment='Center'/></StackPanel>"
    }
    if ($t.Id -eq 'vrrcap') { $c = Get-VrrCap; if ($c) { $t.Action = "Set $c FPS" } }
    $pill = if ($t.Preset) { "<Border x:Name='ActivePill' Background='#2D4635' CornerRadius='10' Padding='8,2,9,3' Margin='0,0,8,0' VerticalAlignment='Center' Visibility='Collapsed'><StackPanel Orientation='Horizontal'><TextBlock Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='10' Foreground='#30D158' VerticalAlignment='Center' Margin='0,1,4,0'/><TextBlock Text='Active' FontSize='11.5' FontWeight='SemiBold' Foreground='#30D158'/></StackPanel></Border>" } else { '' }
    $control = $pill + $(if ($t.Picker) { '' } elseif ($t.Action) {
        "<Button x:Name='ActionBtn' Content='$(Esc $t.Action)' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12.5'/>"
    } else {
        "<ToggleButton x:Name='Toggle' Style='{DynamicResource Switch}'/>"
    })
    $recTag = if ($t.Rec) { "<StackPanel x:Name='RecTag' Orientation='Horizontal' Margin='0,12,14,0' VerticalAlignment='Center' Background='Transparent' ToolTip='Included when you press Apply recommended'><TextBlock Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='11' Foreground='#30D158' VerticalAlignment='Center' Margin='0,1,5,0'/><TextBlock Text='Recommended' FontSize='12' FontWeight='Medium' Foreground='#A1A1A6' VerticalAlignment='Center'/></StackPanel>" } else { '' }
    $cardXaml = @"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Style='{DynamicResource Card}' Width='342' Height='220' VerticalAlignment='Top' Margin='0,0,16,16' Padding='20'>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/>
    </Grid.RowDefinitions>
    <Grid>
      <Border Width='32' Height='32' CornerRadius='8' HorizontalAlignment='Left' VerticalAlignment='Center' Background='$(if ($t.Lat) { '{DynamicResource GreenTint}' } else { '{DynamicResource Fill}' })' $(if ($t.Lat) { "ToolTip='Affects input delay, frame time or ping'" })>
        <TextBlock Text='$([int][char]$t.Icon | ForEach-Object { '&#x{0:X};' -f $_ })' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='16' Foreground='$(if ($t.Lat) { '{DynamicResource Green}' } else { '#D1D1D6' })' HorizontalAlignment='Center' VerticalAlignment='Center'/>
      </Border>
      <StackPanel Orientation='Horizontal' HorizontalAlignment='Right' VerticalAlignment='Center'>$control</StackPanel>
    </Grid>
    <TextBlock Grid.Row='1' Text='$(Esc $t.Title)' ToolTip='$(Esc $t.Title)' FontSize='15' FontWeight='SemiBold' Foreground='{DynamicResource Label}' TextTrimming='CharacterEllipsis' Margin='0,16,0,0'/>
    <TextBlock Grid.Row='2' Text='$(Esc $t.Desc)' ToolTip='$(Esc $t.Desc)' Foreground='{DynamicResource Label2}' FontSize='13' LineHeight='18' LineStackingStrategy='BlockLineHeight'
               TextWrapping='Wrap' TextTrimming='CharacterEllipsis' VerticalAlignment='Top' MaxHeight='55' Margin='0,4,0,0'/>
    <ContentControl x:Name='Extra' Grid.Row='3' Margin='0,12,0,0'/>
    <Grid Grid.Row='4'>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <StackPanel Orientation='Horizontal' VerticalAlignment='Bottom' ClipToBounds='True'>$recTag$badge</StackPanel>
      <Border x:Name='Warn' Grid.Column='1' Style='{DynamicResource InfoLink}' VerticalAlignment='Bottom' Margin='8,12,-3,-3'
              AutomationProperties.Name='Not recommended if' ToolTipService.InitialShowDelay='100' ToolTipService.ShowDuration='20000'>
        <Border.ToolTip>
          <StackPanel MaxWidth='300'>
            <TextBlock Text='Not recommended if' FontWeight='SemiBold' Foreground='#FF9F0A'/>
            <TextBlock Text='$(Esc $t.Warn)' Foreground='#D1D1D6' Margin='0,4,0,0' TextWrapping='Wrap' LineHeight='17' LineStackingStrategy='BlockLineHeight'/>
          </StackPanel>
        </Border.ToolTip>
        <TextBlock Text='&#xE946;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='15'/>
      </Border>
    </Grid>
  </Grid>
</Border>
"@
    $card = [ZdTheme]::Parse($cardXaml)
    $card.RenderTransform = New-Object Windows.Media.TranslateTransform
    $card.Add_MouseEnter({ param($s, $e) Set-HoverGlow $s $true; if ($script:Anim -and $s.RenderTransform -is [Windows.Media.TranslateTransform]) { Start-Anim $s.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) $null -3 180 } })
    $card.Add_MouseLeave({ param($s, $e) Set-HoverGlow $s $false; if ($script:Anim -and $s.RenderTransform -is [Windows.Media.TranslateTransform]) { Start-Anim $s.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) $null 0 220 } })
    $card.Tag = $t
    $t.Card = $card
    $t.Toggle = $card.FindName('Toggle')
    $extra = $card.FindName('Extra')

    if ($t.Toggle) {
        $t.Toggle.Tag = $t
        $t.Toggle.Add_Click({ param($s, $e) Switch-Tweak $s.Tag ([bool]$s.IsChecked) })
    }
    if ($t.Extra -eq 'fps') {
        $panel = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Orientation='Horizontal'>
  <TextBox Width='64' Padding='6,3' FontSize='13'/>
  <TextBlock Text='FPS  (0 = unlimited)' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Margin='8,0,0,0'/>
</StackPanel>
"@)
        $script:FpsBox = $panel.Children[0]
        $cur = if (Test-Path $IniPath) { Get-IniValue (Get-Content $IniPath) 'FrameRateLimit' } else { $null }
        $script:FpsBox.Text = if ($cur -and [double]$cur -gt 0) { [int][double]$cur } else { Get-RefreshRate }
        $extra.Content = $panel
    }
    if ($t.Extra -eq 'res') {
        $panel = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Orientation='Horizontal'>
  <TextBox Width='64' Padding='6,3' FontSize='13'/>
  <TextBlock Text='%  of screen resolution (25 to 99)' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Margin='8,0,0,0'/>
</StackPanel>
"@)
        $script:ResBox = $panel.Children[0]
        $resLines = if (Test-Path $IniPath) { Get-Content $IniPath } else { @() }
        $cur = Get-IniValue $resLines 'PotentiallyUpscaledResolutionQuality'; if (-not $cur) { $cur = Get-IniValue $resLines 'sg.ResolutionQuality' }
        $script:ResBox.Text = if ($cur -and [double]$cur -lt 100) { [int][double]$cur } else { 75 }
        $extra.Content = $panel
    }
    if ($t.Id -eq 'ping') {
        $script:PingText = New-Object Windows.Controls.TextBlock
        $script:PingText.FontFamily = 'Cascadia Mono, Consolas'; $script:PingText.FontSize = 11.5
        $script:PingText.Foreground = [ZdTheme]::Brush('#D1D1D6')
        $script:PingText.TextWrapping = 'Wrap'
        $extra.Content = $script:PingText
    }
    if ($t.Extra -eq 'builder') {
        $card.Height = 432
        $extra.Content = New-BuilderPanel $t
    }
    if ($t.Extra -eq 'preset') {
        $card.Height = 432
        $t.PreviewHost = $extra
        Update-PresetPreview $t
    }
    if ($t.Action -or -not $t.Warn) { $card.FindName('Warn').Visibility = 'Collapsed' }
    $btn = $card.FindName('ActionBtn')
    if ($btn) { $btn.Tag = $t; $t.ActionBtn = $btn; $btn.Add_Click({ param($s, $e) Invoke-Action $s.Tag $s }) }
    if ($t.Extra -eq 'gamemode') {
        $card.Height = 432
        $extra.Content = New-GameModePanel $t
    }
    if ($t.Extra -eq 'session') {
        $card.Height = 432
        $extra.Content = New-SessionPanel $t
        Update-SessionCard
    }
    $card
}

# --------------------------------------------------------------- dialog ---
# ZeroDelay's own question box instead of the grey Windows one. Same inputs and answers as MessageBox::Show
# (buttons 'OK', 'OKCancel', 'YesNo', 'YesNoCancel'; icon 'Question', 'Warning', 'Error', 'Information'),
# returns 'Yes', 'No', 'Cancel' or 'OK'. Enter picks the main button, Esc the way out.
function Show-ZdDialog([string]$Message, [string]$Title = 'ZeroDelay', [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    $look = switch ($Icon) { 'Question' { @(0xE9CE, '#0A84FF') } 'Warning' { @(0xE7BA, '#FF9F0A') } 'Error' { @(0xEA39, '#FF453A') } default { @(0xE946, '#0A84FF') } }
    $btns = switch ($Buttons) { 'YesNo' { @('No', 'Yes') } 'YesNoCancel' { @('Cancel', 'No', 'Yes') } 'OKCancel' { @('Cancel', 'OK') } default { @('OK') } }
    $main = $btns[-1]
    $escape = if ($btns -contains 'Cancel') { 'Cancel' } elseif ($btns -contains 'No') { 'No' } else { 'OK' }
    $danger = $Icon -in 'Warning', 'Error' -and $btns.Count -gt 1
    $bx = ($btns | ForEach-Object {
        $isMain = $_ -eq $main
        $bg = if ($isMain) { if ($danger) { " Background='#FF453A' Foreground='#FFFFFF'" } else { " Background='#0071E3' Foreground='#FFFFFF'" } } else { '' }
        "<Button x:Name='B_$_' Content='$_' Style='{DynamicResource Btn}' MinWidth='96' Padding='16,8' Margin='8,0,0,0'$bg/>"
    }) -join ''
    $dlg = [ZdTheme]::Parse(@"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='$(Esc $Title)' Width='480' SizeToContent='Height' WindowStyle='None' AllowsTransparency='True' Background='Transparent'
        ResizeMode='NoResize' ShowInTaskbar='False' FontFamily='Segoe UI' Opacity='0'>
  <Grid Margin='24'>
    <Border CornerRadius='20' Background='#2C2C2F'>
      <Border.Effect><DropShadowEffect BlurRadius='40' ShadowDepth='10' Direction='270' Opacity='0.6' Color='Black'/></Border.Effect>
    </Border>
    <Border x:Name='Card' CornerRadius='20' Background='#2C2C2F' BorderBrush='#48484B' BorderThickness='1' ClipToBounds='True'>
      <Grid>
        <Ellipse Width='300' Height='300' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-120,-150,0,0' IsHitTestVisible='False'>
          <Ellipse.Fill><RadialGradientBrush><GradientStop Color='$($look[1] -replace '^#', '#40')' Offset='0'/><GradientStop Color='$($look[1] -replace '^#', '#00')' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
        </Ellipse>
        <StackPanel Margin='26,24,24,20'>
          <StackPanel Orientation='Horizontal'>
            <Border Width='42' Height='42' CornerRadius='12' Background='$($look[1] -replace '^#', '#33')'>
              <Border.Effect><DropShadowEffect Color='$($look[1])' BlurRadius='18' ShadowDepth='0' Opacity='0.45'/></Border.Effect>
              <TextBlock Text='&#x$('{0:X}' -f $look[0]);' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='19' Foreground='$($look[1])' HorizontalAlignment='Center' VerticalAlignment='Center'/>
            </Border>
            <TextBlock Text='$(Esc $Title)' FontSize='18' FontWeight='SemiBold' Foreground='{DynamicResource Label}' VerticalAlignment='Center' Margin='14,0,0,0' TextWrapping='Wrap' MaxWidth='330'/>
          </StackPanel>
          <ScrollViewer Style='{DynamicResource OverlayScroll}' VerticalScrollBarVisibility='Auto' MaxHeight='440' Margin='0,16,0,0'>
            <TextBlock x:Name='Msg' FontSize='13.5' Foreground='{DynamicResource Label2}' TextWrapping='Wrap' LineHeight='20' LineStackingStrategy='BlockLineHeight'/>
          </ScrollViewer>
          <StackPanel Orientation='Horizontal' HorizontalAlignment='Right' Margin='0,22,0,0'>$bx</StackPanel>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@)
    $dlg.Resources.MergedDictionaries.Add($window.Resources)
    Set-RoundClip $dlg.FindName('Card') 20
    $dlg.FindName('Msg').Text = $Message
    $script:DlgResult = $escape
    foreach ($b in $btns) {
        $btn = $dlg.FindName("B_$b"); $btn.Tag = $b
        $btn.Add_Click({ param($s, $e) $script:DlgResult = $s.Tag; [Windows.Window]::GetWindow($s).Close() })
    }
    $script:DlgMain = $main; $script:DlgEsc = $escape
    $dlg.Add_KeyDown({ param($s, $e)
        if ($e.Key -eq 'Escape') { $script:DlgResult = $script:DlgEsc; $s.Close() }
        elseif ($e.Key -eq 'Return') { $script:DlgResult = $script:DlgMain; $s.Close() }
    })
    $dlg.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch {} })
    $dlg.Add_Loaded({ param($s, $e)
        $s.FindName("B_$script:DlgMain").Focus() | Out-Null
        if ($script:Anim) {
            $s.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation 0, 1, ([Windows.Duration][TimeSpan]::FromMilliseconds(160))))
            $c = $s.FindName('Card'); $tt = New-Object Windows.Media.ScaleTransform 0.96, 0.96; $c.RenderTransformOrigin = '0.5,0.5'; $c.RenderTransform = $tt
            $a = New-Object Windows.Media.Animation.DoubleAnimation 0.96, 1, ([Windows.Duration][TimeSpan]::FromMilliseconds(220)); $a.EasingFunction = New-Ease
            $tt.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $a); $tt.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
        } else { $s.Opacity = 1 }
    })
    if ($window -and $window.IsVisible) { $dlg.Owner = $window; $dlg.WindowStartupLocation = 'CenterOwner' } else { $dlg.WindowStartupLocation = 'CenterScreen'; $dlg.Topmost = $true }
    # dim the app behind the question
    $dim = $window -and $window.IsVisible -and $ui.Wizard.Visibility -ne 'Visible'
    if ($dim) { $script:DimPrev = $ui.Wizard.Background; $ui.WizardBody.Visibility = 'Collapsed'; $ui.Wizard.Visibility = 'Visible' }
    try { [void]$dlg.ShowDialog() } finally { if ($dim) { $ui.Wizard.Visibility = 'Collapsed'; $ui.WizardBody.Visibility = 'Visible' } }
    $script:DlgResult
}

# ---------------------------------------------------------------- toast ---
$script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromSeconds(4.5)
$script:ToastTimer.Add_Tick({ $script:ToastTimer.Stop(); Hide-Animated $ui.Toast 220 })
function Show-Toast([string]$msg, [string]$color = '#F5F5F7') {
    $ui.ToastText.Text = $msg
    $k = switch ($color) {
        { $_ -in '#30D158', '#30D158' } { @(0xE73E, '#30D158') }
        { $_ -in '#FF9F0A', '#FF9F0A' } { @(0xE7BA, '#FF9F0A') }
        { $_ -in '#FF453A', '#FF453A' } { @(0xEA39, '#FF453A') }
        { $_ -in '#A1A1A6', '#0A84FF', '#0A84FF', '#A1A1A6' } { @(0xE946, '#0A84FF') }
        default { $null }
    }
    if ($k) { $ui.ToastIcon.Text = [string][char]$k[0]; $ui.ToastIcon.Foreground = [ZdTheme]::Brush($k[1]); $ui.ToastIcon.Visibility = 'Visible' }
    else { $ui.ToastIcon.Visibility = 'Collapsed' }
    $wasHidden = $ui.Toast.Visibility -ne 'Visible'
    $ui.Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $ui.Toast.Opacity = 1
    $ui.Toast.Visibility = 'Visible'
    if ($wasHidden) { Show-Animated $ui.Toast 16 280 }
    $script:ToastTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(4.5, $msg.Length / 16))
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
}

# --------------------------------------------------------------- state ----
# How "potato" a set of graphics values is: 0% = best looking Performance mode, 100% = lowest everything.
# 3D resolution counts most because it is the biggest FPS lever; 50% render or lower counts as fully potato.
function Get-PotatoScore($v) {
    function lvl($key, $max, $default) { $x = $v[$key]; if ($null -eq $x -or "$x" -eq '') { $x = $default }; [Math]::Min(1.0, [Math]::Max(0.0, ($max - [double]$x) / $max)) }
    $res = $v['PotentiallyUpscaledResolutionQuality']; if (-not $res) { $res = $v['sg.ResolutionQuality'] }; if (-not $res) { $res = 100 }
    $lod = [double]$v['NvLod']
    $score = 0.27 * [Math]::Min(1.0, [Math]::Max(0.0, (100 - [double]$res) / 50)) +
             0.09 * (lvl 'sg.ViewDistanceQuality' 3 3) + 0.13 * (lvl 'sg.TextureQuality' 3 3) + 0.13 * (lvl 'MeshQuality' 2 2) +
             0.13 * (lvl 'sg.EffectsQuality' 3 3) + 0.05 * (lvl 'sg.AntiAliasingQuality' 3 3) +
             0.09 * $(if ("$($v['bShowGrass'])" -eq 'False') { 1 } else { 0 }) +
             0.11 * [Math]::Min(1.0, $lod / 120)
    [int][Math]::Round($score * 100)
}
function Get-CurrentPotatoScore {
    if (-not (Test-Path $IniPath)) { return $null }
    $lines = Get-Content $IniPath
    $v = @{}; foreach ($k in $PresetKeys.Keys) { $v[$k] = Get-IniValue $lines $k }
    $v['NvLod'] = if ($null -ne $script:CurrentNvLod) { $script:CurrentNvLod } else { 0 }
    Get-PotatoScore $v
}

# Preview area of a preset card: a big "% potato" score and a chart of what the preset sets.
function Update-PresetPreview($t) {
    $levels = @('Low', 'Medium', 'High', 'Epic')
    $v = $t.Preset
    $score = Get-PotatoScore $v
    $rows = @(
        , @('3D resolution', "$($v['sg.ResolutionQuality'])%", ([int]$v['sg.ResolutionQuality'] / 100))
        , @('View distance', $levels[[int]$v['sg.ViewDistanceQuality']], (([int]$v['sg.ViewDistanceQuality'] + 1) / 4))
        , @('Textures', $levels[[int]$v['sg.TextureQuality']], (([int]$v['sg.TextureQuality'] + 1) / 4))
        , @('Models', @('Low', 'Medium', 'High')[[int]$v['MeshQuality']], (([int]$v['MeshQuality'] + 1) / 3))
        , @('Effects, shadows', $levels[[int]$v['sg.EffectsQuality']], (([int]$v['sg.EffectsQuality'] + 1) / 4))
        , @('Grass', $(if ($v['bShowGrass'] -eq 'True') { 'On' } else { 'Off' }), $(if ($v['bShowGrass'] -eq 'True') { 1 } else { 0.08 }))
        , @('Texture blur', $NvLodLevels[[int]$v['NvLod']], ([double]$v['NvLod'] / 120))
    )
    $r = ($rows | ForEach-Object {
        $w = [int](84 * [Math]::Max([double]0.06, [Math]::Min([double]1, [double]$_[2])))
        "<Grid Margin='0,0,0,5'><Grid.ColumnDefinitions><ColumnDefinition Width='108'/><ColumnDefinition Width='94'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
        "<TextBlock Text='$($_[0])' Foreground='#A1A1A6' FontSize='12'/>" +
        "<Border Grid.Column='1' Height='6' CornerRadius='3' Background='#3A3A3C' VerticalAlignment='Center' Width='84' HorizontalAlignment='Left'><Border Width='$w' Height='6' CornerRadius='3' Background='#8E8E93' HorizontalAlignment='Left'/></Border>" +
        "<TextBlock Grid.Column='2' Text='$($_[1])' Foreground='#D1D1D6' FontSize='12'/></Grid>"
    }) -join ''
    # Score colour: green = very potato, amber = middle, grey = pretty.
    $color = if ($score -ge 70) { '#30D158' } elseif ($score -ge 35) { '#FFD60A' } else { '#8E8E93' }
    $barW = [int](2.6 * [Math]::Max(3, $score))
    $panel = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' CornerRadius='8' Background='#1C1C1E' BorderThickness='0' Padding='14,12'>
  <StackPanel>
    <StackPanel Orientation='Horizontal'>
      <TextBlock Text='$score%' FontSize='30' FontWeight='Bold' Foreground='$color'/>
      <TextBlock Text='potato' FontSize='14' Foreground='#A1A1A6' VerticalAlignment='Bottom' Margin='8,0,0,6'/>
    </StackPanel>
    <Border Height='8' CornerRadius='4' Background='#3A3A3C' Width='260' HorizontalAlignment='Left' Margin='0,4,0,12'>
      <Border Width='$barW' Height='8' CornerRadius='4' Background='$color' HorizontalAlignment='Left'/>
    </Border>
    $r
  </StackPanel>
</Border>
"@)
    $t.PreviewHost.Content = $panel
}

# "Build your own" card: three sliders and a grass switch, with a live potato score.
$BlurValues = @(0, 24, 56, 120)
$BlurNames  = @('Off', 'Soft', 'Smudged', 'Flat')
$ViewNames  = @('Low', 'Medium', 'High', 'Epic')
function Get-BuilderValues {
    $b = $script:Builder
    New-PresetValues ([int]$b.Res.Value) ([int]$b.View.Value) 0 0 0 0 ([bool]$b.Grass.IsChecked) $BlurValues[[int]$b.Blur.Value]
}
function Update-BuilderScore {
    $b = $script:Builder
    $b.ResText.Text = "$([int]$b.Res.Value)%"
    $b.ViewText.Text = $ViewNames[[int]$b.View.Value]
    $b.BlurText.Text = $BlurNames[[int]$b.Blur.Value]
    $score = Get-PotatoScore (Get-BuilderValues)
    $color = if ($score -ge 70) { '#30D158' } elseif ($score -ge 35) { '#FFD60A' } else { '#8E8E93' }
    $brush = [ZdTheme]::Brush($color)
    $b.Score.Text = "$score%"; $b.Score.Foreground = $brush
    $track = if ($b.BarTrack) { $b.BarTrack.Width } else { 260 }
    $w = $track * [Math]::Max(3, $score) / 100
    # animate only from a real width: WPF cannot animate from an unset (NaN) one, and the error stops the app
    if ($script:Anim -and $b.BarTrack -and -not [double]::IsNaN($b.Bar.Width)) { Start-Anim $b.Bar ([Windows.FrameworkElement]::WidthProperty) $null $w 260 } else { $b.Bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null); $b.Bar.Width = $w }
    $b.Bar.Background = $brush
    if ($b.ScoreGlow) { $b.ScoreGlow.Color = $brush.Color }
    if ($b.Verdict) {
        $b.Verdict.Text = if ($score -ge 85) { 'Full potato. Flat and blurry, maximum FPS.' } elseif ($score -ge 70) { 'Very potato. Ugly, very fast, still playable.' } elseif ($score -ge 50) { 'Half potato. A good balance of speed and clarity.' } elseif ($score -ge 35) { 'Light potato. Mostly sharp, a little faster.' } else { 'Barely potato. Close to normal graphics.' }
    }
}
function New-BuilderPanel($t) {
    $panel = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        CornerRadius='8' Background='#1C1C1E' BorderThickness='0' Padding='14,12'>
  <StackPanel>
    <StackPanel Orientation='Horizontal'>
      <TextBlock x:Name='Score' FontSize='30' FontWeight='Bold'/>
      <TextBlock Text='potato' FontSize='14' Foreground='#A1A1A6' VerticalAlignment='Bottom' Margin='8,0,0,6'/>
    </StackPanel>
    <Border Height='8' CornerRadius='4' Background='#3A3A3C' Width='260' HorizontalAlignment='Left' Margin='0,4,0,12'>
      <Border x:Name='Bar' Height='8' CornerRadius='4' HorizontalAlignment='Left'/>
    </Border>
    <Grid Margin='0,0,0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='92'/><ColumnDefinition Width='*'/><ColumnDefinition Width='70'/></Grid.ColumnDefinitions>
      <TextBlock Text='3D resolution' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center'/>
      <Slider x:Name='Res' Grid.Column='1' Minimum='25' Maximum='100' Style='{DynamicResource ZSlider}'/>
      <TextBlock x:Name='ResText' Grid.Column='2' Foreground='#D1D1D6' FontSize='12' Margin='10,0,0,0' VerticalAlignment='Center'/>
    </Grid>
    <Grid Margin='0,0,0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='92'/><ColumnDefinition Width='*'/><ColumnDefinition Width='70'/></Grid.ColumnDefinitions>
      <TextBlock Text='View distance' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center'/>
      <Slider x:Name='View' Grid.Column='1' Minimum='0' Maximum='3' Style='{DynamicResource ZSlider}'/>
      <TextBlock x:Name='ViewText' Grid.Column='2' Foreground='#D1D1D6' FontSize='12' Margin='10,0,0,0' VerticalAlignment='Center'/>
    </Grid>
    <Grid Margin='0,0,0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='92'/><ColumnDefinition Width='*'/><ColumnDefinition Width='70'/></Grid.ColumnDefinitions>
      <TextBlock Text='Texture blur' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center'/>
      <Slider x:Name='Blur' Grid.Column='1' Minimum='0' Maximum='3' Style='{DynamicResource ZSlider}'/>
      <TextBlock x:Name='BlurText' Grid.Column='2' Foreground='#D1D1D6' FontSize='12' Margin='10,0,0,0' VerticalAlignment='Center'/>
    </Grid>
    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width='96'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
      <TextBlock Text='Grass' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center'/>
      <ToggleButton x:Name='Grass' Grid.Column='1' HorizontalAlignment='Left' Style='{DynamicResource Switch}'/>
    </Grid>
  </StackPanel>
</Border>
"@)
    Initialize-Builder $panel
    $panel
}
function Initialize-Builder($panel) {
    $b = @{}
    foreach ($n in 'Score', 'Bar', 'Res', 'ResText', 'View', 'ViewText', 'Blur', 'BlurText', 'Grass', 'BarTrack', 'Verdict', 'ScoreText') { $b[$n] = $panel.FindName($n) }
    if ($b.ScoreText) { $b.ScoreGlow = $b.ScoreText.Effect }
    $script:Builder = $b
    # start from the player's current settings
    $lines = if (Test-Path $IniPath) { Get-Content $IniPath } else { @() }
    $res = Get-IniValue $lines 'PotentiallyUpscaledResolutionQuality'; if (-not $res) { $res = Get-IniValue $lines 'sg.ResolutionQuality' }; $b.Res.Value = if ($res) { [Math]::Max(25, [Math]::Min(100, [int][double]$res)) } else { 100 }
    $view = Get-IniValue $lines 'sg.ViewDistanceQuality'; $b.View.Value = if ($view) { [Math]::Min(3, [int]$view) } else { 3 }
    $lod = if (Test-NvAvailable) { Get-NvLod } else { 0 }
    $b.Blur.Value = [array]::IndexOf($BlurValues, [int]$lod); if ($b.Blur.Value -lt 0) { $b.Blur.Value = 0 }
    if (-not (Test-NvAvailable)) { $b.Blur.IsEnabled = $false }
    $b.Grass.IsChecked = ((Get-IniValue $lines 'bShowGrass') -eq 'True')
    foreach ($n in 'Res', 'View', 'Blur') { $b[$n].Add_ValueChanged({ Update-BuilderScore }) }
    $b.Grass.Add_Click({ Update-BuilderScore })
    Update-BuilderScore
}
# "Build your own" as a dashboard: score and Apply on the left, the controls on a glass panel on the right
function New-PotatoStudio($t) {
    function Ctl([string]$icon, [string]$tint, [string]$label, [string]$name, [string]$min, [string]$max, [string]$hint) {
        "<Border Background='#0DFFFFFF' CornerRadius='14' Padding='14,12' Margin='0,0,0,8'><Grid>" +
        "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
        "<Border Width='36' Height='36' CornerRadius='10' Background='$($tint -replace '^#', '#33')' VerticalAlignment='Top'><TextBlock Text='$icon' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='16' Foreground='$tint' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" +
        "<StackPanel Grid.Column='1' Margin='14,0,0,0'><Grid><TextBlock Text='$label' FontSize='13.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>" +
        "<Border HorizontalAlignment='Right' Background='#1AFFFFFF' CornerRadius='8' Padding='9,1,9,2'><TextBlock x:Name='${name}Text' FontSize='12' FontWeight='SemiBold' Foreground='#FFFFFF'/></Border></Grid>" +
        "<Slider x:Name='$name' Minimum='$min' Maximum='$max' Style='{DynamicResource ZSlider}' Margin='0,8,0,0'/>" +
        "<TextBlock Text='$hint' FontSize='11.5' Foreground='#8A8A94' Margin='0,2,0,0'/></StackPanel></Grid></Border>"
    }
    $nv = if (Test-NvAvailable) { 'NVIDIA driver setting: blurs textures into flat colours' } else { 'Needs an NVIDIA graphics card' }
    $root = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Width='1058' Height='430' CornerRadius='26' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Margin='0,0,16,22' HorizontalAlignment='Left'>
  <Grid>
    <Ellipse Width='620' Height='620' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-200,-300,0,0' IsHitTestVisible='False'>
      <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#4DFFD60A' Offset='0'/><GradientStop Color='#00FFD60A' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
    </Ellipse>
    <Ellipse Width='700' Height='700' HorizontalAlignment='Right' VerticalAlignment='Bottom' Margin='0,0,-240,-360' IsHitTestVisible='False'>
      <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#4430D158' Offset='0'/><GradientStop Color='#0030D158' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
    </Ellipse>
    <Ellipse Width='380' Height='380' HorizontalAlignment='Center' VerticalAlignment='Bottom' Margin='0,0,300,-200' IsHitTestVisible='False'>
      <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#33FF9F0A' Offset='0'/><GradientStop Color='#00FF9F0A' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
    </Ellipse>
    <Grid Margin='40,34,22,22'>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='440'/></Grid.ColumnDefinitions>
      <DockPanel Margin='0,0,28,0'>
        <StackPanel DockPanel.Dock='Top'>
          <StackPanel Orientation='Horizontal'>
            <TextBlock Text='&#xE70F;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#FFD60A' FontSize='13' VerticalAlignment='Center' Margin='0,1,8,0'/>
            <TextBlock Text='CUSTOM POTATO' FontSize='12' FontWeight='Bold' Foreground='#C9C9D1'/>
          </StackPanel>
          <StackPanel Orientation='Horizontal' Margin='0,6,0,0' x:Name='ScoreText'>
            <StackPanel.Effect><DropShadowEffect Color='#FFD60A' BlurRadius='30' ShadowDepth='0' Opacity='0.55'/></StackPanel.Effect>
            <TextBlock x:Name='Score' FontSize='88' FontWeight='Black' FontFamily='Segoe UI Black, Segoe UI' Typography.NumeralAlignment='Tabular'/>
            <TextBlock Text='potato' FontSize='20' Foreground='#B8B8C2' VerticalAlignment='Bottom' Margin='10,0,0,22'/>
          </StackPanel>
          <TextBlock x:Name='Verdict' FontSize='14' Foreground='#E6E6EC' Margin='0,-4,0,0'/>
          <Border x:Name='BarTrack' Width='420' Height='10' CornerRadius='5' Background='#1FFFFFFF' HorizontalAlignment='Left' Margin='0,18,0,0'>
            <Border x:Name='Bar' Height='10' CornerRadius='5' HorizontalAlignment='Left'/>
          </Border>
          <TextBlock Text='Everything else in Fortnite is set to low. Fortnite must be closed.' FontSize='12.5' Foreground='#9A9AA5' Margin='0,14,0,0' TextWrapping='Wrap'/>
        </StackPanel>
        <StackPanel DockPanel.Dock='Bottom' Orientation='Horizontal' VerticalAlignment='Bottom'>
          <Button x:Name='ActionBtn' Height='58' Width='240' Cursor='Hand'>
            <Button.Template>
              <ControlTemplate TargetType='Button'>
                <Border x:Name='B' CornerRadius='29'>
                  <Border.Background><LinearGradientBrush StartPoint='0,0' EndPoint='1,1'><GradientStop Color='#FFE14D' Offset='0'/><GradientStop Color='#7EDB5A' Offset='1'/></LinearGradientBrush></Border.Background>
                  <Border.Effect><DropShadowEffect Color='#C8E04A' BlurRadius='32' ShadowDepth='0' Opacity='0.55'/></Border.Effect>
                  <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='B' Property='Opacity' Value='0.9'/></Trigger>
                  <Trigger Property='IsPressed' Value='True'><Setter TargetName='B' Property='Opacity' Value='0.78'/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
            <StackPanel Orientation='Horizontal'>
              <TextBlock Text='&#xE768;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='15' Foreground='#1E2400' VerticalAlignment='Center' Margin='0,2,10,0'/>
              <TextBlock Text='Apply to Fortnite' FontSize='18' FontWeight='SemiBold' Foreground='#1E2400'/>
            </StackPanel>
          </Button>
        </StackPanel>
      </DockPanel>
      <Border Grid.Column='1' CornerRadius='20' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='16,16,16,8'>
        <StackPanel>
          $(Ctl '&#xE7F4;' '#0A84FF' '3D resolution' 'Res' '25' '100' 'Lower is blurrier and much faster')
          $(Ctl '&#xE7B3;' '#BF5AF2' 'View distance' 'View' '0' '3' 'How far away things are drawn')
          $(Ctl '&#xE790;' '#FFD60A' 'Texture blur' 'Blur' '0' '3' $nv)
          <Border Background='#0DFFFFFF' CornerRadius='14' Padding='14,11'>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
              <Border Width='36' Height='36' CornerRadius='10' Background='#3330D158'><TextBlock Text='&#xE913;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='16' Foreground='#30D158' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>
              <StackPanel Grid.Column='1' Margin='14,0,0,0' VerticalAlignment='Center'>
                <TextBlock Text='Grass' FontSize='13.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>
                <TextBlock Text='Off hides players less and saves a little FPS' FontSize='11.5' Foreground='#8A8A94'/>
              </StackPanel>
              <ToggleButton x:Name='Grass' Grid.Column='2' Style='{DynamicResource Switch}' VerticalAlignment='Center'/>
            </Grid>
          </Border>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Border>
"@)
    Set-RoundClip $root 26
    $t.Card = $root
    $root.Tag = $t
    Initialize-Builder $root
    $btn = $root.FindName('ActionBtn'); $btn.Tag = $t; $t.ActionBtn = $btn
    $btn.Add_Click({ param($s, $e) Invoke-Action $s.Tag $s })
    $root
}
function Invoke-Builder($t) {
    $fake = @{ Title = 'Custom potato'; Preset = (Get-BuilderValues) }
    Invoke-Preset $fake
}

# Game-session card: one switch per app, saved between launches.
function New-SessionPanel($t) {
    $prefs = Get-SessionPrefs
    $shown = @($SessionApps | Where-Object { Test-SessionAppPresent $_ })
    $rows = ($shown | ForEach-Object {
        "<Grid Margin='0,0,0,6'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<TextBlock Text='$(Esc $_.Name)' Foreground='#D1D1D6' FontSize='12' VerticalAlignment='Center'/>" +
        "<ToggleButton x:Name='S_$($_.Key)' Grid.Column='1' Style='{DynamicResource Switch}' Width='34' Height='18'/></Grid>"
    }) -join ''
    $panel = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        CornerRadius='8' Background='#1C1C1E' BorderThickness='0' Padding='14,10,6,10'>
  <ScrollViewer Style='{DynamicResource OverlayScroll}' VerticalScrollBarVisibility='Auto' MaxHeight='238' Padding='0,0,8,0'>
    <StackPanel>$rows</StackPanel>
  </ScrollViewer>
</Border>
"@)
    foreach ($a in $shown) {
        $sw = $panel.FindName("S_$($a.Key)")
        $sw.IsChecked = [bool]$prefs[$a.Key]; $sw.Tag = $a.Key
        $sw.Add_Click({
            param($s, $e)
            $p = Get-SessionPrefs; $p[$s.Tag] = [bool]$s.IsChecked
            $script:Backup.Custom['sessionprefs'] = $p; Save-Backup
        })
    }
    $panel
}
function New-GameModePanel($t) {
    $prefs = Get-GameModePrefs
    $rows = ($GameModeSteps.Keys | ForEach-Object {
        "<Grid Margin='0,0,0,6'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<TextBlock Text='$(Esc $GameModeSteps[$_].Name)' Foreground='#D1D1D6' FontSize='12' VerticalAlignment='Center'/>" +
        "<ToggleButton x:Name='G_$_' Grid.Column='1' Style='{DynamicResource Switch}' Width='34' Height='18'/></Grid>"
    }) -join ''
    $panel = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        CornerRadius='8' Background='#1C1C1E' BorderThickness='0' Padding='14,10'>
  <StackPanel>$rows</StackPanel>
</Border>
"@)
    foreach ($k in $GameModeSteps.Keys) {
        $sw = $panel.FindName("G_$k"); $sw.IsChecked = [bool]$prefs[$k]; $sw.Tag = $k
        $sw.Add_Click({
            param($s, $e)
            $p = Get-GameModePrefs; $p[$s.Tag] = [bool]$s.IsChecked
            $script:Backup.Custom['gamemodeprefs'] = $p; Save-Backup
        })
    }
    $panel
}
function Update-GameModeUi {
    if ($script:GmUi) { Update-GameModePage }
    $on = Test-ZDGameMode
    $mint = [ZdTheme]::Brush('#30D158')
    $ui.GmSwitch.IsChecked = $on
    $ui.GmStatus.Text = if ($on) { if (Test-FortniteRunning) { 'On · Fortnite running' } else { 'On' } } elseif ((Get-GameModePrefs).auto) { 'Auto-starts with Fortnite' } else { 'Off' }
    $ui.GmStatus.Foreground = if ($on) { $mint } else { [ZdTheme]::Brush('#A1A1A6') }
    $ui.GmPanel.ClearValue([Windows.Controls.Border]::BorderBrushProperty)
    $t = $Tweaks | Where-Object { $_.Id -eq 'gm-main' } | Select-Object -First 1
    if ($t -and $t.ActionBtn) {
        $t.ActionBtn.Content = if ($on) { 'Turn off' } else { 'Turn on' }
        $t.ActionBtn.Background = [ZdTheme]::Brush($(if ($on) { '#2D4635' } else { '#0071E3' }))
        $t.ActionBtn.Foreground = [ZdTheme]::Brush($(if ($on) { '#30D158' } else { '#FFFFFF' }))
    }
}

function Update-SessionCard {
    $t = $Tweaks | Where-Object { $_.Id -eq 'gamesession' } | Select-Object -First 1
    if (-not $t -or -not $t.ActionBtn) { return }
    $on = Test-GameSession
    $t.ActionBtn.Content = if ($on) { 'End session' } else { 'Start session' }
    $t.ActionBtn.Background = [ZdTheme]::Brush($(if ($on) { '#4E3E28' } else { '#3A3A3C' }))
    $t.ActionBtn.Foreground = [ZdTheme]::Brush($(if ($on) { '#FF9F0A' } else { '#F5F5F7' }))
}

function Update-Card($t, $Pre) {
    if ($t.Preset) {
        $pillEl = $t.Card.FindName('ActivePill')
        if ($pillEl) { $pillEl.Visibility = if (Test-Preset $t) { 'Visible' } else { 'Collapsed' } }
        return
    }
    if (-not $t.Toggle) { return }
    $state = if ($Pre) { $Pre.State } else { Invoke-TweakTest $t }
    $t.State = $state
    # a card for hardware or software this PC does not have is hidden rather than shown greyed out
    $reqOk = if ($Pre) { $Pre.Req } elseif ($t.Requires -and $null -eq $state) { & $t.Requires } else { $true }
    $t.Hidden = [bool]($t.ForceHidden -or ($t.Requires -and $null -eq $state -and -not $reqOk))
    if ($t.Hidden) { $t.Card.Visibility = 'Collapsed' }
    if ($null -eq $state) {
        $t.Toggle.IsEnabled = $false
        $t.Toggle.IsChecked = $false
        $t.Toggle.ToolTip = 'Not available on this PC'
    } else {
        $t.Toggle.IsEnabled = $true
        $t.Toggle.IsChecked = $state
        $t.Toggle.ToolTip = $null
    }
}

function Update-Summary {
    $toggles = @($Tweaks | Where-Object { $_.Toggle -and $null -ne $_.State })
    $on = @($toggles | Where-Object { $_.State }).Count
    $ui.ActiveCount.Text = "$on / $($toggles.Count)"
    $ui.ActiveBar.Width = if ($toggles.Count) { 170 * $on / $toggles.Count } else { 0 }
    $plan = Get-ActivePowerScheme
    $fn = if ($script:FortniteExe) { 'Fortnite found' } else { 'Fortnite not found' }
    $run = if (Test-FortniteRunning) { '  ·  Fortnite is running (close it to change game settings)' } else { '' }
    $ui.StatusLine.Text = "$fn  ·  Power plan: $($plan.Name)$run"
    $ui.RestoreAll.IsEnabled = ($script:Backup.Registry.Count -gt 0 -or $script:Backup.Custom.Count -gt 0)
    Update-RestartBar
    if ($script:CurrentCat) { Update-Filter }
    if ($script:HomeUi) { Update-HomePage }
    if ($script:ActiveUi -and $script:CurrentCat.Name -eq 'Active') { Update-ActivePage }
}

function Update-RestartBar {
    Update-PendingLive
    $n = @($script:Pending.Items).Count
    if (-not $n -or $script:RestartSnoozed) { $ui.RestartBar.Visibility = 'Collapsed'; return }
    $restart = $script:Pending.Kind -eq 'restart'
    $what = if ($n -eq 1) { '1 change' } else { "$n changes" }
    $ui.RestartTitle.Text = if ($restart) { "Restart needed for $what to take effect" } else { "Sign out and back in for $what to take effect" }
    $boot = try { [datetime]$script:BootId } catch { $null }
    $when = @($script:Pending.Items | ForEach-Object { try { [datetime]$script:PendingAdded[$_] } catch {} } | Sort-Object | Select-Object -First 1)
    $fmt = { param($d) if ($d.Date -eq (Get-Date).Date) { "today $($d.ToString('HH:mm'))" } else { $d.ToString('d MMM HH:mm') } }
    $ui.RestartText.Text = ($script:Pending.Items -join '  ·  ') +
        $(if ($boot) { "   —   Windows last restarted $(& $fmt $boot)$(if ($when) { ", these were changed $(& $fmt $when[0])" }). $(if ($restart) { 'Use Restart (not only closing ZeroDelay).' } else { 'Signing out or restarting both work.' })" } else { '' })
    $ui.RestartText.TextTrimming = 'None'; $ui.RestartText.TextWrapping = 'Wrap'
    $ui.RestartNow.Content = if ($restart) { 'Restart now' } else { 'Sign out now' }
    $ui.RestartLater.Content = if ($restart) { 'Restart later' } else { 'Later' }
    if ($ui.RestartBar.Visibility -ne 'Visible') { $ui.RestartBar.Visibility = 'Visible'; Show-Animated $ui.RestartBar -8 260 }
}

function Update-All {
    Clear-ReadCache
    $script:CurrentNvLod = if (Test-NvAvailable) { Get-NvLod } else { $null }
    foreach ($t in $Tweaks) { Update-Card $t }; Update-Summary
}

function Switch-Tweak($t, [bool]$enable) {
    $window.Cursor = [Windows.Input.Cursors]::Wait
    Clear-ReadCache
    try {
        if ($enable) { Invoke-TweakOn $t } else { Invoke-TweakOff $t }
        $note = switch ($t.Badge) { 'restart' { ' Restart your PC to finish.' } 'signout' { ' Sign out and back in to finish.' } default { '' } }
        Show-Toast ("$($t.Title): " + $(if ($enable) { 'on.' } else { 'restored.' }) + $note) '#30D158'
    } catch {
        Show-Toast "$($t.Title): $($_.Exception.Message)" '#FF9F0A'
    }
    Update-Card $t
    Update-Summary
    $window.Cursor = $null
}

function Invoke-Action($t, $btn) {
    if ($t.Id -eq 'ping') { Start-PingTest $btn; return }
    try { Show-Toast (& $t.Run) '#30D158' } catch { Show-Toast $_.Exception.Message '#FF9F0A' }
}

# ---------------------------------------------------------------- ping ----
$PingHosts = @(
    @{ Name = 'NA East';     Host = 'ping-nae.ds.on.epicgames.com' }
    @{ Name = 'NA Central';  Host = 'ping-nac.ds.on.epicgames.com' }
    @{ Name = 'NA West';     Host = 'ping-naw.ds.on.epicgames.com' }
    @{ Name = 'Europe';      Host = 'ping-eu.ds.on.epicgames.com' }
    @{ Name = 'Oceania';     Host = 'ping-oce.ds.on.epicgames.com' }
    @{ Name = 'Brazil';      Host = 'ping-br.ds.on.epicgames.com' }
    @{ Name = 'Asia';        Host = 'ping-asia.ds.on.epicgames.com' }
    @{ Name = 'Middle East'; Host = 'ping-me.ds.on.epicgames.com' }
)
$script:PingTimer = New-Object Windows.Threading.DispatcherTimer
$script:PingTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:PingTimer.Add_Tick({
    if ($script:PingJob.State -in 'Running', 'NotStarted') { return }
    $script:PingTimer.Stop()
    $res = @(Receive-Job $script:PingJob); Remove-Job $script:PingJob -Force
    $best = $res | Where-Object { $_.Ms } | Sort-Object Ms | Select-Object -First 1
    $lines = foreach ($r in $res) {
        $ms = if ($r.Ms) { "$($r.Ms) ms" } else { 'no reply' }
        $mark = if ($best -and $r.Name -eq $best.Name) { '  < best' } else { '' }
        '{0,-12}{1,9}{2}' -f $r.Name, $ms, $mark
    }
    # two columns to fit the card
    $half = [Math]::Ceiling($lines.Count / 2)
    $rows = for ($i = 0; $i -lt $half; $i++) { '{0,-30}{1}' -f $lines[$i], $(if ($i + $half -lt $lines.Count) { $lines[$i + $half] } else { '' }) }
    $script:PingText.Text = $rows -join "`n"
    $script:PingBtn.IsEnabled = $true
    $script:PingBtn.Content = 'Test ping'
})
function Start-PingTest($btn) {
    $script:PingBtn = $btn
    $btn.IsEnabled = $false; $btn.Content = 'Testing...'
    $script:PingText.Text = 'Pinging Fortnite regions...'
    $script:PingJob = Start-Job -ArgumentList (, $PingHosts) -ScriptBlock {
        param($list)
        foreach ($h in $list) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $times = @()
            1..4 | ForEach-Object { try { $r = $p.Send($h.Host, 1000); if ($r.Status -eq 'Success') { $times += $r.RoundtripTime } } catch {} }
            [pscustomobject]@{ Name = $h.Name; Ms = $(if ($times.Count) { [int](($times | Measure-Object -Average).Average) } else { $null }) }
        }
    }
    $script:PingTimer.Start()
}

# ---------------------------------------------------------- navigation ----
$Categories = @(
    @{ Name = 'Home';       Icon = [char]0xE80F; Title = 'Home'; Page = 'Home' }
    @{ Name = 'All';        Icon = [char]0xE80F; Title = 'All optimizations' }
    @{ Name = 'Active';     Icon = [char]0xE73E; Title = 'Active tweaks'; Page = 'Active' }
    @{ Name = 'Latency';    Icon = [char]0xE916; Title = 'Latency & delay'
       Note = 'Only the tweaks that change input delay, frame time or ping. Green icons mark them in every tab.' }
    @{ Name = 'GameMode';   Icon = [char]0xE768; Title = 'Game Mode'; Page = 'GameMode' }
    @{ Name = 'Events';     Icon = [char]0xE7C1; Title = 'Tournaments'; Page = 'Events' }
    @{ Name = 'Potato';     Icon = [char]0xE7F4; Title = 'Potato graphics'
       Note = 'Ugly but fast. Performance mode, low mesh and lower 3D resolution give the biggest gains; Fortnite must be closed to apply.' }
    @{ Name = 'Gtx1080Ti';  Icon = [char]0xE7F4; Title = 'GTX 1080 Ti'; Requires = { Test-Gtx1080Ti }
       Note = 'Everything that matters for a GTX 1080 Ti in one place. This 2017 card has no DLSS, frame generation or RTX features, and is now on a security-only driver branch, so some general advice does not apply to it.' }
    @{ Name = 'Creator';    Icon = [char]0xE714; Title = 'Creator'; Requires = { Test-CreatorPc }
       Note = 'For Premiere Pro, After Effects, Photoshop, Media Encoder and OBS. Close the app before you flip a switch: Adobe apps and OBS rewrite their settings when they close.' }
    @{ Name = 'Fortnite';   Icon = [char]0xE7FC; Title = 'Fortnite' }
    @{ Name = 'System';     Icon = [char]0xE7F8; Title = 'System' }
    @{ Name = 'Power';      Icon = [char]0xE945; Title = 'Power & CPU' }
    @{ Name = 'Graphics';   Icon = [char]0xE7F4; Title = 'Graphics' }
    @{ Name = 'Input';      Icon = [char]0xE962; Title = 'Input & audio' }
    @{ Name = 'Network';    Icon = [char]0xE839; Title = 'Network' }
    @{ Name = 'Background'; Icon = [char]0xE895; Title = 'Background & privacy' }
    @{ Name = 'Services';   Icon = [char]0xE912; Title = 'Services & tasks' }
    @{ Name = 'Vendor';     Icon = [char]0xE74C; Title = 'Vendor software'
       Note = 'Services from PC, motherboard and peripheral makers that are known stutter sources. Only the ones installed on this PC are shown; each card says what stops working.' }
    @{ Name = 'Storage';    Icon = [char]0xEDA2; Title = 'Storage & updates' }
    @{ Name = 'Visuals';    Icon = [char]0xE790; Title = 'Desktop visuals' }
    @{ Name = 'Startup';    Icon = [char]0xE768; Title = 'Startup apps' }
    @{ Name = 'Repair';     Icon = [char]0xE90F; Title = 'Repair old tweaks' }
    @{ Name = 'ThisPC';     Icon = [char]0xE7F8; Title = 'This PC'; Page = 'ThisPC'; Section = 'TOOLS'
       Note = 'Everything ZeroDelay found on this PC: hardware, Windows, drivers and installed apps, and how it adapted its tweaks to them.' }
    @{ Name = 'Sync';       Icon = [char]0xE7F4; Title = 'FreeSync'; Page = 'Sync'; Requires = { @(Get-VrrMonitors).Count -gt 0 }
       Note = 'Variable refresh rate: the monitor waits for each frame instead of the other way round, so no tearing and no V-Sync delay.' }
    @{ Name = 'Nvidia';     Icon = [char]0xE7F4; Title = 'NVIDIA'; Page = 'Nvidia'
       Note = 'G-SYNC, V-Sync and frame cap setup, NVIDIA App features that cost FPS, and your driver.' }
    @{ Name = 'Health';     Icon = [char]0xE95E; Title = 'Health check'; Page = 'Health'
       Note = 'One scan for the problems that cost you the most. Fix them one by one or all at once.' }
    @{ Name = 'Benchmark';  Icon = [char]0xE9D9; Title = 'Benchmark'; Page = 'Benchmark'
       Note = 'Measure real FPS, 1% lows and latency in Fortnite, then compare before and after a change.' }
    @{ Name = 'Matches';    Icon = [char]0xE7FC; Title = 'Match reports'; Page = 'Matches'
       Note = 'After each Fortnite session: stutters and what was busy at that moment, GPU heat, background apps and memory.' }
    @{ Name = 'Debloat';    Icon = [char]0xE74D; Title = 'Debloat'; Page = 'Debloat'
       Note = 'Preinstalled apps and trials most people never use. You pick what goes; nothing is removed on its own.' }
    @{ Name = 'Booster';    Icon = [char]0xE9F5; Title = 'Ping booster'; Page = 'Booster'; Requires = { @(Get-InstalledBoosters).Count -gt 0 }
       Note = 'Your ping booster is allowed to change settings. ZeroDelay keeps whatever it changes and shows you what that was.' }
    @{ Name = 'Ping';       Icon = [char]0xE839; Title = 'Ping monitor'; Page = 'Ping'
       Note = 'Live ping, jitter and packet loss to a Fortnite region. Spikes are logged with what was busy at the time.' }
    @{ Name = 'Sens';       Icon = [char]0xE962; Title = 'Sensitivity'; Page = 'Sens'
       Note = 'eDPI and cm/360 for Fortnite, and keeping the same aim when you change DPI.' }
    @{ Name = 'Mouse';      Icon = [char]0xEC4A; Title = 'Mouse test'; Page = 'Mouse'
       Note = 'Measures how often your mouse really reports to the PC (its polling rate) and whether that rate is steady.' }
    @{ Name = 'Profiles';   Icon = [char]0xE8F1; Title = 'Profiles'; Page = 'Profiles'
       Note = 'Save your whole setup, switch between setups, and share one with a code.' }
    @{ Name = 'History';    Icon = [char]0xE81C; Title = 'History'; Page = 'History'
       Note = 'Everything ZeroDelay changed, newest first. Undo any single change.' }
    @{ Name = 'Apps';       Icon = [char]0xE71D; Title = 'Uninstall apps'; Page = 'Apps'
       Note = 'Remove programs and Microsoft Store apps you do not use. Fewer apps means fewer things starting and running in the background.' }
    @{ Name = 'Clean';      Icon = [char]0xE74D; Title = 'Clean up files'; Page = 'Clean'
       Note = 'Free disk space: temporary files, old update downloads, crash dumps and caches. You see the size of everything before anything is deleted.' }
    @{ Name = 'Memory';     Icon = [char]0xE950; Title = 'Memory (RAM)'; Page = 'Memory'
       Note = 'What is using your RAM right now, which apps to close, and a standby-memory clear for the PCs that need it.' }
    @{ Name = 'Settings';   Icon = [char]0xE713; Title = 'Settings'; Page = 'Settings' }
)
function New-HistoryPage {
    $root = New-Object Windows.Controls.StackPanel
    $script:HistoryList = $root
    $script:PageRefresh['History'] = { Update-HistoryPage }
    Update-HistoryPage
    New-PageScroll $root
}
function Update-HistoryPage {
    $root = $script:HistoryList; if (-not $root) { return }
    $root.Children.Clear()
    $items = @(Get-History)
    if (-not $items.Count) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'Nothing changed yet. Every switch, preset and Game Mode change will show up here.'
        $tb.Foreground = ConvertTo-Brush '#A1A1A6'; [void]$root.Children.Add($tb); return
    }
    foreach ($h in $items | Select-Object -First 150) {
        $when = try { ([datetime]$h.Time).ToString('dd MMM  HH:mm') } catch { $h.Time }
        $color = switch ("$(@($h.Action)[0])") { 'on' { '#30D158' } 'off' { '#FF9F0A' } default { '#0A84FF' } }
        $word = switch ("$(@($h.Action)[0])") { 'on' { 'Turned on' } 'off' { 'Turned off' } 'preset' { 'Applied' } 'gamemode' { 'Game Mode' } default { $h.Action } }
        $row = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='16,10' Margin='0,0,0,8'>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width='120'/><ColumnDefinition Width='110'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <TextBlock Text='$(Esc $when)' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center'/>
    <TextBlock Grid.Column='1' Text='$(Esc $word)' Foreground='$color' FontSize='12' FontWeight='SemiBold' VerticalAlignment='Center'/>
    <TextBlock Grid.Column='2' Text='$(Esc $h.Title)' FontSize='13' VerticalAlignment='Center' TextTrimming='CharacterEllipsis'/>
    <Button x:Name='Undo' Grid.Column='3' Content='Undo' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12'/>
  </Grid>
</Border>
"@)
        $btn = $row.FindName('Undo')
        $tw = if ($h.Id) { $Tweaks | Where-Object { $_.Id -eq $h.Id } | Select-Object -First 1 } else { $null }
        if (-not $tw -or $h.Action -notin 'on', 'off') { $btn.Visibility = 'Hidden' }
        else {
            $btn.Tag = @{ T = $tw; Action = $h.Action }
            $btn.Add_Click({
                param($s, $e)
                $x = $s.Tag
                try {
                    if ($x.Action -eq 'on') { Invoke-TweakOff $x.T } else { Invoke-TweakOn $x.T }
                    Update-Card $x.T; Update-Summary
                    Show-Toast "Undone: $($x.T.Title)" '#30D158'
                } catch { Show-Toast "$($x.T.Title): $($_.Exception.Message)" '#FF9F0A' }
                Update-HistoryPage
            })
        }
        [void]$root.Children.Add($row)
    }
}

# =============================================================== Health check
# Each check returns $null (fine) or an issue: Sev (3 high, 2 medium, 1 low), Title, Detail, and either Tweak (card id to
# switch on), Fix (scriptblock returning a message) or neither (advice only).
function Get-HealthIssues {
    $issues = New-Object System.Collections.ArrayList
    function Add-Issue([int]$Sev, [string]$Title, [string]$Detail, [string]$Tweak, [scriptblock]$Fix, [string]$FixLabel = 'Fix') {
        [void]$issues.Add([pscustomobject]@{ Sev = $Sev; Title = $Title; Detail = $Detail; Tweak = $Tweak; Fix = $Fix; FixLabel = $FixLabel })
    }
    function St([string]$Id) { $t = $Tweaks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1; if ($t) { Invoke-TweakTest $t } else { $null } }

    $lines = if (Test-Path $IniPath) { Get-Content $IniPath } else { @() }
    # --- aim
    if ((St 'mouse') -eq $false) { Add-Issue 3 'Windows mouse acceleration is on' 'The same hand movement gives different aim depending on speed. Every pro turns this off.' 'mouse' }
    if ((St 'fnmouse') -eq $false) { Add-Issue 3 'Fortnite mouse acceleration is on' 'Fortnite has its own acceleration on top of Windows. Needs Fortnite closed to fix.' 'fnmouse' }
    # --- frames
    $cap = [double](Get-IniValue $lines 'FrameRateLimit'); $vrr = Get-VrrCap
    $hz = (Get-Displays | Where-Object Discrete | Measure-Object Hz -Maximum).Maximum
    $vrrOn = Test-VrrActive
    if ($vrrOn -eq $false -and $vrr -and $hz -and $cap -ge $vrr -and $cap -le $hz) {
        Add-Issue 2 "FPS cap is $([int]$cap) on a $hz Hz monitor without G-SYNC" 'With G-SYNC off, capping right at your refresh rate adds a little delay. Either turn G-SYNC on (see the NVIDIA page) or remove the cap. Uncapped gives the lowest delay, but frame pacing can be less even.' $null `
            { Assert-IniWritable; $l = Get-Content $IniPath; Set-Content $IniPath (Set-IniValue $l 'FrameRateLimit' '0.000000') -Encoding UTF8; 'FPS cap removed (unlimited).' } 'Remove cap'
    }
    if ($vrrOn -ne $false -and $vrr -and $hz -and ($cap -eq 0 -or $cap -gt $vrr + 1)) {
        Add-Issue 3 "FPS cap is $(if ($cap -eq 0) { 'unlimited' } else { [int]$cap }) on a $hz Hz monitor" "Above $vrr FPS G-SYNC/FreeSync switches off and frames queue up. $vrr keeps it engaged." $null `
            { $t = $Tweaks | Where-Object { $_.Id -eq 'vrrcap' }; & $t.Run } "Set $vrr FPS"
    }
    if ((St 'vsync') -eq $false) { Add-Issue 3 'V-Sync is on in Fortnite' 'V-Sync holds every frame for the next refresh and adds a lot of delay.' 'vsync' }
    if ((Get-IniValue $lines 'LatencyTweak2') -ne '2' -and (Test-NvAvailable)) { Add-Issue 3 'NVIDIA Reflex is not on "On + Boost"' 'Reflex is the biggest single latency setting for NVIDIA cards.' 'reflex' }
    if ((Get-IniValue $lines 'bEnableDLSSFrameGeneration') -eq 'True') { Add-Issue 2 'Frame generation is on' 'Generated frames look smoother but add input delay.' 'framegen' }
    if ((St 'refreshrate') -eq $false) { Add-Issue 3 'Your main monitor is below its highest refresh rate' 'Windows often leaves high-Hz monitors at 60 Hz.' 'refreshrate' }
    $d = Get-Displays
    $igpu = @($d | Where-Object { -not $_.Discrete }); $dgpu = @($d | Where-Object Discrete)
    if ($igpu.Count -and $dgpu.Count) {
        Add-Issue 1 "$($igpu.Count) monitor(s) run on the CPU graphics" "$(($igpu | ForEach-Object { "$($_.Monitor) ($($_.Hz) Hz)" }) -join ', ') is plugged into the motherboard. Only play on monitors plugged into the graphics card." $null $null
    }
    # --- power
    if ((Get-ActivePowerScheme).Name -notmatch 'ZeroDelay|Ultimate|High performance') { Add-Issue 2 'Power plan is not a performance plan' 'Power saving lets the CPU drop clocks between frames.' 'zdplan' }
    $powerNames = @{ minstate = 'CPU can drop to low clocks between frames'; usbsuspend = 'USB ports can go to sleep'; usb3lpm = 'USB 3 power-saving is on'; usbhub = 'USB hubs can go to sleep' }
    foreach ($id in 'minstate', 'usbsuspend', 'usb3lpm', 'usbhub') {
        if ((St $id) -eq $false) { Add-Issue 2 $powerNames[$id] 'Your power plan still saves power here. Another tool (often ExitLag) may have changed it.' $id }
    }
    if ((St 'idleon') -eq $false) { Add-Issue 2 'CPU idle states are switched off' 'This stops your CPU boosting to full clock on the busy cores.' 'idleon' }
    # --- leftovers
    foreach ($id in 'nvpreempt', 'kernelsched', 'prefetchon') {
        if ((St $id) -eq $false) { $tw = $Tweaks | Where-Object { $_.Id -eq $id }; Add-Issue 2 "Old tweak to repair: $($tw.Title)" $tw.Desc $id }
    }
    if ((St 'dvr') -eq $false) { Add-Issue 2 'Game Bar background recording is on' 'Background capture costs GPU time and causes frame spikes.' 'dvr' }
    # --- memory: speed (XMP/EXPO) and channels
    $ram = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Where-Object { $_.Capacity -gt 0 })
    $lpddr = ($ram | Where-Object { $_.SMBIOSMemoryType -in 30, 35 }).Count -gt 0   # soldered laptop RAM: no profile, always multi-channel
    if ($ram.Count -and -not $lpddr) {
        $run = ($ram | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
        $rated = ($ram | Measure-Object Speed -Maximum).Maximum
        $isDdr5 = ($ram | Where-Object { $_.SMBIOSMemoryType -eq 34 }).Count -gt 0
        $jedec = if ($isDdr5) { 4800, 5200, 5600 } else { 2133, 2400, 2666, 2933 }
        if ($run -and $rated -and $run -lt $rated) {
            Add-Issue 3 "RAM runs at $run MT/s but is rated for $rated MT/s" 'Motherboards start RAM at a slow safe speed until you turn on its profile. Restart, enter the BIOS (Del or F2 while booting) and enable XMP (Intel) or EXPO / DOCP (AMD), then save. Fortnite is CPU-bound at high FPS, and memory speed directly raises 1% lows.' $null $null
        } elseif ($run -and $jedec -contains $run) {
            Add-Issue 2 "RAM runs at $run MT/s, a slow default speed" 'If your kit is rated higher (most gaming kits are), enable XMP (Intel) or EXPO / DOCP (AMD) in the BIOS to run it at its rated speed. That directly raises 1% lows in Fortnite.' $null $null
        }
        if ($ram.Count -eq 1) {
            Add-Issue 3 'Only one RAM stick is installed' 'Two sticks run in dual channel, which doubles memory bandwidth. In CPU-bound games like Fortnite, single channel costs roughly 5 to 30% FPS and much worse 1% lows. Add a second identical stick.' $null $null
        } elseif ($ram.Count -ge 2) {
            $chan = @($ram | ForEach-Object { $x = "$($_.BankLabel) $($_.DeviceLocator)"; if ($x -match '(?i)CHANNEL\s*([A-D])|Channel([A-D])|DIMM[_ ]?([A-D])\d|\b([A-D])\d\b') { ($Matches[1] + $Matches[2] + $Matches[3] + $Matches[4]).ToUpper() } })
            if ($chan.Count -eq $ram.Count -and ($chan | Sort-Object -Unique).Count -eq 1) {
                Add-Issue 3 'Both RAM sticks sit in the same channel' "They are in slots $(($ram | ForEach-Object { $_.DeviceLocator }) -join ' and '). Move one so they use slots A2 and B2 (the 2nd and 4th from the CPU on most boards; check the manual). Dual channel doubles memory bandwidth." $null $null
            }
        }
    }
    # --- Windows Update restarts
    $wu = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue
    if ($wu.IsExpedited -eq 1) {
        Add-Issue 3 'Windows may restart in the middle of a match ("Get me up to date" is on)' 'This Windows Update option restarts the PC as soon as an update is installed, even during your active hours. Updates still install with it off; Windows just waits for a quiet time.' $null `
            { Set-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'IsExpedited' 0 'DWord'; '"Get me up to date" switched off.' } 'Switch off'
    }
    # --- graphics card link (negotiated maximum; the live link drops at idle, so it is not used)
    $smi = "$env:WINDIR\System32\nvidia-smi.exe"
    if (Test-Path $smi) {
        try {
            $q = (& $smi --query-gpu=name,pcie.link.gen.max,pcie.link.gen.gpumax,pcie.link.width.max --format=csv,noheader 2>$null | Select-Object -First 1) -split ',\s*'
            if ($q.Count -ge 4) {
                $gname = $q[0]; $genMax = [int]$q[1]; $genGpu = [int]$q[2]; $wMax = [int]$q[3]
                $nativeNarrow = $gname -match '4060|3050|5050|5060|6400|6500|7600|A380|B570|B580'
                if ($wMax -lt 16 -and -not $nativeNarrow) {
                    Add-Issue 2 "Your $gname has only $wMax of its 16 PCIe lanes" 'Make sure the card sits in the top x16 slot (the one wired to the CPU) and is pushed fully in. On many boards the second or third M.2 slot takes 8 lanes from the graphics slot: move that SSD to another M.2 socket.' $null $null
                } elseif ($genMax -lt $genGpu -and $genMax -le 3) {
                    Add-Issue 1 "Your $gname runs at PCIe $genMax, but supports PCIe $genGpu" 'Check the BIOS setting for the graphics slot: it should be Auto or Gen 4/5, not Gen 3. The FPS cost is small (1 to 2%), larger on 8 GB cards.' $null $null
                }
            }
        } catch {}
    }
    # --- CPU held back by heat or a power limit (firmware events, last 7 days)
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction Stop)
        if ($ev.Count) {
            Add-Issue 3 "Your CPU was held below its normal speed $($ev.Count) time$(if ($ev.Count -ne 1) { 's' }) this week" 'Windows logged the firmware capping CPU speed, usually heat or a power limit. That costs far more FPS than any software setting. Clean dust from the CPU cooler, check it is seated and the pump runs, and look in the BIOS for a power or thermal limit (PL1/PL2, PPT, Eco mode) left on. Laptops: lift it off the desk and use the performance mode on mains.' $null $null
        }
    } catch {}
    # --- where Fortnite lives
    $fnDir = $null
    try { $dat = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"; if (Test-Path $dat) { $fnDir = ((Get-Content $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object { $_.AppName -eq 'Fortnite' } | Select-Object -First 1).InstallLocation } } catch {}
    function Get-DiskForPath([string]$Path) {
        try {
            $letter = (Split-Path -Qualifier $Path).TrimEnd(':')
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
            Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
        } catch { $null }
    }
    if ($fnDir) {
        $pd = Get-DiskForPath $fnDir
        if ($pd -and ($pd.MediaType -eq 'HDD' -or $pd.SpindleSpeed -gt 0)) {
            Add-Issue 3 "Fortnite is on $($pd.FriendlyName), a mechanical hard drive" 'Fortnite streams textures and buildings while you play; a hard drive cannot keep up, causing hitching, late-loading textures and long load screens. Move it to an SSD: Epic Games Launcher > Library > Fortnite > Manage lets you reinstall to another drive.' $null $null
        } elseif ($pd -and $pd.BusType -eq 'USB') {
            Add-Issue 2 "Fortnite is on an external USB drive ($($pd.FriendlyName))" 'USB drives are slower and share bandwidth with other USB devices. Move Fortnite to an internal SSD if you can.' $null $null
        }
    }
    $sys = Get-DiskForPath $env:SystemDrive
    if ($sys -and ($sys.MediaType -eq 'HDD' -or $sys.SpindleSpeed -gt 0)) {
        Add-Issue 2 "Windows is on a mechanical hard drive ($($sys.FriendlyName))" 'Fortnite''s shader and DirectX caches live on the Windows drive, so a slow system drive means stutter on new shaders and slow loading. An SSD for Windows is the biggest upgrade for this PC.' $null $null
    }
    # --- page file
    $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    if (-not $pf.Count) {
        Add-Issue 3 'The page file is switched off' 'Unreal Engine 5 reserves more memory than it uses; without a page file Windows refuses those reservations and Fortnite crashes with "Out of memory", even with 32 GB of RAM. Turning it off saves nothing. Settings > System > About > Advanced system settings > Performance > Advanced > Virtual memory: tick "Automatically manage".' $null $null
    } else {
        foreach ($x in $pf) { $pdd = Get-DiskForPath $x.Name; if ($pdd -and ($pdd.MediaType -eq 'HDD' -or $pdd.SpindleSpeed -gt 0)) { Add-Issue 2 "The page file is on a mechanical hard drive ($($pdd.FriendlyName))" 'Every time Windows spills memory to it, the game stutters. Move the page file to your fastest SSD in Settings > System > About > Advanced system settings > Performance > Advanced > Virtual memory.' $null $null } }
        try { $cs = Get-CimInstance Win32_ComputerSystem; $pfs = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue); if ($cs.AutomaticManagedPagefile -eq $false -and $pfs.Count -and ($pfs | Measure-Object MaximumSize -Maximum).Maximum -lt 4096) { Add-Issue 2 "The page file is fixed at $(($pfs | Measure-Object MaximumSize -Maximum).Maximum) MB" 'That is too small for Unreal Engine 5 and causes "Out of memory" crashes. Set it to "Automatically manage", or at least 4096 to 16384 MB, in Virtual memory settings.' $null $null } } catch {}
    }
    # --- power mode slider (Balanced plan only), battery, Energy Saver
    if ((Get-ActivePowerScheme).Guid -eq '381b4222-f694-41f0-9685-ff5bb260df2e') {
        $ov = [PowerOverlay]::Get()
        if ($ov -eq [PowerOverlay]::BestEfficiency) { Add-Issue 3 'Power mode is set to Best power efficiency' 'On this plan the Power mode slider is the real power setting: Best power efficiency caps the CPU boost and throttles background work, costing FPS and adding frame-time spikes.' 'powermode' }
        elseif ($ov -eq [PowerOverlay]::Balanced) { Add-Issue 2 'Power mode is set to Balanced' 'On this plan the Power mode slider decides CPU boost; Best performance keeps clocks up between frames.' 'powermode' }
    }
    try {
        [void][Windows.System.Power.PowerManager, Windows.System.Power, ContentType = WindowsRuntime]
        if ("$([Windows.System.Power.PowerManager]::EnergySaverStatus)" -eq 'On') { Add-Issue 3 'Energy Saver is on' 'Energy Saver caps CPU and GPU clocks and throttles background work. Turn it off in Quick Settings (Win+A); on desktops check Settings > System > Power > Energy saver > "Always use energy saver" is off.' $null $null }
        if ("$([Windows.System.Power.PowerManager]::BatteryStatus)" -eq 'Discharging') { Add-Issue 3 'The laptop is running on battery' 'On battery most laptops halve the GPU power limit and cap the CPU. Plug in the charger before you play.' $null $null }
    } catch {}
    # --- monitors: cable and mixed refresh rates
    try {
        $dsp = @(Get-Displays)
        $main = $dsp | Where-Object Primary | Select-Object -First 1
        $conn = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue)
        $ids = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
        if ($main -and $conn.Count -and $ids.Count) {
            $mid = $ids | Where-Object { $n = -join ($_.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ }); $n -and $main.Monitor -like "*$($n.Trim())*" } | Select-Object -First 1
            $mc = if ($mid) { $conn | Where-Object { $_.InstanceName -eq $mid.InstanceName } | Select-Object -First 1 }
            if ($mc -and $mc.VideoOutputTechnology -eq 5 -and $main.Hz -ge 144 -and ((Test-VrrActive) -eq $false)) {
                Add-Issue 1 "$($main.Monitor) is connected with HDMI" 'HDMI 2.0 tops out at 1440p 144 Hz, and NVIDIA G-SYNC Compatible is certified over DisplayPort on most monitors; some monitors hide their top refresh rates on HDMI. If both the monitor and the graphics card have a DisplayPort socket, use a DisplayPort cable (or HDMI 2.1 on both ends).' $null $null
            }
        }
        $rates = @($dsp | ForEach-Object { $_.Hz } | Where-Object { $_ } | Sort-Object -Unique)
        if ($rates.Count -gt 1 -and $main) {
            $bad = @($rates | Where-Object { $_ -ne $main.Hz -and ($main.Hz % $_) -ne 0 })
            if ($bad.Count -and (St 'fullscreen') -eq $false) {
                Add-Issue 2 "Monitors run at $($rates -join ' and ') Hz" "Windows composes the desktop at one rate; a video or animated page moving on the $($bad[0]) Hz screen can make a windowed game stutter. Set the second monitor to a divisor of the main one ($([int]($main.Hz / 2)) Hz, for example), play in exclusive fullscreen, or pause videos on the second screen while you play." $null $null
            }
        }
    } catch {}
    # --- AMD chipset software and the X3D scheduler driver
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($cpu.Manufacturer -eq 'AuthenticAMD') {
            if (-not ((Get-InstalledNames) -match '^AMD Chipset Software')) { Add-Issue 2 'AMD chipset software is not installed' 'The chipset package installs the Ryzen power-management provisioning (how fast cores ramp and park). Download "AMD Chipset Software" for your socket from amd.com/support and install it.' $null $null }
            if ($cpu.Name -match '79[05]0X3D|99[05]0X3D' -and -not (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like 'AMD 3D V-Cache Performance Optimizer*' })) {
                Add-Issue 3 'The AMD 3D V-Cache Performance Optimizer driver is missing' 'On dual-die X3D CPUs this driver keeps games on the V-Cache die. Without it Fortnite can run on the slow die and lose 10 to 20% FPS. Install AMD Chipset Software from amd.com/support and keep Windows Game Mode on (the driver uses it to detect games).' $null $null
            }
        }
    } catch {}
    # --- mouse behind a USB hub
    try {
        $mice = @(Get-PnpDevice -Class Mouse -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'HID\VID_*' })
        $hubs = @()
        foreach ($m in $mice) {
            $id = $m.InstanceId
            for ($hop = 0; $hop -lt 8 -and $id; $hop++) {
                $parent = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data
                if (-not $parent) { break }
                $pd2 = Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue
                if ($pd2 -and $pd2.Class -eq 'USB' -and $pd2.FriendlyName -match 'Hub' -and $pd2.FriendlyName -notmatch 'Root Hub') { $hubs += $pd2.FriendlyName; break }
                if ($pd2 -and $pd2.FriendlyName -match 'Root Hub|Host Controller') { break }
                $id = $parent
            }
        }
        if ($hubs.Count) { Add-Issue 2 "Your mouse is plugged into a USB hub ($($hubs | Select-Object -Unique | Select-Object -First 1))" 'Hubs (including the ones inside monitors, keyboards and docks) add polling jitter and share bandwidth with everything else on them. Plug the mouse or its wireless receiver straight into a USB port on the motherboard, ideally a USB 2.0 port away from USB 3 drives.' $null $null }
    } catch {}
    # --- Defender scans while you play
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        if ($mp.ScanOnlyIfIdleEnabled -eq $false) {
            Add-Issue 2 'Defender may start a scheduled scan while you play' 'A scan reads tens of thousands of files and spikes disk and CPU. With "only when idle" on, Windows waits until you step away. Real-time protection is not affected.' $null `
                { Set-MpPreference -ScanOnlyIfIdleEnabled $true -ErrorAction Stop; 'Defender scans now wait until the PC is idle.' } 'Only when idle'
        }
    } catch {}
    # --- other tools that undo settings
    $tools = @{ 'ExitLag' = 'ExitLag'; 'EXM' = 'EXM'; 'GearUP' = 'GearUP Booster'; 'RazerCortex' = 'Razer Cortex'; 'ProcessLasso' = 'Process Lasso'; 'WTFast' = 'WTFast'; 'NoPing' = 'NoPing' }
    $running = foreach ($k in $tools.Keys) { if (Get-Process -Name "$k*" -ErrorAction SilentlyContinue) { $tools[$k] } }
    $trustedNames = @(Get-RunningTrustedBoosters | ForEach-Object { $Boosters[$_].Name })
    $running = @($running | Where-Object { $trustedNames -notcontains $_ })
    if ($running) { Add-Issue 1 "Other optimizers are running: $($running -join ', ')" 'They can change the same settings as ZeroDelay. Drift alerts will tell you if they undo something.' $null $null }
    # --- background CPU right now
    $a = @{}; Get-Process | ForEach-Object { try { $a[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch {} }
    Start-Sleep -Milliseconds 1500
    $busy = Get-Process | ForEach-Object {
        try { if ($a.ContainsKey($_.Id)) { [pscustomobject]@{ Name = $_.ProcessName; Pct = ($_.TotalProcessorTime.TotalMilliseconds - $a[$_.Id]) / 1500 / [Environment]::ProcessorCount * 100 } } } catch {}
    } | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Pct = ($_.Group | Measure-Object Pct -Sum).Sum } } |
        Where-Object { $_.Pct -ge 1.5 -and $_.Name -notmatch '^(Idle|System|FortniteClient|powershell|dwm|audiodg|csrss|Registry|Memory Compression)' } | Sort-Object Pct -Descending | Select-Object -First 3
    if ($busy) { Add-Issue 1 'Background apps using CPU right now' (($busy | ForEach-Object { '{0} {1:N1}%' -f $_.Name, $_.Pct }) -join ', ') $null { "Turn on Game Mode to close or pause apps while you play." } 'How' }
    # --- disk + driver + reboot
    $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    if ($sys -and $sys.FreeSpace / $sys.Size -lt 0.1) { Add-Issue 2 ('System drive is {0:N0}% full' -f (100 - 100 * $sys.FreeSpace / $sys.Size)) 'Low free space slows Windows and game updates.' $null { & ($Tweaks | Where-Object { $_.Id -eq 'cleantemp' }).Run } 'Clean temp' }
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $DiscreteGpuRx } | Select-Object -First 1
    $drv = Get-NvDriverInfo
    if (Test-Gtx1080Ti) {
        if ($drv -and $drv.Installed -and [version]$drv.Installed -lt [version]$PascalSecurityDriver) {
            Add-Issue 1 "Security driver $PascalSecurityDriver is available for your GTX 1080 Ti (you have $($drv.Installed))" 'Your card is on NVIDIA''s 580 security branch. Drivers 590 and newer do not support it, so ignore those. Get this one from NVIDIA''s driver search (GeForce 10 Series > GTX 1080 Ti).' $null `
                { Start-Process 'https://www.nvidia.com/en-us/drivers/'; 'NVIDIA driver search opened.' } 'Driver page'
        }
    } elseif ($drv -and $drv.Latest -and $drv.Installed -and [version]$drv.Latest -gt [version]$drv.Installed) {
        Add-Issue 1 "NVIDIA driver $($drv.Latest) is available (you have $($drv.Installed))" 'Updates often fix Fortnite stutter. Install it from the NVIDIA App. It is not a latency fix by itself.' $null $null
    } elseif ($gpu -and $gpu.DriverDate -and ((Get-Date) - $gpu.DriverDate).TotalDays -gt 180) { Add-Issue 1 ('Graphics driver is {0:N0} months old' -f (((Get-Date) - $gpu.DriverDate).TotalDays / 30)) 'New drivers often fix Fortnite stutter. Update through the NVIDIA app or AMD Adrenalin.' $null $null }
    if (Test-NvAvailable) {
        $sm = Get-NvEff $NvProfile $NvSmoothMotionId
        if ($sm.Found -and $sm.Value -ne 0) { Add-Issue 3 'NVIDIA Smooth Motion is on for Fortnite' 'Driver frame generation adds input delay. Turn it off.' 'smoothmotion' }
        $hdr = Get-NvEff $NvProfile ([uint32]0x00DD48FB)
        if ($hdr.Found -and $hdr.Value -ne 0) { Add-Issue 2 'RTX HDR is on for Fortnite' 'AI HDR processing costs GPU time every frame.' $null { Disable-NvRtxHdr } 'Turn off' }
        if ((Get-NvOverlayState).On) { Add-Issue 1 'NVIDIA overlay is on' 'Instant Replay and the stats overlay cost a little GPU time. Turn the overlay off in NVIDIA App > Settings > Features if you do not clip.' $null $null }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { Add-Issue 1 'Windows is waiting for a restart' 'Pending updates can install in the background while you play.' $null $null }
    @($issues | Sort-Object Sev -Descending)
}

function New-HealthPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <Grid>
      <StackPanel Orientation='Horizontal' VerticalAlignment='Center'>
        <TextBlock x:Name='Score' Text='?' FontSize='40' FontWeight='Bold' Foreground='#A1A1A6'/>
        <StackPanel Margin='16,0,0,0' VerticalAlignment='Center'>
          <TextBlock x:Name='Summary' Text='Press Scan to check your PC.' FontSize='15' FontWeight='SemiBold'/>
          <TextBlock x:Name='Sub' Text='Takes a few seconds. Nothing is changed until you press Fix.' FontSize='12' Foreground='#A1A1A6' Margin='0,3,0,0'/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation='Horizontal' HorizontalAlignment='Right' VerticalAlignment='Center'>
        <Button x:Name='Scan' Content='Scan' Style='{DynamicResource Btn}' Margin='0,0,10,0'/>
        <Button x:Name='FixAll' Content='Fix all' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' IsEnabled='False'/>
      </StackPanel>
    </Grid>
  </Border>
  <StackPanel x:Name='List'/>
</StackPanel>
"@)
    $script:Health = @{}; foreach ($n in 'Score', 'Summary', 'Sub', 'Scan', 'FixAll', 'List') { $script:Health[$n] = $root.FindName($n) }
    $script:Health.Scan.Add_Click({ Invoke-HealthScan })
    $script:Health.FixAll.Add_Click({
        $window.Cursor = [Windows.Input.Cursors]::Wait
        $n = 0; $skipped = @()
        foreach ($i in @($script:HealthIssues | Where-Object { $_.Tweak -or ($_.Fix -and $_.FixLabel -ne 'How') })) {
            try { Invoke-HealthFix $i | Out-Null; $n++ } catch { $skipped += $i.Title }
        }
        $window.Cursor = $null
        Show-Toast ("Fixed $n issues." + $(if ($skipped) { " Skipped: $($skipped -join '; ')." } else { '' })) $(if ($skipped) { '#FF9F0A' } else { '#30D158' })
        Invoke-HealthScan
    })
    New-PageScroll $root
}
function Invoke-HealthFix($i) {
    if ($i.Tweak) {
        $t = $Tweaks | Where-Object { $_.Id -eq $i.Tweak } | Select-Object -First 1
        Invoke-TweakOn $t; Update-Card $t; Update-Summary
        return "$($t.Title): on."
    }
    if ($i.Fix) { return (& $i.Fix) }
}
function Invoke-HealthScan {
    $h = $script:Health
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $h.Summary.Text = 'Scanning...'; $h.Sub.Text = ''
    $window.Dispatcher.Invoke([action] {}, 'Render')
    $script:HealthIssues = Get-HealthIssues
    $window.Cursor = $null
    $issues = $script:HealthIssues
    $score = [Math]::Max(0, 100 - (($issues | ForEach-Object { switch ($_.Sev) { 3 { 10 } 2 { 5 } default { 1 } } }) | Measure-Object -Sum).Sum)
    Start-CountUp $h.Score $score
    $h.Score.Foreground = ConvertTo-Brush $(if ($score -ge 85) { '#30D158' } elseif ($score -ge 60) { '#FFD60A' } else { '#FF453A' })
    $fixable = @($issues | Where-Object { $_.Tweak -or ($_.Fix -and $_.FixLabel -ne 'How') }).Count
    $h.Summary.Text = if ($issues.Count) { "$($issues.Count) things to look at" } else { 'Everything looks good' }
    $h.Sub.Text = "$fixable can be fixed with one click. Last scan $(Get-Date -Format 'HH:mm')."
    $h.FixAll.IsEnabled = $fixable -gt 0
    $h.List.Children.Clear()
    foreach ($i in $issues) {
        $color = switch ($i.Sev) { 3 { '#FF453A' } 2 { '#FFD60A' } default { '#0A84FF' } }
        $sevWord = switch ($i.Sev) { 3 { 'High impact' } 2 { 'Medium' } default { 'Info' } }
        $row = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='18,14' Margin='0,0,0,10'>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <Ellipse Width='10' Height='10' Fill='$color' VerticalAlignment='Top' Margin='0,6,14,0'/>
    <StackPanel Grid.Column='1'>
      <StackPanel Orientation='Horizontal'>
        <TextBlock Text='$(Esc $i.Title)' FontSize='14' FontWeight='SemiBold'/>
        <TextBlock Text='$sevWord' FontSize='11' Foreground='$color' Margin='10,2,0,0'/>
      </StackPanel>
      <TextBlock Text='$(Esc $i.Detail)' FontSize='12.5' Foreground='#A1A1A6' TextWrapping='Wrap' Margin='0,4,20,0'/>
    </StackPanel>
    <Button x:Name='Fix' Grid.Column='2' Content='$(Esc $i.FixLabel)' Style='{DynamicResource Btn}' Padding='14,7' FontSize='12' VerticalAlignment='Center'/>
  </Grid>
</Border>
"@)
        $btn = $row.FindName('Fix')
        if (-not $i.Tweak -and -not $i.Fix) { $btn.Visibility = 'Collapsed' }
        $btn.Tag = @{ Issue = $i; Row = $row }
        $btn.Add_Click({
            param($s, $e)
            try { $msg = Invoke-HealthFix $s.Tag.Issue; Show-Toast $msg '#30D158'; if ($s.Tag.Issue.FixLabel -ne 'How') { Start-Anim $s.Tag.Row ([Windows.UIElement]::OpacityProperty) $null 0.45 300; $s.IsEnabled = $false; $s.Content = 'Done' } }
            catch { Show-Toast "$($s.Tag.Issue.Title): $($_.Exception.Message)" '#FF9F0A' }
        })
        [void]$h.List.Children.Add($row)
        Show-Animated $row 10 260 ([Math]::Min(600, 45 * ($h.List.Children.Count - 1)))
    }
}

# =============================================================== Drift alerts
# Re-checks what ZeroDelay set (switched-on cards, last graphics preset, NVIDIA texture blur) and reports anything another
# program, a Fortnite patch or a driver update changed back.
$KnownOptimizers = [ordered]@{ 'ExitLag' = 'ExitLag'; 'EXM' = 'EXM'; 'GearUP' = 'GearUP Booster'; 'RazerCortex' = 'Razer Cortex'
                               'ProcessLasso' = 'Process Lasso'; 'WTFast' = 'WTFast'; 'NoPing' = 'NoPing'; 'Hone' = 'Hone' }
# --- Ping boosters (GearUP, ExitLag, ...). A trusted booster may change settings: ZeroDelay keeps its changes, never
#     switches them back (alerts, auto-fix, Optimize, Game Mode), and logs what changed while it was running.
$Boosters = [ordered]@{
    GearUP  = @{ Name = 'GearUP Booster'; Proc = @('gearup_booster', 'GearUP*'); Detect = '^GearUP' }
    ExitLag = @{ Name = 'ExitLag';        Proc = @('ExitLag*');                   Detect = '^ExitLag' }
    WTFast  = @{ Name = 'WTFast';         Proc = @('WTFast*');                    Detect = '^WTFast' }
    NoPing  = @{ Name = 'NoPing';         Proc = @('NoPing*');                    Detect = '^NoPing' }
}
function Get-InstalledBoosters {
    $names = Get-InstalledNames
    @(foreach ($k in $Boosters.Keys) { $b = $Boosters[$k]; if (($names -match $b.Detect) -or (Get-Process -Name $b.Proc -ErrorAction SilentlyContinue)) { $k } })
}
function Test-BoosterRunning([string]$Key) { [bool](Get-Process -Name $Boosters[$Key].Proc -ErrorAction SilentlyContinue) }
function Test-BoosterTrusted([string]$Key) { $t = $script:Backup.Custom['trustedboosters']; if ($t -and $null -ne $t.$Key) { [bool]$t.$Key } else { $true } }
function Set-BoosterTrusted([string]$Key, [bool]$On) {
    $t = @{}; $old = $script:Backup.Custom['trustedboosters']; if ($old) { foreach ($k in $Boosters.Keys) { if ($null -ne $old.$k) { $t[$k] = [bool]$old.$k } } }
    $t[$Key] = $On; $script:Backup.Custom['trustedboosters'] = $t; Save-Backup
}
function Get-RunningTrustedBoosters { @(Get-InstalledBoosters | Where-Object { (Test-BoosterTrusted $_) -and (Test-BoosterRunning $_) }) }
function Get-BoosterLog { @($script:Backup.Custom['boosterlog'] | Where-Object { $_ }) }
function Add-BoosterLog([string]$Key, [string]$Who, [string]$Setting, [string]$Before, [string]$After) {
    $e = [pscustomobject]@{ Time = (Get-Date).ToString('o'); Booster = $Who; BoosterKey = $Key; Setting = $Setting; Before = $Before; After = $After }
    $script:Backup.Custom['boosterlog'] = @($e) + @(Get-BoosterLog | Select-Object -First 199)
}
# settings a booster handed over: ZeroDelay does not switch these on again
function Get-BoosterOwned { @($script:Backup.Custom['boosterowned'] | Where-Object { $_ }) }
function Test-BoosterOwnsPlan { [bool](Get-BoosterLog | Where-Object { $_.Setting -eq 'Power plan' -and $Boosters.Keys -contains "$($_.BoosterKey)" -and (Test-BoosterTrusted $_.BoosterKey) }) }
# What ping boosters usually touch: DNS, MTU, interface priority, Nagle/TCP values, proxy, hosts, QoS, power plan, route
function Get-NetSnapshot {
    $s = [ordered]@{}
    try {
        foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            $n = $a.Name
            $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ', '
            $s["DNS servers ($n)"] = if ($dns) { $dns } else { 'automatic' }
            $ip = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ip) { $s["MTU ($n)"] = "$($ip.NlMtu)"; $s["Interface priority ($n)"] = "$($ip.InterfaceMetric)$(if ("$($ip.AutomaticMetric)" -eq 'Enabled') { ' (automatic)' })" }
            $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction SilentlyContinue
            foreach ($v in 'TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks') { $s["$v ($n)"] = if ($null -ne $p.$v) { "$($p.$v)" } else { 'not set' } }
        }
    } catch {}
    $tp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction SilentlyContinue
    foreach ($v in 'DefaultTTL', 'Tcp1323Opts', 'MaxUserPort', 'TcpTimedWaitDelay') { $s["TCP $v"] = if ($null -ne $tp.$v) { "$($tp.$v)" } else { 'not set' } }
    try { $t = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop; $s['TCP auto-tuning'] = "$($t.AutoTuningLevelLocal)"; $s['TCP congestion control'] = "$($t.CongestionProvider)"; $s['TCP ECN'] = "$($t.EcnCapability)" } catch {}
    $mm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction SilentlyContinue
    $s['Network throttling index'] = if ($null -ne $mm.NetworkThrottlingIndex) { '0x{0:X}' -f [uint32]$mm.NetworkThrottlingIndex } else { 'not set' }
    $s['System responsiveness'] = if ($null -ne $mm.SystemResponsiveness) { "$($mm.SystemResponsiveness)" } else { 'not set' }
    $q = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -ErrorAction SilentlyContinue
    $s['QoS reserved bandwidth'] = if ($null -ne $q.NonBestEffortLimit) { "$($q.NonBestEffortLimit)%" } else { 'Windows default' }
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $s['Proxy'] = if ($ie.ProxyEnable) { "$($ie.ProxyServer)" } else { 'off' }
    $h = "$env:WINDIR\System32\drivers\etc\hosts"
    $s['Hosts file'] = if (Test-Path $h) { "$(@(Get-Content $h -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' }).Count) entries" } else { 'missing' }
    $s['Power plan'] = "$((Get-ActivePowerScheme).Name)"
    $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    $s['Internet route'] = if ($gw) { "$($gw.NextHop) via $($gw.InterfaceAlias)" } else { 'none' }
    $s
}
# Compares a fresh snapshot with the last one; changes made while a trusted booster ran are logged (and kept).
function Invoke-BoosterWatch {
    if ($script:BoosterBusy -or -not @(Get-InstalledBoosters).Count) { return }
    $script:BoosterBusy = $true
    $script:BoosterNow = Get-RunningTrustedBoosters
    Invoke-Worker 'Get-NetSnapshot' @() {
        param($out, $errs)
        $script:BoosterBusy = $false
        $cur = Get-WorkerResult $out
        if ($cur -isnot [Collections.IDictionary] -or -not $cur.Count) { return }
        $prev = ConvertTo-OrderedTable $script:Backup.Custom['boostersnap']
        $who = @(@($script:BoosterNow) + @($script:BoosterWas) | Where-Object { $_ } | Select-Object -Unique)
        $n = 0
        $whoNames = ($who | ForEach-Object { $Boosters[$_].Name }) -join ', '
        if ($prev.Count -and $who.Count) {
            foreach ($k in @(@($cur.Keys) + @($prev.Keys) | Select-Object -Unique)) {
                $b = "$($prev[$k])"; $a = "$($cur[$k])"
                if ($b -ne $a -and $prev.Contains($k) -and $cur.Contains($k)) {
                    Add-BoosterLog $who[0] $whoNames $k $b $a
                    $n++
                }
            }
        }
        $script:Backup.Custom['boostersnap'] = $cur
        $script:BoosterWas = $script:BoosterNow
        Save-Backup
        if ($n) { Show-Toast "$whoNames changed $n network setting$(if ($n -ne 1) { 's' }). ZeroDelay kept them: see Ping booster." '#0A84FF' }
        if ($script:BoosterUi) { Update-BoosterPage }
    }
}
function Get-RunningOptimizers { @(foreach ($k in $KnownOptimizers.Keys) { if (Get-Process -Name "$k*" -ErrorAction SilentlyContinue) { $KnownOptimizers[$k] } }) }
function ConvertTo-OrderedTable($o) {
    $h = [ordered]@{}
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in $o.Keys) { $h[$k] = $o[$k] } }
    elseif ($o) { $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    $h
}
function Get-Drift {
    Clear-ReadCache
    $items = @()
    foreach ($id in Get-Applied) {
        $t = $Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $t -or -not $t.Toggle) { continue }
        # Fortnite leaves out keys at their default and cannot be edited while running; skip those cases.
        if ($t.Ini -and ((Test-FortniteRunning) -or -not (Test-Path $IniPath) -or -not ($t.Ini.Keys | Where-Object { $null -ne (Get-IniValue (Get-Content $IniPath) $_) }))) { continue }
        if ((Invoke-TweakTest $t) -eq $false) { $items += [pscustomobject]@{ Kind = 'tweak'; T = $t; Title = $t.Title } }
    }
    $lp = $script:Backup.Custom['lastpreset']
    if ($lp -and (Test-Path $IniPath) -and -not (Test-FortniteRunning)) {
        $vals = ConvertTo-OrderedTable $lp.Values
        if (-not (Test-Preset @{ Preset = $vals })) { $items += [pscustomobject]@{ Kind = 'preset'; Values = $vals; Title = "Graphics preset ($($lp.Title))" } }
    }
    $want = $script:Backup.Custom['nvlodvalue']
    if ($want -and (Test-NvAvailable)) {
        $cur = Get-NvLod
        if ($null -ne $cur -and $cur -ne [int]$want) { $items += [pscustomobject]@{ Kind = 'nvlod'; Value = [int]$want; Title = 'NVIDIA texture blur (driver update?)' } }
    }
    $items
}
function Repair-Drift($items) {
    $ok = 0; $failed = @()
    foreach ($i in $items) {
        try {
            switch ($i.Kind) {
                'tweak'  { Invoke-TweakOn $i.T; Update-Card $i.T }
                'preset' { Invoke-Preset @{ Title = $script:Backup.Custom['lastpreset'].Title; Preset = $i.Values } | Out-Null }
                'nvlod'  { Set-NvLod $i.Value; $script:CurrentNvLod = $i.Value }
            }
            $ok++
        } catch { $failed += $i.Title }
    }
    Update-Summary
    "Re-applied $ok setting$(if ($ok -ne 1) { 's' })." + $(if ($failed) { " Could not: $($failed -join ', ')." } else { '' })
}
function Invoke-DriftCheck {
    if ($script:DriftBusy) { return }
    $script:DriftBusy = $true
    try {
        $items = @(Get-Drift)
        $script:DriftItems = $items
        if (-not $items.Count) { $ui.DriftBar.Visibility = 'Collapsed'; return }
        $trusted = Get-RunningTrustedBoosters
        if ($trusted.Count) {
            $names = ($trusted | ForEach-Object { $Boosters[$_].Name }) -join ', '
            $owned = @(Get-BoosterOwned)
            foreach ($i in $items) {
                switch ($i.Kind) {
                    'tweak'  { Set-Applied $i.T.Id $false; $owned += $i.T.Id; Update-Card $i.T }
                    'preset' { $script:Backup.Custom.Remove('lastpreset') }
                    'nvlod'  { $script:Backup.Custom.Remove('nvlodvalue') }
                }
                Add-BoosterLog $trusted[0] $names $i.Title 'set by ZeroDelay' "changed by $names"
            }
            $script:Backup.Custom['boosterowned'] = @($owned | Select-Object -Unique)
            Save-Backup; Update-Summary
            $ui.DriftBar.Visibility = 'Collapsed'
            Show-Toast "$names changed $($items.Count) setting$(if ($items.Count -ne 1) { 's' }). Kept as $names set them: see Ping booster." '#0A84FF'
            if ($script:BoosterUi) { Update-BoosterPage }
            return
        }
        $who = Get-RunningOptimizers
        if ($script:Backup.Custom['autofix']) {
            $msg = Repair-Drift $items
            $ui.DriftBar.Visibility = 'Collapsed'
            Add-History "Auto-fixed $($items.Count) changed setting(s)$(if ($who) { " ($($who -join ', ') running)" })" 'autofix' $null
            Show-Toast "Something changed your settings$(if ($who) { " ($($who -join ', ') is running)" }). $msg" '#FF9F0A'
            return
        }
        $ui.DriftTitle.Text = "$($items.Count) setting$(if ($items.Count -ne 1) { 's were' } else { ' was' }) changed back" + $(if ($who) { " — $($who -join ', ') is running" } else { ' by another program or an update' })
        $ui.DriftText.Text = ($items | ForEach-Object Title) -join '  ·  '
        if ($ui.DriftBar.Visibility -ne 'Visible') { $ui.DriftBar.Visibility = 'Visible'; Show-Animated $ui.DriftBar -8 260 }
    } finally { $script:DriftBusy = $false }
}

# =============================================================== Benchmark (Intel PresentMon)
$PresentMonUrl = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe'
$ToolsDir      = Join-Path $DataDir 'tools'
$PresentMonExe = Join-Path $ToolsDir 'PresentMon.exe'
$BenchFile     = Join-Path $DataDir 'benchmarks.json'
function Get-BenchRuns { @(Read-JsonList $BenchFile) }
function Save-BenchRuns($runs) { ConvertTo-Json -InputObject @($runs) -Depth 4 | Set-Content $BenchFile -Encoding UTF8 }

# Turns a PresentMon CSV into the numbers people compare: average FPS, 1% / 0.1% lows, frame-time spread and latency.
function Measure-BenchCsv([string]$Csv) {
    $rows = Import-Csv $Csv
    if (-not $rows) { throw 'PresentMon recorded no frames. Was Fortnite in a match (not minimised)?' }
    $cols = $rows[0].PSObject.Properties.Name
    $ftCol = @('MsBetweenPresents', 'FrameTime', 'MsBetweenAppStart') | Where-Object { $cols -contains $_ } | Select-Object -First 1
    if (-not $ftCol) { throw 'Unexpected PresentMon output (no frame-time column).' }
    $ft = [double[]]@($rows | ForEach-Object { $v = 0.0; if ([double]::TryParse($_.$ftCol, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -gt 0) { $v } })
    if ($ft.Count -lt 30) { throw 'Too few frames recorded to measure.' }
    $sorted = $ft | Sort-Object
    $avg = ($ft | Measure-Object -Average).Average
    # "1% low" = FPS of the slowest 1% of frames averaged (the common definition), not a percentile that hides stutters.
    $p = { param($share) $k = [Math]::Max(1, [int][Math]::Ceiling($share * $sorted.Count)); ($sorted[($sorted.Count - $k)..($sorted.Count - 1)] | Measure-Object -Average).Average }
    $sd = [Math]::Sqrt((($ft | ForEach-Object { ($_ - $avg) * ($_ - $avg) }) | Measure-Object -Sum).Sum / $ft.Count)
    $lat = $null; $latKind = $null
    foreach ($c in 'MsPCLatency', 'PCLatency', 'DisplayLatency', 'MsDisplayLatency') {
        if ($cols -notcontains $c) { continue }
        $vals = [double[]]@($rows | ForEach-Object { $v = 0.0; if ([double]::TryParse($_.$c, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -gt 0) { $v } })
        if ($vals.Count -gt 10) { $lat = ($vals | Measure-Object -Average).Average; $latKind = $(if ($c -match 'PC') { 'PC latency' } else { 'Display latency' }); break }
    }
    [pscustomobject]@{
        Frames = $ft.Count; AvgFps = [Math]::Round(1000 / $avg, 1)
        Low1 = [Math]::Round(1000 / (& $p 0.01), 1); Low01 = [Math]::Round(1000 / (& $p 0.001), 1)
        FtSd = [Math]::Round($sd, 2); Latency = $(if ($lat) { [Math]::Round($lat, 1) } else { $null }); LatencyKind = $latKind
    }
}
function Get-SetupSummary {
    $parts = @()
    if (Test-ZDGameMode) { $parts += 'Game Mode on' }
    $lp = $script:Backup.Custom['lastpreset']; if ($lp) { $parts += "preset $($lp.Title)" }
    $parts += "$(@(Get-Applied).Count) tweaks"
    $parts -join ', '
}

function New-BenchmarkPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <Grid>
        <StackPanel>
          <TextBlock Text='Record a benchmark' FontSize='16' FontWeight='SemiBold'/>
          <TextBlock x:Name='Hint' FontSize='12.5' Foreground='#A1A1A6' Margin='0,4,0,0' TextWrapping='Wrap' MaxWidth='620' HorizontalAlignment='Left'
                     Text='Start it while you are in a match, Creative map or Battle Lab, not the lobby. Play normally until it finishes. Do the same route each time for a fair comparison.'/>
        </StackPanel>
        <Button x:Name='Get' Content='Download PresentMon' Style='{DynamicResource Btn}' HorizontalAlignment='Right' VerticalAlignment='Top'/>
      </Grid>
      <StackPanel Orientation='Horizontal' Margin='0,16,0,0'>
        <TextBlock Text='Name' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Margin='0,0,10,0'/>
        <TextBox x:Name='Label' Width='220' Padding='8,5' FontSize='13'/>
        <TextBlock Text='Length' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Margin='22,0,10,0'/>
        <Button x:Name='D30' Content='30 s' Style='{DynamicResource Btn}' Padding='12,6' FontSize='12' Margin='0,0,6,0'/>
        <Button x:Name='D60' Content='60 s' Style='{DynamicResource Btn}' Padding='12,6' FontSize='12' Margin='0,0,6,0'/>
        <Button x:Name='D120' Content='120 s' Style='{DynamicResource Btn}' Padding='12,6' FontSize='12' Margin='0,0,22,0'/>
        <Button x:Name='Start' Content='Start benchmark' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF'/>
      </StackPanel>
      <TextBlock x:Name='Status' FontSize='13' FontWeight='SemiBold' Foreground='#30D158' Margin='0,12,0,0'/>
    </StackPanel>
  </Border>
  <Border x:Name='CompareBox' Background='#22382A' BorderBrush='#2F5A3D' BorderThickness='1' CornerRadius='10' Padding='22,14' Margin='0,0,0,16' Visibility='Collapsed'>
    <TextBlock x:Name='Compare' FontSize='13.5' TextWrapping='Wrap'/>
  </Border>
  <StackPanel x:Name='Runs'/>
</StackPanel>
"@)
    $b = @{}; foreach ($n in 'Hint', 'Get', 'Label', 'D30', 'D60', 'D120', 'Start', 'Status', 'CompareBox', 'Compare', 'Runs') { $b[$n] = $root.FindName($n) }
    $script:Bench = $b
    $script:BenchSeconds = 60
    $b.Label.Text = "Run $(@(Get-BenchRuns).Count + 1)"
    foreach ($n in 'D30', 'D60', 'D120') {
        $b[$n].Tag = [int]($n.Substring(1))
        $b[$n].Add_Click({ param($s, $e) $script:BenchSeconds = $s.Tag; Update-BenchDurationButtons })
    }
    $b.Get.Add_Click({
        $r = (Show-ZdDialog ("Download PresentMon 2.6.0 from Intel's official GitHub page?`n`n$PresentMonUrl`n`nIt is Intel's free frame-time recorder. ZeroDelay saves it to its own folder and only runs it when you start a benchmark.") ('Download PresentMon') ('YesNo') ('Question'))
        if ($r -ne 'Yes') { return }
        try {
            $window.Cursor = [Windows.Input.Cursors]::Wait
            New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $PresentMonUrl -OutFile $PresentMonExe -UseBasicParsing
            Show-Toast 'PresentMon downloaded. You can benchmark now.' '#30D158'
        } catch { Show-Toast "Download failed: $($_.Exception.Message)" '#FF9F0A' }
        finally { $window.Cursor = $null; Update-BenchmarkPage }
    })
    $b.Start.Add_Click({ Start-Benchmark })
    $script:BenchTimer = New-Object Windows.Threading.DispatcherTimer
    $script:BenchTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:BenchTimer.Add_Tick({ Watch-Benchmark })
    $script:PageRefresh['Benchmark'] = { Update-BenchmarkPage }
    Update-BenchDurationButtons
    Update-BenchmarkPage
    New-PageScroll $root
}
function Update-BenchDurationButtons {
    foreach ($n in 'D30', 'D60', 'D120') {
        $on = $script:Bench[$n].Tag -eq $script:BenchSeconds
        $script:Bench[$n].Background = ConvertTo-Brush $(if ($on) { '#636366' } else { '#3A3A3C' })
        $script:Bench[$n].Foreground = ConvertTo-Brush $(if ($on) { '#FFFFFF' } else { '#A1A1A6' })
    }
}
function Start-Benchmark {
    $b = $script:Bench
    if (-not (Test-Path $PresentMonExe)) { Show-Toast 'Download PresentMon first.' '#FF9F0A'; return }
    if (-not (Test-FortniteRunning)) { Show-Toast 'Start Fortnite and get into a match or Creative first.' '#FF9F0A'; return }
    $script:BenchCsv = Join-Path $ToolsDir "bench-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $pmArgs = @('--process_name', $FortniteExeName, '--output_file', "`"$script:BenchCsv`"", '--timed', "$script:BenchSeconds",
              '--terminate_after_timed', '--no_console_stats', '--stop_existing_session', '--session_name', 'ZeroDelayBench')
    try { $script:BenchProc = Start-Process $PresentMonExe -ArgumentList $pmArgs -WindowStyle Hidden -PassThru }
    catch { Show-Toast "Could not start PresentMon: $($_.Exception.Message)" '#FF9F0A'; return }
    $script:BenchEnd = (Get-Date).AddSeconds($script:BenchSeconds + 2)
    $script:BenchLabel = if ($b.Label.Text.Trim()) { $b.Label.Text.Trim() } else { "Run $(@(Get-BenchRuns).Count + 1)" }
    $b.Start.IsEnabled = $false
    $script:BenchTimer.Start()
}
function Watch-Benchmark {
    $b = $script:Bench
    if (-not $script:BenchProc.HasExited) {
        $left = [Math]::Max(0, [int]($script:BenchEnd - (Get-Date)).TotalSeconds)
        $b.Status.Text = "Recording '$script:BenchLabel'... $left s left. Keep playing."
        if ((Get-Date) -gt $script:BenchEnd.AddSeconds(20)) { try { $script:BenchProc.Kill() } catch {} }
        return
    }
    $script:BenchTimer.Stop()
    $b.Start.IsEnabled = $true
    try {
        $m = Measure-BenchCsv $script:BenchCsv
        $run = [pscustomobject]@{ Label = $script:BenchLabel; Time = (Get-Date).ToString('o'); Seconds = $script:BenchSeconds; Setup = (Get-SetupSummary)
                                  AvgFps = $m.AvgFps; Low1 = $m.Low1; Low01 = $m.Low01; FtSd = $m.FtSd; Latency = $m.Latency; LatencyKind = $m.LatencyKind; Frames = $m.Frames }
        Save-BenchRuns (@(Get-BenchRuns) + $run)
        Add-History "Benchmark: $($run.Label) ($($run.AvgFps) FPS avg, $($run.Low1) 1% low)" 'benchmark' $null
        $b.Status.Text = "Done: $($run.AvgFps) FPS average, $($run.Low1) FPS 1% low."
        $b.Label.Text = "Run $(@(Get-BenchRuns).Count + 1)"
    } catch { $b.Status.Text = ''; Show-Toast "Benchmark failed: $($_.Exception.Message)" '#FF9F0A' }
    finally { Remove-Item $script:BenchCsv -ErrorAction SilentlyContinue }
    Update-BenchmarkPage
}
function Update-BenchmarkPage {
    $b = $script:Bench; if (-not $b) { return }
    $have = Test-Path $PresentMonExe
    $b.Get.Visibility = if ($have) { 'Collapsed' } else { 'Visible' }
    $b.Start.IsEnabled = $have -and -not ($script:BenchTimer -and $script:BenchTimer.IsEnabled)
    if (-not $have) { $b.Status.Text = 'PresentMon is not downloaded yet.'; $b.Status.Foreground = ConvertTo-Brush '#FFD60A' }
    elseif (-not $script:BenchTimer.IsEnabled -and $b.Status.Text -like 'PresentMon is not*') { $b.Status.Text = '' }
    if ($have) { $b.Status.Foreground = ConvertTo-Brush '#30D158' }
    $runs = @(Get-BenchRuns)
    $b.Runs.Children.Clear()
    if ($runs.Count -ge 2) {
        $a = $runs[-2]; $z = $runs[-1]
        function D($new, $old, [string]$unit, [bool]$lowerBetter) {
            if ($null -eq $new -or $null -eq $old -or $old -eq 0) { return '' }
            $pct = ($new - $old) / $old * 100
            $good = if ($lowerBetter) { $pct -lt 0 } else { $pct -gt 0 }
            '{0}{1:N1}% {2}' -f $(if ($pct -ge 0) { '+' } else { '' }), $pct, $(if ([Math]::Abs($pct) -lt 2) { '(about the same)' } elseif ($good) { '(better)' } else { '(worse)' })
        }
        $b.Compare.Text = "$($z.Label) vs $($a.Label):   average FPS $(D $z.AvgFps $a.AvgFps 'fps' $false)   ·   1% low $(D $z.Low1 $a.Low1 'fps' $false)   ·   frame-time spread $(D $z.FtSd $a.FtSd 'ms' $true)" +
                          $(if ($z.Latency -and $a.Latency) { "   ·   latency $(D $z.Latency $a.Latency 'ms' $true)" } else { '' })
        $b.CompareBox.Visibility = 'Visible'
    } else { $b.CompareBox.Visibility = 'Collapsed' }
    if (-not $runs.Count) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'No runs yet. Tip: record one now, change something (a preset, Game Mode, a tweak), then record again.'
        $tb.Foreground = ConvertTo-Brush '#A1A1A6'; [void]$b.Runs.Children.Add($tb); return
    }
    $maxFps = ($runs | Measure-Object AvgFps -Maximum).Maximum
    $best = ($runs | Sort-Object Low1 -Descending | Select-Object -First 1)
    for ($i = $runs.Count - 1; $i -ge 0; $i--) {
        $r = $runs[$i]
        $w1 = [int](260 * $r.AvgFps / $maxFps); $w2 = [int](260 * $r.Low1 / $maxFps)
        $when = try { ([datetime]$r.Time).ToString('dd MMM HH:mm') } catch { '' }
        $tag = if ($r -eq $best -and $runs.Count -gt 1) { "<Border Background='#2D4635' CornerRadius='5' Padding='7,2' Margin='10,0,0,0'><TextBlock Text='Best 1% low' FontSize='11' Foreground='#30D158' FontWeight='SemiBold'/></Border>" } else { '' }
        $lat = if ($r.Latency) { "$($r.Latency) ms $($r.LatencyKind)" } else { 'latency n/a' }
        $row = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='18,14' Margin='0,0,0,10'>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width='240'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <StackPanel>
      <StackPanel Orientation='Horizontal'><TextBlock Text='$(Esc $r.Label)' FontSize='14' FontWeight='SemiBold'/>$tag</StackPanel>
      <TextBlock Text='$(Esc "$when  ·  $($r.Seconds) s  ·  $($r.Setup)")' FontSize='11.5' Foreground='#A1A1A6' Margin='0,4,0,0' TextWrapping='Wrap'/>
    </StackPanel>
    <StackPanel Grid.Column='1' Margin='10,0,10,0'>
      <StackPanel Orientation='Horizontal' Margin='0,0,0,6'>
        <Border Width='$w1' Height='8' CornerRadius='4' Background='#30D158' VerticalAlignment='Center'/>
        <TextBlock Text='$($r.AvgFps) FPS average' FontSize='12' Margin='10,0,0,0'/>
      </StackPanel>
      <StackPanel Orientation='Horizontal'>
        <Border Width='$w2' Height='8' CornerRadius='4' Background='#FFD60A' VerticalAlignment='Center'/>
        <TextBlock Text='$($r.Low1) FPS 1% low  ·  $($r.Low01) 0.1% low  ·  spread $($r.FtSd) ms  ·  $(Esc $lat)' FontSize='12' Foreground='#D1D1D6' Margin='10,0,0,0'/>
      </StackPanel>
    </StackPanel>
    <Button x:Name='Del' Grid.Column='2' Content='Delete' Style='{DynamicResource Btn}' Foreground='#FF453A' Padding='12,5' FontSize='12' VerticalAlignment='Center'/>
  </Grid>
</Border>
"@)
        $del = $row.FindName('Del'); $del.Tag = $r.Time
        $del.Add_Click({ param($s, $e) Save-BenchRuns @(Get-BenchRuns | Where-Object { $_.Time -ne $s.Tag }); Update-BenchmarkPage })
        [void]$b.Runs.Children.Add($row)
    }
}

# =============================================================== Ping monitor
$PingLogFile = Join-Path $env:TEMP 'zerodelay-ping.log'
function New-PingPage {
    $regions = ($PingHosts | ForEach-Object { "<ComboBoxItem Content='$($_.Name)'/>" }) -join ''
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <Grid>
        <StackPanel Orientation='Horizontal' VerticalAlignment='Center'>
          <TextBlock Text='Region' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Margin='0,0,10,0'/>
          <ComboBox x:Name='Region' Width='160' FontSize='13'>$regions</ComboBox>
          <TextBlock Text='Pick the region you play on. The ping test card shows which is closest.' Foreground='#98989D' FontSize='12' VerticalAlignment='Center' Margin='14,0,0,0'/>
        </StackPanel>
        <Button x:Name='Go' Content='Start monitoring' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' HorizontalAlignment='Right'/>
      </Grid>
      <UniformGrid Columns='4' Margin='0,18,0,0'>
        <StackPanel><TextBlock x:Name='Now' Text='-' FontSize='28' FontWeight='Bold'/><TextBlock Text='ping now (ms)' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
        <StackPanel><TextBlock x:Name='Avg' Text='-' FontSize='28' FontWeight='Bold'/><TextBlock Text='average (ms)' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
        <StackPanel><TextBlock x:Name='Jit' Text='-' FontSize='28' FontWeight='Bold'/><TextBlock Text='jitter (ms)' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
        <StackPanel><TextBlock x:Name='Loss' Text='-' FontSize='28' FontWeight='Bold'/><TextBlock Text='packet loss' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
      </UniformGrid>
      <Border Background='#1C1C1E' BorderThickness='0' CornerRadius='8' Margin='0,16,0,0' Height='170'>
        <Canvas x:Name='Graph' ClipToBounds='True'/>
      </Border>
      <TextBlock Text='Last 2 minutes. Red marks are spikes or lost packets.' Foreground='#98989D' FontSize='11.5' Margin='0,6,0,0'/>
    </StackPanel>
  </Border>
  <TextBlock Text='Spikes' FontSize='16' FontWeight='SemiBold' Margin='0,0,0,8'/>
  <StackPanel x:Name='Spikes'/>
</StackPanel>
"@)
    $pg = @{}; foreach ($n in 'Region', 'Go', 'Now', 'Avg', 'Jit', 'Loss', 'Graph', 'Spikes') { $pg[$n] = $root.FindName($n) }
    $script:PingUi = $pg
    $saved = $script:Backup.Custom['pingregion']
    $idx = [Math]::Max(0, [array]::IndexOf([string[]]($PingHosts | ForEach-Object { $_.Name }), "$saved"))
    $pg.Region.SelectedIndex = $idx
    $pg.Region.Add_SelectionChanged({ $script:Backup.Custom['pingregion'] = $PingHosts[$script:PingUi.Region.SelectedIndex].Name; Save-Backup })
    $pg.Go.Add_Click({ if ($script:PingMonJob) { Stop-PingMonitor } else { Start-PingMonitor } })
    $script:PingMonTimer = New-Object Windows.Threading.DispatcherTimer
    $script:PingMonTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:PingMonTimer.Add_Tick({ Update-PingMonitor })
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'No spikes recorded yet.'; $tb.Foreground = ConvertTo-Brush '#A1A1A6'; [void]$pg.Spikes.Children.Add($tb)
    New-PageScroll $root
}
function Start-PingMonitor {
    $pg = $script:PingUi
    $target = $PingHosts[$pg.Region.SelectedIndex].Host
    Remove-Item $PingLogFile -ErrorAction SilentlyContinue
    $script:PingSamples = New-Object System.Collections.ArrayList
    $script:PingRead = 0
    $script:PingMonJob = Start-Job -ArgumentList $target, $PingLogFile -ScriptBlock {
        param($h, $log)
        $p = New-Object System.Net.NetworkInformation.Ping
        while ($true) {
            $t0 = Get-Date
            $ms = try { $r = $p.Send($h, 1000); if ($r.Status -eq 'Success') { $r.RoundtripTime } else { -1 } } catch { -1 }
            Add-Content -Path $log -Value "$($t0.ToString('HH:mm:ss')),$ms"
            $wait = 1000 - ((Get-Date) - $t0).TotalMilliseconds; if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
        }
    }
    $pg.Go.Content = 'Stop'; $pg.Go.Background = ConvertTo-Brush '#4E3E28'; $pg.Go.Foreground = ConvertTo-Brush '#FF9F0A'
    $pg.Region.IsEnabled = $false
    $script:PingMonTimer.Start()
}
function Stop-PingMonitor {
    $pg = $script:PingUi
    $script:PingMonTimer.Stop()
    if ($script:PingMonJob) { Stop-Job $script:PingMonJob -ErrorAction SilentlyContinue; Remove-Job $script:PingMonJob -Force -ErrorAction SilentlyContinue }
    $script:PingMonJob = $null
    $pg.Go.Content = 'Start monitoring'; $pg.Go.Background = ConvertTo-Brush '#0071E3'; $pg.Go.Foreground = ConvertTo-Brush '#FFFFFF'
    $pg.Region.IsEnabled = $true
}
function Update-PingMonitor {
    $pg = $script:PingUi
    if (-not (Test-Path $PingLogFile)) { return }
    $lines = @(Get-Content $PingLogFile -ErrorAction SilentlyContinue)
    for ($i = $script:PingRead; $i -lt $lines.Count; $i++) {
        $parts = $lines[$i] -split ','
        if ($parts.Count -ne 2) { continue }
        $ms = [int]$parts[1]
        $good = @($script:PingSamples | Where-Object { $_.Ms -ge 0 } | Select-Object -Last 30 | ForEach-Object Ms)
        $med = if ($good.Count -ge 5) { ($good | Sort-Object)[[int]($good.Count / 2)] } else { $null }
        $spike = ($ms -lt 0) -or ($med -and $ms -gt [Math]::Max($med * 1.5, $med + 25))
        [void]$script:PingSamples.Add([pscustomobject]@{ Time = $parts[0]; Ms = $ms; Spike = $spike })
        if ($spike) { Add-PingSpike $parts[0] $ms $med }
    }
    $script:PingRead = $lines.Count
    $all = @($script:PingSamples | Select-Object -Last 120)
    if (-not $all.Count) { return }
    $ok = @($all | Where-Object { $_.Ms -ge 0 })
    $pg.Now.Text = if ($all[-1].Ms -ge 0) { "$($all[-1].Ms)" } else { 'lost' }
    if ($ok.Count) {
        $pg.Avg.Text = '{0:N0}' -f ($ok | Measure-Object Ms -Average).Average
        $diffs = for ($i = 1; $i -lt $ok.Count; $i++) { [Math]::Abs($ok[$i].Ms - $ok[$i - 1].Ms) }
        $pg.Jit.Text = if ($diffs) { '{0:N1}' -f ($diffs | Measure-Object -Average).Average } else { '0' }
    }
    $pg.Loss.Text = '{0:N1}%' -f (100 * ($all.Count - $ok.Count) / $all.Count)
    # graph
    $c = $pg.Graph; $c.Children.Clear()
    $w = [Math]::Max(100, $c.ActualWidth); $h = [Math]::Max(60, $c.ActualHeight)
    $max = [Math]::Max(40, (($ok | Measure-Object Ms -Maximum).Maximum) * 1.2)
    $line = New-Object Windows.Shapes.Polyline
    $line.Stroke = ConvertTo-Brush '#30D158'; $line.StrokeThickness = 2
    for ($i = 0; $i -lt $all.Count; $i++) {
        $x = $w * $i / 119
        if ($all[$i].Ms -ge 0) { [void]$line.Points.Add((New-Object Windows.Point $x, ($h - 8 - ($h - 16) * $all[$i].Ms / $max))) }
        if ($all[$i].Spike) {
            $m = New-Object Windows.Shapes.Rectangle; $m.Width = 3; $m.Height = $h; $m.Fill = ConvertTo-Brush '#66FF453A'
            [Windows.Controls.Canvas]::SetLeft($m, $x - 1); [void]$c.Children.Add($m)
        }
    }
    [void]$c.Children.Add($line)
}
# Logs a spike with whatever was most likely competing for the connection at that moment.
function Add-PingSpike($time, $ms, $med) {
    $pg = $script:PingUi
    if ($pg.Spikes.Children.Count -and $pg.Spikes.Children[0] -is [Windows.Controls.TextBlock]) { $pg.Spikes.Children.Clear() }
    $busy = try {
        Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
            Where-Object { $_.Name -notmatch '^(_Total|Idle|System)$' -and $_.IODataBytesPersec -gt 200000 } |
            Sort-Object IODataBytesPersec -Descending | Select-Object -First 3 |
            ForEach-Object { '{0} {1:N1} MB/s' -f ($_.Name -replace '#\d+$', ''), ($_.IODataBytesPersec / 1MB) }
    } catch { @() }
    $upd = if ((Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running') { 'Windows Update running' } else { $null }
    $what = @($busy) + @($upd) | Where-Object { $_ }
    $text = if ($ms -lt 0) { 'Packet lost' } else { "Spike to $ms ms (normal ~$med ms)" }
    $row = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='16,10' Margin='0,0,0,8'>
  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width='90'/><ColumnDefinition Width='230'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
    <TextBlock Text='$time' Foreground='#A1A1A6' FontSize='12'/>
    <TextBlock Grid.Column='1' Text='$(Esc $text)' Foreground='#FF453A' FontSize='12.5' FontWeight='SemiBold'/>
    <TextBlock Grid.Column='2' Text='$(Esc $(if ($what) { "Busy at the time: $($what -join ', ')" } else { 'Nothing on this PC was busy: likely your Wi-Fi, router or internet provider.' }))' Foreground='#D1D1D6' FontSize='12' TextWrapping='Wrap'/>
  </Grid>
</Border>
"@)
    $pg.Spikes.Children.Insert(0, $row)
    while ($pg.Spikes.Children.Count -gt 50) { $pg.Spikes.Children.RemoveAt(50) }
}

# =============================================================== Sensitivity
# Fortnite: degrees per mouse count = sensitivity (as a fraction, 6% = 0.06) x 0.5555. Matches published pro tables within ~1%.
$FortniteYaw = 0.5555
function New-SensPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <TextBlock Text='Your sensitivity' FontSize='16' FontWeight='SemiBold'/>
      <StackPanel Orientation='Horizontal' Margin='0,14,0,0'>
        <TextBlock Text='Mouse DPI' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Width='110'/>
        <TextBox x:Name='Dpi' Width='110' Padding='8,5' FontSize='14' Text='800'/>
        <TextBlock Text='Fortnite X sensitivity' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Margin='30,0,10,0'/>
        <TextBox x:Name='Sens' Width='90' Padding='8,5' FontSize='14' Text='6.5'/>
        <TextBlock Text='%' Foreground='#A1A1A6' FontSize='14' VerticalAlignment='Center' Margin='6,0,0,0'/>
      </StackPanel>
      <UniformGrid Columns='3' Margin='0,20,0,0'>
        <StackPanel><TextBlock x:Name='Edpi' FontSize='30' FontWeight='Bold' Foreground='#30D158'/><TextBlock Text='eDPI (DPI x sensitivity)' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
        <StackPanel><TextBlock x:Name='Cm' FontSize='30' FontWeight='Bold'/><TextBlock Text='cm for a 360 turn' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
        <StackPanel><TextBlock x:Name='Inch' FontSize='30' FontWeight='Bold'/><TextBlock Text='inches for a 360 turn' Foreground='#A1A1A6' FontSize='12'/></StackPanel>
      </UniformGrid>
      <TextBlock x:Name='Verdict' FontSize='12.5' Foreground='#D1D1D6' Margin='0,14,0,0' TextWrapping='Wrap'/>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <TextBlock Text='Changing DPI? Keep the same aim' FontSize='16' FontWeight='SemiBold'/>
      <StackPanel Orientation='Horizontal' Margin='0,14,0,0'>
        <TextBlock Text='New DPI' Foreground='#A1A1A6' FontSize='12' VerticalAlignment='Center' Width='110'/>
        <TextBox x:Name='NewDpi' Width='110' Padding='8,5' FontSize='14' Text='1600'/>
        <TextBlock x:Name='NewSens' FontSize='14' FontWeight='SemiBold' Foreground='#30D158' VerticalAlignment='Center' Margin='24,0,0,0'/>
      </StackPanel>
      <TextBlock Text='Set the same value for X and Y, and remember Fortnite keeps separate targeting (ADS) and build/edit sensitivities.' Foreground='#98989D' FontSize='12' Margin='0,10,0,0' TextWrapping='Wrap'/>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20'>
    <StackPanel>
      <TextBlock Text='For reference' FontSize='16' FontWeight='SemiBold'/>
      <TextBlock Foreground='#A1A1A6' FontSize='12.5' Margin='0,8,0,0' TextWrapping='Wrap'
                 Text='Most competitive Fortnite players sit between 40 and 70 eDPI, about 26 to 46 cm per 360. Lower is steadier for tracking, higher is quicker for building. Pick what feels controllable, then stop changing it.'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $sg = @{}; foreach ($n in 'Dpi', 'Sens', 'Edpi', 'Cm', 'Inch', 'Verdict', 'NewDpi', 'NewSens') { $sg[$n] = $root.FindName($n) }
    $script:SensUi = $sg
    $saved = $script:Backup.Custom['sens']
    if ($saved) { $sg.Dpi.Text = "$($saved.Dpi)"; $sg.Sens.Text = "$($saved.Sens)" }
    foreach ($n in 'Dpi', 'Sens', 'NewDpi') { $sg[$n].Add_TextChanged({ Update-SensPage }) }
    Update-SensPage
    New-PageScroll $root
}
function Update-SensPage {
    $sg = $script:SensUi
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $dpi = 0.0; $sens = 0.0; $nd = 0.0
    $okD = [double]::TryParse(($sg.Dpi.Text -replace ',', '.'), [Globalization.NumberStyles]::Float, $ci, [ref]$dpi)
    $okS = [double]::TryParse(($sg.Sens.Text -replace ',', '.'), [Globalization.NumberStyles]::Float, $ci, [ref]$sens)
    if (-not ($okD -and $okS) -or $dpi -le 0 -or $sens -le 0) { $sg.Edpi.Text = '-'; $sg.Cm.Text = '-'; $sg.Inch.Text = '-'; $sg.Verdict.Text = 'Enter your DPI and sensitivity.'; return }
    $frac = $sens / 100
    $edpi = $dpi * $frac
    $cm = 914.4 / ($dpi * $frac * $FortniteYaw)
    $sg.Edpi.Text = '{0:N1}' -f $edpi
    $sg.Cm.Text = '{0:N1}' -f $cm
    $sg.Inch.Text = '{0:N1}' -f ($cm / 2.54)
    $sg.Verdict.Text = if ($edpi -lt 40) { 'Lower than most competitive players: very steady aim, but fast turns and building need big arm movements.' }
                       elseif ($edpi -le 70) { 'Inside the range most competitive players use.' }
                       else { 'Higher than most competitive players: quick turns and building, but small tracking adjustments are harder.' }
    if ([double]::TryParse(($sg.NewDpi.Text -replace ',', '.'), [Globalization.NumberStyles]::Float, $ci, [ref]$nd) -and $nd -gt 0) {
        $sg.NewSens.Text = 'Set Fortnite sensitivity to {0:N2}% to keep the same aim.' -f ($sens * $dpi / $nd)
    } else { $sg.NewSens.Text = '' }
    $script:Backup.Custom['sens'] = @{ Dpi = $dpi; Sens = $sens }
}

# =============================================================== Profiles + share codes
$ProfileDir = Join-Path $DataDir 'profiles'
function Get-CurrentProfile([string]$Name) {
    $on = @($Tweaks | Where-Object { $_.Toggle -and $_.State -eq $true -and $_.Id -notlike 'startup:*' -and $_.Id -notlike 'device:*' } | ForEach-Object Id)
    $fps = if (Test-Path $IniPath) { Get-IniValue (Get-Content $IniPath) 'FrameRateLimit' } else { $null }
    [ordered]@{
        Name = $Name; Created = (Get-Date).ToString('o'); App = 'ZeroDelay'; Version = 1
        On = $on; Preset = $script:Backup.Custom['lastpreset']; FpsCap = $fps
        GameMode = (Get-GameModePrefs); Session = (Get-SessionPrefs)
    }
}
function Get-Profiles {
    if (-not (Test-Path $ProfileDir)) { return @() }
    @(Get-ChildItem $ProfileDir -Filter *.json | ForEach-Object { try { $o = Get-Content $_.FullName -Raw | ConvertFrom-Json; $o | Add-Member -NotePropertyName File -NotePropertyValue $_.FullName -Force; $o } catch {} } | Sort-Object Created -Descending)
}
function Save-Profile($prof) {
    New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
    $safe = ($prof.Name -replace '[^\w\- ]', '').Trim(); if (-not $safe) { $safe = 'Profile' }
    $prof | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ProfileDir "$safe.json") -Encoding UTF8
}
# Share code: "ZD1:" + base64 of gzip-compressed JSON.
function ConvertTo-ShareCode($prof) {
    $o = [ordered]@{}; foreach ($k in 'Name', 'App', 'Version', 'On', 'Preset', 'FpsCap', 'GameMode', 'Session') { $o[$k] = $prof.$k }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Depth 6 -Compress))
    $ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
    'ZD1:' + [Convert]::ToBase64String($ms.ToArray())
}
function ConvertFrom-ShareCode([string]$Code) {
    $Code = $Code.Trim()
    if ($Code -notlike 'ZD1:*') { throw 'That is not a ZeroDelay share code (it should start with ZD1:).' }
    $ms = New-Object IO.MemoryStream(, [Convert]::FromBase64String($Code.Substring(4)))
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader($gz); $json = $sr.ReadToEnd(); $sr.Close()
    $o = $json | ConvertFrom-Json
    if ($o.App -ne 'ZeroDelay') { throw 'That code was not made by ZeroDelay.' }
    # only known card ids are ever acted on, so a code cannot run anything else
    $o.On = @($o.On | Where-Object { $id = $_; $Tweaks | Where-Object { $_.Id -eq $id -and $_.Toggle } })
    $o
}
function Invoke-Profile($prof, [bool]$Strict) {
    $ok = 0; $failed = @()
    $want = @($prof.On)
    foreach ($t in $Tweaks | Where-Object { $_.Toggle -and $want -contains $_.Id -and $_.State -eq $false }) {
        try { Invoke-TweakOn $t; $ok++ } catch { $failed += $t.Title }
    }
    if ($Strict) {
        foreach ($t in $Tweaks | Where-Object { $_.Toggle -and $_.State -eq $true -and $want -notcontains $_.Id -and $_.Id -notlike 'startup:*' -and $_.Id -notlike 'device:*' -and (Test-TweakHasBackup $_.Id) }) {
            try { Invoke-TweakOff $t; $ok++ } catch { $failed += $t.Title }
        }
    }
    if ($prof.GameMode) { $script:Backup.Custom['gamemodeprefs'] = ConvertTo-OrderedTable $prof.GameMode }
    if ($prof.Session) { $script:Backup.Custom['sessionprefs'] = ConvertTo-OrderedTable $prof.Session }
    $note = ''
    if ($prof.Preset -or $prof.FpsCap) {
        if (Test-FortniteRunning) { $note = ' Close Fortnite and apply again for the graphics preset and FPS cap.' }
        else {
            if ($prof.Preset) { try { Invoke-Preset @{ Title = $prof.Preset.Title; Preset = (ConvertTo-OrderedTable $prof.Preset.Values) } | Out-Null } catch { $failed += 'graphics preset' } }
            if ($prof.FpsCap) { try { $l = Get-Content $IniPath; Set-Content $IniPath (Set-IniValue $l 'FrameRateLimit' $prof.FpsCap) -Encoding UTF8 } catch { $failed += 'FPS cap' } }
        }
    }
    Save-Backup; Update-All
    Add-History "Profile applied: $($prof.Name)" 'profile' $null
    "Profile '$($prof.Name)' applied: $ok change$(if ($ok -ne 1) { 's' })." + $note + $(if ($failed) { " Skipped: $($failed -join ', ')." } else { '' })
}

function New-ProfilesPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <TextBlock Text='Save your current setup' FontSize='16' FontWeight='SemiBold'/>
      <TextBlock Text='Saves every switched-on card, your graphics preset, FPS cap and Game Mode choices.' Foreground='#A1A1A6' FontSize='12.5' Margin='0,4,0,0'/>
      <StackPanel Orientation='Horizontal' Margin='0,14,0,0'>
        <TextBox x:Name='Name' Width='260' Padding='8,5' FontSize='13' Text='Tournament'/>
        <Button x:Name='Save' Content='Save profile' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Margin='10,0,0,0'/>
      </StackPanel>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <TextBlock Text='Import a share code' FontSize='16' FontWeight='SemiBold'/>
      <TextBlock Text='Paste a code a friend copied from their ZeroDelay. You will see what it contains before anything changes.' Foreground='#A1A1A6' FontSize='12.5' Margin='0,4,0,0'/>
      <StackPanel Orientation='Horizontal' Margin='0,14,0,0'>
        <TextBox x:Name='Code' Width='420' Padding='8,5' FontSize='12'/>
        <Button x:Name='Import' Content='Import' Style='{DynamicResource Btn}' Margin='10,0,0,0'/>
      </StackPanel>
    </StackPanel>
  </Border>
  <CheckBox x:Name='Strict' Foreground='#D1D1D6' FontSize='12.5' Margin='2,0,0,12' Content='When applying, also switch off cards that are not in the profile'/>
  <StackPanel x:Name='List'/>
</StackPanel>
"@)
    $pr = @{}; foreach ($n in 'Name', 'Save', 'Code', 'Import', 'Strict', 'List') { $pr[$n] = $root.FindName($n) }
    $script:ProfUi = $pr
    $pr.Save.Add_Click({
        $n = $script:ProfUi.Name.Text.Trim(); if (-not $n) { Show-Toast 'Give the profile a name.' '#FF9F0A'; return }
        Save-Profile (Get-CurrentProfile $n); Show-Toast "Saved profile '$n'." '#30D158'; Update-ProfilesPage
    })
    $pr.Import.Add_Click({
        try {
            $o = ConvertFrom-ShareCode $script:ProfUi.Code.Text
            $r = (Show-ZdDialog ("Profile '$($o.Name)' switches on $(@($o.On).Count) cards$(if ($o.Preset) { ", sets the '$($o.Preset.Title)' graphics preset" })$(if ($o.FpsCap) { " and an FPS cap of $([int][double]$o.FpsCap)" }).`n`nSave it to your profiles? (Nothing changes until you press Apply.)") ('Import profile') ('YesNo') ('Question'))
            if ($r -ne 'Yes') { return }
            $o | Add-Member -NotePropertyName Created -NotePropertyValue (Get-Date).ToString('o') -Force
            Save-Profile $o; $script:ProfUi.Code.Text = ''; Show-Toast "Imported '$($o.Name)'." '#30D158'; Update-ProfilesPage
        } catch { Show-Toast $_.Exception.Message '#FF9F0A' }
    })
    $script:PageRefresh['Profiles'] = { Update-ProfilesPage }
    Update-ProfilesPage
    New-PageScroll $root
}
function Update-ProfilesPage {
    $pr = $script:ProfUi; if (-not $pr) { return }
    $pr.List.Children.Clear()
    $list = @(Get-Profiles)
    if (-not $list.Count) { $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'No profiles yet. Save your current setup above.'; $tb.Foreground = ConvertTo-Brush '#A1A1A6'; [void]$pr.List.Children.Add($tb); return }
    foreach ($o in $list) {
        $when = try { ([datetime]$o.Created).ToString('dd MMM yyyy') } catch { '' }
        $row = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='18,14' Margin='0,0,0,10'>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <StackPanel>
      <TextBlock Text='$(Esc $o.Name)' FontSize='14' FontWeight='SemiBold'/>
      <TextBlock Text='$(Esc "$when  ·  $(@($o.On).Count) cards$(if ($o.Preset) { "  ·  preset $($o.Preset.Title)" })$(if ($o.FpsCap) { "  ·  $([int][double]$o.FpsCap) FPS cap" })")' FontSize='12' Foreground='#A1A1A6' Margin='0,4,0,0'/>
    </StackPanel>
    <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'>
      <Button x:Name='Apply' Content='Apply' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Padding='14,6' FontSize='12' Margin='0,0,8,0'/>
      <Button x:Name='Copy' Content='Copy code' Style='{DynamicResource Btn}' Padding='12,6' FontSize='12' Margin='0,0,8,0'/>
      <Button x:Name='Del' Content='Delete' Style='{DynamicResource Btn}' Foreground='#FF453A' Padding='12,6' FontSize='12'/>
    </StackPanel>
  </Grid>
</Border>
"@)
        foreach ($n in 'Apply', 'Copy', 'Del') { $row.FindName($n).Tag = $o }
        $row.FindName('Apply').Add_Click({
            param($s, $e)
            $window.Cursor = [Windows.Input.Cursors]::Wait
            $msg = Invoke-Profile $s.Tag ([bool]$script:ProfUi.Strict.IsChecked)
            $window.Cursor = $null; Show-Toast $msg '#30D158'
        })
        $row.FindName('Copy').Add_Click({ param($s, $e) [Windows.Clipboard]::SetText((ConvertTo-ShareCode $s.Tag)); Show-Toast 'Share code copied. Paste it to a friend; they import it on their Profiles page.' '#30D158' })
        $row.FindName('Del').Add_Click({ param($s, $e) Remove-Item $s.Tag.File -Force -ErrorAction SilentlyContinue; Update-ProfilesPage })
        [void]$pr.List.Children.Add($row)
    }
}

# =============================================================== First-run setup wizard
function Get-HardwareSummary {
    $cpu = Get-CpuName
    $gpu = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $DiscreteGpuRx } | Select-Object -First 1).Name
    if (-not $gpu) { $gpu = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1).Name }
    $ram = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $gb = [int](($ram | Measure-Object Capacity -Sum).Sum / 1GB); $mts = ($ram | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
    $hz = (Get-Displays | Where-Object Discrete | Measure-Object Hz -Maximum).Maximum
    $laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    [pscustomobject]@{ Cpu = $cpu; Gpu = $gpu; RamGb = $gb; RamMts = $mts; Hz = $hz; Laptop = $laptop; Nvidia = ($gpu -match 'NVIDIA|GeForce|RTX|GTX') }
}
function Show-Wizard {
    $hw = Get-HardwareSummary
    $script:WizHw = $hw
    $body = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <TextBlock Text='Welcome to ZeroDelay' FontSize='24' FontWeight='Bold'/>
  <TextBlock Text='Three quick questions and ZeroDelay sets up your PC. You can change everything afterwards.' Foreground='#A1A1A6' FontSize='13' Margin='0,6,0,18' TextWrapping='Wrap'/>
  <Border Background='#1C1C1E' BorderThickness='0' CornerRadius='8' Padding='16,12' Margin='0,0,0,18'>
    <StackPanel>
      <TextBlock Text='$(Esc "CPU      $($hw.Cpu)")' FontFamily='Consolas' FontSize='12' Foreground='#D1D1D6'/>
      <TextBlock Text='$(Esc "GPU      $($hw.Gpu)")' FontFamily='Consolas' FontSize='12' Foreground='#D1D1D6'/>
      <TextBlock Text='$(Esc "RAM      $($hw.RamGb) GB at $($hw.RamMts) MT/s")' FontFamily='Consolas' FontSize='12' Foreground='#D1D1D6'/>
      <TextBlock Text='$(Esc "Monitor  $($hw.Hz) Hz")' FontFamily='Consolas' FontSize='12' Foreground='#D1D1D6'/>
    </StackPanel>
  </Border>
  <TextBlock x:Name='PcLine' Text='Scanning your PC: hardware, drivers, Windows and installed apps...' FontSize='12' Foreground='#98989D' Margin='0,-8,0,18' TextWrapping='Wrap'/>
  <TextBlock Text='1. What kind of PC is this?' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,8'/>
  <StackPanel Orientation='Horizontal' Margin='0,0,0,16'>
    <RadioButton x:Name='Desk' GroupName='pc' Content='Desktop' Foreground='#D1D1D6' FontSize='13' Margin='0,0,24,0'/>
    <RadioButton x:Name='Lap' GroupName='pc' Content='Laptop' Foreground='#D1D1D6' FontSize='13'/>
  </StackPanel>
  <TextBlock Text='2. How should Fortnite look?' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,8'/>
  <StackPanel Margin='0,0,0,16'>
    <RadioButton x:Name='LookComp' GroupName='look' Content='Competitive: sharp and clear, high FPS' Foreground='#D1D1D6' FontSize='13' Margin='0,0,0,6' IsChecked='True'/>
    <RadioButton x:Name='LookFlat' GroupName='look' Content='Flat potato: solid colours, maximum FPS (NVIDIA)' Foreground='#D1D1D6' FontSize='13' Margin='0,0,0,6'/>
    <RadioButton x:Name='LookKeep' GroupName='look' Content='Keep my current graphics settings' Foreground='#D1D1D6' FontSize='13'/>
  </StackPanel>
  <TextBlock Text='3. Do you stream or record while you play?' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,8'/>
  <StackPanel Orientation='Horizontal' Margin='0,0,0,22'>
    <RadioButton x:Name='StreamNo' GroupName='st' Content='No' Foreground='#D1D1D6' FontSize='13' Margin='0,0,24,0' IsChecked='True'/>
    <RadioButton x:Name='StreamYes' GroupName='st' Content='Yes' Foreground='#D1D1D6' FontSize='13'/>
  </StackPanel>
  <TextBlock x:Name='Progress' FontSize='12.5' Foreground='#30D158' Margin='0,0,0,10' TextWrapping='Wrap'/>
  <Grid>
    <Button x:Name='Skip' Content='Skip, I will set it up myself' Style='{DynamicResource Btn}' HorizontalAlignment='Left'/>
    <Button x:Name='Go' Content='Set up my PC' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' HorizontalAlignment='Right'/>
  </Grid>
</StackPanel>
"@)
    $wz = @{}; foreach ($n in 'Desk', 'Lap', 'LookComp', 'LookFlat', 'LookKeep', 'StreamNo', 'StreamYes', 'Progress', 'Skip', 'Go', 'PcLine') { $wz[$n] = $body.FindName($n) }
    $script:Wiz = $wz
    if ($hw.Laptop) { $wz.Lap.IsChecked = $true } else { $wz.Desk.IsChecked = $true }
    if (-not $hw.Nvidia) { $wz.LookFlat.IsEnabled = $false }
    $wz.Skip.Add_Click({ $script:Backup.Custom['wizarddone'] = $true; Save-Backup; $ui.Wizard.Visibility = 'Collapsed' })
    $wz.Go.Add_Click({ Invoke-Wizard })
    if ($script:SysProfile) { Update-WizardProfileLine }
    $ui.WizardBody.Content = $body
    $ui.Wizard.Visibility = 'Visible'
    if ($script:Anim) {
        Start-Anim $ui.Wizard ([Windows.UIElement]::OpacityProperty) 0 1 220
        Show-Animated $ui.WizardBody 24 380 60
    }
}
function Invoke-Wizard {
    $wz = $script:Wiz
    $wz.Go.IsEnabled = $false; $wz.Skip.IsEnabled = $false
    $say = { param($m) $script:Wiz.Progress.Text = $m; $window.Dispatcher.Invoke([action] {}, 'Render') }
    $laptop = [bool]$wz.Lap.IsChecked; $stream = [bool]$wz.StreamYes.IsChecked
    & $say 'Creating a restore point...'
    $rp = New-ZeroDelayRestorePoint
    & $say 'Applying recommended tweaks...'
    $skipPower = 'zdplan', 'power', 'minstate', 'epp', 'boostmode', 'coreparking', 'throttle'
    $ok = 0
    foreach ($t in $Tweaks | Where-Object { $_.Rec -and $_.Toggle -and $_.State -eq $false }) {
        if ($laptop -and $skipPower -contains $t.Id) { continue }
        if ($stream -and $t.Id -in 'lowprio', 'cpuprio') { continue }
        try { Invoke-TweakOn $t; $ok++ } catch {}
    }
    if (-not $laptop) { try { $zd = $Tweaks | Where-Object { $_.Id -eq 'zdplan' }; if ((Invoke-TweakTest $zd) -eq $false) { Invoke-TweakOn $zd; $ok++ } } catch {} }
    $msg = @("$ok tweaks on")
    if (-not (Test-FortniteRunning)) {
        $preset = if ($wz.LookComp.IsChecked) { 'preset-competitive' } elseif ($wz.LookFlat.IsChecked) { 'preset-flatcolours' } else { $null }
        if ($preset) { & $say 'Setting your graphics...'; try { $pt = $Tweaks | Where-Object { $_.Id -eq $preset }; Invoke-Preset $pt | Out-Null; $msg += "$($pt.Title) graphics" } catch {} }
        if ((Test-VrrActive) -ne $false) { try { & ($Tweaks | Where-Object { $_.Id -eq 'vrrcap' }).Run | Out-Null; $msg += 'FPS cap set' } catch {} }
    } else { $msg += 'close Fortnite and use the Potato tab for graphics' }
    $gm = Get-GameModePrefs
    if ($stream) { $gm['priority'] = $false; $sp = Get-SessionPrefs; $sp['streamdock'] = $false; $script:Backup.Custom['sessionprefs'] = $sp }
    if ($laptop) { $gm['plan'] = $false }
    $script:Backup.Custom['gamemodeprefs'] = $gm
    $script:Backup.Custom['wizarddone'] = $true
    Save-Backup; Update-All
    Add-History 'Setup wizard finished' 'wizard' $null
    $ui.Wizard.Visibility = 'Collapsed'
    Show-Toast ("All set: $($msg -join ', '). " + $(if ($rp -like 'Restore point created*') { 'A restore point was made first.' } else { '' })) '#30D158'
    $script:NavButtons['Health'].IsChecked = $true
}

# =============================================================== Settings (tray, auto-fix)
function Get-Setting([string]$Key, $Default) { if ($script:Backup.Custom.ContainsKey($Key)) { $script:Backup.Custom[$Key] } else { $Default } }

function New-SettingsPage {
    $rows = @(
        @{ Key = 'closetotray'; Title = 'Closing the window keeps ZeroDelay in the tray'; Desc = 'The X button hides ZeroDelay next to the clock instead of quitting. Right-click the tray icon to exit.' }
        @{ Key = 'startup';    Title = 'Start ZeroDelay when you sign in to Windows'; Desc = 'Opens quietly in the tray (no window), so Game Mode and match reports work without opening the app. Uses a Windows scheduled task named ZeroDelay; switching this off removes it.' }
        @{ Key = 'autofix';    Title = 'Automatically re-apply settings other programs change'; Desc = 'Instead of showing the orange bar, ZeroDelay quietly puts your settings back and tells you.' }
        @{ Key = 'matchreport'; Title = 'Match reports'; Desc = 'Watches quietly while Fortnite runs and shows what got in the way when you close it (Tools > Match reports). Uses about 1% of one CPU core.' }
        @{ Key = 'autoupdate'; Title = 'Check for new versions'; Desc = 'Asks GitHub when ZeroDelay starts and every 6 hours whether a newer version is out. Nothing is downloaded or installed unless you choose to.' }
    )
    $xr = ($rows | ForEach-Object {
        "<Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,0,0,10'><Grid>" +
        "<Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<StackPanel><TextBlock Text='$(Esc $_.Title)' FontSize='14' FontWeight='SemiBold'/><TextBlock Text='$(Esc $_.Desc)' FontSize='12.5' Foreground='#A1A1A6' Margin='0,4,20,0' TextWrapping='Wrap'/></StackPanel>" +
        "<ToggleButton x:Name='S_$($_.Key)' Grid.Column='1' Style='{DynamicResource Switch}' VerticalAlignment='Center'/></Grid></Border>"
    }) -join ''
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,0,0,10'>
    <StackPanel>
      <TextBlock Text='Appearance' FontSize='14' FontWeight='SemiBold'/>
      <Grid Margin='0,14,0,0'>
        <Grid.ColumnDefinitions><ColumnDefinition Width='120'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text='Theme' Foreground='#A1A1A6' FontSize='12.5' VerticalAlignment='Center'/>
        <StackPanel Grid.Column='1' Orientation='Horizontal'>
          <Button x:Name='T_dark' Content='Dark' Style='{DynamicResource Btn}' Margin='0,0,8,0' MinWidth='72'/>
          <Button x:Name='T_light' Content='Light' Style='{DynamicResource Btn}' Margin='0,0,8,0' MinWidth='72'/>
          <Button x:Name='T_system' Content='Match Windows' Style='{DynamicResource Btn}'/>
        </StackPanel>
        <TextBlock Grid.Row='1' Text='Accent colour' Foreground='#A1A1A6' FontSize='12.5' VerticalAlignment='Center' Margin='0,14,0,0'/>
        <StackPanel x:Name='Swatches' Grid.Row='1' Grid.Column='1' Orientation='Horizontal' Margin='0,14,0,0'/>
        <TextBlock Grid.Row='2' Text='Glass' Foreground='#A1A1A6' FontSize='12.5' VerticalAlignment='Center' Margin='0,14,0,0'/>
        <StackPanel Grid.Row='2' Grid.Column='1' Orientation='Horizontal' Margin='0,14,0,0'>
          <ToggleButton x:Name='S_glass' Style='{DynamicResource Switch}' VerticalAlignment='Center'/>
          <TextBlock Text='Frosted, see-through window and panels (Windows 11)' Foreground='#98989D' FontSize='12' VerticalAlignment='Center' Margin='10,0,0,0'/>
        </StackPanel>
      </Grid>
      <Border x:Name='ThemeNote' Background='#1C1C1E' CornerRadius='8' Padding='14,10' Margin='0,16,0,0' Visibility='Collapsed'>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
          <TextBlock Text='ZeroDelay restarts to switch its look. It takes about 3 seconds.' Foreground='#D1D1D6' FontSize='12.5' VerticalAlignment='Center' TextWrapping='Wrap'/>
          <Button x:Name='ThemeApply' Grid.Column='1' Content='Restart ZeroDelay' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Margin='12,0,0,0'/>
        </Grid>
      </Border>
    </StackPanel>
  </Border>
  $xr
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,6,0,10'>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock x:Name='VerTitle' FontSize='14' FontWeight='SemiBold'/>
          <TextBlock x:Name='UpdStatus' FontSize='12.5' Foreground='#A1A1A6' Margin='0,4,20,0' TextWrapping='Wrap'/>
        </StackPanel>
        <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'>
          <Button x:Name='UpdCheck' Content='Check for updates' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
          <Button x:Name='UpdGet' Content='Download' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Margin='0,0,8,0' Visibility='Collapsed'/>
          <Button x:Name='UpdReport' Content='Report a problem' Style='{DynamicResource Btn}' Margin='0,0,8,0' ToolTip='Opens a new GitHub issue with your PC details filled in. Needs a free GitHub account.'/>
          <Button x:Name='UpdRepo' Content='GitHub page' Style='{DynamicResource Btn}'/>
        </StackPanel>
      </Grid>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,0,0,10'>
    <StackPanel>
      <TextBlock Text='More' FontSize='14' FontWeight='SemiBold'/>
      <StackPanel Orientation='Horizontal' Margin='0,12,0,0'>
        <Button x:Name='Wizard' Content='Run the setup wizard again' Style='{DynamicResource Btn}' Margin='0,0,10,0'/>
        <Button x:Name='Folder' Content='Open ZeroDelay data folder' Style='{DynamicResource Btn}'/>
      </StackPanel>
      <TextBlock x:Name='About' FontSize='12' Foreground='#98989D' Margin='0,14,0,0' TextWrapping='Wrap'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $st = @{}; foreach ($n in 'S_closetotray', 'S_autofix', 'S_autoupdate', 'S_startup', 'S_matchreport', 'UpdReport', 'Wizard', 'Folder', 'About', 'T_dark', 'T_light', 'T_system', 'Swatches', 'ThemeNote', 'ThemeApply', 'S_glass',
                              'VerTitle', 'UpdStatus', 'UpdCheck', 'UpdGet', 'UpdRepo') { $st[$n] = $root.FindName($n) }
    $script:SetUi = $st
    $st.S_closetotray.IsChecked = [bool](Get-Setting 'closetotray' $true)
    $st.S_autofix.IsChecked = [bool](Get-Setting 'autofix' $false)
    $st.S_closetotray.Add_Click({ param($s, $e) $script:Backup.Custom['closetotray'] = [bool]$s.IsChecked; Save-Backup })
    $st.S_autofix.Add_Click({ param($s, $e) $script:Backup.Custom['autofix'] = [bool]$s.IsChecked; Save-Backup })
    $st.Wizard.Add_Click({ Show-Wizard })
    $st.Folder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })
    $st.About.Text = "ZeroDelay $AppVersion  ·  app: $PSCommandPath  ·  data and backups: $DataDir"
    $st.S_matchreport.IsChecked = [bool](Get-Setting 'matchreport' $true)
    $st.S_matchreport.Add_Click({ param($s, $e) $script:Backup.Custom['matchreport'] = [bool]$s.IsChecked; Save-Backup })
    $st.S_startup.IsChecked = [bool](Get-StartupTask)
    if ($NoElevate) { $st.S_startup.IsEnabled = $false }
    $st.S_startup.Add_Click({ param($s, $e)
        try {
            Set-StartWithWindows ([bool]$s.IsChecked)
            Show-Toast $(if ($s.IsChecked) { 'ZeroDelay will start in the tray when you sign in.' } else { 'ZeroDelay no longer starts with Windows.' }) '#30D158'
        } catch { $s.IsChecked = [bool](Get-StartupTask); Show-Toast "Could not change this: $($_.Exception.Message)" '#FF9F0A' }
    })
    $st.UpdReport.Add_Click({ Open-ProblemReport })
    $st.S_autoupdate.IsChecked = [bool](Get-Setting 'autoupdate' $true)
    $st.S_autoupdate.Add_Click({ param($s, $e)
        $script:Backup.Custom['autoupdate'] = [bool]$s.IsChecked; Save-Backup
        if ($s.IsChecked) { Start-UpdateCheck } else { $ui.UpdateBar.Visibility = 'Collapsed' }
    })
    # theme: Dark / Light / Match Windows
    foreach ($m in 'dark', 'light', 'system') {
        $st["T_$m"].Tag = $m
        $st["T_$m"].Add_Click({ param($s, $e) $script:Backup.Custom['theme'] = $s.Tag; Save-Backup; Update-AppearanceUi })
    }
    # accent swatches: a coloured dot inside a ring that shows the current choice
    foreach ($k in $Accents.Keys) {
        $ring = New-Object Windows.Controls.Border
        $ring.Width = 30; $ring.Height = 30; $ring.CornerRadius = 15; $ring.BorderThickness = 2; $ring.Padding = 3; $ring.Margin = '0,0,8,0'
        $ring.Cursor = [Windows.Input.Cursors]::Hand; $ring.ToolTip = $Accents[$k].Name; $ring.Tag = $k; $ring.Background = [Windows.Media.Brushes]::Transparent
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString("#$($Accents[$k].Dark[0])"))
        $ring.Child = $dot
        $ring.Add_MouseLeftButtonUp({ param($s, $e) $script:Backup.Custom['accent'] = $s.Tag; Save-Backup; Update-AppearanceUi })
        [void]$st.Swatches.Children.Add($ring)
    }
    $st.ThemeApply.Add_Click({ Restart-ZeroDelay })
    $st.S_glass.IsChecked = [bool](Get-Setting 'glass' $true)
    if ([Environment]::OSVersion.Version.Build -lt 22621) { $st.S_glass.IsEnabled = $false; $st.S_glass.ToolTip = 'Needs Windows 11 22H2 or newer' }
    $st.S_glass.Add_Click({ param($s, $e) $script:Backup.Custom['glass'] = [bool]$s.IsChecked; Save-Backup; Update-AppearanceUi })
    Update-AppearanceUi
    # version and updates
    $st.VerTitle.Text = "ZeroDelay $AppVersion"
    $st.UpdCheck.Add_Click({ Start-UpdateCheck -Manual })
    $st.UpdGet.Add_Click({ Install-Update })
    $st.UpdRepo.Add_Click({ Start-Process "https://github.com/$UpdateRepo" })
    Update-UpdateUi
    New-PageScroll $root
}

function Update-AppearanceUi {
    $st = $script:SetUi; if (-not $st) { return }
    $mode = Get-Setting 'theme' 'dark'
    $acc = Get-Setting 'accent' 'blue'
    foreach ($m in 'dark', 'light', 'system') {
        $b = $st["T_$m"]
        if ($m -eq $mode) { $b.Background = [ZdTheme]::Brush('#0071E3'); $b.Foreground = [ZdTheme]::Brush('#FFFFFF') }
        else { $b.ClearValue([Windows.Controls.Control]::BackgroundProperty); $b.ClearValue([Windows.Controls.Control]::ForegroundProperty) }
    }
    $st.T_system.ToolTip = "Windows is set to $(Get-SystemTheme) mode."
    foreach ($ring in $st.Swatches.Children) {
        $ring.BorderBrush = if ($ring.Tag -eq $acc) { [ZdTheme]::Brush('#F5F5F7') } else { [Windows.Media.Brushes]::Transparent }
    }
    $changed = ($mode -ne $script:ThemeMode) -or ($acc -ne $script:Accent) -or ([bool](Get-Setting 'glass' $true) -ne $script:GlassSetting)
    $st.ThemeNote.Visibility = if ($changed) { 'Visible' } else { 'Collapsed' }
}
# Closes this window and starts a fresh copy on the Settings page (used to switch theme).
function Restart-ZeroDelay {
    Save-Backup
    $script:Relaunch = $true
    $script:ReallyExit = $true
    $window.Close()
}

# --- Update check: asks GitHub for the latest release. Runs in the background; never downloads anything itself.
function Get-TagVersion([string]$Tag) {
    $v = $null
    if ([version]::TryParse(($Tag -replace '^[vV]', '' -replace '[^0-9.].*$', ''), [ref]$v)) { $v } else { $null }
}
function Start-UpdateCheck([switch]$Manual) {
    if ($script:UpdateTask -and -not $script:UpdateTask.IsCompleted) { return }
    $script:UpdateManual = [bool]$Manual
    if ($Manual) { $script:UpdateSnoozed = $false }
    if ($env:ZD_FAKE_UPDATE) { Set-UpdateResult @{ Tag = $env:ZD_FAKE_UPDATE; Url = "https://github.com/$UpdateRepo/releases" }; return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = "ZeroDelay/$AppVersion"
        $wc.Headers['Accept'] = 'application/vnd.github+json'
        $script:UpdateTask = $wc.DownloadStringTaskAsync("https://api.github.com/repos/$UpdateRepo/releases/latest")
    } catch { Set-UpdateResult $null 'Could not check for updates.'; return }
    if ($script:SetUi) { $script:SetUi.UpdStatus.Text = 'Checking...' }
    if (-not $script:UpdatePoll) {
        $script:UpdatePoll = New-Object Windows.Threading.DispatcherTimer
        $script:UpdatePoll.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:UpdatePoll.Add_Tick({
            $task = $script:UpdateTask
            if (-not $task -or -not $task.IsCompleted) { return }
            $script:UpdatePoll.Stop()
            if ($task.IsFaulted -or $task.IsCanceled) {
                $msg = "$($task.Exception.InnerException.Message)"
                Set-UpdateResult $null $(if ($msg -match '404') { 'No release has been published yet.' } else { 'Could not reach GitHub. Check your internet connection and try again.' })
                return
            }
            try { $j = $task.Result | ConvertFrom-Json; Set-UpdateResult @{ Tag = "$($j.tag_name)"; Url = "$($j.html_url)"; Body = "$($j.body)"; Assets = @($j.assets) } }
            catch { Set-UpdateResult $null 'GitHub sent an answer ZeroDelay could not read.' }
        })
    }
    $script:UpdatePoll.Start()
}
function Set-UpdateResult($r, [string]$err) {
    $script:UpdateChecked = Get-Date
    if (-not $r) {
        $script:UpdateError = $err
        if ($script:UpdateManual) { Show-Toast $err '#FF9F0A' }
        Update-UpdateUi; return
    }
    $script:UpdateError = $null
    $latest = Get-TagVersion $r.Tag
    $script:UpdateInfo = $null
    if ($latest -and $latest -gt [version]$AppVersion) {
        $asset = @($r.Assets) | Where-Object { $_.name -like '*Setup*.exe' } | Select-Object -First 1
        $sha = if ("$($r.Body)" -match '\b([A-Fa-f0-9]{64})\b') { $Matches[1].ToUpper() } else { $null }
        $script:UpdateInfo = @{ Version = "$latest"; Url = $r.Url; SetupUrl = "$($asset.browser_download_url)"; Size = [long]$asset.size; Sha = $sha }
    }
    if ($script:UpdateManual -and -not $script:UpdateInfo) { Show-Toast "You have the latest version ($AppVersion)." '#30D158' }
    Update-UpdateUi
}
function Update-UpdateUi {
    $u = $script:UpdateInfo
    if ($u -and -not $script:UpdateSnoozed) {
        $ui.UpdateTitle.Text = "ZeroDelay $($u.Version) is available"
        $ui.UpdateText.Text = if ($script:UpdateDl) { $script:UpdateDl.Status }
                              elseif ($u.SetupUrl -and $u.Sha) { "You have $AppVersion. ZeroDelay closes, updates and opens again in about 10 seconds. Your settings are kept." }
                              else { "You have $AppVersion. Download the new setup, exit ZeroDelay from the tray, then run it. Your settings are kept." }
        $ui.UpdateGet.Content = if ($u.SetupUrl -and $u.Sha) { 'Update now' } else { 'Download' }
        $ui.UpdateGet.IsEnabled = -not $script:UpdateDl; $ui.UpdateLater.IsEnabled = -not $script:UpdateDl
        if ($ui.UpdateBar.Visibility -ne 'Visible') { $ui.UpdateBar.Visibility = 'Visible'; Show-Animated $ui.UpdateBar -8 260 }
    } else { $ui.UpdateBar.Visibility = 'Collapsed' }
    $st = $script:SetUi; if (-not $st) { return }
    $st.UpdGet.Visibility = if ($u) { 'Visible' } else { 'Collapsed' }
    if ($u) { $st.UpdGet.Content = if ($u.SetupUrl -and $u.Sha) { "Update to $($u.Version)" } else { "Download $($u.Version)" }; $st.UpdGet.IsEnabled = -not $script:UpdateDl }
    $st.UpdStatus.Text = if ($script:UpdateDl) { $script:UpdateDl.Status }
                         elseif ($u) { "Version $($u.Version) is out. Your settings, backups and history are kept when you update." }
                         elseif ($script:UpdateError) { $script:UpdateError }
                         elseif ($script:UpdateChecked) { "You have the latest version. Checked at $($script:UpdateChecked.ToString('HH:mm'))." }
                         else { 'Not checked yet.' }
}
function Open-UpdatePage {
    $url = if ($script:UpdateInfo) { $script:UpdateInfo.Url } else { "https://github.com/$UpdateRepo/releases/latest" }
    Start-Process $url
}

# --- One-click update: download the new setup from the GitHub release, check its SHA-256 against the
#     release notes, then let the setup replace this copy and reopen ZeroDelay.
function Install-Update {
    $u = $script:UpdateInfo
    if (-not $u -or $script:UpdateDl) { return }
    if (-not $u.SetupUrl -or -not $u.Sha) { Open-UpdatePage; return }
    $r = (Show-ZdDialog ("Update ZeroDelay to $($u.Version) now?`n`nZeroDelay downloads the new setup from GitHub, checks it, closes, installs it and opens again. It takes about 10 seconds. Your settings, backups and history are kept.") ('ZeroDelay update') ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    $dir = Join-Path $env:TEMP 'ZeroDelay-Update'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir "ZeroDelay-Setup-$($u.Version).exe"
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = "ZeroDelay/$AppVersion"
        $task = $wc.DownloadFileTaskAsync([uri]$u.SetupUrl, $file)
    } catch { Show-Toast "Could not start the download: $($_.Exception.Message)" '#FF9F0A'; return }
    $script:UpdateDl = @{ Task = $task; File = $file; Info = $u; Status = "Downloading ZeroDelay $($u.Version)..." }
    $script:UpdateSnoozed = $false
    Update-UpdateUi
    $script:UpdateDlTimer = New-Object Windows.Threading.DispatcherTimer
    $script:UpdateDlTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:UpdateDlTimer.Add_Tick({ Watch-UpdateDownload })
    $script:UpdateDlTimer.Start()
}
function Watch-UpdateDownload {
    $d = $script:UpdateDl
    if (-not $d.Task.IsCompleted) {
        $len = try { (Get-Item $d.File -ErrorAction Stop).Length } catch { 0 }
        if ($d.Info.Size -gt 0) { $d.Status = "Downloading ZeroDelay $($d.Info.Version)... $([int](100 * $len / $d.Info.Size))%"; Update-UpdateUi }
        return
    }
    $script:UpdateDlTimer.Stop()
    $script:UpdateDl = $null
    $fail = $null
    if ($d.Task.IsFaulted -or $d.Task.IsCanceled) { $fail = 'The download failed. Check your internet connection and try again.' }
    elseif ((Get-FileHash $d.File -Algorithm SHA256).Hash -ne $d.Info.Sha) { $fail = 'The downloaded file did not match the release checksum, so it was deleted and nothing was installed.' }
    if ($fail) {
        Remove-Item $d.File -Force -ErrorAction SilentlyContinue
        Update-UpdateUi
        Show-Toast $fail '#FF453A'
        return
    }
    Add-History "Updated ZeroDelay $AppVersion to $($d.Info.Version)" 'update' $null
    Save-Backup
    try { Start-Process -FilePath $d.File -ArgumentList '/update' } catch { Show-Toast "Could not start the setup: $($_.Exception.Message)" '#FF453A'; Update-UpdateUi; return }
    $script:ReallyExit = $true
    $window.Close()
}

# --- What's new: shown once after an update (not after a fresh install, which gets the setup wizard).
$WhatsNew = @{
    '1.9.1' = @(
        @{ T = 'New look for questions'; D = 'The grey Windows pop-ups are gone: every question and message is now a dark ZeroDelay dialog that matches the app. Enter picks the main button, Esc closes it, and actions that delete things use a red button.' }
        @{ T = 'FreeSync asks the NVIDIA driver'; D = 'The FreeSync page now checks every monitor with the NVIDIA driver and shows G-SYNC on, off for that monitor, or not seen by the driver, with what to check in the monitor menu. It also marks your main screen.' }
        @{ T = 'G-SYNC on the restart banner'; D = 'Switched G-SYNC on in the NVIDIA App but it is not active yet? Press I turned it on: ZeroDelay adds it to the restart banner and checks after the restart that the driver uses it.' }
        @{ T = 'Clearer restart banner'; D = 'Changes Windows already uses drop off the banner, it says when Windows last restarted, and after the restart ZeroDelay confirms the changes took effect.' }
    )
    '1.9.0' = @(
        @{ T = 'You choose what Optimize switches on'; D = 'Optimize now lists every recommended tweak that is still off, with what it does and when to skip it. Nothing is ticked: you pick, then confirm.' }
        @{ T = 'Debloat'; D = 'A new Tools > Debloat page finds preinstalled Windows apps, promo apps and PC-maker trials, explains each one, and removes only what you tick.' }
        @{ T = 'FreeSync'; D = 'A new Tools > FreeSync page shows each monitor''s FreeSync range and cable, whether it can work on your graphics card, and the settings in order: refresh rate, G-SYNC Compatible, Windows VRR and a frame cap inside the range.' }
        @{ T = 'Works with GearUP'; D = 'Your ping booster may now change settings: ZeroDelay keeps whatever GearUP (or ExitLag, WTFast, NoPing) changes, never switches it back, and lists each change with the old and new value under Tools > Ping booster.' }
        @{ T = 'Active tweaks'; D = 'A new page (Tweaks > Active tweaks, or click the counter at the bottom left) lists everything that is switched on, grouped like the menu, with when ZeroDelay turned it on and a switch to undo each one.' }
        @{ T = 'Tournaments tab'; D = 'Every cup for your region (taken from your Fortnite settings) with its art and times in your time zone, straight from Epic''s official schedule. Click one for scoring, rules and prizes. Plus a ready check and competitive tips.' }
        @{ T = 'Match reports tell you how to fix it'; D = 'Every report now ends with a How to fix it list: the exact settings to switch on, apps for Game Mode to close, or the page to open, each with one button. Older reports get it too.' }
        @{ T = 'Faster and smoother'; D = 'ZeroDelay starts about a third faster with a new loading screen, and the NVIDIA, Memory and Game Mode tabs no longer freeze when you open them: their checks now run in the background.' }
        @{ T = 'Glow everywhere'; D = 'Soft colour light drifts behind every page, main buttons glow, and cards light up under the mouse.' }
        @{ T = 'New Potato builder'; D = 'Build your own potato is now a big dashboard like Game Mode, with a live score and one Apply button.' }
        @{ T = 'Fixes'; D = 'Game Mode corners are round again, and History shows changes that an older version had hidden.' }
    )
    '1.8.0' = @(
        @{ T = 'New Game Mode screen'; D = 'Game Mode is now a full dashboard: a big Start Game button that turns Game Mode on and launches Fortnite, a session timer, live ping, apps closed, memory freed, and CPU, GPU and memory numbers.' }
        @{ T = 'Game Mode tools'; D = 'Every boost step and every app Game Mode closes in one panel, with app icons, a running label, and filters for Boost, Apps and Auto.' }
        @{ T = 'True black'; D = 'Dark mode is now real black instead of grey, glass included.' }
    )
    '1.7.0' = @(
        @{ T = 'A cleaner ZeroDelay'; D = 'A new Home page with one Optimize button, a shorter menu with folding Tweaks and Tools groups, and Restore point / Undo everything tucked into the menu next to Optimize.' }
        @{ T = 'Glass'; D = 'Frosted, see-through window and glass panels on Windows 11, with cards that lift under the mouse. Switch it off in Settings > Appearance.' }
        @{ T = 'Creator tab'; D = 'For Premiere Pro, After Effects, Photoshop, Media Encoder and OBS: auto-save hitches, Adobe RAM reserve, Multi-Frame Rendering, Adobe apps on the right graphics card, OBS priority and staying awake during renders.' }
        @{ T = 'App icons in Uninstall apps'; D = 'Programs and Store apps now show their own icons, so you find them at a glance.' }
        @{ T = 'Adobe caches in Clean up'; D = 'Adobe media cache and the After Effects disk cache can be emptied, only while the apps are closed.' }
    )
    '1.6.0' = @(
        @{ T = 'ZeroDelay now knows your PC'; D = 'On first start (and every few days) it scans the hardware, drivers, Windows and every installed app, then adapts which tweaks it recommends. See Tools > This PC.' }
        @{ T = 'Recommendations that fit'; D = 'Laptops keep battery-draining power tweaks out of Apply recommended, streamers keep their frames, and cards for hardware or apps you do not have stay hidden.' }
        @{ T = 'GTX 1080 Ti tab'; D = 'On PCs with a GTX 1080 Ti: the right renderer and settings for that card, the driver branch it needs, and advice for keeping an older card cool.' }
    )
    '1.5.0' = @(
        @{ T = 'Vendor software tab'; D = 'Services from ASUS, MSI, Corsair, Razer, Logitech, Dell, HP, Lenovo, Intel, AMD and Adobe that are known stutter sources. Only what is installed on your PC is shown, and each card says what stops working.' }
        @{ T = '12 new Health checks'; D = 'RAM below its rated speed or in single channel, the graphics card on fewer PCIe lanes, Fortnite on a hard drive, no page file, CPU held back by heat, a mouse on a USB hub, Windows Update restarts, Defender scan timing and more.' }
        @{ T = 'Browsers and Steam'; D = 'Stop Chrome and Brave running in the background, keep browsers off the GPU while you play, and let Steam update games only at night.' }
        @{ T = 'Audio enhancements off'; D = 'One switch for every playback device, the same as Settings > Sound.' }
        @{ T = 'Game Mode closes more'; D = 'RGB and monitoring apps (SignalRGB, OpenRGB, NZXT CAM, iCUE, G HUB, HWiNFO...), cloud sync and live wallpapers. Clip recorders and launchers are listed too, off by default.' }
        @{ T = 'Cards you cannot use are hidden'; D = 'Tweaks for hardware or software this PC does not have no longer show up greyed out.' }
    )
    '1.4.0' = @(
        @{ T = '18 new researched tweaks'; D = 'Found by checking Microsoft, NVIDIA and Epic documentation and measured guides. About 120 placebo or harmful tweaks were rejected on purpose.' }
        @{ T = 'Power and drives'; D = 'Full speed for Intel performance cores, and NVMe/SATA drives that never doze mid-match.' }
        @{ T = 'Graphics'; D = 'GPU interrupt mode (when your driver has not done it), the hypervisor switch, and two fixes for borderless and multi-monitor stutter.' }
        @{ T = 'Background'; D = 'Fewer diagnostic uploads and tasks, capped update downloads, optional Store, OneDrive and inventory switches, and Nahimic off.' }
        @{ T = 'Fortnite'; D = 'Switches off fake launch arguments in the Epic launcher, such as -useallavailablecores.' }
    )
    '1.3.0' = @(
        @{ T = 'Uninstall apps'; D = 'Tools > Uninstall apps lists your programs and Store apps. Force remove also deletes the files, registry keys, shortcuts, services and tasks an app leaves behind.' }
        @{ T = 'Clean up files'; D = 'Temp files, old Windows Update downloads, crash dumps and caches. You see the size of each group before anything is deleted.' }
        @{ T = 'Memory (RAM)'; D = 'See what uses your RAM, close the heavy apps, and clear standby memory if your PC needs it.' }
        @{ T = 'Smoother animations'; D = 'Animations now run at your monitor''s refresh rate and start only after a page is ready.' }
        @{ T = 'ZeroDelay asks for permission as ZeroDelay'; D = 'The Windows permission prompt now shows ZeroDelay''s name and icon instead of PowerShell.' }
    )
    '1.2.0' = @(
        @{ T = 'One-click updates'; D = 'When a new version is out, press Update now. ZeroDelay downloads it from GitHub, checks it and reinstalls itself in about 10 seconds.' }
        @{ T = 'Match reports'; D = 'After each Fortnite session ZeroDelay shows its stutters with what was busy at that moment, GPU heat, background apps and memory. Tools > Match reports.' }
        @{ T = 'Mouse test'; D = 'Tools > Mouse test measures your real polling rate and whether it is steady.' }
        @{ T = 'Start with Windows'; D = 'Settings: ZeroDelay can open quietly in the tray when you sign in, so Game Mode is always ready. It stays off unless you switch it on.' }
        @{ T = 'Report a problem'; D = 'Settings > Report a problem opens a GitHub issue with your PC details already filled in.' }
    )
}
function Show-WhatsNew {
    $items = $WhatsNew[$AppVersion]
    if (-not $items) { return }
    $rows = ($items | ForEach-Object {
        "<StackPanel Margin='0,0,0,14'><TextBlock Text='$(Esc $_.T)' FontSize='14' FontWeight='SemiBold'/>" +
        "<TextBlock Text='$(Esc $_.D)' FontSize='12.5' Foreground='#A1A1A6' TextWrapping='Wrap' Margin='0,3,0,0' LineHeight='18' LineStackingStrategy='BlockLineHeight'/></StackPanel>"
    }) -join ''
    $body = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <TextBlock Text='$(Esc "What's new in ZeroDelay $AppVersion")' FontSize='22' FontWeight='Bold'/>
  <TextBlock Text='ZeroDelay was updated. Your settings, backups and history are all still here.' Foreground='#A1A1A6' FontSize='13' Margin='0,6,0,22' TextWrapping='Wrap'/>
  $rows
  <Button x:Name='Ok' Content='Got it' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' HorizontalAlignment='Right' Margin='0,8,0,0' MinWidth='90'/>
</StackPanel>
"@)
    $body.FindName('Ok').Add_Click({ Hide-Animated $ui.Wizard 200 })
    $ui.WizardBody.Content = $body
    $ui.Wizard.Visibility = 'Visible'
    if ($script:Anim) {
        Start-Anim $ui.Wizard ([Windows.UIElement]::OpacityProperty) 0 1 220
        Show-Animated $ui.WizardBody 24 380 60
    }
}

# --- Report a problem: a new GitHub issue with the PC details filled in (the user reviews it before sending).
function Open-ProblemReport {
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $hw = Get-HardwareSummary
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $drv = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $hw.Gpu } | Select-Object -First 1).DriverVersion
        $info = @(
            "ZeroDelay $AppVersion", "$($os.Caption) (build $($os.BuildNumber))", "CPU: $($hw.Cpu)", "GPU: $($hw.Gpu) (driver $drv)",
            "RAM: $($hw.RamGb) GB at $($hw.RamMts) MT/s", "Monitor: $($hw.Hz) Hz", "Fortnite found: $(if ($script:FortniteExe) { 'yes' } else { 'no' })",
            "Game Mode: $(if (Test-ZDGameMode) { 'on' } else { 'off' })", "Tweaks on: $(@(Get-Applied).Count)", "Theme: $script:Theme / $script:Accent"
        )
    } finally { $window.Cursor = $null }
    $body = "### What happened?`n`n`n### What did you expect to happen?`n`n`n### How can it be made to happen again?`n1. `n`n---`n" +
            "<details><summary>PC details (added by ZeroDelay)</summary>`n`n" + (($info | ForEach-Object { "- $_" }) -join "`n") + "`n</details>"
    Start-Process "https://github.com/$UpdateRepo/issues/new?body=$([uri]::EscapeDataString($body))"
    Show-Toast 'GitHub is open. Describe what went wrong, then press Create. You need a free GitHub account.' '#0A84FF'
}

# --- Start with Windows: a logon task (admin rights, so no permission prompt at every sign-in), started in the tray.
$StartupTaskName = 'ZeroDelay'
function Get-StartupTask { Get-ScheduledTask -TaskName $StartupTaskName -TaskPath '\' -ErrorAction SilentlyContinue }
function Set-StartWithWindows([bool]$On) {
    if (-not $On) { Unregister-ScheduledTask -TaskName $StartupTaskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue; return }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -Tray"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT15S'   # let Windows finish signing in first
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $StartupTaskName -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Starts ZeroDelay in the tray when you sign in. Turn it off in ZeroDelay > Settings.' -Force -ErrorAction Stop | Out-Null
}
# After an update or a move the task may point at an old copy; point it at this one.
function Repair-StartupTask {
    if ($Snapshot -or $NoElevate) { return }
    try { $t = Get-StartupTask; if ($t -and "$($t.Actions[0].Arguments)" -notlike "*$PSCommandPath*") { Set-StartWithWindows $true } } catch {}
}

# --- Mouse test (Tools > Mouse test)
function Measure-MouseBins([int[]]$Bins, [int]$BinMs) {
    $b = @($Bins)
    if ($b.Count -lt 10) { return $null }
    $sorted = @($b | Sort-Object)
    $p95 = $sorted[[int][Math]::Floor(0.95 * ($sorted.Count - 1))]
    # only slices where the mouse was clearly moving (a mouse only reports when it moves)
    $moving = @($b | Where-Object { $_ -gt 0 -and $_ -ge 0.5 * $p95 })
    if ($moving.Count -lt 8) { return $null }
    $ms = @($moving | Sort-Object)
    $med = $ms[[int][Math]::Floor($ms.Count / 2)]
    $hz = $med * 1000.0 / $BinMs
    $snap = 125, 250, 500, 1000, 2000, 4000, 8000 | Where-Object { [Math]::Abs($_ - $hz) / $_ -le 0.12 } | Select-Object -First 1
    $steady = @($moving | Where-Object { [Math]::Abs($_ - $med) / [Math]::Max(1, $med) -le 0.15 }).Count / $moving.Count
    [pscustomobject]@{ Hz = [int][Math]::Round($hz); Snap = $snap; Steady = [int][Math]::Round(100 * $steady); Seconds = [Math]::Round($moving.Count * $BinMs / 1000.0, 1) }
}
function Get-MouseVerdict($r) {
    if (-not $r) { return @('No steady movement was measured. Click Start and move the mouse in fast circles for the whole 5 seconds.', '#FF9F0A') }
    $rate = if ($r.Snap) { $r.Snap } else { $r.Hz }
    if ($r.Steady -lt 75) { return @("Your rate jumps around (only $($r.Steady)% of the test was steady). Plug the mouse or its receiver straight into a USB port on the back of the PC (not a hub or the front panel), and close mouse-software overlays.", '#FF9F0A') }
    if (-not $r.Snap) { return @("About $($r.Hz) Hz, which is not a standard rate. Usually the CPU or USB port cannot keep up: try 1000 Hz in your mouse software, or another USB port.", '#FF9F0A') }
    if ($rate -le 250) { return @("$rate Hz is slow for gaming: up to $([Math]::Round(1000 / $rate)) ms between mouse updates. Almost every gaming mouse can do 1000 Hz; set it in your mouse software (Logitech G HUB, Razer Synapse, SteelSeries GG, ...) or with the button under the mouse.", '#FF453A') }
    if ($rate -eq 500) { return @('500 Hz works, but 1000 Hz halves the gap between mouse updates (2 ms to 1 ms). Set 1000 Hz in your mouse software if it offers it.', '#FF9F0A') }
    if ($rate -eq 1000) { return @('1000 Hz and steady: the competitive standard. Nothing to change.', '#30D158') }
    @("$rate Hz and steady: very smooth. If Fortnite ever stutters while you flick, try 1000 Hz, because high rates need more CPU time.", '#30D158')
}
function New-MousePage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text='Polling rate' Foreground='#A1A1A6' FontSize='12'/>
          <StackPanel Orientation='Horizontal'>
            <TextBlock x:Name='Hz' Text='-' FontSize='44' FontWeight='Bold'/>
            <TextBlock Text='Hz' FontSize='18' Foreground='#A1A1A6' VerticalAlignment='Bottom' Margin='8,0,0,10'/>
          </StackPanel>
          <TextBlock x:Name='Sub' Text='Click Start, then move your mouse in fast circles for 5 seconds.' FontSize='12.5' Foreground='#A1A1A6' TextWrapping='Wrap'/>
        </StackPanel>
        <Button x:Name='Start' Grid.Column='1' Content='Start test' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' VerticalAlignment='Top'/>
      </Grid>
      <Border Background='#1C1C1E' CornerRadius='10' Height='150' Margin='0,18,0,0'>
        <Grid>
          <TextBlock x:Name='PadText' Text='Move your mouse anywhere while the test runs' Foreground='#98989D' FontSize='13' HorizontalAlignment='Center' VerticalAlignment='Center'/>
          <Border Height='4' CornerRadius='2' Background='#3A3A3C' VerticalAlignment='Bottom' Margin='16,0,16,14'>
            <Border x:Name='Prog' Height='4' CornerRadius='2' Background='#0A84FF' HorizontalAlignment='Left' Width='0'/>
          </Border>
        </Grid>
      </Border>
      <TextBlock x:Name='Verdict' FontSize='13' FontWeight='SemiBold' Margin='0,14,0,0' TextWrapping='Wrap' LineHeight='19' LineStackingStrategy='BlockLineHeight'/>
      <TextBlock x:Name='Detail' FontSize='12' Foreground='#98989D' Margin='0,4,0,0' TextWrapping='Wrap'/>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20'>
    <StackPanel>
      <TextBlock Text='Good to know' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,8'/>
      <TextBlock Foreground='#A1A1A6' FontSize='12.5' TextWrapping='Wrap' LineHeight='20' LineStackingStrategy='BlockLineHeight'
        Text='&#x2022;  1000 Hz is the competitive standard: a new mouse position every 1 ms. 500 Hz waits up to 2 ms, 125 Hz up to 8 ms.&#x0a;&#x2022;  2000 to 8000 Hz feels even smoother but costs CPU time; if Fortnite stutters when you flick, go back to 1000 Hz.&#x0a;&#x2022;  Change the rate in your mouse software (Logitech G HUB, Razer Synapse, SteelSeries GG, ...) or with the button under the mouse.&#x0a;&#x2022;  Plug the mouse or its wireless receiver straight into the PC, not into a hub, keyboard or front-panel port.'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $m = @{}; foreach ($n in 'Hz', 'Sub', 'Start', 'PadText', 'Prog', 'Verdict', 'Detail') { $m[$n] = $root.FindName($n) }
    $script:MouseUi = $m
    $m.Start.Add_Click({ Start-MouseTest })
    $last = Get-Setting 'mousetest' $null
    if ($last) {
        $m.Hz.Text = "$(if ($last.Snap) { $last.Snap } else { $last.Hz })"
        $m.Sub.Text = "Last test $(([datetime]$last.Time).ToString('d MMM HH:mm')), $($last.Steady)% steady. Run it again any time."
    }
    New-PageScroll $root
}
function Start-MouseTest {
    $m = $script:MouseUi
    $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    if (-not [MouseRate]::Start($h)) { Show-Toast 'Windows did not let ZeroDelay read the mouse.' '#FF9F0A'; return }
    $script:MouseWait = Get-Date; $script:MouseT0 = $null
    $m.Start.IsEnabled = $false; $m.Hz.Text = '0'; $m.Verdict.Text = ''; $m.Detail.Text = ''; $m.Prog.Width = 0
    $m.Sub.Text = 'Now move your mouse in fast circles and keep going...'
    $m.PadText.Text = 'Keep moving...'
    if (-not $script:MouseTimer) {
        $script:MouseTimer = New-Object Windows.Threading.DispatcherTimer
        $script:MouseTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:MouseTimer.Add_Tick({
            $m = $script:MouseUi
            if (-not $script:MouseT0) {
                if ([MouseRate]::Count -gt 20) { $script:MouseT0 = Get-Date }
                elseif (((Get-Date) - $script:MouseWait).TotalSeconds -gt 15) { Stop-MouseTest; return }
                return
            }
            $m.Hz.Text = "$([int][MouseRate]::RecentRate(250))"
            $el = ((Get-Date) - $script:MouseT0).TotalSeconds
            $w = $m.Prog.Parent.ActualWidth
            $m.Prog.Width = [Math]::Max(0, [Math]::Min($w, $w * $el / 5))
            if ($el -ge 5) { Stop-MouseTest }
        })
    }
    $script:MouseTimer.Start()
}
function Stop-MouseTest {
    $script:MouseTimer.Stop()
    $bins = [MouseRate]::Bins(50)
    [MouseRate]::Stop()
    $m = $script:MouseUi
    $m.Start.IsEnabled = $true; $m.Start.Content = 'Test again'; $m.PadText.Text = 'Move your mouse anywhere while the test runs'
    $r = Measure-MouseBins $bins 50
    $v = Get-MouseVerdict $r
    $m.Verdict.Text = $v[0]; $m.Verdict.Foreground = ConvertTo-Brush $v[1]
    if ($r) {
        $m.Hz.Text = "$(if ($r.Snap) { $r.Snap } else { $r.Hz })"
        $m.Sub.Text = 'Done.'
        $m.Detail.Text = "Measured $($r.Hz) Hz over $($r.Seconds) s of movement, $($r.Steady)% of it steady."
        $script:Backup.Custom['mousetest'] = @{ Hz = $r.Hz; Snap = $r.Snap; Steady = $r.Steady; Time = (Get-Date).ToString('o') }; Save-Backup
    } else { $m.Hz.Text = '-'; $m.Sub.Text = 'Click Start, then move your mouse in fast circles for 5 seconds.' }
}

# --- Match reports: while Fortnite runs, a background sampler notes CPU hogs, GPU heat/slowdowns and free memory
#     every 5 s, and PresentMon (if downloaded on the Benchmark page) records frame times. When Fortnite closes,
#     the two are lined up so each stutter shows what was busy at that moment.
$MatchDir = Join-Path $DataDir 'matches'
$MatchSampler = {
    param($sync, $smi, $smiField, $cores, $exclude, $selfPid, $gmFile)
    $prev = @{}; $prevT = Get-Date
    while (-not $sync.Stop) {
        $now = Get-Date
        $dt = ($now - $prevT).TotalSeconds; $prevT = $now
        $cur = @{}; $top = @()
        foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
            $c = $null; try { $c = $p.TotalProcessorTime.TotalSeconds } catch {}
            if ($null -eq $c) { continue }
            $cur[$p.Id] = $c
            if ($prev.ContainsKey($p.Id) -and $dt -gt 1 -and $p.Id -ne $selfPid -and $exclude -notcontains $p.ProcessName) {
                $pct = ($c - $prev[$p.Id]) / $dt / $cores * 100
                if ($pct -ge 3) { $path = $null; try { $path = $p.Path } catch {}; $top += [pscustomobject]@{ Name = $p.ProcessName; Pct = [Math]::Round($pct, 1); Path = $path } }
            }
        }
        $prev = $cur
        $gpu = $null
        if ($smi) {
            try {
                $o = & $smi "--query-gpu=temperature.gpu,utilization.gpu,$smiField" --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                $f = "$o" -split ',\s*'
                if ($f.Count -ge 3) {
                    $bits = [Convert]::ToInt64(($f[2].Trim() -replace '^0x', ''), 16)
                    # 0x20/0x40 = thermal slowdown, 0x08/0x80 = hardware slowdown / power brake. The everyday
                    # power-limit flag (0x04) is normal under load and deliberately ignored.
                    $gpu = [pscustomobject]@{ Temp = [int]$f[0]; Util = [int]$f[1]; Thermal = [bool]($bits -band 0x60); HwSlow = [bool]($bits -band 0x88) }
                }
            } catch {}
        }
        $free = $null; try { $free = [int]((Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory / 1024) } catch {}
        [void]$sync.Samples.Add([pscustomobject]@{ T = $now; Top = @($top | Sort-Object Pct -Descending | Select-Object -First 3); Gpu = $gpu; FreeMb = $free; GM = [bool]($gmFile -and (Test-Path $gmFile)) })
        for ($i = 0; $i -lt 20 -and -not $sync.Stop; $i++) { Start-Sleep -Milliseconds 250 }
    }
}
function Start-MatchRecorder {
    $rec = @{ Start = Get-Date; Csv = $null; Pm = $null }
    if ((Test-Path $PresentMonExe) -and -not ($script:BenchProc -and -not $script:BenchProc.HasExited)) {
        $rec.Csv = Join-Path $ToolsDir "match-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $pmArgs = @('--process_name', $FortniteExeName, '--output_file', "`"$($rec.Csv)`"", '--terminate_on_proc_exit',
                    '--no_console_stats', '--stop_existing_session', '--session_name', 'ZeroDelayMatch')
        try { $rec.Pm = Start-Process $PresentMonExe -ArgumentList $pmArgs -WindowStyle Hidden -PassThru } catch { $rec.Csv = $null }
    }
    $smi = "$env:WINDIR\System32\nvidia-smi.exe"
    if (Test-Path $smi) {
        if (-not $script:SmiField) {
            $o = & $smi --query-gpu=clocks_event_reasons.active --format=csv,noheader 2>$null | Out-String
            $script:SmiField = if ($o -match '0x[0-9A-Fa-f]+') { 'clocks_event_reasons.active' } else { 'clocks_throttle_reasons.active' }
        }
    } else { $smi = $null }
    $sync = [hashtable]::Synchronized(@{ Stop = $false; Samples = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)) })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($MatchSampler.ToString()).AddArgument($sync).AddArgument($smi).AddArgument($script:SmiField).AddArgument([Environment]::ProcessorCount).AddArgument(@('Idle', ($FortniteExeName -replace '\.exe$'))).AddArgument($PID).AddArgument($GameModeFile)
    $rec.PS = $ps; $rec.Sync = $sync; $rec.Handle = $ps.BeginInvoke()
    $script:MatchRec = $rec
    if ($script:MatchUi) { Update-MatchesPage }
}
function Stop-MatchRecorder {
    $rec = $script:MatchRec
    $script:MatchRec = $null
    $rec.Sync.Stop = $true
    $rec.End = Get-Date
    $script:MatchAnalysis = @{ Rec = $rec; Phase = 'pm'; Deadline = (Get-Date).AddSeconds(15); Task = $null }
}
# Runs on the match timer until the report is built, so nothing here blocks the window.
function Complete-MatchReport {
    $a = $script:MatchAnalysis
    if ($a.Phase -eq 'pm') {
        if ($a.Rec.Pm -and -not $a.Rec.Pm.HasExited) {
            if ((Get-Date) -lt $a.Deadline) { return }
            try { $a.Rec.Pm.Kill() } catch {}
        }
        $a.Task = if ($a.Rec.Csv -and (Test-Path $a.Rec.Csv)) { [FrameStats]::AnalyzeAsync($a.Rec.Csv) } else { $null }
        $a.Phase = 'analyze'
    }
    if ($a.Task -and -not $a.Task.IsCompleted) { return }
    $script:MatchAnalysis = $null
    $frames = if ($a.Task -and -not $a.Task.IsFaulted) { $a.Task.Result } else { $null }
    try { if ($a.Rec.Handle.IsCompleted) { [void]$a.Rec.PS.EndInvoke($a.Rec.Handle) }; $a.Rec.PS.Dispose() } catch {}
    if ($a.Rec.Csv) { Remove-Item $a.Rec.Csv -Force -ErrorAction SilentlyContinue }
    if ($script:MatchUi) { Update-MatchesPage }
    if (($a.Rec.End - $a.Rec.Start).TotalMinutes -lt 2) { return }   # too short to say anything useful
    $r = New-MatchReport $a.Rec.Start $a.Rec.End $frames @($a.Rec.Sync.Samples)
    Save-MatchReport $r
    if ($script:MatchUi) { Update-MatchesPage }
    $n = @($r.Issues).Count
    $sum = if ($n) { "$n thing$(if ($n -ne 1) { 's' }) got in the way." } else { 'Smooth session: nothing got in the way.' }
    Show-Toast "Match report ready. $sum" $(if ($n) { '#FF9F0A' } else { '#30D158' })
    if (-not $window.IsVisible -and $script:TrayIcon) {
        $script:BalloonPage = 'Matches'
        $script:TrayIcon.ShowBalloonTip(6000, 'ZeroDelay match report', "$sum Click to see it.", 'None')
    }
}
function New-MatchReport($Start, $End, $Frames, $Samples) {
    $samples = @($Samples | Where-Object { $_ })
    $n = [Math]::Max(1, $samples.Count)
    $issues = @()
    # background apps
    $hog = @{}
    foreach ($s in $samples) { foreach ($p in @($s.Top)) {
        if (-not $hog.ContainsKey($p.Name)) { $hog[$p.Name] = @{ Sum = 0.0; Max = 0.0; Path = $null } }
        if ($p.Path) { $hog[$p.Name].Path = $p.Path }
        $hog[$p.Name].Sum += $p.Pct; if ($p.Pct -gt $hog[$p.Name].Max) { $hog[$p.Name].Max = $p.Pct }
    } }
    $hogs = @($hog.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Avg = [Math]::Round($hog[$_].Sum / $n, 1); Max = $hog[$_].Max; Path = $hog[$_].Path } } |
              Where-Object { $_.Avg -ge 3 -or $_.Max -ge 25 } | Sort-Object Avg -Descending | Select-Object -First 4)
    foreach ($h in $hogs | Where-Object { $_.Avg -ge 6 }) { $issues += "$($h.Name) used $($h.Avg)% of your CPU on average (up to $($h.Max)%). Close it before playing, or add it to the apps Game Mode closes." }
    # graphics card
    $g = @($samples | Where-Object { $_.Gpu })
    $maxT = if ($g) { ($g | ForEach-Object { $_.Gpu.Temp } | Measure-Object -Maximum).Maximum } else { $null }
    $hot = if ($g) { [int][Math]::Round(100 * @($g | Where-Object { $_.Gpu.Thermal }).Count / $g.Count) } else { 0 }
    $slow = if ($g) { [int][Math]::Round(100 * @($g | Where-Object { $_.Gpu.HwSlow }).Count / $g.Count) } else { 0 }
    if ($hot -ge 5) { $issues += "Your graphics card slowed itself down because it got too hot (up to $maxT °C) for $hot% of the session. Clean out the dust or set a stronger fan curve." }
    if ($slow -ge 5) { $issues += "Your graphics card hit a hardware slowdown (power or heat protection) for $slow% of the session. Check its power cables and that the power supply is strong enough." }
    # memory
    $minFree = ($samples | Where-Object { $null -ne $_.FreeMb } | ForEach-Object { $_.FreeMb } | Measure-Object -Minimum).Minimum
    if ($minFree -and $minFree -lt 1024) { $issues += "Your PC ran low on memory (only $minFree MB free at one point). Windows then swaps to the disk, which causes stutters. Close browsers and other big apps before playing." }
    # frames
    $stutters = @(); $fps = $null
    if ($Frames -and $Frames.Frames -gt 0) {
        $fps = [pscustomobject]@{ Avg = [Math]::Round($Frames.AvgFps); Low1 = [Math]::Round($Frames.Low1Fps); Frames = $Frames.Frames }
        for ($i = 0; $i -lt $Frames.StutterAtMs.Length; $i++) {
            # PresentMon stops with Fortnite, so frame times are counted back from the end of the session
            $at = $End.AddMilliseconds(-($Frames.TotalMs - $Frames.StutterAtMs[$i]))
            $near = $samples | Sort-Object { [Math]::Abs(($_.T - $at).TotalSeconds) } | Select-Object -First 1
            $busy = @()
            if ($near -and [Math]::Abs(($near.T - $at).TotalSeconds) -le 6) {
                $busy = @($near.Top | ForEach-Object { "$($_.Name) $($_.Pct)%" })
                if ($near.Gpu -and $near.Gpu.Thermal) { $busy += 'GPU too hot' }
                if ($null -ne $near.FreeMb -and $near.FreeMb -lt 1024) { $busy += 'low memory' }
            }
            $stutters += [pscustomobject]@{ At = $at.ToString('o'); Ms = [int][Math]::Round($Frames.StutterMs[$i]); Busy = ($busy -join ', ') }
        }
        $sc = $Frames.StutterCount
        if ($sc) { $issues = @("$sc stutter$(if ($sc -ne 1) { 's' }): a frame that took much longer than the ones around it. The times are below, with what was busy at that moment.") + $issues }
        if ($Frames.Low1Fps -lt 0.5 * $Frames.AvgFps) { $issues += "Your 1% lows ($($fps.Low1) FPS) are less than half your average ($($fps.Avg) FPS), so the game felt less smooth than the FPS counter says." }
    }
    [pscustomobject]@{
        Version = 1; Start = $Start.ToString('o'); End = $End.ToString('o'); Minutes = [int][Math]::Round(($End - $Start).TotalMinutes)
        Fps = $fps; StutterCount = $(if ($Frames) { $Frames.StutterCount } else { $null }); Stutters = $stutters
        GpuMaxTemp = $maxT; GpuHotPct = $hot; GpuSlowPct = $slow; Hogs = $hogs; MinFreeMb = $minFree; Issues = @($issues)
        GameModePct = $(if (@($samples | Where-Object { $null -ne $_.GM }).Count) { [int][Math]::Round(100 * @($samples | Where-Object { $_.GM }).Count / $n) } else { $null })
    }
}
# --- What to do about a report: each problem becomes one fix with a button (switch on cards, let Game Mode close an
#     app, open a page). Worked out when the page is drawn, so old reports get fixes too and done ones show as done.
function Find-Tweak([string]$Id) { $Tweaks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
function Get-OffTweaks([string[]]$Ids) { $owned = Get-BoosterOwned; @($Ids | ForEach-Object { Find-Tweak $_ } | Where-Object { $_ -and $_.Toggle -and -not $_.Hidden -and $_.State -eq $false -and $owned -notcontains $_.Id }) }
$MatchSystemProcs = 'System', 'Registry', 'svchost', 'dwm', 'csrss', 'audiodg', 'lsass', 'services', 'wininit', 'explorer', 'Memory Compression', 'Secure System', 'WmiPrvSE', 'powershell', 'ZeroDelay'
function Get-MatchFixes($r) {
    $fixes = New-Object Collections.ArrayList
    $gp = Get-GameModePrefs; $sp = Get-SessionPrefs
    $gmOff = ($null -ne $r.GameModePct -and $r.GameModePct -lt 50)
    function Add-Fix($f) { [void]$fixes.Add($f) }
    # 1. apps that were busy during the match or during stutters
    $names = @{}
    foreach ($h in @($r.Hogs)) { if ($h.Avg -ge 3 -or $h.Max -ge 25) { $names[$h.Name] = $h } }
    foreach ($st in @($r.Stutters)) { foreach ($b in "$($st.Busy)" -split ',\s*') { if ($b -match '^(.+?) [\d.]+%$' -and -not $names.ContainsKey($Matches[1])) { $names[$Matches[1]] = [pscustomobject]@{ Name = $Matches[1]; Avg = 0; Max = 0; Path = $null } } } }
    $closeKeys = @(); $closeNames = @(); $others = @()
    foreach ($n in @($names.Keys)) {
        if ($MatchSystemProcs -contains $n) { continue }
        if ($n -eq 'MsMpEng') { continue }    # Defender: handled below
        $h = $names[$n]
        $path = if ($h.Path) { "$($h.Path)" } else { "C:\x\$n\$n.exe" }
        $app = $SessionApps | Where-Object { $path -match $_.PathRx } | Select-Object -First 1
        if ($app) { if (-not $sp[$app.Key] -or -not $gp.apps -or $gmOff) { $closeKeys += $app.Key; $closeNames += $app.Name } } else { $others += $n }
    }
    if ($closeKeys) {
        $done = -not $gmOff -and $gp.apps -and -not @($closeKeys | Where-Object { -not $sp[$_] }).Count
        Add-Fix @{ Icon = 0xE71D; Tint = '#5E5CE6'; Title = "Let Game Mode close $($closeNames -join ', ')"
                   Desc = 'They used your CPU while you played. Game Mode closes them when the match starts and opens them again afterwards.'
                   Kind = 'session'; AppKeys = $closeKeys; Button = 'Close them in Game Mode'; Done = $done }
    }
    if ($others) {
        Add-Fix @{ Icon = 0xE9D9; Tint = '#0A84FF'; Title = "$($others -join ', ') took CPU time from Fortnite"
                   Desc = 'Close them before you play. Game Mode can also push apps like these to low priority so Fortnite always comes first.'
                   Kind = 'gmstep'; Step = 'priority'; Button = 'Lower their priority'; Done = [bool]$gp.priority -and -not $gmOff }
    }
    if ($names.ContainsKey('MsMpEng')) {
        $t = Get-OffTweaks @('defendercpu', 'shaderexcl')
        Add-Fix @{ Icon = 0xE83D; Tint = '#30B0C7'; Title = 'Windows Defender scanned during the match'
                   Desc = 'Limit how much CPU a scan may use and stop it from rescanning Fortnite''s shader cache. Protection stays on.'
                   Kind = 'tweaks'; Ids = @($t | ForEach-Object { $_.Id }); Button = 'Switch on'; Done = -not $t.Count }
    }
    # 2. stutters while nothing else was busy: shader compiling, power saving or timers
    $st = @($r.Stutters)
    if ($st.Count) {
        $quiet = @($st | Where-Object { -not $_.Busy }).Count
        if ($quiet -ge [Math]::Max(1, $st.Count / 2)) {
            $t = Get-OffTweaks @('shaderexcl', 'nvshadercache', 'mpo-off', 'timer', 'coreparking', 'minstate', 'zdplan', 'usbsuspend', 'dvr')
            Add-Fix @{ Icon = 0xE945; Tint = '#FF9F0A'; Title = "$quiet stutter$(if ($quiet -ne 1) { 's' }) with nothing else busy"
                       Desc = $(if ($t.Count) { "Usually shader compiling, power saving or Windows timers. These $($t.Count) settings target exactly that: $(@($t | ForEach-Object { $_.Title }) -join ', ')." } else { 'Everything that targets this is already on. Short stutters in the first minutes are shaders compiling and fade after a few matches.' })
                       Kind = 'tweaks'; Ids = @($t | ForEach-Object { $_.Id }); Button = "Switch on $($t.Count)"; Done = -not $t.Count }
        }
    }
    # 3. uneven frame rate
    if ($r.Fps -and $r.Fps.Low1 -lt 0.5 * $r.Fps.Avg) {
        $t = Get-OffTweaks @('fpscap', 'perfmode', 'minstate', 'coreparking', 'gamemode', 'timer')
        Add-Fix @{ Icon = 0xE9D9; Tint = '#FFD60A'; Title = 'Your FPS jumps around a lot'
                   Desc = $(if ($t.Count) { "1% lows of $($r.Fps.Low1) against $($r.Fps.Avg) average. A frame cap you can always hold and steady CPU clocks even it out: $(@($t | ForEach-Object { $_.Title }) -join ', ')." } else { "1% lows of $($r.Fps.Low1) against $($r.Fps.Avg) average. Try a frame cap a little under your 1% lows on the Fortnite tab." })
                   Kind = 'tweaks'; Ids = @($t | ForEach-Object { $_.Id }); Button = "Switch on $($t.Count)"; Done = -not $t.Count }
    }
    # 4. heat and power
    if ($r.GpuHotPct -ge 5) {
        Add-Fix @{ Icon = 0xE9CA; Tint = '#FF453A'; Title = "Graphics card too hot ($($r.GpuMaxTemp) °C)"
                   Desc = 'It slowed itself down to cool off. Clean the dust out, set a stronger fan curve, or cap your FPS: fewer frames means less heat. Lighter graphics on the Potato page help too.'
                   Kind = 'page'; Page = 'Potato'; Button = 'Open Potato graphics'; Done = $false }
    }
    if ($r.GpuSlowPct -ge 5) {
        Add-Fix @{ Icon = 0xE945; Tint = '#FF453A'; Title = 'Graphics card hit a power or heat limit'
                   Desc = 'Check that both power cables sit firmly in the card and that the power supply is strong enough for it. Nothing to switch on in Windows for this.'
                   Kind = 'none'; Done = $false }
    }
    # 5. memory
    if ($r.MinFreeMb -and $r.MinFreeMb -lt 1024) {
        Add-Fix @{ Icon = 0xE964; Tint = '#BF5AF2'; Title = "Memory ran low ($($r.MinFreeMb) MB free)"
                   Desc = 'Windows had to swap to the disk, which stutters. See what uses your memory and close it before playing.'
                   Kind = 'page'; Page = 'Memory'; Button = 'Open Memory'; Done = $false }
    }
    # 6. Game Mode off while things went wrong
    if ($gmOff -and @($r.Issues).Count -and -not $gp.auto) {
        Add-Fix @{ Icon = 0xE768; Tint = '#2EE6A6'; Title = 'Game Mode was off for this match'
                   Desc = 'Let it switch on by itself whenever Fortnite starts, so background apps are dealt with every time.'
                   Kind = 'gmstep'; Step = 'auto'; Button = 'Start it automatically'; Done = $false }
    }
    # 7. no frame data
    if (-not $r.Fps) {
        Add-Fix @{ Icon = 0xE9D2; Tint = '#8E8E93'; Title = 'Stutters could not be measured'
                   Desc = 'Download PresentMon once on the Benchmark page. Then every report shows each stutter and what caused it.'
                   Kind = 'page'; Page = 'Benchmark'; Button = 'Open Benchmark'; Done = (Test-Path $PresentMonExe) }
    }
    @($fixes)
}
function Invoke-MatchFix($fx) {
    switch ($fx.Kind) {
        'tweaks' {
            $window.Cursor = [Windows.Input.Cursors]::Wait
            $ok = 0; $failed = @()
            foreach ($id in $fx.Ids) { $t = Find-Tweak $id; if (-not $t -or $t.State -ne $false) { continue }; try { Invoke-TweakOn $t; $ok++ } catch { $failed += $t.Title }; Clear-ReadCache; Update-Card $t }
            Update-Summary
            $window.Cursor = $null
            $msg = "Switched on $ok setting$(if ($ok -ne 1) { 's' })."
            if ($failed) { $msg += " Could not change: $($failed -join ', ')." }
            if ($fx.Ids | Where-Object { (Find-Tweak $_).Badge -eq 'restart' }) { $msg += ' Restart your PC to finish.' }
            Show-Toast $msg $(if ($failed) { '#FF9F0A' } else { '#30D158' })
        }
        'session' {
            $p = Get-SessionPrefs; foreach ($k in $fx.AppKeys) { $p[$k] = $true }; $script:Backup.Custom['sessionprefs'] = $p
            $g = Get-GameModePrefs; $g.apps = $true; $script:Backup.Custom['gamemodeprefs'] = $g; Save-Backup
            Show-Toast 'Game Mode will close them when you play and reopen them afterwards.' '#30D158'
        }
        'gmstep' {
            $g = Get-GameModePrefs; $g[$fx.Step] = $true; $script:Backup.Custom['gamemodeprefs'] = $g; Save-Backup
            Show-Toast $(if ($fx.Step -eq 'auto') { 'Game Mode now switches on by itself when Fortnite starts.' } else { 'Done: Game Mode takes care of it from your next match.' }) '#30D158'
        }
        'page' { Select-NavPage $fx.Page; return }
    }
    Update-GameModeUi
    Update-MatchesPage
}
function Save-MatchReport($r) {
    New-Item -ItemType Directory -Force $MatchDir | Out-Null
    $r | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $MatchDir "$(([datetime]$r.Start).ToString('yyyyMMdd-HHmmss')).json") -Encoding UTF8
    Get-ChildItem $MatchDir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Get-MatchReports {
    if ($Snapshot -and $env:ZD_FAKE_MATCH) { return @(New-FakeMatchReport) }
    if (-not (Test-Path $MatchDir)) { return @() }
    @(Get-ChildItem $MatchDir -Filter '*.json' | Sort-Object Name -Descending | ForEach-Object {
        $f = $_.FullName
        try { Get-Content $f -Raw | ConvertFrom-Json | Add-Member -NotePropertyName File -NotePropertyValue $f -PassThru } catch {}
    })
}
# dev: a report built from a synthetic session, to see the page without playing
function New-FakeMatchReport {
    $csv = Join-Path $env:TEMP 'zd-fake-match.csv'
    $rnd = New-Object Random 7
    $lines = New-Object Collections.Generic.List[string]; $lines.Add('Application,ProcessID,FrameTime')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    for ($i = 0; $i -lt 60000; $i++) { $ft = 4.2 + $rnd.NextDouble() * 0.6; if ($i -in 12000, 30500, 30520, 47000) { $ft = 38.0 + $i % 20 }; $lines.Add("Fortnite,1,$($ft.ToString($inv))") }
    [IO.File]::WriteAllLines($csv, $lines)
    $frames = [FrameStats]::Analyze($csv)
    Remove-Item $csv -ErrorAction SilentlyContinue
    $end = Get-Date; $start = $end.AddMinutes(-21)
    $samples = for ($t = 0; $t -lt 252; $t++) {
        [pscustomobject]@{ T = $start.AddSeconds($t * 5); Top = @([pscustomobject]@{ Name = 'Discord'; Pct = 9.5 }, [pscustomobject]@{ Name = 'chrome'; Pct = 4.1 })
                           Gpu = [pscustomobject]@{ Temp = 70 + ($t % 15); Util = 97; Thermal = ($t % 10 -eq 0); HwSlow = $false }; FreeMb = 5200 }
    }
    New-MatchReport $start $end $frames $samples | Add-Member -NotePropertyName File -NotePropertyValue '' -PassThru
}
function New-MatchesPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,18' Margin='0,0,0,16'>
    <StackPanel>
      <TextBlock x:Name='State' FontSize='14' FontWeight='SemiBold'/>
      <TextBlock x:Name='How' FontSize='12.5' Foreground='#A1A1A6' Margin='0,4,0,0' TextWrapping='Wrap' LineHeight='18' LineStackingStrategy='BlockLineHeight'/>
    </StackPanel>
  </Border>
  <StackPanel x:Name='List'/>
</StackPanel>
"@)
    $script:MatchUi = @{ State = $root.FindName('State'); How = $root.FindName('How'); List = $root.FindName('List') }
    Update-MatchesPage
    New-PageScroll $root
}
function Update-MatchesPage {
    $mu = $script:MatchUi
    $on = [bool](Get-Setting 'matchreport' $true)
    $pm = Test-Path $PresentMonExe
    $mu.State.Text = if (-not $on) { 'Match reports are off (Settings).' }
                     elseif ($script:MatchRec) { "Recording since $($script:MatchRec.Start.ToString('HH:mm')). The report appears when you close Fortnite." }
                     elseif ($script:MatchAnalysis) { 'Building the report...' }
                     else { 'Ready. Play with ZeroDelay open (the tray is enough) and close Fortnite when you are done.' }
    $mu.How.Text = 'ZeroDelay checks every 5 seconds which apps use your CPU, how hot your graphics card is and how much memory is free. ' +
                   $(if ($pm) { 'PresentMon records every frame, so each stutter is shown with what was busy at that moment.' }
                     else { 'To also find stutters, download PresentMon once on the Benchmark page.' })
    $mu.List.Children.Clear()
    $reports = Get-MatchReports
    if (-not $reports) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = 'No reports yet. Your first one appears after your next Fortnite session (at least 2 minutes).'
        $tb.Foreground = ConvertTo-Brush '#98989D'; $tb.FontSize = 13; $tb.Margin = '4,4,0,0'
        [void]$mu.List.Children.Add($tb); return
    }
    foreach ($r in $reports) {
        $start = [datetime]$r.Start
        $head = "$($start.ToString('ddd d MMM, HH:mm'))  ·  $($r.Minutes) min"
        $fpsTxt = if ($r.Fps) { "$($r.Fps.Avg) FPS average  ·  $($r.Fps.Low1) FPS 1% low" } else { 'No frame data (PresentMon not downloaded)' }
        $issues = @($r.Issues)
        $verdict = if ($issues.Count) { "$($issues.Count) thing$(if ($issues.Count -ne 1) { 's' }) got in the way" } else { 'Smooth session: nothing got in the way' }
        $vColor = if ($issues.Count) { '#FF9F0A' } else { '#30D158' }
        $issueX = ($issues | ForEach-Object { "<TextBlock Text='$(Esc "•  $_")' FontSize='12.5' Foreground='#D1D1D6' TextWrapping='Wrap' Margin='0,6,0,0' LineHeight='18' LineStackingStrategy='BlockLineHeight'/>" }) -join ''
        $st = @($r.Stutters)
        $stX = ''
        if ($st.Count) {
            $stX = "<TextBlock Text='Stutters' FontSize='12' FontWeight='SemiBold' Foreground='#A1A1A6' Margin='0,14,0,2'/>" +
                (($st | Select-Object -First 10 | ForEach-Object {
                    "<Grid Margin='0,3,0,0'><Grid.ColumnDefinitions><ColumnDefinition Width='60'/><ColumnDefinition Width='70'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
                    "<TextBlock Text='$(([datetime]$_.At).ToString('HH:mm:ss'))' FontSize='12' Foreground='#D1D1D6'/>" +
                    "<TextBlock Grid.Column='1' Text='$($_.Ms) ms' FontSize='12' Foreground='#FF453A' FontWeight='SemiBold'/>" +
                    "<TextBlock Grid.Column='2' Text='$(Esc $(if ($_.Busy) { "busy: $($_.Busy)" } else { 'nothing else was busy' }))' FontSize='12' Foreground='#98989D' TextTrimming='CharacterEllipsis'/></Grid>"
                }) -join '')
            $more = [int]$r.StutterCount - [Math]::Min(10, $st.Count)
            if ($more -gt 0) { $stX += "<TextBlock Text='and $more more' FontSize='12' Foreground='#98989D' Margin='0,4,0,0'/>" }
        }
        $gpuX = if ($r.GpuMaxTemp) { "  ·  GPU up to $($r.GpuMaxTemp) °C" } else { '' }
        $fixes = @(Get-MatchFixes $r)
        $fixX = ''
        if ($fixes.Count) {
            $left = @($fixes | Where-Object { -not $_.Done }).Count
            $fixX = "<Border Margin='0,16,0,0' CornerRadius='14' Background='#0A2EE6A6' BorderBrush='#332EE6A6' BorderThickness='1' Padding='14,12,14,6'><StackPanel>" +
                    "<StackPanel Orientation='Horizontal' Margin='2,0,0,10'><TextBlock Text='&#xE90F;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='13' Foreground='#2EE6A6' VerticalAlignment='Center' Margin='0,1,8,0'/>" +
                    "<TextBlock Text='How to fix it' FontSize='13.5' FontWeight='SemiBold' Foreground='#2EE6A6'/>" +
                    "<TextBlock Text='$(if ($left) { "$left to do" } else { 'all done' })' FontSize='12' Foreground='#9A9AA5' VerticalAlignment='Center' Margin='10,1,0,0'/></StackPanel>"
            for ($i = 0; $i -lt $fixes.Count; $i++) {
                $fx = $fixes[$i]
                $right = if ($fx.Done) { "<Border Grid.Column='2' Background='#2630D158' CornerRadius='10' Padding='10,4,12,5' VerticalAlignment='Center'><StackPanel Orientation='Horizontal'><TextBlock Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='11' Foreground='#30D158' VerticalAlignment='Center' Margin='0,1,6,0'/><TextBlock Text='Done' FontSize='12' FontWeight='SemiBold' Foreground='#30D158'/></StackPanel></Border>" }
                         elseif ($fx.Button) { "<Button x:Name='F_$i' Grid.Column='2' Content='$(Esc $fx.Button)' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Padding='14,6' FontSize='12.5' VerticalAlignment='Center'/>" } else { '' }
                $fixX += "<Border Background='#0DFFFFFF' CornerRadius='12' Padding='12,10' Margin='0,0,0,8'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
                         "<Border Width='34' Height='34' CornerRadius='9' Background='$($fx.Tint -replace '^#', '#33')' VerticalAlignment='Top'><TextBlock Text='&#x$('{0:X}' -f $fx.Icon);' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='15' Foreground='$($fx.Tint)' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" +
                         "<StackPanel Grid.Column='1' Margin='12,0,14,0' VerticalAlignment='Center'><TextBlock Text='$(Esc $fx.Title)' FontSize='13' FontWeight='SemiBold' TextWrapping='Wrap'/>" +
                         "<TextBlock Text='$(Esc $fx.Desc)' FontSize='12' Foreground='#A1A1A6' TextWrapping='Wrap' Margin='0,2,0,0' LineHeight='17' LineStackingStrategy='BlockLineHeight'/></StackPanel>$right</Grid></Border>"
            }
            $fixX += "</StackPanel></Border>"
        }
        $card = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,0,0,10'>
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text='$(Esc $head)' FontSize='14' FontWeight='SemiBold'/>
        <TextBlock Text='$(Esc "$fpsTxt$gpuX")' FontSize='12' Foreground='#A1A1A6' Margin='0,3,0,0'/>
      </StackPanel>
      <Button x:Name='Del' Grid.Column='1' Content='Delete' Style='{DynamicResource Btn}' Foreground='#FF453A' Padding='12,5' FontSize='12' VerticalAlignment='Top'/>
    </Grid>
    <TextBlock Text='$(Esc $verdict)' FontSize='13' FontWeight='SemiBold' Foreground='$vColor' Margin='0,12,0,0'/>
    $issueX
    $fixX
    $stX
  </StackPanel>
</Border>
"@)
        for ($i = 0; $i -lt $fixes.Count; $i++) { $b = $card.FindName("F_$i"); if ($b) { $b.Tag = $fixes[$i]; $b.Add_Click({ param($s, $e) Invoke-MatchFix $s.Tag }) } }
        $del = $card.FindName('Del')
        if ($r.File) { $del.Tag = $r.File; $del.Add_Click({ param($s, $e) Remove-Item $s.Tag -Force -ErrorAction SilentlyContinue; Update-MatchesPage }) } else { $del.IsEnabled = $false }
        [void]$mu.List.Children.Add($card)
    }
}

# --- Background work: runs a script in its own runspace so the window never freezes, then calls Done on the UI thread.
$script:BgJobs = New-Object Collections.ArrayList
function Start-Background([string]$Script, [object[]]$ArgList = @(), [scriptblock]$Done) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    [void]$script:BgJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $Done })
    Start-BgPoll
}
function Start-BgPoll {
    if (-not $script:BgTimer) {
        $script:BgTimer = New-Object Windows.Threading.DispatcherTimer
        $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:BgTimer.Add_Tick({
            foreach ($j in @($script:BgJobs)) {
                if (-not $j.Handle.IsCompleted) { continue }
                $script:BgJobs.Remove($j)
                $out = $null; $errs = @()
                try { $out = $j.PS.EndInvoke($j.Handle) } catch { $errs += $_ }
                $errs += @($j.PS.Streams.Error)
                $j.PS.Dispose()
                if ($j.Worker) { $script:WorkerJob = $null }
                if ($j.Done) { try { & $j.Done @($out) $errs } catch { [Console]::Error.WriteLine("$_ $($_.InvocationInfo.PositionMessage)"); Show-Toast "Something went wrong: $($_.Exception.Message)" '#FF453A' } }
                if ($j.Worker) { Start-WorkerNext }
            }
            if (-not $script:BgJobs.Count) { $script:BgTimer.Stop() }
        })
    }
    $script:BgTimer.Start()
}
# --- Background worker: a second PowerShell with all of ZeroDelay's functions, for slow reads (setting checks,
#     NVIDIA driver profile, process lists) so the window never waits for them. Jobs run one after another.
$script:WorkerQueue = New-Object Collections.ArrayList
function Initialize-Worker {
    if ($script:Worker) { return }
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    # Windows modules whose objects need their type data (device IDs, task states, adapter values): a pool shares
    # one type table, so they are loaded up front instead of on first use
    $iss.ImportPSModule([string[]]@('PnpDevice', 'ScheduledTasks', 'NetAdapter', 'NetQos', 'Storage', 'ConfigDefender', 'NetTCPIP', 'DnsClient'))
    foreach ($fn in Get-ChildItem Function: | Where-Object { $_.ScriptBlock.File -eq $PSCommandPath }) {
        $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry $fn.Name, $fn.Definition))
    }
    # plain data only: never windows, timers, jobs or tray objects
    $skip = 'window', 'ui', 'Tweaks', 't', 'Splash', 'ReadCache', 'Worker', 'WorkerQueue', 'WorkerJob', 'BgJobs', 'AnimQueue', 'Uncache', 'Pages', 'PageRefresh', 'NavButtons', 'NavGroups', 'Tray'
    # PowerShell's own variables are left out: the worker has its own (a script run with -File shares the global scope)
    $builtin = [powershell]::Create(); $builtinNames = @($builtin.AddScript('(Get-Variable).Name').Invoke()) + 'args', 'input', 'MyInvocation', 'PSBoundParameters', 'PSCommandPath', 'PSScriptRoot', 'this', '_', 'foreach', 'switch', 'Matches', 'LASTEXITCODE', 'Error', 'StackTrace', 'PSItem', 'sender', 'EventArgs', 'Event'; $builtin.Dispose()
    foreach ($v in Get-Variable -Scope Script) {
        if ($skip -contains $v.Name -or ($v.Options -band 11) -or $builtinNames -contains $v.Name) { continue }
        $val = $v.Value
        if ($val -is [Windows.Threading.DispatcherObject] -or $val -is [ComponentModel.Component] -or $val -is [Management.Automation.Job] -or $val -is [Threading.WaitHandle] -or $val -is [Management.Automation.Runspaces.Runspace]) { continue }
        $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry $v.Name, $val, ''))
    }
    $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry 'ReadCache', @{}, ''))
    # three PowerShells, so independent reads run side by side
    $pool = [runspacefactory]::CreateRunspacePool(3, 3, $iss, $Host)
    $pool.ApartmentState = 'STA'; $pool.ThreadOptions = 'ReuseThread'
    [void]$pool.BeginOpen($null, $null)
    $script:Worker = $pool
}
# Runs $Code (script text) in the worker with $ArgList; $Done gets the output on the UI thread.
function Invoke-Worker([string]$Code, [object[]]$ArgList = @(), [scriptblock]$Done) {
    Initialize-Worker
    [void]$script:WorkerQueue.Add(@{ Code = $Code; Args = $ArgList; Done = $Done })
    Start-WorkerNext
}
function Start-WorkerNext {
    if (-not $script:WorkerQueue.Count) { return }
    if ($script:Worker.RunspacePoolStateInfo.State -ne 'Opened') {
        if ($script:Worker.RunspacePoolStateInfo.State -in 'Broken', 'Closed') { $script:Worker = $null; $q = @($script:WorkerQueue); $script:WorkerQueue.Clear(); foreach ($j in $q) { & $j.Done @() @('worker unavailable') }; return }
        if (-not $script:WorkerWait) {
            $script:WorkerWait = New-Object Windows.Threading.DispatcherTimer; $script:WorkerWait.Interval = [TimeSpan]::FromMilliseconds(50)
            $script:WorkerWait.Add_Tick({ if ($script:Worker.RunspacePoolStateInfo.State -ne 'Opening') { $script:WorkerWait.Stop(); Start-WorkerNext } })
        }
        $script:WorkerWait.Start(); return
    }
    while ($script:WorkerQueue.Count) {
        $job = $script:WorkerQueue[0]; $script:WorkerQueue.RemoveAt(0)
        $ps = [powershell]::Create(); $ps.RunspacePool = $script:Worker
        # each run gets its own read cache: the three PowerShells must not share one
        $code = if ($job.Code -match '^\s*param\([^)]*\)') { $job.Code.Insert($Matches[0].Length, "`n`$global:ReadCache = @{}") } else { "`$global:ReadCache = @{}`n" + $job.Code }
        [void]$ps.AddScript($code); foreach ($a in $job.Args) { [void]$ps.AddArgument($a) }
        [void]$script:BgJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $job.Done })
    }
    Start-BgPoll
}
function Get-WorkerResult($out) { $r = @($out | Where-Object { $null -ne $_ }) | Select-Object -First 1; if ($null -ne $r) { $r.psobject.BaseObject } }
# A tweak as plain data for the worker: scriptblocks travel as text and are rebuilt there.
function ConvertTo-WorkerSpec($t) {
    $o = @{}
    foreach ($k in @($t.PSBase.Keys)) {
        if ($k -in 'Card', 'Toggle', 'ActionBtn', 'PreviewHost') { continue }
        $v = $t[$k]
        $o[$k] = if ($v -is [scriptblock]) { @{ __sb = $v.ToString() } } else { $v }
    }
    $o
}
$WorkerTestScript = @'
param($specs)
$res = @{ __nvlod = $(if (Test-NvAvailable) { Get-NvLod } else { $null }) }
$script:CurrentNvLod = $res.__nvlod
foreach ($s in $specs) {
    $t = @{}
    foreach ($k in $s.PSBase.Keys) { $v = $s[$k]; $t[$k] = if ($v -is [hashtable] -and $v.ContainsKey('__sb')) { [scriptblock]::Create($v.__sb) } else { $v } }
    if (-not $t.Id) { continue }
    $st = Invoke-TweakTest $t
    $req = if ($t.Requires -and $null -eq $st) { try { [bool](& $t.Requires) } catch { $false } } else { $true }
    $res[$t.Id] = @{ State = $st; Req = $req }
}
$res
'@
# Checks every card in the background, then updates them all at once.
function Start-StateRefresh([scriptblock]$Then) {
    $specs = @($Tweaks | Where-Object { -not $_.Header -and -not $_.Picker -and -not $_.Action } | ForEach-Object { ConvertTo-WorkerSpec $_ })   # the cards that get a switch
    $script:StateThen = $Then
    # split across the three worker PowerShells, slow and fast checks mixed
    $n = 3; $script:StateParts = @{}; $script:StateLeft = $n; $script:StateFail = $false
    for ($i = 0; $i -lt $n; $i++) {
        $chunk = @(for ($j = $i; $j -lt $specs.Count; $j += $n) { $specs[$j] })
        Invoke-Worker $WorkerTestScript @(, $chunk) {
            param($out, $errs)
            $r = Get-WorkerResult $out
            if ($r -is [hashtable]) { foreach ($k in $r.PSBase.Keys) { $script:StateParts[$k] = $r[$k] } } else { $script:StateFail = $true }
            if (--$script:StateLeft -eq 0) { Complete-StateRefresh }
        }
    }
}
function Complete-StateRefresh {
        $res = $script:StateParts
        if (-not $script:StateFail -and $res.Count -gt 1) {
            $script:CurrentNvLod = $res.__nvlod
            foreach ($t in $Tweaks) { if ($t.Toggle -and $res.ContainsKey($t.Id)) { Update-Card $t $res[$t.Id] } elseif ($t.Preset) { Update-Card $t } }
            Update-Summary
        } else { Update-All }    # worker failed: do it here
        if ($script:EventsUi) { Update-EventsReady }
        Test-AfterBoot; Update-RestartBar
        if ($script:StateThen) { $then = $script:StateThen; $script:StateThen = $null; & $then }
}
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) } elseif ($Bytes -gt 0) { '{0:N0} KB' -f [Math]::Max(1, $Bytes / 1KB) } else { '0 MB' }
}

# =============================================================== Uninstall apps
# Store apps Windows needs (or that are needed to get apps back) are never listed.
$StoreProtected = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.StorePurchaseApp', 'Microsoft.Windows.Photos.DLC')
# Preinstalled apps most people never open. Only labelled; nothing is removed unless you press Uninstall.
$StoreBloat = @('Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.549981C3F5F10', 'MicrosoftCorporationII.QuickAssist',
    'Microsoft.WindowsMaps', 'Microsoft.Copilot', 'Microsoft.OutlookForWindows', 'MicrosoftTeams', 'MSTeams', 'Microsoft.MixedReality.Portal', 'Microsoft.SkypeApp')
$AppScanScript = {
    param($opt)
    $list = New-Object Collections.ArrayList
    $seen = @{}
    # Start-menu shortcuts by name -> the exe they open (used for icons when an app registers none)
    $lnkIndex = @{}
    $sh = New-Object -ComObject WScript.Shell
    foreach ($r in "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs") {
        foreach ($l in Get-ChildItem -LiteralPath $r -Recurse -Filter *.lnk -ErrorAction SilentlyContinue) {
            try { $tgt = $sh.CreateShortcut($l.FullName).TargetPath; if ($tgt -and $tgt -like '*.exe' -and $tgt -notmatch '(?i)unins|\\Windows\\') { $k = $l.BaseName.ToLower(); if (-not $lnkIndex.ContainsKey($k)) { $lnkIndex[$k] = $tgt } } } catch {}
        }
    }
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName -or -not $p.UninstallString -or $p.SystemComponent -eq 1 -or $p.ParentKeyName -or "$($p.ReleaseType)" -match 'Update|Hotfix') { continue }
            if ($p.DisplayName -eq 'ZeroDelay') { continue }
            $id = "$($p.DisplayName)|$($p.DisplayVersion)"
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $date = $null
            if ("$($p.InstallDate)" -match '^(\d{4})(\d{2})(\d{2})$') { try { $date = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] } catch {} }
            # the app's own icon (the one Settings > Apps shows), as PNG bytes. Fallbacks: the uninstaller, the app's
            # Start-menu shortcut, then an exe in its install folder whose name matches the app.
            $png = $null
            $nameKey = ("$($p.DisplayName)" -replace '\s*\(.*?\)|\s+v?\d+(\.\d+)+.*$', '').Trim().ToLower()
            $first = ($nameKey -split '\s+')[0]
            $lnkTarget = $null
            if ($nameKey) {
                $hit = $lnkIndex.Keys | Where-Object { $_ -eq $nameKey } | Select-Object -First 1
                if (-not $hit -and $first.Length -ge 4) { $hit = $lnkIndex.Keys | Where-Object { $_ -like "$nameKey*" -or $_ -like "$first*" } | Select-Object -First 1 }
                if ($hit) { $lnkTarget = $lnkIndex[$hit] }
            }
            $dirExe = $null
            if ($p.InstallLocation -and $first.Length -ge 3 -and (Test-Path -LiteralPath "$($p.InstallLocation)".Trim('"'))) {
                $dirExe = Get-ChildItem -LiteralPath "$($p.InstallLocation)".Trim('"') -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like "*$first*" -and $_.Name -notmatch '(?i)unins|setup|update|crash|helper' } | Select-Object -First 1 -ExpandProperty FullName
            }
            foreach ($src in "$($p.DisplayIcon)", "$($p.UninstallString)", "$lnkTarget", "$dirExe") {
                if ($png -or -not $src -or $src -match '(?i)msiexec|rundll32') { continue }
                $path = if ($src.Trim().StartsWith('"')) { $src.Trim().Split('"')[1] } else { ($src -split '(?i)(?<=\.(exe|ico|dll))')[0] }
                $path = ($path -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
                if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                try {
                    $icon = if ($path -match '(?i)\.ico$') { New-Object System.Drawing.Icon $path, 48, 48 } else { [System.Drawing.Icon]::ExtractAssociatedIcon($path) }
                    $bmp = $icon.ToBitmap(); $ms = New-Object IO.MemoryStream
                    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $png = $ms.ToArray()
                    $bmp.Dispose(); $icon.Dispose(); $ms.Dispose()
                } catch {}
            }
            [void]$list.Add([pscustomobject]@{ Kind = 'desktop'; Name = "$($p.DisplayName)".Trim(); Publisher = "$($p.Publisher)".Trim(); Version = "$($p.DisplayVersion)"
                SizeMb = $(if ($p.EstimatedSize) { [Math]::Round($p.EstimatedSize / 1024.0) } else { $null }); Date = $date; Uninstall = "$($p.UninstallString)"; Id = $k.PSChildName; Bloat = $false
                InstallLocation = "$($p.InstallLocation)"; Icon = "$($p.DisplayIcon)"; KeyPath = ($k.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:'); IconPng = $png })
        }
    }
    foreach ($a in @(Get-AppxPackage -PackageTypeFilter Main -ErrorAction SilentlyContinue)) {
        if ($a.IsFramework -or $a.NonRemovable -or "$($a.SignatureKind)" -eq 'System' -or $opt.Protected -contains $a.Name) { continue }
        $dn = $null; $pub = $null; $png = $null
        try { [xml]$m = Get-Content (Join-Path $a.InstallLocation 'AppxManifest.xml') -Raw -ErrorAction Stop; $dn = "$($m.Package.Properties.DisplayName)"; $pub = "$($m.Package.Properties.PublisherDisplayName)" } catch {}
        # Store logo: the manifest names a base file; the package ships size variants (scale-100, targetsize-48, ...)
        try {
            $lg = "$($m.Package.Properties.Logo)"
            if ($lg) {
                $full = Join-Path $a.InstallLocation $lg
                $pick = if (Test-Path -LiteralPath $full) { $full } else {
                    Get-ChildItem -LiteralPath (Split-Path $full) -Filter "$([IO.Path]::GetFileNameWithoutExtension($full)).*$([IO.Path]::GetExtension($full))" -ErrorAction SilentlyContinue |
                        Sort-Object { if ($_.Name -match 'scale-100|targetsize-48') { 0 } elseif ($_.Name -match 'scale-1[25]0|targetsize-(32|64)') { 1 } elseif ($_.Name -match 'scale-200') { 2 } else { 3 } } |
                        Select-Object -First 1 -ExpandProperty FullName }
                if ($pick -and (Get-Item -LiteralPath $pick).Length -lt 200KB) { $png = [IO.File]::ReadAllBytes($pick) }
            }
        } catch {}
        if (-not $dn -or $dn -like 'ms-resource:*') { $dn = (($a.Name -replace '^[^.]+\.', '') -creplace '([a-z])([A-Z])', '$1 $2') }
        if (-not $pub -or $pub -like 'ms-resource:*') { $pub = ($a.Publisher -replace '^CN=([^,]+).*', '$1') }
        [void]$list.Add([pscustomobject]@{ Kind = 'store'; Name = $dn; Publisher = $pub; Version = "$($a.Version)"; SizeMb = $null; Date = $null
            Full = $a.PackageFullName; Id = $a.Name; Family = $a.PackageFamilyName; Bloat = ($opt.Bloat -contains $a.Name); IconPng = $png })
    }
    $list
}
function New-AppsPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='20,16' Margin='0,0,0,14'>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel Orientation='Horizontal'>
          <Button x:Name='TabDesk' Content='Programs' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
          <Button x:Name='TabStore' Content='Store apps' Style='{DynamicResource Btn}'/>
        </StackPanel>
        <TextBox x:Name='Find' Grid.Column='1' Margin='16,0' Padding='10,6' FontSize='13' Background='#1C1C1E' Foreground='#F5F5F7' BorderBrush='#38383A' CaretBrush='#F5F5F7' VerticalContentAlignment='Center' ToolTip='Search by name or publisher'/>
        <StackPanel Grid.Column='2' Orientation='Horizontal'>
          <Button x:Name='SortName' Content='A to Z' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
          <Button x:Name='SortSize' Content='Biggest' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
          <Button x:Name='SortDate' Content='Newest' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
          <Button x:Name='Reload' Content='Refresh' Style='{DynamicResource Btn}'/>
        </StackPanel>
      </Grid>
      <TextBlock x:Name='Hint' FontSize='12' Foreground='#98989D' Margin='0,12,0,0' TextWrapping='Wrap'/>
    </StackPanel>
  </Border>
  <ContentControl x:Name='List'/>
</StackPanel>
"@)
    $au = @{}; foreach ($n in 'TabDesk', 'TabStore', 'Find', 'SortName', 'SortSize', 'SortDate', 'Reload', 'Hint', 'List') { $au[$n] = $root.FindName($n) }
    $script:AppsUi = $au
    $script:AppsKind = 'desktop'; $script:AppsSort = 'name'; $script:AppsData = $null
    $au.TabDesk.Add_Click({ $script:AppsKind = 'desktop'; Update-AppsList })
    $au.TabStore.Add_Click({ $script:AppsKind = 'store'; Update-AppsList })
    $au.SortName.Add_Click({ $script:AppsSort = 'name'; Update-AppsList })
    $au.SortSize.Add_Click({ $script:AppsSort = 'size'; Update-AppsList })
    $au.SortDate.Add_Click({ $script:AppsSort = 'date'; Update-AppsList })
    $au.Reload.Add_Click({ Start-AppScan })
    # filter as you type, after a short pause
    $script:AppsFindTimer = New-Object Windows.Threading.DispatcherTimer
    $script:AppsFindTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:AppsFindTimer.Add_Tick({ $script:AppsFindTimer.Stop(); Update-AppsList })
    $au.Find.Add_TextChanged({ $script:AppsFindTimer.Stop(); $script:AppsFindTimer.Start() })
    Start-AppScan
    New-PageScroll $root
}
function Start-AppScan {
    $script:AppsUi.Hint.Text = 'Reading your installed apps...'
    Start-Background $AppScanScript.ToString() @(@{ Protected = $StoreProtected; Bloat = $StoreBloat }) {
        param($out, $errs)
        $script:AppsData = @($out | Where-Object { $_ })
        Update-AppsList
    }
}
function Update-AppsList {
    $au = $script:AppsUi
    if ($null -eq $script:AppsData) { return }
    foreach ($b in 'TabDesk', 'TabStore') {
        $on = ($b -eq 'TabDesk') -eq ($script:AppsKind -eq 'desktop')
        if ($on) { $au[$b].Background = ConvertTo-Brush '#0071E3'; $au[$b].Foreground = ConvertTo-Brush '#FFFFFF' }
        else { $au[$b].ClearValue([Windows.Controls.Control]::BackgroundProperty); $au[$b].ClearValue([Windows.Controls.Control]::ForegroundProperty) }
    }
    $desk = @($script:AppsData | Where-Object { $_.Kind -eq 'desktop' }); $store = @($script:AppsData | Where-Object { $_.Kind -eq 'store' })
    $au.TabDesk.Content = "Programs ($($desk.Count))"; $au.TabStore.Content = "Store apps ($($store.Count))"
    foreach ($b in 'SortSize', 'SortDate') { $au[$b].Visibility = if ($script:AppsKind -eq 'desktop') { 'Visible' } else { 'Collapsed' } }
    foreach ($b in 'SortName', 'SortSize', 'SortDate') { $au[$b].FontWeight = if ($b -eq "Sort$($script:AppsSort)") { 'Bold' } else { 'Normal' } }
    $q = $au.Find.Text.Trim()
    $items = if ($script:AppsKind -eq 'desktop') { $desk } else { $store }
    if ($q) { $items = @($items | Where-Object { $_.Name -like "*$q*" -or $_.Publisher -like "*$q*" }) }
    $items = switch ($script:AppsSort) {
        'size' { if ($script:AppsKind -eq 'desktop') { @($items | Sort-Object { [double]$_.SizeMb } -Descending) } else { @($items | Sort-Object Name) } }
        'date' { if ($script:AppsKind -eq 'desktop') { @($items | Sort-Object { if ($_.Date) { $_.Date } else { [datetime]::MinValue } } -Descending) } else { @($items | Sort-Object Name) } }
        default { @($items | Sort-Object @{ e = { -not $_.Bloat } }, Name) }
    }
    $au.Hint.Text = if ($script:AppsKind -eq 'desktop') { "Each program's own uninstaller opens when you press Uninstall: follow its steps. Showing $($items.Count)." }
                    else { "Removed for your Windows account only. Any of these can be reinstalled from the Microsoft Store. Apps marked 'Often unused' come with Windows and most people never open them. Showing $($items.Count)." }
    $rows = for ($i = 0; $i -lt [Math]::Min(400, $items.Count); $i++) {
        $a = $items[$i]
        $sub = @($a.Publisher, $(if ($a.Version) { "version $($a.Version)" }), $(if ($a.SizeMb) { Format-Size ($a.SizeMb * 1MB) }), $(if ($a.Date) { "installed $($a.Date.ToString('d MMM yyyy'))" })) | Where-Object { $_ }
        $tag = if ($a.Bloat) { "<Border Background='#4E3E28' CornerRadius='5' Padding='7,1,7,2' Margin='10,0,0,0' VerticalAlignment='Center'><TextBlock Text='Often unused' FontSize='11' Foreground='#FF9F0A'/></Border>" } else { '' }
        # icon slot: a letter tile in the app's own colour, covered by the real icon when there is one
        $nm = "$($a.Name)".Trim() -replace '^[^A-Za-z0-9]+', ''
        $letter = if ($nm) { Esc $nm.Substring(0, 1).ToUpper() } else { '?' }
        $tint = $AppTileColors[[Math]::Abs(("$($a.Name)".GetHashCode())) % $AppTileColors.Count]
        "<Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='10' Padding='12,10,16,10' Margin='0,0,0,6'><Grid>" +
        "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<Grid Width='36' Height='36' Margin='0,0,14,0' VerticalAlignment='Center'>" +
        "<Border x:Name='T_$i' CornerRadius='9' Background='$tint'><TextBlock Text='$letter' FontSize='16' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" +
        "<Image x:Name='I_$i' Width='32' Height='32' HorizontalAlignment='Center' VerticalAlignment='Center' RenderOptions.BitmapScalingMode='HighQuality'/></Grid>" +
        "<StackPanel Grid.Column='1' VerticalAlignment='Center'><StackPanel Orientation='Horizontal'><TextBlock Text='$(Esc $a.Name)' FontSize='13.5' FontWeight='SemiBold' TextTrimming='CharacterEllipsis'/>$tag</StackPanel>" +
        "<TextBlock Text='$(Esc ($sub -join '  ·  '))' FontSize='12' Foreground='#98989D' Margin='0,2,0,0' TextTrimming='CharacterEllipsis'/></StackPanel>" +
        "<StackPanel Grid.Column='2' Orientation='Horizontal' VerticalAlignment='Center' Margin='12,0,0,0'>" +
        "<Button x:Name='U_$i' Content='Uninstall' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12' Margin='0,0,6,0'/>" +
        "<Button x:Name='F_$i' Content='Force remove' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12' Foreground='#FF453A' ToolTip='$(Esc $(if ($a.Kind -eq 'store') { 'Removes it for every account on this PC and stops Windows from installing it again for new accounts.' } else { 'Skips the app''s own uninstaller: closes it, then deletes its files, settings, shortcuts, services and tasks. For apps whose normal uninstall fails.' }))'/>" +
        "</StackPanel></Grid></Border>"
    }
    if (-not $items.Count) { $rows = @("<TextBlock Text='Nothing matches.' Foreground='#98989D' FontSize='13' Margin='4,4,0,0'/>") }
    $panel = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$($rows -join '')</StackPanel>")
    for ($i = 0; $i -lt [Math]::Min(400, $items.Count); $i++) {
        $img = Get-AppIconSource $items[$i]
        if ($img) { $panel.FindName("I_$i").Source = $img; $panel.FindName("T_$i").Visibility = 'Collapsed' }
        $b = $panel.FindName("U_$i"); $b.Tag = $items[$i]
        $b.Add_Click({ param($s, $e) Invoke-AppUninstall $s.Tag })
        $b = $panel.FindName("F_$i"); $b.Tag = $items[$i]
        $b.Add_Click({ param($s, $e) Invoke-ForceRemove $s.Tag })
    }
    $au.List.Content = $panel
}
# App icons: made once from the PNG bytes the scan collected, then reused when the list is filtered or sorted.
$AppTileColors = @('#5E5CE6', '#0A84FF', '#30B0C7', '#34C759', '#FF9F0A', '#FF6482', '#BF5AF2', '#AC8E68', '#8E8E93')
function Get-AppIconSource($app) {
    if ($app.IconSrc) { return $app.IconSrc }
    if (-not $app.IconPng) { return $null }
    try {
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit(); $bi.StreamSource = New-Object IO.MemoryStream (, [byte[]]$app.IconPng); $bi.CacheOption = 'OnLoad'; $bi.DecodePixelWidth = 64; $bi.EndInit(); $bi.Freeze()
        $app | Add-Member -NotePropertyName IconSrc -NotePropertyValue $bi -Force
        $bi
    } catch { $null }
}
function Invoke-AppUninstall($app) {
    if ($app.Kind -eq 'store') {
        $r = (Show-ZdDialog ("Remove $($app.Name)?`n`nIt is removed for your Windows account. You can reinstall it from the Microsoft Store at any time.") ('Uninstall app') ('YesNo') ('Question'))
        if ($r -ne 'Yes') { return }
        Show-Toast "Removing $($app.Name)..." '#A1A1A6'
        $script:RemovingApp = $app.Name
        Start-Background 'param($f) Remove-AppxPackage -Package $f -ErrorAction Stop' @($app.Full) {
            param($out, $errs)
            $name = $script:RemovingApp
            if ($errs) { Show-Toast "$name could not be removed: $($errs[0].Exception.Message)" '#FF453A'; return }
            Add-History "Removed app: $name" 'apps' $null
            Show-Toast "$name was removed." '#30D158'
            Start-AppScan
        }
        return
    }
    $r = (Show-ZdDialog ("Uninstall $($app.Name)?`n`nIts own uninstaller opens next. Follow its steps; some ask you to restart.") ('Uninstall app') ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    $cmd = $app.Uninstall.Trim()
    if ($cmd -match '(?i)msiexec') {
        $guid = [regex]::Match($cmd, '\{[0-9A-Fa-f-]{36}\}').Value
        $file = 'msiexec.exe'; $argText = if ($guid) { "/x $guid" } else { ($cmd -replace '(?i)^.*?msiexec(\.exe)?"?\s*', '') -replace '(?i)/i', '/x' }
    } elseif ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1); $file = $cmd.Substring(1, $end - 1); $argText = $cmd.Substring($end + 1).Trim()
    } else {
        $i = $cmd.ToLower().IndexOf('.exe')
        if ($i -gt 0) { $file = $cmd.Substring(0, $i + 4); $argText = $cmd.Substring($i + 4).Trim() } else { $file = $cmd; $argText = '' }
    }
    try {
        $proc = if ($argText) { Start-Process -FilePath $file -ArgumentList $argText -PassThru -ErrorAction Stop } else { Start-Process -FilePath $file -PassThru -ErrorAction Stop }
    } catch { Show-Toast "The uninstaller could not be started: $($_.Exception.Message)" '#FF453A'; return }
    # when the uninstaller closes, check whether the app is gone
    $script:UninstallWatch = @{ Proc = $proc; App = $app; Since = Get-Date }
    if (-not $script:UninstallTimer) {
        $script:UninstallTimer = New-Object Windows.Threading.DispatcherTimer
        $script:UninstallTimer.Interval = [TimeSpan]::FromSeconds(1.5)
        $script:UninstallTimer.Add_Tick({
            $w = $script:UninstallWatch
            if (-not $w.Proc.HasExited -and ((Get-Date) - $w.Since).TotalMinutes -lt 30) { return }
            $script:UninstallTimer.Stop()
            $gone = -not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($w.App.Id)") -and
                    -not (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$($w.App.Id)") -and
                    -not (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($w.App.Id)")
            if ($gone) { Add-History "Uninstalled: $($w.App.Name)" 'apps' $null }
            Start-AppScan
            Find-Leftovers $w.App $false
        })
    }
    $script:UninstallTimer.Start()
}

# --- Deep uninstall: find what an app leaves behind (or everything of an app whose uninstaller is broken) and delete it.
#     Only exact name matches and things that point into the app's own folders are listed, and system folders,
#     Windows, other apps' shared roots and ZeroDelay itself are never touched.
$LeftoverScan = {
    param($job)
    $a = $job.App
    $win = "$env:WINDIR".TrimEnd('\').ToLower()
    $never = @("$env:SystemDrive\", $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA,
        "$env:LOCALAPPDATA\Programs", "$env:ProgramFiles\Common Files", "${env:ProgramFiles(x86)}\Common Files", "$env:ProgramData\Package Cache",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), "$env:PUBLIC\Desktop", $env:PUBLIC, "$env:SystemDrive\Users", $env:TEMP) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }
    function Test-SafePath([string]$p) {
        if (-not $p) { return $false }
        $l = $p.TrimEnd('\').ToLower()
        if ($l.Length -lt 8 -or $l -notmatch '^[a-z]:\\') { return $false }
        if ($never -contains $l) { return $false }
        if ($l -eq $win -or $l.StartsWith("$win\")) { return $false }
        if ($l -match '\\(microsoft|windows|windowsapps|zerodelay|fortnitelatencyoptimizer|nvidia corporation|common files|steamapps)(\\|$)') { return $false }
        $true
    }
    # folders an app record points at: install location, and the folders of its icon and uninstaller
    function Get-AppDirs($x) {
        $d = @()
        if ($x.InstallLocation) { $d += "$($x.InstallLocation)".Trim().Trim('"') }
        foreach ($s in $x.Icon, $x.Uninstall) {
            if (-not $s -or $s -match '(?i)msiexec|rundll32|://') { continue }
            $exe = if ("$s".Trim().StartsWith('"')) { "$s".Trim().Split('"')[1] } else { ("$s" -split '(?i)(?<=\.exe)')[0] }
            $exe = $exe -replace ',\s*-?\d+$', ''
            if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) { $d += (Split-Path $exe -Parent) }
        }
        @($d | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | ForEach-Object { (Get-Item -LiteralPath $_ -Force).FullName.TrimEnd('\') } | Select-Object -Unique)
    }
    # where every OTHER installed program lives: a folder that holds any of them is shared, not this app's
    $otherDirs = @(foreach ($o in @($job.Others)) { Get-AppDirs $o }) | ForEach-Object { $_.ToLower() } | Select-Object -Unique
    # games installed by the Epic launcher (Fortnite, Rocket League, ...) are protected wherever they are
    $epicList = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
    if (Test-Path $epicList) { try { $otherDirs = @($otherDirs) + @((Get-Content $epicList -Raw | ConvertFrom-Json).InstallationList | ForEach-Object { "$($_.InstallLocation)".TrimEnd('\').ToLower() } | Where-Object { $_ }) } catch {} }
    function Test-Owned([string]$d) {
        $dl = $d.TrimEnd('\').ToLower()
        foreach ($o in $otherDirs) { if ($o -eq $dl -or $o.StartsWith("$dl\")) { return $false } }
        # game libraries and launchers' shared roots are never one app's leftovers
        foreach ($m in 'steamapps', 'Fortnite', 'FortniteGame', '.egstore', 'Riot Client', 'VALORANT', 'Games') { if (Test-Path -LiteralPath (Join-Path $d $m)) { return $false } }
        $true
    }
    $out = New-Object Collections.ArrayList
    function Add-Item($kind, $path, $label, $size = $null, $risky = $false) { [void]$out.Add([pscustomobject]@{ Kind = $kind; Path = $path; Label = $label; Size = $size; Risky = $risky }) }

    $own = @(Get-AppDirs $a)
    if ($a.InstallLocation -and $own) {
        # with an install location, icon/uninstaller folders count only when they are inside it
        $inst = $own[0].ToLower()
        $own = @($own | Where-Object { $_.ToLower() -eq $inst -or $_.ToLower().StartsWith("$inst\") })
    }
    $dirs = @($own | Where-Object { (Test-SafePath $_) -and (Test-Owned $_) })
    # names its folders and keys are likely to use: the display name without version/bitness, and its own folder's name
    $base = ($a.Name -replace '\s*\((x64|x86|64-bit|32-bit|[^)]*bit[^)]*)\)', '' -replace '(?i)\s+(version\s+)?v?\d+(\.\d+)+.*$', '').Trim()
    $names = @($a.Name.Trim(), $base) + @($dirs | ForEach-Object { Split-Path $_ -Leaf })
    $names = @($names | Where-Object { $_.Length -ge 3 -and $_ -notmatch '^(microsoft|windows|common files|program files|nvidia|intel|amd|google|valve|epic games|steam|update|setup|app|apps|data|cache|temp|games|bin)$' } | Select-Object -Unique)
    $pub = "$($a.Publisher)".Trim() -replace '[\\/:*?"<>|]', ''
    foreach ($root in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, "$env:LOCALAPPDATA\Programs") {
        if (-not $root) { continue }
        foreach ($n in $names) {
            foreach ($c in @("$root\$n") + $(if ($pub) { @("$root\$pub\$n") } else { @() })) {
                if ((Test-Path -LiteralPath $c -PathType Container) -and (Test-SafePath $c) -and (Test-Owned $c)) { $dirs += (Get-Item -LiteralPath $c -Force).FullName.TrimEnd('\') }
            }
        }
    }
    # keep only the outermost folders
    $dirs = @($dirs | Select-Object -Unique | Sort-Object Length)
    $top = @(); foreach ($d in $dirs) { if (-not ($top | Where-Object { $d.ToLower().StartsWith($_.ToLower() + '\') })) { $top += $d } }
    foreach ($d in $top) {
        $size = (Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Add-Item 'Folder' $d $d $size ($size -gt 10GB)
    }
    $inTop = { param($x) $x = "$x".Trim('"').ToLower(); foreach ($d in $top) { if ($x.StartsWith($d.ToLower() + '\') -or $x -eq $d.ToLower()) { return $true } }; $false }
    # registry: the uninstall entry and keys named exactly like the app
    if ($a.KeyPath -and (Test-Path $a.KeyPath)) { Add-Item 'Registry' $a.KeyPath "Uninstall entry: $($a.KeyPath)" }
    foreach ($rb in 'HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node') {
        foreach ($n in $names) {
            foreach ($c in @("$rb\$n") + $(if ($pub) { @("$rb\$pub\$n") } else { @() })) { if (Test-Path $c) { Add-Item 'Registry' $c $c } }
        }
    }
    # shortcuts, services, tasks and running programs that point into the app's own folders
    if ($top) {
        $sh = New-Object -ComObject WScript.Shell
        foreach ($r in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", [Environment]::GetFolderPath('Desktop'), "$env:PUBLIC\Desktop") {
            foreach ($lnk in Get-ChildItem -LiteralPath $r -Recurse -Filter *.lnk -Force -ErrorAction SilentlyContinue) {
                try { if (& $inTop $sh.CreateShortcut($lnk.FullName).TargetPath) { Add-Item 'Shortcut' $lnk.FullName $lnk.FullName } } catch {}
            }
        }
        foreach ($sv in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
            $img = "$($sv.PathName)"; $img = if ($img.StartsWith('"')) { $img.Split('"')[1] } else { ($img -split '(?i)(?<=\.exe)')[0] }
            if (& $inTop $img) { Add-Item 'Service' $sv.Name "Service: $($sv.DisplayName)" }
        }
        foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
            foreach ($act in @($t.Actions)) { if ($act.Execute -and (& $inTop ([Environment]::ExpandEnvironmentVariables($act.Execute)))) { Add-Item 'Task' "$($t.TaskPath)$($t.TaskName)" "Scheduled task: $($t.TaskPath)$($t.TaskName)"; break } }
        }
        $procs = @{}
        foreach ($pr in Get-Process -ErrorAction SilentlyContinue) {
            try { if ($pr.Path -and (& $inTop $pr.Path)) { if (-not $procs[$pr.ProcessName]) { $procs[$pr.ProcessName] = @() }; $procs[$pr.ProcessName] += $pr.Id } } catch {}
        }
        foreach ($k in $procs.Keys) { Add-Item 'Process' ($procs[$k] -join ',') "Running: $k$(if ($procs[$k].Count -gt 1) { " ($($procs[$k].Count))" }) (will be closed)" }
    }
    foreach ($r in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") {
        foreach ($n in $names) { $c = "$r\$n"; if ((Test-Path -LiteralPath $c -PathType Container) -and -not ($out | Where-Object { $_.Path -eq $c })) { Add-Item 'Folder' $c $c 0 } }
    }
    # a shortcut inside a Start-menu folder that is itself listed goes with the folder
    $folders = @($out | Where-Object { $_.Kind -eq 'Folder' } | ForEach-Object { $_.Path.ToLower() })
    foreach ($x in $out) {
        if ($x.Kind -eq 'Shortcut' -and ($folders | Where-Object { $x.Path.ToLower().StartsWith($_ + '\') })) { continue }
        $x
    }
}
$LeftoverRemove = {
    param($job)
    $res = New-Object Collections.ArrayList
    function Note($item, $state, $msg = '') { [void]$res.Add([pscustomobject]@{ Label = $item.Label; Kind = $item.Kind; State = $state; Msg = $msg }) }
    $items = @($job.Items)
    foreach ($it in $items | Where-Object { $_.Kind -eq 'Process' }) { foreach ($id in "$($it.Path)" -split ',') { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue }; Note $it 'done' }
    Start-Sleep -Milliseconds 600
    foreach ($it in $items | Where-Object { $_.Kind -eq 'Service' }) {
        Stop-Service -Name $it.Path -Force -ErrorAction SilentlyContinue
        & sc.exe delete $it.Path | Out-Null
        Note $it $(if ($LASTEXITCODE -eq 0) { 'done' } else { 'failed' })
    }
    foreach ($it in $items | Where-Object { $_.Kind -eq 'Task' }) {
        $tp = $it.Path.Substring(0, $it.Path.LastIndexOf('\') + 1); $tn = $it.Path.Substring($it.Path.LastIndexOf('\') + 1)
        try { Unregister-ScheduledTask -TaskPath $tp -TaskName $tn -Confirm:$false -ErrorAction Stop; Note $it 'done' } catch { Note $it 'failed' $_.Exception.Message }
    }
    foreach ($it in $items | Where-Object { $_.Kind -eq 'Registry' }) {
        # backup first, so a key can be put back by double-clicking the .reg file
        $native = $it.Path -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
        $file = Join-Path $job.BackupDir ("{0}-{1}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (($native -replace '[\\/:*?"<>| ]', '_') -replace '^(.{0,80}).*$', '$1'))
        & reg.exe export $native $file /y | Out-Null
        try { Remove-Item -Path $it.Path -Recurse -Force -ErrorAction Stop; Note $it 'done' } catch { Note $it 'failed' $_.Exception.Message }
    }
    foreach ($it in $items | Where-Object { $_.Kind -eq 'Shortcut' }) {
        try { Remove-Item -LiteralPath $it.Path -Force -ErrorAction Stop; Note $it 'done' } catch { if (-not (Test-Path -LiteralPath $it.Path)) { Note $it 'done' } else { Note $it 'failed' } }
    }
    foreach ($it in $items | Where-Object { $_.Kind -eq 'Folder' } | Sort-Object { $_.Path.Length } -Descending) {
        if (-not (Test-Path -LiteralPath $it.Path)) { Note $it 'done'; continue }
        Remove-Item -LiteralPath $it.Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $it.Path) {
            # brute force: take ownership, give Administrators full control, try again
            & takeown.exe /f $it.Path /r /d y 2>&1 | Out-Null
            & icacls.exe $it.Path /grant '*S-1-5-32-544:F' /t /c /q 2>&1 | Out-Null
            Get-ChildItem -LiteralPath $it.Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
            Remove-Item -LiteralPath $it.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $it.Path) {
            # still in use: Windows deletes what is left when the PC restarts
            $left = @(Get-ChildItem -LiteralPath $it.Path -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
            foreach ($f in $left) { [void][FileTools]::DeleteAtRestart($f.FullName) }
            [void][FileTools]::DeleteAtRestart($it.Path)
            Note $it 'restart'
        } else { Note $it 'done' }
    }
    $res
}
function Find-Leftovers($app, [bool]$Forced) {
    $script:LeftoverApp = $app; $script:LeftoverForced = $Forced
    Show-Toast "Looking for what $($app.Name) left behind..." '#A1A1A6'
    $others = @($script:AppsData | Where-Object { $_.Kind -eq 'desktop' -and $_.Id -ne $app.Id } | ForEach-Object { [pscustomobject]@{ InstallLocation = $_.InstallLocation; Icon = $_.Icon; Uninstall = $_.Uninstall } })
    Start-Background $LeftoverScan.ToString() @(@{ App = $app; Others = $others }) {
        param($out, $errs)
        $items = @($out | Where-Object { $_ })
        $app = $script:LeftoverApp
        if (-not $items) {
            if ($script:LeftoverForced) { Show-Toast "Nothing of $($app.Name) was found on this PC." '#A1A1A6' } else { Show-Toast "$($app.Name) is completely gone: no leftovers found." '#30D158' }
            return
        }
        Show-LeftoverSheet $app $items $script:LeftoverForced
    }
}
function Show-LeftoverSheet($app, $items, [bool]$Forced) {
    $kinds = @{ Folder = 'Folder'; Registry = 'Registry'; Shortcut = 'Shortcut'; Service = 'Service'; Task = 'Task'; Process = 'Running' }
    $rows = for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $size = if ($it.Size) { "  ·  $(Format-Size $it.Size)" } else { '' }
        if ($it.Risky) { $size += '  ·  very large, so not ticked: look inside before deleting' }
        "<Grid Margin='0,0,0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='78'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
        "<CheckBox x:Name='L_$i' IsChecked='$(-not $it.Risky)' VerticalAlignment='Center' Margin='0,0,10,0'/>" +
        "<Border Grid.Column='1' Background='#3A3A3C' CornerRadius='5' Padding='6,1,6,2' HorizontalAlignment='Left' VerticalAlignment='Center'><TextBlock Text='$($kinds[$it.Kind])' FontSize='11' Foreground='#D1D1D6'/></Border>" +
        "<TextBlock Grid.Column='2' Text='$(Esc "$($it.Label)$size")' FontSize='12' Foreground='#D1D1D6' VerticalAlignment='Center' TextTrimming='CharacterEllipsis' ToolTip='$(Esc $it.Label)'/></Grid>"
    }
    $title = if ($Forced) { "Force remove $($app.Name)" } else { "$($app.Name) left these behind" }
    $sub = if ($Forced) { "ZeroDelay found these parts of $($app.Name). Its own uninstaller is skipped. Untick anything you want to keep." }
           else { "The uninstaller is done, but these parts of $($app.Name) are still on your PC. Untick anything you want to keep." }
    $body = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <TextBlock Text='$(Esc $title)' FontSize='22' FontWeight='Bold' TextWrapping='Wrap'/>
  <TextBlock Text='$(Esc $sub)' Foreground='#A1A1A6' FontSize='13' Margin='0,6,0,6' TextWrapping='Wrap'/>
  <TextBlock Text='Registry keys are backed up to ZeroDelay&apos;s data folder first. Files that are in use are deleted when you restart.' Foreground='#98989D' FontSize='12' Margin='0,0,0,18' TextWrapping='Wrap'/>
  $($rows -join '')
  <StackPanel Orientation='Horizontal' HorizontalAlignment='Right' Margin='0,14,0,0'>
    <Button x:Name='Keep' Content='Keep everything' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
    <Button x:Name='Del' Content='Delete selected' Style='{DynamicResource Btn}' Background='#FF453A' Foreground='#FFFFFF'/>
  </StackPanel>
</StackPanel>
"@)
    $script:LeftoverSheet = @{ Items = $items; Body = $body; App = $app }
    $body.FindName('Keep').Add_Click({ Hide-Animated $ui.Wizard 200 })
    $body.FindName('Del').Add_Click({ Remove-Leftovers })
    $ui.WizardBody.Content = $body
    $ui.Wizard.Visibility = 'Visible'
    if ($script:Anim) { Start-Anim $ui.Wizard ([Windows.UIElement]::OpacityProperty) 0 1 220; Show-Animated $ui.WizardBody 24 380 60 }
}
function Remove-Leftovers {
    $sh = $script:LeftoverSheet
    $chosen = @(for ($i = 0; $i -lt $sh.Items.Count; $i++) { if ($sh.Body.FindName("L_$i").IsChecked) { $sh.Items[$i] } })
    if (-not $chosen) { Hide-Animated $ui.Wizard 200; return }
    $r = (Show-ZdDialog ("Delete $($chosen.Count) item$(if ($chosen.Count -ne 1) { 's' }) of $($sh.App.Name) for good?`n`nFolders and files cannot be brought back. Registry keys are backed up first.") ('Deep uninstall') ('YesNo') ('Warning'))
    if ($r -ne 'Yes') { return }
    Hide-Animated $ui.Wizard 200
    Show-Toast "Removing $($sh.App.Name)..." '#A1A1A6'
    $backup = Join-Path $DataDir 'uninstall-backups'
    New-Item -ItemType Directory -Force $backup | Out-Null
    $script:LeftoverName = $sh.App.Name
    Start-Background $LeftoverRemove.ToString() @(@{ Items = $chosen; BackupDir = $backup }) {
        param($out, $errs)
        $res = @($out | Where-Object { $_ })
        $done = @($res | Where-Object { $_.State -eq 'done' }).Count; $later = @($res | Where-Object { $_.State -eq 'restart' }).Count; $fail = @($res | Where-Object { $_.State -eq 'failed' }).Count
        Add-History "Deep uninstall: $($script:LeftoverName) ($done removed$(if ($later) { ", $later at restart" }))" 'apps' $null
        $msg = "$($script:LeftoverName): $done item$(if ($done -ne 1) { 's' }) removed."
        if ($later) { $msg += " $later will finish when you restart the PC." }
        if ($fail) { $msg += " $fail could not be removed." }
        Show-Toast $msg $(if ($fail) { '#FF9F0A' } else { '#30D158' })
        Start-AppScan
    }
}
$StoreForceScript = {
    param($a)
    $errs = @()
    try { Remove-AppxPackage -Package $a.Full -AllUsers -ErrorAction Stop } catch { try { Remove-AppxPackage -Package $a.Full -ErrorAction Stop } catch { $errs += $_.Exception.Message } }
    try { Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $a.Id } | Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction Stop | Out-Null } catch {}
    if ($a.Family) { Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA "Packages\$($a.Family)") -Recurse -Force -ErrorAction SilentlyContinue }
    $errs
}
function Invoke-ForceRemove($app) {
    if ($app.Kind -eq 'store') {
        $r = (Show-ZdDialog ("Force remove $($app.Name)?`n`nIt is removed for every account on this PC, its data folder is deleted, and Windows stops installing it for new accounts. You can still get it again from the Microsoft Store.") ('Force remove') ('YesNo') ('Warning'))
        if ($r -ne 'Yes') { return }
        $script:RemovingApp = $app.Name
        Show-Toast "Removing $($app.Name) for all accounts..." '#A1A1A6'
        Start-Background $StoreForceScript.ToString() @($app) {
            param($out, $errs)
            $name = $script:RemovingApp
            $fail = @($out | Where-Object { $_ }) + @($errs | ForEach-Object { "$_" })
            if ($fail) { Show-Toast "$name could not be removed: $($fail[0])" '#FF453A'; return }
            Add-History "Force removed app: $name" 'apps' $null
            Show-Toast "$name was removed for all accounts." '#30D158'
            Start-AppScan
        }
        return
    }
    $r = (Show-ZdDialog ("Force remove $($app.Name)?`n`nZeroDelay skips its own uninstaller, closes it, and then shows you every file, registry key, shortcut, service and task it found, so you can delete them.`n`nUse this when the normal Uninstall does not work.") ('Force remove') ('YesNo') ('Warning'))
    if ($r -ne 'Yes') { return }
    Find-Leftovers $app $true
}

# =============================================================== Clean up files
$CleanTargets = @(
    @{ Key = 'usertemp'; Title = 'Your temp folder'; Default = $true; Age = 2
       Desc = 'Leftovers from installers and apps. Files used in the last 2 hours are kept, and files in use are skipped.'
       Dirs = @($env:TEMP) }
    @{ Key = 'wintemp'; Title = 'Windows temp folder'; Default = $true; Age = 2
       Desc = 'The same for Windows itself and its services.'
       Dirs = @("$env:WINDIR\Temp") }
    @{ Key = 'wucache'; Title = 'Windows Update downloads'; Default = $true; Age = 0; Services = @('wuauserv', 'bits')
       Desc = 'Update files Windows has already installed. If an update is downloading right now, it simply starts again.'
       Dirs = @("$env:WINDIR\SoftwareDistribution\Download") }
    @{ Key = 'deliveryopt'; Title = 'Delivery Optimization cache'; Default = $true; Age = 0; Cmd = 'Delete-DeliveryOptimizationCache'
       Desc = 'Pieces of updates Windows keeps to share with other PCs.'
       Dirs = @("$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
    @{ Key = 'dumps'; Title = 'Crash dumps and error reports'; Default = $true; Age = 0
       Desc = 'Files Windows and apps write when something crashes. Only useful to developers.'
       Dirs = @("$env:WINDIR\Minidump", "$env:LOCALAPPDATA\CrashDumps", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue")
       Files = @("$env:WINDIR\MEMORY.DMP") }
    @{ Key = 'thumbs'; Title = 'Thumbnail cache'; Default = $false; Age = 0
       Desc = 'Small previews of your pictures and videos. Windows rebuilds them when you open those folders again.'
       Files = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db") }
    @{ Key = 'browsers'; Title = 'Browser and Discord caches'; Default = $false; Age = 0
       Desc = 'Saved copies of websites (Chrome, Edge, Brave, Opera GX, Firefox) and Discord. Pages load a bit slower the first time afterwards. Close them first for the biggest result. Logins and history are not touched.'
       Dirs = @(foreach ($b in "$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\Microsoft\Edge\User Data", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data") { foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { "$b\*\$c" } }) +
               @("$env:LOCALAPPDATA\Opera Software\Opera GX Stable\Cache", "$env:APPDATA\Opera Software\Opera GX Stable\Code Cache", "$env:APPDATA\Opera Software\Opera GX Stable\GPUCache",
                 "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2", "$env:APPDATA\discord\Cache", "$env:APPDATA\discord\Code Cache", "$env:APPDATA\discord\GPUCache") }
    @{ Key = 'recycle'; Title = 'Recycle Bin'; Default = $false; Recycle = $true
       Desc = 'Permanently deletes everything in the Recycle Bin. Look inside first if you are not sure.' }
)
# Adobe caches: added only on PCs with Adobe video apps; skipped while any of them is open
if (Test-Path "$env:APPDATA\Adobe\Common") {
    $mc = @("$env:APPDATA\Adobe\Common\Media Cache Files", "$env:APPDATA\Adobe\Common\Media Cache", "$env:APPDATA\Adobe\Common\Peak Files")
    foreach ($k in @(Get-Item 'HKCU:\Software\Adobe\Common *\Media Cache' -ErrorAction SilentlyContinue)) {
        $fp = "$((Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).FolderPath)".TrimEnd('\')
        if ($fp -and $fp -notlike "$env:APPDATA\Adobe\Common*") { $mc += "$fp\Media Cache Files", "$fp\Media Cache", "$fp\Peak Files" }
    }
    $CleanTargets += @{ Key = 'adobecache'; Title = 'Adobe media cache'; Default = $false; Age = 0; Block = $AdobeVideoProcs
        Desc = 'Audio conform and preview files for Premiere, After Effects and Media Encoder. They are rebuilt when you open a project (the first playback is slower). Skipped while an Adobe video app is open.'
        Dirs = @($mc | Select-Object -Unique) }
}
$aeFile = Get-AePrefsFile
if ($aeFile) {
    $folder = "$(Get-AeValue ([IO.File]::ReadAllText($aeFile)) 'Disk Cache Controls' 'Folder 7')".Trim().Trim('"') -replace '\\\\', '\'
    # only a folder that is clearly a cache, never a drive root or a personal folder
    if ($folder -and $folder -match '(?i)cache' -and $folder.Length -gt 6 -and (Test-Path -LiteralPath $folder)) {
        $CleanTargets += @{ Key = 'aecache'; Title = 'After Effects disk cache'; Default = $false; Age = 0; Block = @('AfterFX', 'aerender')
            Desc = "Rendered preview frames in $folder. After Effects re-renders them when needed. Skipped while After Effects is open."
            Dirs = @($folder) }
    }
}

# Scans (Clean = false) or deletes (Clean = true) the chosen targets; returns one result per target.
$CleanWorker = {
    param($job)
    $now = Get-Date
    foreach ($t in $job.Targets) {
        if ($job.Keys -notcontains $t.Key) { continue }
        $bytes = [long]0; $files = 0; $skipped = 0
        if ($job.Clean -and $t.Block -and (Get-Process -Name $t.Block -ErrorAction SilentlyContinue)) { [pscustomobject]@{ Key = $t.Key; Bytes = 0; Files = 0; Skipped = 1 }; continue }
        if ($t.Recycle) {
            try { $sh = New-Object -ComObject Shell.Application; foreach ($it in @($sh.Namespace(10).Items())) { $bytes += [long]$it.ExtendedProperty('Size'); $files++ } } catch {}
            if ($job.Clean -and $files) { try { Clear-RecycleBin -Force -ErrorAction Stop } catch { $skipped = $files; $bytes = 0; $files = 0 } }
            [pscustomobject]@{ Key = $t.Key; Bytes = $bytes; Files = $files; Skipped = $skipped }
            continue
        }
        $wasRunning = @()
        if ($job.Clean -and $t.Services) {
            foreach ($sv in $t.Services) { $o = Get-Service $sv -ErrorAction SilentlyContinue; if ($o -and $o.Status -eq 'Running') { $wasRunning += $sv; Stop-Service $sv -Force -ErrorAction SilentlyContinue } }
        }
        $roots = @(foreach ($d in @($t.Dirs)) { if ($d) { Get-Item -Path $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } } })
        $items = @(foreach ($r in $roots) { Get-ChildItem -LiteralPath $r.FullName -Recurse -File -Force -ErrorAction SilentlyContinue })
        $items += @(foreach ($f in @($t.Files)) { if ($f) { Get-Item -Path $f -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } } })
        $cut = $now.AddHours(-[double]$t.Age)
        foreach ($it in $items) {
            if ($t.Age -and $it.LastWriteTime -gt $cut) { continue }
            if (-not $job.Clean) { $bytes += $it.Length; $files++; continue }
            try { Remove-Item -LiteralPath $it.FullName -Force -ErrorAction Stop; $bytes += $it.Length; $files++ } catch { $skipped++ }
        }
        if ($job.Clean) {
            # empty folders left behind (deepest first); the top folders themselves stay
            foreach ($r in $roots) {
                Get-ChildItem -LiteralPath $r.FullName -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
                    ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } }
            }
            if ($t.Cmd -and (Get-Command $t.Cmd -ErrorAction SilentlyContinue)) { try { & $t.Cmd -Force -ErrorAction Stop } catch {} }
            foreach ($sv in $wasRunning) { Start-Service $sv -ErrorAction SilentlyContinue }
        }
        [pscustomobject]@{ Key = $t.Key; Bytes = $bytes; Files = $files; Skipped = $skipped }
    }
}
function New-CleanPage {
    $rows = ($CleanTargets | ForEach-Object {
        "<Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='10' Padding='16,12' Margin='0,0,0,6'><Grid>" +
        "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<CheckBox x:Name='C_$($_.Key)' VerticalAlignment='Center' Margin='0,0,14,0'/>" +
        "<StackPanel Grid.Column='1'><TextBlock Text='$(Esc $_.Title)' FontSize='13.5' FontWeight='SemiBold'/><TextBlock Text='$(Esc $_.Desc)' FontSize='12' Foreground='#98989D' Margin='0,2,0,0' TextWrapping='Wrap'/></StackPanel>" +
        "<TextBlock x:Name='S_$($_.Key)' Grid.Column='2' Text='...' FontSize='13' FontWeight='SemiBold' Foreground='#A1A1A6' VerticalAlignment='Center' Margin='16,0,0,0' MinWidth='70' TextAlignment='Right'/></Grid></Border>"
    }) -join ''
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,18' Margin='0,0,0,14'>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock x:Name='Total' Text='Scanning...' FontSize='26' FontWeight='Bold'/>
        <TextBlock x:Name='Status' FontSize='12.5' Foreground='#A1A1A6' Margin='0,4,0,0' TextWrapping='Wrap'/>
      </StackPanel>
      <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'>
        <Button x:Name='Rescan' Content='Scan again' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
        <Button x:Name='Go' Content='Clean selected' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' IsEnabled='False'/>
      </StackPanel>
    </Grid>
  </Border>
  $rows
  <TextBlock Text='Shader caches are left alone on purpose: Fortnite would rebuild them and stutter for your next few matches. If you ever need to, use Clear shader cache on the Potato graphics page.' FontSize='12' Foreground='#98989D' Margin='4,10,0,0' TextWrapping='Wrap'/>
</StackPanel>
"@)
    $cu = @{ Total = $root.FindName('Total'); Status = $root.FindName('Status'); Rescan = $root.FindName('Rescan'); Go = $root.FindName('Go'); Check = @{}; Size = @{} }
    foreach ($t in $CleanTargets) {
        $cb = $root.FindName("C_$($t.Key)"); $cb.IsChecked = $t.Default; $cb.Add_Click({ Update-CleanTotal })
        $cu.Check[$t.Key] = $cb; $cu.Size[$t.Key] = $root.FindName("S_$($t.Key)")
    }
    $script:CleanUi = $cu
    $cu.Rescan.Add_Click({ Start-CleanScan })
    $cu.Go.Add_Click({ Start-Clean })
    Start-CleanScan
    New-PageScroll $root
}
function Start-CleanScan {
    $cu = $script:CleanUi
    $cu.Total.Text = 'Scanning...'; $cu.Status.Text = 'Adding up what can be deleted. Nothing is deleted yet.'
    $cu.Go.IsEnabled = $false; $cu.Rescan.IsEnabled = $false
    foreach ($k in $cu.Size.Keys) { $cu.Size[$k].Text = '...' }
    $script:CleanSizes = @{}
    Start-Background $CleanWorker.ToString() @(@{ Targets = $CleanTargets; Keys = @($CleanTargets | ForEach-Object { $_.Key }); Clean = $false }) {
        param($out, $errs)
        $cu = $script:CleanUi
        foreach ($r in @($out | Where-Object { $_ })) { $script:CleanSizes[$r.Key] = $r; $cu.Size[$r.Key].Text = Format-Size $r.Bytes }
        $cu.Rescan.IsEnabled = $true
        Update-CleanTotal
    }
}
function Update-CleanTotal {
    $cu = $script:CleanUi
    if (-not $script:CleanSizes) { return }
    $sum = [long]0; $n = 0
    foreach ($k in $cu.Check.Keys) { if ($cu.Check[$k].IsChecked -and $script:CleanSizes[$k]) { $sum += $script:CleanSizes[$k].Bytes; $n++ } }
    $cu.Total.Text = "$(Format-Size $sum) can be freed"
    $cu.Status.Text = if ($n) { "From the $n ticked group$(if ($n -ne 1) { 's' }). Tick or untick groups below, then press Clean selected." } else { 'Tick the groups you want to clean.' }
    $cu.Go.IsEnabled = $sum -gt 0
    $script:CleanPlanned = $sum
}
function Start-Clean {
    $cu = $script:CleanUi
    $keys = @($cu.Check.Keys | Where-Object { $cu.Check[$_].IsChecked })
    if (-not $keys) { return }
    $extra = if ($keys -contains 'recycle') { "`n`nThis also empties the Recycle Bin." } else { '' }
    $r = (Show-ZdDialog ("Delete $(Format-Size $script:CleanPlanned) of files now?`n`nDeleted files cannot be brought back. Files that are in use are skipped.$extra") ('Clean up files') ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    $cu.Go.IsEnabled = $false; $cu.Rescan.IsEnabled = $false
    $cu.Total.Text = 'Cleaning...'; $cu.Status.Text = 'This can take a minute for big caches.'
    Start-Background $CleanWorker.ToString() @(@{ Targets = $CleanTargets; Keys = $keys; Clean = $true }) {
        param($out, $errs)
        $res = @($out | Where-Object { $_ })
        $freed = ($res | Measure-Object Bytes -Sum).Sum; $skip = ($res | Measure-Object Skipped -Sum).Sum
        Add-History "Cleaned up $(Format-Size $freed) of files" 'clean' $null
        Show-Toast ("Freed $(Format-Size $freed)." + $(if ($skip) { " $skip files were in use and were skipped." } else { '' })) '#30D158'
        Start-CleanScan
    }
}

# =============================================================== Memory (RAM)
# Apps that Windows itself, your drivers, security or the game need: no Close button for these.
$MemNoClose = @('System', 'Registry', 'Memory Compression', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'dwm', 'explorer', 'fontdrvhost',
    'MsMpEng', 'NisSrv', 'SecurityHealthService', 'audiodg', 'spoolsv', 'sihost', 'ctfmon', 'RuntimeBroker', 'SearchHost', 'StartMenuExperienceHost', 'ShellExperienceHost',
    'TextInputHost', 'Idle', 'WmiPrvSE', 'powershell', 'NVDisplay.Container', 'nvcontainer', 'FortniteClient-Win64-Shipping', 'EasyAntiCheat_EOS', 'EasyAntiCheat', 'MsSense',
    'LsaIso', 'vmmem', 'vmcompute', 'dllhost', 'conhost', 'taskhostw', 'SgrmBroker', 'WUDFHost', 'atiesrxx', 'atieclxx', 'amdfendrsr')
function Get-MemInfo {
    $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue
    if (-not $m -or -not $m.AvailableBytes) {
        # performance counters switched off (some optimizers do that): ask Windows directly; the system cache is
        # close to the standby list, and whatever is available beyond it is free
        $ph = [MemTools]::Physical()
        if (-not $ph) { return [pscustomobject]@{ Total = 0 } }
        $standby = [Math]::Min($ph[2], $ph[1])
        return [pscustomobject]@{ Total = $ph[0]; Available = $ph[1]; InUse = $ph[0] - $ph[1]; Standby = $standby; Free = $ph[1] - $standby; Modified = 0 }
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $total = [long]$os.TotalVisibleMemorySize * 1KB
    $standby = [long]$m.StandbyCacheCoreBytes + [long]$m.StandbyCacheNormalPriorityBytes + [long]$m.StandbyCacheReserveBytes
    [pscustomobject]@{ Total = $total; Available = [long]$m.AvailableBytes; InUse = $total - [long]$m.AvailableBytes; Standby = $standby
                       Free = [long]$m.FreeAndZeroPageListBytes; Modified = [long]$m.ModifiedPageListBytes }
}
function New-MemoryPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,14'>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text='In use' Foreground='#A1A1A6' FontSize='12'/>
          <TextBlock x:Name='Used' FontSize='30' FontWeight='Bold'/>
        </StackPanel>
        <Button x:Name='Purge' Grid.Column='1' Content='Free standby memory' Style='{DynamicResource Btn}' VerticalAlignment='Top'
                ToolTip='Clears the standby list once (what ISLC and Mem Reduct do). Your apps keep all their memory.'/>
      </Grid>
      <Grid Height='10' Margin='0,12,0,0'>
        <Border CornerRadius='5' Background='#3A3A3C'/>
        <StackPanel Orientation='Horizontal'>
          <Border x:Name='BarUse' Height='10' CornerRadius='5,0,0,5' Background='#0A84FF' Width='0'/>
          <Border x:Name='BarStandby' Height='10' Background='#636366' Width='0'/>
        </StackPanel>
      </Grid>
      <TextBlock x:Name='Parts' FontSize='12' Foreground='#A1A1A6' Margin='0,8,0,0'/>
      <TextBlock x:Name='Verdict' FontSize='13' FontWeight='SemiBold' Margin='0,12,0,0' TextWrapping='Wrap'/>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,18' Margin='0,0,0,14'>
    <StackPanel>
      <TextBlock Text='Apps using the most memory' FontSize='14' FontWeight='SemiBold'/>
      <TextBlock Text='Closing apps you are not using is the only thing that really frees RAM. Save your work in them first.' FontSize='12' Foreground='#98989D' Margin='0,3,0,10' TextWrapping='Wrap'/>
      <ContentControl x:Name='Top'/>
    </StackPanel>
  </Border>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,18'>
    <StackPanel>
      <TextBlock Text='Why there is no RAM cleaner' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,8'/>
      <TextBlock Foreground='#A1A1A6' FontSize='12.5' TextWrapping='Wrap' LineHeight='20' LineStackingStrategy='BlockLineHeight'
        Text='&#x2022;  Standby memory is a cache of files you used recently. It already counts as available: Windows hands it to Fortnite instantly, so a big standby number is normal and good.&#x0a;&#x2022;  Most RAM cleaners force every app to give its memory back. Windows then has to read it all back from the disk, which causes the very stutter they promise to fix. ZeroDelay does not do that.&#x0a;&#x2022;  Free standby memory clears the cache once. It only helps on the rare PCs where a full standby list causes stutter (what ISLC fixes); on most PCs nothing changes.'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $mu = @{}; foreach ($n in 'Used', 'Purge', 'BarUse', 'BarStandby', 'Parts', 'Verdict', 'Top') { $mu[$n] = $root.FindName($n) }
    $script:MemUi = $mu
    $mu.Purge.Add_Click({ Invoke-StandbyPurge })
    $mu.Used.Text = 'Reading memory...'
    Update-MemoryPage
    # refresh every 4 s while this page is on screen
    $script:MemTimer = New-Object Windows.Threading.DispatcherTimer
    $script:MemTimer.Interval = [TimeSpan]::FromSeconds(4)
    $script:MemTimer.Add_Tick({ if ($script:CurrentCat.Name -eq 'Memory' -and $window.IsVisible -and $window.WindowState -ne 'Minimized') { Update-MemoryPage } })
    $script:MemTimer.Start()
    New-PageScroll $root
}
function Get-MemoryPageData {
    $groups = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum; Procs = $_.Group }
    } | Sort-Object Bytes -Descending | Select-Object -First 10
    $top = foreach ($g in $groups) {
        $label = $g.Name
        try { $d = $g.Procs[0].MainModule.FileVersionInfo.FileDescription; if ($d) { $label = $d } } catch {}
        [pscustomobject]@{ Name = $g.Name; Count = $g.Count; Bytes = $g.Bytes; Label = $label }
    }
    @{ Mi = (Get-MemInfo); Top = @($top) }
}
function Update-MemoryPage {
    if ($script:MemBusy) { return }
    $script:MemBusy = $true
    Invoke-Worker 'Get-MemoryPageData' @() { param($out, $errs) $script:MemBusy = $false; $d = Get-WorkerResult $out; if ($d -is [hashtable]) { Show-MemoryPage $d } }
}
function Show-MemoryPage($d) {
    $mu = $script:MemUi
    $mi = $d.Mi
    if (-not $mi.Total) { return }
    $mu.Used.Text = "$(Format-Size $mi.InUse) of $(Format-Size $mi.Total)"
    $w = [Math]::Max(0, $mu.BarUse.Parent.ActualWidth); if (-not $w) { $w = 700 }
    $mu.BarUse.Width = $w * $mi.InUse / $mi.Total
    $mu.BarStandby.Width = [Math]::Max(0, [Math]::Min($w - $mu.BarUse.Width, $w * $mi.Standby / $mi.Total))
    $mu.Parts.Text = "Available $(Format-Size $mi.Available)   ·   of that, standby cache $(Format-Size $mi.Standby) and completely free $(Format-Size $mi.Free)"
    $availGb = $mi.Available / 1GB
    $v = if ($availGb -ge 6) { @("Plenty of memory available for Fortnite ($('{0:N1}' -f $availGb) GB). Nothing to do.", '#30D158') }
         elseif ($availGb -ge 3) { @("Fortnite runs best with 6 GB or more available; you have $('{0:N1}' -f $availGb) GB. Close the apps below that you are not using.", '#FF9F0A') }
         else { @("Only $('{0:N1}' -f $availGb) GB available. Fortnite will stutter while Windows swaps to the disk: close the biggest apps below.", '#FF453A') }
    if ($mi.Total -lt 15GB) { $v[0] += ' With less than 16 GB in the PC, adding RAM is the biggest upgrade for Fortnite.' }
    $mu.Verdict.Text = $v[0]; $mu.Verdict.Foreground = ConvertTo-Brush $v[1]
    $groups = @($d.Top)
    $max = [double]($groups | Select-Object -First 1).Bytes
    $rows = for ($i = 0; $i -lt @($groups).Count; $i++) {
        $g = $groups[$i]
        $label = $g.Label
        $canClose = $MemNoClose -notcontains $g.Name
        "<Grid Margin='0,0,0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='160'/><ColumnDefinition Width='80'/><ColumnDefinition Width='86'/></Grid.ColumnDefinitions>" +
        "<TextBlock Text='$(Esc "$label$(if ($g.Count -gt 1) { " ($($g.Count))" })")' FontSize='13' VerticalAlignment='Center' TextTrimming='CharacterEllipsis'/>" +
        "<Border Grid.Column='1' Height='6' CornerRadius='3' Background='#3A3A3C' VerticalAlignment='Center'><Border Height='6' CornerRadius='3' Background='#0A84FF' HorizontalAlignment='Left' Width='$([int](160 * $g.Bytes / [Math]::Max([double]1, $max)))'/></Border>" +
        "<TextBlock Grid.Column='2' Text='$(Format-Size $g.Bytes)' FontSize='12.5' Foreground='#D1D1D6' VerticalAlignment='Center' TextAlignment='Right'/>" +
        $(if ($canClose) { "<Button x:Name='K_$i' Grid.Column='3' Content='Close' Style='{DynamicResource Btn}' Padding='12,4' FontSize='12' HorizontalAlignment='Right'/>" } else { "<TextBlock Grid.Column='3' Text='Windows' FontSize='11.5' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center' ToolTip='Part of Windows, your drivers or the game: not closed from here.'/>" }) +
        "</Grid>"
    }
    $panel = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$($rows -join '')</StackPanel>")
    for ($i = 0; $i -lt @($groups).Count; $i++) {
        $b = $panel.FindName("K_$i")
        if ($b) { $b.Tag = $groups[$i].Name; $b.Add_Click({ param($s, $e) Close-AppGroup $s.Tag }) }
    }
    $mu.Top.Content = $panel
}
function Close-AppGroup([string]$Name) {
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if (-not $procs) { return }
    $r = (Show-ZdDialog ("Close $Name ($($procs.Count) process$(if ($procs.Count -ne 1) { 'es' }))?`n`nZeroDelay asks it to close first and ends it if it does not. Unsaved work in it may be lost.") ('Close app') ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    foreach ($p in $procs) { try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch {} }
    # anything still running after 3 s (tray apps have no window to close) is ended
    $script:CloseName = $Name
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(3)
    $t.Add_Tick({ param($s, $e)
        $s.Stop()
        Get-Process -Name $script:CloseName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Show-Toast "$script:CloseName was closed." '#30D158'
        if ($script:MemUi) { Update-MemoryPage }
    })
    $t.Start()
}
function Invoke-StandbyPurge {
    $before = Get-MemInfo
    $rc = [MemTools]::PurgeStandby()
    if ($rc -eq -1) { Show-Toast 'Windows did not give ZeroDelay permission to clear standby memory.' '#FF9F0A'; return }
    if ($rc -ne 0) { Show-Toast ('Windows refused to clear standby memory (error 0x{0:X8}).' -f $rc) '#FF9F0A'; return }
    $after = Get-MemInfo
    Show-Toast "Cleared $(Format-Size ([Math]::Max(0, $before.Standby - $after.Standby))) of standby cache. Your apps kept all their memory." '#30D158'
    Update-MemoryPage
}

# =============================================================== System profile (This PC)
# One background scan of the hardware, Windows and installed apps. Saved to system-profile.json and used to decide which
# tweaks fit this PC. Runs on first start (right after install) and again every few days or after an update.
$ProfileFile = Join-Path $DataDir 'system-profile.json'
$ProfileScan = {
    param($appVersion)
    function Try-Get([scriptblock]$sb) { try { & $sb } catch { $null } }
    $P = [ordered]@{ Version = 1; AppVersion = $appVersion; ScannedAt = (Get-Date).ToString('o') }
    # --- Windows and the machine
    $os = Try-Get { Get-CimInstance Win32_OperatingSystem }
    $cv = Try-Get { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
    $P.Windows = [ordered]@{ Name = "$($os.Caption)".Trim(); Version = "$($cv.DisplayVersion)"; Build = "$($os.BuildNumber).$($cv.UBR)"
                             Installed = $(if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') }) }
    $cs = Try-Get { Get-CimInstance Win32_ComputerSystem }
    $bb = Try-Get { Get-CimInstance Win32_BaseBoard }
    $bios = Try-Get { Get-CimInstance Win32_BIOS }
    $enc = Try-Get { Get-CimInstance Win32_SystemEnclosure }
    $bat = @(Try-Get { Get-CimInstance Win32_Battery })
    $laptop = ($bat.Count -gt 0) -or (@($enc.ChassisTypes) | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }).Count -gt 0
    $P.Computer = [ordered]@{ Maker = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); Board = "$($bb.Manufacturer) $($bb.Product)".Trim()
                              Bios = "$($bios.SMBIOSBIOSVersion)".Trim(); BiosDate = $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') }); Laptop = [bool]$laptop }
    # --- CPU
    $cpu = Try-Get { Get-CimInstance Win32_Processor | Select-Object -First 1 }
    $cn = "$($cpu.Name)".Trim() -replace '\s+', ' '
    $P.Cpu = [ordered]@{ Name = $cn; Vendor = $(switch ($cpu.Manufacturer) { 'AuthenticAMD' { 'AMD' } 'GenuineIntel' { 'Intel' } default { "$($cpu.Manufacturer)" } })
                         Cores = [int]$cpu.NumberOfCores; Threads = [int]$cpu.NumberOfLogicalProcessors; MaxMHz = [int]$cpu.MaxClockSpeed
                         Hybrid = [bool]($cn -match 'i[3579]-1[2-4]\d{3}|Core\(TM\) Ultra|Core Ultra|i[3579]-2\d{2}[A-Z]'); X3D = [bool]($cn -match 'X3D'); DualDieX3D = [bool]($cn -match '79[05]0X3D|99[05]0X3D') }
    # --- graphics (nvidia-smi gives exact memory and driver for NVIDIA cards; Windows caps memory at 4 GB in this list)
    $nv = @{}
    $smi = "$env:WINDIR\System32\nvidia-smi.exe"
    if (Test-Path $smi) { Try-Get { & $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null | ForEach-Object { $x = $_ -split ',\s*'; if ($x.Count -ge 3) { $nv[$x[0].Trim()] = @{ Mb = [int]$x[1]; Drv = $x[2].Trim() } } } } }
    if ($env:ZD_FAKE_GPU) { $nv[$env:ZD_FAKE_GPU] = @{ Mb = 11264; Drv = '580.97' } }
    $gl = @(Try-Get { Get-CimInstance Win32_VideoController })
    if ($env:ZD_FAKE_GPU) { $gl = @([pscustomobject]@{ Name = $env:ZD_FAKE_GPU; PNPDeviceID = 'PCI\VEN_10DE&DEV_1B06'; AdapterRAM = 0; DriverVersion = '32.0.15.8097'; DriverDate = (Get-Date '2025-10-01') }) + @($gl | Where-Object { $_.PNPDeviceID -notmatch 'VEN_10DE' }) }
    $P.Gpus = @(foreach ($g in $gl) {
        $id = "$($g.PNPDeviceID)"; $name = "$($g.Name)".Trim()
        $vendor = if ($id -match 'VEN_10DE') { 'NVIDIA' } elseif ($id -match 'VEN_1002') { 'AMD' } elseif ($id -match 'VEN_8086') { 'Intel' } else { 'Other' }
        if ($vendor -eq 'Other') { continue }
        $arch = switch -Regex ($name) {
            'RTX 50\d\d' { 'Blackwell'; break }  'RTX 40\d\d' { 'Ada Lovelace'; break }  'RTX 30\d\d' { 'Ampere'; break }  'RTX 20\d\d|GTX 16\d\d|TITAN RTX' { 'Turing'; break }
            'GTX 10\d\d|TITAN Xp|TITAN X \(Pascal\)|GT 10\d\d' { 'Pascal'; break }  'GTX 9\d\d|GTX 750' { 'Maxwell'; break }
            'RX 9\d\d\d' { 'RDNA 4'; break }  'RX 7\d\d\d' { 'RDNA 3'; break }  'RX 6\d\d\d' { 'RDNA 2'; break }  'RX 5\d\d\d' { 'RDNA'; break }  'RX (4|5)\d\d\b|Vega' { 'GCN'; break }
            'Arc\(TM\) (A|B)\d|Arc (A|B)\d' { 'Intel Arc'; break }  default { '' } }
        $integrated = ($vendor -eq 'Intel' -and $arch -ne 'Intel Arc') -or ($vendor -eq 'AMD' -and $name -match 'Radeon\(TM\) Graphics|Radeon Graphics$|Vega \d+ Graphics|Radeon\(TM\) \d+M')
        [ordered]@{ Name = $name; Vendor = $vendor; Arch = $arch; Integrated = [bool]$integrated
                    VramMb = $(if ($nv[$name]) { $nv[$name].Mb } elseif ($g.AdapterRAM -gt 0) { [int]($g.AdapterRAM / 1MB) } else { $null })
                    Driver = $(if ($nv[$name]) { $nv[$name].Drv } else { "$($g.DriverVersion)" }); DriverDate = $(if ($g.DriverDate) { ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') }) }
    })
    # --- memory
    $m = @(Try-Get { Get-CimInstance Win32_PhysicalMemory } | Where-Object { $_.Capacity -gt 0 })
    $P.Memory = [ordered]@{ TotalGb = [int](($m | Measure-Object Capacity -Sum).Sum / 1GB); Sticks = $m.Count
                            SpeedMts = [int](($m | Measure-Object ConfiguredClockSpeed -Minimum).Minimum); RatedMts = [int](($m | Measure-Object Speed -Maximum).Maximum)
                            Type = $(switch ([int]($m | Select-Object -First 1).SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } 30 { 'LPDDR4' } 35 { 'LPDDR5' } default { '' } }) }
    # --- drives, and where Windows and Fortnite live
    $disks = @(Try-Get { Get-PhysicalDisk })
    $P.Drives = @(foreach ($d in $disks) { [ordered]@{ Name = "$($d.FriendlyName)".Trim(); Type = "$($d.MediaType)"; Bus = "$($d.BusType)"; SizeGb = [int]($d.Size / 1GB); Number = "$($d.DeviceId)" } })
    function Get-DriveOf([string]$path) { try { $n = (Get-Partition -DriveLetter ((Split-Path -Qualifier $path).TrimEnd(':')) -ErrorAction Stop).DiskNumber; ($P.Drives | Where-Object { $_.Number -eq "$n" } | Select-Object -First 1).Name } catch { $null } }
    $fn = $null
    try { $dat = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"; if (Test-Path $dat) { $fn = ((Get-Content $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object { $_.AppName -eq 'Fortnite' } | Select-Object -First 1).InstallLocation } } catch {}
    $P.Fortnite = [ordered]@{ Path = $fn; Drive = $(if ($fn) { Get-DriveOf $fn }) }
    $P.SystemDrive = Get-DriveOf $env:SystemDrive
    # --- monitors (name, refresh rate, cable)
    $ids = @(Try-Get { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID })
    $conn = @(Try-Get { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams })
    $P.Displays = @(foreach ($x in @(Try-Get { [NativeDisplay]::ListDisplays() })) {
        if ($x -match 'Virtual|Parsec|Remote Display|Meta ') { continue }
        $f = $x -split '\|'
        $cable = ''
        $mid = $ids | Where-Object { $n = -join (@($_.UserFriendlyName) | Where-Object { $_ } | ForEach-Object { [char]$_ }); $n -and $f[0] -like "*$($n.Trim())*" } | Select-Object -First 1
        if ($mid) { $c = $conn | Where-Object { $_.InstanceName -eq $mid.InstanceName } | Select-Object -First 1
            $cable = switch ([int]$c.VideoOutputTechnology) { 5 { 'HDMI' } 10 { 'DisplayPort' } 11 { 'Built-in' } 6 { 'Built-in' } 4 { 'DVI' } 18 { 'USB-C' } default { '' } } }
        [ordered]@{ Name = $f[0]; Gpu = $f[1]; Hz = [int]$f[2]; Primary = ($f[3] -eq 'True'); Cable = $cable }
    })
    $P.Monitors = @(foreach ($mi in $ids) {
        $n = (-join (@($mi.UserFriendlyName) | Where-Object { $_ } | ForEach-Object { [char]$_ })).Trim()
        $c = $conn | Where-Object { $_.InstanceName -eq $mi.InstanceName } | Select-Object -First 1
        [ordered]@{ Name = $(if ($n) { $n } else { 'Monitor' }); Cable = $(switch ([int]$c.VideoOutputTechnology) { 5 { 'HDMI' } 10 { 'DisplayPort' } 11 { 'Built-in' } 6 { 'Built-in' } 4 { 'DVI' } 18 { 'USB-C' } default { '' } }) }
    })
    # --- network
    $P.Network = @(foreach ($a in @(Try-Get { Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up' })) {
        [ordered]@{ Name = "$($a.InterfaceDescription)"; Kind = $(if ("$($a.PhysicalMediaType)" -match '802\.11|Wireless' -or $a.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11') { 'Wi-Fi' } else { 'Ethernet' }); Speed = "$($a.LinkSpeed)" } })
    # --- audio and input devices
    $P.Audio = @(Try-Get { [AudioFx]::List() | ForEach-Object { $_.Name } })
    $P.Input = @(foreach ($h in @(Try-Get { Get-PnpDevice -PresentOnly -Class Mouse, Keyboard -ErrorAction Stop | Where-Object { $_.InstanceId -like 'HID\VID_*' } })) {
        $name = $null; $id = $h.InstanceId
        for ($hop = 0; $hop -lt 3 -and -not $name; $hop++) {
            $parent = Try-Get { (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data }
            if (-not $parent) { break }
            $desc = Try-Get { (Get-PnpDeviceProperty -InstanceId $parent -KeyName DEVPKEY_Device_BusReportedDeviceDesc -ErrorAction Stop).Data }
            if ($desc -and $desc -notmatch '^(USB Input Device|USB Composite Device|HID-compliant)') { $name = "$desc".Trim() }
            $id = $parent
        }
        if ($name) { [ordered]@{ Kind = "$($h.Class)"; Name = $name } }
    }) | Group-Object { $_.Name } | ForEach-Object { $g = $_.Group; $mouse = $g | Where-Object { $_.Kind -eq 'Mouse' } | Select-Object -First 1; if ($mouse) { $mouse } else { $g[0] } }
    # --- security and power
    $dg = Try-Get { Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard }
    $P.Security = [ordered]@{ Vbs = ([int]$dg.VirtualizationBasedSecurityStatus -eq 2); MemoryIntegrity = (@($dg.SecurityServicesRunning) -contains 2); Hypervisor = [bool]$cs.HypervisorPresent
                              Antivirus = @(Try-Get { Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop } | ForEach-Object { $_.displayName } | Select-Object -Unique) }
    $plan = (Try-Get { powercfg /getactivescheme }) -replace '^.*\((.*)\)\s*$', '$1'
    $P.Power = [ordered]@{ Plan = "$plan".Trim(); OnBattery = (@($bat | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0) }
    # --- installed apps
    $seen = @{}
    $progs = foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $q = Try-Get { Get-ItemProperty $k.PSPath }
            if (-not $q.DisplayName -or $q.SystemComponent -eq 1 -or $q.ParentKeyName -or "$($q.ReleaseType)" -match 'Update|Hotfix') { continue }
            $n = "$($q.DisplayName)".Trim() -replace '[\x00-\x1F]', ''
            if ($seen.ContainsKey($n)) { continue }; $seen[$n] = 1
            $n
        }
    }
    $progs = @($progs | Sort-Object)
    $store = @(Try-Get { Get-AppxPackage -PackageTypeFilter Main -ErrorAction Stop } | Where-Object { -not $_.IsFramework -and "$($_.SignatureKind)" -ne 'System' })
    $P.Apps = [ordered]@{ Programs = $progs; StoreCount = $store.Count; Store = @($store | ForEach-Object { $_.Name } | Sort-Object) }
    # --- what the installed software means for tuning
    $groups = [ordered]@{
        'Game launchers'          = 'Epic Games Launcher|^Steam$|Battle\.net|^EA app|Ubisoft Connect|GOG GALAXY|Riot (Client|Vanguard)|^Xbox'
        'Overlays and recording'  = 'Discord|^Medal|Overwolf|OBS Studio|Streamlabs|NVIDIA App|GeForce Experience|AMD Software|Outplayed|ShareX|Insights Capture'
        'RGB and device software' = 'Armoury Crate|AURA|iCUE|Synapse|G HUB|Logitech Gaming Software|SteelSeries GG|NZXT CAM|SignalRGB|OpenRGB|MSI Center|Mystic Light|RGB Fusion|Gigabyte Control Center|L-Connect|Wootility|NGENUITY|Glorious Core|Stream ?Deck|Stream ?Dock|Elgato'
        'Monitoring and tuning'   = 'HWiNFO|HWMonitor|AIDA64|Core Temp|MSI Afterburner|RivaTuner|CPU-Z|GPU-Z|Ryzen Master|Extreme Tuning|Precision X1|ThrottleStop|LatencyMon'
        'Other optimizers'        = 'ExitLag|^EXM|GearUP|Razer Cortex|WTFast|NoPing|^Hone|Process Lasso|CCleaner|Advanced SystemCare|Game Booster'
        'PC maker software'       = 'MyASUS|Dell SupportAssist|Dell Optimizer|Alienware Command|HP Support Assistant|OMEN Gaming Hub|Lenovo Vantage|Legion|Acer Care|PredatorSense|Driver & Support Assistant|Killer'
        'Cloud and sync'          = 'OneDrive|Dropbox|Google Drive|iCloud|^MEGA|pCloud'
        'Streaming and voice'     = 'OBS Studio|Streamlabs|XSplit|Spotify|TeamSpeak|Mumble|VoiceMeeter|Wave Link'
        'Antivirus'               = 'Norton|McAfee|Avast|^AVG|Bitdefender|Kaspersky|ESET|Malwarebytes|Avira|Sophos|Webroot|Trend Micro'
    }
    $P.Software = [ordered]@{}
    foreach ($k in $groups.Keys) { $hit = @($progs | Where-Object { $_ -match $groups[$k] }); if ($hit.Count) { $P.Software[$k] = $hit } }
    $P
}
function Get-SavedProfile { if (Test-Path $ProfileFile) { try { Get-Content $ProfileFile -Raw | ConvertFrom-Json } catch { $null } } else { $null } }
function Get-MainGpu($p) { $g = @($p.Gpus | Where-Object { -not $_.Integrated }); if ($g) { $g[0] } else { @($p.Gpus)[0] } }
function Start-ProfileScan([switch]$Quiet) {
    if ($script:ProfileScanning) { return }
    $script:ProfileScanning = $true; $script:ProfileQuiet = [bool]$Quiet
    if ($script:PcUi) { $script:PcUi.Status.Text = 'Scanning this PC: hardware, drivers, Windows and installed apps...'; $script:PcUi.Rescan.IsEnabled = $false }
    Start-Background $ProfileScan.ToString() @($AppVersion) {
        param($out, $errs)
        $script:ProfileScanning = $false
        $p = @($out | Where-Object { $_ }) | Select-Object -First 1
        if (-not $p) { if ($script:PcUi) { $script:PcUi.Status.Text = 'The scan did not finish. Try again.'; $script:PcUi.Rescan.IsEnabled = $true }; return }
        $p | ConvertTo-Json -Depth 6 | Set-Content $ProfileFile -Encoding UTF8
        $script:SysProfile = Get-SavedProfile
        Set-ProfileTailoring
        if ($script:PcUi) { Update-ThisPCPage }
        Update-WizardProfileLine
        if (-not $script:ProfileQuiet) { Show-Toast 'Scan finished. ZeroDelay adapted its recommendations to this PC.' '#30D158' }
    }
}
# Adjusts which cards "Apply recommended" and the setup wizard switch on, from what the scan found. Never adds risky
# tweaks: it only takes cards out of the recommended set, and records why.
function Set-ProfileTailoring {
    $p = $script:SysProfile; if (-not $p) { return }
    $notes = New-Object Collections.ArrayList
    foreach ($t in $Tweaks) { if ($null -eq $t.RecBase) { $t.RecBase = [bool]$t.Rec }; $t.Rec = $t.RecBase; $t.TailorWhy = $null }
    function Drop([string[]]$Ids, [string]$Why) {
        $n = 0
        foreach ($id in $Ids) { $t = $Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if ($t -and $t.Rec) { $t.Rec = $false; $t.TailorWhy = $Why; $n++ } }
        $n
    }
    if ($p.Computer.Laptop) {
        $n = Drop @('coreparking', 'minstate', 'epp', 'boostmode', 'throttle', 'zdplan', 'nvme-idle', 'sata-lpm', 'hybrid-pcore', 'usbsuspend', 'usb3lpm', 'pcie') 'Laptop: keeps parts at full power and drains the battery. Switch it on yourself when you play plugged in.'
        [void]$notes.Add("Laptop detected: $n power tweaks are no longer part of Apply recommended (they drain the battery). You can still switch them on when you play plugged in.")
    }
    $stream = @($p.Software.'Streaming and voice') + @($p.Software.'Overlays and recording') | Where-Object { $_ -match 'OBS|Streamlabs|XSplit' } | Select-Object -First 1
    if ($stream) {
        [void](Drop @('cpuprio', 'lowprio') "You have $stream`: raising Fortnite's priority can make your stream drop frames.")
        [void]$notes.Add("$stream found: Fortnite priority tweaks are not recommended, so your stream keeps its frames.")
    }
    $av = @($p.Security.Antivirus | Where-Object { $_ -notmatch 'Defender' })
    if ($av.Count) { [void]$notes.Add("Antivirus: $($av -join ', '). Cards that change Microsoft Defender have no effect while it is in charge.") }
    if ($p.Cpu.DualDieX3D) { [void]$notes.Add("$($p.Cpu.Name): core unparking is hidden. The AMD driver parks the second die on purpose so Fortnite stays on the V-Cache cores.") }
    elseif ($p.Cpu.Hybrid) { [void]$notes.Add("$($p.Cpu.Name) has performance and efficiency cores: the hybrid-CPU power card is shown for you.") }
    $net = @($p.Network | ForEach-Object { $_.Kind } | Select-Object -Unique)
    if ($net -contains 'Wi-Fi' -and $net -notcontains 'Ethernet') { [void]$notes.Add('You play on Wi-Fi: the Wi-Fi cards apply to you. A cable is the biggest single ping and jitter improvement if you can run one.') }
    elseif ($net -contains 'Ethernet') { [void]$notes.Add('You are on Ethernet: Wi-Fi cards are hidden.') }
    $gpu = Get-MainGpu $p
    if ($gpu -and $gpu.Vendor -ne 'NVIDIA') { [void]$notes.Add("$($gpu.Name): NVIDIA-only cards (Reflex driver settings, texture blur, G-SYNC page) are hidden.") }
    if (Test-Gtx1080Ti) {
        Set-GpuTailoring
        $pm = $Tweaks | Where-Object { $_.Id -eq 'perfmode' } | Select-Object -First 1
        if ($pm) { $pm.Rec = $true; $pm.TailorWhy = 'GTX 1080 Ti: Performance mode is the right renderer for this card.' }
        [void]$notes.Add('GTX 1080 Ti: a tab of its own was added (left menu). Performance rendering mode is now part of Apply recommended; cards for features the card does not have (frame generation, Smooth Motion, low textures for small graphics memory) are hidden; driver alerts only point to the 580 security branch.')
    }
    if (Test-CreatorPc) { [void]$notes.Add('Creator apps found (Adobe, OBS): a Creator tab was added, and Game Mode leaves Creative Cloud running while an Adobe app is open, so fonts and licences keep working.') }
    $opt = @($p.Software.'Other optimizers')
    if ($opt.Count) { [void]$notes.Add("Other optimizers installed: $($opt -join ', '). They can change the same settings; drift alerts will tell you when they do.") }
    $script:TailorNotes = @($notes)
    if ($script:HomeUi) { Update-HomePage }
    foreach ($t in $Tweaks) {
        if (-not $t.Card) { continue }
        $tag = $t.Card.FindName('RecTag')
        if ($tag) { $tag.Visibility = if ($t.Rec) { 'Visible' } else { 'Collapsed' } }
    }
}
# Cards for features a GTX 1080 Ti does not have are hidden (also before the first scan finishes).
function Set-GpuTailoring {
    if (-not (Test-Gtx1080Ti)) { return }
    foreach ($id in 'smoothmotion', 'framegen', 'texturelow') {
        $t = $Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($t) { $t.ForceHidden = $true; $t.Rec = $false; if ($t.Card) { $t.Card.Visibility = 'Collapsed' } }
    }
}
# --- Keep awake while a render runs: checks every 20 s how busy the render processes are.
function Start-RenderWatch {
    if (-not $script:RenderTimer) {
        $script:RenderTimer = New-Object Windows.Threading.DispatcherTimer
        $script:RenderTimer.Interval = [TimeSpan]::FromSeconds(20)
        $script:RenderCpu = @{}
        $script:RenderTimer.Add_Tick({
            if (-not (Get-Setting 'keepawake' $false)) { $script:RenderTimer.Stop(); [KeepAwake]::Release(); $script:RenderAwake = $false; return }
            $now = @{}; $busy = $false
            foreach ($p in Get-Process -Name 'Adobe Media Encoder', 'aerender', 'AfterFX', 'Adobe Premiere Pro' -ErrorAction SilentlyContinue) {
                $c = $null; try { $c = $p.TotalProcessorTime.TotalSeconds } catch {}
                if ($null -eq $c) { continue }
                $now[$p.Id] = $c
                if ($script:RenderCpu.ContainsKey($p.Id) -and (($c - $script:RenderCpu[$p.Id]) / 20 / [Environment]::ProcessorCount) -gt 0.2) { $busy = $true }
            }
            $script:RenderCpu = $now
            if ($busy -and -not $script:RenderAwake) { [KeepAwake]::Hold(); $script:RenderAwake = $true }
            elseif (-not $busy -and $script:RenderAwake) { [KeepAwake]::Release(); $script:RenderAwake = $false }
        })
    }
    $script:RenderTimer.Start()
}
function Update-WizardProfileLine {
    $p = $script:SysProfile
    if (-not $script:Wiz -or -not $script:Wiz.PcLine -or -not $p) { return }
    $bits = @("$(@($p.Apps.Programs).Count) programs and $($p.Apps.StoreCount) Store apps")
    foreach ($k in 'Overlays and recording', 'RGB and device software', 'Other optimizers') { $v = @($p.Software.$k); if ($v.Count) { $bits += ($v | Select-Object -First 2) -join ', ' } }
    $script:Wiz.PcLine.Text = "Scanned: $($bits -join '; '). ZeroDelay picks tweaks that fit this PC (details in Tools > This PC)."
    $stream = @($p.Software.'Streaming and voice') + @($p.Software.'Overlays and recording') | Where-Object { $_ -match 'OBS|Streamlabs|XSplit' }
    if ($stream -and $script:Wiz.StreamYes) { $script:Wiz.StreamYes.IsChecked = $true }
    if ($p.Computer.Laptop -and $script:Wiz.Lap) { $script:Wiz.Lap.IsChecked = $true }
}

function New-ThisPCPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,18' Margin='0,0,0,14'>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock x:Name='Head' FontSize='20' FontWeight='Bold' TextWrapping='Wrap'/>
        <TextBlock x:Name='Status' FontSize='12.5' Foreground='#A1A1A6' Margin='0,4,0,0' TextWrapping='Wrap'/>
      </StackPanel>
      <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'>
        <Button x:Name='Copy' Content='Copy summary' Style='{DynamicResource Btn}' Margin='0,0,8,0' ToolTip='Copies a text summary of this PC, handy when asking for help'/>
        <Button x:Name='Rescan' Content='Scan again' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF'/>
      </StackPanel>
    </Grid>
  </Border>
  <ContentControl x:Name='Body'/>
</StackPanel>
"@)
    $u = @{}; foreach ($n in 'Head', 'Status', 'Copy', 'Rescan', 'Body') { $u[$n] = $root.FindName($n) }
    $script:PcUi = $u
    $u.Rescan.Add_Click({ Start-ProfileScan })
    $u.Copy.Add_Click({ [Windows.Clipboard]::SetText((Get-ProfileText)); Show-Toast 'Summary copied.' '#30D158' })
    Update-ThisPCPage
    New-PageScroll $root
}
function Get-ProfileText {
    $p = $script:SysProfile; if (-not $p) { return 'Not scanned yet.' }
    $g = @($p.Gpus | ForEach-Object { "$($_.Name)$(if ($_.VramMb) { " $([Math]::Round($_.VramMb / 1024)) GB" }) (driver $($_.Driver))" }) -join '; '
    @("ZeroDelay $AppVersion - PC summary, scanned $(([datetime]$p.ScannedAt).ToString('yyyy-MM-dd HH:mm'))",
      "Windows: $($p.Windows.Name) $($p.Windows.Version) (build $($p.Windows.Build))",
      "PC: $($p.Computer.Maker) $($p.Computer.Model)$(if ($p.Computer.Laptop) { ' (laptop)' }); board $($p.Computer.Board), BIOS $($p.Computer.Bios) ($($p.Computer.BiosDate))",
      "CPU: $($p.Cpu.Name), $($p.Cpu.Cores) cores / $($p.Cpu.Threads) threads",
      "GPU: $g",
      "RAM: $($p.Memory.TotalGb) GB $($p.Memory.Type), $($p.Memory.Sticks) sticks at $($p.Memory.SpeedMts) MT/s (rated $($p.Memory.RatedMts))",
      "Drives: $(@($p.Drives | ForEach-Object { "$($_.Name) ($($_.Type) $($_.Bus), $($_.SizeGb) GB)" }) -join '; ')",
      "Fortnite: $(if ($p.Fortnite.Path) { "$($p.Fortnite.Path) on $($p.Fortnite.Drive)" } else { 'not found' })",
      "Monitors: $(@($p.Monitors | ForEach-Object { "$($_.Name)$(if ($_.Cable) { " ($($_.Cable))" })" }) -join '; '); refresh rates $(@($p.Displays | ForEach-Object { "$($_.Hz) Hz" }) -join ', ')",
      "Network: $(@($p.Network | ForEach-Object { "$($_.Kind) $($_.Name) $($_.Speed)" }) -join '; ')",
      "Security: Memory Integrity $(if ($p.Security.MemoryIntegrity) { 'on' } else { 'off' }), hypervisor $(if ($p.Security.Hypervisor) { 'running' } else { 'off' }), antivirus $(@($p.Security.Antivirus) -join ', ')",
      "Power plan: $($p.Power.Plan)",
      "Apps: $(@($p.Apps.Programs).Count) programs, $($p.Apps.StoreCount) Store apps") -join "`r`n"
}
function Update-ThisPCPage {
    $u = $script:PcUi; $p = $script:SysProfile
    $u.Rescan.IsEnabled = -not $script:ProfileScanning
    if (-not $p) {
        $u.Head.Text = 'This PC has not been scanned yet'
        $u.Status.Text = if ($script:ProfileScanning) { 'Scanning this PC: hardware, drivers, Windows and installed apps...' } else { 'Press Scan again to read the hardware, Windows and installed apps.' }
        $u.Body.Content = $null; return
    }
    $u.Head.Text = if ($p.Computer.Model -and $p.Computer.Model -notmatch 'System Product Name|To be filled|Default string') { "$($p.Computer.Maker) $($p.Computer.Model)" } else { "$($p.Cpu.Name) + $((Get-MainGpu $p).Name)" }
    $u.Status.Text = "Scanned $(([datetime]$p.ScannedAt).ToString('d MMM, HH:mm'))  ·  $(@($p.Apps.Programs).Count) programs, $($p.Apps.StoreCount) Store apps  ·  ZeroDelay re-scans every few days and after updates."
    function Row([string]$k, [string]$v) { if (-not "$v".Trim()) { return '' }; "<Grid Margin='0,0,0,6'><Grid.ColumnDefinitions><ColumnDefinition Width='110'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions><TextBlock Text='$(Esc $k)' FontSize='12' Foreground='#98989D'/><TextBlock Grid.Column='1' Text='$(Esc $v)' FontSize='12.5' Foreground='#D1D1D6' TextWrapping='Wrap'/></Grid>" }
    function Box([string]$title, [string]$rows) { if (-not $rows) { return '' }; "<Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='20,16' Margin='0,0,12,12' Width='520' VerticalAlignment='Top'><StackPanel><TextBlock Text='$(Esc $title)' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,10'/>$rows</StackPanel></Border>" }
    $gpuRows = (@($p.Gpus) | ForEach-Object { Row $(if ($_.Integrated) { 'Integrated' } else { 'Graphics' }) "$($_.Name)$(if ($_.VramMb) { ", $([Math]::Round($_.VramMb / 1024)) GB" })$(if ($_.Arch) { " ($($_.Arch))" }), driver $($_.Driver)" }) -join ''
    $boxes = @(
        (Box 'Computer' ((Row 'Type' $(if ($p.Computer.Laptop) { 'Laptop' } else { 'Desktop' })) + (Row 'Made by' $(if ("$($p.Computer.Model)" -match 'System Product Name|To be filled|Default string|^System$') { '' } else { "$($p.Computer.Maker) $($p.Computer.Model)" })) + (Row 'Motherboard' $p.Computer.Board) + (Row 'BIOS' "$($p.Computer.Bios)$(if ($p.Computer.BiosDate) { ", $($p.Computer.BiosDate)" })") + (Row 'Windows' "$($p.Windows.Name) $($p.Windows.Version), build $($p.Windows.Build)")))
        (Box 'Processor and graphics' ((Row 'CPU' "$($p.Cpu.Name)") + (Row 'Cores' "$($p.Cpu.Cores) cores, $($p.Cpu.Threads) threads$(if ($p.Cpu.Hybrid) { ', performance + efficiency cores' })$(if ($p.Cpu.X3D) { ', 3D V-Cache' })") + $gpuRows))
        (Box 'Memory and drives' ((Row 'RAM' "$($p.Memory.TotalGb) GB $($p.Memory.Type), $($p.Memory.Sticks) stick$(if ($p.Memory.Sticks -ne 1) { 's' }) at $($p.Memory.SpeedMts) MT/s$(if ($p.Memory.RatedMts -gt $p.Memory.SpeedMts) { " (rated $($p.Memory.RatedMts))" })") +
            ((@($p.Drives) | ForEach-Object { Row 'Drive' "$($_.Name): $($_.Type) $($_.Bus), $($_.SizeGb) GB" }) -join '') + (Row 'Windows on' $p.SystemDrive) + (Row 'Fortnite on' $(if ($p.Fortnite.Path) { "$($p.Fortnite.Drive) ($($p.Fortnite.Path))" } else { 'not found' }))))
        (Box 'Monitors, network and devices' (((@($p.Monitors) | ForEach-Object { Row 'Monitor' "$($_.Name)$(if ($_.Cable) { ", $($_.Cable)" })" }) -join '') +
            (Row 'Refresh rates' ((@($p.Displays) | Sort-Object { -not $_.Primary } | ForEach-Object { "$($_.Hz) Hz$(if ($_.Primary) { ' (main)' })" }) -join ', ')) +
            ((@($p.Network) | ForEach-Object { Row $_.Kind "$($_.Name), $($_.Speed)" }) -join '') + ((@($p.Input) | ForEach-Object { Row $_.Kind $_.Name }) -join '') + (Row 'Audio' "$(@($p.Audio).Count) playback devices")))
        (Box 'Windows security and power' ((Row 'Memory Integrity' $(if ($p.Security.MemoryIntegrity) { 'On' } else { 'Off' })) + (Row 'Hypervisor' $(if ($p.Security.Hypervisor) { 'Running' } else { 'Off' })) + (Row 'Antivirus' (@($p.Security.Antivirus) -join ', ')) + (Row 'Power plan' $p.Power.Plan)))
        (Box 'Software that matters for gaming' ((@($p.Software.PSObject.Properties) | ForEach-Object { Row $_.Name ((@($_.Value) | Select-Object -First 6) -join ', ' + $(if (@($_.Value).Count -gt 6) { ", +$(@($_.Value).Count - 6) more" })) }) -join ''))
    ) -join ''
    $notesX = (@($script:TailorNotes) | ForEach-Object { "<TextBlock Text='$(Esc "•  $_")' FontSize='12.5' Foreground='#D1D1D6' TextWrapping='Wrap' Margin='0,0,0,6' LineHeight='18' LineStackingStrategy='BlockLineHeight'/>" }) -join ''
    if (-not $notesX) { $notesX = "<TextBlock Text='Nothing on this PC needs special handling: the standard recommendations fit.' FontSize='12.5' Foreground='#D1D1D6'/>" }
    $progList = Esc ((@($p.Apps.Programs)) -join "`n")
    $panel = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,0,12,12'>
    <StackPanel>
      <TextBlock Text='How ZeroDelay adapted to this PC' FontSize='14' FontWeight='SemiBold' Margin='0,0,0,10'/>
      $notesX
    </StackPanel>
  </Border>
  <WrapPanel>$boxes</WrapPanel>
  <Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='22,16' Margin='0,0,12,12'>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <TextBlock Text='$(@($p.Apps.Programs).Count) installed programs' FontSize='14' FontWeight='SemiBold' VerticalAlignment='Center'/>
        <Button x:Name='ShowApps' Grid.Column='1' Content='Show all' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12'/>
      </Grid>
      <TextBlock x:Name='AppList' Text='$progList' FontSize='12' Foreground='#A1A1A6' Margin='0,10,0,0' Visibility='Collapsed' LineHeight='18' LineStackingStrategy='BlockLineHeight'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $panel.FindName('ShowApps').Add_Click({ param($s, $e) $l = $s.Parent.Parent.Children[1]; $vis = $l.Visibility -ne 'Visible'; $l.Visibility = if ($vis) { 'Visible' } else { 'Collapsed' }; $s.Content = if ($vis) { 'Hide' } else { 'Show all' } })
    $u.Body.Content = $panel
}

# =============================================================== Home: one place, one button
function New-HomePage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' MaxWidth='1060' HorizontalAlignment='Left'>
  <Border Style='{DynamicResource Card}' CornerRadius='22' Padding='34,30' Margin='0,0,0,16'>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <Grid Width='132' Height='132' VerticalAlignment='Center'>
        <Ellipse Stroke='#3A3A3C' StrokeThickness='11'/>
        <Ellipse x:Name='Ring' Stroke='#30D158' StrokeThickness='11' StrokeDashCap='Round' RenderTransformOrigin='0.5,0.5'>
          <Ellipse.RenderTransform><RotateTransform Angle='-90'/></Ellipse.RenderTransform>
        </Ellipse>
        <StackPanel VerticalAlignment='Center' HorizontalAlignment='Center'>
          <TextBlock x:Name='Pct' Text='0' FontSize='38' FontWeight='Bold' HorizontalAlignment='Center' Typography.NumeralAlignment='Tabular'/>
          <TextBlock Text='optimized' FontSize='12' Foreground='#A1A1A6' HorizontalAlignment='Center' Margin='0,-4,0,0'/>
        </StackPanel>
      </Grid>
      <StackPanel Grid.Column='1' Margin='30,0,24,0' VerticalAlignment='Center'>
        <TextBlock x:Name='Headline' FontSize='26' FontWeight='Bold' TextWrapping='Wrap'/>
        <TextBlock x:Name='Sub' FontSize='13.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' LineHeight='20' LineStackingStrategy='BlockLineHeight'/>
      </StackPanel>
      <Button x:Name='Go' Grid.Column='2' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Padding='26,13' FontSize='15' VerticalAlignment='Center'>
        <StackPanel Orientation='Horizontal'><TextBlock Text='&#xE945;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Margin='0,2,10,0'/><TextBlock x:Name='GoText' Text='Optimize'/></StackPanel>
      </Button>
    </Grid>
  </Border>
  <UniformGrid Columns='3'>
    <Border Style='{DynamicResource Card}' Padding='22,20' Margin='0,0,12,12'>
      <StackPanel>
        <Grid><TextBlock Text='Game Mode' FontSize='15' FontWeight='SemiBold'/><ToggleButton x:Name='Gm' Style='{DynamicResource Switch}' HorizontalAlignment='Right'/></Grid>
        <TextBlock x:Name='GmText' FontSize='12.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' MinHeight='36'/>
      </StackPanel>
    </Border>
    <Border x:Name='HealthTile' Style='{DynamicResource Card}' Padding='22,20' Margin='0,0,12,12' Cursor='Hand'>
      <StackPanel>
        <Grid><TextBlock Text='Health check' FontSize='15' FontWeight='SemiBold'/><TextBlock Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center'/></Grid>
        <TextBlock x:Name='HealthText' FontSize='12.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' MinHeight='36'/>
      </StackPanel>
    </Border>
    <Border x:Name='MatchTile' Style='{DynamicResource Card}' Padding='22,20' Margin='0,0,12,12' Cursor='Hand'>
      <StackPanel>
        <Grid><TextBlock Text='Last match' FontSize='15' FontWeight='SemiBold'/><TextBlock Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center'/></Grid>
        <TextBlock x:Name='MatchText' FontSize='12.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' MinHeight='36'/>
      </StackPanel>
    </Border>
    <Border x:Name='PcTile' Style='{DynamicResource Card}' Padding='22,20' Margin='0,0,12,12' Cursor='Hand'>
      <StackPanel>
        <Grid><TextBlock Text='This PC' FontSize='15' FontWeight='SemiBold'/><TextBlock Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center'/></Grid>
        <TextBlock x:Name='PcText' FontSize='12.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' MinHeight='36'/>
      </StackPanel>
    </Border>
    <Border x:Name='CleanTile' Style='{DynamicResource Card}' Padding='22,20' Margin='0,0,12,12' Cursor='Hand'>
      <StackPanel>
        <Grid><TextBlock Text='Clean up' FontSize='15' FontWeight='SemiBold'/><TextBlock Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center'/></Grid>
        <TextBlock Text='Temp files, update leftovers and caches. You see the size first.' FontSize='12.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' MinHeight='36'/>
      </StackPanel>
    </Border>
    <Border x:Name='TweaksTile' Style='{DynamicResource Card}' Padding='22,20' Margin='0,0,12,12' Cursor='Hand'>
      <StackPanel>
        <Grid><TextBlock Text='All tweaks' FontSize='15' FontWeight='SemiBold'/><TextBlock Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center'/></Grid>
        <TextBlock x:Name='TweaksText' FontSize='12.5' Foreground='#A1A1A6' Margin='0,8,0,0' TextWrapping='Wrap' MinHeight='36'/>
      </StackPanel>
    </Border>
  </UniformGrid>
</StackPanel>
"@)
    $h = @{}; foreach ($n in 'Ring', 'Pct', 'Headline', 'Sub', 'Go', 'GoText', 'Gm', 'GmText', 'HealthTile', 'HealthText', 'MatchTile', 'MatchText', 'PcTile', 'PcText', 'CleanTile', 'TweaksTile', 'TweaksText') { $h[$n] = $root.FindName($n) }
    $script:HomeUi = $h
    $h.Go.Add_Click({ $ui.ApplyRec.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
    $h.Gm.Add_Click({ param($s, $e)
        $window.Cursor = [Windows.Input.Cursors]::Wait
        $msg = if ($s.IsChecked) { Enable-ZDGameMode } else { $m = Disable-ZDGameMode; if (Test-FortniteRunning) { $script:GmSuppress = $true }; $m }
        $window.Cursor = $null
        Show-Toast $msg '#30D158'; Update-GameModeUi; Update-HomePage })
    foreach ($pair in @(@('HealthTile', 'Health'), @('MatchTile', 'Matches'), @('PcTile', 'ThisPC'), @('CleanTile', 'Clean'), @('TweaksTile', 'All'))) {
        $h[$pair[0]].Tag = $pair[1]
        $h[$pair[0]].Add_MouseLeftButtonUp({ param($s, $e) Select-NavPage $s.Tag })
        $h[$pair[0]].RenderTransform = New-Object Windows.Media.TranslateTransform
        $h[$pair[0]].Add_MouseEnter({ param($s, $e) Set-HoverGlow $s $true; if ($script:Anim) { Start-Anim $s.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) $null -3 180 } })
        $h[$pair[0]].Add_MouseLeave({ param($s, $e) Set-HoverGlow $s $false; if ($script:Anim) { Start-Anim $s.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) $null 0 220 } })
    }
    $script:PageRefresh['Home'] = { Update-HomePage }
    Update-HomePage
    New-PageScroll $root
}
function Update-HomePage {
    $h = $script:HomeUi; if (-not $h) { return }
    $rec = @($Tweaks | Where-Object { $_.Rec -and $_.Toggle -and $null -ne $_.State })
    $on = @($rec | Where-Object { $_.State }).Count
    $left = $rec.Count - $on
    $pct = if ($rec.Count) { [int][Math]::Round(100 * $on / $rec.Count) } else { 100 }
    Start-CountUp $h.Pct $pct '' 900
    # ring: dash length in stroke-thickness units around the circle (diameter 132 - stroke 11)
    $circ = [Math]::PI * (132 - 11) / 11
    $h.Ring.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@(($circ * $pct / 100), 1000))
    $h.Ring.Stroke = ConvertTo-Brush $(if ($pct -ge 90) { '#30D158' } elseif ($pct -ge 60) { '#FFD60A' } else { '#FF9F0A' })
    $h.Ring.Effect = New-Glow $h.Ring.Stroke.Color 22 0.55   # the ring glows in its own colour
    if ($left -gt 0) {
        $h.Headline.Text = "$left recommended tweak$(if ($left -ne 1) { 's are' } else { ' is' }) still off"
        $h.Sub.Text = 'Optimize shows the list and you pick what to switch on. A restore point comes first, and every change can be undone from the menu next to Optimize.'
        $h.Go.IsEnabled = $true; $h.GoText.Text = 'Optimize'
    } else {
        $h.Headline.Text = 'Your PC is fully optimized'
        $h.Sub.Text = 'Everything recommended for this PC is on. ZeroDelay keeps watching and tells you if another program changes something back.'
        $h.Go.IsEnabled = $false; $h.GoText.Text = 'All set'
    }
    $gm = Test-ZDGameMode
    $h.Gm.IsChecked = $gm
    $h.GmText.Text = if ($gm) { 'On. Background apps are closed and the PC is in match mode.' } elseif ((Get-GameModePrefs).auto) { 'Turns on by itself when Fortnite starts.' } else { 'Closes background apps and switches to match mode while you play.' }
    $issues = @($script:HealthIssues)
    $h.HealthText.Text = if ($null -eq $script:HealthIssues) { 'Scan for the problems that cost the most FPS and delay.' } elseif ($issues.Count) { "$($issues.Count) thing$(if ($issues.Count -ne 1) { 's' }) to look at." } else { 'Everything looks good.' }
    $mr = @(Get-MatchReports) | Select-Object -First 1
    $h.MatchText.Text = if ($mr) { "$(([datetime]$mr.Start).ToString('ddd HH:mm')): $(if (@($mr.Issues).Count) { "$(@($mr.Issues).Count) thing$(if (@($mr.Issues).Count -ne 1) { 's' }) got in the way" } else { 'smooth' })$(if ($mr.Fps) { ", $($mr.Fps.Avg) FPS" })." } else { 'Play a match with ZeroDelay open to get your first report.' }
    $p = $script:SysProfile
    $h.PcText.Text = if ($p) { "$((Get-MainGpu $p).Name), $($p.Memory.TotalGb) GB RAM. $(@($script:TailorNotes).Count) adjustments for this PC." } else { 'Scanning your hardware and apps...' }
    $all = @($Tweaks | Where-Object { $_.Toggle -and $null -ne $_.State })
    $h.TweaksText.Text = "$(@($all | Where-Object { $_.State }).Count) of $($all.Count) switched on, in $(@($Categories | Where-Object { -not $_.Page }).Count) groups."
}
# Switches the left menu (and the page) to a category, opening its group if it is folded.
function Select-NavPage([string]$Name) {
    if (-not $script:NavButtons.ContainsKey($Name)) { return }
    Set-NavGroupOpen (Get-NavGroupOf $Name) $true
    $script:NavButtons[$Name].IsChecked = $true
    $script:NavButtons[$Name].BringIntoView()
}

# =============================================================== Game Mode page (booster dashboard)
$GmStepInfo = [ordered]@{
    apps     = @{ Icon = 0xE71D; Tint = '#5E5CE6'; Desc = 'Closes the apps you pick below and reopens them afterwards.' }
    plan     = @{ Icon = 0xE945; Tint = '#FF9F0A'; Desc = 'Full CPU speed and no parked cores while you play.' }
    priority = @{ Icon = 0xE9D9; Tint = '#0A84FF'; Desc = 'Discord, browsers and launchers step back to below-normal priority.' }
    dnd      = @{ Icon = 0xE708; Tint = '#BF5AF2'; Desc = 'No Windows pop-ups in the middle of a fight.' }
    updates  = @{ Icon = 0xE896; Tint = '#30B0C7'; Desc = 'Windows Update stops downloading until you are done.' }
    dns      = @{ Icon = 0xE968; Tint = '#34C759'; Desc = 'Clears stale server addresses before you queue.' }
    nvreplay = @{ Icon = 0xE714; Tint = '#76B900'; Desc = 'Stops NVIDIA background recording. Leave off if you want clips.' }
    auto     = @{ Icon = 0xE768; Tint = '#2EE6A6'; Desc = 'Game Mode starts by itself when Fortnite opens.' }
    autooff  = @{ Icon = 0xE71A; Tint = '#FF6482'; Desc = 'Everything goes back when Fortnite closes.' }
}
# icons for the apps Game Mode closes: from the running process, Settings > Apps, or the app's known exe
function Get-ExeIconSource([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (-not $script:ExeIcons) { $script:ExeIcons = @{} }
    if ($script:ExeIcons.ContainsKey($Path)) { return $script:ExeIcons[$Path] }
    $src = $null
    try {
        $ico = if ($Path -match '(?i)\.ico$') { New-Object System.Drawing.Icon $Path, 48, 48 } else { [System.Drawing.Icon]::ExtractAssociatedIcon($Path) }
        $src = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze(); $ico.Dispose()
    } catch {}
    $script:ExeIcons[$Path] = $src
    $src
}
function Get-InstalledEntries {
    Get-Cached 'installedentries' {
        @(foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
            foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) { $q = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue; if ($q.DisplayName) { [pscustomobject]@{ Name = "$($q.DisplayName)"; Icon = "$($q.DisplayIcon)" } } }
        })
    } 120
}
function Get-SessionAppIcon($app) {
    # looked up once per app (and again only if it starts running from somewhere new)
    if (-not $script:AppIconCache) { $script:AppIconCache = @{} }
    $ck = "$($app.Key)|$(if ($script:GmRunningPaths) { $script:GmRunningPaths[$app.Key] })"
    if ($script:AppIconCache.ContainsKey($ck)) { return $script:AppIconCache[$ck] }
    $script:AppIconCache[$ck] = Find-SessionAppIcon $app
    $script:AppIconCache[$ck]
}
function Find-SessionAppIcon($app) {
    $paths = @()
    if ($script:GmRunningPaths -and $script:GmRunningPaths[$app.Key]) { $paths += $script:GmRunningPaths[$app.Key] }
    if ($app.Main) { $paths += Get-AppPath $app.Main }
    if ($app.Detect) { $e = Get-InstalledEntries | Where-Object { $_.Name -match "^($($app.Detect))" -and $_.Icon } | Select-Object -First 1; if ($e) { $paths += (($e.Icon -replace ',\s*-?\d+\s*$', '').Trim('"')) } }
    foreach ($pth in $paths) { $i = Get-ExeIconSource $pth; if ($i) { return $i } }
    $null
}
function Start-FortniteGame {
    if (Test-FortniteRunning) { return 'Fortnite is already running.' }
    try { Start-Process 'com.epicgames.launcher://apps/fn%3A4fe75bbc5a674f4f9b356b5c90567da5%3AFortnite?action=launch&silent=true'; 'Launching Fortnite through the Epic Games Launcher.' }
    catch { 'Could not start Fortnite: is the Epic Games Launcher installed?' }
}
$GmStatScript = {
    param($pingHost, $apps)
    $r = @{ Cpu = $null; GpuTemp = $null; GpuUtil = $null; MemPct = $null; Ping = $null; Running = @{} }
    
    $smi = "$env:WINDIR\System32\nvidia-smi.exe"
    if (Test-Path $smi) { try { $x = "$(& $smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1)" -split ',\s*'; if ($x.Count -ge 2) { $r.GpuTemp = [int]$x[0]; $r.GpuUtil = [int]$x[1] } } catch {} }
    try { $os = Get-CimInstance Win32_OperatingSystem; $r.MemPct = [int](100 - 100 * $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) } catch {}
    if ($pingHost) { try { $png = New-Object Net.NetworkInformation.Ping; $x = $png.Send($pingHost, 1000); if ($x.Status -eq 'Success') { $r.Ping = [int]$x.RoundtripTime } } catch {} }
    $procs = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ })
    foreach ($a in $apps) { $hit = $procs | Where-Object { $_ -match $a.PathRx } | Select-Object -First 1; if ($hit) { $r.Running[$a.Key] = $hit } }
    [pscustomobject]$r
}
function New-GameModePage {
    $root = [ZdTheme]::Parse(@"
<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' HorizontalAlignment='Stretch' Margin='0,0,0,8'>
  <Border CornerRadius='26' ClipToBounds='True' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Height='640'>
    <Grid>
      <!-- soft colour glows instead of game art -->
      <Ellipse Width='620' Height='620' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-180,-260,0,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#552EE6A6' Offset='0'/><GradientStop Color='#002EE6A6' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='760' Height='760' HorizontalAlignment='Right' VerticalAlignment='Bottom' Margin='0,0,-260,-320' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#555E5CE6' Offset='0'/><GradientStop Color='#005E5CE6' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='420' Height='420' HorizontalAlignment='Center' VerticalAlignment='Center' Margin='0,0,260,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#3324A0FF' Offset='0'/><GradientStop Color='#0024A0FF' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Grid Margin='44,40,22,22'>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='370'/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
        <!-- left: title, status, numbers, start -->
        <DockPanel Margin='0,0,28,0'>
          <StackPanel DockPanel.Dock='Top'>
            <TextBlock Text='FORTNITE' FontFamily='Segoe UI Black, Segoe UI' FontWeight='Black' FontSize='74' Foreground='#FFFFFF' Margin='-3,0,0,0'/>
            <StackPanel Orientation='Horizontal' Margin='0,6,0,0'>
              <Border x:Name='StatePill' CornerRadius='14' Padding='12,5,14,6' Background='#1AFFFFFF' BorderBrush='#26FFFFFF' BorderThickness='1'>
                <StackPanel Orientation='Horizontal'>
                  <Ellipse x:Name='StateDot' Width='8' Height='8' Fill='#8E8E93' VerticalAlignment='Center' Margin='0,0,8,0'/>
                  <TextBlock x:Name='StateText' FontSize='13' FontWeight='SemiBold' Foreground='#FFFFFF'/>
                </StackPanel>
              </Border>
              <TextBlock x:Name='StateSub' FontSize='12.5' Foreground='#9A9AA5' VerticalAlignment='Center' Margin='14,0,0,0'/>
            </StackPanel>
            <WrapPanel Margin='0,30,0,0'>
              <StackPanel Margin='0,0,44,16'>
                <StackPanel Orientation='Horizontal'><TextBlock x:Name='PingVal' Text='-' FontSize='38' FontWeight='Bold' Foreground='#2EE6A6' Typography.NumeralAlignment='Tabular'/><TextBlock Text='ms' FontSize='13' Foreground='#2EE6A6' VerticalAlignment='Bottom' Margin='4,0,0,8'/></StackPanel>
                <TextBlock x:Name='PingLbl' Text='Ping' FontSize='12' Foreground='#9A9AA5'/>
              </StackPanel>
              <StackPanel Margin='0,0,44,16'>
                <TextBlock x:Name='AppsVal' Text='0' FontSize='38' FontWeight='Bold' Foreground='#FFFFFF' Typography.NumeralAlignment='Tabular'/>
                <TextBlock x:Name='AppsLbl' Text='Apps closed' FontSize='12' Foreground='#9A9AA5'/>
              </StackPanel>
              <StackPanel Margin='0,0,44,16'>
                <StackPanel Orientation='Horizontal'><TextBlock x:Name='MemVal' Text='0' FontSize='38' FontWeight='Bold' Foreground='#FFFFFF' Typography.NumeralAlignment='Tabular'/><TextBlock Text='GB' FontSize='13' Foreground='#9A9AA5' VerticalAlignment='Bottom' Margin='4,0,0,8'/></StackPanel>
                <TextBlock Text='Memory freed' FontSize='12' Foreground='#9A9AA5'/>
              </StackPanel>
              <StackPanel Margin='0,0,0,16'>
                <TextBlock x:Name='StepsVal' Text='0' FontSize='38' FontWeight='Bold' Foreground='#FFFFFF'/>
                <TextBlock Text='Boost steps on' FontSize='12' Foreground='#9A9AA5'/>
              </StackPanel>
            </WrapPanel>
            <TextBlock x:Name='DoneText' FontSize='12.5' Foreground='#B8B8C2' TextWrapping='Wrap' MaxWidth='560' HorizontalAlignment='Left' Margin='0,6,0,0' LineHeight='19' LineStackingStrategy='BlockLineHeight'/>
          </StackPanel>
          <StackPanel DockPanel.Dock='Bottom' Orientation='Horizontal' VerticalAlignment='Bottom' Margin='0,30,0,0'>
            <Border CornerRadius='30' Background='#14FFFFFF' BorderBrush='#22FFFFFF' BorderThickness='1' Padding='22,0' Height='60' Margin='0,0,14,0'>
              <StackPanel Orientation='Horizontal' VerticalAlignment='Center'>
                <Ellipse x:Name='TimerDot' Width='10' Height='10' Fill='#8E8E93' Margin='0,0,12,0'/>
                <TextBlock x:Name='Timer' Text='00:00:00' FontSize='22' FontWeight='SemiBold' Foreground='#FFFFFF' Typography.NumeralAlignment='Tabular'/>
              </StackPanel>
            </Border>
            <Button x:Name='Start' Height='60' Width='270' Cursor='Hand' Margin='0,0,10,0'>
              <Button.Template>
                <ControlTemplate TargetType='Button'>
                  <Border x:Name='B' CornerRadius='30' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}'>
                    <Border.Effect><DropShadowEffect x:Name='Glow' Color='#2EE6A6' BlurRadius='34' ShadowDepth='0' Opacity='0.55'/></Border.Effect>
                    <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='B' Property='Opacity' Value='0.92'/></Trigger>
                    <Trigger Property='IsPressed' Value='True'><Setter TargetName='B' Property='Opacity' Value='0.8'/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
              <TextBlock x:Name='StartText' Text='Start Game' FontSize='20' FontWeight='SemiBold'/>
            </Button>
            <Button x:Name='Power' Width='60' Height='60' Cursor='Hand' ToolTip='Game Mode on or off, without launching Fortnite'>
              <Button.Template>
                <ControlTemplate TargetType='Button'>
                  <Border x:Name='B' CornerRadius='30' Background='{TemplateBinding Background}' BorderBrush='#33FFFFFF' BorderThickness='1'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>
                  <ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='B' Property='Opacity' Value='0.85'/></Trigger></ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
              <TextBlock x:Name='PowerIcon' Text='&#xE7E8;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='20'/>
            </Button>
          </StackPanel>
        </DockPanel>
        <!-- right: the tools panel -->
        <Border Grid.Column='1' Grid.RowSpan='2' CornerRadius='20' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='18,18,10,14'>
          <DockPanel>
            <StackPanel DockPanel.Dock='Top' Margin='0,0,8,0'>
              <StackPanel Orientation='Horizontal'>
                <TextBlock Text='&#xE71D;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#2EE6A6' FontSize='14' VerticalAlignment='Center' Margin='0,1,8,0'/>
                <TextBlock Text='Game Mode tools' FontSize='15' FontWeight='SemiBold' Foreground='#FFFFFF'/>
              </StackPanel>
              <StackPanel x:Name='Chips' Orientation='Horizontal' Margin='0,14,0,12'/>
            </StackPanel>
            <ScrollViewer Style='{DynamicResource OverlayScroll}' VerticalScrollBarVisibility='Auto' Padding='0,0,8,0'>
              <StackPanel x:Name='Tools'/>
            </ScrollViewer>
          </DockPanel>
        </Border>
        <!-- live numbers -->
        <Border Grid.Row='1' HorizontalAlignment='Left' CornerRadius='16' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='6,8' Margin='0,18,28,0'>
          <StackPanel Orientation='Horizontal'>
            <StackPanel Width='86'><TextBlock x:Name='CpuVal' Text='-' FontSize='17' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center'/><TextBlock Text='CPU' FontSize='11' Foreground='#9A9AA5' HorizontalAlignment='Center'/></StackPanel>
            <Border Width='1' Background='#22FFFFFF' Margin='0,4'/>
            <StackPanel Width='86'><TextBlock x:Name='GpuTVal' Text='-' FontSize='17' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center'/><TextBlock Text='GPU temp' FontSize='11' Foreground='#9A9AA5' HorizontalAlignment='Center'/></StackPanel>
            <Border Width='1' Background='#22FFFFFF' Margin='0,4'/>
            <StackPanel Width='86'><TextBlock x:Name='GpuUVal' Text='-' FontSize='17' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center'/><TextBlock Text='GPU load' FontSize='11' Foreground='#9A9AA5' HorizontalAlignment='Center'/></StackPanel>
            <Border Width='1' Background='#22FFFFFF' Margin='0,4'/>
            <StackPanel Width='86'><TextBlock x:Name='MemPctVal' Text='-' FontSize='17' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center'/><TextBlock Text='Memory' FontSize='11' Foreground='#9A9AA5' HorizontalAlignment='Center'/></StackPanel>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Grid>
"@)
    $g = @{}; foreach ($n in 'StatePill', 'StateDot', 'StateText', 'StateSub', 'PingVal', 'PingLbl', 'AppsVal', 'AppsLbl', 'MemVal', 'StepsVal', 'DoneText', 'TimerDot', 'Timer', 'Start', 'StartText', 'Power', 'PowerIcon', 'Chips', 'Tools', 'CpuVal', 'GpuTVal', 'GpuUVal', 'MemPctVal') { $g[$n] = $root.FindName($n) }
    $script:GmUi = $g
    Set-RoundClip $root.Children[0] 26   # glows stay inside the rounded corners
    $script:GmFilter = 'all'
    foreach ($c in @(@('all', 'All'), @('steps', 'Boost'), @('apps', 'Apps'), @('auto', 'Auto'))) {
        $b = [ZdTheme]::Parse("<Button xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Content='$($c[1])' Cursor='Hand' Margin='0,0,6,0' Padding='14,5' FontSize='12.5'><Button.Template><ControlTemplate TargetType='Button'><Border CornerRadius='13' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' Padding='{TemplateBinding Padding}'><ContentPresenter/></Border></ControlTemplate></Button.Template></Button>")
        $b.Tag = $c[0]
        $b.Add_Click({ param($s, $e) $script:GmFilter = $s.Tag; Update-GameModeTools; Show-Animated $script:GmUi.Tools 8 220 })
        [void]$g.Chips.Children.Add($b)
    }
    $g.Start.Add_Click({
        $window.Cursor = [Windows.Input.Cursors]::Wait
        if (Test-ZDGameMode) { $msg = Disable-ZDGameMode; if (Test-FortniteRunning) { $script:GmSuppress = $true } }
        else { $msg = Enable-ZDGameMode; $msg = "$msg $(Start-FortniteGame)" }
        $window.Cursor = $null
        Show-Toast $msg '#30D158'; Update-GameModeUi
    })
    $g.Power.Add_Click({
        $window.Cursor = [Windows.Input.Cursors]::Wait
        $msg = if (Test-ZDGameMode) { $m = Disable-ZDGameMode; if (Test-FortniteRunning) { $script:GmSuppress = $true }; $m } else { Enable-ZDGameMode }
        $window.Cursor = $null
        Show-Toast $msg '#30D158'; Update-GameModeUi
    })
    # live numbers once a second (clock) and every 3 s (CPU, GPU, memory, ping, running apps) while the page is open
    if (-not $script:GmPageTimer) {
        $script:GmPageTimer = New-Object Windows.Threading.DispatcherTimer
        $script:GmPageTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:GmTick = 0
        $script:GmPageTimer.Add_Tick({
            if ($script:CurrentCat.Name -ne 'GameMode' -or -not $window.IsVisible) { return }
            Update-GameModeClock
            $script:GmTick++
            if ($script:GmTick % 3 -eq 1 -and -not $script:GmStatBusy) {
                $script:GmStatBusy = $true
                $region = Get-Setting 'pingregion' $null
                $hostEntry = $PingHosts | Where-Object { $_.Name -eq $region } | Select-Object -First 1; if (-not $hostEntry) { $hostEntry = $PingHosts[0] }
                $script:GmPingName = $hostEntry.Name
                Start-Background $GmStatScript.ToString() @($hostEntry.Host, @($SessionApps | ForEach-Object { @{ Key = $_.Key; PathRx = $_.PathRx } })) {
                    param($out, $errs)
                    $script:GmStatBusy = $false
                    $r = @($out | Where-Object { $_ }) | Select-Object -First 1
                    if (-not $r -or -not $script:GmUi) { return }
                    $g = $script:GmUi
                    $cpu = [CpuLoad]::Sample(); $g.CpuVal.Text = if ($cpu -ge 0) { "$cpu%" } else { '-' }
                    $g.GpuTVal.Text = if ($null -ne $r.GpuTemp) { "$($r.GpuTemp)°C" } else { '-' }
                    $g.GpuUVal.Text = if ($null -ne $r.GpuUtil) { "$($r.GpuUtil)%" } else { '-' }
                    $g.MemPctVal.Text = if ($null -ne $r.MemPct) { "$($r.MemPct)%" } else { '-' }
                    $g.PingVal.Text = if ($null -ne $r.Ping) { "$($r.Ping)" } else { '-' }
                    $g.PingLbl.Text = "Ping to $($script:GmPingName)"
                    $g.GpuTVal.Foreground = ConvertTo-Brush $(if ($r.GpuTemp -ge 83) { '#FF453A' } elseif ($r.GpuTemp -ge 75) { '#FF9F0A' } else { '#FFFFFF' })
                    $changed = (@($r.Running.Keys) -join ',') -ne (@($script:GmRunningPaths.Keys) -join ',')
                    $script:GmRunningPaths = $r.Running
                    if ($changed) { Update-GameModeTools; Update-GameModePage }
                }
            }
        })
    }
    [void][CpuLoad]::Sample()   # first reading is the baseline
    $script:GmPageTimer.Start()
    $script:PageRefresh['GameMode'] = { Update-GameModePage; Update-GameModeTools }
    Update-GameModeTools
    Update-GameModePage
    New-PageScroll $root
}
function Update-GameModeClock {
    $g = $script:GmUi; if (-not $g) { return }
    $span = [TimeSpan]::Zero
    if (Test-ZDGameMode) { try { $st = Get-Content $GameModeFile -Raw | ConvertFrom-Json; $span = (Get-Date) - [datetime]$st.Started } catch {} }
    $g.Timer.Text = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
}
function Update-GameModePage {
    $g = $script:GmUi; if (-not $g) { return }
    $on = Test-ZDGameMode
    $fn = Test-FortniteRunning
    $prefs = Get-GameModePrefs
    $st = $null; if ($on) { try { $st = Get-Content $GameModeFile -Raw | ConvertFrom-Json } catch {} }
    $mint = '#2EE6A6'
    $g.StateDot.Fill = ConvertTo-Brush $(if ($on) { $mint } elseif ($fn) { '#FF9F0A' } else { '#8E8E93' })
    $g.StateText.Text = if ($on) { 'Game Mode on' } else { 'Game Mode off' }
    $g.StateSub.Text = if ($on -and $fn) { 'Fortnite is running' } elseif ($on) { "On since $(([datetime]$st.Started).ToString('HH:mm'))" } elseif ($fn) { 'Fortnite is running without Game Mode' } elseif ($prefs.auto) { 'Turns on by itself when Fortnite starts' } else { 'Press Start Game when you are ready' }
    $g.TimerDot.Fill = ConvertTo-Brush $(if ($on) { '#FF453A' } else { '#8E8E93' })
    if ($on -and $script:Anim) {
        $a = New-Object Windows.Media.Animation.DoubleAnimation 1, 0.25, ([Windows.Duration][TimeSpan]::FromMilliseconds(900)); $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $g.TimerDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    } else { $g.TimerDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null) }
    # Start button: mint gradient to start, dark with a mint edge to stop
    if ($on) {
        $g.Start.Background = ConvertTo-Brush '#141416'; $g.Start.BorderBrush = ConvertTo-Brush $mint; $g.Start.BorderThickness = 1.5
        $g.StartText.Text = 'Stop Game Mode'; $g.StartText.Foreground = ConvertTo-Brush $mint
    } else {
        $grad = New-Object Windows.Media.LinearGradientBrush; $grad.StartPoint = '0,0'; $grad.EndPoint = '1,1'
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString('#4BF0BA')), 0))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString('#1FC48C')), 1))
        $g.Start.Background = [Windows.Media.Brush]$grad; $g.Start.BorderThickness = 0
        $g.StartText.Text = if ($fn) { 'Start Game Mode' } else { 'Start Game' }; $g.StartText.Foreground = ConvertTo-Brush '#04241A'
    }
    $g.Power.Background = ConvertTo-Brush $(if ($on) { '#262E2EE6' } else { '#14FFFFFF' })
    $g.PowerIcon.Foreground = ConvertTo-Brush $(if ($on) { $mint } else { '#FFFFFF' })
    # numbers
    if ($on) {
        $g.AppsVal.Text = "$([int]$st.ClosedCount)"; $g.AppsLbl.Text = 'Apps closed'
        $g.MemVal.Text = ('{0:0.0}' -f ([double]$st.FreedMb / 1024))
        $g.DoneText.Text = if (@($st.Done).Count -or $st.Session) { 'Everything is put back when you stop Game Mode' + $(if ($prefs.autooff) { ' or close Fortnite.' } else { '.' }) } else { '' }
    } else {
        $would = @($SessionApps | Where-Object { $prefs[$_.Key] -and $script:GmRunningPaths -and $script:GmRunningPaths.ContainsKey($_.Key) }).Count
        $g.AppsVal.Text = "$would"; $g.AppsLbl.Text = 'Apps it will close'
        $g.MemVal.Text = '0.0'
        $g.DoneText.Text = 'Start Game turns on Game Mode and launches Fortnite through the Epic Games Launcher. The round button switches Game Mode on or off without launching anything.'
    }
    $g.StepsVal.Text = "$(@('apps', 'plan', 'priority', 'dnd', 'updates', 'dns', 'nvreplay' | Where-Object { $prefs[$_] }).Count)/7"
    Update-GameModeClock
}
function Update-GameModeTools {
    $g = $script:GmUi; if (-not $g) { return }
    foreach ($b in $g.Chips.Children) {
        $sel = $b.Tag -eq $script:GmFilter
        $b.Background = ConvertTo-Brush $(if ($sel) { '#332EE6A6' } else { '#12FFFFFF' })
        $b.BorderBrush = ConvertTo-Brush $(if ($sel) { '#2EE6A6' } else { '#1FFFFFFF' })
        $b.Foreground = [ZdTheme]::Brush($(if ($sel) { '#2EE6A6' } else { '#D3D3D9' }))
    }
    $prefs = Get-GameModePrefs; $sp = Get-SessionPrefs
    $rows = New-Object Collections.ArrayList
    function Head([string]$t) { "<TextBlock Text='$t' FontSize='11' FontWeight='SemiBold' Foreground='#7C7C86' Margin='4,10,0,6'/>" }
    function Row([string]$name, [string]$id, [string]$desc, [string]$iconXaml, [bool]$running) {
        "<Border Background='#0DFFFFFF' CornerRadius='12' Padding='10,9' Margin='0,0,0,6'><Grid>" +
        "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "$iconXaml<StackPanel Grid.Column='1' VerticalAlignment='Center' Margin='12,0,8,0'>" +
        "<StackPanel Orientation='Horizontal'><TextBlock Text='$(Esc $name)' FontSize='13' FontWeight='SemiBold' Foreground='#FFFFFF' TextTrimming='CharacterEllipsis'/>" +
        $(if ($running) { "<Border Background='#262EE6A6' CornerRadius='6' Padding='6,0,6,1' Margin='8,0,0,0' VerticalAlignment='Center'><TextBlock Text='running' FontSize='10.5' Foreground='#2EE6A6'/></Border>" } else { '' }) +
        "</StackPanel>" + $(if ($desc) { "<TextBlock Text='$(Esc $desc)' FontSize='11.5' Foreground='#9A9AA5' TextWrapping='Wrap' Margin='0,2,0,0'/>" } else { '' }) +
        "</StackPanel><ToggleButton x:Name='$id' Grid.Column='2' Style='{DynamicResource Switch}' Width='34' Height='18' VerticalAlignment='Center'/></Grid></Border>"
    }
    function Glyph([int]$code, [string]$tint) { "<Border Width='34' Height='34' CornerRadius='9' Background='$($tint -replace '^#', '#33')'><TextBlock Text='&#x$('{0:X}' -f $code);' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='15' Foreground='$tint' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" }
    $f = $script:GmFilter
    if ($f -in 'all', 'steps') {
        [void]$rows.Add((Head 'BOOST STEPS'))
        foreach ($k in 'apps', 'plan', 'priority', 'dnd', 'updates', 'dns', 'nvreplay') { [void]$rows.Add((Row $GameModeSteps[$k].Name "G_$k" $GmStepInfo[$k].Desc (Glyph $GmStepInfo[$k].Icon $GmStepInfo[$k].Tint) $false)) }
    }
    $shown = @()
    if ($f -in 'all', 'apps') {
        [void]$rows.Add((Head 'APPS IT CLOSES'))
        $shown = @($SessionApps | Where-Object { Test-SessionAppPresent $_ })
        $i = 0
        foreach ($a in $shown) {
            $nm = "$($a.Name)" -replace '^[^A-Za-z0-9]+', ''; $letter = if ($nm) { $nm.Substring(0, 1).ToUpper() } else { '?' }
            $tint = $AppTileColors[[Math]::Abs($a.Name.GetHashCode()) % $AppTileColors.Count]
            $icon = "<Grid Width='34' Height='34'><Border x:Name='GT_$i' CornerRadius='9' Background='$tint'><TextBlock Text='$letter' FontSize='15' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><Image x:Name='GI_$i' Width='30' Height='30' RenderOptions.BitmapScalingMode='HighQuality'/></Grid>"
            [void]$rows.Add((Row $a.Name "S_$($a.Key)" $(if ($a.Pause) { 'Paused, not closed' } else { '' }) $icon ([bool]($script:GmRunningPaths -and $script:GmRunningPaths.ContainsKey($a.Key)))))
            $i++
        }
    }
    if ($f -in 'all', 'auto') {
        [void]$rows.Add((Head 'AUTOMATIC'))
        foreach ($k in 'auto', 'autooff') { [void]$rows.Add((Row $GameModeSteps[$k].Name "G_$k" $GmStepInfo[$k].Desc (Glyph $GmStepInfo[$k].Icon $GmStepInfo[$k].Tint) $false)) }
    }
    $panel = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$($rows -join '')</StackPanel>")
    foreach ($k in $GameModeSteps.Keys) {
        $sw = $panel.FindName("G_$k"); if (-not $sw) { continue }
        $sw.IsChecked = [bool]$prefs[$k]; $sw.Tag = $k
        $sw.Add_Click({ param($s, $e) $p = Get-GameModePrefs; $p[$s.Tag] = [bool]$s.IsChecked; $script:Backup.Custom['gamemodeprefs'] = $p; Save-Backup; Update-GameModePage; Update-GameModeUi })
    }
    for ($i = 0; $i -lt $shown.Count; $i++) {
        $a = $shown[$i]
        $sw = $panel.FindName("S_$($a.Key)"); $sw.IsChecked = [bool]$sp[$a.Key]; $sw.Tag = $a.Key
        $sw.Add_Click({ param($s, $e) $p = Get-SessionPrefs; $p[$s.Tag] = [bool]$s.IsChecked; $script:Backup.Custom['sessionprefs'] = $p; Save-Backup; Update-GameModePage })
        $img = Get-SessionAppIcon $a
        if ($img) { $panel.FindName("GI_$i").Source = $img; $panel.FindName("GT_$i").Visibility = 'Collapsed' }
    }
    $g.Tools.Children.Clear(); [void]$g.Tools.Children.Add($panel)
}

# =============================================================== Tournaments
# Epic's official schedule (fortnite.com) shown in an Edge WebView2 view: it has every cup for the region with its art,
# times in this PC's time zone, and each event's scoring and payouts. Around it: region, a ready check and tips.
$WebViewFiles = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll'
$EventRegions = [ordered]@{ EU = 'Europe'; NAE = 'NA East'; NAC = 'NA Central'; NAW = 'NA West'; OCE = 'Oceania'; BR = 'Brazil'; ASIA = 'Asia'; ME = 'Middle East' }
function Test-WebView2 {
    $dir = $PSScriptRoot
    if (@($WebViewFiles | Where-Object { -not (Test-Path (Join-Path $dir $_)) }).Count) { return $false }
    # the Edge WebView2 Runtime ships with Windows 11 and current Windows 10
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
        $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).pv; if ($v -and $v -ne '0.0.0.0') { return $true }
    }
    $false
}
# Fortnite's own settings remember the region of every recent match; the newest one is where you play
function Get-FortniteRecent {
    $ini = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini'
    if (-not (Test-Path $ini)) { return @() }
    @(Get-Content $ini -ErrorAction SilentlyContinue | Where-Object { $_ -like 'RecentSelections=*' -or $_ -like 'LastPlayedIsland=*' } | ForEach-Object {
        $l = $_
        $region = if ($l -match '\\"regionId\\":\\"([A-Z]+)\\"') { $Matches[1] } elseif ($l -match 'Matchmaking:Region\\":\\"([A-Z]+)\\"') { $Matches[1] } else { $null }
        $link = if ($l -match '\\"LinkId\\":\\"([^\\"]*)\\"') { $Matches[1] } else { '' }
        $ts = if ($l -match 'Timestamp=(\d+)') { [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).LocalDateTime } else { $null }
        [pscustomobject]@{ Region = $region; Link = $link; Time = $ts }
    })
}
function Get-FortniteRegion {
    $r = Get-FortniteRecent | Where-Object { $_.Region -and $EventRegions.Contains($_.Region) } | Sort-Object { if ($_.Time) { $_.Time } else { [datetime]::MinValue } } -Descending | Select-Object -First 1
    if ($r) { $r.Region } else { $null }
}
function Get-EventsRegion { $s = Get-Setting 'eventsregion' $null; if ($s -and $EventRegions.Contains($s)) { $s } else { $d = Get-FortniteRegion; if ($d) { $d } else { 'EU' } } }
# tournament_epicgames_s42_rankedcupsoloreload_eu -> Ranked Cup Solo Reload
$TourneyWords = 'championship', 'evaluation', 'performance', 'qualifier', 'contender', 'zerobuild', 'victory', 'console', 'reload', 'ranked', 'squads', 'finals', 'mobile', 'chance', 'solos', 'trios', 'final', 'blitz', 'arena', 'elite', 'duos', 'solo', 'duo', 'cash', 'fncs', 'last', 'cups', 'cup', 'lcq', 'zb', 'og', 'br'
function Format-TournamentName([string]$Id) {
    $x = ($Id -replace '^tournament_epicgames_s\d+_', '' -replace '_(eu|nae|nac|naw|oce|br|asia|me)$', '').ToLower()
    $parts = foreach ($seg in $x -split '_') {
        $i = 0
        while ($i -lt $seg.Length) {
            $w = $TourneyWords | Where-Object { $seg.Substring($i).StartsWith($_) } | Select-Object -First 1
            if (-not $w) { $j = $i + 1; while ($j -lt $seg.Length -and -not ($TourneyWords | Where-Object { $seg.Substring($j).StartsWith($_) })) { $j++ }; $w = $seg.Substring($i, $j - $i) }
            $i += $w.Length
            switch ($w) { 'zb' { 'Zero Build' } 'zerobuild' { 'Zero Build' } 'fncs' { 'FNCS' } 'og' { 'OG' } 'lcq' { 'Last Chance' } 'br' { 'Battle Royale' } default { (Get-Culture).TextInfo.ToTitleCase($w) } }
        }
    }
    ($parts -join ' ') -replace '\s+', ' '
}
function Get-EventsUrl([string]$Region) { "https://www.fortnite.com/competitive/schedule?region=$Region&lang=en-US" }
# opens a web page in the normal browser, not as administrator
function Open-WebPage([string]$Url) { try { Start-Process explorer.exe -ArgumentList "`"$Url`"" } catch {} }
# Scrolls the schedule to today (or the next day with events): the page lists the whole month from the 1st.
$EventsTodayJs = @'
(function () {
  var n = 0;
  function fmt(d) { return d.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' }); }
  function go() {
    n++;
    var nodes = Array.prototype.filter.call(document.querySelectorAll('main *'), function (e) { return e.children.length === 0; });
    for (var k = 0; k < 21; k++) {
      var d = new Date(); d.setDate(d.getDate() + k);
      var t = fmt(d), el = null;
      for (var i = 0; i < nodes.length; i++) { if (nodes[i].textContent.trim() === t) { el = nodes[i]; break; } }
      if (el) { el.scrollIntoView({ block: 'start' }); window.scrollBy(0, -170); return true; }
    }
    return false;
  }
  var iv = setInterval(function () { if (go() || n > 30) clearInterval(iv); }, 400);
})();
'@
function New-EventsWeb {
    $fallback = {
        param([string]$Why)
        [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' VerticalAlignment='Center' HorizontalAlignment='Center' MaxWidth='440'>
  <TextBlock Text='&#xE7C1;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='34' Foreground='#BF5AF2' HorizontalAlignment='Center'/>
  <TextBlock Text='The tournament schedule opens here' FontSize='17' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center' Margin='0,14,0,0'/>
  <TextBlock Text='$(Esc $Why)' FontSize='12.5' Foreground='#9A9AA5' TextWrapping='Wrap' TextAlignment='Center' Margin='0,6,0,0'/>
</StackPanel>
"@)
    }
    if ($Snapshot) { return (& $fallback 'Epic''s official schedule for your region, with every cup, its art, times in your time zone, scoring and payouts.') }
    if (-not (Test-WebView2)) { return (& $fallback 'This needs the Microsoft Edge WebView2 Runtime, which comes with Windows 11. Use Open in browser above meanwhile.') }
    try {
        foreach ($dll in $WebViewFiles[0..1]) { Add-Type -Path (Join-Path $PSScriptRoot $dll) }
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($PSScriptRoot)
        # the composition control draws inside the window like any other element, so dialogs, the What's new box and
        # toasts show on top of it (the plain WebView2 is a separate window that covers them); it needs Windows 10 1803+
        $wv = try { New-Object Microsoft.Web.WebView2.Wpf.WebView2CompositionControl } catch { New-Object Microsoft.Web.WebView2.Wpf.WebView2 }
        $cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
        $cp.UserDataFolder = Join-Path $DataDir 'webview'
        $wv.CreationProperties = $cp
        $wv.DefaultBackgroundColor = [Drawing.Color]::FromArgb(255, 5, 5, 7)
        $wv.ZoomFactor = 0.8    # the site's desktop layout, with more cups on screen
        $wv.Add_CoreWebView2InitializationCompleted({
            param($s, $e)
            if (-not $e.IsSuccess) { $script:EventsUi.Web.Content = (New-EventsWebError "$($e.InitializationException.Message)"); return }
            $s.CoreWebView2.Settings.AreDevToolsEnabled = $false
            $s.CoreWebView2.Settings.IsStatusBarEnabled = $false
            # links that would open a new window stay in this view
            $s.CoreWebView2.add_NewWindowRequested({ param($c, $a) $a.Handled = $true; $c.Navigate($a.Uri) })
        })
        $wv.Add_NavigationCompleted({
            param($s, $e)
            if ($e.IsSuccess -and "$($s.Source)" -like '*/competitive/schedule*') { [void]$s.ExecuteScriptAsync($EventsTodayJs) }
        })
        $wv.Source = [Uri](Get-EventsUrl (Get-EventsRegion))
        $script:EventsWeb = $wv
        $wv
    } catch { & $fallback "The schedule view could not start ($($_.Exception.Message)). Use Open in browser above." }
}
$ui.Wizard.Add_IsVisibleChanged({
    if ($script:EventsWeb -and $script:EventsWeb -is [Windows.Interop.HwndHost] -or ($script:EventsWeb -and $script:EventsWeb.GetType().Name -eq 'WebView2')) {
        $script:EventsWeb.Visibility = if ($ui.Wizard.IsVisible) { 'Hidden' } else { 'Visible' }
    }
})
function New-EventsWebError([string]$Msg) {
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = "The schedule view could not start: $Msg Use Open in browser above."
    $tb.TextWrapping = 'Wrap'; $tb.Margin = '24'; $tb.Foreground = ConvertTo-Brush '#A1A1A6'; $tb
}
$CompTips = @(
    , @(0xE8A5, '#FFD60A', 'Read the scoring first', 'Click the cup in the schedule: it shows the points for placement and for eliminations. That decides whether you play for kills or for the endgame.')
    , @(0xE916, '#FF9F0A', 'Queue the moment it opens', 'A session is a fixed time window and only matches that start inside it count. A late start costs games.')
    , @(0xE9D9, '#0A84FF', 'Know how many games count', 'Many cups cap the number of matches that score. The details on the event page say how many; plan your session around it.')
    , @(0xE7FC, '#30D158', 'Warm up before, not in game 1', '15 to 20 minutes of aim and edit practice in Creative, so your first scoring match is not your warm-up.')
    , @(0xE707, '#BF5AF2', 'Land where you can loot in peace', 'When placement scores well, a quiet drop that gets you to the endgame every game beats a hot drop that wins half of them.')
    , @(0xE839, '#30B0C7', 'Play your best-ping region', 'Points only count in the region you queue. The ping above shows how far you are from its servers.')
    , @(0xE714, '#FF6482', 'Watch your deaths', 'Fortnite saves your replays (Career > Replays). Watch the last 30 seconds of a bad game at quarter speed; the mistake is usually there.')
    , @(0xE787, '#8E8E93', 'Rest between sessions', 'Stand up, drink water and rest your eyes between rounds. Tired hands and eyes cost more than any setting.')
)
function New-EventsPage {
    $chips = ($EventRegions.Keys | ForEach-Object { "<Button x:Name='R_$_' Content='$_' ToolTip='$($EventRegions[$_])' Cursor='Hand' Margin='0,0,6,6' Padding='12,5' FontSize='12.5'><Button.Template><ControlTemplate TargetType='Button'><Border CornerRadius='13' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' Padding='{TemplateBinding Padding}'><ContentPresenter/></Border></ControlTemplate></Button.Template></Button>" }) -join ''
    $tips = for ($i = 0; $i -lt $CompTips.Count; $i++) {
        $t = $CompTips[$i]
        "<Grid Margin='0,0,0,12'><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
        "<Border Width='30' Height='30' CornerRadius='8' Background='$($t[1] -replace '^#', '#33')' VerticalAlignment='Top'><TextBlock Text='&#x$('{0:X}' -f $t[0]);' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='13' Foreground='$($t[1])' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" +
        "<StackPanel Grid.Column='1' Margin='11,0,0,0'><TextBlock Text='$(Esc $t[2])' FontSize='13' FontWeight='SemiBold' Foreground='#FFFFFF' TextWrapping='Wrap'/><TextBlock Text='$(Esc $t[3])' FontSize='12' Foreground='#9A9AA5' TextWrapping='Wrap' Margin='0,2,0,0' LineHeight='17' LineStackingStrategy='BlockLineHeight'/></StackPanel></Grid>"
    }
    $tz = [TimeZoneInfo]::Local
    $off = $tz.GetUtcOffset((Get-Date)); $offTxt = 'UTC{0}{1:00}:{2:00}' -f $(if ($off -lt [TimeSpan]::Zero) { '-' } else { '+' }), [Math]::Abs($off.Hours), [Math]::Abs($off.Minutes)
    $root = [ZdTheme]::Parse(@"
<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Margin='32,0,32,28'>
  <Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='*'/></Grid.RowDefinitions>
  <Border x:Name='Hero' CornerRadius='22' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1'>
    <Grid>
      <Ellipse Width='560' Height='560' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-200,-330,0,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#55BF5AF2' Offset='0'/><GradientStop Color='#00BF5AF2' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='520' Height='520' HorizontalAlignment='Right' VerticalAlignment='Top' Margin='0,-300,-140,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#44FFD60A' Offset='0'/><GradientStop Color='#00FFD60A' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Grid Margin='28,22,24,20'>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment='Center'>
          <StackPanel Orientation='Horizontal'>
            <TextBlock Text='&#xE7C1;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#FFD60A' FontSize='12' VerticalAlignment='Center' Margin='0,1,8,0'/>
            <TextBlock Text='COMPETITIVE' FontSize='12' FontWeight='Bold' Foreground='#C9C9D1'/>
          </StackPanel>
          <TextBlock Text='FORTNITE EVENTS' FontFamily='Segoe UI Black, Segoe UI' FontWeight='Black' FontSize='40' Foreground='#FFFFFF' Margin='-2,2,0,0'/>
          <TextBlock x:Name='Sub' FontSize='12.5' Foreground='#B8B8C2' TextWrapping='Wrap' Margin='0,4,0,0'/>
        </StackPanel>
        <StackPanel Grid.Column='1' VerticalAlignment='Center' Margin='20,0,0,0'>
          <TextBlock Text='REGION' FontSize='11' FontWeight='Bold' Foreground='#8A8A94' Margin='2,0,0,6'/>
          <WrapPanel x:Name='Regions' MaxWidth='380'>$chips</WrapPanel>
          <StackPanel Orientation='Horizontal' Margin='0,6,0,0'>
            <Button x:Name='Today' Content='Jump to today' Style='{DynamicResource Btn}' Margin='0,0,8,0'/>
            <Button x:Name='Browser' Content='Open in browser' Style='{DynamicResource Btn}'/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
  <Grid Grid.Row='1' Margin='0,16,0,0'>
    <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='350'/></Grid.ColumnDefinitions>
    <Border CornerRadius='18' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Padding='1'>
      <ContentControl x:Name='Web'/>
    </Border>
    <ScrollViewer Grid.Column='1' Style='{DynamicResource OverlayScroll}' VerticalScrollBarVisibility='Auto' Margin='16,0,0,0' Padding='0,0,6,0'>
      <StackPanel>
        <Border CornerRadius='18' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='16,14,16,8' Margin='0,0,0,12'>
          <StackPanel>
            <StackPanel Orientation='Horizontal' Margin='0,0,0,10'>
              <TextBlock Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#30D158' FontSize='13' VerticalAlignment='Center' Margin='0,1,8,0'/>
              <TextBlock Text='Tournament ready check' FontSize='14.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>
            </StackPanel>
            <StackPanel x:Name='Ready'/>
          </StackPanel>
        </Border>
        <Border x:Name='RecentBox' CornerRadius='18' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='16,14,16,10' Margin='0,0,0,12'>
          <StackPanel>
            <StackPanel Orientation='Horizontal' Margin='0,0,0,8'>
              <TextBlock Text='&#xE81C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#0A84FF' FontSize='13' VerticalAlignment='Center' Margin='0,1,8,0'/>
              <TextBlock Text='Your recent cups' FontSize='14.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>
            </StackPanel>
            <StackPanel x:Name='Recent'/>
          </StackPanel>
        </Border>
        <Border CornerRadius='18' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='16,14,16,4'>
          <StackPanel>
            <StackPanel Orientation='Horizontal' Margin='0,0,0,12'>
              <TextBlock Text='&#xE82F;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#FFD60A' FontSize='13' VerticalAlignment='Center' Margin='0,1,8,0'/>
              <TextBlock Text='Competitive tips' FontSize='14.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>
            </StackPanel>
            $($tips -join '')
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</Grid>
"@)
    $g = @{}; foreach ($n in 'Hero', 'Sub', 'Regions', 'Today', 'Browser', 'Web', 'Ready', 'RecentBox', 'Recent') { $g[$n] = $root.FindName($n) }
    $tzName = $tz.DisplayName -replace '^\(UTC[^)]*\)\s*', ''
    $g.TzText = "$offTxt, $tzName"
    $script:EventsUi = $g
    Set-RoundClip $g.Hero 22
    foreach ($k in $EventRegions.Keys) {
        $b = $root.FindName("R_$k"); $b.Tag = $k
        $b.Add_Click({ param($s, $e)
            $script:Backup.Custom['eventsregion'] = $s.Tag; Save-Backup
            Update-EventsHeader
            if ($script:EventsWeb) { $script:EventsWeb.Source = [Uri](Get-EventsUrl $s.Tag) }
            Update-EventsReady
        })
    }
    $g.Today.Add_Click({ if ($script:EventsWeb -and $script:EventsWeb.CoreWebView2) { [void]$script:EventsWeb.ExecuteScriptAsync($EventsTodayJs) } })
    $g.Browser.Add_Click({ Open-WebPage (Get-EventsUrl (Get-EventsRegion)) })
    $g.Web.Content = New-EventsWeb
    Update-EventsHeader
    Update-EventsRecent
    Update-EventsReady
    $script:PageRefresh['Events'] = { Update-EventsReady; Update-EventsRecent }
    $root
}
function Update-EventsHeader {
    $g = $script:EventsUi; if (-not $g) { return }
    $r = Get-EventsRegion; $det = Get-FortniteRegion
    $why = if (Get-Setting 'eventsregion' $null) { 'chosen by you' } elseif ($det) { 'from your Fortnite settings' } else { 'Fortnite has not played a match yet, so Europe is the default' }
    $g.Sub.Text = "Every cup in $($EventRegions[$r]) ($why). Times are in your PC's time zone ($($g.TzText)). Click a cup for its scoring, rules and prizes."
    foreach ($b in $g.Regions.Children) {
        $sel = $b.Tag -eq $r
        $b.Background = ConvertTo-Brush $(if ($sel) { '#33FFD60A' } else { '#12FFFFFF' })
        $b.BorderBrush = ConvertTo-Brush $(if ($sel) { '#FFD60A' } else { '#1FFFFFFF' })
        $b.Foreground = [ZdTheme]::Brush($(if ($sel) { '#FFD60A' } else { '#D3D3D9' }))
    }
}
function Update-EventsRecent {
    $g = $script:EventsUi; if (-not $g) { return }
    $seen = @{}
    $items = @(Get-FortniteRecent | Where-Object { $_.Link -like 'tournament_*' } | Sort-Object Time -Descending | Where-Object { $k = Format-TournamentName $_.Link; if ($seen[$k]) { $false } else { $seen[$k] = $true; $true } } | Select-Object -First 5)
    $g.RecentBox.Visibility = if ($items.Count) { 'Visible' } else { 'Collapsed' }
    $g.Recent.Children.Clear()
    foreach ($it in $items) {
        $ago = if ($it.Time) { $d = (Get-Date) - $it.Time; if ($d.TotalHours -lt 1) { 'just now' } elseif ($d.TotalHours -lt 24) { "$([int]$d.TotalHours) h ago" } else { "$([int]$d.TotalDays) d ago" } } else { '' }
        $row = [ZdTheme]::Parse("<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Margin='0,0,0,6'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><TextBlock Text='$(Esc (Format-TournamentName $it.Link))' FontSize='12.5' Foreground='#E6E6EC' TextTrimming='CharacterEllipsis'/><TextBlock Grid.Column='1' Text='$(Esc "$($it.Region)  ·  $ago")' FontSize='11.5' Foreground='#8A8A94' Margin='10,0,0,0'/></Grid>")
        [void]$g.Recent.Children.Add($row)
    }
}
$EventsPingScript = @'
param($h)
$png = New-Object Net.NetworkInformation.Ping; $ms = @()
for ($i = 0; $i -lt 4; $i++) { try { $x = $png.Send($h, 1000); if ($x.Status -eq 'Success') { $ms += [int]$x.RoundtripTime } } catch {}; Start-Sleep -Milliseconds 150 }
if ($ms.Count) { [int](($ms | Measure-Object -Average).Average) } else { -1 }
'@
# What usually goes wrong before a cup, checked against this PC: ping, Game Mode, Fortnite settings, account security
function Update-EventsReady {
    $g = $script:EventsUi; if (-not $g) { return }
    $rows = New-Object Collections.ArrayList
    $region = Get-EventsRegion; $rName = $EventRegions[$region]
    [void]$rows.Add(@{ Key = 'ping'; State = 'wait'; Title = "Ping to $rName"; Desc = 'Measuring...' })
    $gp = Get-GameModePrefs
    [void]$rows.Add(@{ State = $(if ($gp.auto) { 'ok' } else { 'warn' }); Title = 'Game Mode starts with Fortnite'
                       Desc = $(if ($gp.auto) { 'Background apps are dealt with as soon as you launch.' } else { 'Turn it on so every cup starts with background apps closed.' })
                       Button = $(if (-not $gp.auto) { 'Turn on' }); Act = 'gmauto' })
    $fn = Get-OffTweaks @('vsync', 'reflex', 'fullscreen', 'perfmode', 'fpscap')
    [void]$rows.Add(@{ State = $(if ($fn.Count) { 'warn' } else { 'ok' }); Title = 'Fortnite settings'
                       Desc = $(if ($fn.Count) { "Still to change: $(@($fn | ForEach-Object { $_.Title }) -join ', '). Fortnite must be closed." } else { 'V-Sync, Reflex, fullscreen and frame cap are set for low delay.' })
                       Button = $(if ($fn.Count) { 'Fix' }); Act = 'fn'; Ids = @($fn | ForEach-Object { $_.Id }) })
    $rec = @($Tweaks | Where-Object { $_.Rec -and $_.Toggle -and -not $_.Hidden -and $_.State -eq $false })
    [void]$rows.Add(@{ State = $(if ($rec.Count) { 'warn' } else { 'ok' }); Title = 'Recommended tweaks'
                       Desc = $(if ($rec.Count) { "$($rec.Count) are still off on this PC." } else { 'All switched on.' }); Button = $(if ($rec.Count) { 'Optimize' }); Act = 'optimize' })
    [void]$rows.Add(@{ State = 'info'; Title = 'Two-factor sign-in and rules'
                       Desc = 'Cups need two-factor authentication on your Epic account, and each event''s rules accepted once in the Compete tab.'; Button = 'Epic account'; Act = 'mfa' })
    $x = for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $col = switch ($r.State) { 'ok' { '#30D158' } 'warn' { '#FF9F0A' } 'info' { '#0A84FF' } default { '#8E8E93' } }
        $btn = if ($r.Button) { "<Button x:Name='A_$i' Grid.Column='2' Content='$(Esc $r.Button)' Style='{DynamicResource Btn}' Padding='11,4' FontSize='12' VerticalAlignment='Center' Margin='8,0,0,0'/>" } else { '' }
        "<Grid Margin='0,0,0,10'><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<Ellipse x:Name='D_$i' Width='9' Height='9' Fill='$col' VerticalAlignment='Top' Margin='0,5,10,0'/>" +
        "<StackPanel Grid.Column='1'><TextBlock x:Name='T_$i' Text='$(Esc $r.Title)' FontSize='13' FontWeight='SemiBold' Foreground='#FFFFFF' TextWrapping='Wrap'/><TextBlock x:Name='S_$i' Text='$(Esc $r.Desc)' FontSize='12' Foreground='#9A9AA5' TextWrapping='Wrap' Margin='0,1,0,0' LineHeight='17' LineStackingStrategy='BlockLineHeight'/></StackPanel>$btn</Grid>"
    }
    $panel = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$($x -join '')</StackPanel>")
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $b = $panel.FindName("A_$i"); if (-not $b) { continue }
        $b.Tag = $rows[$i]
        $b.Add_Click({ param($s, $e)
            $r = $s.Tag
            switch ($r.Act) {
                'gmauto' { $p = Get-GameModePrefs; $p.auto = $true; $script:Backup.Custom['gamemodeprefs'] = $p; Save-Backup; Update-GameModeUi; Show-Toast 'Game Mode now switches on by itself when Fortnite starts.' '#30D158' }
                'fn' { Invoke-MatchFix @{ Kind = 'tweaks'; Ids = $r.Ids } }
                'optimize' { $ui.ApplyRec.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
                'mfa' { Open-WebPage 'https://www.epicgames.com/account/password' }
            }
            Update-EventsReady
        })
    }
    $g.Ready.Children.Clear(); [void]$g.Ready.Children.Add($panel)
    # ping in the background
    $hostEntry = $PingHosts | Where-Object { $_.Name -eq $rName } | Select-Object -First 1
    $script:EventsPingPanel = $panel
    if ($hostEntry) {
        Start-Background $EventsPingScript @($hostEntry.Host) {
            param($out, $errs)
            $p = $script:EventsPingPanel; if (-not $p) { return }
            $ms = [int](@($out)[0])
            $d = $p.FindName('D_0'); $sTxt = $p.FindName('S_0'); $tTxt = $p.FindName('T_0')
            if ($ms -lt 0) { $sTxt.Text = 'No reply from the region''s servers. Check your connection.'; $d.Fill = ConvertTo-Brush '#FF453A'; return }
            $tTxt.Text = "Ping to $($EventRegions[(Get-EventsRegion)]): $ms ms"
            $sTxt.Text = if ($ms -le 40) { 'Great for competitive play.' } elseif ($ms -le 70) { 'Playable. A wired connection and the Ping monitor help find spikes.' } else { 'High. If another region is closer to you, it may play better.' }
            $d.Fill = ConvertTo-Brush $(if ($ms -le 40) { '#30D158' } elseif ($ms -le 70) { '#FF9F0A' } else { '#FF453A' })
        }
    }
}

# =============================================================== Active tweaks
# Everything that is switched on right now, grouped like the menu, with when it was turned on and a switch to undo it.
function New-ActivePage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' MaxWidth='1100' HorizontalAlignment='Left'>
  <Border x:Name='Hero' CornerRadius='22' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Margin='0,0,0,16'>
    <Grid>
      <Ellipse Width='520' Height='520' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-180,-300,0,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#5530D158' Offset='0'/><GradientStop Color='#0030D158' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='480' Height='480' HorizontalAlignment='Right' VerticalAlignment='Bottom' Margin='0,0,-160,-300' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#440A84FF' Offset='0'/><GradientStop Color='#000A84FF' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Grid Margin='30,24,26,24'>
        <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment='Center'>
          <TextBlock x:Name='Count' FontSize='64' FontWeight='Black' FontFamily='Segoe UI Black, Segoe UI' Foreground='#30D158' Typography.NumeralAlignment='Tabular'>
            <TextBlock.Effect><DropShadowEffect Color='#30D158' BlurRadius='28' ShadowDepth='0' Opacity='0.5'/></TextBlock.Effect>
          </TextBlock>
          <TextBlock Text='tweaks active' FontSize='13' Foreground='#B8B8C2' Margin='2,-6,0,0'/>
        </StackPanel>
        <WrapPanel Grid.Column='1' VerticalAlignment='Center' Margin='40,0,20,0'>
          <StackPanel Margin='0,0,36,8'><TextBlock x:Name='ByZd' FontSize='26' FontWeight='Bold' Foreground='#FFFFFF'/><TextBlock Text='switched on by ZeroDelay' FontSize='12' Foreground='#9A9AA5'/></StackPanel>
          <StackPanel Margin='0,0,36,8'><TextBlock x:Name='Already' FontSize='26' FontWeight='Bold' Foreground='#FFFFFF'/><TextBlock Text='were already set that way' FontSize='12' Foreground='#9A9AA5'/></StackPanel>
          <StackPanel Margin='0,0,0,8'><TextBlock x:Name='Restart' FontSize='26' FontWeight='Bold' Foreground='#FFFFFF'/><TextBlock Text='need a restart to apply' FontSize='12' Foreground='#9A9AA5'/></StackPanel>
        </WrapPanel>
        <StackPanel Grid.Column='2' VerticalAlignment='Center'>
          <Button x:Name='Undo' Content='Undo everything' Style='{DynamicResource Btn}' Padding='16,8' Margin='0,0,0,8'/>
          <TextBlock Text='Switch any row off to put it back.' FontSize='11.5' Foreground='#8A8A94' HorizontalAlignment='Center'/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
  <StackPanel x:Name='List'/>
</StackPanel>
"@)
    $g = @{}; foreach ($n in 'Hero', 'Count', 'ByZd', 'Already', 'Restart', 'Undo', 'List') { $g[$n] = $root.FindName($n) }
    $script:ActiveUi = $g
    Set-RoundClip $g.Hero 22
    $g.Undo.Add_Click({ $ui.RestoreAll.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); Update-ActivePage })
    $script:PageRefresh['Active'] = { Update-ActivePage }
    Update-ActivePage
    New-PageScroll $root
}
function Update-ActivePage {
    $g = $script:ActiveUi; if (-not $g) { return }
    $on = @($Tweaks | Where-Object { $_.Toggle -and -not $_.Hidden -and $_.State -eq $true })
    $applied = Get-Applied
    # when each one was last turned on, from the change history
    $when = @{}
    foreach ($h in @(Get-History)) { $a = "$(@($h.Action)[0])"; if ($a -eq 'on' -and $h.Id -and -not $when.ContainsKey($h.Id)) { try { $when[$h.Id] = [datetime]$h.Time } catch {} } }
    $byZd = @($on | Where-Object { $applied -contains $_.Id }).Count
    Start-CountUp $g.Count $on.Count '' 700
    $g.ByZd.Text = "$byZd"; $g.Already.Text = "$($on.Count - $byZd)"
    $g.Restart.Text = "$(@($on | Where-Object { $_.Badge -eq 'restart' -and $script:Pending.Items -contains $_.Title }).Count)"
    $g.Undo.IsEnabled = [bool]$byZd
    $g.List.Children.Clear()
    if (-not $on.Count) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'Nothing is switched on yet. Press Optimize to turn on everything recommended for this PC.'
        $tb.Foreground = ConvertTo-Brush '#A1A1A6'; $tb.Margin = '4'; [void]$g.List.Children.Add($tb); return
    }
    $catTitle = @{}; $catIcon = @{}; foreach ($c in $Categories) { $catTitle[$c.Name] = $c.Title; $catIcon[$c.Name] = $c.Icon }
    $order = @{}; for ($i = 0; $i -lt $Categories.Count; $i++) { $order[$Categories[$i].Name] = $i }
    $i = 0
    foreach ($grp in ($on | Group-Object { $_.Cat } | Sort-Object { $order[$_.Name] })) {
        $title = if ($catTitle[$grp.Name]) { $catTitle[$grp.Name] } else { $grp.Name }
        $rows = foreach ($t in $grp.Group) {
            $mine = $applied -contains $t.Id
            $sub = if ($mine -and $when.ContainsKey($t.Id)) { "Turned on by ZeroDelay  ·  $($when[$t.Id].ToString('d MMM, HH:mm'))" } elseif ($mine) { 'Turned on by ZeroDelay' } else { 'Already set this way on this PC' }
            $tag = if ($t.Lat) { "<Border Background='#2630D158' CornerRadius='6' Padding='6,0,6,1' Margin='8,0,0,0' VerticalAlignment='Center'><TextBlock Text='latency' FontSize='10.5' Foreground='#30D158'/></Border>" } else { '' }
            $rs = if ($t.Badge -eq 'restart' -and $script:Pending.Items -contains $t.Title) { "<Border Background='#260A84FF' CornerRadius='6' Padding='6,0,6,1' Margin='6,0,0,0' VerticalAlignment='Center'><TextBlock Text='after restart' FontSize='10.5' Foreground='#0A84FF'/></Border>" } else { '' }
            "<Border Background='#0DFFFFFF' CornerRadius='12' Padding='12,9' Margin='0,0,0,6'><Grid>" +
            "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
            "<Border Width='32' Height='32' CornerRadius='9' Background='$(if ($mine) { '#2630D158' } else { '#14FFFFFF' })'><TextBlock Text='&#x$('{0:X}' -f [int][char]$t.Icon);' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='14' Foreground='$(if ($mine) { '#30D158' } else { '#D1D1D6' })' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" +
            "<StackPanel Grid.Column='1' Margin='12,0,12,0' VerticalAlignment='Center'><StackPanel Orientation='Horizontal'><TextBlock Text='$(Esc $t.Title)' FontSize='13' FontWeight='SemiBold' TextTrimming='CharacterEllipsis'/>$tag$rs</StackPanel>" +
            "<TextBlock Text='$(Esc $sub)' FontSize='11.5' Foreground='#8A8A94' Margin='0,2,0,0'/></StackPanel>" +
            "<ToggleButton x:Name='W_$i' Grid.Column='2' Style='{DynamicResource Switch}' Width='34' Height='18' IsChecked='True' VerticalAlignment='Center' ToolTip='Switch off to put this back'/></Grid></Border>"
            $t.ActiveIdx = $i; $i++
        }
        $sec = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Margin='0,8,0,10'>
  <StackPanel Orientation='Horizontal' Margin='4,0,0,8'>
    <TextBlock Text='&#x$('{0:X}' -f [int][char]$catIcon[$grp.Name]);' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='12' Foreground='#9A9AA5' VerticalAlignment='Center' Margin='0,1,8,0'/>
    <TextBlock Text='$(Esc $title)' FontSize='13' FontWeight='SemiBold' Foreground='#D1D1D6'/>
    <TextBlock Text='$($grp.Count)' FontSize='12' Foreground='#8A8A94' Margin='8,1,0,0'/>
  </StackPanel>
  $($rows -join '')
</StackPanel>
"@)
        foreach ($t in $grp.Group) {
            $sw = $sec.FindName("W_$($t.ActiveIdx)"); $sw.Tag = $t
            $sw.Add_Click({ param($s, $e)
                Switch-Tweak $s.Tag ([bool]$s.IsChecked)
                if ($s.Tag.State -ne $true) { Update-ActivePage }    # it went back: drop the row
            })
        }
        [void]$g.List.Children.Add($sec)
    }
}

# =============================================================== Ping booster page
function New-BoosterPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' MaxWidth='1100' HorizontalAlignment='Left'>
  <Border x:Name='Hero' CornerRadius='22' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Margin='0,0,0,16'>
    <Grid>
      <Ellipse Width='560' Height='560' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-200,-320,0,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#550A84FF' Offset='0'/><GradientStop Color='#000A84FF' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='480' Height='480' HorizontalAlignment='Right' VerticalAlignment='Bottom' Margin='0,0,-150,-300' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#4430D158' Offset='0'/><GradientStop Color='#0030D158' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <StackPanel Margin='30,24,26,22'>
        <StackPanel Orientation='Horizontal'>
          <TextBlock Text='&#xE9F5;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#0A84FF' FontSize='12' VerticalAlignment='Center' Margin='0,1,8,0'/>
          <TextBlock Text='PING BOOSTER' FontSize='12' FontWeight='Bold' Foreground='#C9C9D1'/>
        </StackPanel>
        <StackPanel x:Name='Boosters' Margin='0,10,0,0'/>
        <TextBlock FontSize='12.5' Foreground='#B8B8C2' TextWrapping='Wrap' Margin='0,10,0,0' LineHeight='19' LineStackingStrategy='BlockLineHeight'
                   Text='With the switch on, the booster may change any setting: ZeroDelay keeps its values, never switches them back (not in alerts, auto-fix, Optimize or Game Mode), and lists every change it saw below. ZeroDelay checks every 90 seconds while ZeroDelay is open.'/>
      </StackPanel>
    </Grid>
  </Border>
  <Border CornerRadius='18' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='18,16,18,10' Margin='0,0,0,14'>
    <StackPanel>
      <Grid Margin='0,0,0,10'>
        <StackPanel Orientation='Horizontal'>
          <TextBlock Text='&#xE81C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#0A84FF' FontSize='13' VerticalAlignment='Center' Margin='0,1,8,0'/>
          <TextBlock Text='What it changed' FontSize='14.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>
          <TextBlock x:Name='LogCount' FontSize='12' Foreground='#8A8A94' VerticalAlignment='Center' Margin='10,1,0,0'/>
        </StackPanel>
        <Button x:Name='Check' Content='Check now' Style='{DynamicResource Btn}' HorizontalAlignment='Right' Padding='12,5' FontSize='12'/>
      </Grid>
      <StackPanel x:Name='Log'/>
    </StackPanel>
  </Border>
  <Border CornerRadius='18' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='18,16,18,12'>
    <StackPanel>
      <StackPanel Orientation='Horizontal' Margin='0,0,0,10'>
        <TextBlock Text='&#xE839;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#30D158' FontSize='13' VerticalAlignment='Center' Margin='0,1,8,0'/>
        <TextBlock Text='Network settings right now' FontSize='14.5' FontWeight='SemiBold' Foreground='#FFFFFF'/>
      </StackPanel>
      <StackPanel x:Name='Now'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $g = @{}; foreach ($n in 'Hero', 'Boosters', 'LogCount', 'Check', 'Log', 'Now') { $g[$n] = $root.FindName($n) }
    $script:BoosterUi = $g
    Set-RoundClip $g.Hero 22
    $g.Check.Add_Click({ Invoke-DriftCheck; Invoke-BoosterWatch; Show-Toast 'Checking network settings...' '#A1A1A6' })
    $script:PageRefresh['Booster'] = { Update-BoosterPage; Invoke-BoosterWatch }
    Update-BoosterPage
    Invoke-BoosterWatch
    New-PageScroll $root
}
function Update-BoosterPage {
    $g = $script:BoosterUi; if (-not $g) { return }
    # one row per installed booster: name, running, trust switch
    $g.Boosters.Children.Clear()
    foreach ($k in Get-InstalledBoosters) {
        $run = Test-BoosterRunning $k; $tr = Test-BoosterTrusted $k
        $row = [ZdTheme]::Parse(@"
<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Margin='0,0,0,8'>
  <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
  <StackPanel Orientation='Horizontal' VerticalAlignment='Center'>
    <TextBlock Text='$(Esc $Boosters[$k].Name.ToUpper())' FontFamily='Segoe UI Black, Segoe UI' FontWeight='Black' FontSize='34' Foreground='#FFFFFF'/>
    <Border Background='$(if ($run) { '#2630D158' } else { '#1AFFFFFF' })' CornerRadius='12' Padding='10,3,12,4' Margin='16,4,0,0' VerticalAlignment='Center'>
      <StackPanel Orientation='Horizontal'><Ellipse Width='7' Height='7' Fill='$(if ($run) { '#30D158' } else { '#8E8E93' })' VerticalAlignment='Center' Margin='0,0,7,0'/>
      <TextBlock Text='$(if ($run) { 'Running' } else { 'Not running' })' FontSize='12' FontWeight='SemiBold' Foreground='$(if ($run) { '#30D158' } else { '#C9C9D1' })'/></StackPanel>
    </Border>
  </StackPanel>
  <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'>
    <TextBlock Text='Let it change settings' FontSize='13' Foreground='#E6E6EC' VerticalAlignment='Center' Margin='0,0,10,0'/>
    <ToggleButton x:Name='Trust' Style='{DynamicResource Switch}' IsChecked='$(if ($tr) { 'True' } else { 'False' })' VerticalAlignment='Center'/>
  </StackPanel>
</Grid>
"@)
        $sw = $row.FindName('Trust'); $sw.Tag = $k
        $sw.Add_Click({ param($s, $e)
            Set-BoosterTrusted $s.Tag ([bool]$s.IsChecked)
            Show-Toast $(if ($s.IsChecked) { "$($Boosters[$s.Tag].Name) may change settings; ZeroDelay keeps its changes." } else { "ZeroDelay will alert you again when $($Boosters[$s.Tag].Name) changes one of its settings." }) '#30D158'
        })
        [void]$g.Boosters.Children.Add($row)
    }
    # change log
    $log = @(Get-BoosterLog)
    $g.LogCount.Text = if ($log.Count) { "$($log.Count) change$(if ($log.Count -ne 1) { 's' }), all kept" } else { '' }
    $g.Log.Children.Clear()
    if (-not $log.Count) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.TextWrapping = 'Wrap'; $tb.FontSize = 12.5; $tb.Margin = '2,0,0,6'
        $tb.Text = 'Nothing yet. Changes the booster makes while it runs show up here, with the old and the new value.'
        $tb.Foreground = ConvertTo-Brush '#9A9AA5'; [void]$g.Log.Children.Add($tb)
    } else {
        $x = ($log | Select-Object -First 60 | ForEach-Object {
            $when = try { ([datetime]$_.Time).ToString('d MMM, HH:mm') } catch { '' }
            "<Border Background='#0DFFFFFF' CornerRadius='12' Padding='12,9' Margin='0,0,0,6'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='96'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
            "<TextBlock Text='$(Esc $when)' FontSize='12' Foreground='#9A9AA5' VerticalAlignment='Center'/>" +
            "<StackPanel Grid.Column='1' Margin='0,0,12,0'><TextBlock Text='$(Esc $_.Setting)' FontSize='13' FontWeight='SemiBold' TextWrapping='Wrap'/>" +
            "<TextBlock FontSize='12' Foreground='#9A9AA5' TextWrapping='Wrap' Margin='0,2,0,0'><Run Text='$(Esc $_.Before)'/><Run Text='  →  ' Foreground='#0A84FF'/><Run Text='$(Esc $_.After)' Foreground='#E6E6EC'/><Run Text='$(Esc "   ·   by $($_.Booster)")'/></TextBlock></StackPanel>" +
            "<Border Grid.Column='2' Background='#2630D158' CornerRadius='8' Padding='8,2,9,3' VerticalAlignment='Center'><TextBlock Text='kept' FontSize='11.5' FontWeight='SemiBold' Foreground='#30D158'/></Border></Grid></Border>"
        }) -join ''
        [void]$g.Log.Children.Add([ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>$x</StackPanel>"))
    }
    # current values from the last snapshot
    $snap = ConvertTo-OrderedTable $script:Backup.Custom['boostersnap']
    $g.Now.Children.Clear()
    if (-not $snap.Count) { $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'Reading...'; $tb.Foreground = ConvertTo-Brush '#9A9AA5'; [void]$g.Now.Children.Add($tb); return }
    $recent = @{}; foreach ($e in $log) { if (-not $recent.ContainsKey($e.Setting)) { $recent[$e.Setting] = $true } }
    $x = ($snap.Keys | ForEach-Object {
        $hi = $recent.ContainsKey($_)
        "<Grid Margin='0,0,0,5'><Grid.ColumnDefinitions><ColumnDefinition Width='300'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
        "<TextBlock Text='$(Esc $_)' FontSize='12.5' Foreground='#9A9AA5' TextTrimming='CharacterEllipsis'/>" +
        "<TextBlock Grid.Column='1' Text='$(Esc "$($snap[$_])$(if ($hi) { '   (changed by the booster)' })")' FontSize='12.5' Foreground='$(if ($hi) { '#0A84FF' } else { '#E6E6EC' })' TextWrapping='Wrap'/></Grid>"
    }) -join ''
    [void]$g.Now.Children.Add([ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>$x</StackPanel>"))
}

# =============================================================== FreeSync / G-SYNC Compatible
# Monitors with a variable refresh range (read from their EDID), how they are connected, and what that means here.
# G-SYNC switched on in the NVIDIA App but the driver is not using it yet: remember it until a restart, then confirm.
$GsyncPendingTitle = 'G-SYNC Compatible (NVIDIA)'
function Add-GsyncPending {
    $script:VrrMonitors = $null
    if (Test-MainVrrOn) { Show-Toast 'G-SYNC Compatible is already working on your main screen. No restart needed.' '#30D158'; return }
    Add-PendingRestart @{ Title = $GsyncPendingTitle; Badge = 'restart'; Live = { Test-MainVrrOn } }
    Update-RestartBar
    Show-Toast 'Added to the restart banner. After you restart, ZeroDelay checks that the driver uses G-SYNC.' '#0A84FF'
}
function Get-VrrMonitors {
    if ($null -ne $script:VrrMonitors) { return $script:VrrMonitors }
    $list = @()
    try {
        $conn = @{}; foreach ($c in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop)) { $conn[$c.InstanceName] = [int64]$c.VideoOutputTechnology }
        foreach ($m in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop)) {
            $inst = $m.InstanceName -replace '_\d+$', ''
            $name = (-join ($m.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ })).Trim()
            $e = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$inst\Device Parameters" -Name EDID -ErrorAction SilentlyContinue).EDID
            $min = $null; $max = $null
            if ($e) { for ($d = 54; $d -le 108; $d += 18) { if ($e[$d] -eq 0 -and $e[$d + 1] -eq 0 -and $e[$d + 3] -eq 0xFD) { $min = [int]$e[$d + 5]; $max = [int]$e[$d + 6] } } }
            $vot = $conn[$m.InstanceName]
            $cable = switch ($vot) { 5 { 'HDMI' } 10 { 'DisplayPort' } 11 { 'DisplayPort' } 4 { 'DVI' } 0 { 'VGA' } 15 { 'USB-C' } default { 'other' } }
            # a real VRR range: at least 30 Hz wide and above 60 Hz
            if ($max -and $min -and $max -gt 60 -and ($max - $min) -ge 30) {
                $gdi = $null; $main = $false
                foreach ($row in [DisplayMap]::List()) { $f = $row -split '\|'; if ($f[1] -ieq $inst) { $gdi = $f[0]; $main = $f[2] -eq '1' } }
                $list += [pscustomobject]@{ Name = $(if ($name) { $name } else { 'Monitor' }); Instance = $inst; Min = $min; Max = $max; Cable = $cable; Gdi = $gdi; Main = $main }
            }
        }
    } catch {}
    $script:VrrMonitors = @($list | Sort-Object { -not $_.Main })
    $script:VrrMonitors
}
# the driver's answer for one monitor: 'on', 'off' (it can, G-SYNC is off for it), 'blocked' (driver sees no VRR), or $null
function Get-MonitorVrr($m) {
    if (-not (Test-NvAvailable) -or -not $m.Gdi) { return $null }
    $f = [NvDrs]::VrrFlagsFor($m.Gdi)
    if ($f -lt 0) { $null } elseif ($f -band 1) { 'on' } elseif ($f -band 2) { 'off' } else { 'blocked' }
}
# G-SYNC on for the main screen right now (used by the restart banner to confirm it after a restart)
function Test-MainVrrOn { $m = @(Get-VrrMonitors) | Where-Object { $_.Main } | Select-Object -First 1; if ($m) { (Get-MonitorVrr $m) -eq 'on' } else { Test-VrrDisplayOn } }
function New-SyncPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' MaxWidth='1100' HorizontalAlignment='Left'>
  <Border x:Name='Hero' CornerRadius='22' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Margin='0,0,0,16'>
    <Grid>
      <Ellipse Width='560' Height='560' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-200,-320,0,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#55FF3B30' Offset='0'/><GradientStop Color='#00FF3B30' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='500' Height='500' HorizontalAlignment='Right' VerticalAlignment='Bottom' Margin='0,0,-160,-300' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#4476B900' Offset='0'/><GradientStop Color='#0076B900' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <StackPanel Margin='30,24,26,24'>
        <StackPanel Orientation='Horizontal'>
          <TextBlock Text='&#xE7F4;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' Foreground='#FF6482' FontSize='12' VerticalAlignment='Center' Margin='0,1,8,0'/>
          <TextBlock Text='VARIABLE REFRESH RATE' FontSize='12' FontWeight='Bold' Foreground='#C9C9D1'/>
        </StackPanel>
        <StackPanel Orientation='Horizontal' Margin='0,4,0,0'>
          <TextBlock Text='FREESYNC' FontFamily='Segoe UI Black, Segoe UI' FontWeight='Black' FontSize='44' Foreground='#FFFFFF'/>
          <Border x:Name='StatePill' CornerRadius='13' Padding='11,4,13,5' Margin='18,6,0,0' VerticalAlignment='Center'>
            <StackPanel Orientation='Horizontal'><Ellipse x:Name='StateDot' Width='8' Height='8' VerticalAlignment='Center' Margin='0,0,8,0'/><TextBlock x:Name='StateText' FontSize='13' FontWeight='SemiBold'/></StackPanel>
          </Border>
        </StackPanel>
        <TextBlock x:Name='StateSub' FontSize='12.5' Foreground='#B8B8C2' TextWrapping='Wrap' Margin='0,6,0,0' LineHeight='19' LineStackingStrategy='BlockLineHeight'/>
      </StackPanel>
    </Grid>
  </Border>
  <StackPanel x:Name='Monitors'/>
  <Border CornerRadius='18' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='18,16,18,8' Margin='0,4,0,0'>
    <StackPanel>
      <TextBlock Text='Settings' FontSize='14.5' FontWeight='SemiBold' Foreground='#FFFFFF' Margin='0,0,0,12'/>
      <StackPanel x:Name='Steps'/>
    </StackPanel>
  </Border>
</StackPanel>
"@)
    $g = @{}; foreach ($n in 'Hero', 'StatePill', 'StateDot', 'StateText', 'StateSub', 'Monitors', 'Steps') { $g[$n] = $root.FindName($n) }
    $script:SyncUi = $g
    Set-RoundClip $g.Hero 22
    $script:PageRefresh['Sync'] = { $script:VrrMonitors = $null; Update-SyncPage }
    Update-SyncPage
    New-PageScroll $root
}
function Update-SyncPage {
    $g = $script:SyncUi; if (-not $g) { return }
    $mons = @(Get-VrrMonitors)
    $nv = Test-NvAvailable
    $amd = [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'VEN_1002' -and $_.Name -notmatch 'Graphics$' })
    $mainMon = $mons | Where-Object { $_.Main } | Select-Object -First 1
    $on = if ($nv) { if ($mainMon) { (Get-MonitorVrr $mainMon) -eq 'on' } else { Test-VrrDisplayOn } } else { $false }
    $curHz = [NativeDisplay]::CurrentHz(); $maxHz = [NativeDisplay]::MaxHz()
    $good = '#30D158'; $warn = '#FF9F0A'; $bad = '#FF453A'
    $g.StatePill.Background = ConvertTo-Brush $(if ($on) { '#2630D158' } else { '#26FF9F0A' })
    $g.StateDot.Fill = ConvertTo-Brush $(if ($on) { $good } else { $warn })
    $g.StateText.Text = if ($nv) { if ($on) { 'G-SYNC Compatible on' } else { 'Not active on your main screen' } } elseif ($amd) { 'Set in AMD Software' } else { 'Check your GPU settings' }
    $g.StateText.Foreground = ConvertTo-Brush $(if ($on) { $good } else { $warn })
    $g.StateSub.Text = if ($nv) { "On an NVIDIA card FreeSync is called G-SYNC Compatible. It needs DisplayPort (or HDMI 2.1), the monitor's own FreeSync / Adaptive-Sync option on, and the NVIDIA switch on. Your main screen runs at $curHz Hz." }
                       else { "Turn FreeSync on in the monitor's menu and in AMD Software > Gaming > Display. Your main screen runs at $curHz Hz." }
    # one card per monitor
    $g.Monitors.Children.Clear()
    foreach ($m in $mons) {
        $drv = Get-MonitorVrr $m
        # the NVIDIA driver knows best; without it, fall back to what the cable allows
        $state = switch ($drv) {
            'on'      { @($good, 'G-SYNC Compatible is on for this monitor: the NVIDIA driver is using it.', 'G-SYNC on') }
            'off'     { @($warn, 'This monitor can do it, but G-SYNC is off for it. In the NVIDIA App > System > Displays, pick this monitor and switch G-SYNC on.', 'Off for this monitor') }
            'blocked' { @($bad, "The NVIDIA driver does not see FreeSync on this monitor right now. Check the monitor menu: Adaptive-Sync / FreeSync on, and motion-blur reduction (MPRT, ELMB, Aim Stabilizer) and any HDR mode off, as they switch FreeSync off. If you just changed it, restart the PC.$(if ($m.Cable -eq 'HDMI') { ' Over HDMI, DisplayPort works more often.' })", 'Not seen by driver') }
            default   { if ($m.Cable -eq 'DisplayPort') { @($good, $(if ($nv) { 'Supported over DisplayPort.' } else { 'Supported. Turn it on in AMD Software.' }), 'Can use FreeSync') } else { @($warn, "Connected by $($m.Cable): VRR may need DisplayPort on this graphics card.", 'Check the cable') } }
        }
        $row = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' CornerRadius='16' Background='#B8101012' BorderBrush='#24FFFFFF' BorderThickness='1' Padding='18,14' Margin='0,0,0,10'>
  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <Border Width='40' Height='40' CornerRadius='11' Background='#22FFFFFF' VerticalAlignment='Top'><TextBlock Text='&#xE7F4;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='17' Foreground='#E6E6EC' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>
    <StackPanel Grid.Column='1' Margin='14,0,14,0'>
      <StackPanel Orientation='Horizontal'><TextBlock Text='$(Esc $m.Name)' FontSize='15' FontWeight='SemiBold' Foreground='#FFFFFF'/>$(if ($m.Main) { "<Border Background='#260A84FF' CornerRadius='6' Padding='7,1,7,2' Margin='10,0,0,0' VerticalAlignment='Center'><TextBlock Text='main screen' FontSize='11' Foreground='#0A84FF'/></Border>" })</StackPanel>
      <TextBlock Text='$(Esc "Variable refresh $($m.Min) to $($m.Max) Hz  ·  connected by $($m.Cable)")' FontSize='12.5' Foreground='#9A9AA5' Margin='0,2,0,0'/>
      <TextBlock Text='$(Esc $state[1])' FontSize='12.5' Foreground='$($state[0])' TextWrapping='Wrap' Margin='0,6,0,0'/>
    </StackPanel>
    <Border Grid.Column='2' Background='$($state[0] -replace '^#', '#26')' CornerRadius='10' Padding='10,3,12,4' VerticalAlignment='Top'>
      <TextBlock Text='$(Esc $state[2])' FontSize='12' FontWeight='SemiBold' Foreground='$($state[0])'/>
    </Border>
  </Grid>
</Border>
"@)
        [void]$g.Monitors.Children.Add($row)
    }
    # the settings, in the order to do them
    $vrr = Find-Tweak 'vrr'
    $capOk = $nv -and $on
    $steps = @(
        @{ Done = ($curHz -ge $maxHz -and $maxHz -gt 0); Title = "Run at the highest refresh rate ($maxHz Hz)"; Desc = $(if ($curHz -ge $maxHz) { "Your main screen already runs at $curHz Hz." } else { "Your main screen runs at $curHz Hz but can do $maxHz Hz." }); Btn = $(if ($curHz -lt $maxHz) { 'Set' }); Act = 'hz' }
        @{ Done = $false; Info = $true; Title = 'Turn on FreeSync / Adaptive-Sync in the monitor menu'; Desc = 'Use the buttons on the monitor. Many monitors ship with it off.' }
        @{ Done = [bool]$on; Info = -not $nv; Title = $(if ($nv) { 'Turn on G-SYNC Compatible in the NVIDIA App' } else { 'Turn on FreeSync in AMD Software' }); Btn2 = $(if ($nv -and -not $on) { 'I turned it on' }); Act2 = 'gsyncpending'; Desc = $(if ($nv) { $(if ($on) { 'On for your main screen.' } else { 'NVIDIA App > System > Displays > G-SYNC: on, for full screen and windowed mode. ZeroDelay cannot switch this for you; this button opens the NVIDIA App.' }) } else { 'AMD Software > Gaming > Display > AMD FreeSync.' }); Btn = $(if ($nv -and -not $on -and (Test-Path $NvAppExe)) { 'Open NVIDIA App' }); Act = 'nvapp' }
        @{ Done = ($vrr -and $vrr.State -eq $true); Title = 'Windows variable refresh rate'; Desc = 'Lets borderless and windowed games use VRR too.'; Switch = [bool]$vrr; Act = 'vrr' }
        @{ Done = $false; Title = 'Keep FPS inside the range'; Desc = $(if ($capOk) { 'The Tear-free preset caps Fortnite a few FPS under your refresh rate and turns on Reflex and driver V-Sync, so frames always land inside the FreeSync range: no tearing and almost no added delay. Fortnite must be closed.' } else { 'Once G-SYNC Compatible is on, the Tear-free preset caps Fortnite just under your refresh rate so frames stay inside the FreeSync range.' }); Btn = $(if ($capOk) { 'Tear-free preset' }); Act = 'tearfree' }
    )
    $x = for ($i = 0; $i -lt $steps.Count; $i++) {
        $st = $steps[$i]
        $dot = if ($st.Done) { "<Border Width='22' Height='22' CornerRadius='11' Background='#2630D158'><TextBlock Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='11' Foreground='#30D158' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" }
               else { "<Border Width='22' Height='22' CornerRadius='11' Background='#1AFFFFFF'><TextBlock Text='$($i + 1)' FontSize='11.5' FontWeight='SemiBold' Foreground='#E6E6EC' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" }
        $right = if ($st.Switch) { "<ToggleButton x:Name='V_$i' Grid.Column='2' Style='{DynamicResource Switch}' IsChecked='$(if ($st.Done) { 'True' } else { 'False' })' VerticalAlignment='Center'/>" }
                 elseif ($st.Btn -or $st.Btn2) { "<StackPanel Grid.Column='2' Orientation='Horizontal' VerticalAlignment='Center'>" + $(if ($st.Btn2) { "<Button x:Name='C_$i' Content='$(Esc $st.Btn2)' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12' Margin='0,0,6,0' ToolTip='The driver does not use it yet: ZeroDelay adds it to the restart banner and checks it after the restart.'/>" } else { '' }) + $(if ($st.Btn) { "<Button x:Name='B_$i' Content='$(Esc $st.Btn)' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12'/>" } else { '' }) + "</StackPanel>" } else { '' }
        "<Grid Margin='0,0,0,12'><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>$dot" +
        "<StackPanel Grid.Column='1' Margin='12,0,12,0'><TextBlock Text='$(Esc $st.Title)' FontSize='13' FontWeight='SemiBold' Foreground='#FFFFFF' TextWrapping='Wrap'/><TextBlock Text='$(Esc $st.Desc)' FontSize='12' Foreground='#9A9AA5' TextWrapping='Wrap' Margin='0,2,0,0' LineHeight='17' LineStackingStrategy='BlockLineHeight'/></StackPanel>$right</Grid>"
    }
    $panel = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$($x -join '')</StackPanel>")
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $c = $panel.FindName("C_$i")
        if ($c) { $c.Tag = $steps[$i].Act2; $c.Add_Click({ param($s, $e) Add-GsyncPending; Update-SyncPage }) }
        $b = $panel.FindName("B_$i"); if (-not $b) { $b = $panel.FindName("V_$i") }; if (-not $b) { continue }
        $b.Tag = $steps[$i].Act
        $b.Add_Click({ param($s, $e)
            try {
                switch ($s.Tag) {
                    'hz' { Switch-Tweak (Find-Tweak 'refreshrate') $true }
                    'nvapp' { Start-Process explorer.exe -ArgumentList "`"$NvAppExe`""; Show-Toast 'Opening the NVIDIA App: System > Displays > G-SYNC. Come back here afterwards.' '#0A84FF' }
                    'vrr' { Switch-Tweak (Find-Tweak 'vrr') ([bool]$s.IsChecked) }
                    'tearfree' { $window.Cursor = [Windows.Input.Cursors]::Wait; try { Show-Toast (Invoke-NvTearFree) '#30D158' } finally { $window.Cursor = $null } }
                }
            } catch { Show-Toast $_.Exception.Message '#FF9F0A' }
            Update-SyncPage
        })
    }
    $g.Steps.Children.Clear(); [void]$g.Steps.Children.Add($panel)
}

# =============================================================== Debloat
# Apps that come with Windows or with the PC and most people never use. Nothing is ticked: you pick what goes.
$BloatInfo = [ordered]@{
    'Clipchamp.Clipchamp' = 'Clipchamp video editor'; 'Microsoft.BingNews' = 'News app with ads and feeds'; 'Microsoft.BingWeather' = 'Weather app'
    'Microsoft.BingSearch' = 'Bing search in the taskbar'; 'Microsoft.BingFinance' = 'Money app'; 'Microsoft.BingSports' = 'Sports app'
    'Microsoft.GetHelp' = 'Get Help (Microsoft support chat)'; 'Microsoft.Getstarted' = 'Tips app'; 'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire with ads'
    'Microsoft.People' = 'People (contacts)'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate (office automation)'; 'Microsoft.Todos' = 'Microsoft To Do'
    'Microsoft.WindowsFeedbackHub' = 'Feedback Hub'; 'Microsoft.ZuneMusic' = 'Media Player (old Groove Music)'; 'Microsoft.ZuneVideo' = 'Movies & TV'
    'Microsoft.MicrosoftOfficeHub' = 'Microsoft 365 app (Office ads and launcher)'; 'Microsoft.549981C3F5F10' = 'Cortana'; 'MicrosoftCorporationII.QuickAssist' = 'Quick Assist (remote help)'
    'Microsoft.WindowsMaps' = 'Maps'; 'Microsoft.Copilot' = 'Copilot app'; 'Microsoft.OutlookForWindows' = 'New Outlook'; 'MicrosoftTeams' = 'Teams (personal)'
    'MSTeams' = 'Teams'; 'Microsoft.MixedReality.Portal' = 'Mixed Reality Portal (VR headsets)'; 'Microsoft.SkypeApp' = 'Skype'; 'Microsoft.YourPhone' = 'Phone Link (runs in the background)'
    'Microsoft.Windows.DevHome' = 'Dev Home (for programmers)'; 'Microsoft.WindowsAlarms' = 'Clock and alarms'; 'Microsoft.WindowsSoundRecorder' = 'Sound Recorder'
    'Microsoft.MicrosoftStickyNotes' = 'Sticky Notes'; 'Microsoft.Windows.Ai.Copilot.Provider' = 'Copilot provider'; 'MicrosoftWindows.CrossDevice' = 'Cross-device experience (phone linking, runs in the background)'
    'Microsoft.Office.OneNote' = 'OneNote for Windows 10'; 'Microsoft.WindowsCamera' = 'Camera'; 'Microsoft.MSPaint' = 'Paint 3D'; 'Microsoft.Microsoft3DViewer' = '3D Viewer'
    'Microsoft.Wallet' = 'Wallet'; 'Microsoft.Messaging' = 'Messaging'; 'Microsoft.OneConnect' = 'Mobile Plans'; 'Microsoft.Print3D' = 'Print 3D'
}
# third-party apps that ship on new PCs or come bundled with other installers
$BloatStoreRx = '^(king\.com|Disney|Facebook|AmazonVideo|BytedancePte|5A894077\.McAfee|7EE7776C\.LinkedIn|SpotifyAB\.SpotifyMusic|Duolingo|PandoraMediaInc|AdobeSystemsIncorporated\.AdobePhotoshopExpress|ROBLOXCORPORATION|Netflix|Hulu|E046963F\.LenovoCompanion|AD2F1837\.HP|DellInc\.)'
$BloatDesktopRx = '(?i)^(McAfee|Norton|Avast|AVG |WildTangent|ExpressVPN|Booking\.com|Dropbox (Promotion|Offer)|Candy Crush|HP (Wolf|Sure|Support Assistant|Documentation)|Dell (SupportAssist|Digital Delivery|Customer Connect)|Lenovo (Vantage Service|Welcome)|Acer (Care|Jumpstart)|ASUS (GiftBox|Welcome)|Microsoft 365 - |Microsoft OneNote - |Opera Browser Assistant|CCleaner|Driver Booster|IObit|Avira|ESET .*Trial|Bonjour)'
$BloatDesktopInfo = [ordered]@{ 'McAfee' = 'Antivirus trial that came with the PC: Windows Security already protects you'; 'Norton' = 'Antivirus trial: Windows Security already protects you'
    'Avast' = 'Third-party antivirus'; 'AVG ' = 'Third-party antivirus'; 'Avira' = 'Third-party antivirus'; 'WildTangent' = 'Preinstalled games store'; 'ExpressVPN' = 'VPN trial'
    'Booking.com' = 'Travel site shortcut'; 'Dropbox' = 'Dropbox trial offer'; 'Candy Crush' = 'Preinstalled game'; 'HP ' = 'HP extras that came with the PC'
    'Dell ' = 'Dell extras that came with the PC'; 'Lenovo ' = 'Lenovo extras that came with the PC'; 'Acer ' = 'Acer extras that came with the PC'; 'ASUS ' = 'ASUS extras that came with the PC'
    'Microsoft 365 - ' = 'Preinstalled Office trial (remove only if you do not use Word, Excel or Outlook)'; 'Microsoft OneNote - ' = 'Preinstalled OneNote'
    'Opera Browser Assistant' = 'Opera helper that runs at startup'; 'CCleaner' = 'Cleaner that bundles extra offers'; 'Driver Booster' = 'Driver updater that bundles offers'; 'IObit' = 'IObit utilities (bundled offers)'
    'ESET' = 'Antivirus trial'; 'Bonjour' = 'Apple network service left behind by iTunes and others' }
function Get-BloatList {
    $apps = @($script:AppsData)
    @(foreach ($a in $apps) {
        if ($a.Kind -eq 'store') {
            $why = if ($BloatInfo.Contains($a.Id)) { $BloatInfo[$a.Id] } elseif ($a.Id -match $BloatStoreRx) { 'Promo app that came with Windows or the PC' } else { $null }
            if ($why) { [pscustomobject]@{ App = $a; Why = $why; Group = $(if ($a.Id -match $BloatStoreRx) { 'Promo apps' } else { 'Windows extras' }); Note = 'Removed for your account. You can get it back from the Microsoft Store.' } }
        } elseif ($a.Name -match $BloatDesktopRx) {
            $k = $BloatDesktopInfo.Keys | Where-Object { $a.Name -like "$_*" } | Select-Object -First 1
            [pscustomobject]@{ App = $a; Why = $(if ($k) { $BloatDesktopInfo[$k] } else { 'Came with the PC' }); Group = 'Trials and PC extras'; Note = 'Its own uninstaller opens: follow its steps.' }
        }
    })
}
function New-DebloatPage {
    $root = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' MaxWidth='1100' HorizontalAlignment='Left'>
  <Border x:Name='Hero' CornerRadius='22' Background='#050507' BorderBrush='#22FFFFFF' BorderThickness='1' Margin='0,0,0,16'>
    <Grid>
      <Ellipse Width='560' Height='560' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-200,-320,0,0' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#55FF9F0A' Offset='0'/><GradientStop Color='#00FF9F0A' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width='500' Height='500' HorizontalAlignment='Right' VerticalAlignment='Bottom' Margin='0,0,-160,-300' IsHitTestVisible='False'>
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color='#44FF453A' Offset='0'/><GradientStop Color='#00FF453A' Offset='1'/></RadialGradientBrush></Ellipse.Fill>
      </Ellipse>
      <Grid Margin='30,24,26,24'>
        <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text='DEBLOAT' FontFamily='Segoe UI Black, Segoe UI' FontWeight='Black' FontSize='44' Foreground='#FFFFFF'/>
          <TextBlock x:Name='Sub' FontSize='12.5' Foreground='#B8B8C2' TextWrapping='Wrap' Margin='0,4,0,0' LineHeight='19' LineStackingStrategy='BlockLineHeight'/>
        </StackPanel>
        <StackPanel Grid.Column='1' VerticalAlignment='Center' Margin='20,0,0,0'>
          <Button x:Name='Go' Content='Remove selected' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' Padding='18,9' FontSize='14' IsEnabled='False'/>
          <Button x:Name='Rescan' Content='Scan again' Style='{DynamicResource Btn}' Margin='0,8,0,0'/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
  <StackPanel x:Name='List'/>
</StackPanel>
"@)
    $g = @{}; foreach ($n in 'Hero', 'Sub', 'Go', 'Rescan', 'List') { $g[$n] = $root.FindName($n) }
    $script:DebloatUi = $g
    Set-RoundClip $g.Hero 22
    $g.Rescan.Add_Click({ Start-DebloatScan })
    $g.Go.Add_Click({ Invoke-Debloat })
    $script:PageRefresh['Debloat'] = { if ($null -eq $script:AppsData) { Start-DebloatScan } else { Update-DebloatPage } }
    if ($null -eq $script:AppsData) { Start-DebloatScan } else { Update-DebloatPage }
    New-PageScroll $root
}
function Start-DebloatScan {
    $g = $script:DebloatUi; if ($g) { $g.Sub.Text = 'Looking through your apps...'; $g.List.Children.Clear() }
    Start-Background $AppScanScript.ToString() @(@{ Protected = $StoreProtected; Bloat = $StoreBloat }) {
        param($out, $errs)
        $script:AppsData = @($out | Where-Object { $_ })
        if ($script:DebloatUi) { Update-DebloatPage }
        if ($script:AppsUi) { Update-AppsList }
    }
}
function Update-DebloatPage {
    $g = $script:DebloatUi; if (-not $g) { return }
    $items = @(Get-BloatList)
    $script:BloatItems = $items
    $g.Sub.Text = if ($items.Count) { "Found $($items.Count) app$(if ($items.Count -ne 1) { 's' }) that came with Windows or the PC and that most people never use. Nothing is ticked: pick only what you want gone. Windows itself, the Store, Xbox and anything Fortnite needs are never listed." }
                  else { 'Nothing to remove: no preinstalled extras found on this PC.' }
    $g.List.Children.Clear()
    $i = 0
    foreach ($grp in ($items | Group-Object Group)) {
        $rows = foreach ($b in $grp.Group) {
            $b | Add-Member -NotePropertyName Idx -NotePropertyValue $i -Force; $i++
            $a = $b.App
            $nm = "$($a.Name)".Trim() -replace '^[^A-Za-z0-9]+', ''; $letter = if ($nm) { Esc $nm.Substring(0, 1).ToUpper() } else { '?' }
            $tint = $AppTileColors[[Math]::Abs(("$($a.Name)".GetHashCode())) % $AppTileColors.Count]
            "<Border Background='#0DFFFFFF' CornerRadius='12' Padding='12,9' Margin='0,0,0,6'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
            "<CheckBox x:Name='K_$($b.Idx)' VerticalAlignment='Center' Margin='0,0,12,0'/>" +
            "<Grid Grid.Column='1' Width='34' Height='34' Margin='0,0,12,0'><Border x:Name='T_$($b.Idx)' CornerRadius='9' Background='$tint'><TextBlock Text='$letter' FontSize='15' FontWeight='SemiBold' Foreground='#FFFFFF' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><Image x:Name='I_$($b.Idx)' Width='30' Height='30' RenderOptions.BitmapScalingMode='HighQuality'/></Grid>" +
            "<StackPanel Grid.Column='2' VerticalAlignment='Center'><TextBlock Text='$(Esc $a.Name)' FontSize='13' FontWeight='SemiBold' TextTrimming='CharacterEllipsis'/>" +
            "<TextBlock Text='$(Esc "$($b.Why)  ·  $($b.Note)")' FontSize='11.5' Foreground='#9A9AA5' TextWrapping='Wrap' Margin='0,2,0,0'/></StackPanel>" +
            "<TextBlock Grid.Column='3' Text='$(if ($a.SizeMb) { Format-Size ($a.SizeMb * 1MB) })' FontSize='12' Foreground='#9A9AA5' VerticalAlignment='Center' Margin='12,0,0,0'/></Grid></Border>"
        }
        $sec = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Margin='0,4,0,10'><TextBlock Text='$(Esc $grp.Name)' FontSize='13' FontWeight='SemiBold' Foreground='#D1D1D6' Margin='4,0,0,8'/>$($rows -join '')</StackPanel>")
        foreach ($b in $grp.Group) {
            $img = Get-AppIconSource $b.App
            if ($img) { $sec.FindName("I_$($b.Idx)").Source = $img; $sec.FindName("T_$($b.Idx)").Visibility = 'Collapsed' }
            $cb = $sec.FindName("K_$($b.Idx)"); $b | Add-Member -NotePropertyName Box -NotePropertyValue $cb -Force
            $cb.Add_Click({ Update-DebloatButton })
        }
        [void]$g.List.Children.Add($sec)
    }
    Update-DebloatButton
}
function Update-DebloatButton {
    $n = @($script:BloatItems | Where-Object { $_.Box.IsChecked }).Count
    $script:DebloatUi.Go.Content = if ($n) { "Remove $n selected" } else { 'Remove selected' }
    $script:DebloatUi.Go.IsEnabled = $n -gt 0
}
function Invoke-Debloat {
    $pick = @($script:BloatItems | Where-Object { $_.Box.IsChecked })
    if (-not $pick.Count) { return }
    $names = ($pick | ForEach-Object { "  •  $($_.App.Name)" }) -join "`n"
    $r = (Show-ZdDialog ("Remove these?`n`n$names`n`nStore apps are removed for your account and can be reinstalled from the Microsoft Store. Other programs open their own uninstaller.") ('Debloat') ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    $store = @($pick | Where-Object { $_.App.Kind -eq 'store' })
    foreach ($d in @($pick | Where-Object { $_.App.Kind -ne 'store' })) { Invoke-AppUninstallDirect $d.App }
    if ($store.Count) {
        Show-Toast "Removing $($store.Count) app$(if ($store.Count -ne 1) { 's' })..." '#A1A1A6'
        $script:DebloatNames = @($store | ForEach-Object { $_.App.Name })
        Start-Background 'param($list) foreach ($f in $list) { try { Remove-AppxPackage -Package $f -ErrorAction Stop; "ok|$f" } catch { "err|$f|$($_.Exception.Message)" } }' @(, @($store | ForEach-Object { $_.App.Full })) {
            param($out, $errs)
            $ok = @($out | Where-Object { "$_" -like 'ok|*' }).Count; $bad = @($out | Where-Object { "$_" -like 'err|*' })
            Add-History "Debloat: removed $ok app$(if ($ok -ne 1) { 's' })" 'apps' $null
            Show-Toast $(if ($bad.Count) { "Removed $ok. $($bad.Count) could not be removed (Windows may need it)." } else { "Removed $ok app$(if ($ok -ne 1) { 's' })." }) $(if ($bad.Count) { '#FF9F0A' } else { '#30D158' })
            Start-DebloatScan
        }
    }
}
# runs a program's own uninstaller without asking again (Debloat already asked)
function Invoke-AppUninstallDirect($app) {
    $cmd = "$($app.Uninstall)".Trim(); if (-not $cmd) { return }
    if ($cmd -match '(?i)msiexec') { $guid = [regex]::Match($cmd, '\{[0-9A-Fa-f-]{36}\}').Value; $file = 'msiexec.exe'; $argText = if ($guid) { "/x $guid" } else { ($cmd -replace '(?i)^.*?msiexec(\.exe)?"?\s*', '') -replace '(?i)/i', '/x' } }
    elseif ($cmd.StartsWith('"')) { $end = $cmd.IndexOf('"', 1); $file = $cmd.Substring(1, $end - 1); $argText = $cmd.Substring($end + 1).Trim() }
    else { $i = $cmd.ToLower().IndexOf('.exe'); if ($i -gt 0) { $file = $cmd.Substring(0, $i + 4); $argText = $cmd.Substring($i + 4).Trim() } else { $file = $cmd; $argText = '' } }
    try { if ($argText) { Start-Process $file -ArgumentList $argText } else { Start-Process $file }; Add-History "Debloat: opened uninstaller for $($app.Name)" 'apps' $null }
    catch { Show-Toast "Could not start the uninstaller for $($app.Name)." '#FF9F0A' }
}

# --- System tray icon
function Show-MainWindow {
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Activate() | Out-Null
    $window.Topmost = $true; $window.Topmost = $false
}
function New-TrayIcon {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = if (Test-Path $LogoIco) { New-Object System.Drawing.Icon $LogoIco } else { [System.Drawing.SystemIcons]::Application }
    $ni.Text = 'ZeroDelay'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $open = $menu.Items.Add('Open ZeroDelay')
    $gm = $menu.Items.Add('Game Mode')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $quit = $menu.Items.Add('Exit')
    $open.Add_Click({ Show-MainWindow })
    $gm.Add_Click({ $msg = if (Test-ZDGameMode) { Disable-ZDGameMode } else { Enable-ZDGameMode }; $script:TrayIcon.ShowBalloonTip(3000, 'ZeroDelay', $msg, 'None') })
    $quit.Add_Click({ $script:ReallyExit = $true; $window.Close() })
    $menu.Add_Opening({ $script:TrayGm.Checked = Test-ZDGameMode })
    $script:TrayGm = $gm
    $ni.ContextMenuStrip = $menu
    $ni.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-MainWindow } })
    $ni.Add_BalloonTipClicked({ Show-MainWindow; if ($script:BalloonPage) { $script:NavButtons[$script:BalloonPage].IsChecked = $true; $script:BalloonPage = $null } })
    $ni.Visible = $true
    $ni
}

# =============================================================== NVIDIA
$NvSmoothMotionId = [uint32]2966652096   # 0xB0D384C0, Smooth Motion enable (0 = off)
$NvIds = [ordered]@{ AppOverride = [uint32]0x10A879CF; Request = [uint32]0x10A879AC; VrrCtl = [uint32]0x10A879CE; VSync = [uint32]0x00A879CF; Frl = [uint32]0x10835002 }
$VSyncNames = @{ 0x60925292 = 'Use the 3D application setting'; 0x08416747 = 'Off'; 0x47814940 = 'On'; 0x18888888 = 'Fast'; 0x32610244 = '1/2 refresh'; 0x71271021 = '1/3 refresh'; 0x13245256 = '1/4 refresh' }
$NvAppDir  = "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App"
$NvAppExe  = "$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe"

function Get-NvDriverInfo {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' } | Select-Object -First 1
    if (-not $gpu) { return $null }
    $digits = ($gpu.DriverVersion -replace '\D', ''); $last = $digits.Substring([Math]::Max(0, $digits.Length - 5))
    $inst = '{0}.{1}' -f $last.Substring(0, 3), $last.Substring(3)
    $latest = (Get-ItemProperty 'HKCU:\Software\NVIDIA Corporation\Global\NvApp' -ErrorAction SilentlyContinue).CurrentNotifiedGameReadyDriverVersion
    [pscustomobject]@{ Name = $gpu.Name; Installed = $inst; Latest = $(if ($latest -match '^\d+\.\d+$') { $latest } else { $null }) }
}
function Get-NvBin([string]$Name, [switch]$Float) {
    $v = (Get-ItemProperty 'HKCU:\Software\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS' -ErrorAction SilentlyContinue).$Name
    if ($v -is [byte[]] -and $v.Length -ge 4) { if ($Float) { [BitConverter]::ToSingle($v, 0) } else { [BitConverter]::ToUInt32($v, 0) } } elseif ($null -ne $v) { $v } else { $null }
}
function Get-NvOverlayState {
    $user = Get-NvBin 'IsShadowPlayEnabledUser'; $en = Get-NvBin 'IsShadowPlayEnabled'
    $running = [bool](Get-Process -Name 'NVIDIA Overlay', 'nvsphelper64' -ErrorAction SilentlyContinue)
    [pscustomobject]@{ On = (($user -eq 1) -or ($en -eq 1) -or $running); Running = $running
                       ReplaySeconds = Get-NvBin 'DVRBufferLen'; Width = Get-NvBin 'VideoWidth'; Height = Get-NvBin 'VideoHeight'; Fps = Get-NvBin 'RecordingFPS' -Float }
}
function Get-NvOptimizeState {
    $auto = $null
    $cfg = Join-Path $NvAppDir 'NvBackend\config.xml'
    if (Test-Path $cfg) { $auto = ([xml](Get-Content $cfg -Raw)).SelectSingleNode("//Setting[@name='EnableAutomaticApplyOPS']").value }
    # NVIDIA's id for Fortnite can differ per PC: find the state file that mentions Fortnite, else the usual id.
    $fn = Get-ChildItem (Join-Path $NvAppDir 'NvBackend\ApplicationState') -Filter *.json -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'Fortnite' } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $fn) { $fn = Join-Path $NvAppDir 'NvBackend\ApplicationState\1802992157.json' }
    $optimized = if (Test-Path $fn) { (Get-Content $fn -Raw) -match '"CurrentACPosition"' } else { $null }
    [pscustomobject]@{ AutoOptimize = $(if ($null -ne $auto) { $auto -eq '1' } else { $null }); FortniteOptimized = $optimized }
}
function Disable-NvRtxHdr {
    $e = Get-NvEff $NvProfile ([uint32]0x00DD48FB)
    if (-not $e.Found -or $e.Value -eq 0) { return 'RTX HDR is already off for Fortnite.' }
    if (-not $script:Backup.Custom.ContainsKey('nvrtxhdr')) { $script:Backup.Custom['nvrtxhdr'] = @{ Value = (Get-NvBackupValue $NvProfile ([uint32]0x00DD48FB)) }; Save-Backup }
    $r = [NvDrs]::Set($NvProfile, [uint32]0x00DD48FB, 0)
    if ($r -ne 0) { throw "The NVIDIA driver refused the change (code $r)." }
    Add-History 'NVIDIA: RTX HDR off for Fortnite' 'nvidia' $null
    'RTX HDR turned off for Fortnite. Restart Fortnite to see it.'
}

# --- Sync presets. The first preset applied saves the original driver values (own values only) and Fortnite ini values.
function Save-NvSyncBackup {
    if ($script:Backup.Custom['nvsync']) { return }
    $drs = @{}; foreach ($k in $NvIds.Keys) { $drs["$($NvIds[$k])"] = Get-NvBackupValue $NvProfile $NvIds[$k] }
    $l = Get-Content $IniPath
    $ini = @{}; foreach ($k in 'bUseVSync', 'LatencyTweak2', 'FrameRateLimit') { $ini[$k] = Get-IniValue $l $k }
    $script:Backup.Custom['nvsync'] = @{ Drs = $drs; Ini = $ini }
    Save-Backup
}
function Set-FortniteSyncIni([string]$Cap) {
    $l = Get-Content $IniPath
    $l = Set-IniValue $l 'bUseVSync' 'False'
    $l = Set-IniValue $l 'LatencyTweak2' '2'
    $l = Set-IniValue $l 'FrameRateLimit' $Cap
    Set-Content -Path $IniPath -Value $l -Encoding UTF8
}
function Invoke-NvTearFree {
    if (-not (Test-VrrDisplayOn)) { throw 'G-SYNC is not active. Turn it on in NVIDIA App > System > Displays (and in your monitor menu) first.' }
    Assert-IniWritable
    Save-NvSyncBackup
    foreach ($pair in @(@($NvIds.AppOverride, 0), @($NvIds.Request, 0), @($NvIds.VrrCtl, 1), @($NvIds.VSync, 0x47814940))) {
        $r = [NvDrs]::Set($NvProfile, [uint32]$pair[0], [uint32]$pair[1]); if ($r -ne 0) { throw "The NVIDIA driver refused a change (code $r)." }
    }
    $frl = Get-NvEff $NvProfile $NvIds.Frl; if ($frl.Found -and $frl.Value -ne 0) { [void][NvDrs]::Set($NvProfile, $NvIds.Frl, 0) }
    $cap = Get-VrrCap
    Set-FortniteSyncIni ('{0}.000000' -f $cap)
    $script:Backup.Custom['nvsyncmode'] = 'tearfree'; Save-Backup
    Add-History 'NVIDIA: tear-free preset (G-SYNC + V-Sync + Reflex)' 'nvidia' $null
    "Tear-free preset applied: G-SYNC, driver V-Sync on, Reflex on, $cap FPS cap. Restart the NVIDIA App if it is open."
}
function Invoke-NvLowest {
    Assert-IniWritable
    Save-NvSyncBackup
    $vs = Get-NvEff $NvProfile $NvIds.VSync
    if ($vs.Found -and $vs.Value -notin 0x08416747, 0x60925292) {
        $base = Get-NvEff 'Base Profile' $NvIds.VSync
        if ($vs.Own -and (-not $base.Found -or $base.Value -in 0x08416747, 0x60925292)) { [void][NvDrs]::Delete($NvProfile, $NvIds.VSync) }
        else { [void][NvDrs]::Set($NvProfile, $NvIds.VSync, [uint32]0x08416747) }
    }
    $frl = Get-NvEff $NvProfile $NvIds.Frl
    if ($frl.Found -and $frl.Value -ne 0) { [void][NvDrs]::Set($NvProfile, $NvIds.Frl, 0) }
    Set-FortniteSyncIni '0.000000'
    $script:Backup.Custom['nvsyncmode'] = 'lowest'; Save-Backup
    Add-History 'NVIDIA: lowest-latency preset (V-Sync off, Reflex, uncapped)' 'nvidia' $null
    'Lowest-latency preset applied: V-Sync off, Reflex on, FPS uncapped. If frame pacing feels uneven, set a cap well above your refresh rate in the Fortnite tab.'
}
function Undo-NvSync {
    $b = $script:Backup.Custom['nvsync']
    if (-not $b) { return 'No sync preset has been applied.' }
    Assert-IniWritable
    $drs = ConvertTo-OrderedTable $b.Drs
    foreach ($k in $drs.Keys) { if ($null -eq $drs[$k]) { [void][NvDrs]::Delete($NvProfile, [uint32]$k) } else { [void][NvDrs]::Set($NvProfile, [uint32]$k, [uint32]$drs[$k]) } }
    $ini = ConvertTo-OrderedTable $b.Ini
    $l = Get-Content $IniPath
    foreach ($k in $ini.Keys) { $l = Set-IniValue $l $k $ini[$k] }
    Set-Content -Path $IniPath -Value $l -Encoding UTF8
    $script:Backup.Custom.Remove('nvsync'); $script:Backup.Custom.Remove('nvsyncmode'); Save-Backup
    Add-History 'NVIDIA: sync preset undone' 'nvidia' $null
    'Your previous V-Sync, G-SYNC and FPS cap settings are back.'
}
function Get-NvSyncStatus {
    $flags = [NvDrs]::VrrFlags()
    $vs = Get-NvEff $NvProfile $NvIds.VSync; $frl = Get-NvEff $NvProfile $NvIds.Frl
    $l = if (Test-Path $IniPath) { Get-Content $IniPath } else { @() }
    $cap = [double](Get-IniValue $l 'FrameRateLimit'); $hz = (Get-Displays | Where-Object Discrete | Measure-Object Hz -Maximum).Maximum
    $vrrOn = Test-VrrActive; $vcap = Get-VrrCap
    $vsVal = if ($vs.Found) { [int64]$vs.Value } else { 0x60925292 }
    $vsKey = if ($vsVal -le [int]::MaxValue) { [int]$vsVal } else { $null }
    $vsName = if ($null -ne $vsKey -and $VSyncNames.ContainsKey($vsKey)) { $VSyncNames[$vsKey] } else { '0x{0:X8}' -f $vsVal }
    $warn = @()
    if ($vrrOn) {
        if ($vsVal -ne 0x47814940) { $warn += 'With G-SYNC on, driver V-Sync should be On to stay tear-free.' }
        if ($cap -eq 0 -or $cap -gt $vcap) { $warn += "Cap Fortnite at $vcap FPS so G-SYNC stays engaged." }
        $verdict = if (-not $warn) { 'Tear-free setup: good.' } else { 'G-SYNC is on but not set up for lowest delay.' }
    } else {
        if ($vsVal -notin 0x08416747, 0x60925292) { $warn += "Driver V-Sync is '$vsName' while G-SYNC is off: this adds delay." }
        if ($vcap -and $hz -and $cap -ge $vcap -and $cap -le $hz) { $warn += "Fortnite is capped at $([int]$cap) FPS, right at your $hz Hz refresh, without G-SYNC." }
        $verdict = if (-not $warn) { 'Lowest-latency setup (no G-SYNC): good.' } else { 'G-SYNC is off and the cap or V-Sync is not ideal.' }
    }
    if ($frl.Found -and $frl.Value -gt 0 -and $cap -gt 0) { $warn += "The driver frame cap ($($frl.Value)) is also set; the in-game cap alone is about half a frame faster." }
    if ((Get-IniValue $l 'LatencyTweak2') -ne '2') { $warn += 'NVIDIA Reflex is not on On + Boost in Fortnite.' }
    [pscustomobject]@{
        Flags = $flags; VrrOn = $vrrOn; VrrPossible = ($flags -ge 0 -and ($flags -band 2)); VSync = $vsName; VSyncInherited = ($vs.Found -and -not $vs.Own)
        DriverCap = $(if ($frl.Found) { $frl.Value } else { 0 }); GameVSync = Get-IniValue $l 'bUseVSync'; Cap = $cap; Hz = $hz; Reflex = Get-IniValue $l 'LatencyTweak2'
        Verdict = $verdict; Warnings = $warn; Mode = $script:Backup.Custom['nvsyncmode']
    }
}

# --- NVIDIA App local agent server (MCP over HTTP on 127.0.0.1). Used only to read status and to pause Instant Replay.
function Invoke-NvMcp([string]$Tool, [hashtable]$Arguments = @{}) {
    $sj = Join-Path $NvAppDir 'McpServer\server.json'
    if (-not (Test-Path $sj)) { throw 'NVIDIA App agent server is not set up.' }
    $url = (Get-Content $sj -Raw | ConvertFrom-Json).http
    if ($url -notmatch '^http://(127\.0\.0\.1|localhost)[:/]') { throw 'Unexpected NVIDIA App agent address.' }
    function Post($body, $sid) {
        $req = [Net.HttpWebRequest]::Create($url); $req.Method = 'POST'; $req.Timeout = 5000; $req.ReadWriteTimeout = 5000; $req.ContentType = 'application/json'
        $req.Accept = 'application/json, text/event-stream'; $req.Headers.Add('MCP-Protocol-Version', '2025-11-25')
        if ($sid) { $req.Headers.Add('Mcp-Session-Id', $sid) }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress)); $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        $resp = $req.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $text = ''
        while ($null -ne ($line = $sr.ReadLine())) { if ($line -match '^data:\s*(\{.*"id".*\})\s*$') { $text = "data: $($Matches[1])"; break }; $text += "$line`n" }
        $sr.Close()
        $newSid = $resp.Headers['Mcp-Session-Id']; $resp.Close()
        $json = if ($text -match '(?m)^data:\s*(\{.*\})\s*$') { $Matches[1] } else { $text }
        @{ Sid = $newSid; Body = $(if ($json.Trim()) { $json | ConvertFrom-Json } else { $null }) }
    }
    $init = Post @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'ZeroDelay'; version = '1' } } } $null
    $sid = $init.Sid
    try {
        [void](Post @{ jsonrpc = '2.0'; method = 'notifications/initialized' } $sid)
        $res = if ($Tool -eq 'tools/list') { Post @{ jsonrpc = '2.0'; id = 2; method = 'tools/list' } $sid }
               else { Post @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = $Tool; arguments = $Arguments } } $sid }
        $r = $res.Body.result
        if ($res.Body.error) { throw "$($res.Body.error.message)" }
        if ($r.isError) { throw "$(if ($r._meta.error_code) { $r._meta.error_code } else { $r.content[0].text })" }
        if ($r.structuredContent) { $r.structuredContent } elseif ($r.content -and $r.content[0].text -match '^\s*[\{\[]') { $r.content[0].text | ConvertFrom-Json } else { $r }
    } finally {
        if ($sid) { try { $d = [Net.HttpWebRequest]::Create($url); $d.Method = 'DELETE'; $d.Timeout = 3000; $d.ReadWriteTimeout = 3000; $d.Headers.Add('Mcp-Session-Id', $sid); $d.GetResponse().Close() } catch {} }
    }
}
function Set-NvInstantReplay([bool]$Enable) {
    [void](Invoke-NvMcp 'nvapp_overlay_capture' @{ action = 'toggle_instant_replay'; enable = $Enable })
    Start-Sleep -Seconds 2
    $st = Invoke-NvMcp 'nvapp_overlay_get_status'
    [bool]($st -and $null -ne $st.instantReplayEnabled -and [bool]$st.instantReplayEnabled -eq $Enable)
}

function New-NvRow([string]$Label, [string]$Value, [string]$Color = '#D1D1D6') {
    "<Grid Margin='0,0,0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='230'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
    "<TextBlock Text='$(Esc $Label)' Foreground='#A1A1A6' FontSize='13'/><TextBlock Grid.Column='1' Text='$(Esc $Value)' Foreground='$Color' FontSize='13' TextWrapping='Wrap'/></Grid>"
}
function New-NvSection([string]$Title, [string]$Rows, [string]$Buttons = '', [string]$Note = '') {
    "<Border Background='#2C2C2E' BorderBrush='#38383A' BorderThickness='1' CornerRadius='12' Padding='24,20' Margin='0,0,0,16'><StackPanel>" +
    "<TextBlock Text='$(Esc $Title)' FontSize='16' FontWeight='SemiBold' Margin='0,0,0,12'/>$Rows" +
    $(if ($Note) { "<TextBlock Text='$(Esc $Note)' Foreground='#A1A1A6' FontSize='12.5' TextWrapping='Wrap' Margin='0,4,0,0'/>" } else { '' }) +
    $(if ($Buttons) { "<WrapPanel Margin='0,10,0,0'>$Buttons</WrapPanel>" } else { '' }) + "</StackPanel></Border>"
}
function New-NvButton([string]$Name, [string]$Text, [bool]$Primary = $false, [bool]$Enabled = $true) {
    "<Button x:Name='$Name' Content='$(Esc $Text)' Style='{DynamicResource Btn}' Margin='0,0,10,8' IsEnabled='$Enabled'" + $(if ($Primary) { " Background='#0071E3' Foreground='#FFFFFF'" } else { '' }) + '/>'
}

function New-NvidiaPage {
    $host_ = New-Object Windows.Controls.ContentControl
    $script:NvHost = $host_
    $script:PageRefresh['Nvidia'] = { Update-NvidiaPage }
    Update-NvidiaPage
    New-PageScroll $host_
}
function Get-NvPageData {
    if (-not (Test-NvAvailable)) { return @{ Ok = $false } }
    $base = @{}
    foreach ($k in '0x1194F158', '0x10A879CF', '0x10A879CE', '0x00A879CF') { $base[$k] = Get-NvEff 'Base Profile' ([uint32]([Convert]::ToUInt32($k.Substring(2), 16))) }
    @{ Ok = $true; Sync = (Get-NvSyncStatus); Ov = (Get-NvOverlayState); Opt = (Get-NvOptimizeState); Drv = (Get-NvDriverInfo); DisplayOn = (Test-VrrDisplayOn)
       Closed = -not (Test-FortniteRunning); Sm = (Get-NvEff $NvProfile $NvSmoothMotionId); Hdr = (Get-NvEff $NvProfile ([uint32]0x00DD48FB))
       Dvc = @([uint32]0x00980880, [uint32]0x00ABAB13, [uint32]0x00ABAB22 | ForEach-Object { Get-NvEff $NvProfile $_ } | Where-Object { $_.Found -and $_.Value -ne 0 })
       Ansel = (Get-NvEff 'Base Profile' ([uint32]0x1075D972)); Base = $base; AppRunning = [bool](Get-Process -Name 'NVIDIA App' -ErrorAction SilentlyContinue) }
}
# Reads in the background (a second or two of driver queries), then draws. Skipped if read in the last 20 s.
function Update-NvidiaPage([switch]$Force) {
    if (-not $script:NvHost -or $script:NvBusy) { return }
    if (-not $Force -and $script:NvRead -and ((Get-Date) - $script:NvRead).TotalSeconds -lt 20) { return }
    $script:NvBusy = $true
    if (-not $script:NvHost.Content) { $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'Reading the NVIDIA driver profile...'; $tb.Foreground = ConvertTo-Brush '#A1A1A6'; $script:NvHost.Content = $tb }
    Invoke-Worker 'Get-NvPageData' @() { param($out, $errs) $script:NvBusy = $false; $script:NvRead = Get-Date; $d = Get-WorkerResult $out; if ($d -is [hashtable]) { Show-NvidiaPage $d } }
}
function Show-NvidiaPage($d) {
    if (-not $d.Ok) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'No NVIDIA graphics card or driver profile found. This page is for NVIDIA cards.'; $tb.Foreground = ConvertTo-Brush '#A1A1A6'
        $script:NvHost.Content = $tb; return
    }
    $sync = $d.Sync; $ov = $d.Ov; $opt = $d.Opt; $drv = $d.Drv
    $green = '#30D158'; $amber = '#FFD60A'; $red = '#FF453A'
    # sync
    $displayOn = $d.DisplayOn
    $rows = (New-NvRow 'G-SYNC' $(if ($sync.VrrOn) { 'On for Fortnite' } elseif ($displayOn) { 'On for the monitor but blocked for Fortnite: the Tear-free preset fixes this' } elseif ($sync.VrrPossible) { 'Available but off' } else { 'Off (not enabled for this monitor)' }) $(if ($sync.VrrOn) { $green } else { $amber })) +
            (New-NvRow 'Driver V-Sync (Fortnite)' "$($sync.VSync)$(if ($sync.VSyncInherited) { '  (from the global profile)' })") +
            (New-NvRow 'Driver frame cap' $(if ($sync.DriverCap) { "$($sync.DriverCap) FPS" } else { 'Off' })) +
            (New-NvRow 'Fortnite V-Sync' $(if ($sync.GameVSync -eq 'False') { 'Off' } else { "$($sync.GameVSync)" })) +
            (New-NvRow 'Fortnite FPS cap' $(if ($sync.Cap -eq 0) { 'Unlimited' } else { "$([int]$sync.Cap) FPS on a $($sync.Hz) Hz screen" })) +
            (New-NvRow 'NVIDIA Reflex' $(if ($sync.Reflex -eq '2') { 'On + Boost' } elseif ($sync.Reflex -eq '1') { 'On' } else { 'Off' }) $(if ($sync.Reflex -eq '2') { $green } else { $amber })) +
            (New-NvRow 'Verdict' $sync.Verdict $(if ($sync.Warnings) { $amber } else { $green }))
    foreach ($w in $sync.Warnings) { $rows += New-NvRow '' "• $w" $amber }
    $closed = $d.Closed
    $btns = (New-NvButton 'TearFree' 'Tear-free preset (G-SYNC)' ([bool]$displayOn) ($displayOn -and $closed)) + (New-NvButton 'Lowest' 'Lowest-latency preset' (-not $sync.VrrOn) $closed) +
            (New-NvButton 'UndoSync' 'Undo preset' $false ([bool]$script:Backup.Custom['nvsync'] -and $closed))
    $note = if ($sync.VrrOn) { 'Tear-free: driver V-Sync on + Reflex + cap a few FPS under refresh. Lowest-latency: V-Sync off and no cap at refresh (allows tearing).' }
            else { 'To use G-SYNC, turn it on in NVIDIA App > System > Displays and in your monitor menu, then come back. Fortnite must be closed to apply a preset.' }
    $x = New-NvSection 'Sync and frame cap' $rows $btns $note
    # filters
    $sm = $d.Sm; $hdr = $d.Hdr; $dvc = @($d.Dvc); $ansel = $d.Ansel
    $rows = (New-NvRow 'Smooth Motion (frame generation)' $(if ($sm.Found -and $sm.Value -ne 0) { 'ON: adds delay' } elseif ($sm.Found -and $sm.Own) { 'Off (pinned by ZeroDelay)' } else { 'Off' }) $(if ($sm.Found -and $sm.Value -ne 0) { $red } else { $green })) +
            (New-NvRow 'RTX HDR' $(if ($hdr.Found -and $hdr.Value -ne 0) { 'ON: costs GPU time' } else { 'Not enabled in the driver profile' }) $(if ($hdr.Found -and $hdr.Value -ne 0) { $red } else { $green })) +
            (New-NvRow 'RTX Dynamic Vibrance' $(if ($dvc.Count) { 'Possibly on' } else { 'Off' }) $(if ($dvc.Count) { $amber } else { $green })) +
            (New-NvRow 'Ansel / photo mode' $(if ($ansel.Found -and $ansel.Value -eq 0) { 'Disabled globally' } else { 'Allowed' }))
    $btns = if ($hdr.Found -and $hdr.Value -ne 0) { New-NvButton 'HdrOff' 'Turn off RTX HDR' $true } else { '' }
    $x += New-NvSection 'Frame generation and filters' $rows $btns $(if ($dvc.Count) { 'Turn Dynamic Vibrance off in NVIDIA App > Graphics > Program settings > Fortnite.' } else { '' })
    # overlay
    $rows = (New-NvRow 'NVIDIA overlay (Alt+Z)' $(if ($ov.On) { 'On' } else { 'Off' }) $(if ($ov.On) { $amber } else { $green })) +
            (New-NvRow 'Instant Replay' $(if ($ov.On) { 'Possible while the overlay is on' } else { 'Not recording (overlay off)' })) +
            (New-NvRow 'Saved replay settings' $(if ($ov.ReplaySeconds) { "$([int]($ov.ReplaySeconds / 60)) min, $($ov.Width)x$($ov.Height), $([int]$ov.Fps) fps" } else { 'None' }))
    $x += New-NvSection 'Overlay and Instant Replay' $rows '' $(if ($ov.On) { 'Instant Replay costs about 2-3% FPS while recording. Game Mode can pause it during matches (turn on "Pause NVIDIA Instant Replay" on the Game Mode page).' } else { 'Keep the overlay off unless you clip. Nothing to do.' })
    # app
    $rows = (New-NvRow 'Auto-optimize new games' $(if ($null -eq $opt.AutoOptimize) { 'Unknown' } elseif ($opt.AutoOptimize) { 'On (only affects games added later)' } else { 'Off' }) $(if ($opt.AutoOptimize) { $amber } else { $green })) +
            (New-NvRow 'Fortnite optimized by NVIDIA' $(if ($null -eq $opt.FortniteOptimized) { 'Unknown' } elseif ($opt.FortniteOptimized) { 'Yes: it may overwrite your graphics settings' } else { 'No (good)' }) $(if ($opt.FortniteOptimized) { $amber } else { $green })) +
            (New-NvRow 'Driver' $(if ($drv) { "$($drv.Installed)$(if ($drv.Latest -and [version]$drv.Latest -gt [version]$drv.Installed) { "  ·  $($drv.Latest) available" } else { '  ·  up to date' })" } else { 'Unknown' })) +
            (New-NvRow 'App connection (agent server)' $(if ($script:NvMcpState) { $script:NvMcpState } else { 'Not checked' }))
    $btns = (New-NvButton 'Mcp' 'Check app connection') + $(if (-not $d.AppRunning -and (Test-Path $NvAppExe)) { New-NvButton 'OpenApp' 'Open NVIDIA App' } else { '' })
    $x += New-NvSection 'NVIDIA App' $rows $btns 'Never press Optimize on Fortnite in the NVIDIA App: it replaces your graphics settings.'
    # leftovers
    $defaults = [ordered]@{ '0x1194F158' = @('G-SYNC (global)', 1); '0x10A879CF' = @('G-SYNC app override (global)', 0); '0x10A879CE' = @('V-Sync with G-SYNC (global)', 1); '0x00A879CF' = @('V-Sync (global)', 0x60925292) }
    $left = foreach ($k in $defaults.Keys) {
        $e = $d.Base[$k]
        if ($e.Own -and $e.Value -ne $defaults[$k][1]) { New-NvRow $defaults[$k][0] ('{0} (default {1})' -f $(if ($k -eq '0x00A879CF' -and $e.Value -le [int]::MaxValue -and $VSyncNames.ContainsKey([int]$e.Value)) { $VSyncNames[[int]$e.Value] } else { $e.Value }), $(if ($k -eq '0x00A879CF') { 'app setting' } else { $defaults[$k][1] })) $amber }
    }
    $x += New-NvSection 'Global NVIDIA settings changed from default' $(if ($left) { $left -join '' } else { New-NvRow 'Status' 'Nothing unusual' $green }) '' 'Change these in NVIDIA App > Graphics > Global settings or System > Displays. G-SYNC must be turned on there; ZeroDelay does not force it.'
    # checklist
    $tips = 'Settings > Features > NVIDIA Overlay: off unless you clip', 'Settings > Automatically optimize newly added games: off', 'System > Performance > Automatic tuning: off', 'Graphics > Global > Shader Cache Size: Driver default or larger', 'System > Displays > G-SYNC: on if your monitor supports it, then use the Tear-free preset'
    $x += New-NvSection 'Set by hand in the NVIDIA App' (($tips | ForEach-Object { New-NvRow '' "• $_" }) -join '')
    $panel = [ZdTheme]::Parse("<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$x</StackPanel>")
    $wire = @{
        TearFree = { Invoke-NvTearFree }; Lowest = { Invoke-NvLowest }; UndoSync = { Undo-NvSync }; HdrOff = { Disable-NvRtxHdr }
        Mcp = { try { $t = Invoke-NvMcp 'tools/list'; $script:NvMcpState = "Connected ($(@($t.tools).Count) tools)"; 'NVIDIA App connection works.' } catch { $script:NvMcpState = 'Not reachable (NVIDIA App closed or agents off)'; throw 'Could not reach the NVIDIA App connection.' } }
        OpenApp = { Start-Process explorer.exe -ArgumentList "`"$NvAppExe`""; 'Opening the NVIDIA App...' }
    }
    foreach ($n in $wire.Keys) {
        $b = $panel.FindName($n); if (-not $b) { continue }
        $b.Tag = $wire[$n]
        $b.Add_Click({ param($s, $e)
            $window.Cursor = [Windows.Input.Cursors]::Wait
            try { Show-Toast (& $s.Tag) '#30D158' } catch { Show-Toast $_.Exception.Message '#FF9F0A' }
            $window.Cursor = $null; Update-NvidiaPage -Force })
    }
    $script:NvHost.Content = $panel
}

$script:Pages = @{}
$script:PageRefresh = @{}
function Get-PageContent([string]$Name) {
    if (-not $script:Pages.ContainsKey($Name)) {
        $builder = Get-Command "New-$($Name)Page" -ErrorAction SilentlyContinue
        $script:Pages[$Name] = if ($builder) { & $builder } else {
            $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'Coming soon.'; $tb.Margin = '32,0,0,0'; $tb.Foreground = [ZdTheme]::Brush('#A1A1A6'); $tb }
    }
    $script:Pages[$Name]
}
# Wraps page content in a scrolling panel with the app's page padding.
function New-PageScroll($content) {
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.Style = $window.FindResource('OverlayScroll')
    $sv.VerticalScrollBarVisibility = 'Auto'; $sv.Padding = '32,0,32,32'
    $sv.Content = $content
    $sv
}
function ConvertTo-Brush([string]$c) { [ZdTheme]::Brush($c) }
$script:CurrentCat = $Categories[0]
function Update-Filter {
    $q = $ui.Search.Text.Trim()
    $ui.SearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    $ui.PageTitle.Text = if ($q) { "Results for `"$q`"" } else { $script:CurrentCat.Title }
    $note = "$($script:CurrentCat.Note)"
    if ($script:CurrentCat.Name -eq 'Potato') { $cur = Get-CurrentPotatoScore; if ($null -ne $cur) { $note += "   Your settings right now: $cur% potato." } }
    $ui.LatencyNote.Text = $note
    $ui.LatencyNote.Visibility = if (-not $q -and $script:CurrentCat.Note) { 'Visible' } else { 'Collapsed' }
    if (-not $q -and $script:CurrentCat.Page) {
        $ui.Scroller.Visibility = 'Collapsed'; $ui.PageHost.Visibility = 'Visible'
        $ui.PageHost.Content = Get-PageContent $script:CurrentCat.Page
        return
    }
    $ui.Scroller.Visibility = 'Visible'; $ui.PageHost.Visibility = 'Collapsed'
    foreach ($t in $Tweaks) {
        $show = if ($q) { -not $t.Header -and ($t.Title -like "*$q*" -or $t.Desc -like "*$q*") }
                elseif ($script:CurrentCat.Name -eq 'Latency') { [bool]$t.Lat }
                elseif ($script:CurrentCat.Name -eq 'Potato') { [bool]$t.Potato }
                elseif ($script:CurrentCat.Name -eq 'Gtx1080Ti') { [bool]$t.Gtx }
                else { $script:CurrentCat.Name -eq 'All' -or $t.Cat -eq $script:CurrentCat.Name }
        $t.Card.Visibility = if ($show -and -not $t.Hidden) { 'Visible' } else { 'Collapsed' }
    }
}
$ui.Search.Add_TextChanged({ Update-Filter })
$script:NavButtons = @{}
$NavTop = @('Home', 'GameMode', 'Events', 'Health')
$NavTools = @('ThisPC', 'Sync', 'Nvidia', 'Benchmark', 'Matches', 'Booster', 'Ping', 'Sens', 'Mouse', 'Profiles', 'History', 'Debloat', 'Apps', 'Clean', 'Memory')
$NavEnd = @('Settings')
function Get-NavGroupOf([string]$Name) { if ($NavTop -contains $Name -or $NavEnd -contains $Name) { '' } elseif ($NavTools -contains $Name) { 'Tools' } else { 'Tweaks' } }
$script:NavGroups = @{}
function Set-NavGroupOpen([string]$Group, [bool]$Open) {
    $g = $script:NavGroups[$Group]; if (-not $g) { return }
    $was = $g.Panel.Visibility -eq 'Visible'
    $g.Panel.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    if ($script:Anim) { Start-Anim $g.Chevron ([Windows.Media.RotateTransform]::AngleProperty) $null $(if ($Open) { 90 } else { 0 }) 200 } else { $g.Chevron.Angle = $(if ($Open) { 90 } else { 0 }) }
    if ($Open -and -not $was) { Show-Animated $g.Panel -6 220 }
    $script:Backup.Custom["nav_$Group"] = $Open
}
function New-NavGroup([string]$Group, [string]$Title) {
    $hd = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Background='Transparent' Cursor='Hand' Padding='10,14,10,6' Margin='0,4,0,0'>
  <Grid>
    <TextBlock Text='$Title' FontSize='11' FontWeight='SemiBold' Foreground='#98989D'/>
    <TextBlock Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='9' Foreground='#98989D' HorizontalAlignment='Right' VerticalAlignment='Center' RenderTransformOrigin='0.5,0.5'>
      <TextBlock.RenderTransform><RotateTransform Angle='0'/></TextBlock.RenderTransform>
    </TextBlock>
  </Grid>
</Border>
"@)
    $panel = New-Object Windows.Controls.StackPanel
    $script:NavGroups[$Group] = @{ Header = $hd; Panel = $panel; Chevron = $hd.Child.Children[1].RenderTransform }
    $hd.Tag = $Group
    $hd.Add_MouseLeftButtonUp({ param($s, $e) $g = $script:NavGroups[$s.Tag]; Set-NavGroupOpen $s.Tag ($g.Panel.Visibility -ne 'Visible') })
    [void]$ui.Nav.Children.Add($hd); [void]$ui.Nav.Children.Add($panel)
    $open = [bool]$script:Backup.Custom["nav_$Group"]
    $panel.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
    if ($open) { $script:NavGroups[$Group].Chevron.Angle = 90 }
}
$navOrder = @($Categories | Where-Object { $NavTop -contains $_.Name } | Sort-Object { $NavTop.IndexOf($_.Name) }) +
            @($Categories | Where-Object { (Get-NavGroupOf $_.Name) -eq 'Tweaks' }) +
            @($Categories | Where-Object { $NavTools -contains $_.Name } | Sort-Object { $NavTools.IndexOf($_.Name) }) +
            @($Categories | Where-Object { $NavEnd -contains $_.Name })
$navTarget = $ui.Nav
foreach ($c in $navOrder) {
    if ($c.Requires -and -not (& $c.Requires)) { continue }   # e.g. the GTX 1080 Ti tab on other PCs
    $grp = Get-NavGroupOf $c.Name
    if ($grp -and -not $script:NavGroups.ContainsKey($grp)) { New-NavGroup $grp $(if ($grp -eq 'Tools') { 'Tools' } else { 'Tweaks' }) }
    if (-not $grp -and $NavEnd -contains $c.Name -and -not $script:NavEndSep) {
        $script:NavEndSep = New-Object Windows.Controls.Border; $script:NavEndSep.Height = 1; $script:NavEndSep.Margin = '10,10,10,8'; $script:NavEndSep.Background = ConvertTo-Brush '#38383A'
        [void]$ui.Nav.Children.Add($script:NavEndSep)
    }
    $navTarget = if ($grp) { $script:NavGroups[$grp].Panel } else { $ui.Nav }
    $rb = [ZdTheme]::Parse(@"
<RadioButton xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' GroupName='nav' Style='{DynamicResource NavButton}'>
  <StackPanel Orientation='Horizontal'>
    <TextBlock Text='$('&#x{0:X};' -f [int][char]$c.Icon)' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='15' Width='20' TextAlignment='Center' VerticalAlignment='Center' Margin='0,0,10,0'>
      <TextBlock.Style>
        <Style TargetType='TextBlock'>
          <Setter Property='Foreground' Value='#98989D'/>
          <Style.Triggers>
            <DataTrigger Binding='{Binding IsChecked, RelativeSource={RelativeSource AncestorType=RadioButton}}' Value='True'>
              <Setter Property='Foreground' Value='#0A84FF'/>
            </DataTrigger>
          </Style.Triggers>
        </Style>
      </TextBlock.Style>
    </TextBlock>
    <TextBlock Text='$(Esc $c.Title)' VerticalAlignment='Center'/>
  </StackPanel>
</RadioButton>
"@)
    $rb.Tag = $c
    $rb.Add_Checked({
        param($s, $e)
        $script:CurrentCat = $s.Tag
        $ui.Search.Text = ''
        Update-Filter
        Reset-Scroll
        if ($s.Tag.Page) { Show-Animated $ui.PageHost 12 280 } else { Show-Animated $ui.Scroller 12 280 }
        if ($s.Tag.Page -and $script:PageRefresh[$s.Tag.Page]) { & $script:PageRefresh[$s.Tag.Page] }
    })
    $script:NavButtons[$c.Name] = $rb
    [void]$navTarget.Children.Add($rb)
}

# --------------------------------------------------------------- header ---
# --- Windows restore point. Windows allows one per 24 h by default, so the result is checked, not assumed.
function New-ZeroDelayRestorePoint {
    try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch {}
    $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
    try { Checkpoint-Computer -Description 'ZeroDelay - before tweaks' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { return "Could not create a restore point: $($_.Exception.Message)" }
    $after = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
    if ($after -gt $before) { $script:Backup.Custom['restorepoint'] = (Get-Date).ToString('o'); Save-Backup; return 'Restore point created. You can roll back from Control Panel > Recovery.' }
    'Windows skipped it: it only allows one restore point every 24 hours, and one already exists from today.'
}
$ui.RestorePoint.Add_Click({
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $msg = New-ZeroDelayRestorePoint
    $window.Cursor = $null
    Show-Toast $msg $(if ($msg -like 'Restore point created*') { '#30D158' } else { '#FF9F0A' })
})

$ui.MoreBtn.Add_Click({ $ui.MorePop.IsOpen = -not $ui.MorePop.IsOpen })
$window.FindName('ActivePanel').Add_MouseLeftButtonUp({ Select-NavPage 'Active' })
$ui.RestorePoint.Add_PreviewMouseLeftButtonUp({ $ui.MorePop.IsOpen = $false })
$ui.RestoreAll.Add_PreviewMouseLeftButtonUp({ $ui.MorePop.IsOpen = $false })
$ui.ApplyRec.Add_Click({ Show-OptimizeChooser })
# Shows every recommended tweak that is still off; nothing changes until you tick what you want and confirm.
function Show-OptimizeChooser {
    $owned = Get-BoosterOwned
    $list = @($Tweaks | Where-Object { $_.Rec -and $_.Toggle -and -not $_.Hidden -and $_.State -eq $false -and $owned -notcontains $_.Id })
    if (-not $list.Count) { Show-Toast 'Everything recommended for this PC is already on.' '#30D158'; return }
    $catTitle = @{}; foreach ($c in $Categories) { $catTitle[$c.Name] = $c.Title }
    $order = @{}; for ($i = 0; $i -lt $Categories.Count; $i++) { $order[$Categories[$i].Name] = $i }
    $i = 0
    $groups = foreach ($grp in ($list | Group-Object { $_.Cat } | Sort-Object { $order[$_.Name] })) {
        $rows = foreach ($t in $grp.Group) {
            $t.ChooseIdx = $i; $i++
            $badge = if ($t.Badge -eq 'restart') { "<Border Background='#260A84FF' CornerRadius='6' Padding='6,0,6,1' Margin='8,0,0,0' VerticalAlignment='Center'><TextBlock Text='needs restart' FontSize='10.5' Foreground='#0A84FF'/></Border>" } else { '' }
            "<Border Background='#14FFFFFF' CornerRadius='10' Padding='12,9' Margin='0,0,0,6'><Grid><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
            "<CheckBox x:Name='C_$($t.ChooseIdx)' VerticalAlignment='Top' Margin='0,2,10,0'/>" +
            "<StackPanel Grid.Column='1'><StackPanel Orientation='Horizontal'><TextBlock Text='$(Esc $t.Title)' FontSize='13' FontWeight='SemiBold' TextWrapping='Wrap'/>$badge</StackPanel>" +
            "<TextBlock Text='$(Esc $t.Desc)' FontSize='12' Foreground='#A1A1A6' TextWrapping='Wrap' Margin='0,2,0,0'/>" +
            $(if ($t.Warn) { "<TextBlock Text='$(Esc "Skip it if: $($t.Warn)")' FontSize='11.5' Foreground='#FF9F0A' TextWrapping='Wrap' Margin='0,3,0,0'/>" } else { '' }) +
            "</StackPanel></Grid></Border>"
        }
        "<TextBlock Text='$(Esc $(if ($catTitle[$grp.Name]) { $catTitle[$grp.Name] } else { $grp.Name }))' FontSize='12' FontWeight='SemiBold' Foreground='#98989D' Margin='2,10,0,6'/>$($rows -join '')"
    }
    $body = [ZdTheme]::Parse(@"
<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <TextBlock Text='Choose what to switch on' FontSize='22' FontWeight='Bold'/>
  <TextBlock Text='$($list.Count) recommended tweaks are off on this PC. Tick only the ones you want: nothing changes until you press Switch on. Every change can be undone later.' Foreground='#A1A1A6' FontSize='13' Margin='0,6,0,12' TextWrapping='Wrap'/>
  <StackPanel Orientation='Horizontal' Margin='0,0,0,4'>
    <Button x:Name='All' Content='Select all' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12' Margin='0,0,8,0'/>
    <Button x:Name='None' Content='Clear' Style='{DynamicResource Btn}' Padding='12,5' FontSize='12'/>
  </StackPanel>
  $($groups -join '')
  <StackPanel Orientation='Horizontal' HorizontalAlignment='Right' Margin='0,14,0,0'>
    <Button x:Name='Cancel' Content='Cancel' Style='{DynamicResource Btn}' Margin='0,0,8,0' MinWidth='90'/>
    <Button x:Name='Go' Content='Switch on 0' Style='{DynamicResource Btn}' Background='#0071E3' Foreground='#FFFFFF' MinWidth='130' IsEnabled='False'/>
  </StackPanel>
</StackPanel>
"@)
    $script:ChooseList = $list; $script:ChooseBody = $body
    $upd = { $n = @($script:ChooseList | Where-Object { $script:ChooseBody.FindName("C_$($_.ChooseIdx)").IsChecked }).Count; $g = $script:ChooseBody.FindName('Go'); $g.Content = "Switch on $n"; $g.IsEnabled = $n -gt 0 }
    $script:ChooseUpd = $upd
    foreach ($t in $list) { $cb = $body.FindName("C_$($t.ChooseIdx)"); $cb.Add_Click({ & $script:ChooseUpd }) }
    $body.FindName('All').Add_Click({ foreach ($t in $script:ChooseList) { $script:ChooseBody.FindName("C_$($t.ChooseIdx)").IsChecked = $true }; & $script:ChooseUpd })
    $body.FindName('None').Add_Click({ foreach ($t in $script:ChooseList) { $script:ChooseBody.FindName("C_$($t.ChooseIdx)").IsChecked = $false }; & $script:ChooseUpd })
    $body.FindName('Cancel').Add_Click({ Hide-Animated $ui.Wizard 200 })
    $body.FindName('Go').Add_Click({
        $pick = @($script:ChooseList | Where-Object { $script:ChooseBody.FindName("C_$($_.ChooseIdx)").IsChecked })
        Hide-Animated $ui.Wizard 200
        Invoke-ApplyTweaks $pick
    })
    $ui.WizardBody.Content = $body
    $ui.Wizard.Visibility = 'Visible'
    if ($script:Anim) { Start-Anim $ui.Wizard ([Windows.UIElement]::OpacityProperty) 0 1 220; Show-Animated $ui.WizardBody 24 380 60 }
}
function Invoke-ApplyTweaks($pick) {
    if (-not @($pick).Count) { return }
    if (-not $script:Backup.Custom.ContainsKey('restorepoint')) {
        $r = (Show-ZdDialog ("Create a Windows restore point first? It takes a few seconds and lets you roll everything back.") ('Restore point') ('YesNoCancel') ('Question'))
        if ($r -eq 'Cancel') { return }
        if ($r -eq 'Yes') { $window.Cursor = [Windows.Input.Cursors]::Wait; Show-Toast (New-ZeroDelayRestorePoint) '#A1A1A6'; $window.Cursor = $null }
        else { $script:Backup.Custom['restorepoint'] = 'declined'; Save-Backup }
    }
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $ok = 0; $failed = @()
    foreach ($t in @($pick)) {
        try { Invoke-TweakOn $t; $ok++ } catch { $failed += $t.Title }
    }
    Update-All
    $window.Cursor = $null
    $msg = "Switched on $ok tweak$(if ($ok -ne 1) { 's' })."
    if ($failed) { $msg += " Skipped: $($failed -join ', ')." }
    if ($Tweaks | Where-Object { $_.Badge -eq 'restart' -and $_.State }) { $msg += ' Restart your PC to finish.' }
    Show-Toast $msg $(if ($failed) { '#FF9F0A' } else { '#30D158' })
    if ($script:HomeUi) { Update-HomePage }
}

$script:SessionTimer = New-Object Windows.Threading.DispatcherTimer
$script:SessionTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:SessionTimer.Add_Tick({
    if (-not (Test-GameSession)) { $script:SessionTimer.Stop(); return }
    $sess = Get-Content $SessionFile -Raw | ConvertFrom-Json
    $running = Test-FortniteRunning
    if ($running -and -not $sess.SawFortnite) { $sess.SawFortnite = $true; $sess | ConvertTo-Json -Depth 4 | Set-Content $SessionFile -Encoding UTF8 }
    elseif (-not $running -and $sess.SawFortnite) {
        $msg = Stop-GameSession
        Update-SessionCard
        Show-Toast "Fortnite closed. $msg" '#30D158'
    }
})
if ((Test-GameSession) -and -not (Test-ZDGameMode)) { $script:SessionTimer.Start() }

# Game Mode watcher: turns on when Fortnite starts and off when it closes (while ZeroDelay is open).
$script:GmSuppress = $false   # set when you switch Game Mode off by hand during a match
$script:GmTimer = New-Object Windows.Threading.DispatcherTimer
$script:GmTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:GmTimer.Add_Tick({
    $prefs = Get-GameModePrefs
    $running = Test-FortniteRunning
    if (-not $running) { $script:GmSuppress = $false }
    if (Test-ZDGameMode) {
        $st = Get-Content $GameModeFile -Raw | ConvertFrom-Json
        if ($running -and -not $st.SawFortnite) { $st.SawFortnite = $true; $st | ConvertTo-Json -Depth 5 | Set-Content $GameModeFile -Encoding UTF8 }
        elseif (-not $running -and $st.SawFortnite -and $prefs.autooff) { Show-Toast "Fortnite closed. $(Disable-ZDGameMode)" '#30D158' }
    } elseif ($running -and $prefs.auto -and -not $script:GmSuppress) {
        $msg = Enable-ZDGameMode
        Show-Toast "Fortnite started. $msg" '#30D158'
    }
    Update-GameModeUi
})
if (-not $Snapshot) { $script:GmTimer.Start() }   # never auto-start Game Mode from a dev render

$ui.GmSwitch.Add_Click({
    $window.Cursor = [Windows.Input.Cursors]::Wait
    if ($ui.GmSwitch.IsChecked) { $msg = Enable-ZDGameMode } else { $msg = Disable-ZDGameMode; if (Test-FortniteRunning) { $script:GmSuppress = $true } }
    $window.Cursor = $null
    Show-Toast $msg '#30D158'
})

$ui.DriftFix.Add_Click({
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $msg = Repair-Drift $script:DriftItems
    $window.Cursor = $null
    $ui.DriftBar.Visibility = 'Collapsed'
    Add-History "Re-applied $(@($script:DriftItems).Count) changed setting(s)" 'drift' $null
    Show-Toast $msg '#30D158'
})
$ui.DriftIgnore.Add_Click({
    # Accept the other program's values: stop watching these settings.
    foreach ($i in @($script:DriftItems)) {
        switch ($i.Kind) {
            'tweak'  { Set-Applied $i.T.Id $false; Update-Card $i.T }
            'preset' { $script:Backup.Custom.Remove('lastpreset') }
            'nvlod'  { $script:Backup.Custom.Remove('nvlodvalue') }
        }
    }
    Save-Backup; Update-Summary
    $ui.DriftBar.Visibility = 'Collapsed'
    Show-Toast 'OK. ZeroDelay will stop watching those settings.' '#A1A1A6'
})
$script:DriftTimer = New-Object Windows.Threading.DispatcherTimer
$script:DriftTimer.Interval = [TimeSpan]::FromSeconds(90)
$script:DriftTimer.Add_Tick({ Invoke-DriftCheck; Invoke-BoosterWatch })
$script:LastDriftOnFocus = [datetime]::MinValue
$window.Add_Activated({
    if ($Snapshot) { return }
    if (((Get-Date) - $script:LastDriftOnFocus).TotalSeconds -gt 60) { $script:LastDriftOnFocus = Get-Date; Invoke-DriftCheck }
})
if (-not $Snapshot) { $script:DriftTimer.Start() }

$ui.UpdateLater.Add_Click({ $script:UpdateSnoozed = $true; Hide-Animated $ui.UpdateBar 200 })
$ui.UpdateGet.Add_Click({ Install-Update })
# first check shortly after start (so it never slows the window opening), then every 6 hours
$script:UpdateTimer = New-Object Windows.Threading.DispatcherTimer
$script:UpdateTimer.Interval = [TimeSpan]::FromSeconds(6)
$script:UpdateTimer.Add_Tick({
    if (-not $script:StartupChecked) { $script:StartupChecked = $true; Repair-StartupTask }
    $script:UpdateTimer.Interval = [TimeSpan]::FromHours(6)
    if (Get-Setting 'autoupdate' $true) { Start-UpdateCheck }
})
if (-not $Snapshot) { $script:UpdateTimer.Start() }

# match recorder: starts when Fortnite starts, builds the report when it closes
$script:MatchTimer = New-Object Windows.Threading.DispatcherTimer
$script:MatchTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:MatchTimer.Add_Tick({
    if ($script:MatchAnalysis) { Complete-MatchReport }
    $running = Test-FortniteRunning
    if ($running -and -not $script:MatchRec -and -not $script:MatchAnalysis -and (Get-Setting 'matchreport' $true)) { Start-MatchRecorder }
    elseif (-not $running -and $script:MatchRec) { Stop-MatchRecorder }
})
if (-not $Snapshot) { $script:MatchTimer.Start() }

$ui.RestartLater.Add_Click({
    # Hide until the next change that needs a restart; the pending list is kept until the PC restarts.
    $script:RestartSnoozed = $true
    Update-RestartBar
    Show-Toast 'OK. Your changes are saved and will apply the next time you restart.' '#A1A1A6'
})

$ui.RestartNow.Add_Click({
    $restart = $script:Pending.Kind -eq 'restart'
    $msg = if ($restart) { 'Restart your PC now? Save anything you have open first.' } else { 'Sign out now? Save anything you have open first.' }
    if (Test-FortniteRunning) { $msg = "Fortnite is still running and will be closed.`n`n$msg" }
    $r = (Show-ZdDialog ($msg) ($(if ($restart) { 'Restart now' } else { 'Sign out now' })) ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    if ($restart) { shutdown.exe /r /t 5 /c 'ZeroDelay is restarting your PC to apply your changes.' }
    else { shutdown.exe /l }
})

$ui.RestoreAll.Add_Click({
    $r = (Show-ZdDialog ('Put every setting this app changed back to how it was?') ('Restore all') ('YesNo') ('Question'))
    if ($r -ne 'Yes') { return }
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $failed = @()
    foreach ($t in $Tweaks | Where-Object { $_.Toggle -and (Test-TweakHasBackup $_.Id) }) {
        try { Invoke-TweakOff $t } catch { $failed += $t.Title }
    }
    if ($script:Backup.Custom['nvsync']) { try { [void](Undo-NvSync) } catch { $failed += 'NVIDIA sync preset' } }
    $h = $script:Backup.Custom['nvrtxhdr']
    if ($h) {
        if ($null -ne $h.Value) { [void][NvDrs]::Set($NvProfile, [uint32]0x00DD48FB, [uint32]$h.Value) } else { [void][NvDrs]::Delete($NvProfile, [uint32]0x00DD48FB) }
        $script:Backup.Custom.Remove('nvrtxhdr'); Save-Backup
    }
    Update-All
    $window.Cursor = $null
    if ($failed) { Show-Toast "Restored, except: $($failed -join ', ')." '#FF9F0A' }
    else { Show-Toast 'All original settings restored. Restart to fully undo restart-only tweaks.' '#30D158' }
})

Set-SplashStatus 'Building the interface'
Initialize-Worker    # opens in the background while the cards are built
$catOrder = @{}; for ($i = 0; $i -lt $Categories.Count; $i++) { $catOrder[$Categories[$i].Name] = $i }
$n = 0
$Tweaks = @($Tweaks | Where-Object { -not ($_.Action -and $_.Requires -and -not (& $_.Requires)) })
$Tweaks = @($Tweaks | ForEach-Object { [pscustomobject]@{ T = $_; K = [int]$catOrder[$_.Cat] * 10000 + $n++ } } | Sort-Object K | ForEach-Object { $_.T })
Set-SplashStatus 'Checking your settings'
Start-StateRefresh { Show-AfterStartup }    # runs in the background while the cards are built
foreach ($t in $Tweaks) { [void]$ui.Cards.Children.Add((New-Card $t)) }

# Stretch cards so each row fills the width evenly (min ~320px per card).
# Smooth scrolling: the mouse wheel moves a target and the view glides toward it.
$script:ScrollTarget = 0.0
$script:ScrollTimer = New-Object Windows.Threading.DispatcherTimer
$script:ScrollTimer.Interval = [TimeSpan]::FromMilliseconds(12)
$script:ScrollTimer.Add_Tick({
    $sv = $ui.Scroller
    $d = $script:ScrollTarget - $sv.VerticalOffset
    if ([Math]::Abs($d) -lt 0.6) { $sv.ScrollToVerticalOffset($script:ScrollTarget); $script:ScrollTimer.Stop(); return }
    $sv.ScrollToVerticalOffset($sv.VerticalOffset + $d * 0.2)
})
$ui.Scroller.Add_PreviewMouseWheel({
    param($s, $e)
    $e.Handled = $true
    if (-not $script:ScrollTimer.IsEnabled) { $script:ScrollTarget = $s.VerticalOffset }
    $script:ScrollTarget = [Math]::Max(0, [Math]::Min($s.ScrollableHeight, $script:ScrollTarget - $e.Delta * 1.2))
    if (-not $script:ScrollTimer.IsEnabled) { $script:ScrollTimer.Start() }
})
function Reset-Scroll { $script:ScrollTimer.Stop(); $script:ScrollTarget = 0; $ui.Scroller.ScrollToVerticalOffset(0) }

$ui.Cards.Add_SizeChanged({
    $w = $ui.Cards.ActualWidth
    $cols = [Math]::Max(1, [Math]::Floor($w / 330))
    $cardW = [Math]::Floor($w / $cols) - 16
    foreach ($c in $ui.Cards.Children) { $c.Width = if ($c.Tag.Header -or $c.Tag.Extra -eq 'builder') { [Math]::Max(100, $w - 16) } else { $cardW } }
})
$startName = if ($Page -and $script:NavButtons.ContainsKey($Page)) { $Page } else { 'Home' }
Set-NavGroupOpen (Get-NavGroupOf $startName) $true
$script:NavButtons[$startName].IsChecked = $true
$window.Add_ContentRendered({ $script:NavButtons[$script:CurrentCat.Name].BringIntoView() })
Update-GameModeUi
function Complete-Startup {
$script:SysProfile = if ($Snapshot -and $env:ZD_SCANPC) { $null } else { Get-SavedProfile }
if ($script:SysProfile) { Set-ProfileTailoring } else { Set-GpuTailoring }
if (-not $Snapshot -and (Get-Setting 'keepawake' $false)) { Start-RenderWatch }
$profileAge = if ($script:SysProfile) { try { ((Get-Date) - [datetime]$script:SysProfile.ScannedAt).TotalDays } catch { 999 } } else { 999 }
if ((-not $Snapshot -and ($profileAge -gt 3 -or "$($script:SysProfile.AppVersion)" -ne $AppVersion)) -or ($Snapshot -and $env:ZD_SCANPC)) { Start-ProfileScan -Quiet }
if ((-not $Snapshot -and -not $script:Backup.Custom['wizarddone']) -or ($Snapshot -and $env:ZD_WIZARD)) { Show-Wizard }
elseif ($Snapshot -and $env:ZD_WHATSNEW) { Show-WhatsNew }
elseif (-not $Snapshot -and "$($script:Backup.Custom['lastversion'])" -ne $AppVersion) { Show-WhatsNew }
if (-not $Snapshot -and "$($script:Backup.Custom['lastversion'])" -ne $AppVersion) { $script:Backup.Custom['lastversion'] = $AppVersion; Save-Backup }
}
if ($Snapshot) {
    if ($env:ZD_PROFILE) {
        $sw = [Diagnostics.Stopwatch]::StartNew(); Update-All; [Console]::WriteLine("UPDATE-ALL {0} ms" -f $sw.ElapsedMilliseconds)
        $times = foreach ($t in $Tweaks | Where-Object { $_.Toggle }) { $sw.Restart(); [void](Invoke-TweakTest $t); [pscustomobject]@{ Id = $t.Id; Ms = $sw.ElapsedMilliseconds } }
        $times | Sort-Object Ms -Descending | Select-Object -First 25 | ForEach-Object { [Console]::WriteLine(("TEST {0,-34} {1,6} ms" -f $_.Id, $_.Ms)) }
        [Console]::WriteLine(("TESTS TOTAL {0} ms over {1}" -f ($times | Measure-Object Ms -Sum).Sum, @($times).Count))
        $sw.Restart(); Update-Summary; [Console]::WriteLine("UPDATE-SUMMARY {0} ms" -f $sw.ElapsedMilliseconds)
        $sw.Restart(); [void](Get-Drift); [Console]::WriteLine(("GET-DRIFT {0} ms (applied {1})" -f $sw.ElapsedMilliseconds, @(Get-Applied).Count))
        $sw.Restart(); [void](Test-FortniteRunning); [void](Get-GameModePrefs); [Console]::WriteLine("GM-TICK {0} ms" -f $sw.ElapsedMilliseconds)
        $sw.Restart(); [void](Get-NvSyncStatus); [Console]::WriteLine("NV-SYNC-STATUS {0} ms" -f $sw.ElapsedMilliseconds)
        $sw.Restart(); [void](Get-ActivePowerScheme); [Console]::WriteLine("POWERCFG {0} ms" -f $sw.ElapsedMilliseconds)
    }    if ($env:ZD_SCAN -and $script:Health) { Invoke-HealthScan }
    if ($env:ZD_DRIFT) { Invoke-DriftCheck; if (-not $script:DriftItems) { $ui.DriftTitle.Text = '2 settings were changed back — ExitLag is running'; $ui.DriftText.Text = 'Turn off USB 3 link power-saving  ·  USB hubs never suspend'; $ui.DriftBar.Visibility = 'Visible' } }
    if ($env:ZD_FAKE_UPDATE) { Start-UpdateCheck }
    if ($env:ZD_DEMO_RESTART) { $script:Pending = @{ Kind = 'restart'; Items = @('Hardware-accelerated GPU scheduling', 'Consistent timer resolution') }; Update-RestartBar }
    if ($script:Glass) {
        $bg = New-Object Windows.Media.LinearGradientBrush; $bg.StartPoint = '0,0'; $bg.EndPoint = '1,1'
        foreach ($st in @(@('#FF050506', 0), @('#FF08070B', 0.55), @('#FF040606', 1))) { $bg.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($st[0])), $st[1])) }
        if ($script:Theme -eq 'light') { $bg.GradientStops.Clear(); foreach ($st in @(@('#FFDDE4F2', 0), @('#FFEADFF0', 0.55), @('#FFDCEDEB', 1))) { $bg.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($st[0])), $st[1])) } }
        $window.Background = [Windows.Media.Brush]$bg
    }
    $window.Add_ContentRendered({
        $script:SnapTimer = New-Object Windows.Threading.DispatcherTimer
        $script:SnapTimer.Interval = [TimeSpan]::FromSeconds($(if ($env:ZD_SNAPWAIT) { [double]$env:ZD_SNAPWAIT } else { 1 }))
        $script:SnapTimer.Add_Tick({ $script:SnapTimer.Stop(); Save-Snapshot })
        $script:SnapTimer.Start()
    })
    function Save-Snapshot {
        foreach ($t in $Tweaks) { if ($t.Toggle) { [Console]::WriteLine(("{0,-10} {1,-34} {2}" -f $t.Cat, $t.Id, $(if ($null -eq $t.State) { "n/a" } else { $t.State }))) } }
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, 'Pbgra32')
        $bmp.Render($window)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
        $window.Close()
    }
}
if (-not $Snapshot) {
    $script:TrayIcon = New-TrayIcon
    $script:ReallyExit = $false
    $window.Add_Closing({
        param($s, $e)
        if (-not $script:ReallyExit -and (Get-Setting 'closetotray' $true)) {
            $e.Cancel = $true
            $window.Hide()
            if (-not $script:Backup.Custom['traytipshown']) {
                $script:TrayIcon.ShowBalloonTip(4000, 'ZeroDelay is still running', 'Game Mode and alerts keep working. Right-click this icon to exit.', 'None')
                $script:Backup.Custom['traytipshown'] = $true; Save-Backup
            }
        }
    })
    # a second launch signals this one to come to the front
    $script:ShowTimer = New-Object Windows.Threading.DispatcherTimer
    $script:ShowTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:ShowTimer.Add_Tick({ if ($script:ShowSignal.WaitOne(0)) { Show-MainWindow } })
    $script:ShowTimer.Start()
}
$window.Add_Closed({
    if ($script:PingMonJob) { Stop-PingMonitor }
    Save-Backup
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
    $window.Dispatcher.InvokeShutdown()
})
$window.Add_ContentRendered({ Close-Splash; [void]$window.Activate() })
$script:StartupDone = $false
function Show-AfterStartup {
    if ($script:StartupDone) { return }
    $script:StartupDone = $true
    if ($script:StartupGuard) { $script:StartupGuard.Stop() }
    Complete-Startup
    if (-not $Tray -or $Snapshot) { $window.Show() } else { Close-Splash }
    # build the heavier pages while nothing is happening, so their first visit is instant
    $script:WarmTimer = New-Object Windows.Threading.DispatcherTimer
    $script:WarmTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:WarmTimer.Add_Tick({
        $next = @('GameMode', 'Settings', 'Home') | Where-Object { -not $script:Pages.ContainsKey($_) } | Select-Object -First 1
        if (-not $next) { $script:WarmTimer.Stop(); return }
        try { [void](Get-PageContent $next) } catch {}
    })
    if (-not $Snapshot) { $script:WarmTimer.Start() }
}
# never leave someone staring at the loading screen: after 30 s check here instead
$script:StartupGuard = New-Object Windows.Threading.DispatcherTimer
$script:StartupGuard.Interval = [TimeSpan]::FromSeconds(30)
$script:StartupGuard.Add_Tick({ $script:StartupGuard.Stop(); if (-not $script:StartupDone) { Update-All; Show-AfterStartup } })
$script:StartupGuard.Start()
[Windows.Threading.Dispatcher]::Run()
if ($script:Relaunch) {
    try { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() } catch {}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -Page Settings$(if ($NoElevate) { ' -NoElevate' })"
}