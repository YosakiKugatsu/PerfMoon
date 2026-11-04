import PerfMoonKit
import SwiftUI

/// Shared panel geometry. The cluster slot height never changes between states.
private enum PanelLayout {
    static let clusterHeight: CGFloat = 40
    /// Two rows of six plus a 4 pt gap fill the cluster slot exactly.
    static let compactCellHeight: CGFloat = 18
    /// Fits "100 °C", "34.6 W", and "1.6 GHz" at the full 22 pt headline size.
    static let headlineWidth: CGFloat = 74
}

private enum PanelMetric: String {
    case usage, temperature, power, anePower, frequency
}

private struct MetricSwitch<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(help)
            .accessibilityHint(help)
    }
}

// MARK: - CPU

struct CPUPanelSection: View {
    let model: DashboardModel

    @AppStorage("panel.cpu.metric") private var metric: PanelMetric = .usage
    @AppStorage("panel.expanded.s") private var expandedS = false
    @AppStorage("panel.expanded.p") private var expandedP = false
    @AppStorage("panel.frequency.s") private var frequencyS = false
    @AppStorage("panel.frequency.p") private var frequencyP = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sensorNames) private var sensorNames

    var body: some View {
        let cpu = model.cpu
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle(title: "CPU")
                    Spacer()
                    ThrottleBadge(status: cpu.throttle)
                    MetricSwitch(help: metric == .temperature
                                    ? "Show CPU usage history"
                                    : "\(temperatureDescription(cpu.temperatureSource)). Click to show its history.",
                                 action: { metric = metric == .temperature ? .usage : .temperature }) {
                        if metric == .temperature {
                            ReadingText.percent(cpu.total, font: .pmCaptionNumber, emphasis: .secondary)
                        } else {
                            SourceTemperatureLabel(reading: cpu.temperature, source: cpu.temperatureSource, showsHelp: false)
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    primaryValue(cpu)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: PanelLayout.headlineWidth, height: 28, alignment: .leading)
                    Sparkline(key: chartKey, color: chartColor, end: model.time, revision: model.historyRevision,
                              domain: metric == .usage ? 0...100 : nil, zeroBased: metric == .power)
                        .frame(height: 24)
                        .help(metric == .usage ? "CPU usage history" : metric == .temperature ? "CPU temperature history" : "CPU power history")
                }

                VStack(alignment: .leading, spacing: 8) {
                    ClusterDisclosure(cluster: .s, cpu: cpu, model: model, isExpanded: binding($expandedS), showsFrequency: $frequencyS)
                    ClusterDisclosure(cluster: .p, cpu: cpu, model: model, isExpanded: binding($expandedP), showsFrequency: $frequencyP)
                }

                MetricSwitch(help: metric == .power ? "Show CPU usage history" : "Show CPU power history",
                             action: { metric = metric == .power ? .usage : .power }) {
                    ValueRow(label: metric == .power ? "CPU Usage" : "CPU Power") {
                        if metric == .power { ReadingText.percent(cpu.total) }
                        else { ReadingText.watts(cpu.power) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func primaryValue(_ cpu: CPUSnapshot) -> some View {
        switch metric {
        case .usage: ReadingText.percent(cpu.total, font: .pmHeadline)
        case .temperature: TemperatureText(reading: cpu.temperature, font: .pmHeadline, emphasis: .primary)
        case .power, .anePower, .frequency: ReadingText.watts(cpu.power, font: .pmHeadline)
        }
    }

    private func temperatureDescription(_ source: TemperatureSource) -> String {
        switch source {
        case .cpuMax: "Highest CPU temperature"
        case .cpuAverage: "Average CPU temperature"
        case .sensor(let id): sensorNames[id].map { "\($0) (\(id))" } ?? id
        }
    }

    private var chartKey: SeriesKey {
        switch metric {
        case .usage: .cpuTotal
        case .temperature: .cpuTemperature
        case .power, .anePower, .frequency: .cpuPower
        }
    }

    private var chartColor: Color {
        switch metric {
        case .usage: Palette.cpu
        case .temperature: Palette.temperature
        case .power, .anePower, .frequency: Palette.power
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

/// A cluster row that expands to show every core. Click, Return, or Space toggles.
private struct ClusterDisclosure: View {
    let cluster: CoreCluster
    let cpu: CPUSnapshot
    let model: DashboardModel
    @Binding var isExpanded: Bool
    @Binding var showsFrequency: Bool

    var body: some View {
        let usage = cpu.usage(cluster)
        HStack(spacing: 8) {
            CoreTierIcon(tier: .cluster(cluster))
                .frame(height: PanelLayout.clusterHeight)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
            ZStack {
                if isExpanded {
                    PanelCoreGrid(cluster: cluster, cpu: cpu, cellHeight: cluster == .s ? PanelLayout.clusterHeight : PanelLayout.compactCellHeight)
                        .disclosureInteraction(isExpanded: $isExpanded,
                            label: "\(cluster.spokenTitle), \(cluster.count) cores", value: accessibilityValue(usage),
                            hint: "Shows cluster usage and frequency", preservesChildren: true)
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(cluster.title).font(.system(size: 13, weight: .medium))
                            Text("×\(cluster.count)")
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            ReadingText.percent(usage, font: .system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .disclosureInteraction(isExpanded: $isExpanded,
                            label: "\(cluster.spokenTitle), \(cluster.count) cores", value: accessibilityValue(usage),
                            hint: "Shows per-core usage")
                        HStack(spacing: 10) {
                            Group {
                                if showsFrequency {
                                    Sparkline(key: cluster == .s ? .cpuFrequencyS : .cpuFrequencyP,
                                              color: Palette.cluster(cluster), end: model.time, revision: model.historyRevision,
                                              domain: nil, zeroBased: true)
                                } else {
                                    Meter(fraction: usage.shownValue.map { $0 / 100 }, color: Palette.cluster(cluster))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                            .contentShape(Rectangle())
                            .onTapGesture { isExpanded.toggle() }
                            MetricSwitch(help: showsFrequency ? "Show \(cluster.title) usage bar" : "Show \(cluster.title) frequency history",
                                         action: { showsFrequency.toggle() }) {
                                ReadingText.frequency(cpu.frequency(cluster))
                                    .frame(width: 84, alignment: .trailing)
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
            // button sits above this layer, so its click never reaches the toggle.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
                .accessibilityHidden(true)
        }
    }

    private func accessibilityValue(_ usage: MetricReading) -> String {
        var parts: [String] = []
        parts.append(usage.shownValue.map(Format.spokenPercent) ?? ReadingText.placeholderHelp(usage))
        if let frequency = cpu.frequency(cluster).shownValue {
            parts.append("frequency \(Format.spokenFrequency(frequency))")
        }
        parts.append(isExpanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

/// Rotating chevron shared by panel disclosures.
private struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 10)
            .accessibilityHidden(true)
    }
}

/// Six fixed-width cells per row; the panel reserves room for two P-Core rows.
private struct PanelCoreGrid: View {
    let cluster: CoreCluster
    let cpu: CPUSnapshot
    var cellHeight: CGFloat = 32

    var body: some View {
        let cores = cluster.cores
        let rows = stride(from: 0, to: cores.count, by: 6).map { Array(cores[$0..<min($0 + 6, cores.count)]) }
        VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row]) { core in
                        PanelCoreCell(core: core, reading: cpu.cores[core.flatIndex], height: cellHeight)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(cluster.spokenTitle) cores")
    }
}

private struct PanelCoreCell: View {
    let core: CoreID
    let reading: MetricReading
    var height: CGFloat = 32

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        let fraction = min(1, max(0, (reading.shownValue ?? 0) / 100))
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
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    ReadingText.percent(reading, font: .system(size: 9.5, weight: .semibold).monospacedDigit())
                        .fixedSize()
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
                        ReadingText.percent(reading, font: .system(size: 11, weight: .semibold).monospacedDigit())
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipShape(.rect(cornerRadius: height < 24 ? 4 : 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(core.label)
        .accessibilityValue(reading.shownValue.map(Format.spokenPercent) ?? ReadingText.placeholderHelp(reading))
    }
}

// MARK: - GPU & ANE

struct GPUPanelSection: View {
    let model: DashboardModel
    @AppStorage("panel.gpu.metric") private var metric: PanelMetric = .usage

    var body: some View {
        let gpu = model.gpu
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: "GPU & ANE")
                    Spacer()
                    MetricSwitch(help: metric == .temperature
                                    ? "Show GPU usage history"
                                    : "Highest GPU temperature. Click to show its history.",
                                 action: { metric = metric == .temperature ? .usage : .temperature }) {
                        if metric == .temperature {
                            ReadingText.percent(gpu.usage, font: .pmCaptionNumber, emphasis: .secondary)
                        } else {
                            TemperatureText(reading: gpu.temperature)
                        }
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    primaryValue(gpu)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: PanelLayout.headlineWidth, height: 28, alignment: .leading)
                    Sparkline(key: chartKey, color: chartColor, end: model.time, revision: model.historyRevision,
                              domain: metric == .usage ? 0...100 : nil,
                              zeroBased: metric == .power || metric == .anePower || metric == .frequency)
                        .frame(height: 24)
                        .help(metric == .usage ? "GPU usage history" : metric == .temperature ? "GPU temperature history" : metric == .power ? "GPU power history" : metric == .frequency ? "GPU frequency history" : "ANE power history")
                }
                VStack(spacing: 6) {
                    MetricSwitch(help: metric == .frequency ? "Show GPU usage history" : "Show GPU frequency history",
                                 action: { metric = metric == .frequency ? .usage : .frequency }) {
                        ValueRow(label: metric == .frequency ? "GPU Usage" : "Frequency") {
                            if metric == .frequency { ReadingText.percent(gpu.usage) }
                            else { ReadingText.frequency(gpu.frequency, font: .pmBodyNumber, emphasis: .primary) }
                        }
                    }
                    MetricSwitch(help: metric == .power ? "Show GPU usage history" : "Show GPU power history",
                                 action: { metric = metric == .power ? .usage : .power }) {
                        ValueRow(label: metric == .power ? "GPU Usage" : "GPU Power") {
                            if metric == .power { ReadingText.percent(gpu.usage) }
                            else { ReadingText.watts(gpu.power) }
                        }
                    }
                    Divider()
                    MetricSwitch(help: metric == .anePower ? "Show GPU usage history" : "Show ANE power history",
                                 action: { metric = metric == .anePower ? .usage : .anePower }) {
                        ValueRow(label: metric == .anePower ? "GPU Usage" : "ANE Power", dot: metric == .anePower ? Palette.gpu : Palette.ane) {
                            if metric == .anePower { ReadingText.percent(gpu.usage) }
                            else { ReadingText.watts(gpu.anePower) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func primaryValue(_ gpu: GPUSnapshot) -> some View {
        switch metric {
        case .usage: ReadingText.percent(gpu.usage, font: .pmHeadline)
        case .temperature: TemperatureText(reading: gpu.temperature, font: .pmHeadline, emphasis: .primary)
        case .power: ReadingText.watts(gpu.power, font: .pmHeadline)
        case .anePower: ReadingText.watts(gpu.anePower, font: .pmHeadline)
        case .frequency: ReadingText.frequency(gpu.frequency, font: .pmHeadline, emphasis: .primary)
        }
    }

    private var chartKey: SeriesKey {
        switch metric {
        case .usage: .gpuUsage
        case .temperature: .gpuTemperature
        case .power: .gpuPower
        case .anePower: .anePower
        case .frequency: .gpuFrequency
        }
    }

    private var chartColor: Color {
        switch metric {
        case .usage: Palette.gpu
        case .temperature: Palette.temperature
        case .power: Palette.power
        case .anePower: Palette.ane
        case .frequency: Palette.gpu
        }
    }
}

// MARK: - Memory

struct MemoryPanelSection: View {
    let model: DashboardModel
    /// Tells the controller whether the process list is on screen, so it is collected only then.
    let onProcessListVisibilityChange: (Bool) -> Void

    @AppStorage("panel.expanded.memory") private var showsProcesses = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let memory = model.memory
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SectionTitle(title: "Memory")
                    DisclosureChevron(isExpanded: showsProcesses)
                    if showsProcesses {
                        Text("Top 10").font(.pmCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PressureBadge(reading: memory.pressure)
                }
                // The summary owns the size in both states. The process grid is an
                // overlay, so changing content cannot resize this card or the popover.
                memorySummary(memory)
                    .opacity(showsProcesses ? 0 : 1)
                    .accessibilityHidden(showsProcesses)
                    .overlay {
                        if showsProcesses {
                            PanelProcessColumns(snapshot: memory.processes)
                        }
                    }
            }
            .disclosureInteraction(
                isExpanded: expansion,
                label: "Memory",
                value: showsProcesses ? "Top 10 processes by memory" : summary(memory),
                hint: showsProcesses ? "Shows memory usage" : "Shows the top 10 processes by memory",
                preservesChildren: showsProcesses
            )
            // Process rows carry their own tooltips, which take precedence over this one.
            .help(showsProcesses ? "Show memory usage" : "Show the top 10 processes by memory")
        }
        .onAppear { onProcessListVisibilityChange(showsProcesses) }
        .onChange(of: showsProcesses) { _, visible in onProcessListVisibilityChange(visible) }
    }

    private func memorySummary(_ memory: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ReadingText.bytes(memory.used, font: .pmHeadline)
                Text("used of \(Format.wholeGigabytes(memory.physical))")
                    .font(.pmCaption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Meter(fraction: memory.used.shownValue.map { $0 / memory.physical }, color: Palette.memory, height: 8)
            HStack {
                Text("Available").foregroundStyle(.secondary)
                ReadingText.bytes(memory.available, font: .pmCaptionNumber)
                Spacer()
                Text("Swap").foregroundStyle(.secondary)
                ReadingText.bytes(memory.swapUsed, font: .pmCaptionNumber)
            }
            .font(.pmCaption)
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { showsProcesses },
            set: { value in
                if reduceMotion {
                    showsProcesses = value
                } else {
                    withAnimation(.snappy(duration: 0.22)) { showsProcesses = value }
                }
            }
        )
    }

    private func summary(_ memory: MemorySnapshot) -> String {
        var parts: [String] = []
        if let used = memory.used.shownValue {
            parts.append("\(Format.spokenBytes(used)) used of \(Format.wholeGigabytes(memory.physical))")
        } else {
            parts.append(ReadingText.placeholderHelp(memory.used))
        }
        if let level = memory.pressureLevel {
            parts.append("pressure \(level.title)")
        }
        if let swap = memory.swapUsed.shownValue {
            parts.append("swap \(Format.spokenBytes(swap))")
        }
        parts.append(showsProcesses ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Power

struct PowerPanelSection: View {
    let model: DashboardModel
    @AppStorage("panel.power.inputHistory") private var inputHistory = false
    @AppStorage("panel.power.systemHistory") private var systemHistory = false
    @AppStorage("panel.power.batteryHistory") private var batteryHistory = false

    var body: some View {
        let power = model.power
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Power")
                HStack(alignment: .top, spacing: 0) {
                    MetricSwitch(help: inputHistory ? "Show input power value" : "Show input power history",
                                 action: { inputHistory.toggle() }) {
                        PowerTile(title: "Input", spokenTitle: "Power Input") {
                            Group {
                                if inputHistory {
                                    powerCurve(.powerInput)
                                } else if power.hasAdapter == false {
                                    Text("No Adapter").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                } else {
                                    ReadingText.watts(power.input, font: .pmTileNumber)
                                }
                            }
                            .frame(height: 24, alignment: .leading)
                        } detail: { EmptyView() }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityValue(power.input.shownValue.map(Format.spokenWatts) ?? ReadingText.placeholderHelp(power.input))
                    ColumnDivider()
                    MetricSwitch(help: systemHistory ? "Show system power value" : "Show system power history",
                                 action: { systemHistory.toggle() }) {
                        PowerTile(title: "System", spokenTitle: "System Power") {
                            Group {
                                if systemHistory { powerCurve(.powerSystem) }
                                else { ReadingText.watts(power.system, font: .pmTileNumber) }
                            }
                            .frame(height: 24, alignment: .leading)
                        } detail: { EmptyView() }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityValue(power.system.shownValue.map(Format.spokenWatts) ?? ReadingText.placeholderHelp(power.system))
                    ColumnDivider()
                    MetricSwitch(help: batteryHistory ? "Show battery power value" : "Show battery power history",
                                 action: { batteryHistory.toggle() }) {
                        PowerTile(title: "Battery", spokenTitle: "Battery Power") {
                            Group {
                                if batteryHistory { powerCurve(.powerBattery) }
                                else { BatteryPowerText(power: power, font: .pmTileNumber) }
                            }
                            .frame(height: 24, alignment: .leading)
                        } detail: { BatteryStatusLabel(power: power) }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityValue(power.battery.shownValue.map(Format.spokenWatts) ?? ReadingText.placeholderHelp(power.battery))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, -10)
            }
        }
    }

    private func powerCurve(_ key: SeriesKey) -> some View {
        Sparkline(key: key, color: Palette.power, end: model.time, revision: model.historyRevision,
                  domain: nil, zeroBased: true)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
    }
}

private struct PowerTile<Value: View, Detail: View>: View {
    let title: String
    let spokenTitle: String
    @ViewBuilder var value: Value
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.pmCaption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(spokenTitle)
            value
            detail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}
