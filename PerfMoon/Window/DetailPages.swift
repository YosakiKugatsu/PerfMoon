import PerfMoonKit
import SwiftUI

// MARK: - GPU & ANE

struct GPUPage: View {
    let model: DashboardModel
    let context: ChartContext

    @State private var width: CGFloat = 800

    var body: some View {
        let gpu = model.gpu
        PageScroll(width: $width) {
            StatStrip {
                StatBlock(label: "Usage", isFirst: true) {
                    ReadingText.percent(gpu.usage, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: gpu.usage)
                }
                StatBlock(label: "Frequency") {
                    ReadingText.frequency(gpu.frequency, font: .pmStatNumber, emphasis: .primary)
                }
                StatBlock(label: "Temperature") {
                    TemperatureText(reading: gpu.temperature, font: .pmStatNumber, emphasis: .primary)
                } detail: {
                    Text("GPU Max").font(.pmCaption).foregroundStyle(.secondary)
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
                    accessibilityName: "GPU usage"
                )
            }

            EqualHeightRow {
                ChartCard(title: "GPU Temperature", height: 130) {
                    EmptyView()
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .gpuTemperature, name: "GPU Temperature", color: Palette.temperature)],
                        scale: .temperature, range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "GPU temperature"
                    )
                }
                ChartCard(title: "GPU Power", height: 130) {
                    EmptyView()
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .gpuPower, name: "GPU Power", color: Palette.gpu, style: .lineAndArea)],
                        scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "GPU power"
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
                        accessibilityName: "ANE power"
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
    /// Reports whether the process list is on screen. False when collapsed or when the page goes away.
    let setProcessListVisible: (Bool) -> Void

    @State private var width: CGFloat = 800
    /// Not persisted: each visit starts collapsed, so a scan starts only after a click.
    @State private var showsProcesses = false

    var body: some View {
        let memory = model.memory
        PageScroll(width: $width) {
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
                    }
                }
            }
        }
        .onAppear { setProcessListVisible(showsProcesses) }
        .onChange(of: showsProcesses) { _, visible in setProcessListVisible(visible) }
        .onDisappear { setProcessListVisible(false) }
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

// MARK: - Power

struct PowerPage: View {
    let model: DashboardModel
    let context: ChartContext

    @State private var width: CGFloat = 800

    var body: some View {
        let power = model.power
        let gpu = model.gpu
        PageScroll(width: $width) {
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
                        accessibilityName: "Chip power"
                    )
                }
            }
        }
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
