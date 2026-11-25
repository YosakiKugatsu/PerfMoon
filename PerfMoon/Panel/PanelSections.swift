// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

/// Shared panel geometry. The cluster slot height never changes between states.
private enum PanelLayout {
    static let clusterHeight: CGFloat = 40
    /// Two rows of six plus a 4 pt gap fill the cluster slot exactly.
    static let compactCellHeight: CGFloat = 18
    static let sparklineHeight: CGFloat = 24
}

private enum PanelMetric: String {
    case usage, temperature, power, anePower, frequency
}

/// Other cards still label their history span; CPU/GPU use their status badges.
private struct HistorySpanLabel: View {
    var body: some View {
        Text("\(Int(PanelSparkline.span)) s history")
            .font(.pmCaption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The series a card's sparkline draws for the selected tile.
private struct PanelChart {
    let key: SeriesKey
    let title: String
    let color: Color
    let scale: SparklineScale
    var unavailableReason: UnavailableReason? = nil
}

// MARK: - CPU

/// Usage, temperature, and power are always visible as named tiles. The selected tile
/// is tinted with its chart color and drives the sparkline below.
struct CPUPanelSection: View {
    let model: DashboardModel
    let setCoreMetric: (Demand?) -> Void

    @AppStorage("panel.cpu.metric") private var metric: PanelMetric = .usage
    @AppStorage("panel.cpu.activeCluster") private var activeCluster: CoreCluster = .s
    @AppStorage("panel.expanded.e") private var expandedE = false
    @AppStorage("panel.expanded.s") private var expandedS = false
    @AppStorage("panel.expanded.p") private var expandedP = false
    @AppStorage("panel.frequency.e") private var frequencyE = false
    @AppStorage("panel.frequency.s") private var frequencyS = false
    @AppStorage("panel.frequency.p") private var frequencyP = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sensorNames) private var sensorNames
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        let cpu = model.cpu
        let selected = selectedMetric
        let chart = panelChart(selected)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle(title: "CPU")
                    Spacer()
                    ThermalStatusBadge(status: cpu.throttle, device: "CPU")
                }

                VStack(alignment: .leading, spacing: 4) {
                    TileRow {
                        MetricTile(title: "Usage", color: Palette.cpu, isSelected: selected == .usage,
                                   spokenValue: ReadingText.spoken(cpu.total, Format.spokenPercent),
                                   action: { metric = .usage }) {
                            ReadingText.percent(cpu.total, font: .pmTileNumber)
                        }
                        MetricTile(title: "Temperature", color: Palette.temperature, isSelected: selected == .temperature,
                                   spokenValue: ReadingText.spoken(cpu.temperature) { Format.spokenTemperature($0, unit: unit) },
                                   about: temperatureDescription(cpu.temperatureSource),
                                   action: { metric = .temperature }) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                // The default CPU Max source has no visible prefix.
                                if cpu.temperatureSource != .cpuMax {
                                    Text(cpu.temperatureSource.compactLabel)
                                        .font(.pmCaption)
                                        .foregroundStyle(.secondary)
                                }
                                TemperatureText(reading: cpu.temperature, font: .pmTileNumber, emphasis: .primary)
                            }
                        }
                        MetricTile(title: "CPU Power", color: Palette.power, isSelected: selected == .power,
                                   spokenValue: ReadingText.spoken(cpu.power, Format.spokenWatts),
                                   action: { metric = .power }) {
                            ReadingText.watts(cpu.power, font: .pmTileNumber)
                        }
                    }
                    PanelSparkline(key: chart.key, title: chart.title, color: chart.color, scale: chart.scale,
                                   end: model.time, revision: model.historyRevision,
                                   unavailableReason: chart.unavailableReason)
                        .frame(height: PanelLayout.sparklineHeight)
                }

                if !cpu.topology.clusters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        clusterRows(cpu)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .onChange(of: selected, initial: true) { _, value in
            setCoreMetric(value == .temperature ? .panelCoreTemperatures : value == .power ? .panelCorePower : nil)
        }
    }

    @ViewBuilder
    private func clusterRows(_ cpu: CPUSnapshot) -> some View {
        let clusters = cpu.topology.clusters
        if clusters.count > 2, let tier = cpu.topology.cluster(activeCluster) ?? clusters.first {
            // Keep the popover at a useful height without scrolling the CPU metric picker offscreen.
            Picker("CPU cluster", selection: Binding(get: { tier.role }, set: { activeCluster = $0 })) {
                ForEach(clusters) { cluster in Text(cluster.title).tag(cluster.role) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            clusterRow(tier, cpu: cpu)
                .id(tier.role)
        } else {
            ForEach(clusters) { cluster in clusterRow(cluster, cpu: cpu) }
        }
    }

    private func clusterRow(_ cluster: CPUClusterTopology, cpu: CPUSnapshot) -> some View {
        let expanded: Binding<Bool>
        let frequency: Binding<Bool>
        switch cluster.role {
        case .e: (expanded, frequency) = ($expandedE, $frequencyE)
        case .s: (expanded, frequency) = ($expandedS, $frequencyS)
        case .p: (expanded, frequency) = ($expandedP, $frequencyP)
        }
        return ClusterDisclosure(cluster: cluster, cpu: cpu, model: model, metric: selectedMetric,
                                 isExpanded: binding(expanded), showsFrequency: frequency)
    }

    /// Older builds stored only CPU metrics here; anything else falls back to usage.
    private var selectedMetric: PanelMetric {
        switch metric {
        case .usage, .temperature, .power: metric
        case .anePower, .frequency: .usage
        }
    }

    private func panelChart(_ metric: PanelMetric) -> PanelChart {
        switch metric {
        case .temperature: PanelChart(key: .cpuTemperature, title: "CPU temperature", color: Palette.temperature, scale: .temperature,
                                     unavailableReason: model.cpu.temperature.unavailableReason)
        case .power: PanelChart(key: .cpuPower, title: "CPU power", color: Palette.power, scale: .watts,
                               unavailableReason: model.cpu.power.unavailableReason)
        case .usage, .anePower, .frequency: PanelChart(key: .cpuTotal, title: "CPU usage", color: Palette.cpu, scale: .percent,
                                                      unavailableReason: model.cpu.total.unavailableReason)
        }
    }

    private func temperatureDescription(_ source: TemperatureSource) -> String {
        switch source {
        case .cpuMax: "Highest CPU temperature"
        case .cpuAverage: "Average CPU temperature"
        case .sensor(let id): sensorNames[id].map { "\($0) (\(id))" } ?? id
        }
    }

    private func binding(_ source: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { value in
                if reduceMotion {
                    source.wrappedValue = value
                } else {
                    withAnimation(.snappy(duration: 0.22)) { source.wrappedValue = value }
                }
            }
        )
    }
}

