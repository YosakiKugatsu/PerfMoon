// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Accessibility
import PerfMoonKit
import SwiftUI

// MARK: - Shared chart definitions

struct ChartSeries: Identifiable {
    enum Style {
        case line
        case area
        case lineAndArea
    }

    let key: SeriesKey
    let name: String
    let color: Color
    var style: Style = .line
    /// Distinct line patterns identify CPU tiers without relying on color.
    var dash: [CGFloat] = []

    var id: String { key.rawValue }
}

extension CPUSnapshot {
    var usageChartSeries: [ChartSeries] {
        [ChartSeries(key: .cpuTotal, name: "Total", color: Palette.cpu, style: .area)] + topology.clusters.map { cluster in
            ChartSeries(key: cluster.role.usageSeries, name: cluster.title, color: Palette.cluster(cluster.role),
                        dash: cluster.role.usageDash)
        }
    }
}

extension CoreCluster {
    var usageSeries: SeriesKey {
        switch self {
        case .e: .cpuE
        case .s: .cpuS
        case .p: .cpuP
        }
    }

    var frequencySeries: SeriesKey {
        switch self {
        case .e: .cpuFrequencyE
        case .s: .cpuFrequencyS
        case .p: .cpuFrequencyP
        }
    }

    var usageDash: [CGFloat] {
        switch self {
        case .e: [1, 4]
        case .s: []
        case .p: [4, 3]
        }
    }
}

enum ChartScale {
    case percent
    case watts(minimumMax: Double)
    case corePower
    case temperature
    case bytes(maximum: Double)
    case throughput, operations
}

private func niceCeiling(_ value: Double) -> Double {
    guard value > 0 else { return 1 }
    let exponent = pow(10, floor(log10(value)))
    let fraction = value / exponent
    let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
    return nice * exponent
}

// MARK: - History chart

/// Immediate-mode drawing keeps each chart to one rendering node. The visual contract
/// remains unchanged: monotone curves, gradient fills, trailing axes, and real gaps.
struct HistoryChart: View {
    let series: [ChartSeries]
    let scale: ChartScale
    let range: TimeRange
    let end: TimeInterval
    let revision: Int
    var compact = false
    let accessibilityName: String
    var unavailableReason: UnavailableReason? = nil

