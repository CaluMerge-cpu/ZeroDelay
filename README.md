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

## Install

Download `ZeroDelay-Setup.exe` from the Releases page and run it. It installs for your Windows account only
(`%LOCALAPPDATA%\Programs\ZeroDelay`) and adds Desktop and Start menu shortcuts. Uninstall from
Settings > Apps > ZeroDelay. Press **Restore all** in ZeroDelay first if you want your original settings back.

The setup is not code-signed, so Windows SmartScreen may show "Windows protected your PC". Click **More info** >
**Run anyway**, or build it yourself from source (below).

ZeroDelay needs administrator rights because it changes system settings. It asks once when it starts.

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
- Game files are only edited when Fortnite is closed. ZeroDelay never touches Fortnite's program files or anti-cheat.
- ZeroDelay does not connect to the internet except for the optional PresentMon download (from Intel's GitHub) and
  the optional ping test to Epic's servers.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Epic Games, NVIDIA or Microsoft.
