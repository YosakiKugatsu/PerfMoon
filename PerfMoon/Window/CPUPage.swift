// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

struct CPUPage: View {
    let model: DashboardModel
    let context: ChartContext
    let width: CGFloat
    let setCoreInspectorVisible: (Bool) -> Void
    let openSensorSettings: () -> Void
    @Bindable var settings: AppSettings
    let setProcessListVisible: (Bool) -> Void

    /// Flat index of the inspected core, or −1. Kept across page switches and window reopening.
    @AppStorage("window.cpu.selectedCore") private var selectedIndex = -1
    @Environment(\.sensorNames) private var sensorNames
    @Environment(\.coreSensorKeys) private var coreSensorKeys

    var body: some View {
        let cpu = model.cpu
        let usageSeries = cpu.usageChartSeries
        PageScroll {
            StatStrip {
                StatBlock(label: "Usage", isFirst: true) {
                    ReadingText.percent(cpu.total, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: cpu.total)
                }
                ForEach(cpu.topology.clusters) { cluster in
                    StatBlock(label: "\(cluster.title) ×\(cluster.count)") {
                        ReadingText.percent(cpu.usage(cluster.role), font: .pmStatNumber)
                    } detail: {
                        let frequency = cpu.frequency(cluster.role)
                        if frequency.unavailableReason == nil {
                            ReadingText.frequency(frequency)
                        } else {
                            ReasonCaption(reading: frequency)
                        }
                    }
                }
                StatBlock(label: "Temperature") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TemperatureText(reading: cpu.temperature, font: .pmStatNumber, emphasis: .primary)
                        ThrottleBadge(status: cpu.throttle)
                    }
                } detail: {
                    if cpu.temperature.unavailableReason == nil {
                        Text(sourceTitle(cpu.temperatureSource))
                            .font(.pmCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        ReasonCaption(reading: cpu.temperature)
                    }
                }
                StatBlock(label: "CPU Power") {
                    ReadingText.watts(cpu.power, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: cpu.power)
                }
            }

            let charts = width >= 660
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            charts {
                ChartCard(title: "Usage", height: 160) {
                    ViewThatFits(in: .horizontal) {
                        usageLegend(usageSeries[...])
                        VStack(alignment: .trailing, spacing: 1) {
                            usageLegend(usageSeries.prefix(2))
                            usageLegend(usageSeries.dropFirst(2))
                        }
                    }
                } chart: {
                    HistoryChart(
                        series: usageSeries,
                        scale: .percent, range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "CPU usage", unavailableReason: cpu.total.unavailableReason
                    )
                }
                ChartCard(title: "Temperature", height: 160) {
                    temperatureSourceMenu(cpu.temperatureSource)
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .cpuTemperature, name: "Temperature", color: Palette.temperature)],
                        scale: .temperature, range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "CPU temperature", unavailableReason: cpu.temperature.unavailableReason
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            ProcessRankingCard(snapshot: model.memory.processes, initialRanking: .cpu, setVisible: setProcessListVisible)

            if !cpu.topology.cores.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "Cores", subtitle: selectedCore == nil ? "Select a core to inspect its history" : nil) {
                            InfoButton(label: "About core temperatures") {
                                CoreMappingExplanation(cores: cpu.topology.clusters.flatMap(\.cores))
                            }
                        }
                        CoreMatrix(cpu: cpu, selected: selectedCore) { core in
                            selectedIndex = selectedCore == core ? -1 : core.flatIndex
                        }
                        if let core = selectedCore {
                            Divider()
                            CoreInspector(
                                core: core,
                                clusterTitle: cpu.topology.cluster(core.cluster)?.title,
                                usage: cpu.cores[core.flatIndex],
                                temperature: cpu.coreTemperatures[core.flatIndex],
                                power: cpu.corePowers.indices.contains(core.flatIndex) ? cpu.corePowers[core.flatIndex] : .pending(.watts),
                                sensorKey: coreSensorKeys[core.flatIndex],
                                width: width - 24,
                                context: context,
                                close: { selectedIndex = -1 }
                            )
                            .id(CoreInspector.scrollID)
                        }
                    }
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        CardHeader(title: "Cores")
                        Text("A reliable core layout isn’t available on this Mac. Total CPU usage is still shown above.")
                            .font(.pmCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ChartCard(title: "CPU Power", height: 120) {
                ReadingText.watts(cpu.power, font: .pmCaptionNumber, emphasis: .secondary)
            } chart: {
                HistoryChart(
                    series: [ChartSeries(key: .cpuPower, name: "CPU Power", color: Palette.cpu, style: .lineAndArea)],
                    scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                    accessibilityName: "CPU power", unavailableReason: cpu.power.unavailableReason
                )
            }
        }
        .modifier(RevealCoreInspector(selectedCore: selectedCore))
        .onChange(of: selectedCore != nil, initial: true) { _, visible in setCoreInspectorVisible(visible) }
        .onDisappear { setCoreInspectorVisible(false) }
    }

    private var selectedCore: CoreID? {
        model.cpu.topology.core(atFlatIndex: selectedIndex)
    }

    private func usageLegend(_ series: ArraySlice<ChartSeries>) -> some View {
        HStack(spacing: 10) {
            ForEach(series) { item in
                LegendKey(title: item.name, color: item.key == .cpuTotal ? item.color.opacity(0.35) : item.color,
                          dash: item.dash)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sourceTitle(_ source: TemperatureSource) -> String {
        switch source {
        case .cpuMax, .cpuAverage: source.title
        case .sensor(let id): sensorNames[id].map { "\(id) · \($0)" } ?? id
        }
    }

    private func temperatureSourceMenu(_ current: TemperatureSource) -> some View {
        Menu {
            Picker("Temperature Source", selection: $settings.temperatureSource) {
                Text("CPU Max").tag(TemperatureSource.cpuMax)
                Text("CPU Average").tag(TemperatureSource.cpuAverage)
                if case .sensor = current {
                    Text(sourceTitle(current)).tag(current)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Choose Sensor…", action: openSensorSettings)
        } label: {
            Text(sourceTitle(current))
                .font(.pmCaption)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Temperature Source")
    }
}

// MARK: - Core matrix

/// All tiers share six equal columns, including incomplete rows and narrow split views.
struct CoreMatrix: View {
    let cpu: CPUSnapshot
    let selected: CoreID?
    let select: (CoreID) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(cpu.topology.clusters) { cluster in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(cluster.title)
                            .font(.pmCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("×\(cluster.count)")
                            .font(.pmCaption)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                        ForEach(cluster.cores) { core in
                            WindowCoreCell(
                                core: core,
                                reading: cpu.cores[core.flatIndex],
                                temperature: cpu.coreTemperatures[core.flatIndex],
                                isSelected: selected == core,
                                select: { select(core) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WindowCoreCell: View {
    let core: CoreID
    let reading: MetricReading
    let temperature: MetricReading?
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false
    @Environment(\.monitorPaused) private var paused
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        let fraction = (reading.shownValue ?? 0) / 100
        let color = Palette.cluster(core.cluster)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(core.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Spacer(minLength: 2)
                    ReadingText.percent(reading, font: .system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Meter(fraction: reading.shownValue.map { $0 / 100 }, color: color, height: 4)
                    if let temperature {
                        TemperatureText(reading: temperature, font: .system(size: 10).monospacedDigit(), emphasis: .tertiary, compact: true)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering && !isSelected ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(color.opacity(paused ? 0 : 0.14 * max(0, fraction - 0.4) / 0.6))
                    }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? "Hide \(core.label) history" : "Show \(core.label) usage, temperature, and power history")
        .accessibilityLabel(core.label)
        .accessibilityValue(spokenValue)
        .accessibilityHint(isSelected ? "Hides this core's history" : "Shows usage, temperature, and power history for this core")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var spokenValue: String {
        var parts = [reading.shownValue.map(Format.spokenPercent) ?? ReadingText.placeholderHelp(reading)]
        if let temperature, let value = temperature.shownValue {
            parts.append(Format.spokenTemperature(value, unit: unit))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Core inspector

/// Scrolls the page just far enough to show the core details when a core is selected.
/// Closing the details, or opening the page with a remembered selection, doesn't scroll.
/// The reader wraps the page's scroll view, so only its content moves, never the window.
private struct RevealCoreInspector: ViewModifier {
    let selectedCore: CoreID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: selectedCore) { _, core in
                guard core != nil else { return }
                let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.3)
                // One main-actor turn later, so details inserted by this change are laid out.
                Task { @MainActor in
                    // No anchor: scroll the minimum amount that shows the whole inspector.
                    withAnimation(animation) { proxy.scrollTo(CoreInspector.scrollID) }
                }
            }
        }
    }
}

/// A single time range across all three metrics for the selected core.
private struct CoreInspector: View {
    static let scrollID = "coreInspector"

    let core: CoreID
    let clusterTitle: String?
    let usage: MetricReading
    let temperature: MetricReading?
    let power: MetricReading
    /// Sensor matched to this core by the community table, if any.
    let sensorKey: String?
    let width: CGFloat
    let context: ChartContext
    let close: () -> Void

    @Environment(\.sensorNames) private var sensorNames

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Core \(core.label)")
                    .font(.pmCardTitle)
                    .accessibilityAddTraits(.isHeader)
                if let clusterTitle {
                    Text(clusterTitle)
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close Core Details")
                .accessibilityLabel("Close \(core.label) details")
            }

            if width >= 630 {
                HStack(alignment: .top, spacing: 16) {
                    usageChart
                    temperatureChart
                    powerChart
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    usageChart
                    temperatureChart
                }
                Divider()
                powerChart
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Core \(core.label) details")
    }

    private var usageChart: some View {
        metric("Usage", key: .coreUsage(core), reading: usage, color: Palette.cluster(core.cluster), scale: .percent) {
            ReadingText.percent(usage)
        }
    }

    private var temperatureChart: some View {
        let reading = temperature ?? (sensorKey == nil
            ? MetricReading(value: nil, unit: .celsius, status: .unavailable(.unsupported), source: .sensors)
            : .pending(.celsius))
        return metric("Temperature", key: .coreTemperature(core), reading: reading, color: Palette.temperature, scale: .temperature) {
            TemperatureText(reading: reading, font: .pmBodyNumber, emphasis: .primary)
        }
        .help(sensorKey.map(sensorHelp) ?? "No temperature sensor is mapped to \(core.label).")
    }

    private var powerChart: some View {
        metric("Power", key: .corePower(core), reading: power, color: Palette.power, scale: .corePower) {
            ReadingText(reading: power, format: { Format.coreWatts($0, compact: false) })
        }
        .help("Average power from this core's energy counter over the sampling interval.")
    }

    private func metric<Value: View>(_ title: String, key: SeriesKey, reading: MetricReading, color: Color,
                                     scale: ChartScale, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.pmBody.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                value()
            }
            HistoryChart(series: [ChartSeries(key: key, name: "\(core.label) \(title)", color: color, style: .lineAndArea)],
                         scale: scale, range: context.range, end: context.end, revision: context.revision,
                         accessibilityName: "\(core.label) \(title.lowercased())", unavailableReason: reading.unavailableReason)
                .frame(height: 112)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sensorHelp(_ key: String) -> String {
        let name = sensorNames[key].map { "\($0) (\(key))" } ?? key
        return "\(name) is matched to \(core.label) by a community-maintained table. Apple doesn't publish this mapping."
    }
}

private struct CoreMappingExplanation: View {
    @Environment(\.coreSensorKeys) private var keys
    let cores: [CoreID]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Core Temperatures")
                .font(.headline)
            Text("Each core shows the sensor matched to it by a community-maintained table. Apple doesn't publish this mapping, so a value describes the area near a core rather than the core itself.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(stride(from: 0, to: cores.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(cores[start..<min(start + 3, cores.count)]) { core in
                            HStack(spacing: 4) {
                                Text(core.label).foregroundStyle(.secondary)
                                Text(keys[core.flatIndex] ?? "—").monospaced()
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
            }
            Text("The CPU temperature chart uses the source chosen in Settings and isn't affected by this mapping.")
                .font(.pmCaption)
                .foregroundStyle(.secondary)
        }
    }
}