    @Environment(\.historyStore) private var history
    @Environment(\.temperatureUnit) private var unit
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPaused) private var paused

    var body: some View {
        let start = end - range.seconds
        let plotted = series.map { history?.points($0.key, start: start, end: end) ?? [] }
        let domain = yDomain(plotted.flatMap { $0 })
        let empty = plotted.allSatisfy(\.isEmpty)
        let emptyMessage = unavailableReason?.message ?? "No data yet"
        Canvas { context, size in
            let rect = CGRect(x: 0, y: compact ? 1 : 5,
                              width: max(1, size.width - (compact ? 0 : 57)),
                              height: max(1, size.height - (compact ? 2 : 25)))
            drawAxes(context: context, rect: rect, domain: domain)
            var plot = context
            plot.clip(to: Path(rect))
            for index in series.indices {
                let definition = series[index]
                // Separate paths preserve source changes, pauses, and missing samples.
                for segment in chartSegments(plotted[index]) {
                    let points = segment.map { point in
                        CGPoint(x: rect.minX + (point.time - start) / range.seconds * rect.width,
                                y: rect.maxY - (point.value - domain.lowerBound) / (domain.upperBound - domain.lowerBound) * rect.height)
                    }
                    guard let first = points.first, let last = points.last else { continue }
                    if points.count == 1 {
                        plot.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)), with: .color(definition.color))
                        continue
                    }
                    let line = monotonePath(points)
                    if definition.style != .line {
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                        area.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                        area.closeSubpath()
                        plot.fill(area, with: .linearGradient(
                            Gradient(colors: [definition.color.opacity(definition.style == .area ? 0.16 : 0.22), definition.color.opacity(0.02)]),
                            startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                    }
                    if definition.style != .area {
                        plot.stroke(line, with: .color(definition.color), style: StrokeStyle(
                            lineWidth: contrast == .increased ? 2 : 1.5, lineCap: .round, lineJoin: .round,
                            dash: definition.dash))
                    }
                }
            }
        }
        .opacity(paused ? 0.7 : 1)
        .overlay {
            if empty {
                Text(emptyMessage)
                    .font(.pmCaption)
                    .foregroundStyle(unavailableReason == nil ? .tertiary : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityLabel("\(accessibilityName), last \(range.spokenTitle)")
        .accessibilityValue(empty ? emptyMessage : "")
        .accessibilityChartDescriptor(HistoryAccessibility(
            title: accessibilityName, series: series.map(\.name), points: plotted,
            start: start, end: end, domain: domain, valueDescription: yLabel))
    }

    private func drawAxes(context: GraphicsContext, rect: CGRect, domain: ClosedRange<Double>) {
        var grid = Path()
        let candidates: [Int] = switch range {
        case .oneMinute, .oneHour: [4, 2, 1]
        case .fiveMinutes: [5, 1]
        case .fifteenMinutes: [3, 1]
        case .sixHours: [6, 3, 2, 1]
        }
        let divisions = candidates.first { rect.width >= CGFloat($0) * 40 } ?? 1
        for index in 0...divisions {
            let fraction = Double(index) / Double(divisions)
            let x = rect.minX + fraction * rect.width
            grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            if !compact {
                let seconds = (divisions - index) * range.rawValue / divisions
                let label: String
                if seconds == 0 { label = "Now" }
                else if seconds.isMultiple(of: 3600) { label = "\(Format.minus)\(seconds / 3600)h" }
                else if seconds.isMultiple(of: 60) { label = "\(Format.minus)\(seconds / 60)m" }
                else { label = "\(Format.minus)\(seconds)s" }
                context.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary),
                             at: CGPoint(x: x, y: rect.maxY + 7),
                             anchor: index == 0 ? .topLeading : index == divisions ? .topTrailing : .top)
            }
        }
        for fraction in [0.0, 0.5, 1.0] {
            let y = rect.maxY - fraction * rect.height
            grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            if !compact {
                let value = domain.lowerBound + fraction * (domain.upperBound - domain.lowerBound)
                context.draw(Text(yLabel(value)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary),
                             at: CGPoint(x: rect.maxX + 7, y: y), anchor: .leading)
            }
        }
        context.stroke(grid, with: .style(.quaternary), lineWidth: 0.5)
    }

    private func yDomain(_ points: [ChartPoint]) -> ClosedRange<Double> {
        switch scale {
        case .percent: return 0...100
        case .corePower: return 0...niceCeiling(max(0.01, (points.lazy.map(\.value).max() ?? 0) * 1.08))
        case .watts(let minimumMax):
            return 0...niceCeiling(max(minimumMax, (points.map(\.value).max() ?? 0) * 1.12))
        case .bytes(let maximum): return 0...maximum
        case .throughput, .operations: return 0...niceCeiling(max(1, (points.map(\.value).max() ?? 0) * 1.08))
        case .temperature:
            let values = points.map(\.value)
            guard let low = values.min(), let high = values.max() else { return 20...60 }
            let lower = ((low - 4) / 10).rounded(.down) * 10
            let upper = max(lower + 20, ((high + 4) / 10).rounded(.up) * 10)
            return lower...upper
        }
    }

    private func yLabel(_ value: Double) -> String {
        switch scale {
        case .percent: return Format.percent(value)
        case .corePower: return Format.coreWatts(value, compact: false)
        case .watts: return value.rounded() == value ? "\(Int(value)) W" : String(format: "%.1f W", value)
        case .bytes: return Format.wholeGigabytes(value)
        case .throughput: return Format.transferRate(value)
        case .operations: return Format.rate(value)
        case .temperature: return Format.temperature(value, unit: unit)
        }
    }
}

