# PerfMoon

A native macOS performance monitor for Apple silicon: a menu bar item, a quick panel, and a
full window with CPU (S-Core / P-Core), GPU & ANE, Memory, and Power pages. Built with
SwiftUI and AppKit, using native Liquid Glass controls. Minimum macOS 27.0, arm64.

## Status

Live hardware collection is integrated and is the default. Debug builds include a
fixture-driven Design Gallery for reviewing edge cases.

The current hardware profile targets **Apple M5 Pro (6 S-Cores, 12 P-Cores, 20 GPU cores)**
on **macOS 27.2**. Hardware counters and sensor mappings are explicitly gated; a supported
API call is not assumed to mean that a counter has meaningful data.

CPU, GPU, and ANE power have been compared with Apple's `powermetrics` under separate,
bounded workloads. The steady portions of those runs gave:

| Workload | PerfMoon | powermetrics |
|---|---:|---:|
| CPU | 31.79 W | 31.76 W |
| GPU | 38.23 W | 38.32 W |
| ANE | 5.87 W | 5.86 W |

These are 10-sample averages from this Mac, not a universal error bound. GPU active residency
and frequency also matched under the GPU workload (100%, 1.62 GHz). The ANE test's Core ML
compute plan selected Neural Engine.

The current collection implementation passes 37 core tests and a live regression with
30 pause/resume cycles, six SMC reconnections, and missing-sensor recovery. Physical system
sleep/wake, battery charging/discharging transitions, and a genuine thermal throttle event
have not been forced on this Mac.

## Build and run

Requirements: Xcode 27.2 (or newer) selected with `xcode-select`.

```sh
scripts/build.sh            # Release → build/PerfMoon.app
scripts/build.sh debug      # Debug   → build/Debug/PerfMoon.app (includes the Design Gallery)
open "build/PerfMoon.app"
```

The script only writes inside `build/`; it never installs or replaces an app in
`/Applications`. The project can also be opened in Xcode (`PerfMoon.xcodeproj`, scheme
**PerfMoon**).

Core tests (scheduler, history, downsampling, formatting):

```sh
swift test --package-path PerfMoonKit
```

## Using the app

PerfMoon is a menu bar app. Its Dock icon appears only while the main window or Settings is
open. The first run opens a window to introduce the app; subsequent launches stay in the
menu bar. Reopening the running app or choosing Open Window shows the main window.
Closing the window leaves the menu bar running. Existing installations keep their settings
and transition to menu bar startup.

| Surface | How to open | Contents |
|---|---|---|
| Menu bar item | Always visible | Two labeled values in one item (CPU and System Power by default); an optional CPU trend appears as a separate item |
| Panel | Click the menu bar item | CPU and GPU metric switches, fixed-height S/P per-core views, fixed-height two-column memory Top 10, and three switchable power tiles |
| Menu | Right-click or Control-click the menu bar item | Pause, Open Window, Settings, About, Quit |
| Window | Panel ▸ window button, or ⌘O | Overview, CPU, GPU & ANE, Memory, Power; time range 1m / 5m / 15m |
| Settings | ⌘, | General, Menu Bar, CPU (temperature source), Performance, Data Sources |

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘1 – ⌘5 | Show Overview, CPU, GPU & ANE, Memory, Power |
| ⇧⌘P | Pause or resume monitoring |
| ⌘O | Open the window |
| ⌘, | Settings |
| ⌘W | Close the current window |
| Esc | Close the panel |
| Return / Space | Expand or collapse a focused panel row* |
| ⌥⌘G | Design Gallery (Debug builds only) |

\* With System Settings ▸ Keyboard ▸ Keyboard Navigation turned on, Tab moves between panel
rows; a focused row shows a soft highlight.

### Panel interactions

- CPU and GPU: click the temperature to swap it with usage and show its history; click Power
  to select power. GPU Frequency uses the same headline/chart area. Click the displaced Usage
  item to return. ANE only has power and history.
- S-Core / P-Core: click a cluster to replace its summary with all its core readings. Each
  cluster keeps its original height. The frequency number has its own click target and
  replaces only that cluster's usage bar with a frequency sparkline.
- Memory: click to replace the summary with ranks 1–5 on the left and 6–10 on the right;
  click again to return. The card does not grow.
- Power: Input, System, and Battery each toggle between their value and a small history.
- The panel has a fixed width and no internal scrollbar. The separate CPU settings list
  remains scrollable and searchable.

### Notes on readings

- **Frequencies** are residency-weighted averages over each update, not instantaneous
  per-core clocks.
- **CPU Power** is the CPU's own energy reading. A separate CPU Package figure isn't
  available on this Mac and isn't estimated.
- **ANE** shows power and its history only.
- **Power Input, System Power, and Battery Power** are independent readings. They aren't
  expected to add up. The battery shows Charging, Discharging, or AC Power (adapter
  connected, battery idle). Its displayed value has `+` while charging and `−` while
  discharging; an idle battery remains unsigned.
- **Throttle** appears next to the CPU temperature only when the data layer reports active
  thermal throttling.
- **History** covers the last 15 minutes and is kept in memory only. Gaps from pausing,
  sleep, failures, or source changes are left as gaps.

## Preview vs. live data

| | Preview (fixtures) | Live |
|---|---|---|
| Data | Seeded simulated scenarios (`PerfMoonKit/Sources/PerfMoonKit/Fixtures`) | Collectors provided by the live data layer |
| Window subtitle | "Simulated Data" | None, or "Paused" while paused |
| Design Gallery | Debug builds: scenarios, source failures, sleep and wake, appearance | Debug builds only; never in Release |

