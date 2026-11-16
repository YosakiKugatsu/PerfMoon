# PerfMoon

<img src="Design/Icon/Reference.svg" alt="PerfMoon app icon" width="96" height="96">

PerfMoon is a native macOS performance monitor for Apple silicon. See key readings in the menu bar, open the quick panel for a closer look, or use the main window to explore up to 15 minutes of history. PerfMoon is built with SwiftUI and AppKit.

[Download v0.0.2 (DMG)](https://github.com/YosakiKugatsu/PerfMoon/releases/download/v0.0.2/PerfMoon-0.0.2-arm64.dmg) · [Install](#install) · [Releases](https://github.com/YosakiKugatsu/PerfMoon/releases) · [Build from source](#build-from-source) · [Contributing](CONTRIBUTING.md) · [GPL v3](LICENSE)

## Features

| Area | What you can see |
| --- | --- |
| Menu bar and quick panel | Two configurable readings, an optional CPU trend, and a panel with current values and 60-second charts. |
| CPU | Total usage on Apple silicon, with E, S, or P core groups where the topology can be verified. Inspect per-core usage history and temperature when available. Also shows CPU power and group frequency where supported. |
| GPU and Neural Engine | GPU usage, frequency, temperature, and power; separate Neural Engine power where available. |
| Memory | Pressure, wired and compressed memory, app memory, and reusable and available capacity. Expand the Top 10 list to see processes by memory footprint. |
| Disk | Physical drives and volumes, filesystem types, and storage usage. For the startup disk, see the storage estimate alongside physical allocation and estimated reclaimable space. |
| Power | System, adapter input, and battery readings with charging state on supported Macs. |

Choose a 1-, 5-, or 15-minute chart range in the main window. You can pause monitoring, choose a CPU temperature source, adjust the update interval, and see which metric sources are available in Settings.

## Install

The DMG requires an Apple silicon Mac running macOS 27.0 or later. You don't need Xcode to install it.

1. Download and open [PerfMoon-0.0.2-arm64.dmg](https://github.com/YosakiKugatsu/PerfMoon/releases/download/v0.0.2/PerfMoon-0.0.2-arm64.dmg).
2. If you are upgrading, quit the running copy of PerfMoon. Drag **PerfMoon.app** to **Applications**, replace the old copy if prompted, and eject the disk image.
3. Open **PerfMoon** from **Applications**. Look for it in the menu bar.

The downloaded app is unsigned and not notarized by Apple. If macOS can't verify the developer or check the app on first launch, and you trust the download from this release, go to **System Settings → Privacy & Security → Security**. Choose **Open** if shown, then **Open Anyway** for PerfMoon and confirm. This exception applies only to PerfMoon. See [Apple's guide to opening apps safely](https://support.apple.com/en-us/102445).

## Compatibility

PerfMoon runs on Apple silicon Macs with macOS 27.0 or later. This release was tested on an Apple M4 Mac mini and an Apple M5 Pro Mac. Total CPU usage works independently of the chip model. GPU activity, frequency, temperature, and power depend on the counters and sensors that the Mac and macOS expose. A missing metric does not prevent other readings from updating. Check **Settings → Data Sources** for the status of each source.

## Build from source

Building requires Xcode 27.2 or later. Run `xcodebuild -version` to check the active version. Download the [v0.0.2 source archive](https://github.com/YosakiKugatsu/PerfMoon/archive/refs/tags/v0.0.2.tar.gz) or clone the repository:

```sh
git clone https://github.com/YosakiKugatsu/PerfMoon.git
cd PerfMoon
git checkout v0.0.2
scripts/build.sh
open build/PerfMoon.app
```

The build script signs a local copy in `build/`. To install it, move `PerfMoon.app` to **Applications** in Finder. You can also open `PerfMoon.xcodeproj` in Xcode and build the **PerfMoon** scheme.

## Using PerfMoon

- **Click** the menu bar item to open the quick panel. Select a CPU, GPU, or power tile to see its short history. In the memory card, switch between Usage, History, and Top 10.
- **Right-click** or **Control-click** the menu bar item to open the app's commands. Choose **Open Window** for the full dashboard, or choose **Pause Monitoring** to stop sampling.
- Use **⌘1** for Overview, **⌘2** for CPU, **⌘3** for GPU & ANE, **⌘4** for Memory, **⌘5** for Power, and **⌘6** for Disk. Use **⇧⌘P** to pause or resume and **⌘,** to open Settings.
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
