// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

// MARK: - GPU & ANE

struct GPUPage: View {
    let model: DashboardModel
    let context: ChartContext

    var body: some View {
        let gpu = model.gpu
        PageScroll {
            StatStrip {
                StatBlock(label: "Usage", isFirst: true) {
                    ReadingText.percent(gpu.usage, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: gpu.usage)
                }
                StatBlock(label: "Frequency") {
                    ReadingText.frequency(gpu.frequency, font: .pmStatNumber, emphasis: .primary)
                } detail: {
                    ReasonCaption(reading: gpu.frequency)
                }
                StatBlock(label: "Temperature") {
                    TemperatureText(reading: gpu.temperature, font: .pmStatNumber, emphasis: .primary)
                } detail: {
                    if gpu.temperature.unavailableReason == nil {
                        Text("GPU Max").font(.pmCaption).foregroundStyle(.secondary)
                    } else {
                        ReasonCaption(reading: gpu.temperature)
                    }
                }
                StatBlock(label: "GPU Power") {
                    ReadingText.watts(gpu.power, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: gpu.power)
                }
            }

            ChartCard(title: "GPU Usage", height: 170) {
                EmptyView()
            } chart: {
                HistoryChart(
                    series: [ChartSeries(key: .gpuUsage, name: "GPU Usage", color: Palette.gpu, style: .lineAndArea)],
                    scale: .percent, range: context.range, end: context.end, revision: context.revision,
                    accessibilityName: "GPU usage", unavailableReason: gpu.usage.unavailableReason
                )
            }

            EqualHeightRow {
                ChartCard(title: "GPU Temperature", height: 130) {
                    EmptyView()
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .gpuTemperature, name: "GPU Temperature", color: Palette.temperature)],
                        scale: .temperature, range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "GPU temperature", unavailableReason: gpu.temperature.unavailableReason
                    )
                }
                ChartCard(title: "GPU Power", height: 130) {
                    EmptyView()
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .gpuPower, name: "GPU Power", color: Palette.gpu, style: .lineAndArea)],
                        scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "GPU power", unavailableReason: gpu.power.unavailableReason
                    )
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "ANE Power", subtitle: "Neural Engine")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Palette.ane).frame(width: 8, height: 8)
                        ReadingText.watts(gpu.anePower, font: .pmCardNumber)
                        ReasonCaption(reading: gpu.anePower)
                        Spacer()
                    }
                    HistoryChart(
                        series: [ChartSeries(key: .anePower, name: "ANE Power", color: Palette.ane, style: .lineAndArea)],
                        scale: .watts(minimumMax: 2), range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "ANE power", unavailableReason: gpu.anePower.unavailableReason
                    )
                    .frame(height: 120)
                }
            }
        }
    }
}

// MARK: - Memory

/// Composition first, then history beside the full breakdown. Top 10 is last and collapsed
/// by default; processes are scanned only while it is shown on the visible page.
struct MemoryPage: View {
    let model: DashboardModel
    let context: ChartContext
    let width: CGFloat
    /// Reports whether the process list is on screen. False when collapsed or when the page goes away.
    let setProcessListVisible: (Bool) -> Void

    /// Not persisted: each visit starts collapsed, so a scan starts only after a click.
    @State private var showsProcesses = false