private func chartSegments(_ points: [ChartPoint]) -> [[ChartPoint]] {
    var result: [[ChartPoint]] = []
    var previous: Int?
    for point in points {
        if previous != point.segment { result.append([]); previous = point.segment }
        result[result.count - 1].append(point)
    }
    return result
}

/// Shape-preserving cubic interpolation. Tangents flatten at extrema; the limiter
/// prevents overshoot, so a chart cannot invent peaks outside its samples.
private func monotonePath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 1 else { return path }
    let slopes = zip(points, points.dropFirst()).map { a, b in
        b.x > a.x ? (b.y - a.y) / (b.x - a.x) : 0
    }
    var tangent = [CGFloat](repeating: 0, count: points.count)
    tangent[0] = slopes[0]; tangent[points.count - 1] = slopes.last!
    if points.count > 2 {
        for i in 1..<(points.count - 1) {
            if slopes[i - 1] * slopes[i] > 0 { tangent[i] = (slopes[i - 1] + slopes[i]) / 2 }
        }
    }
    for i in slopes.indices {
        if slopes[i] == 0 { tangent[i] = 0; tangent[i + 1] = 0; continue }
        let a = tangent[i] / slopes[i], b = tangent[i + 1] / slopes[i]
        let radius = a * a + b * b
        if radius > 9 {
            let factor = 3 / sqrt(radius)
            tangent[i] = factor * a * slopes[i]; tangent[i + 1] = factor * b * slopes[i]
        }
    }
    for i in slopes.indices {
        let a = points[i], b = points[i + 1], step = (b.x - a.x) / 3
        path.addCurve(to: b, control1: CGPoint(x: a.x + step, y: a.y + step * tangent[i]),
                      control2: CGPoint(x: b.x - step, y: b.y - step * tangent[i + 1]))
    }
    return path
}

/// Canvas keeps the same VoiceOver audio-graph support without a retained mark tree.
private struct HistoryAccessibility: AXChartDescriptorRepresentable {
    let title: String
    let series: [String]
    let points: [[ChartPoint]]
    let start: Double
    let end: Double
    let domain: ClosedRange<Double>
    let valueDescription: (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(title: title, summary: "Missing samples are shown as gaps.",
            xAxis: AXNumericDataAxisDescriptor(title: "Time", range: start...end, gridlinePositions: []) { value in
                "\(Int(max(0, end - value))) seconds ago"
            },
            yAxis: AXNumericDataAxisDescriptor(title: title, range: domain, gridlinePositions: [], valueDescriptionProvider: valueDescription),
            series: descriptors())
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let next = makeChartDescriptor()
        descriptor.xAxis = next.xAxis; descriptor.yAxis = next.yAxis; descriptor.series = next.series
    }

    private func descriptors() -> [AXDataSeriesDescriptor] {
        points.indices.flatMap { index in
            chartSegments(points[index]).map { segment in
                AXDataSeriesDescriptor(name: series[index], isContinuous: segment.count > 1,
                    dataPoints: segment.map { AXDataPoint(x: $0.time, y: $0.value) })
            }
        }
    }
}

// MARK: - Discrete levels

/// Memory pressure or charge state as colored runs. Never interpolated.
struct LevelChart: View {
    enum Kind {
        case pressure
        case charge

        func color(_ level: Int) -> Color {
            switch self {
            case .pressure: Palette.pressure(MemoryPressureLevel(rawValue: level) ?? .normal)
            case .charge: Palette.charge(BatteryChargeState(rawValue: level) ?? .notCharging)
            }
        }

        func title(_ level: Int) -> String {
            switch self {
            case .pressure: (MemoryPressureLevel(rawValue: level) ?? .normal).title
            case .charge: (BatteryChargeState(rawValue: level) ?? .notCharging).title
            }
        }
    }

    let key: SeriesKey
    let kind: Kind
    let range: TimeRange
    let end: TimeInterval
    let revision: Int

    @Environment(\.historyStore) private var history

