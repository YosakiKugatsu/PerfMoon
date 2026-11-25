// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

/// Three columns when the content is at least 760 pt wide, otherwise two. Power always spans.
struct OverviewPage: View {
    let model: DashboardModel
    let context: ChartContext
    let machine: MachineInfo
    let width: CGFloat
    let navigate: (Page) -> Void

    private var columns: Int { width >= 760 ? 3 : 2 }

    var body: some View {
        let spacing: CGFloat = 12
        let column = max(0, ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        PageScroll {
            if columns == 3 {
                EqualHeightRow(spacing: spacing) {
                    cpuCard.frame(width: column)
                    gpuCard.frame(width: column)
                    memoryCard.frame(width: column)
                }
            } else {
                EqualHeightRow(spacing: spacing) {
                    cpuCard.frame(width: column)
                    gpuCard.frame(width: column)
                }
                memoryCard
            }
            diskCard
            networkCard
            powerCard
        }
    }

    // MARK: Cards

    private var cpuCard: some View {
        let cpu = model.cpu
        return OverviewCard(title: "CPU", page: .cpu, navigate: navigate) {
            ThrottleBadge(status: cpu.throttle)
            OverviewMetricValue(reading: cpu.temperature) {
                SourceTemperatureLabel(reading: cpu.temperature, source: cpu.temperatureSource)
            }
        } content: {
            HStack(alignment: .firstTextBaseline) {
                ReadingText.percent(cpu.total, font: .pmCardNumber)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(cpu.topology.clusters) { cluster in
                        LegendValue(title: cluster.title, color: Palette.cluster(cluster.role), reading: cpu.usage(cluster.role),
                                    dash: cluster.role.usageDash)
                    }
                }
            }
            HistoryChart(
                series: cpu.usageChartSeries,
                scale: .percent, range: context.range, end: context.end, revision: context.revision,
                compact: true, accessibilityName: "CPU usage", unavailableReason: cpu.total.unavailableReason
            )
            .frame(height: 84)
            VStack(spacing: 4) {
                ValueRow(label: "CPU Power") {
                    OverviewMetricValue(reading: cpu.power) { ReadingText.watts(cpu.power) }
                }
                if let first = cpu.topology.clusters.first {
                    ValueRow(label: "Frequency") {
                        if cpu.topology.clusters.allSatisfy({ cpu.frequency($0.role).unavailableReason != nil }) {
                            ReasonCaption(reading: cpu.frequency(first.role))
                        } else {
                            ClusterFrequencies(cpu: cpu).layoutPriority(1)
                        }
                    }
                }
            }
        }
    }