    var body: some View {
        let memory = model.memory
        PageScroll {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Memory") {
                        PressureBadge(reading: memory.pressure, font: .pmBody)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ReadingText.bytes(memory.used, font: .pmCardNumber)
                        Text("used of \(Format.wholeGigabytes(memory.physical))")
                            .font(.pmBody)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Available").font(.pmCaption).foregroundStyle(.secondary)
                            ReadingText.bytes(memory.available, font: .pmStatNumber)
                        }
                        .accessibilityElement(children: .combine)
                        .help(MemoryPart.available.help)
                    }
                    MemoryCompositionView(memory: memory, layout: .window)
                }
            }

            // The chart stretches to the table's height, so neither card leaves a gap.
            EqualHeightRow {
                Card(stretches: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Used") {
                            ReadingText.bytes(memory.used, font: .pmCaptionNumber, emphasis: .secondary)
                        }
                        HistoryChart(
                            series: [ChartSeries(key: .memoryUsed, name: "Used", color: Palette.memory, style: .lineAndArea)],
                            scale: .bytes(maximum: memory.physical), range: context.range, end: context.end, revision: context.revision,
                            accessibilityName: "Memory used"
                        )
                        .frame(minHeight: 130, maxHeight: .infinity)
                    }
                }
                Card(stretches: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Breakdown") {
                            InfoButton(label: "How memory is counted") {
                                MemoryExplanation()
                            }
                        }
                        VStack(spacing: 0) {
                            MetricRow(label: "App Memory", reading: memory.app, kind: .bytes)
                            MetricRow(label: "Reusable", reading: memory.reusable, kind: .bytes, indent: true)
                                .help(MemoryPart.reusable.help)
                            MetricRow(label: "Wired Memory", reading: memory.wired, kind: .bytes)
                            MetricRow(label: "Compressed", reading: memory.compressed, kind: .bytes)
                            MetricRow(label: "Cached Files", reading: memory.cached, kind: .bytes)
                            MetricRow(label: "Purgeable", reading: memory.purgeable, kind: .bytes, indent: true)
                            MetricRow(label: "Free", reading: memory.free, kind: .bytes)
                            MetricRow(label: "Swap Used", reading: memory.swapUsed, kind: .bytes, last: true)
                        }
                    }
                }
            }

            ChartCard(title: "Pressure", height: 110) {
                LevelChart(key: .memoryPressure, kind: .pressure, range: context.range, end: context.end, revision: context.revision)
            }

            StatStrip {
                StatBlock(label: "Page-ins", isFirst: true) {
                    ReadingText.rate(memory.pageIns, font: .pmStatNumber)
                }
                StatBlock(label: "Page-outs") {
                    ReadingText.rate(memory.pageOuts, font: .pmStatNumber)
                }
                StatBlock(label: "Swap-ins") {
                    ReadingText.rate(memory.swapIns, font: .pmStatNumber)
                }
                StatBlock(label: "Swap-outs") {
                    ReadingText.rate(memory.swapOuts, font: .pmStatNumber)
                }
            }

            // Collapsed, this is a single header row rather than a tall empty card.
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "Top 10 Processes", subtitle: "by memory") {
                        Text("Scanned only while shown.")
                            .font(.pmCaption)
                            .foregroundStyle(.tertiary)
                        Button(showsProcesses ? "Hide" : "Show") { showsProcesses.toggle() }
                            .controlSize(.small)
                            .help(showsProcesses ? "Hide the process list and stop scanning" : "Show the 10 processes using the most memory")
                            .accessibilityLabel(showsProcesses ? "Hide Top 10 Processes" : "Show Top 10 Processes")
                            .accessibilityValue(showsProcesses ? "Expanded" : "Collapsed")
                    }
                    if showsProcesses {
                        ProcessMemoryList(snapshot: memory.processes, showsPID: width >= 700)
                            .onAppear { setProcessListVisible(true) }
                            .onDisappear { setProcessListVisible(false) }
                    }
                }
            }
        }
    }
}

private struct MetricRow: View {
    enum Kind {
        case bytes
        case rate
    }

    let label: String
    let reading: MetricReading
    let kind: Kind
    var indent = false
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if indent {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .foregroundStyle(indent ? .secondary : .primary)
                Spacer(minLength: 12)
                switch kind {
                case .bytes: ReadingText.bytes(reading)
                case .rate: ReadingText.rate(reading)
                }
            }
            .font(.pmBody)
            .padding(.vertical, 6)
            .padding(.leading, indent ? 10 : 0)
            .accessibilityElement(children: .combine)
            if !last { Divider() }
        }
    }
}

private struct MemoryExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How Memory Is Counted").font(.headline)
            Text("Used is App Memory + Wired Memory + Compressed. Available is physical memory minus Used.")
            Text("Reusable is part of App Memory: memory apps have released for macOS to reclaim. It's still resident and included in Used. The bar shows it apart from the rest of App Memory, which appears as Apps.")
            Text("Cached Files holds recently used files and is reused when apps need memory. It isn't counted in Used. Purgeable is part of Cached Files, so the two overlap and aren't added together.")
            Text("Swap Used is memory written to disk. Pressure is the level macOS reports: Normal, Warning, or Critical.")
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Disk

/// One card per physical drive, startup drive first: what kind of storage it is, its media
/// and BSD names, its capacity, then each volume with its device, file system, and own used
/// space. Shared APFS space is never split into per-volume percentages or added together.
/// No chart or history: capacity changes slowly and isn't activity.
struct DiskPage: View {
    let model: DashboardModel


