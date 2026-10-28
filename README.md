# ZeroDelay

A free, open-source Windows app that lowers input delay and stutter in Fortnite. Every change is shown as a card with
an on/off switch, explained in plain words, backed up before it is applied, and can be undone at any time.

## Features

- **Knows your PC**: on first start (and every few days) ZeroDelay scans the hardware, drivers, Windows and installed
  apps, and adapts its recommendations: laptops, streamers, Wi-Fi vs Ethernet, X3D and hybrid CPUs, GPU model.
  **Tools > This PC** shows everything it found and what it changed. Nothing is sent anywhere.
- **Clean, simple design**: a Home page with an Optimize button that lists what is still off so you choose what to switch on, folding menu groups, and frosted glass on Windows 11.
- **Creator tab** for Premiere Pro, After Effects, Photoshop, Media Encoder and OBS: auto-save hitches, Adobe RAM
  reserve, Multi-Frame Rendering, Adobe apps on the dedicated GPU, OBS priority, staying awake during renders, and
  Adobe cache cleanup. Each setting is changed one value at a time, only while the app is closed.
- **GTX 1080 Ti tab** on PCs with that card: the right renderer and settings, the 580 security driver branch, and
  advice for undervolting and cooling an older card.

- **240+ tweaks** grouped by Latency & delay, Power & CPU, Graphics, Input & audio, Network, Background & privacy,
  Services & tasks, Storage, Desktop visuals and Startup apps. Each card says what it does and when *not* to use it.
- **Network checks**: your cable's link speed and errors, Wi-Fi signal and band, a 20-second test of the link to your router
  (home network or internet line?), VPN routing, traffic shapers such as Killer or cFosSpeed, and the Intel 2.5G driver bug.
- **Guided cards** for settings no program can change safely: AMD Anti-Lag and Fluid Motion Frames, Intel Arc Low Latency
  Mode, NVIDIA App auto-optimize, TV/monitor game mode and wireless receiver placement.
- **Counter-Strike 2 tab** (when CS2 is installed): Reflex, V-Sync or Valve's G-SYNC combo, Boost Player Contrast, AO,
  anti-aliasing, FSR, particles, shaders, shadows, FPS caps, the telemetry HUD and network settings, each a single CS2 setting that
  is backed up and undone exactly (CS2 must be closed). Plus NVIDIA settings and GPU choice for cs2.exe, a **Valve server ping**
  through Valve's relay list that can set your matchmaking ping limit, and checks for launch options (dead ones and the
  VAC-blocking `-insecure`), Steam overlay/downloads/recording, CS2 version and drive, and sensitivity in cm/360. VAC-safe:
  nothing touches the game files or anti-cheat.
- **Your real matches**: reads Fortnite's own log for ping, jitter and packet loss per match, real in-match stutters (loading
  screens left out), which graphics card and renderer Fortnite used, whether Reflex was on, and recent crashes.
- **Fortnite subregion ping**: Epic's regions have servers in several cities (Europe: Germany, France, UK); ZeroDelay pings
  each one so you can set Fortnite's Subregion Preference, plus a one-minute jitter and loss test, a route check that shows
  where lag starts, and Epic's live server status.
- **Game Mode**: a booster-style dashboard with a Start Game button (turns Game Mode on and launches Fortnite), a
  session timer, live ping, CPU, GPU and memory numbers, and every boost step and app in one panel. It closes or pauses
  background apps, switches to the ZeroDelay power plan, lowers background priority, silences notifications and pauses
  update downloads (or does all of it automatically when Fortnite starts), then puts everything back when the match ends.
- **Tournaments**: Epic's official competitive schedule inside ZeroDelay, opened on the region you play (read from
  your Fortnite settings), with every cup's art, times in your PC's time zone, and each event's scoring, rules and
  prizes. Next to it: a ready check (ping to the region, Game Mode, Fortnite settings, two-factor sign-in) and
  competitive tips. Shown with Microsoft Edge WebView2, which comes with Windows 11.
- **Active tweaks**: everything switched on right now, grouped like the menu, with when ZeroDelay turned it on and a switch
  to undo each one.
- **Debloat**: finds preinstalled Windows apps, promo apps and PC-maker trials, explains each one, and removes only
  what you tick.
- **FreeSync**: each monitor's variable refresh range and cable, what the NVIDIA driver reports for each one (on, off for that monitor, or not seen), and what to check (NVIDIA needs
  DisplayPort or HDMI 2.1), and the settings in order: refresh rate, G-SYNC Compatible, Windows VRR, an in-range frame cap.
- **Ping booster**: works with GearUP, ExitLag, WTFast and NoPing. A trusted booster may change settings: ZeroDelay
  keeps its changes, never switches them back, and lists every change with the old and new value.
- **Potato graphics**: presets from competitive to flat-colour potato, a "build your own" slider card with a live
  "% potato" score, and NVIDIA texture-blur levels.
- **NVIDIA page**: G-SYNC / V-Sync / Reflex / frame-cap check with tear-free and lowest-latency presets, Smooth Motion
  and RTX HDR checks, overlay and Instant Replay status, driver update check.
- **Health check**: one scan for the problems that cost the most, with one-click fixes where possible: mouse
  acceleration, wrong FPS cap, power settings, RAM below its rated speed or in single channel, the graphics card on
  fewer PCIe lanes, Fortnite on a hard drive, no page file, CPU held back by heat, a mouse on a USB hub, Windows Update
  restarts mid-match, Defender scan timing, leftovers from other optimizers.
