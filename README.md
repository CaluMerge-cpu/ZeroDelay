# ZeroDelay

A free, open-source Windows app that lowers input delay and stutter in Fortnite. Every change is shown as a card with
an on/off switch, explained in plain words, backed up before it is applied, and can be undone at any time.

## Features

- **150+ tweaks** grouped by Latency & delay, Power & CPU, Graphics, Input & audio, Network, Background & privacy,
  Services & tasks, Storage, Desktop visuals and Startup apps. Each card says what it does and when *not* to use it.
- **Game Mode**: one switch (or automatic when Fortnite starts) that closes or pauses background apps, switches to the
  ZeroDelay power plan, lowers background priority, silences notifications and pauses update downloads, then puts
  everything back when the match ends.
- **Potato graphics**: presets from competitive to flat-colour potato, a "build your own" slider card with a live
  "% potato" score, and NVIDIA texture-blur levels.
- **NVIDIA page**: G-SYNC / V-Sync / Reflex / frame-cap check with tear-free and lowest-latency presets, Smooth Motion
  and RTX HDR checks, overlay and Instant Replay status, driver update check.
- **Health check**: one scan for the problems that cost the most (mouse acceleration, wrong FPS cap, power settings,
  leftovers from other optimizers) with one-click fixes.
- **Benchmark** with Intel PresentMon (average FPS, 1% and 0.1% lows, latency, before/after comparison),
  **Ping monitor** for Fortnite regions, **Sensitivity** calculator (eDPI, cm/360).
- **Profiles** with share codes, **History** with per-change undo, **drift alerts** when another program changes your
  settings back, Windows restore point before applying.
- **Match reports**: after each Fortnite session, the stutters (with what was busy at that moment), background apps
  that used your CPU, GPU heat or hardware slowdowns, and low memory. Stutter timing uses PresentMon.
- **Mouse test**: measures your mouse's real polling rate (125 to 8000 Hz) and whether it is steady.
- **Light and dark mode** (or match Windows) with six accent colours.
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
4. Click **Install**. ZeroDelay asks for administrator rights when it starts, because it changes system settings.

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
