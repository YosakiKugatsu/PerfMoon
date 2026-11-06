import PerfMoonKit
import SwiftUI

/// Renders one MetricReading with the shared state rules:
/// valid → value; stale → value at 45%; warming → "—" tertiary; unavailable → "—" with the reason.
struct ReadingText: View {
    enum Emphasis {
        case primary
        case secondary
        case tertiary
    }

    let reading: MetricReading
    let format: (Double) -> String
    var font: Font = .pmBodyNumber
    var emphasis: Emphasis = .primary
    /// Spoken form for VoiceOver; defaults to the visible text.
    var spoken: ((Double) -> String)?

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        if let value = reading.shownValue {
            Text(format(value))
                .font(font)
                .foregroundStyle(style)
                .opacity(reading.isStale ? 0.45 : 1)
                .helpIfPresent(reading.isStale ? ReadingText.staleHelp(reading) : nil)
                .accessibilityLabel(spoken?(value) ?? format(value))
                .accessibilityValue(reading.isStale ? "Stale" : "")
        } else {
            Text(Format.placeholder)
                .font(font)
                .foregroundStyle(.tertiary)
                .help(ReadingText.placeholderHelp(reading))
                .accessibilityLabel(ReadingText.placeholderHelp(reading))
        }
    }

    private var style: HierarchicalShapeStyle {
        switch emphasis {
        case .tertiary: .tertiary
        case .secondary: .secondary
        case .primary: paused ? .secondary : .primary
        }
    }

    static func placeholderHelp(_ reading: MetricReading) -> String {
        if let reason = reading.unavailableReason { return reason.message }
        return ReadingStatus.warmingMessage
    }

    /// VoiceOver text for a reading shown inside a combined control.
    static func spoken(_ reading: MetricReading, _ format: (Double) -> String) -> String {
        guard let value = reading.shownValue else { return placeholderHelp(reading) }
        return format(value) + (reading.isStale ? ", stale" : "")
    }

    static func staleHelp(_ reading: MetricReading) -> String {
        guard let timestamp = reading.timestamp else { return "Stale" }
        return "Last updated \(Format.clockTime(timestamp))"
    }
}

/// A short explanation under a placeholder, used where the main window has room.
struct ReasonCaption: View {
    let reading: MetricReading

    var body: some View {
        if let reason = reading.unavailableReason {
            Text(reason.message)
                .font(.pmCaption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Typed helpers so call sites stay short and consistent.
extension ReadingText {
    static func percent(_ reading: MetricReading, font: Font = .pmBodyNumber, emphasis: Emphasis = .primary) -> ReadingText {
        ReadingText(reading: reading, format: Format.percent, font: font, emphasis: emphasis, spoken: Format.spokenPercent)
    }

    static func watts(_ reading: MetricReading, font: Font = .pmBodyNumber, emphasis: Emphasis = .primary) -> ReadingText {
        ReadingText(reading: reading, format: Format.watts, font: font, emphasis: emphasis, spoken: Format.spokenWatts)
    }

    static func bytes(_ reading: MetricReading, font: Font = .pmBodyNumber, emphasis: Emphasis = .primary) -> ReadingText {
        ReadingText(reading: reading, format: Format.bytes, font: font, emphasis: emphasis, spoken: Format.spokenBytes)
    }

    static func rate(_ reading: MetricReading, font: Font = .pmBodyNumber) -> ReadingText {
        ReadingText(reading: reading, format: Format.rate, font: font, spoken: Format.spokenRate)
    }

    static func frequency(_ reading: MetricReading, prefix: String = "", font: Font = .pmCaptionNumber, emphasis: Emphasis = .secondary) -> ReadingText {
        ReadingText(
            reading: reading,
            format: { prefix + Format.frequency($0) },
            font: font,
            emphasis: emphasis,
            spoken: { "frequency " + Format.spokenFrequency($0) }
        )
    }
}

/// Temperature with the current unit from the environment.
struct TemperatureText: View {
    let reading: MetricReading
    var prefix: String = ""
    var font: Font = .pmCaptionNumber
    var emphasis: ReadingText.Emphasis = .secondary
    var compact = false

    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        ReadingText(
            reading: reading,
            format: { value in
                let text = compact ? Format.temperatureCompact(value, unit: unit) : Format.temperature(value, unit: unit)
                return prefix.isEmpty ? text : "\(prefix) \(text)"
            },
            font: font,
            emphasis: emphasis,
            spoken: { value in
                let text = Format.spokenTemperature(value, unit: unit)
                return prefix.isEmpty ? text : "\(prefix) \(text)"
            }
        )
    }
}

/// Direction comes from the battery state, not the sign/offset of the power sensor.
/// External power with an idle battery remains unsigned.
struct BatteryPowerText: View {
    let power: PowerSnapshot
    var font: Font = .pmBodyNumber

    var body: some View {
        ReadingText(reading: power.battery, format: { prefix + Format.watts(abs($0)) }, font: font,
                    spoken: { value in
                        let state = power.chargeState
                        let direction = state == .charging ? "Charging at " : state == .discharging ? "Discharging at " : ""
                        return direction + Format.spokenWatts(abs(value))
                    })
    }

    private var prefix: String {
        switch power.chargeState {
        case .charging: "+"
        case .discharging: Format.minus
        case .notCharging, nil: ""
        }
    }
}

/// The default temperature has no visible prefix; its source remains in the tooltip.
struct SourceTemperatureLabel: View {
    let reading: MetricReading
    let source: TemperatureSource
    var font: Font = .pmCaptionNumber
    var emphasis: ReadingText.Emphasis = .secondary
    /// Off when a parent control supplies a tooltip that already names the source.
    var showsHelp = true
    @Environment(\.sensorNames) private var sensorNames

    var body: some View {
        HStack(spacing: 4) {
            if source != .cpuMax {
                Text(source.compactLabel)
                    .font(font)
                    .foregroundStyle(.secondary)
            }
            TemperatureText(reading: reading, font: font, emphasis: emphasis)
        }
        .helpIfPresent(showsHelp ? helpText : nil)
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        switch source {
        case .cpuMax: "Highest CPU temperature"
        case .cpuAverage: "Average CPU temperature"
        case .sensor(let id):
            if let name = sensorNames[id] { "\(name) (\(id))" } else { id }
        }
    }
}

extension EnvironmentValues {
    /// Sensor ID → display name, for tooltips on compact labels.
    @Entry var sensorNames: [String: String] = [:]
}
