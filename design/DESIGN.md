# ZeroDelay redesign — stage 1: rationale, tokens, core components

Status:
- **Stage 1 (approved):** tokens and core components, below.
- **Stage 2 (in `ZeroDelay.ps1`, not yet run on Windows):** the old palette maps onto the 2.0 tokens, so every page
  re-skins at once; accents are the six new presets (old choices migrate); accent buttons get on-accent text and no
  glow; switches turn on in the accent; glass is opt-in; the `Zd.*` styles live in the window resources. **Home** is
  rebuilt: last-matches strip, score hero with area chips, banner, live tiles with monospaced numbers.
- **Stage 3 (in `ZeroDelay.ps1`, not yet run on Windows):** **Boost now** is one sheet with three steps: Safety first
  (restore point, on by default), Choose (all recommended tweaks ticked, grouped, "When not to use it" expands), Apply
  (one real operation per tick with ✓ / ⚠ and the reason, then the result and a Before & after button). It replaces
  `Show-OptimizeChooser`, so Home and the Boost page both open it. The sheet cannot be closed while applying.
- **Stage 4 (in `ZeroDelay.ps1`, not yet run on Windows):** every card built by `New-Card` (Tweaks, Checks and the
  other card pages) uses the 2.0 TweakCard look: 2.0 card surface, title beside the icon, "Don't use if" on the card
  face, tag chips (Input delay, Recommended, New, Needs restart/sign-out, Advanced, Source). The named parts other code
  uses are unchanged. Tweaks header: views as a segmented control (Recommended · Input delay · On · New · All), live
  count, "Turn on all N shown" (opens Boost now with those cards), accent area chips, and an empty state.
- **Not in this stage:** multi-select area chips, a sort menu, Ctrl+K, the expandable card details and live card
  states (applying/failed), and list virtualization. The cards still sit in a WrapPanel.
- **Stage 5 (in `ZeroDelay.ps1`, not yet run on Windows):** game page. The hero shows the game's header art, faded
  into the page background by a gradient, with the logo, the title (no longer upper case), **Start Game** as the accent
  button with on-accent text, the Game Mode chip (Good tint when on), auto switch and running state, and the launch
  note. The route has its own half-line per stop, coloured by that hop's delay (router < 2 / 5 ms, provider < 15 / 30,
  server < 30 / 60), with the ms reading in the same colour and in mono. Server-card numbers are mono, ping coloured
  by the same rule. Presets are a segmented control. All cards use `Zd.Card`.
- **Not in this stage:** the pulse animation on the route (left out on purpose: no motion near a running game), the
  Settings · Checks · Trends · Tools tabs (the tools panel keeps its filter chips), and the library grid's hover lift.
- **Stage 6 (in `ZeroDelay.ps1`, not yet run on Windows):** Checks. The header button reads **Run all checks** on
  the Checks page (primary style); it opens the health check and runs it. That page has one summary card (score in
  mono, coloured; "2 problems, 1 to check, 2 notes"; Run again; Fix all N) and the findings grouped by severity
  (Problems · Worth a look · Notes). Each row has status icon + word, title, finding, and its action ("How" reads
  "Show me how"). Fix and Fix-all logic unchanged. Also fixes a Stage 4 bug: the old health-check chip sat inside
  the views box that Checks hides.
- **Not in this stage:** the two-column category layout. Health findings carry no category yet, so they are grouped
  by severity; the area chips on the Checks page still filter the check cards.
- **Stage 7 (in `ZeroDelay.ps1`, not yet run on Windows):** Game Mode dashboard. The glow ellipses and the shadowed
  mint button are gone; the 74 px black "FORTNITE" is a 32 px title under a GAME MODE label; all surfaces, text and
  numbers use the tokens (numbers in mono). The status dot is Good / Warn / Muted. The timer dot no longer pulses
  forever (the brief: no continuous animation while playing). **Start Game** uses the accent; when on, the same
  button reads **Stop Game Mode** in the Bad tint. Live ping is coloured by the < 30 / ≤ 60 ms rule. New
  **Minimize to tray** button (hides the window when the tray icon exists, otherwise minimizes). Tool chips and rows
  use the accent and tokens.
- **Stage 8 (in `ZeroDelay.ps1`, not yet run on Windows):** Before & after. The three step cards have a numbered
  dot (check when done, accent on the current step, accent edge on its card). Record and Switch on recommended are
  primary buttons; Pick, Undo, Stop, Start over and Copy use the secondary and ghost styles. The result leads with a
  verdict badge (Real improvement · No meaningful change · Worse: consider restoring · Mixed result · Nothing
  measured), icon + word. The table has mono numbers and a new **Vs. noise** strip per row: the shaded band is
  the noise of two runs, the dot is the change, so you can see why something counts or not. The comparison maths is
  unchanged.
