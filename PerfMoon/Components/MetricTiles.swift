// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

// MARK: - Tiles

/// A reading that also chooses what its card's chart shows. The name stays visible in
/// every state, and the selected tile takes the chart's color, so the chart can be
/// identified without hovering. Values never move between tiles when the selection changes.
struct MetricTile<Value: View>: View {
    let title: String
    let color: Color
    let isSelected: Bool
    /// VoiceOver value, for example "23 percent".
    let spokenValue: String
    /// One line, label leading and value trailing, for secondary readings.
    var compact = false
    /// Extra tooltip text, such as which sensor a temperature comes from.
    var about: String?
    let action: () -> Void
    @ViewBuilder var value: Value

    var body: some View {
        TileButton(color: color, isSelected: isSelected, action: action) {
            Group {
                if compact {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        titleText
                        Spacer(minLength: 4)
                        value
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        titleText
                        value
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 5)
                }
            }
            .padding(.horizontal, TileLayout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help((about.map { "\($0). " } ?? "") + (isSelected ? "Shown in the chart below." : "Click to show it in the chart below."))
        // Set on the button itself so VoiceOver keeps its press action.
        .accessibilityLabel(about.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(spokenValue)
        .accessibilityHint(isSelected ? "Shown in the chart" : "Shows its last 60 seconds in the chart")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var titleText: some View {
        Text(title)
            .font(.pmCaption.weight(isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .lineLimit(1)
    }
}

enum TileLayout {
    /// Text inset inside a tile. Rows extend by the same amount into the card padding.
    static let inset: CGFloat = 8
}

/// A row of tiles whose highlight extends into the card padding, so the tile text
/// lines up with the section title above it.
struct TileRow<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
        }
        .padding(.horizontal, -TileLayout.inset)
    }
}

/// A quiet button: no chrome at rest, a light fill on hover, and the chart color while
/// selected. Keyboard focus (Keyboard Navigation on) shows a soft outline rather than the
/// system ring; clicking never leaves an outline.
struct TileButton<Label: View>: View {
    let color: Color
    let isSelected: Bool
    let cornerRadius: CGFloat
    let action: () -> Void
    let label: Label

    @State private var hovering = false
    @FocusState private var focused: Bool

    init(color: Color, isSelected: Bool, cornerRadius: CGFloat = 8, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.color = color
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(TileButtonStyle(color: color, isSelected: isSelected, isHovered: hovering,
                                         isFocused: focused, cornerRadius: cornerRadius))
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovering = $0 }
    }
}

private struct TileButtonStyle: ButtonStyle {
    let color: Color
    let isSelected: Bool
    let isHovered: Bool
    let isFocused: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        TileChrome(color: color, isSelected: isSelected, isHovered: isHovered, isPressed: configuration.isPressed,
                   isFocused: isFocused, cornerRadius: cornerRadius) {
            configuration.label
        }
    }
}

private struct TileChrome<Content: View>: View {
    let color: Color
    let isSelected: Bool
    let isHovered: Bool
    let isPressed: Bool
    let isFocused: Bool
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPaused) private var paused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .contentShape(shape)
            .background {
                if isSelected {
                    shape.fill(color.opacity((paused ? 0.09 : 0.16) + (isPressed ? 0.08 : 0)))
                } else if isPressed {
                    shape.fill(.fill.tertiary)
                } else if isHovered {
                    shape.fill(.fill.quaternary)
                }
            }
            .overlay {
                if isFocused {
                    shape.strokeBorder(.secondary, lineWidth: 1)
                } else if isSelected, contrast == .increased {
                    shape.strokeBorder(color, lineWidth: 1)
                }
            }
    }
}

// MARK: - Labeled sparkline

/// Units for a panel sparkline. Its printed bounds and spoken range use these units.
enum SparklineScale {
    case percent
    case watts
    case gigahertz
    case temperature
    /// Memory in bytes, within 0 and the installed total.
    case bytes(total: Double)