    private var gpuCard: some View {
        let gpu = model.gpu
        return OverviewCard(title: "GPU & ANE", page: .gpu, navigate: navigate) {
            OverviewMetricValue(reading: gpu.temperature) {
                TemperatureText(reading: gpu.temperature).help("Highest GPU temperature")
            }
        } content: {
            HStack(alignment: .firstTextBaseline) {
                ReadingText.percent(gpu.usage, font: .pmCardNumber)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Frequency")
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                    OverviewMetricValue(reading: gpu.frequency) {
                        ReadingText.frequency(gpu.frequency, emphasis: .primary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HistoryChart(
                series: [ChartSeries(key: .gpuUsage, name: "GPU", color: Palette.gpu, style: .lineAndArea)],
                scale: .percent, range: context.range, end: context.end, revision: context.revision,
                compact: true, accessibilityName: "GPU usage", unavailableReason: gpu.usage.unavailableReason
            )
            .frame(height: 84)
            VStack(spacing: 4) {
                ValueRow(label: "GPU Power") { OverviewMetricValue(reading: gpu.power) { ReadingText.watts(gpu.power) } }
                ValueRow(label: "ANE Power", dot: Palette.ane) {
                    OverviewMetricValue(reading: gpu.anePower) { ReadingText.watts(gpu.anePower) }
                }
            }
        }
    }

    private var memoryCard: some View {
        let memory = model.memory
        return OverviewCard(title: "Memory", page: .memory, navigate: navigate) {
            PressureBadge(reading: memory.pressure)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ReadingText.bytes(memory.used, font: .pmCardNumber)
                Text("of \(Format.wholeGigabytes(memory.physical))")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                HistoryChart(
                    series: [ChartSeries(key: .memoryUsed, name: "Used", color: Palette.memory, style: .lineAndArea)],
                    scale: .bytes(maximum: memory.physical), range: context.range, end: context.end, revision: context.revision,
                    compact: true, accessibilityName: "Memory used"
                )
                LevelStrip(key: .memoryPressure, kind: .pressure, range: context.range, end: context.end, revision: context.revision)
            }
            .frame(height: 84)
            VStack(spacing: 4) {
                ValueRow(label: "Available") { ReadingText.bytes(memory.available) }
                ValueRow(label: "Swap Used") { ReadingText.bytes(memory.swapUsed) }
            }
        }
    }

    /// The startup drive in one row: used of total, then the occupancy bar filling the rest.
    /// Its storage type and startup volume head the card; other drives are counted there and
    /// listed on the Disk page.
    private var diskCard: some View {
        let drive = model.diskDrives.first
        let capacity: any StorageCapacity = drive.map { $0 as any StorageCapacity } ?? model.disk
        let subtitle = drive.map { drive in
            [drive.storageTitle, drive.leadingVolume?.name].compactMap { $0 }.joined(separator: " · ")
        } ?? model.disk.name
        let others = max(0, model.diskDrives.count - 1)
        let othersText = others == 1 ? "1 more drive" : "\(others) more drives"
        return OverviewCard(title: "Disk", subtitle: subtitle, page: .disk, navigate: navigate) {
            if others > 0 {
                Text(othersText)
                    .font(.pmCaption)
                    .foregroundStyle(.tertiary)
            }
            DiskAvailableText(capacity: capacity)
        } content: {
            HStack(alignment: .center, spacing: 16) {
                DiskUsageText(capacity: capacity, font: .pmCardNumber, separator: "of")
                DiskCapacityBar(capacity: capacity)
            }
            .helpIfPresent(drive.map { "\($0.menuTitle). \($0.capacityHelp)" })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(subtitle)
            .accessibilityValue(capacity.spokenCapacity
                + (drive?.capacityScopeName.map { ", for \($0)" } ?? "")
                + (others > 0 ? ", \(othersText) connected" : ""))
            if let activity = model.diskActivity.first(where: { $0.device == drive?.id }) {
                InlineTransfer(rates: activity.bytes, labels: ("Read", "Write"))
            }
        }
    }

    private var networkCard: some View {
        let network = model.network
        return OverviewCard(title: "Network", subtitle: network.selected?.displayTitle, page: .network, navigate: navigate) {
            EmptyView()
        } content: {
            HStack(spacing: 20) {
                TransferPair(rates: network.rates, incoming: "Download", outgoing: "Upload")
                TransferChart(incoming: .networkDownload, outgoing: .networkUpload, labels: ("Download", "Upload"),
                              context: context, compact: true, reason: network.rates.incoming.unavailableReason)
                    .frame(height: 44)
            }
        }
    }

    private var powerCard: some View {
        let power = model.power
        let gpu = model.gpu
        return OverviewCard(title: "Power", page: .power, navigate: navigate) {
            EmptyView()
        } content: {
            HStack(alignment: .top, spacing: 0) {
                PowerColumn(title: "Power Input", key: .powerInput, context: context, isFirst: true) {
                    if power.hasAdapter == false {
                        NoAdapterText(font: .pmStatNumber)
                    } else {
                        ReadingText.watts(power.input, font: .pmStatNumber)
                    }
                } detail: {
                    DetailSpacer()
                }
                PowerColumn(title: "System Power", key: .powerSystem, context: context) {
                    ReadingText.watts(power.system, font: .pmStatNumber)
                } detail: {
                    DetailSpacer()
                }
                PowerColumn(title: "Battery Power", key: .powerBattery, context: context, showsChargeStrip: true) {
                    BatteryPowerText(power: power, font: .pmStatNumber)
                } detail: {
                    BatteryStatusLabel(power: power)
                }
            }
            Divider()
            HStack(spacing: 14) {
                Text("Chip Power")
                    .font(.pmBody)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ChipValue(title: "CPU", color: Palette.cpu, reading: model.cpu.power)
                ChipValue(title: "GPU", color: Palette.gpu, reading: gpu.power)
                ChipValue(title: "ANE", color: Palette.ane, reading: gpu.anePower)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Overview parts

/// Compact cards have room for a reason in place of an unavailable value.
private struct OverviewMetricValue<Value: View>: View {
    let reading: MetricReading
    @ViewBuilder var value: Value

    var body: some View {
        if reading.unavailableReason == nil {
            value
        } else {
            ReasonCaption(reading: reading)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A row whose cards share the tallest card's height.
struct EqualHeightRow<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A card that opens its page when clicked.
private struct OverviewCard<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    let page: Page
    let navigate: (Page) -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Card(stretches: true) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: title, subtitle: subtitle) {
                    trailing
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.6)
                }
                content
            }
        }
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { navigate(page) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show \(page.title)") { navigate(page) }
    }
}

private struct LegendValue: View {
    let title: String
    let color: Color
    let reading: MetricReading
    var dash: [CGFloat] = []

    var body: some View {
        HStack(spacing: 6) {
            LegendKey(title: title, color: color, dash: dash)
            ReadingText.percent(reading, font: .pmCaptionNumber)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) usage")
    }
}

private struct PowerColumn<Value: View, Detail: View>: View {
    let title: String
    let key: SeriesKey
    let context: ChartContext
    var isFirst = false
    var showsChargeStrip = false
    @ViewBuilder var value: Value
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            if !isFirst { ColumnDivider().padding(.horizontal, 14) }
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.pmCaption).foregroundStyle(.secondary)
                    value
                    detail
                }
                .accessibilityElement(children: .combine)
                VStack(spacing: 5) {
                    HistoryChart(
                        series: [ChartSeries(key: key, name: title, color: Palette.power, style: .lineAndArea)],
                        scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                        compact: true, accessibilityName: title
                    )
                    if showsChargeStrip {
                        LevelStrip(key: .batteryState, kind: .charge, range: context.range, end: context.end, revision: context.revision)
                    }
                }
                .frame(height: 64)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NoAdapterText: View {
    var font: Font

    var body: some View {
        Text("No Adapter")
            .font(font)
            .foregroundStyle(.secondary)
    }
}

struct ChipValue: View {
    let title: String
    let color: Color
    let reading: MetricReading

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
                .accessibilityLabel("\(title) Power")
            ReadingText.watts(reading)
        }
        .font(.pmBody)
        .accessibilityElement(children: .combine)
    }
}

/// Reserves one caption line so columns with and without a detail line align.
struct DetailSpacer: View {
    var body: some View {
        Text(" ").font(.pmCaption).accessibilityHidden(true)
    }
}