    var body: some View {
        let drives = model.diskDrives
        PageScroll {
            if drives.isEmpty {
                // Before the first reading, or if none succeeds.
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: model.disk.name)
                        DiskUsageText(capacity: model.disk, font: .pmStatNumber, separator: "used of", captionFont: .pmBody)
                        DiskCapacityBar(capacity: model.disk, height: 10)
                        ReasonCaption(reading: model.disk.available)
                    }
                }
            } else {
                ForEach(drives) { DiskDriveCard(drive: $0) }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: "About Disk Capacity")
                    Group {
                        Text("For the startup disk, Used and Available are what macOS reports for the startup volume, as in System Settings: space macOS can reclaim counts as available. Allocated is all space APFS has allocated there, and Reclaimable is the part macOS reports it can free.")
                        Text("Each volume's Used is the space allocated to it, so it can include reclaimable space and volumes can add up to more than the drive's Used. Volumes in one APFS container share its free space, so they show no separate total or percentage and aren't added together.")
                        Text("When macOS gives no estimate for a drive, it shows the space allocated on that drive's file systems.")
                        Text("This is capacity, not read or write activity.")
                    }
                    .font(.pmBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A physical drive: identity and available space, its capacity, then its volumes.
private struct DiskDriveCard: View {
    let drive: DiskDriveSnapshot

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: drive.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.storageTitle)
                            .font(.pmCardTitle)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 6) {
                            if drive.name != drive.storageTitle {
                                Text(drive.name)
                            }
                            Text(drive.id).monospaced()
                        }
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Available").font(.pmCaption).foregroundStyle(.secondary)
                        ReadingText.storage(drive.available, font: .pmStatNumber)
                    }
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 16) {
                        DiskUsageText(capacity: drive, font: .pmStatNumber, separator: "used of", captionFont: .pmBody)
                        DiskCapacityBar(capacity: drive, height: 10)
                    }
                    .help(drive.capacityHelp)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(drive.storageTitle) capacity")
                    .accessibilityValue([drive.spokenCapacity, drive.spokenScope].filter { !$0.isEmpty }.joined(separator: ", "))
                    if drive.capacityScopeName != nil || drive.allocated != nil || drive.reclaimable != nil {
                        // One line when it fits, otherwise stacked.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) { scopeDetails }
                            VStack(alignment: .leading, spacing: 3) { scopeDetails }
                        }
                        .font(.pmCaption)
                        .accessibilityHidden(true)
                    }
                }
                ReasonCaption(reading: drive.used)
                DiskVolumeTable(volumes: drive.volumes)
            }
        }
    }

    /// Whose Used and Available these are, then the startup container's allocated and
    /// reclaimable space. Each part appears only when macOS reports it.
    @ViewBuilder
    private var scopeDetails: some View {
        if let scope = drive.capacityScopeName {
            Text("Used and Available for \(scope)")
                .foregroundStyle(.secondary)
                .help(drive.capacityHelp)
        }
        if let allocated = drive.allocated {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Allocated").foregroundStyle(.secondary)
                ReadingText.storage(allocated, font: .pmCaptionNumber)
            }
            .help("All space APFS has allocated in this container, including space macOS can reclaim.")
        }
        if let reclaimable = drive.reclaimable {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Reclaimable").foregroundStyle(.secondary)
                ReadingText.storage(reclaimable, font: .pmCaptionNumber)
            }
            .help("Allocated space macOS reports it can free when needed, such as purgeable files, caches, and local snapshots.")
        }
    }
}

/// Volumes in aligned columns. A volume with its own capacity shows used of total and a
/// small bar; a volume sharing its container's space shows only what it uses.
private struct DiskVolumeTable: View {
    let volumes: [DiskSnapshot]

    var body: some View {
        if volumes.isEmpty {
            Text("No mounted volumes")
                .font(.pmCaption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VolumeColumns {
                    Text("Volume")
                } device: {
                    Text("Device")
                } fileSystem: {
                    Text("File System")
                } used: {
                    Text("Used")
                }
                .font(.pmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)
                .accessibilityHidden(true)
                ForEach(volumes) { volume in
                    Divider()
                    DiskVolumeRow(volume: volume)
                }
                if volumes.contains(where: \.sharesCapacity) {
                    Text("Volumes in an APFS container share its free space. Used shows each one's own data.")
                        .font(.pmCaption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
        }
    }
}

/// Shared column widths, so the header and every row line up.
private struct VolumeColumns<Name: View, Device: View, FileSystem: View, Used: View>: View {
    @ViewBuilder var name: Name
    @ViewBuilder var device: Device
    @ViewBuilder var fileSystem: FileSystem
    @ViewBuilder var used: Used

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            device.frame(width: 92, alignment: .leading)
            fileSystem.frame(width: 76, alignment: .leading)
            used.frame(width: 140, alignment: .trailing)
        }
    }
}

private struct DiskVolumeRow: View {
    let volume: DiskSnapshot