private extension PanelMetric {
    var coreLabel: String {
        switch self {
        case .temperature: "temperature"
        case .power: "power"
        default: "usage"
        }
    }

    func reading(_ core: CoreID, cpu: CPUSnapshot) -> MetricReading {
        switch self {
        case .temperature:
            return cpu.coreTemperatures[core.flatIndex]
                ?? MetricReading(value: nil, unit: .celsius, status: .unavailable(.unsupported), source: .sensors)
        case .power:
            return cpu.corePowers.indices.contains(core.flatIndex) ? cpu.corePowers[core.flatIndex] : .pending(.watts, source: .corePower)
        default: return cpu.cores[core.flatIndex]
        }
    }

    func reading(_ group: CPUClusterTopology, cpu: CPUSnapshot) -> MetricReading {
        if self == .usage { return cpu.usage(group.role) }
        let readings = group.cores.map { reading($0, cpu: cpu) }
        let available = readings.compactMap(\.shownValue)
        if let value = available.max(), self == .temperature {
            return readings.first { $0.shownValue == value }!
        }
        if self == .power, available.count == readings.count, var result = readings.first {
            result.value = available.reduce(0, +)
            if readings.contains(where: \.isStale) { result.status = .stale }
            return result
        }
        return readings.first { $0.shownValue == nil } ?? .pending(self == .power ? .watts : .celsius)
    }

    func fraction(_ reading: MetricReading, cpu: CPUSnapshot) -> Double? {
        guard let value = reading.shownValue else { return nil }
        if self == .power { return cpu.power.shownValue.flatMap { $0 > 0 ? min(1, value / $0) : nil } }
        return min(1, max(0, value / 100))
    }

