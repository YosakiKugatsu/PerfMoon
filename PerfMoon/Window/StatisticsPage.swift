// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

private enum StatisticUnit {
    case percent, frequency, temperature, watts, corePower, memory, storage, throughput, operations, pages

    func display(peak: Double, temperature: TemperatureUnit) -> (symbol: String, divisor: Double) {
        switch self {
        case .percent: ("%", 1)
        case .frequency: ("GHz", 1)
        case .temperature: (temperature == .celsius ? "°C" : "°F", 1)
        case .watts: ("W", 1)
        case .corePower: peak < 1 ? ("mW", 0.001) : ("W", 1)
        case .memory: peak >= Format.gibibyte ? ("GiB", Format.gibibyte) : ("MiB", Format.mebibyte)
        case .operations: ("IOPS", 1)
        case .pages: ("/s", 1)
        case .storage, .throughput:
            {
                var divisor = 1.0, i = 0
                let units = ["B", "kB", "MB", "GB", "TB", "PB"]
                while peak / divisor >= 1000 && i < units.count - 1 { divisor *= 1000; i += 1 }
                return (units[i] + (self == .throughput ? "/s" : ""), divisor)
            }()
        }
    }
}

private struct StatisticMetric: Identifiable {
    let id: SeriesKey
    let name: String
    let reading: MetricReading
    let unit: StatisticUnit

    init(_ key: SeriesKey, _ name: String, _ reading: MetricReading, _ unit: StatisticUnit) {
        id = key; self.name = name; self.reading = reading; self.unit = unit
    }
}

private struct StatisticGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    let metrics: [StatisticMetric]

    init(_ title: String, _ symbol: String, _ color: Color, _ metrics: [StatisticMetric], id: String? = nil) {
        self.id = id ?? title
        self.title = title; self.symbol = symbol; self.color = color; self.metrics = metrics
    }
}

struct StatisticsPage: View {
    let page: Page
    let model: DashboardModel
    let context: ChartContext
    let width: CGFloat
    let setCoreInspectorVisible: (Bool) -> Void
    @Environment(\.historyStore) private var history
    @Environment(\.temperatureUnit) private var temperature
    @Binding var preferredInterface: String
    @AppStorage("window.cpu.selectedCore") private var selectedCore = -1
    @State private var summary: [SeriesKey: RangeStatistics] = [:]
    @State private var displayedScope: Scope?

    private struct Scope: Equatable {
        var keys: [SeriesKey]
        var range: TimeRange
        var network: NetworkInterfaceInfo?
    }
    private struct Refresh: Equatable {
        var scope: Scope
        var tick: Int
        var paused: Bool
    }
    private let columns = ["Current", "Average", "Min", "Max", "P95"]
    private var cellWidth: CGFloat { max(48, (width - 32) * 0.133) }

