import PerfMoonKit
import SwiftUI

struct CPUPage: View {
    let model: DashboardModel
    let context: ChartContext
    let openSensorSettings: () -> Void
    @Bindable var settings: AppSettings

    @State private var width: CGFloat = 800
    @Environment(\.sensorNames) private var sensorNames

    var body: some View {
        let cpu = model.cpu
        PageScroll(width: $width) {
            StatStrip {
                StatBlock(label: "Usage", isFirst: true) {
                    ReadingText.percent(cpu.total, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: cpu.total)
                }
                ForEach(CoreCluster.allCases, id: \.self) { cluster in
                    StatBlock(label: "\(cluster.title) ×\(cluster.count)") {
                        ReadingText.percent(cpu.usage(cluster), font: .pmStatNumber)
                    } detail: {
                        ReadingText.frequency(cpu.frequency(cluster))
                    }
                }
                StatBlock(label: "Temperature") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TemperatureText(reading: cpu.temperature, font: .pmStatNumber, emphasis: .primary)
                        ThrottleBadge(status: cpu.throttle)
                    }
                } detail: {
                    Text(sourceTitle(cpu.temperatureSource))
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                StatBlock(label: "CPU Power") {
                    ReadingText.watts(cpu.power, font: .pmStatNumber)
                } detail: {
                    ReasonCaption(reading: cpu.power)
                }
            }

            ChartCard(title: "Usage", height: 180) {
                HStack(spacing: 12) {
                    LegendKey(title: "Total", color: Palette.cpu.opacity(0.35))
                    LegendKey(title: "S-Core", color: Palette.sCore)
                    LegendKey(title: "P-Core", color: Palette.pCore, dashed: true)
                }
            } chart: {
                HistoryChart(
                    series: [
                        ChartSeries(key: .cpuTotal, name: "Total", color: Palette.cpu, style: .area),
                        ChartSeries(key: .cpuS, name: "S-Core", color: Palette.sCore),
                        ChartSeries(key: .cpuP, name: "P-Core", color: Palette.pCore, dashedForAccessibility: true),
                    ],
                    scale: .percent, range: context.range, end: context.end, revision: context.revision,
                    accessibilityName: "CPU usage"
                )
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Cores") {
                        InfoButton(label: "About core temperatures") {
                            CoreMappingExplanation()
                        }
                    }
                    CoreMatrix(cpu: cpu)
                }
            }

            EqualHeightRow {
                ChartCard(title: "Temperature") {
                    temperatureSourceMenu(cpu.temperatureSource)
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .cpuTemperature, name: "Temperature", color: Palette.temperature)],
                        scale: .temperature, range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "CPU temperature"
                    )
                }
                ChartCard(title: "CPU Power") {
                    ReadingText.watts(cpu.power, font: .pmCaptionNumber, emphasis: .secondary)
                } chart: {
                    HistoryChart(
                        series: [ChartSeries(key: .cpuPower, name: "CPU Power", color: Palette.cpu, style: .lineAndArea)],
                        scale: .watts(minimumMax: 10), range: context.range, end: context.end, revision: context.revision,
                        accessibilityName: "CPU power"
                    )
                }
            }
        }
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

/// Six columns that adapt between 76 and 140 pt with 8 pt gaps.
struct CoreMatrix: View {
    let cpu: CPUSnapshot

    @State private var width: CGFloat = 600

    var body: some View {
        let cell = min(140, max(76, ((width - 5 * 8) / 6).rounded(.down)))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(CoreCluster.allCases, id: \.self) { cluster in
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
                                    width: cell
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

    @Environment(\.monitorPaused) private var paused
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        let fraction = (reading.shownValue ?? 0) / 100
        let color = Palette.cluster(core.cluster)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(core.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
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
                .fill(.fill.quaternary)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(paused ? 0 : 0.14 * max(0, fraction - 0.4) / 0.6))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(core.label)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        var parts = [reading.shownValue.map(Format.spokenPercent) ?? ReadingText.placeholderHelp(reading)]
        if let temperature, let value = temperature.shownValue {
            parts.append(Format.spokenTemperature(value, unit: unit))
        }
        return parts.joined(separator: ", ")
    }
}

private struct CoreMappingExplanation: View {
    @Environment(\.coreSensorKeys) private var keys

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Core Temperatures")
                .font(.headline)
            Text("Each core shows the sensor matched to it by a community-maintained table. Apple doesn't publish this mapping, so a value describes the area near a core rather than the core itself.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(stride(from: 0, to: CoreID.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + 3, CoreID.count), id: \.self) { index in
                            let core = CoreID(flatIndex: index)
                            HStack(spacing: 4) {
                                Text(core.label).foregroundStyle(.secondary)
                                Text(index < keys.count ? keys[index] ?? "—" : "—").monospaced()
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
            }
            Text("The CPU temperature at the top of the page uses the source chosen in Settings and isn't affected by this mapping.")
                .font(.pmCaption)
                .foregroundStyle(.secondary)
        }
    }
}
