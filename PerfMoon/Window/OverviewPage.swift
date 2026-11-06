import PerfMoonKit
import SwiftUI

/// Three columns when the content is at least 760 pt wide, otherwise two. Power always spans.
struct OverviewPage: View {
    let model: DashboardModel
    let context: ChartContext
    let machine: MachineInfo
    let navigate: (Page) -> Void

    @State private var width: CGFloat = 800

    private var columns: Int { width >= 760 ? 3 : 2 }

    var body: some View {
        let spacing: CGFloat = 12
        let column = max(0, ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        PageScroll(width: $width) {
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
            powerCard
        }
    }

    // MARK: Cards

    private var cpuCard: some View {
        let cpu = model.cpu
        return OverviewCard(title: "CPU", page: .cpu, navigate: navigate) {
            ThrottleBadge(status: cpu.throttle)
            SourceTemperatureLabel(reading: cpu.temperature, source: cpu.temperatureSource)
        } content: {
            HStack(alignment: .firstTextBaseline) {
                ReadingText.percent(cpu.total, font: .pmCardNumber)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    LegendValue(title: "S-Core", color: Palette.sCore, reading: cpu.sCore)
                    LegendValue(title: "P-Core", color: Palette.pCore, reading: cpu.pCore, dashed: true)
                }
            }
            HistoryChart(
                series: [
                    ChartSeries(key: .cpuTotal, name: "Total", color: Palette.cpu, style: .area),
                    ChartSeries(key: .cpuS, name: "S-Core", color: Palette.sCore),
                    ChartSeries(key: .cpuP, name: "P-Core", color: Palette.pCore, dashed: true),
                ],
                scale: .percent, range: context.range, end: context.end, revision: context.revision,
                compact: true, accessibilityName: "CPU usage"
            )
            .frame(height: 84)
            VStack(spacing: 4) {
                ValueRow(label: "CPU Power") { ReadingText.watts(cpu.power) }
                ValueRow(label: "Frequency") {
                    FrequencyPair(s: cpu.sFrequency, p: cpu.pFrequency)
                        .layoutPriority(1)
                }
            }
        }
    }

    private var gpuCard: some View {
        let gpu = model.gpu
        return OverviewCard(title: "GPU & ANE", page: .gpu, navigate: navigate) {
            TemperatureText(reading: gpu.temperature).help("Highest GPU temperature")
        } content: {
            HStack(alignment: .firstTextBaseline) {
                ReadingText.percent(gpu.usage, font: .pmCardNumber)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Frequency")
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                    ReadingText.frequency(gpu.frequency, emphasis: .primary)
                }
                .accessibilityElement(children: .combine)
            }
            HistoryChart(
                series: [ChartSeries(key: .gpuUsage, name: "GPU", color: Palette.gpu, style: .lineAndArea)],
                scale: .percent, range: context.range, end: context.end, revision: context.revision,
                compact: true, accessibilityName: "GPU usage"
            )
            .frame(height: 84)
            VStack(spacing: 4) {
                ValueRow(label: "GPU Power") { ReadingText.watts(gpu.power) }
                ValueRow(label: "ANE Power", dot: Palette.ane) { ReadingText.watts(gpu.anePower) }
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
    let page: Page
    let navigate: (Page) -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Card(stretches: true) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: title) {
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
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            LegendKey(title: title, color: color, dashed: dashed)
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
