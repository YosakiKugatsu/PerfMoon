# PerfMoon

<img src="Design/Icon/Reference.svg" alt="PerfMoon app icon" width="96" height="96">

PerfMoon is a native macOS performance monitor for Apple silicon. See key readings in the menu bar, open the quick panel for a closer look, or use the main window to explore up to 15 minutes of history. PerfMoon is built with SwiftUI and AppKit.

[Releases](https://github.com/YosakiKugatsu/PerfMoon/releases) · [Build from source](#build-from-source) · [Contributing](CONTRIBUTING.md) · [GPL v3](LICENSE)

## Features

| Area | What you can see |
| --- | --- |
| Menu bar and quick panel | Two configurable readings, an optional CPU trend, and a panel with current values and 60-second charts. |
| CPU | Overall and per-core usage, cluster frequency, CPU power, and temperatures from available sensors. Inspect a core's recent usage and temperature in the CPU window. |
| GPU and Neural Engine | GPU usage, frequency, temperature, and power; separate Neural Engine power where available. |
| Memory | Pressure, wired and compressed memory, app memory, and reusable and available capacity. Expand the Top 10 list to see processes by memory footprint. |
| Disk | Physical drives and volumes, filesystem types, and storage usage. For the startup disk, see the storage estimate alongside physical allocation and estimated reclaimable space. |
| Power | System, adapter input, and battery readings with charging state on supported Macs. |

Choose a 1-, 5-, or 15-minute chart range in the main window. You can pause monitoring, choose a CPU temperature source, adjust the update interval, and see which metric sources are available in Settings.

## Requirements

- Apple silicon Mac running macOS 27.0 or later.
- Xcode 27.2 or later for the source build. Run `xcodebuild -version` to check the active version.

Collector validation for this release focused on Apple M5 Pro. CPU topology, sensor coverage, energy counters, and battery readings vary by Mac and macOS version. PerfMoon shows unavailable readings as missing rather than substituting estimated hardware values. Check **Settings → Data Sources** if a reading is missing.

### Build from source

Download the tagged source archive from [Releases](https://github.com/YosakiKugatsu/PerfMoon/releases), or clone the repository:

```sh
git clone https://github.com/YosakiKugatsu/PerfMoon.git
cd PerfMoon
git checkout v0.0.1
scripts/build.sh
open build/PerfMoon.app
```

The build script signs a local copy in `build/`. To install it, move `PerfMoon.app` to **Applications** in Finder. You can also open `PerfMoon.xcodeproj` in Xcode and build the **PerfMoon** scheme.

## Using PerfMoon

- **Click** the menu bar item to open the quick panel. Select a CPU, GPU, or power tile to see its short history. In the memory card, switch between Usage, History, and Top 10.
- **Right-click** or **Control-click** the menu bar item to open the app's commands. Choose **Open Window** for the full dashboard, or choose **Pause Monitoring** to stop sampling.
- Use **⌘1–⌘6** to open Overview, CPU, GPU & ANE, Memory, Power, and Disk, respectively. Use **⇧⌘P** to pause or resume and **⌘,** to open Settings.
- The main window opens on the first launch. Closing it leaves PerfMoon running in the menu bar. Enable **Launch at Login** in Settings if you want it to start automatically.

### Reading the charts

History stays in memory. Pausing, sleeping, or losing a data source leaves gaps. Per-core history starts when the main window is visible and is cleared when the window closes. Frequency readings are averages over a sampling interval. Adapter input, system power, and battery power are separate readings; they do not necessarily add up.

On APFS, volumes can share a container's capacity. PerfMoon counts a container once in each drive's usage total. On the startup disk, the storage estimate includes reclaimable space in the available figure, while the allocation figure describes space currently occupied.

## Privacy

PerfMoon runs without administrator privileges, an account, or an internet connection. It does not send telemetry or upload readings. It saves preferences locally but keeps metric history in memory. Process names and disk volume information are read locally for the corresponding views.

The development probe prints local diagnostics to the terminal. Its output can contain hardware details, process names and IDs, disk names, and mount paths. Review and redact diagnostic output or screenshots before posting them publicly.

## Development

```sh
swift test --package-path PerfMoonKit
scripts/build.sh debug
```

The Debug build includes a Design Gallery with simulated data for checking the UI. Open it with **⌥⌘G** while the Debug app's window is active. Use the live probe to inspect collector behavior without the UI:

```sh
swift run -c release --package-path PerfMoonKit PerfMoonProbe --seconds 10 --mode overview
```

| Path | Contents |
| --- | --- |
| `PerfMoon/` | AppKit and SwiftUI app: menu bar, quick panel, dashboard, and settings. |
| `PerfMoonKit/` | Collectors, sampling, history, test fixtures, and the diagnostic probe. |
| `Design/Icon/` | Editable app icon and [icon build notes](Design/Icon/README.md). |

See [CONTRIBUTING.md](CONTRIBUTING.md) for bug reports and pull requests.

## License

Copyright © 2026 YosakiKugatsu. PerfMoon is licensed under the [GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`).

The AppleSMC and IOReport implementations reference [Stats](https://github.com/exelban/stats) and [macmon](https://github.com/vladkens/macmon). Their original MIT notices are preserved in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