    var body: some View {
        let sections = groups
        let keys = sections.flatMap { $0.metrics.map(\.id) }
        let scope = Scope(keys: keys, range: context.range, network: keys.contains(.networkDownload) ? model.network.selected : nil)
        let end = context.end
        PageScroll {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Range Statistics").font(.title2.weight(.semibold))
                InfoButton(label: "How statistics are calculated") {
                    Text("Average, minimum, maximum, and P95 use valid samples in the selected time range. Each sample counts once. P95 is the smallest value at or above 95% of the ordered samples. Pauses and missing readings contribute no samples.")
                        .frame(maxWidth: 320, alignment: .leading)
                }
                Spacer()
                Text("Last " + context.range.spokenTitle).font(.pmBody).foregroundStyle(.secondary)
            }
            ForEach(sections) { group in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: group.symbol).foregroundStyle(group.color).accessibilityHidden(true)
                            Text(group.title).font(.headline).accessibilityAddTraits(.isHeader)
                            Spacer()
                            if group.id == "cores" { corePicker }
                            if page == .network {
                                NetworkInterfacePicker(interfaces: model.network.interfaces, preferredInterface: $preferredInterface)
                            }
                        }
                        HStack(spacing: 0) {
                            Text("Metric").frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(columns, id: \.self) { Text($0).frame(width: cellWidth, alignment: .trailing) }
                        }.font(.pmCaption.weight(.medium)).foregroundStyle(.secondary)
                        Divider()
                        ForEach(group.metrics) { metric in
                            row(metric, values: displayedScope == scope ? summary[metric.id] : nil)
                        }
                    }
                }
            }
            if sections.isEmpty {
                Text("Waiting for device readings…").foregroundStyle(.secondary)
            }
        }
        .id(page)
        .task(id: Refresh(scope: scope, tick: Int(end / 2), paused: model.run.isPaused)) {
            guard let history else { return }
            let values = await history.statistics(for: Array(Set(keys)), from: end - context.range.seconds, through: end)
            guard !Task.isCancelled else { return }
            summary = values
            displayedScope = scope
        }
        .onChange(of: page == .cpu, initial: true) { _, cpu in setCoreInspectorVisible(cpu) }
        .onDisappear { setCoreInspectorVisible(false) }
    }

    private func row(_ metric: StatisticMetric, values: RangeStatistics?) -> some View {
        let numbers = [metric.reading.shownValue, values?.average, values?.minimum, values?.maximum, values?.p95]
        let unit = metric.unit.display(peak: numbers.compactMap { $0 }.map(abs).max() ?? 0, temperature: temperature)
        let texts = numbers.map { number -> String in
            guard let number else { return Format.placeholder }
            if metric.unit == .percent { return String(Int(number.rounded())) }
            if metric.unit == .temperature { return String(Format.temperatureValue(number, unit: temperature)) }
            return (number / unit.divisor).formatted(.number.precision(.significantDigits(1...3)))
        }
        let detail = values.map { "\($0.count) valid samples · \(Format.clockTime($0.firstTime))–\(Format.clockTime($0.lastTime))" } ?? "No samples in this range"
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.name).font(.pmBody).lineLimit(2)
                Text(unit.symbol).font(.pmCaption).foregroundStyle(.secondary).fixedSize()
            }.frame(maxWidth: .infinity, alignment: .leading)
            ForEach(texts.indices, id: \.self) { i in
                Text(texts[i]).font(.pmBodyNumber).fontWeight(i == 0 ? .semibold : .regular)
                    .foregroundStyle(i == 0 && metric.reading.isStale || numbers[i] == nil ? .secondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(width: cellWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.name + ", " + unit.symbol)
        .accessibilityValue(zip(columns, texts).map { "\($0) \($1)" }.joined(separator: ", "))
        .accessibilityHint(detail)
    }

    private var cores: [CoreID] { model.cpu.topology.clusters.flatMap(\.cores) }
    private var core: CoreID? { cores.first { $0.flatIndex == selectedCore } ?? cores.first }

    private var corePicker: some View {
        Picker("Core", selection: Binding(get: { core?.flatIndex ?? -1 }, set: { selectedCore = $0 })) {
            ForEach(cores) { Text($0.label).tag($0.flatIndex) }
        }.labelsHidden().fixedSize().controlSize(.small).accessibilityLabel("Inspected core")
    }

    private var groups: [StatisticGroup] {
        let overview = page == .overview
        var result: [StatisticGroup] = []
        let cpu = model.cpu, gpu = model.gpu, memory = model.memory, power = model.power
        if overview || page == .cpu {
            var rows: [StatisticMetric] = [.init(.cpuTotal, "Usage", cpu.total, .percent),
                .init(.cpuTemperature, "Temperature", cpu.temperature, .temperature), .init(.cpuPower, "Power", cpu.power, .watts)]
            for cluster in cpu.topology.clusters {
                rows.append(.init(cluster.role.usageSeries, cluster.title + " usage", cpu.usage(cluster.role), .percent))
                rows.append(.init(cluster.role.frequencySeries, cluster.title + " frequency", cpu.frequency(cluster.role), .frequency))
            }
            result.append(.init("CPU", "cpu", Palette.cpu, rows))
            if page == .cpu, let core {
                let i = core.flatIndex
                result.append(.init("Individual Core", "cpu", Palette.cluster(core.cluster), [
                    .init(.coreUsage(core), "Usage", cpu.cores.indices.contains(i) ? cpu.cores[i] : .pending(.percent), .percent),
                    .init(.coreTemperature(core), "Temperature", cpu.coreTemperatures.indices.contains(i) ? cpu.coreTemperatures[i] ?? .pending(.celsius) : .pending(.celsius), .temperature),
                    .init(.corePower(core), "Power", cpu.corePowers.indices.contains(i) ? cpu.corePowers[i] : .pending(.watts), .corePower)
                ], id: "cores"))
            }
        }
        if overview || page == .gpu {
            result.append(.init("GPU & ANE", Page.gpu.symbol, Palette.gpu, [
                .init(.gpuUsage, "GPU usage", gpu.usage, .percent), .init(.gpuFrequency, "Frequency", gpu.frequency, .frequency),
                .init(.gpuTemperature, "Temperature", gpu.temperature, .temperature), .init(.gpuPower, "GPU power", gpu.power, .watts),
                .init(.anePower, "ANE power", gpu.anePower, .watts)]))
        }
        if overview || page == .memory {
            var rows: [StatisticMetric] = [.init(.memoryUsed, "Used", memory.used, .memory),
                .init(.memoryDetail(.available), "Available", memory.available, .memory),
                .init(.memoryDetail(.swapUsed), "Swap used", memory.swapUsed, .memory)]
            if page == .memory {
                rows += [.init(.memoryDetail(.app), "Apps", memory.app, .memory),
                         .init(.memoryDetail(.wired), "Wired", memory.wired, .memory),
                         .init(.memoryDetail(.compressed), "Compressed", memory.compressed, .memory),
                         .init(.memoryDetail(.cached), "Cached", memory.cached, .memory),
                         .init(.memoryDetail(.purgeable), "Purgeable", memory.purgeable, .memory),
                         .init(.memoryDetail(.reusable), "Reusable", memory.reusable, .memory),
                         .init(.memoryDetail(.free), "Free", memory.free, .memory),
                         .init(.memoryDetail(.pageIns), "Page-ins", memory.pageIns, .pages),
                         .init(.memoryDetail(.pageOuts), "Page-outs", memory.pageOuts, .pages),
                         .init(.memoryDetail(.swapIns), "Swap-ins", memory.swapIns, .pages),
                         .init(.memoryDetail(.swapOuts), "Swap-outs", memory.swapOuts, .pages)]
            }
            result.append(.init("Memory", Page.memory.symbol, .secondary, rows))
        }
        if overview || page == .disk {
            for drive in model.diskDrives {
                var rows: [StatisticMetric] = []
                if let io = model.diskActivity.first(where: { $0.device == drive.id }) {
                    rows += [.init(.diskActivity(io.id, .read), "Read", io.bytes.incoming, .throughput),
                             .init(.diskActivity(io.id, .write), "Write", io.bytes.outgoing, .throughput)]
                    if !overview {
                        rows += [.init(.diskActivity(io.id, .readIOPS), "Read operations", io.operations.incoming, .operations),
                                 .init(.diskActivity(io.id, .writeIOPS), "Write operations", io.operations.outgoing, .operations)]
                    }
                }
                for (metric, reading) in drive.capacityReadings {
                    let name: String
                    switch metric {
                    case .used: name = "Used"
                    case .available: name = "Available"
                    case .allocated: if overview { continue }; name = "Allocated"
                    case .reclaimable: if overview { continue }; name = "Reclaimable"
                    case .volume(let id):
                        guard !overview, let volume = drive.volumes.first(where: { $0.id == id }) else { continue }
                        name = volume.name + " used"
                    }
                    rows.append(.init(drive.capacityKey(metric), name, reading, .storage))
                }
                result.append(.init(drive.storageTitle + " · " + drive.id, drive.symbol, .secondary, rows, id: drive.id))
            }
        }
        if overview || page == .network {
            let net = model.network
            result.append(.init(net.selected?.displayTitle ?? "Network", Page.network.symbol, Palette.incoming, [
                .init(.networkDownload, "Download", net.rates.incoming, .throughput), .init(.networkUpload, "Upload", net.rates.outgoing, .throughput)]))
        }
        if overview || page == .power {
            var rows: [StatisticMetric] = [.init(.powerInput, "Adapter input", power.input, .watts),
                .init(.powerSystem, "System", power.system, .watts), .init(.powerBattery, "Battery (signed)", power.battery, .watts)]
            if !overview {
                rows += [.init(.cpuPower, "CPU", cpu.power, .watts), .init(.gpuPower, "GPU", gpu.power, .watts), .init(.anePower, "ANE", gpu.anePower, .watts)]
            }
            result.append(.init("Power", Page.power.symbol, Palette.power, rows))
        }
        return result
    }
}