- **Tested on macOS (PowerShell 7.6.9):** parser on every script; 543 generated card/match/sheet XAML documents,
  five page roots, the results table and the window in 12 theme × accent combinations are well-formed XML with
  declared prefixes; StaticResource order and DynamicResource keys check out; 16 logic tests (backup recovery,
  update checksum against the live release, thresholds, contrast) pass. Not covered: WPF itself (property names,
  rendering), the installer and anything that needs Windows.
- **Stage 9 (in `ZeroDelay.ps1`, tested on macOS as above):** Tools is grouped under Play · Measure · Clean ·
  System, with a pin on every tile; pinned tools move to a Pinned group at the top (new setting key `toolpins`;
  no existing key renamed). Tiles use `Zd.Card`, no hover glow or lift. Settings uses `Zd.Card` for every section,
  secondary buttons for actions and primary for Download and Restart. **Fixed two bugs from Stage 2:** Settings
  compared the saved accent with the migrated one (an old `teal` never equals `cyan`) and assumed glass defaults to
  on, so the "restarts to switch its look" bar would have shown for most existing users; the glass switch also showed
  on by default.
- **Stage 10 (in `ZeroDelay.ps1`, tested on macOS):**
  - **Dialogs:** one style on the raised surface, 16 px corners, no icon glow. The main button is `Zd.Button.Primary`;
    a risky yes (Warning/Error with a choice) is Bad red with on-accent text (white on the dark red was 3:1).
  - **Toasts:** bottom right on the raised surface. `Show-Toast` takes an optional Undo action (button + at least 8 s);
    every card switch uses it to flip the switch back.
  - **Trends:** calm hero (no glow, 22 px title), mono headline numbers, theme text; the charts and their event
    markers (tweaks changed, game and driver updates) were already there.
  - **Tournaments:** native chrome on tokens (no glow blobs, 22 px titles, raised panels); game picker chips fixed.
  - **Same restyle** for the remaining booster-look pages: Potato studio, Active tweaks, Ping boosters,
    FreeSync & G-SYNC, Debloat, and the game library tiles. The big score numbers use mono.
  - **Accent-selector contrast fixed everywhere it remained** (game chips, game tools chips, Tournaments picker).
  - **First run:** four screens (Welcome with the three promises · Your PC · Your setup with main game · Ready with
    Boost now or Look around first), skippable from any. Same controls and `Invoke-Wizard`. New setting key
    `maingame` (also sets the Tournaments game).
  - **Left alone:** the loading screen (its glow is animated by name before the theme loads).

## Feature checklist (brief, deliverable 6)

Every page in the menu still exists and opens the same way: Home · Games · Tournaments · Tweaks · Checks · Tools ·
Settings, and from Tools every tool. No feature, setting key or command-line switch (`-Tray`, `-NoElevate`,
`-Snapshot`, `-Page`) was removed or renamed. New setting keys: `toolpins`, `maingame`.

- Backup and restore: unchanged logic. Every switch still saves the original first; Restore and Undo are where they
  were. The backup file location changed with the security fix (see "Changes to the brief", item 5).
- Restore point: still created first (Boost now step 1, on by default; first-run Boost now).
- Anti-cheat safety: no tweak, game-file or driver logic was changed by the redesign.
- "No FPS promise": the Home score always reads "This counts recommended tweaks, not FPS". Before & after verdicts
  still only count differences outside the noise of two runs, now drawn as a band.

## How it was tested (macOS, PowerShell 7.6.9)

- PowerShell's parser on all five scripts: no errors (`ZeroDelay.ps1`: 1,055 functions).
- XAML built from the app's own builders and data with a checking stand-in for `ZdTheme`: all 544 tweak cards,
  match cards, both Boost sheets, the Before & after table, 16 dialog variants, the wizard on two PCs, Tools tiles
  pinned and unpinned, and 25 of 28 page builders (the other 3 need live PC data first). The main window parses in
  dark and light × six accents; StaticResource order and all DynamicResource keys check out.
- Whole-file sweep of all 102 XAML strings: the only 6 flagged are strings finished at runtime that 1.19 already
  ships unchanged.
- 16 logic tests: backup save/reload/recovery and migration, update checksum against the live GitHub release,
  match thresholds, accent migration, and 4.5:1 contrast for every accent and text token in both themes.
- Each harness was shown to fail on planted bugs before its passes were trusted.
- **Not covered:** WPF itself (property names, layout, rendering, animations), the installer and uninstaller, folder
  permissions and anything else that needs Windows. Run it on Windows before releasing. Live tiles still need the
  status dot + word from the MetricTile.

Files:
- `design/ZeroDelay.Design.ps1` — token dictionaries (dark, light), accent presets, and the three core components
  (Primary button, TweakCard, MetricTile) as XAML here-strings plus their PowerShell builders.
- Visual preview: published as an artifact (dark/light, all six accents, every card state, live tiles).

## Design rationale