    /// Round bounds that contain every sample. Percent always spans 0–100%; power and
    /// frequency start at zero; temperature follows the samples in the display unit;
    /// memory follows the samples in whole gigabytes, at least 2 GB tall so small
    /// changes aren't magnified.
    func domain(_ values: [Double], unit: TemperatureUnit) -> ClosedRange<Double>? {
        switch self {
        case .bytes(let total):
            guard let low = values.min(), let high = values.max() else { return nil }
            let step = Format.gibibyte
            var lower = max(0, ((low - step / 2) / step).rounded(.down) * step)
            var upper = max(lower + 2 * step, ((high + step / 2) / step).rounded(.up) * step)
            if total > 0, upper > total {
                upper = max(total, high)
                lower = min(lower, max(0, upper - 2 * step))
            }
            return lower...upper
        case .percent:
            return 0...100
        case .watts:
            guard let high = values.max() else { return nil }
            return 0...Self.wattsCeiling(high * 1.1)
        case .gigahertz:
            guard let high = values.max() else { return nil }
            return 0...max(0.5, (high * 1.05 / 0.5).rounded(.up) * 0.5)
        case .temperature:
            guard let low = values.min(), let high = values.max() else { return nil }
            let lower = ((Self.display(low, unit) - 1) / 5).rounded(.down) * 5
            let upper = max(lower + 10, ((Self.display(high, unit) + 1) / 5).rounded(.up) * 5)
            return Self.celsius(lower, unit)...Self.celsius(upper, unit)
        }
    }

    func label(_ value: Double, unit: TemperatureUnit) -> String {
        switch self {
        case .percent: Format.percent(value)
        case .watts: "\(Int(value.rounded())) W"
        case .gigahertz: value == 0 ? "0 GHz" : String(format: "%.1f GHz", value)
        case .temperature: Format.temperatureCompact(value, unit: unit)
        case .bytes: Format.wholeGigabytes(value)
        }
    }

    func spoken(_ value: Double, unit: TemperatureUnit) -> String {
        switch self {
        case .percent: Format.spokenPercent(value)
        case .watts: Format.spokenWatts(value)
        case .gigahertz: Format.spokenFrequency(value)
        case .temperature: Format.spokenTemperature(value, unit: unit)
        case .bytes: Format.spokenBytes(value)
        }
    }

    private static func wattsCeiling(_ value: Double) -> Double {
        for step in [1.0, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 150, 200] where value <= step {
            return step
        }
        return (value / 50).rounded(.up) * 50
    }

    private static func display(_ celsius: Double, _ unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    private static func celsius(_ display: Double, _ unit: TemperatureUnit) -> Double {
        unit == .celsius ? display : (display - 32) * 5 / 9
    }
}

/// The last 60 seconds of one series with its scale printed beside it, like the trailing
/// axis of the window charts. Reads the shared history; keeps no samples of its own.
struct PanelSparkline: View {
    static let span: TimeInterval = 60

    let key: SeriesKey
    /// Tooltip and VoiceOver name, for example "CPU usage".
    let title: String
    let color: Color
    let scale: SparklineScale
    let end: TimeInterval
    let revision: Int
    var showsScale = true
    var unavailableReason: UnavailableReason? = nil

    @Environment(\.historyStore) private var history
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        // One read serves both the printed scale and the line.
        let samples = history?.samples(key, since: end - Self.span) ?? []
        let values = samples.map { Double($0.value) }
        let domain = scale.domain(values, unit: unit)
        HStack(spacing: 6) {
            Sparkline(key: key, color: color, end: end, revision: revision, span: Self.span,
                      domain: domain ?? 0...1, samples: samples)
                .overlay {
                    if values.isEmpty {
                        Text(unavailableReason?.message ?? "No data yet")
                            .font(.pmCaption)
                            .foregroundStyle(unavailableReason == nil ? .tertiary : .secondary)
                    }
                }
            if showsScale {
                VStack(alignment: .leading, spacing: 0) {
                    Text(domain.map { scale.label($0.upperBound, unit: unit) } ?? " ")
                    Spacer(minLength: 0)
                    Text(domain.map { scale.label($0.lowerBound, unit: unit) } ?? " ")
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)
            }
        }
        .help("\(title), last 60 seconds")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), last 60 seconds")
        .accessibilityValue(spokenRange(values))
    }

    private func spokenRange(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max() else { return unavailableReason?.message ?? "No data yet" }
        return "Low \(scale.spoken(low, unit: unit)), high \(scale.spoken(high, unit: unit))"
    }
}