    var body: some View {
        VolumeColumns {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.pmBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if volume.isStartup {
                        DiskContextTag(title: "Startup")
                    }
                }
                if !volume.mountPath.isEmpty {
                    Text(volume.mountPath)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } device: {
            Text(volume.deviceIdentifier ?? Format.placeholder)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } fileSystem: {
            Text(volume.fileSystem.isEmpty ? Format.placeholder : volume.fileSystem)
                .font(.pmBody)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } used: {
            VStack(alignment: .trailing, spacing: 3) {
                VolumeUsedText(volume: volume, font: .pmBodyNumber, separator: "of")
                    .font(.pmBody)
                if !volume.sharesCapacity, volume.usedFraction != nil {
                    DiskCapacityBar(capacity: volume, height: 4)
                        .frame(width: 80)
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(volume.isStartup ? "\(volume.name), startup volume" : volume.name)
        .accessibilityValue(volume.spokenVolume)
    }
}

// MARK: - Power

struct PowerPage: View {
    let model: DashboardModel
    let context: ChartContext


    var body: some View {
        let power = model.power
        let gpu = model.gpu
        PageScroll {
            HStack(spacing: 6) {
                Text("Three independent readings")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                InfoButton(label: "About these readings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Independent Readings").font(.headline)
                        Text("Power Input, System Power, and Battery Power come from separate sensors with their own timing. They aren't expected to add up, and PerfMoon doesn't calculate losses between them.")
                            .foregroundStyle(.secondary)
                        Text("Battery Power shows the measured magnitude with the battery's status: Charging, Discharging, or AC Power when the adapter is supplying power and the battery is idle.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            EqualHeightRow {
                PowerCard(title: "Power Input", key: .powerInput, context: context) {
                    if power.hasAdapter == false {
                        NoAdapterText(font: .pmCardNumber)
                    } else {
                        ReadingText.watts(power.input, font: .pmCardNumber)
                    }
                } detail: {
                    if power.hasAdapter == false {
                        Text("Running on battery").font(.pmCaption).foregroundStyle(.secondary)
                    } else {
                        DetailSpacer()
                    }
                }
                PowerCard(title: "System Power", key: .powerSystem, context: context) {
                    ReadingText.watts(power.system, font: .pmCardNumber)
                } detail: {
                    DetailSpacer()
                }
                PowerCard(title: "Battery Power", key: .powerBattery, context: context, showsChargeStrip: true) {
                    BatteryPowerText(power: power, font: .pmCardNumber)
                } detail: {
                    BatteryStatusLabel(power: power)
                }
            }

            ChartCard(title: "Chip Power", height: 150) {
                HStack(spacing: 12) {
                    LegendKey(title: "CPU", color: Palette.cpu)
                    LegendKey(title: "GPU", color: Palette.gpu)
                    LegendKey(title: "ANE", color: Palette.ane)
                }
            } chart: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        ChipValue(title: "CPU", color: Palette.cpu, reading: model.cpu.power)
                        ChipValue(title: "GPU", color: Palette.gpu, reading: gpu.power)
                        ChipValue(title: "ANE", color: Palette.ane, reading: gpu.anePower)
                        Spacer()
                    }
                    HistoryChart(
                        series: [
                            ChartSeries(key: .cpuPower, name: "CPU Power", color: Palette.cpu),
                            ChartSeries(key: .gpuPower, name: "GPU Power", color: Palette.gpu),
                            ChartSeries(key: .anePower, name: "ANE Power", color: Palette.ane),
                        ],
                        scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "Chip power", unavailableReason: chipPowerReason
                    )
                }
            }
        }
    }

    private var chipPowerReason: UnavailableReason? {
        let gpu = model.gpu
        guard let reason = model.cpu.power.unavailableReason,
              gpu.power.unavailableReason == reason, gpu.anePower.unavailableReason == reason else { return nil }
        return reason
    }
}

private struct PowerCard<Value: View, Detail: View>: View {
    let title: String
    let key: SeriesKey
    let context: ChartContext
    var showsChargeStrip = false
    @ViewBuilder var value: Value
    @ViewBuilder var detail: Detail

    var body: some View {
        Card(stretches: true) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.pmCardTitle).accessibilityAddTraits(.isHeader)
                    value
                    detail
                }
                .accessibilityElement(children: .combine)
                VStack(spacing: 6) {
                    HistoryChart(
                        series: [ChartSeries(key: key, name: title, color: Palette.power, style: .lineAndArea)],
                        scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: title
                    )
                    if showsChargeStrip {
                        LevelStrip(key: .batteryState, kind: .charge, range: context.range, end: context.end, revision: context.revision)
                    }
                }
                .frame(height: 120)
            }
        }
    }
}
