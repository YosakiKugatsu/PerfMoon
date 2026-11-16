// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

struct CPUPage: View {
    let model: DashboardModel
    let context: ChartContext
    let openSensorSettings: () -> Void
    @Bindable var settings: AppSettings

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

            // The two whole-CPU histories side by side, so load and heat read together.
            EqualHeightRow {
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

            if !cpu.topology.cores.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "Cores", subtitle: selectedCore == nil ? "Select a core to see its usage and temperature history" : nil) {
                            InfoButton(label: "About core temperatures") {
                                CoreMappingExplanation(cores: cpu.topology.cores)
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
                                sensorKey: coreSensorKeys[core.flatIndex],
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

/// Six columns that adapt between 76 and 140 pt with 8 pt gaps. Every cell selects its core.
struct CoreMatrix: View {
    let cpu: CPUSnapshot
    let selected: CoreID?
    let select: (CoreID) -> Void

    @State private var width: CGFloat = 600

    var body: some View {
        let cell = min(140, max(76, ((width - 5 * 8) / 6).rounded(.down)))
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
                    let cores = cluster.cores
                    ForEach(Array(stride(from: 0, to: cores.count, by: 6)), id: \.self) { start in
                        HStack(spacing: 8) {
                            ForEach(cores[start..<min(start + 6, cores.count)]) { core in
                                WindowCoreCell(
                                    core: core,
                                    reading: cpu.cores[core.flatIndex],
                                    temperature: cpu.coreTemperatures[core.flatIndex],
                                    width: cell,
                                    isSelected: selected == core,
                                    select: { select(core) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct WindowCoreCell: View {
    let core: CoreID
    let reading: MetricReading
    let temperature: MetricReading?
    let width: CGFloat
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false
    @Environment(\.monitorPaused) private var paused
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        let fraction = (reading.shownValue ?? 0) / 100
        let color = Palette.cluster(core.cluster)
        Button(action: select) {
            VStack(spacing: 0) {
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
            .frame(width: width, height: 56)
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
        .help(isSelected ? "Hide \(core.label) history" : "Show \(core.label) usage and temperature history")
        .accessibilityLabel(core.label)
        .accessibilityValue(spokenValue)
        .accessibilityHint(isSelected ? "Hides this core's history" : "Shows usage and temperature history for this core")
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

/// Usage and temperature history for one core, on the page's time range. Two charts at
/// most, drawn from the shared history; the matrix cells themselves stay chart-free.
private struct CoreInspector: View {
    static let scrollID = "coreInspector"

    let core: CoreID
    let clusterTitle: String?
    let usage: MetricReading
    let temperature: MetricReading?
    /// Sensor matched to this core by the community table, if any.
    let sensorKey: String?
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

            EqualHeightRow(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    header("Usage") {
                        ReadingText.percent(usage)
                    }
                    HistoryChart(
                        series: [ChartSeries(key: .coreUsage(core), name: "\(core.label) Usage", color: Palette.cluster(core.cluster), style: .lineAndArea)],
                        scale: .percent, range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "\(core.label) usage", unavailableReason: usage.unavailableReason
                    )
                    .frame(height: 120)
                    Text("Share of time this core was busy over each update.")
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 6) {
                    header("Temperature") {
                        if sensorKey != nil {
                            TemperatureText(reading: temperature ?? .pending(.celsius), font: .pmBodyNumber, emphasis: .primary)
                        }
                    }
                    if let sensorKey {
                        HistoryChart(
                            series: [ChartSeries(key: .coreTemperature(core), name: "\(core.label) Temperature", color: Palette.temperature)],
                            scale: .temperature, range: context.range, end: context.end, revision: context.revision,
                            accessibilityName: "Temperature near \(core.label)", unavailableReason: temperature?.unavailableReason
                        )
                        .frame(height: 120)
                        Text("Sensor \(sensorKey) · reads the area near \(core.label), not the core itself.")
                            .font(.pmCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(sensorHelp(sensorKey))
                    } else {
                        Text("No sensor is matched to \(core.label).")
                            .font(.pmCaption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background(.fill.quinary, in: .rect(cornerRadius: 8))
                        Text("Core temperatures come from a community-maintained table that has no entry for this core.")
                            .font(.pmCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Text("Core history is recorded while this window is visible.")
                .font(.pmCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Core \(core.label) details")
    }

    private func header<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.pmBody.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            value()
        }
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
