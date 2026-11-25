# PerfMoon

<img src="Design/Icon/Reference.svg" alt="PerfMoon app icon" width="96" height="96">

PerfMoon is a native macOS performance monitor for Apple silicon. See key readings in the menu bar, open the quick panel for a closer look, or use the main window to explore up to six hours of history. PerfMoon is built with SwiftUI and AppKit.

[Download v0.1.0 (DMG)](https://github.com/YosakiKugatsu/PerfMoon/releases/download/v0.1.0/PerfMoon-0.1.0-arm64.dmg) · [Install](#install) · [Releases](https://github.com/YosakiKugatsu/PerfMoon/releases) · [Build from source](#build-from-source) · [Contributing](CONTRIBUTING.md) · [GPL v3](LICENSE)

## Features

| Area | What you can see |
| --- | --- |
| Menu bar and quick panel | Two configurable readings, an optional CPU trend, and a panel with current values and 60-second charts. |
| CPU | Total usage on Apple silicon, with E, S, or P core groups where the topology can be verified. Core groups appear in S, P, E order. In the panel, choosing Usage, Temperature, or CPU Power also changes the group and individual core readings. Per-core temperature and power require a verified mapping and available counters. Also shows CPU power and group frequency where supported. |
| GPU and Neural Engine | GPU usage, frequency, temperature, and power; separate Neural Engine power where available. |
| Memory | Pressure, wired and compressed memory, app memory, and reusable and available capacity. Expand Top 10 on the CPU, Memory, or Disk page and rank processes by CPU, physical footprint, disk reads, or disk writes. One fully occupied core is 100%. |
| Disk | Physical drives and volumes, filesystem types, and storage usage. Click the panel’s Disk summary for a 60-second read/write chart with the current transfer rates. The Disk page adds the volume table and longer throughput and IOPS histories. For the startup disk, see the storage estimate alongside physical allocation and estimated reclaimable space. |
| Network | Download and upload rates, history, and interface byte totals. Automatic selects the active physical service. Choose a specific interface, including a tunnel, on the Network page. Both rates are available as menu bar metrics. |
| Power | System, adapter input, and battery readings with charging state on supported Macs. |

Choose 1m, 5m, 15m, 1h, or 6h in the main window. Select a CPU core for its aligned usage, temperature, and power charts. You can pause monitoring, choose a CPU temperature source, adjust the update interval, and see which metric sources are available in Settings.

Open **Statistics** (⌥⌘I) in any main-window page to compare its current reading, sample mean, minimum, maximum, and nearest-rank P95 for the selected range. Hover over a metric to inspect the sample count and first and last sample times. Statistics use recorded observations, including those older than the chart’s full-resolution window.

Disk and Network show the bytes transferred during the selected range and how much time was recorded when coverage is partial. At the bottom of Disk, open **Drive Health → View SMART Data…** for the selected drive’s SMART status, lifetime counters, and all health attributes reported by macOS.

## Install

The DMG requires an Apple silicon Mac running macOS 27.0 or later. You don't need Xcode to install it.

1. Quit PerfMoon if it is already running.
2. Download and open [PerfMoon-0.1.0-arm64.dmg](https://github.com/YosakiKugatsu/PerfMoon/releases/download/v0.1.0/PerfMoon-0.1.0-arm64.dmg), then open **PerfMoon.pkg** inside the disk image.
3. Follow the macOS Installer prompts. Installation may require an administrator password. At launch, PerfMoon requests administrator access for its local metrics collector when needed.
4. Eject the disk image and open **PerfMoon** from **Applications**. Look for it in the menu bar.

The installer is unsigned and has not been notarized by Apple. If macOS blocks **PerfMoon.pkg** because it cannot verify the developer, and you trust the download from this release, go to **System Settings → Privacy & Security → Security**, choose **Open Anyway** for the installer, and confirm. See [Apple's guide to opening apps safely](https://support.apple.com/en-us/102445).

## Compatibility

PerfMoon runs on Apple silicon Macs with macOS 27.0 or later. The v0.1.0 release was checked on an M5 Pro Mac. Total CPU usage works independently of the chip model. GPU activity, frequency, temperature, and power depend on the counters and sensors that the Mac and macOS expose. A missing metric does not prevent other readings from updating. Check **Settings → Data Sources** for the status of each source.

## Build from source

Building requires Xcode 27.2 or later. Run `xcodebuild -version` to check the active version. Run `scripts/build.sh` in this checkout to build the current features. To reproduce the packaged v0.1.0 release, download the [v0.1.0 source archive](https://github.com/YosakiKugatsu/PerfMoon/archive/refs/tags/v0.1.0.tar.gz) or clone the repository:

```sh
git clone https://github.com/YosakiKugatsu/PerfMoon.git
cd PerfMoon
git checkout v0.1.0
scripts/build.sh
open build/PerfMoon.app
```

The build script signs a local copy in `build/`. To install it, move `PerfMoon.app` to **Applications** in Finder. You can also open `PerfMoon.xcodeproj` in Xcode and build the **PerfMoon** scheme.

## Using PerfMoon

- **Click** the menu bar item to open the quick panel. Select a CPU, GPU, or power tile to see its short history. In the memory card, switch between Usage, History, and Top 10.
- **Right-click** or **Control-click** the menu bar item to open the app's commands. Choose **Open Window** for the full dashboard, or choose **Pause Monitoring** to stop sampling.
- Use **⌘1** for Overview, **⌘2** for CPU, **⌘3** for GPU & ANE, **⌘4** for Memory, **⌘5** for Power, and **⌘6** for Disk. Open Network with **⌘7**. Use **⇧⌘P** to pause or resume and **⌘,** to open Settings.
- The main window opens on the first launch. Closing it leaves PerfMoon running in the menu bar. Enable **Launch at Login** in Settings if you want it to start automatically.

### Reading the charts

History stays in memory. Pausing, sleeping, or losing a data source leaves gaps. Continuous Collection is enabled by default in Settings → General. Charts keep recording while the Mac is awake, including with the window closed or the screen locked. The latest 15 minutes retain raw samples. For older numerical history, charts retain the first, last, highest, and lowest readings of each 30-second span. Statistics use losslessly stored observations throughout the six-hour window. Level charts retain their transitions. Switch Continuous Collection off for on-demand sampling and to release per-core history when the window closes. Frequency readings are averages over a sampling interval. Adapter input, system power, and battery power are separate readings; they do not necessarily add up.

On APFS, volumes can share a container's capacity. PerfMoon counts a container once in each drive's usage total. On the startup disk, the storage estimate includes reclaimable space in the available figure, while the allocation figure describes space currently occupied.

## Collection and privacy

PerfMoon runs its interface in your login session and starts one local root collector for live readings. It first tries noninteractive sudo. If authorization is needed, macOS presents its administrator dialog. Settings → Data Sources shows the collector status and lets you retry. The private connection closes when the app quits. No login daemon, sudoers change, or stored password is required.

Disk and network rates use differences between 64-bit counters over measured intervals. Network reads one interface. Changing interfaces starts a new network chart. A process scan runs only while a ranking is expanded and serves all its visible consumers. Process disk accounting covers all disks and can differ from physical drive traffic.

On supported Macs, continuous history, a selected core in the CPU window, and CPU Power in the panel share one Apple powermetrics process for individually mapped Energy Model channels. The existing scheduler requests each hardware update. The first complete interval establishes a baseline. The values cover the individual core domains. Shared CPU rails can contribute to the aggregate CPU reading. The sampler exits on pause, system sleep, or when its last consumer closes with continuous collection off. Unavailable mappings display a dash.

PerfMoon runs without an account or an internet connection. It does not send telemetry or upload readings. It saves preferences locally but keeps metric history in memory. Process names and disk volume information are read locally for the corresponding views.

The live development probe also uses the root collector. It prints local diagnostics to the terminal. Its output can contain hardware details, process names and IDs, disk names, and mount paths. Review and redact diagnostic output or screenshots before posting them publicly.

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