**Mood: an esports instrument panel.** ZeroDelay's whole pitch is "measured, not guessed", so the interface should
look like a measuring instrument, not a toy. Calm surfaces, one accent colour that means "act", status colours that mean
exactly one thing, and numbers set in a monospaced face so ping and FPS never jitter while they update. References: the
NVIDIA App's density, Linear's restraint (tone-on-tone surfaces, 1-px borders instead of shadows), and Riot Client's
confident hero art on game pages.

**Honesty is a visual rule, not just copy.** No glows, no gradients on text, no fake scans. The score ring always carries
its subtitle ("counts recommended tweaks, not FPS"). The tweak card shows *when not to use it* on the card face,
not hidden in a tooltip, because that line is what separates ZeroDelay from every "FPS booster". Tweaks that tests show
do nothing are shown muted with that label, never hidden.

**Depth by tone, not shadow.** Four surface steps (base → surface → raised, plus a 1-px subtle border) read clearly on
true black and cost nothing to render. That matters: the app must never cost a player frames, so there are no blur
effects, no `DropShadowEffect` on lists, and no animation at all while a game runs.

**Colour is never the only signal.** Every status colour is paired with an icon and a word ("Good", "Check", "High"),
so colour-blind players get the same information.

**Built to fit the current engine.** The app already themes by swapping hex values in its XAML at load time. The new
tokens are named brushes (`Bg.Surface`, `Text.Secondary`, …) used through `DynamicResource`, so a theme or accent change
applies live, and the old hex palette can be mapped onto the new tokens to re-skin every existing page on day one,
before each page is rebuilt.

## Changes to the brief (please confirm)

1. **Text.Muted is `#7A8390`, not `#5B6470`.** The brief requires 4.5:1 for text; `#5B6470` gives 3.2:1 on cards.
   `#7A8390` gives 5.0:1 on cards and 4.6:1 on raised panels and still reads as muted.
2. **Accent buttons use near-black text (`#07080A`), not white.** White text fails 4.5:1 on all six accents
   (Cyan 1.6:1, Volt 1.3:1, even Purple 3.9:1). Near-black passes on all six (5.2:1 to 15:1).
3. **Light mode has its own darker status and accent colours.** The dark-mode values fail on white (Good 1.8:1,
   Info 2.4:1, Cyan 1.6:1). Light-mode variants are tuned to at least 5.0:1 on the light base, with white text on
   light-mode accent buttons (5.4:1 to 6.0:1).
4. **Accent setting values.** The setting key stays `accent`, but the six presets change. Existing choices carry over:
   `blue` → Electric blue, `teal` → Cyan, `purple` → Fortnite purple, `pink` → Magenta, `indigo` → Electric blue,
   `graphite` → Cyan. New installs default to Cyan.
5. **Backup path.** The brief says to keep `%LOCALAPPDATA%\FortniteLatencyOptimizer\backup-v2.json`. The pending
   security fix (not committed yet) moves it to `%ProgramData%\ZeroDelay\backup-<SID>.json`, because the elevated
   app must not trust a file any program can edit. The redesign does not touch backup code either way.

## Tokens

| Token | Dark | Light | Use |
|---|---|---|---|
| `Bg.Base` | `#07080A` | `#F6F7F9` | window |
| `Bg.Surface` | `#0E1013` | `#FFFFFF` | cards, panels |
| `Bg.Raised` | `#15181D` | `#F0F2F5` | hover, dialogs, popovers |
| `Border.Subtle` | `#1F242B` | `#E3E6EA` | 1-px borders |
| `Border.Strong` | `#2B323B` | `#CDD2D9` | hover borders, switch track |
| `Text.Primary` | `#F2F4F7` | `#0B0D10` | |
| `Text.Secondary` | `#9AA3AF` | `#5A6472` | descriptions |
| `Text.Muted` | `#7A8390` | `#626B77` | captions, units |
| `Good` | `#3DDC84` | `#157A43` | ping < 30 ms, healthy |
| `Warn` | `#F5B83D` | `#8A5E06` | 30–60 ms, check this |
| `Bad` | `#FF5C5C` | `#C81E1E` | > 60 ms, loss, failed |
| `Info` | `#6CA8FF` | `#1D63D6` | guided / manual |

Accents (dark / light): Cyan `#2EE6D6`/`#0E7469` · Electric blue `#3D8BFF`/`#2459E0` · Volt `#B6F23D`/`#4D7007` ·
Orange `#FF8A3D`/`#B34700` · Magenta `#FF4FD8`/`#BF0A98` · Fortnite purple `#9D5CFF`/`#7B33EC`.

Type: Display 32 SemiBold · Title 22 SemiBold · Subtitle 16 SemiBold · Body 14 · Caption 12 · Metric 32 mono
(Segoe UI Variable → Segoe UI; Cascadia Mono → Consolas). Spacing on a 4-px grid. Radius 8 controls / 12 cards /
16 hero panels and dialogs. Motion 140 ms (hover, press, switch) and 220 ms (pages); all durations come from one
resource, so "Show animations: off" in Windows sets them to zero.