    func text(_ value: Double, unit: TemperatureUnit, compact: Bool) -> String {
        switch self {
        case .temperature: compact ? Format.temperatureCompact(value, unit: unit) : Format.temperature(value, unit: unit)
        case .power: Format.coreWatts(value, compact: compact)
        default: Format.percent(value)
        }
    }

    func spoken(_ value: Double, unit: TemperatureUnit) -> String {
        switch self {
        case .temperature: Format.spokenTemperature(value, unit: unit)
        case .power: Format.coreWatts(value, compact: false)
        default: Format.spokenPercent(value)
        }
    }
}

/// A cluster row that expands to show every core. Click, Return, or Space toggles.
private struct ClusterDisclosure: View {
    let cluster: CPUClusterTopology
    let cpu: CPUSnapshot
    let model: DashboardModel
    let metric: PanelMetric
    @Environment(\.temperatureUnit) private var unit
    @Binding var isExpanded: Bool
    @Binding var showsFrequency: Bool

    var body: some View {
        let value = metric.reading(cluster, cpu: cpu)
        let frequency = cpu.frequency(cluster.role)
        HStack(spacing: 8) {
            CoreTierIcon(tier: .cluster(cluster.role))
                .frame(height: PanelLayout.clusterHeight)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
            ZStack {
                if isExpanded {
                    expandedGrid
                        .disclosureInteraction(isExpanded: $isExpanded,
                            label: "\(cluster.title), \(cluster.count) cores", value: accessibilityValue(value),
                            hint: "Shows group \(metric.coreLabel)", preservesChildren: true)
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(cluster.title).font(.system(size: 13, weight: .medium))
                            Text("×\(cluster.count)")
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            ReadingText(reading: value, format: { metric.text($0, unit: unit, compact: false) },
                                        font: .system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .disclosureInteraction(isExpanded: $isExpanded,
                            label: "\(cluster.title), \(cluster.count) cores", value: accessibilityValue(value),
                            hint: "Shows per-core \(metric.coreLabel)")
                        HStack(spacing: 8) {
                            Group {
                                if metric == .usage && showsFrequency && frequency.unavailableReason == nil {
                                    Sparkline(key: cluster.role.frequencySeries,
                                              color: Palette.cluster(cluster.role), end: model.time, revision: model.historyRevision,
                                              domain: nil, zeroBased: true)
                                } else {
                                    Meter(fraction: metric.fraction(value, cpu: cpu), color: Palette.cluster(cluster.role))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                            .contentShape(Rectangle())
                            .onTapGesture { isExpanded.toggle() }
                            if metric == .usage {
                                FrequencyChip(cluster: cluster, reading: frequency, isOn: $showsFrequency)
                                    .fixedSize().frame(width: 88, alignment: .trailing)
                            } else {
                                Text(metric == .temperature ? "Hottest core" : "Core total").font(.pmCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: PanelLayout.clusterHeight)
        .background {
            // Catches clicks in the gaps between the icon, title, and bar. The frequency
            // chip sits above this layer, so its click never reaches the toggle.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var expandedGrid: some View {
        let grid = PanelCoreGrid(cluster: cluster, cpu: cpu, metric: metric,
                                cellHeight: cluster.count <= 6 ? PanelLayout.clusterHeight : PanelLayout.compactCellHeight)
        if cluster.count <= 12 {
            grid
        } else {
            ScrollView(.vertical) { grid }
                .scrollIndicators(.visible)
        }
    }

    private func accessibilityValue(_ usage: MetricReading) -> String {
        var parts: [String] = []
        parts.append(usage.shownValue.map { metric.spoken($0, unit: unit) } ?? ReadingText.placeholderHelp(usage))
        if metric == .usage, let frequency = cpu.frequency(cluster.role).shownValue {
            parts.append("frequency \(Format.spokenFrequency(frequency))")
        }
        parts.append(isExpanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

/// A cluster's frequency, which also swaps the usage bar for a 60-second frequency line.
/// The chart symbol marks it as a chart control; the tint shows the line is on.
private struct FrequencyChip: View {
    let cluster: CPUClusterTopology
    let reading: MetricReading
    @Binding var isOn: Bool

    var body: some View {
        let selected = isOn && reading.unavailableReason == nil
        TileButton(color: Palette.cluster(cluster.role), isSelected: selected, cornerRadius: 5, action: { isOn.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .tertiary)
                ReadingText.frequency(reading, emphasis: selected ? .primary : .secondary)
            }
            .padding(.horizontal, 5)
            // Stays within the 14 pt bar row, so the 40 pt cluster slot doesn't grow.
            .padding(.vertical, 0.5)
        }
        .disabled(reading.unavailableReason != nil)
        .help(reading.unavailableReason?.message ?? (selected ? "The line shows \(cluster.title) frequency for the last 60 seconds. Click to show usage."
                   : "Show \(cluster.title) frequency for the last 60 seconds"))
        .accessibilityLabel("\(cluster.title) frequency")
        .accessibilityValue(ReadingText.spoken(reading, Format.spokenFrequency))
        .accessibilityHint(selected ? "Shows the usage bar again" : "Shows frequency history in place of the usage bar")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Six fixed-width cells per row; larger clusters scroll within the expanded slot.
private struct PanelCoreGrid: View {
    let cluster: CPUClusterTopology
    let cpu: CPUSnapshot
    let metric: PanelMetric
    var cellHeight: CGFloat = 32

    var body: some View {
        let cores = cluster.cores
        let columns = min(6, max(1, cores.count))
        let rows = (cores.count + columns - 1) / columns
        GeometryReader { geometry in
            let cellWidth = max(0, (geometry.size.width - CGFloat(columns - 1) * 4) / CGFloat(columns))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(cores[(row * columns)..<min((row + 1) * columns, cores.count)]) { core in
                            let reading = metric.reading(core, cpu: cpu)
                            PanelCoreCell(core: core, reading: reading, metric: metric,
                                          fraction: metric.fraction(reading, cpu: cpu) ?? 0, height: cellHeight)
                                .frame(width: cellWidth)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(cluster.title) cores")
    }
}

private struct PanelCoreCell: View {
    let core: CoreID
    let reading: MetricReading
    let metric: PanelMetric
    let fraction: Double
    @Environment(\.temperatureUnit) private var unit
    var height: CGFloat = 32

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        let color = Palette.cluster(core.cluster)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: height < 24 ? 4 : 6).fill(.fill.quaternary)
            if height < 24 {
                // Two rows of six stay within the original cluster row's 40 pt slot.
                HStack(spacing: 1) {
                    Text(core.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                    ReadingText(reading: reading, format: { metric.text($0, unit: unit, compact: true) }, font: .system(size: 9.5, weight: .semibold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 2.5).padding(.bottom, 2)
                .frame(maxHeight: .infinity)
                Meter(fraction: fraction, color: color.opacity(paused ? 0.45 : 0.8), height: 2)
            } else {
                Rectangle()
                    .fill(color.opacity((paused ? 0.12 : 0.18) + 0.30 * fraction))
                    .frame(height: height * fraction)
                VStack(alignment: .leading, spacing: 0) {
                    Text(core.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        ReadingText(reading: reading, format: { metric.text($0, unit: unit, compact: true) }, font: .system(size: 11, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipShape(.rect(cornerRadius: height < 24 ? 4 : 6))
        .accessibilityElement(children: .ignore)
        .help("\(core.label) · \(reading.shownValue.map { metric.spoken($0, unit: unit) } ?? ReadingText.placeholderHelp(reading))")
        .accessibilityLabel("\(core.label) \(metric.coreLabel)")
        .accessibilityValue(reading.shownValue.map { metric.spoken($0, unit: unit) } ?? ReadingText.placeholderHelp(reading))
    }
}

// MARK: - GPU & ANE

/// GPU usage, temperature, and power as primary tiles; frequency and ANE power as one-line
/// tiles. Whichever is selected drives the sparkline below. ANE has power only.
struct GPUPanelSection: View {
    let model: DashboardModel
    @AppStorage("panel.gpu.metric") private var metric: PanelMetric = .usage
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        let gpu = model.gpu
        let chart = panelChart(metric)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle(title: "GPU & ANE")
                    Spacer()
                    ThermalStatusBadge(status: gpu.throttle, device: "GPU")
                }
                VStack(alignment: .leading, spacing: 2) {
                    TileRow {
                        MetricTile(title: "Usage", color: Palette.gpu, isSelected: metric == .usage,
                                   spokenValue: ReadingText.spoken(gpu.usage, Format.spokenPercent),
                                   action: { metric = .usage }) {
                            ReadingText.percent(gpu.usage, font: .pmTileNumber)
                        }
                        MetricTile(title: "Temperature", color: Palette.temperature, isSelected: metric == .temperature,
                                   spokenValue: ReadingText.spoken(gpu.temperature) { Format.spokenTemperature($0, unit: unit) },
                                   about: "Highest GPU temperature",
                                   action: { metric = .temperature }) {
                            TemperatureText(reading: gpu.temperature, font: .pmTileNumber, emphasis: .primary)
                        }
                        MetricTile(title: "GPU Power", color: Palette.power, isSelected: metric == .power,
                                   spokenValue: ReadingText.spoken(gpu.power, Format.spokenWatts),
                                   action: { metric = .power }) {
                            ReadingText.watts(gpu.power, font: .pmTileNumber)
                        }
                    }
                    TileRow {
                        MetricTile(title: "Frequency", color: Palette.gpu, isSelected: metric == .frequency,
                                   spokenValue: ReadingText.spoken(gpu.frequency, Format.spokenFrequency),
                                   compact: true, about: "GPU frequency, averaged over each update",
                                   action: { metric = .frequency }) {
                            ReadingText.frequency(gpu.frequency, font: .pmBodyNumber, emphasis: .primary)
                        }
                        MetricTile(title: "ANE Power", color: Palette.ane, isSelected: metric == .anePower,
                                   spokenValue: ReadingText.spoken(gpu.anePower, Format.spokenWatts),
                                   compact: true, about: "Neural Engine power",
                                   action: { metric = .anePower }) {
                            ReadingText.watts(gpu.anePower)
                        }
                    }
                    PanelSparkline(key: chart.key, title: chart.title, color: chart.color, scale: chart.scale,
                                   end: model.time, revision: model.historyRevision,
                                   unavailableReason: chart.unavailableReason)
                        .frame(height: PanelLayout.sparklineHeight)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func panelChart(_ metric: PanelMetric) -> PanelChart {
        switch metric {
        case .usage: PanelChart(key: .gpuUsage, title: "GPU usage", color: Palette.gpu, scale: .percent,
                                unavailableReason: model.gpu.usage.unavailableReason)
        case .temperature: PanelChart(key: .gpuTemperature, title: "GPU temperature", color: Palette.temperature, scale: .temperature,
                                     unavailableReason: model.gpu.temperature.unavailableReason)
        case .power: PanelChart(key: .gpuPower, title: "GPU power", color: Palette.power, scale: .watts,
                               unavailableReason: model.gpu.power.unavailableReason)
        case .anePower: PanelChart(key: .anePower, title: "ANE power", color: Palette.ane, scale: .watts,
                                  unavailableReason: model.gpu.anePower.unavailableReason)
        case .frequency: PanelChart(key: .gpuFrequency, title: "GPU frequency", color: Palette.gpu, scale: .gigahertz,
                                   unavailableReason: model.gpu.frequency.unavailableReason)
        }
    }
}

// MARK: - Memory

private enum MemoryMode: CaseIterable {
    case usage, history, processes

    var title: String {
        switch self {
        case .usage: "Usage"
        case .history: "History"
        case .processes: "Top 10"
        }
    }

    var hint: String {
        switch self {
        case .usage: "Shows where memory goes, including Reusable and Swap"
        case .history: "Shows memory used over the last 60 seconds"
        case .processes: "Shows the 10 processes using the most memory"
        }
    }
}

/// Three named views in one fixed-height card: the usage summary, a 60-second line of
/// memory used, and the top 10 processes. The summary always sets the card's height and
/// the other views draw over it. Processes are collected only while Top 10 is shown.
struct MemoryPanelSection: View {
    let model: DashboardModel
    /// Tells the controller whether the process list is on screen, so it is collected only then.
    let onProcessListVisibilityChange: (Bool) -> Void

    /// Earlier builds stored only this flag, meaning Top 10. It takes precedence over history.
    @AppStorage("panel.expanded.memory") private var showsProcesses = false
    @AppStorage("panel.memory.history") private var showsHistory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: MemoryMode {
        showsProcesses ? .processes : showsHistory ? .history : .usage
    }

    var body: some View {
        let memory = model.memory
        let current = mode
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle(title: "Memory")
                    HStack(spacing: 2) {
                        ForEach(MemoryMode.allCases, id: \.self) { option in
                            ModeChip(title: option.title, isSelected: current == option, hint: option.hint) {
                                select(option)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Memory view")
                    Spacer(minLength: 4)
                    PressureBadge(reading: memory.pressure)
                }
                // The summary owns the size in every mode. History and processes are
                // overlays, so switching cannot resize this card or the popover.
                memorySummary(memory)
                    .opacity(current == .usage ? 1 : 0)
                    .accessibilityHidden(current != .usage)
                    .overlay {
                        switch current {
                        case .usage: EmptyView()
                        case .history: memoryHistory(memory)
                        case .processes: PanelProcessColumns(snapshot: memory.processes)
                        }
                    }
            }
        }
        .onAppear { onProcessListVisibilityChange(mode == .processes) }
        .onChange(of: mode == .processes) { _, visible in onProcessListVisibilityChange(visible) }
    }

    /// "Used / installed" with Swap on the right, then where the memory goes.
    private func memorySummary(_ memory: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ReadingText.bytes(memory.used, font: .pmHeadline)
                Text("/ \(Format.wholeGigabytes(memory.physical))")
                    .font(.pmCaption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Swap").foregroundStyle(.secondary)
                    ReadingText.bytes(memory.swapUsed, font: .pmCaptionNumber)
                }
                .font(.pmCaption)
                .fixedSize()
            }
            MemoryCompositionView(memory: memory, layout: .panel)
        }
    }

    /// Memory used for the last 60 seconds, in the summary's space. The current value and
    /// installed total stay in view. Pressure is a level, not a quantity on this line, so it
    /// stays in the header badge.
    private func memoryHistory(_ memory: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Used").font(.pmCaption).foregroundStyle(.secondary)
                ReadingText.bytes(memory.used)
                Text("of \(Format.wholeGigabytes(memory.physical))")
                    .font(.pmCaption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HistorySpanLabel()
            }
            .accessibilityElement(children: .combine)
            PanelSparkline(key: .memoryUsed, title: "Memory used", color: Palette.memory,
                           scale: .bytes(total: memory.physical), end: model.time, revision: model.historyRevision)
                .frame(maxHeight: .infinity)
        }
    }

    private func select(_ option: MemoryMode) {
        let change = {
            showsProcesses = option == .processes
            showsHistory = option == .history
        }
        if reduceMotion {
            change()
        } else {
            withAnimation(.snappy(duration: 0.22), change)
        }
    }
}

/// A named view choice in a card header. The selected chip is filled; every chip is a
/// button, so VoiceOver and Keyboard Navigation can choose it directly.
private struct ModeChip: View {
    let title: String
    let isSelected: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        TileButton(color: .primary, isSelected: isSelected, cornerRadius: 5, action: action) {
            Text(title)
                .font(.pmCaption.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        }
        .help(hint)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - I/O

/// Disk capacity, disk activity, and network traffic share one fixed-height card.
struct DiskPanelSection: View {
    let model: DashboardModel
    let setTransferDemand: (Demand?) -> Void
    let openNetwork: () -> Void
    @AppStorage("panel.io.network") private var showsNetwork = false

    /// The chosen drive's BSD name. If it's disconnected, the first (startup) drive shows
    /// instead, and the choice returns when it's connected again.
    @AppStorage("panel.disk.drive") private var selectedDriveID = ""
    @AppStorage("panel.disk.showsActivity") private var showsActivity = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let contentHeight: CGFloat = 40

    var body: some View {
        let drives = model.diskDrives
        let drive = drives.first { $0.id == selectedDriveID } ?? drives.first
        Card {
            VStack(alignment: .leading, spacing: 8) {
                header(drives, drive: drive)
                    .frame(height: 18)
                Group {
                    if showsNetwork {
                        TransferPair(rates: model.network.rates, incoming: "Download", outgoing: "Upload", font: .pmTileNumber)
                    } else if let drive {
                        diskTile(drive)
                    } else {
                        pending
                    }
                }
                .frame(height: Self.contentHeight, alignment: .top)
            }
        }
        .onChange(of: transferDemand, initial: true) { _, demand in setTransferDemand(demand) }
    }

    private var transferDemand: Demand? {
        if showsNetwork { return .panelNetwork }
        return showsActivity ? .panelDiskActivity : nil
    }

    // MARK: Header

    private func header(_ drives: [DiskDriveSnapshot], drive: DiskDriveSnapshot?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SectionTitle(title: "I/O")
                .fixedSize()
            HStack(spacing: 2) {
                ModeChip(title: "Disk", isSelected: !showsNetwork, hint: "Show the selected drive") { showsNetwork = false }
                ModeChip(title: "Network", isSelected: showsNetwork, hint: "Show interface traffic") { showsNetwork = true }
            }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("I/O view")
            Spacer(minLength: 6)
            if showsNetwork {
                let disconnected = model.network.rates.incoming.unavailableReason == .interfaceDisconnected
                Button(action: openNetwork) {
                    Text(model.network.selected?.displayTitle ?? (disconnected ? "Disconnected" : "Network details"))
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open Network")
                .accessibilityHint("Opens the Network page")
            } else if let drive {
                if drives.count > 1 {
                    driveMenu(drives, selected: drive)
                } else {
                    Text("\(drive.shortTitle)\(Text(" · \(drive.id)").foregroundStyle(.tertiary))")
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(drive.menuTitle)
                }
            } else {
                Text(model.disk.name)
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func diskTile(_ drive: DiskDriveSnapshot) -> some View {
        let name = drive.leadingVolume?.name ?? drive.name
        let activity = showsActivity ? model.diskActivity.first { $0.device == drive.id } : nil
        return TileButton(color: .primary, isSelected: false, cornerRadius: 6, action: toggleDiskView) {
            Group {
                if !showsActivity {
                    summary(drive, name: name)
                } else if let activity {
                    activityRow(activity)
                } else {
                    Text(activityStatusText)
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, TileLayout.inset)
        }
        .padding(.horizontal, -TileLayout.inset)
        .help(showsActivity ? "Click to show disk capacity." : "\(drive.capacityHelp) Click to show the last minute of read and write activity.")
        .accessibilityLabel(showsActivity ? "\(name), disk activity" : "\(name), disk capacity")
        .accessibilityValue(showsActivity ? spokenActivity(activity) : drive.spokenCapacity)
        .accessibilityHint(showsActivity ? "Shows disk capacity" : "Shows the last minute of read and write activity")
    }

    private func activityRow(_ activity: DiskActivity) -> some View {
        HStack(spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 2) {
                diskRate("Read", activity.bytes.incoming, Palette.incoming)
                diskRate("Write", activity.bytes.outgoing, Palette.outgoing)
            }
            .frame(width: 102, alignment: .leading)
            TransferChart(incoming: .diskActivity(activity.id, .read), outgoing: .diskActivity(activity.id, .write),
                          labels: ("Read", "Write"),
                          context: ChartContext(range: .oneMinute, end: model.time, revision: model.historyRevision),
                          compact: true, reason: activity.bytes.incoming.unavailableReason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activityStatusText: String {
        switch model.diskActivityStatus {
        case .warming: ReadingStatus.warmingMessage
        case .unavailable(let reason): reason.message
        default: "No device counters available"
        }
    }

    private func spokenActivity(_ activity: DiskActivity?) -> String {
        guard let rates = activity?.bytes else { return activityStatusText }
        return "Read \(ReadingText.spoken(rates.incoming, Format.transferRate)), Write \(ReadingText.spoken(rates.outgoing, Format.transferRate))"
    }

    private func diskRate(_ label: String, _ bytes: MetricReading, _ color: Color) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).font(.pmCaption.weight(.medium)).foregroundStyle(color)
            ReadingText(reading: bytes, format: Format.transferRate, font: .pmBodyNumber)
                .lineLimit(1).minimumScaleFactor(0.85)
                .accessibilityLabel("\(label) \(ReadingText.spoken(bytes, Format.transferRate))")
        }
    }

    private func driveMenu(_ drives: [DiskDriveSnapshot], selected: DiskDriveSnapshot) -> some View {
        Menu {
            Picker("Drive", selection: Binding(get: { selected.id }, set: { selectedDriveID = $0 })) {
                ForEach(drives) { Text($0.menuTitle).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("\(selected.shortTitle) · \(selected.id)")
                .font(.pmCaption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("\(drives.count) drives connected. Choose one to show.")
        .accessibilityLabel("Drive")
        .accessibilityValue("\(selected.storageTitle), \(selected.id)")
        .accessibilityHint("Chooses which of \(drives.count) connected drives to show")
    }

    private func summary(_ drive: DiskDriveSnapshot, name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                DiskUsageText(capacity: drive, font: .pmTileNumber)
                DiskCapacityBar(capacity: drive)
            }
            Text(name)
                .font(.pmCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Before the first reading, or if none succeeds: the startup placeholder and its reason.
    private var pending: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                DiskUsageText(capacity: model.disk, font: .pmTileNumber)
                DiskCapacityBar(capacity: model.disk)
            }
            if let reason = model.disk.available.unavailableReason {
                Text(reason.message)
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.disk.name)
        .accessibilityValue(model.disk.spokenCapacity)
    }

    private func toggleDiskView() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            showsActivity.toggle()
        }
    }
}

// MARK: - Power

/// Three independent readings. Each tile switches between its value and its own
/// 60-second history; the value stays visible in the tile's title row while charted.
struct PowerPanelSection: View {
    let model: DashboardModel
    @AppStorage("panel.power.inputHistory") private var inputHistory = false
    @AppStorage("panel.power.systemHistory") private var systemHistory = false
    @AppStorage("panel.power.batteryHistory") private var batteryHistory = false

    var body: some View {
        let power = model.power
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle(title: "Power")
                    Spacer()
                    // Only while a tile is charted; live values aren't history.
                    if inputHistory || systemHistory || batteryHistory {
                        HistorySpanLabel()
                    }
                }
                TileRow {
                    PowerTile(title: "Input", spokenTitle: "Power Input", key: .powerInput, model: model,
                              spokenValue: power.hasAdapter == false ? "No adapter" : ReadingText.spoken(power.input, Format.spokenWatts),
                              showsHistory: $inputHistory) { font, compact in
                        if power.hasAdapter == false {
                            Text("No Adapter")
                                .font(compact ? .pmCaption : .system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            ReadingText.watts(power.input, font: font)
                        }
                    } detail: {
                        EmptyView()
                    }
                    PowerTile(title: "System", spokenTitle: "System Power", key: .powerSystem, model: model,
                              spokenValue: ReadingText.spoken(power.system, Format.spokenWatts),
                              showsHistory: $systemHistory) { font, _ in
                        ReadingText.watts(power.system, font: font)
                    } detail: {
                        EmptyView()
                    }
                    PowerTile(title: "Battery", spokenTitle: "Battery Power", key: .powerBattery, model: model,
                              spokenValue: batterySpoken(power),
                              showsHistory: $batteryHistory) { font, _ in
                        BatteryPowerText(power: power, font: font)
                    } detail: {
                        BatteryStatusLabel(power: power)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func batterySpoken(_ power: PowerSnapshot) -> String {
        let value = ReadingText.spoken(power.battery) { Format.spokenWatts(abs($0)) }
        return BatteryStatus(power: power).map { "\($0.title), \(value)" } ?? value
    }
}

private struct PowerTile<Value: View, Detail: View>: View {
    let title: String
    let spokenTitle: String
    let key: SeriesKey
    let model: DashboardModel
    let spokenValue: String
    @Binding var showsHistory: Bool
    /// The value at a given font; `compact` is true in the title row while charted.
    @ViewBuilder let value: (Font, Bool) -> Value
    @ViewBuilder var detail: Detail

    var body: some View {
        TileButton(color: Palette.power, isSelected: showsHistory, action: { showsHistory.toggle() }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .font(.pmCaption.weight(showsHistory ? .medium : .regular))
                        .foregroundStyle(showsHistory ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if showsHistory {
                        value(.pmCaptionNumber, true)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Group {
                    if showsHistory {
                        PanelSparkline(key: key, title: spokenTitle, color: Palette.power, scale: .watts,
                                       end: model.time, revision: model.historyRevision, showsScale: false)
                    } else {
                        value(.pmTileNumber, false)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                detail
            }
            .padding(.horizontal, TileLayout.inset)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .help(showsHistory ? "The line shows \(spokenTitle) for the last 60 seconds. Click to show the value."
                           : "Show \(spokenTitle) for the last 60 seconds")
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(showsHistory ? "\(spokenValue), showing the last 60 seconds" : spokenValue)
        .accessibilityHint(showsHistory ? "Shows the value" : "Shows the last 60 seconds")
        .accessibilityAddTraits(showsHistory ? .isSelected : [])
    }
}
