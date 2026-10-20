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
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$(if ($Tray) { ' -Tray' })"
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not $Snapshot) {
    $created = $false
    $script:AppMutex = New-Object System.Threading.Mutex($true, 'Local\ZeroDelayApp', [ref]$created)
    $script:ShowSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\ZeroDelayShow')
    if (-not $created) { [void]$script:ShowSignal.Set(); exit }
}
$AppVersion = '1.2.0'
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
    static readonly Regex Hex = new Regex("#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6})(?![0-9A-Fa-f])");
    public static string Apply(string s) {
        if (s == null || Map.Count == 0) return s;
        return Hex.Replace(s, m => {
            string h = m.Groups[1].Value, a = "";
            if (h.Length == 8) { a = h.Substring(0, 2); h = h.Substring(2); }
            string t;
            return Map.TryGetValue(h, out t) ? "#" + a + t : m.Value;
        });
    }
    public static object Parse(string xaml) { return System.Windows.Markup.XamlReader.Parse(Apply(xaml)); }
    public static System.Windows.Media.Brush Brush(string c) {
        return (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFrom(Apply(c));
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
    static int With(string profile, bool save, Func<IntPtr, IntPtr, int> op) {
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

function Save-Backup { $script:Backup | ConvertTo-Json -Depth 8 | Set-Content -Path $BackupFile -Encoding UTF8 }

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
function Get-Cached([string]$Key, [scriptblock]$Load) {
    $c = $script:ReadCache[$Key]
    if ($c -and ((Get-Date) - $c.Time).TotalSeconds -lt 4) { return $c.Data }
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

# --- Builds a card that disables a Windows service (Start = 4) and restores its default start type.
function New-SvcTweak([string]$Id, [string]$Svc, [int]$Default, [string]$Title, [string]$Desc, [string]$Warn, [bool]$Rec, [string]$Badge) {
    @{ Id = $Id; Cat = 'Services'; Icon = [char]0xE912; Rec = $Rec; Badge = $Badge; Svc = $Svc
       Title = $Title; Desc = $Desc; Warn = $Warn
       Reg   = @( @{ P = "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc"; N = 'Start'; V = 4; D = $Default; M = $Default } )
       After = { Sync-Service $t.Svc } }
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
    @{ Key = 'phonelink'; Name = 'Phone Link, Widgets, Copilot'; PathRx = '\\(PhoneExperienceHost|Widgets|WidgetService|Copilot)\.exe$'; Main = $null }
    @{ Key = 'wallpaper'; Name = 'Wallpaper Engine (paused, not closed)'; PathRx = '\\wallpaper_engine\\'; Main = $null; Pause = $true }
)
$SessionFile = Join-Path $DataDir 'game-session.json'
function Get-SessionPrefs {
    $p = @{}; foreach ($a in $SessionApps) { $p[$a.Key] = $true }
    $p['xbox'] = $true; $p['streamdock'] = $false   # Stream Dock stays open by default: many people use it mid-game
    $saved = $script:Backup.Custom['sessionprefs']
    if ($saved -is [hashtable]) { foreach ($k in @($saved.Keys)) { $p[$k] = [bool]$saved[$k] } }
    elseif ($saved) { $saved.PSObject.Properties | ForEach-Object { $p[$_.Name] = [bool]$_.Value } }
    $p
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
    foreach ($app in $SessionApps | Where-Object { $prefs[$_.Key] }) {
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
    $state = @{ Started = (Get-Date).ToString('o'); SawFortnite = (Test-FortniteRunning); Done = @() }
    $done = @()
    if ($prefs.apps) {
        $msg = Start-GameSession
        $script:SessionTimer.Stop()          # Game Mode decides when apps come back
        $state.Session = $true
        if ($msg -match 'Closed: (.+?)\. Everything') { $done += "closed $($Matches[1])" }
    }
    if ($prefs.plan) {
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
function Get-History {
    if ($null -eq $script:History) {
        $script:History = @()
        if (Test-Path $HistoryFile) { try { $script:History = @(Get-Content $HistoryFile -Raw | ConvertFrom-Json) } catch {} }
    }
    $script:History
}
function Add-History([string]$Title, [string]$Action, [string]$Id) {
    $entry = [pscustomobject]@{ Time = (Get-Date).ToString('o'); Title = $Title; Action = $Action; Id = $Id }
    $script:History = @($entry) + @(Get-History | Select-Object -First 299)
    try { ConvertTo-Json -InputObject @($script:History) -Depth 3 | Set-Content $HistoryFile -Encoding UTF8 } catch {}
}
function Get-Applied { @($script:Backup.Custom['applied'] | Where-Object { $_ }) }
function Set-Applied([string]$Id, [bool]$On) {
    $list = @(Get-Applied | Where-Object { $_ -ne $Id })
    if ($On) { $list += $Id }
    $script:Backup.Custom['applied'] = $list
}

function Invoke-TweakOn($t) {
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
if (Test-Path $PendingFile) {
    try {
        $p = Get-Content $PendingFile -Raw | ConvertFrom-Json
        if ($p.Boot -eq $script:BootId) { $script:Pending = @{ Kind = $p.Kind; Items = @($p.Items) } } else { Remove-Item $PendingFile -Force }
    } catch {}
}
function Add-PendingRestart($t) {
    if ($t.Badge -notin 'restart', 'signout') { return }
    if ($script:Pending.Items -notcontains $t.Title) { $script:Pending.Items += $t.Title }
    if ($t.Badge -eq 'restart' -or -not $script:Pending.Kind) { $script:Pending.Kind = $t.Badge }
    $script:RestartSnoozed = $false
    @{ Kind = $script:Pending.Kind; Items = $script:Pending.Items; Boot = $script:BootId } | ConvertTo-Json | Set-Content $PendingFile -Encoding UTF8
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
    '3D3D41' = 'DCDCE1'; '38383B' = 'D8D8DD'; '303033' = 'EDEDF2'
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
$acc = if ($script:Theme -eq 'light') { $Accents[$script:Accent].Light } else { $Accents[$script:Accent].Dark }
[ZdTheme]::Map['0A84FF'] = $acc[0]; [ZdTheme]::Map['0071E3'] = $acc[1]; [ZdTheme]::Map['273A4F'] = $acc[2]

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
      <Setter Property="Background" Value="{StaticResource BgCard}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Separator}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
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
      <Setter Property="Background" Value="#3A3A3C"/>
      <Setter Property="Foreground" Value="#F5F5F7"/>
      <Setter Property="BorderBrush" Value="#4A4A4D"/>
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
                  <Border CornerRadius="8" Background="#2C2C2E">
                    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
                  </Border>
                  <Border CornerRadius="8" Background="#2C2C2E" BorderBrush="#48484A" BorderThickness="1" Padding="4">
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
            <StackPanel Margin="15,10,15,12">
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
          <Button x:Name="RestorePoint" Content="Restore point" Style="{StaticResource Btn}" Margin="0,0,8,0"
                  ToolTip="Create a Windows restore point you can roll back to if anything goes wrong."/>
          <Button x:Name="RestoreAll" Content="Restore all" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="ApplyRec" Content="Apply recommended" Style="{StaticResource Btn}" Background="#0071E3" Foreground="#FFFFFF"/>
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
        <Border CornerRadius="14" Background="#3A3A3C">
          <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="8" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
        </Border>
        <Border CornerRadius="14" Background="#3A3A3C" BorderBrush="#48484A" BorderThickness="1" Padding="14,10,18,10">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="ToastIcon" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="15" Foreground="#30D158" VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Collapsed"/>
            <TextBlock x:Name="ToastText" FontSize="13" FontWeight="Medium" Foreground="#F5F5F7" TextWrapping="Wrap" MaxWidth="560" VerticalAlignment="Center" LineHeight="18" LineStackingStrategy="BlockLineHeight"/>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
    <Grid x:Name="Wizard" Grid.ColumnSpan="2" Background="#99000000" Visibility="Collapsed">
      <Grid Width="600" Margin="24" VerticalAlignment="Center" HorizontalAlignment="Center">
        <Border CornerRadius="16" Background="#2C2C2E">
          <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="16" Direction="270" Opacity="0.55" Color="Black"/></Border.Effect>
        </Border>
        <Border Background="#2C2C2E" BorderBrush="#48484A" BorderThickness="1" CornerRadius="16" Padding="32,28,20,28">
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
$window.Add_SourceInitialized({
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        $dk = $script:Theme -ne 'light'
        $v = [int]$dk; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)                         # dark title bar
        $v = if ($dk) { 0x001E1C1C } else { 0x00F7F2F2 }; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$v, 4)  # caption = window colour
        $v = if ($dk) { 0x003A3838 } else { 0x00E5E0E0 }; [void][ZD.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$v, 4)  # border = separator
    } catch {}
})
$LogoIco = Join-Path $PSScriptRoot 'ZeroDelay.ico'
if (-not (Test-Path $LogoIco)) { try { Save-LogoIco $LogoIco } catch {} }
if (Test-Path $LogoIco) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$LogoIco, 'None', 'OnLoad') } catch {}
}
$ui = @{}
foreach ($n in 'Nav', 'Cards', 'PageTitle', 'StatusLine', 'RestoreAll', 'ApplyRec', 'Toast', 'ToastText', 'ActiveCount', 'ActiveBar', 'Search', 'SearchHint', 'LatencyNote',
            'RestartBar', 'RestartTitle', 'RestartText', 'RestartNow', 'RestartLater', 'Scroller', 'RestorePoint', 'GmPanel', 'GmStatus', 'GmSwitch',
            'PageHost', 'DriftBar', 'DriftTitle', 'DriftText', 'DriftIgnore', 'DriftFix', 'Wizard', 'WizardBody', 'ToastIcon',
            'UpdateBar', 'UpdateTitle', 'UpdateText', 'UpdateLater', 'UpdateGet') { $ui[$n] = $window.FindName($n) }

$BadgeInfo = @{
    restart  = @{ Color = '#0A84FF'; Label = 'Needs restart'; Tip = 'Takes effect after you restart the PC.' }
    signout  = @{ Color = '#0A84FF'; Label = 'Needs sign-out'; Tip = 'Takes effect after you sign out and back in.' }
    advanced = @{ Color = '#FF9F0A'; Label = 'Advanced'; Tip = 'Advanced: benefit depends on your hardware. Test with and without.' }
}

function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }

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
# Fades an element in while sliding it up (or down for a negative distance) into place.
function Show-Animated($el, [double]$dy = 10, [int]$ms = 260, [int]$delay = 0) {
    if (-not $el) { return }
    if (-not $script:Anim) { $el.Opacity = 1; return }
    $tt = New-Object Windows.Media.TranslateTransform 0, $dy
    $el.RenderTransform = $tt
    $el.Opacity = 0
    Start-Anim $el ([Windows.UIElement]::OpacityProperty) 0 1 $ms $delay
    Start-Anim $tt ([Windows.Media.TranslateTransform]::YProperty) $dy 0 ($ms + 60) $delay
}
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
    if (-not $script:CountTimer) {
        $script:CountTimer = New-Object Windows.Threading.DispatcherTimer
        $script:CountTimer.Interval = [TimeSpan]::FromMilliseconds(16)
        $script:CountTimer.Add_Tick({
            $left = @()
            foreach ($j in $script:CountJobs) {
                $t = [Math]::Min(1.0, ((Get-Date) - $j.Start).TotalMilliseconds / $j.Ms)
                $e = 1 - [Math]::Pow(1 - $t, 3)
                $j.Tb.Text = "$([int][Math]::Round($j.To * $e))$($j.Suffix)"
                if ($t -lt 1) { $left += $j }
            }
            $script:CountJobs = $left
            if (-not $left) { $script:CountTimer.Stop() }
        })
    }
    $script:CountTimer.Start()
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
    $recTag = if ($t.Rec) { "<StackPanel Orientation='Horizontal' Margin='0,12,14,0' VerticalAlignment='Center' Background='Transparent' ToolTip='Included when you press Apply recommended'><TextBlock Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='11' Foreground='#30D158' VerticalAlignment='Center' Margin='0,1,5,0'/><TextBlock Text='Recommended' FontSize='12' FontWeight='Medium' Foreground='#A1A1A6' VerticalAlignment='Center'/></StackPanel>" } else { '' }
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
    $b.Bar.Width = 2.6 * [Math]::Max(3, $score); $b.Bar.Background = $brush
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
    $b = @{}
    foreach ($n in 'Score', 'Bar', 'Res', 'ResText', 'View', 'ViewText', 'Blur', 'BlurText', 'Grass') { $b[$n] = $panel.FindName($n) }
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
    $panel
}
function Invoke-Builder($t) {
    $fake = @{ Title = 'Custom potato'; Preset = (Get-BuilderValues) }
    Invoke-Preset $fake
}

# Game-session card: one switch per app, saved between launches.
function New-SessionPanel($t) {
    $prefs = Get-SessionPrefs
    $rows = ($SessionApps | ForEach-Object {
        "<Grid Margin='0,0,0,6'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        "<TextBlock Text='$(Esc $_.Name)' Foreground='#D1D1D6' FontSize='12' VerticalAlignment='Center'/>" +
        "<ToggleButton x:Name='S_$($_.Key)' Grid.Column='1' Style='{DynamicResource Switch}' Width='34' Height='18'/></Grid>"
    }) -join ''
    $panel = [ZdTheme]::Parse(@"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        CornerRadius='8' Background='#1C1C1E' BorderThickness='0' Padding='14,10'>
  <StackPanel>$rows</StackPanel>
</Border>
"@)
    foreach ($a in $SessionApps) {
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

function Update-Card($t) {
    if ($t.Preset) {
        $pillEl = $t.Card.FindName('ActivePill')
        if ($pillEl) { $pillEl.Visibility = if (Test-Preset $t) { 'Visible' } else { 'Collapsed' } }
        return
    }
    if (-not $t.Toggle) { return }
    $state = Invoke-TweakTest $t
    $t.State = $state
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
}

function Update-RestartBar {
    $n = @($script:Pending.Items).Count
    if (-not $n -or $script:RestartSnoozed) { $ui.RestartBar.Visibility = 'Collapsed'; return }
    $restart = $script:Pending.Kind -eq 'restart'
    $what = if ($n -eq 1) { '1 change' } else { "$n changes" }
    $ui.RestartTitle.Text = if ($restart) { "Restart needed for $what to take effect" } else { "Sign out and back in for $what to take effect" }
    $ui.RestartText.Text = $script:Pending.Items -join '  ·  '
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
    @{ Name = 'All';        Icon = [char]0xE80F; Title = 'All optimizations' }
    @{ Name = 'Latency';    Icon = [char]0xE916; Title = 'Latency & delay'
       Note = 'Only the tweaks that change input delay, frame time or ping. Green icons mark them in every tab.' }
    @{ Name = 'GameMode';   Icon = [char]0xE768; Title = 'Game Mode'
       Note = 'Turn it on before you play, or let it switch on by itself when Fortnite starts. ZeroDelay must stay open for the automatic part.' }
    @{ Name = 'Potato';     Icon = [char]0xE7F4; Title = 'Potato graphics'
       Note = 'Ugly but fast. Performance mode, low mesh and lower 3D resolution give the biggest gains; Fortnite must be closed to apply.' }
    @{ Name = 'Fortnite';   Icon = [char]0xE7FC; Title = 'Fortnite' }
    @{ Name = 'System';     Icon = [char]0xE7F8; Title = 'System' }
    @{ Name = 'Power';      Icon = [char]0xE945; Title = 'Power & CPU' }
    @{ Name = 'Graphics';   Icon = [char]0xE7F4; Title = 'Graphics' }
    @{ Name = 'Input';      Icon = [char]0xE962; Title = 'Input & audio' }
    @{ Name = 'Network';    Icon = [char]0xE839; Title = 'Network' }
    @{ Name = 'Background'; Icon = [char]0xE895; Title = 'Background & privacy' }
    @{ Name = 'Services';   Icon = [char]0xE912; Title = 'Services & tasks' }
    @{ Name = 'Storage';    Icon = [char]0xEDA2; Title = 'Storage & updates' }
    @{ Name = 'Visuals';    Icon = [char]0xE790; Title = 'Desktop visuals' }
    @{ Name = 'Startup';    Icon = [char]0xE768; Title = 'Startup apps' }
    @{ Name = 'Repair';     Icon = [char]0xE90F; Title = 'Repair old tweaks' }
    @{ Name = 'Nvidia';     Icon = [char]0xE7F4; Title = 'NVIDIA'; Page = 'Nvidia'; Section = 'TOOLS'
       Note = 'G-SYNC, V-Sync and frame cap setup, NVIDIA App features that cost FPS, and your driver.' }
    @{ Name = 'Health';     Icon = [char]0xE95E; Title = 'Health check'; Page = 'Health'
       Note = 'One scan for the problems that cost you the most. Fix them one by one or all at once.' }
    @{ Name = 'Benchmark';  Icon = [char]0xE9D9; Title = 'Benchmark'; Page = 'Benchmark'
       Note = 'Measure real FPS, 1% lows and latency in Fortnite, then compare before and after a change.' }
    @{ Name = 'Matches';    Icon = [char]0xE7FC; Title = 'Match reports'; Page = 'Matches'
       Note = 'After each Fortnite session: stutters and what was busy at that moment, GPU heat, background apps and memory.' }
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
        $color = switch ($h.Action) { 'on' { '#30D158' } 'off' { '#FF9F0A' } default { '#0A84FF' } }
        $word = switch ($h.Action) { 'on' { 'Turned on' } 'off' { 'Turned off' } 'preset' { 'Applied' } 'gamemode' { 'Game Mode' } default { $h.Action } }
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
    # --- memory
    $ram = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if ($ram.Count) {
        $run = ($ram | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
        $isDdr5 = ($ram | Where-Object { $_.SMBIOSMemoryType -eq 34 }).Count -gt 0
        if (($isDdr5 -and $run -le 4800) -or (-not $isDdr5 -and $run -le 2666)) {
            Add-Issue 2 "RAM runs at $run MT/s" 'That is the slow default speed. Turn on XMP (Intel) or EXPO (AMD) in your BIOS to run it at its rated speed.' $null $null
        }
    }
    # --- other tools that undo settings
    $tools = @{ 'ExitLag' = 'ExitLag'; 'EXM' = 'EXM'; 'GearUP' = 'GearUP Booster'; 'RazerCortex' = 'Razer Cortex'; 'ProcessLasso' = 'Process Lasso'; 'WTFast' = 'WTFast'; 'NoPing' = 'NoPing' }
    $running = foreach ($k in $tools.Keys) { if (Get-Process -Name "$k*" -ErrorAction SilentlyContinue) { $tools[$k] } }
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
    if ($drv -and $drv.Latest -and $drv.Installed -and [version]$drv.Latest -gt [version]$drv.Installed) {
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
function Get-BenchRuns { if (Test-Path $BenchFile) { try { @(Get-Content $BenchFile -Raw | ConvertFrom-Json) } catch { @() } } else { @() } }
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
        $r = [Windows.MessageBox]::Show("Download PresentMon 2.6.0 from Intel's official GitHub page?`n`n$PresentMonUrl`n`nIt is Intel's free frame-time recorder. ZeroDelay saves it to its own folder and only runs it when you start a benchmark.", 'Download PresentMon', 'YesNo', 'Question')
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
            $r = [Windows.MessageBox]::Show("Profile '$($o.Name)' switches on $(@($o.On).Count) cards$(if ($o.Preset) { ", sets the '$($o.Preset.Title)' graphics preset" })$(if ($o.FpsCap) { " and an FPS cap of $([int][double]$o.FpsCap)" }).`n`nSave it to your profiles? (Nothing changes until you press Apply.)", 'Import profile', 'YesNo', 'Question')
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
    $wz = @{}; foreach ($n in 'Desk', 'Lap', 'LookComp', 'LookFlat', 'LookKeep', 'StreamNo', 'StreamYes', 'Progress', 'Skip', 'Go') { $wz[$n] = $body.FindName($n) }
    $script:Wiz = $wz
    if ($hw.Laptop) { $wz.Lap.IsChecked = $true } else { $wz.Desk.IsChecked = $true }
    if (-not $hw.Nvidia) { $wz.LookFlat.IsEnabled = $false }
    $wz.Skip.Add_Click({ $script:Backup.Custom['wizarddone'] = $true; Save-Backup; $ui.Wizard.Visibility = 'Collapsed' })
    $wz.Go.Add_Click({ Invoke-Wizard })
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
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text='Theme' Foreground='#A1A1A6' FontSize='12.5' VerticalAlignment='Center'/>
        <StackPanel Grid.Column='1' Orientation='Horizontal'>
          <Button x:Name='T_dark' Content='Dark' Style='{DynamicResource Btn}' Margin='0,0,8,0' MinWidth='72'/>
          <Button x:Name='T_light' Content='Light' Style='{DynamicResource Btn}' Margin='0,0,8,0' MinWidth='72'/>
          <Button x:Name='T_system' Content='Match Windows' Style='{DynamicResource Btn}'/>
        </StackPanel>
        <TextBlock Grid.Row='1' Text='Accent colour' Foreground='#A1A1A6' FontSize='12.5' VerticalAlignment='Center' Margin='0,14,0,0'/>
        <StackPanel x:Name='Swatches' Grid.Row='1' Grid.Column='1' Orientation='Horizontal' Margin='0,14,0,0'/>
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
    $st = @{}; foreach ($n in 'S_closetotray', 'S_autofix', 'S_autoupdate', 'S_startup', 'S_matchreport', 'UpdReport', 'Wizard', 'Folder', 'About', 'T_dark', 'T_light', 'T_system', 'Swatches', 'ThemeNote', 'ThemeApply',
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
    $changed = ($mode -ne $script:ThemeMode) -or ($acc -ne $script:Accent)
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
    $r = [Windows.MessageBox]::Show("Update ZeroDelay to $($u.Version) now?`n`nZeroDelay downloads the new setup from GitHub, checks it, closes, installs it and opens again. It takes about 10 seconds. Your settings, backups and history are kept.", 'ZeroDelay update', 'YesNo', 'Question')
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
    param($sync, $smi, $smiField, $cores, $exclude, $selfPid)
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
                if ($pct -ge 3) { $top += [pscustomobject]@{ Name = $p.ProcessName; Pct = [Math]::Round($pct, 1) } }
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
        [void]$sync.Samples.Add([pscustomobject]@{ T = $now; Top = @($top | Sort-Object Pct -Descending | Select-Object -First 3); Gpu = $gpu; FreeMb = $free })
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
    [void]$ps.AddScript($MatchSampler.ToString()).AddArgument($sync).AddArgument($smi).AddArgument($script:SmiField).AddArgument([Environment]::ProcessorCount).AddArgument(@('Idle', ($FortniteExeName -replace '\.exe$'))).AddArgument($PID)
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
    if (-not $window.IsVisible -and $script:Tray) {
        $script:BalloonPage = 'Matches'
        $script:Tray.ShowBalloonTip(6000, 'ZeroDelay match report', "$sum Click to see it.", 'None')
    }
}
function New-MatchReport($Start, $End, $Frames, $Samples) {
    $samples = @($Samples | Where-Object { $_ })
    $n = [Math]::Max(1, $samples.Count)
    $issues = @()
    # background apps
    $hog = @{}
    foreach ($s in $samples) { foreach ($p in @($s.Top)) {
        if (-not $hog.ContainsKey($p.Name)) { $hog[$p.Name] = @{ Sum = 0.0; Max = 0.0 } }
        $hog[$p.Name].Sum += $p.Pct; if ($p.Pct -gt $hog[$p.Name].Max) { $hog[$p.Name].Max = $p.Pct }
    } }
    $hogs = @($hog.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Avg = [Math]::Round($hog[$_].Sum / $n, 1); Max = $hog[$_].Max } } |
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
    }
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
    $stX
  </StackPanel>
</Border>
"@)
        $del = $card.FindName('Del')
        if ($r.File) { $del.Tag = $r.File; $del.Add_Click({ param($s, $e) Remove-Item $s.Tag -Force -ErrorAction SilentlyContinue; Update-MatchesPage }) } else { $del.IsEnabled = $false }
        [void]$mu.List.Children.Add($card)
    }
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
    $gm.Add_Click({ $msg = if (Test-ZDGameMode) { Disable-ZDGameMode } else { Enable-ZDGameMode }; $script:Tray.ShowBalloonTip(3000, 'ZeroDelay', $msg, 'None') })
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
function Update-NvidiaPage {
    if (-not $script:NvHost) { return }
    if (-not (Test-NvAvailable)) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'No NVIDIA graphics card or driver profile found. This page is for NVIDIA cards.'; $tb.Foreground = ConvertTo-Brush '#A1A1A6'
        $script:NvHost.Content = $tb; return
    }
    $sync = Get-NvSyncStatus; $ov = Get-NvOverlayState; $opt = Get-NvOptimizeState; $drv = Get-NvDriverInfo
    $green = '#30D158'; $amber = '#FFD60A'; $red = '#FF453A'
    # sync
    $displayOn = Test-VrrDisplayOn
    $rows = (New-NvRow 'G-SYNC' $(if ($sync.VrrOn) { 'On for Fortnite' } elseif ($displayOn) { 'On for the monitor but blocked for Fortnite: the Tear-free preset fixes this' } elseif ($sync.VrrPossible) { 'Available but off' } else { 'Off (not enabled for this monitor)' }) $(if ($sync.VrrOn) { $green } else { $amber })) +
            (New-NvRow 'Driver V-Sync (Fortnite)' "$($sync.VSync)$(if ($sync.VSyncInherited) { '  (from the global profile)' })") +
            (New-NvRow 'Driver frame cap' $(if ($sync.DriverCap) { "$($sync.DriverCap) FPS" } else { 'Off' })) +
            (New-NvRow 'Fortnite V-Sync' $(if ($sync.GameVSync -eq 'False') { 'Off' } else { "$($sync.GameVSync)" })) +
            (New-NvRow 'Fortnite FPS cap' $(if ($sync.Cap -eq 0) { 'Unlimited' } else { "$([int]$sync.Cap) FPS on a $($sync.Hz) Hz screen" })) +
            (New-NvRow 'NVIDIA Reflex' $(if ($sync.Reflex -eq '2') { 'On + Boost' } elseif ($sync.Reflex -eq '1') { 'On' } else { 'Off' }) $(if ($sync.Reflex -eq '2') { $green } else { $amber })) +
            (New-NvRow 'Verdict' $sync.Verdict $(if ($sync.Warnings) { $amber } else { $green }))
    foreach ($w in $sync.Warnings) { $rows += New-NvRow '' "• $w" $amber }
    $closed = -not (Test-FortniteRunning)
    $btns = (New-NvButton 'TearFree' 'Tear-free preset (G-SYNC)' ([bool]$displayOn) ($displayOn -and $closed)) + (New-NvButton 'Lowest' 'Lowest-latency preset' (-not $sync.VrrOn) $closed) +
            (New-NvButton 'UndoSync' 'Undo preset' $false ([bool]$script:Backup.Custom['nvsync'] -and $closed))
    $note = if ($sync.VrrOn) { 'Tear-free: driver V-Sync on + Reflex + cap a few FPS under refresh. Lowest-latency: V-Sync off and no cap at refresh (allows tearing).' }
            else { 'To use G-SYNC, turn it on in NVIDIA App > System > Displays and in your monitor menu, then come back. Fortnite must be closed to apply a preset.' }
    $x = New-NvSection 'Sync and frame cap' $rows $btns $note
    # filters
    $sm = Get-NvEff $NvProfile $NvSmoothMotionId; $hdr = Get-NvEff $NvProfile ([uint32]0x00DD48FB)
    $dvc = @([uint32]0x00980880, [uint32]0x00ABAB13, [uint32]0x00ABAB22 | ForEach-Object { Get-NvEff $NvProfile $_ } | Where-Object { $_.Found -and $_.Value -ne 0 })
    $ansel = Get-NvEff 'Base Profile' ([uint32]0x1075D972)
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
    $btns = (New-NvButton 'Mcp' 'Check app connection') + $(if (-not (Get-Process -Name 'NVIDIA App' -ErrorAction SilentlyContinue) -and (Test-Path $NvAppExe)) { New-NvButton 'OpenApp' 'Open NVIDIA App' } else { '' })
    $x += New-NvSection 'NVIDIA App' $rows $btns 'Never press Optimize on Fortnite in the NVIDIA App: it replaces your graphics settings.'
    # leftovers
    $defaults = [ordered]@{ '0x1194F158' = @('G-SYNC (global)', 1); '0x10A879CF' = @('G-SYNC app override (global)', 0); '0x10A879CE' = @('V-Sync with G-SYNC (global)', 1); '0x00A879CF' = @('V-Sync (global)', 0x60925292) }
    $left = foreach ($k in $defaults.Keys) {
        $e = Get-NvEff 'Base Profile' ([uint32]([Convert]::ToUInt32($k.Substring(2), 16)))
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
            $window.Cursor = $null; Update-NvidiaPage })
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
                else { $script:CurrentCat.Name -eq 'All' -or $t.Cat -eq $script:CurrentCat.Name }
        $t.Card.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    }
}
$ui.Search.Add_TextChanged({ Update-Filter })
$script:NavButtons = @{}
foreach ($c in $Categories) {
    if ($c.Section) {
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = (Get-Culture).TextInfo.ToTitleCase($c.Section.ToLower()); $lbl.FontSize = 11; $lbl.FontWeight = 'SemiBold'; $lbl.Foreground = ConvertTo-Brush '#98989D'; $lbl.Margin = '10,16,0,6'
        [void]$ui.Nav.Children.Add($lbl)
    }
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
    [void]$ui.Nav.Children.Add($rb)
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

$ui.ApplyRec.Add_Click({
    if (-not $script:Backup.Custom.ContainsKey('restorepoint')) {
        $r = [Windows.MessageBox]::Show("Create a Windows restore point first? It takes a few seconds and lets you roll everything back.", 'Restore point', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { return }
        if ($r -eq 'Yes') { $window.Cursor = [Windows.Input.Cursors]::Wait; Show-Toast (New-ZeroDelayRestorePoint) '#A1A1A6'; $window.Cursor = $null }
        else { $script:Backup.Custom['restorepoint'] = 'declined'; Save-Backup }
    }
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $ok = 0; $failed = @()
    foreach ($t in $Tweaks | Where-Object { $_.Rec -and $_.Toggle -and $_.State -eq $false }) {
        try { Invoke-TweakOn $t; $ok++ } catch { $failed += $t.Title }
    }
    Update-All
    $window.Cursor = $null
    $msg = "Applied $ok recommended optimizations."
    if ($failed) { $msg += " Skipped: $($failed -join ', ')." }
    if ($Tweaks | Where-Object { $_.Badge -eq 'restart' -and $_.State }) { $msg += ' Restart your PC to finish.' }
    Show-Toast $msg $(if ($failed) { '#FF9F0A' } else { '#30D158' })
})

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
$script:DriftTimer.Add_Tick({ Invoke-DriftCheck })
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
    $r = [Windows.MessageBox]::Show($msg, $(if ($restart) { 'Restart now' } else { 'Sign out now' }), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    if ($restart) { shutdown.exe /r /t 5 /c 'ZeroDelay is restarting your PC to apply your changes.' }
    else { shutdown.exe /l }
})

$ui.RestoreAll.Add_Click({
    $r = [Windows.MessageBox]::Show('Put every setting this app changed back to how it was?', 'Restore all', 'YesNo', 'Question')
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

$catOrder = @{}; for ($i = 0; $i -lt $Categories.Count; $i++) { $catOrder[$Categories[$i].Name] = $i }
$n = 0
$Tweaks = @($Tweaks | Where-Object { -not ($_.Action -and $_.Requires -and -not (& $_.Requires)) })
$Tweaks = @($Tweaks | ForEach-Object { [pscustomobject]@{ T = $_; K = [int]$catOrder[$_.Cat] * 10000 + $n++ } } | Sort-Object K | ForEach-Object { $_.T })
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
    foreach ($c in $ui.Cards.Children) { $c.Width = if ($c.Tag.Header) { [Math]::Max(100, $w - 16) } else { $cardW } }
})
$startName = if ($Page -and $script:NavButtons.ContainsKey($Page)) { $Page } else { 'All' }
$script:NavButtons[$startName].IsChecked = $true
$window.Add_ContentRendered({ $script:NavButtons[$script:CurrentCat.Name].BringIntoView() })
Update-GameModeUi
Update-All
if ((-not $Snapshot -and -not $script:Backup.Custom['wizarddone']) -or ($Snapshot -and $env:ZD_WIZARD)) { Show-Wizard }
elseif ($Snapshot -and $env:ZD_WHATSNEW) { Show-WhatsNew }
elseif (-not $Snapshot -and "$($script:Backup.Custom['lastversion'])" -ne $AppVersion) { Show-WhatsNew }
if (-not $Snapshot -and "$($script:Backup.Custom['lastversion'])" -ne $AppVersion) { $script:Backup.Custom['lastversion'] = $AppVersion; Save-Backup }
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
    $window.Add_ContentRendered({
        $script:SnapTimer = New-Object Windows.Threading.DispatcherTimer
        $script:SnapTimer.Interval = [TimeSpan]::FromSeconds(1)
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
    $script:Tray = New-TrayIcon
    $script:ReallyExit = $false
    $window.Add_Closing({
        param($s, $e)
        if (-not $script:ReallyExit -and (Get-Setting 'closetotray' $true)) {
            $e.Cancel = $true
            $window.Hide()
            if (-not $script:Backup.Custom['traytipshown']) {
                $script:Tray.ShowBalloonTip(4000, 'ZeroDelay is still running', 'Game Mode and alerts keep working. Right-click this icon to exit.', 'None')
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
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    $window.Dispatcher.InvokeShutdown()
})
if (-not $Tray -or $Snapshot) { $window.Show() }
[Windows.Threading.Dispatcher]::Run()
if ($script:Relaunch) {
    try { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() } catch {}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -Page Settings$(if ($NoElevate) { ' -NoElevate' })"
}