    var body: some View {
        let start = end - range.seconds
        let runs = history?.runs(key, start: start, end: end) ?? []
        Canvas { context, size in
            let rect = CGRect(x: 0, y: 5, width: max(1, size.width - 63), height: max(1, size.height - 10))
            var grid = Path()
            for level in 1...3 {
                let y = rect.maxY - Double(level) / 3 * rect.height
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.draw(Text(kind.title(level - 1)).font(.system(size: 10)).foregroundStyle(.tertiary),
                             at: CGPoint(x: rect.maxX + 7, y: y), anchor: .leading)
            }
            context.stroke(grid, with: .style(.quaternary), lineWidth: 0.5)
            var plot = context
            plot.clip(to: Path(rect))
            for run in runs {
                let x0 = (max(start, run.start) - start) / range.seconds * rect.width
                let x1 = (min(end, run.end) - start) / range.seconds * rect.width
                let height = Double(run.level + 1) / 3 * rect.height
                guard x1 > x0 else { continue }
                plot.fill(Path(CGRect(x: x0, y: rect.maxY - height, width: x1 - x0, height: height)),
                          with: .color(kind.color(run.level).opacity(0.75)))
            }
        }
        .overlay {
            if runs.isEmpty {
                Text("No data yet").font(.pmCaption).foregroundStyle(.tertiary)
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityLabel(kind == .pressure ? "Memory pressure history" : "Charge state history")
    }
}

/// A thin strip of level runs under a compact chart.
struct LevelStrip: View {
    let key: SeriesKey
    let kind: LevelChart.Kind
    let range: TimeRange
    let end: TimeInterval
    let revision: Int

    @Environment(\.historyStore) private var history

    var body: some View {
        let start = end - range.seconds
        let runs = history?.runs(key, start: start, end: end) ?? []
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2), with: .style(.fill.quaternary))
            let span = max(1, end - start)
            for run in runs {
                let x0 = max(0, (run.start - start) / span) * size.width
                let x1 = min(1, (run.end - start) / span) * size.width
                guard x1 > x0 else { continue }
                let rect = CGRect(x: x0, y: 0, width: max(1.5, x1 - x0), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(size.height / 2, rect.width / 2)), with: .color(kind.color(run.level).opacity(0.85)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Sparkline

/// 60-second sparkline drawn with Canvas. Breaks are respected.
struct Sparkline: View {
    let key: SeriesKey
    let color: Color
    let end: TimeInterval
    let revision: Int
    var span: TimeInterval = 60
    var domain: ClosedRange<Double>? = 0...100
    var zeroBased = false
    /// Samples the caller already read for this key and span; read here when nil.
    var samples: [HistorySample]?

    @Environment(\.historyStore) private var history
    @Environment(\.monitorPaused) private var paused

    var body: some View {
        let start = end - span
        let samples = self.samples ?? history?.samples(key, since: start) ?? []
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let values = samples.map { Double($0.value) }
            let lower = domain?.lowerBound ?? (zeroBased ? 0 : (values.min() ?? 0) - 4)
            var upper = domain?.upperBound ?? (zeroBased ? max(1, (values.max() ?? 1) * 1.12) : (values.max() ?? 1) + 4)
            if upper <= lower { upper = lower + 1 }
            func point(_ sample: HistorySample) -> CGPoint {
                let x = (sample.time - start) / span * size.width
                let y = (1 - (Double(sample.value) - lower) / (upper - lower)) * (size.height - 2) + 1
                return CGPoint(x: x, y: y)
            }
            var segments: [[CGPoint]] = []
            for (index, sample) in samples.enumerated() {
                if index == 0 || sample.startsSegment { segments.append([]) }
                segments[segments.count - 1].append(point(sample))
            }
            let tint = paused ? color.opacity(0.45) : color
            for segment in segments {
                guard let first = segment.first, let last = segment.last else { continue }
                if segment.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 1.25, y: first.y - 1.25, width: 2.5, height: 2.5)), with: .color(tint))
                    continue
                }
                var line = Path()
                line.addLines(segment)
                var fill = line
                fill.addLine(to: CGPoint(x: last.x, y: size.height))
                fill.addLine(to: CGPoint(x: first.x, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.24), tint.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