Views read the `isLiveData` environment value (`PerfMoon/Components/Theme.swift`) to choose
the wording. The app root sets it.

### Collection and rendering

The application itself uses Mach, IOKit/AppleSMC, and IOReport directly. It does not run
Python, `powermetrics`, Stats, or shell commands to produce readings. The validation tools
are separate from the app. Connections and subscriptions are reused, process memory is
sampled only when its list is shown, and hidden window models stop observing the engine.

History uses bounded 15-minute ring buffers. Charts draw through Canvas with peak-preserving
downsampling and explicit gaps, rather than creating one SwiftUI node per history point.
The regular build writes no metric history to disk. Settings pages load when first visited;
only the visible page's data model receives updates. Thermal polling joins an existing
sampling tick (every 4 seconds at a 2-second cadence), avoiding separate thermal-only wakes
without extending the previous polling latency.

### Measured overhead

The following baseline captures were made for the initial release on the M5 Pro above.
CPU is a share of **one core** (100% = one fully occupied core); memory is the process's
physical footprint, in MiB.

| Scope | Effective update interval | Measured CPU | Observed memory |
|---|---:|---:|---:|
| Native collectors, scheduler, and history; 120 s | 2 s | 0.42% | 6.34 MiB peak in capture |
| Native collectors, scheduler, and history; 120 s | 5 s | 0.18% | 6.49 MiB peak in capture |
| Full menu bar app; CPU + RAM, trend off; 180 s after 60 s warm-up | 2 s | 0.86% | 53.8–55.3 MiB |

The menu capture verified that no window, panel, or Settings page was observing data. It
used opt-in QA diagnostics; the delivered normal Release build disables those file writes.
The original 0.5% CPU target for the complete menu bar process has **not** been met. The
collector-only result must not be presented as the application's total overhead.

A separate two-hour collector run averaged 0.45% CPU with a 6.30 MiB captured peak and
roughly 5.9–6.0 MiB after warm-up. That run preceded the final fixed-buffer and same-tick
temperature-cache refinements. It validates the collector architecture over that period;
it is not a two-hour GUI measurement.

The subsequent menu-only startup experiment measured 18.2–18.8 MiB before any SwiftUI
surface was opened. This is a different lifecycle state from opening and closing a window;
opening the interface can still increase retained framework memory. Final GUI verification
of the current optimization build is pending.

In a separate native comparison of about 135 seconds per variant, aligning thermal polling
reduced scheduler wakes from 83 to 69 while all 18 history-series counts remained identical.
The two steady CPU captures were 0.63% and 0.66%, so this comparison does not establish a CPU
percentage reduction. Startup preference checks also cover fresh installs, legacy installs,
and preservation of the configured metrics, interval, and units.

CPU deltas reuse fixed counter storage. Temperature requests in the same scheduler tick
share both successful and failed reads. Menu glyphs reuse fonts and shaped text, then bake
1× and 2× template bitmaps only when displayed content changes. The tested manual-counter
and IOReport sample-reuse alternatives did not show a confirmed benefit and were not
adopted; the validated hardware-counter path remains in use.

The development `PerfMoonProbe` executable exercises the same collectors without a UI:

```sh
swift run -c release --package-path PerfMoonKit PerfMoonProbe --seconds 60 --mode overview
swift run -c release --package-path PerfMoonKit PerfMoonProbe --exercise --mode overview
```

The second command checks real collector pause/resume, repeated SMC reconnection, and
missing-sensor recovery. It simulates lifecycle events inside the collector; it does not
put the computer to sleep.

### Debug launch arguments (Design Gallery builds)

```sh
open "build/Debug/PerfMoon.app" --args -PMScenario heavyLoad -PMOpen window -PMPage cpu -PMAppearance dark
```

| Argument | Values |
|---|---|
| `-PMOpen` | `window`, `settings`, `panel`, `none` |
| `-PMPage` | `overview`, `cpu`, `gpu`, `memory`, `power` |
| `-PMSettingsTab` | `general`, `menuBar`, `cpu`, `performance`, `dataSources` |
| `-PMScenario` | Any `FixtureScenario` raw value |
| `-PMGallery` | `YES` |

## Source layout

| Path | Contents |
|---|---|
| `PerfMoon/App` | App delegate, composition root, settings storage, main menu |
| `PerfMoon/StatusItem` | Menu bar item and its template glyph renderer |
| `PerfMoon/Panel` | Popover controller and panel sections |
| `PerfMoon/Window` | Main window controller and the five pages |
| `PerfMoon/Settings` | Settings window (toolbar tabs) and its five pages |
| `PerfMoon/Components` | Theme, reading text, cards, charts, badges, process list |
| `PerfMoon/Debug` | Design Gallery and launch options (Debug only) |
| `PerfMoonKit` | Native collectors, data contract, scheduler, bounded history, downsampling, fixtures, and CLI probe |
| `Design/Icon` | App icon source (Icon Composer document and SVG layers) and steps to add it to the app |

## References

Sensor protocol and M5 mappings were checked against [Stats](https://github.com/exelban/stats).
IOReport and CLPC conventions were checked against [macmon](https://github.com/vladkens/macmon).
License notices are in `THIRD_PARTY_NOTICES.txt` and are bundled with the app.