- **Vendor software**: services from ASUS, MSI, Corsair, Razer, Logitech, Dell, HP, Lenovo, Intel, AMD and Adobe that
  are documented stutter sources. Only what is installed is shown, and each card says what stops working.
- **Trends**: your matches over time (FPS, 1% lows, stutters, input latency, ping) with markers where tweaks changed or
  Fortnite and the graphics driver updated, and the last matches compared with the ones before.
- **Heads-up after updates**: when Fortnite or the graphics driver updates, ZeroDelay warns that the first match or two
  stutter while shaders rebuild.
- **Benchmark** with Intel PresentMon (average FPS, 1% and 0.1% lows, latency, before/after comparison) and a guided **A/B test with a replay** that says whether a change is a real gain or run-to-run noise,
  **Ping monitor** for Fortnite regions with a **Ping check** that finds which network tweak raised your ping and can fix it automatically (kept only if ping really drops), **Sensitivity** calculator (eDPI, cm/360).
- **Pause all tweaks** (Settings): turn off everything ZeroDelay switched on at once and bring exactly those back later.
- **Profiles** with share codes, **History** with per-change undo, **drift alerts** when another program changes your
  settings back, Windows restore point before applying.
- **Match reports**: after each Fortnite session, the stutters (with what was busy at that moment), background apps
  that used your CPU, GPU heat or hardware slowdowns, low memory, input latency and the connection (ping, jitter, packet loss), plus a How to fix it list with one button per fix. Stutter timing uses PresentMon.
- **Mouse test**: measures your mouse's real polling rate (125 to 8000 Hz) and whether it is steady.
- **Uninstall apps**: programs and Microsoft Store apps, with common Windows bloat labelled. **Force remove** skips a
  broken uninstaller and deletes the app's own folders, registry keys (backed up first), shortcuts, services and tasks;
  folders shared with other programs or holding games (Steam, Epic, Riot) are never listed.
- **Clean up files**: temp folders, Windows Update downloads, Delivery Optimization cache, crash dumps, thumbnails,
  browser/Discord caches and the Recycle Bin, with the size of each shown before anything is deleted.
- **Memory (RAM)**: what uses your memory, closing heavy apps, and a one-time standby-list clear. No "RAM cleaner" that
  forces apps to drop their memory: that causes the stutter it claims to fix.
- **Light and true-black dark mode** (or match Windows) with six accent colours.
- **Own dialogs**: every question is a dark ZeroDelay dialog instead of a grey Windows pop-up.
- **One-click updates**: ZeroDelay tells you when a new version is out, downloads it from the GitHub release, checks
  its SHA-256 against the release notes and reinstalls itself.
- Optional **Start with Windows** (in the tray), and **Report a problem**, which opens a GitHub issue with your PC
  details filled in.

## How to install

1. Open the [latest release](../../releases/latest) and click **ZeroDelay-Setup.exe** under *Assets* to download it.
2. Run it. Windows will probably show a blue **"Windows protected your PC"** screen. That is normal: ZeroDelay is a
   free hobby project and is not code-signed (a signing certificate costs a few hundred dollars a year), so Windows
   does not recognise it yet. Click **More info**, then **Run anyway**.
3. Your browser may also warn that the file "isn't commonly downloaded". Choose **Keep** (in Edge: **...** > **Keep**
   > **Keep anyway**).
4. Click **Install**. ZeroDelay asks for administrator rights when it starts, because it changes system settings. The
   prompt shows ZeroDelay's name with "Publisher: Unknown", since the app is not code-signed.

Not comfortable running an unsigned file? Every line of code is in this repository: compare the SHA-256 on the
release page, or build the setup yourself (see below).

ZeroDelay installs for your Windows account only (`%LOCALAPPDATA%\Programs\ZeroDelay`) and adds Desktop and Start menu
shortcuts. **Updating:** ZeroDelay tells you when a new version is out; press **Update now**. (From 1.0 or 1.1, update once
by hand: exit ZeroDelay from the tray and run the new setup.) Your settings and backups are kept. **Uninstalling:** press **Restore all** in ZeroDelay first if you want your
original settings back, then remove it from Settings > Apps > ZeroDelay.

## Run from source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\ZeroDelay.ps1
```

Requirements: Windows 10 or 11, Windows PowerShell 5.1 (built in). No other dependencies.

## Build the installer

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

This compiles `dist\ZeroDelay-Setup.exe` with the C# compiler that ships with Windows (.NET Framework 4).

## How it stays safe

- The original value of every setting is saved to `%LOCALAPPDATA%\FortniteLatencyOptimizer\backup-v2.json` before it
  is changed; switching a card off or pressing **Restore all** puts it back.
- No placebo tweaks: TCP/Nagle tweaks (Fortnite uses UDP), RAM cleaners, disabling Windows Update or security
  protections are deliberately not included.
- **Start with Windows** is off unless you switch it on. It creates a scheduled task named ZeroDelay, which switching it
  off (or uninstalling) removes.
- Game files are only edited when Fortnite is closed. ZeroDelay never touches Fortnite's program files or anti-cheat.
- ZeroDelay only connects to the internet for the update check (it reads the latest release from GitHub; the new
  setup is downloaded only when you press **Update now**; switch the check off in Settings), the optional PresentMon download (from
  Intel's GitHub) and the optional ping test to Epic's servers.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Epic Games, NVIDIA or Microsoft.
