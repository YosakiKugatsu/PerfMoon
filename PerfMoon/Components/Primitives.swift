import Foundation
import PerfMoonKit
import SwiftUI

/// A consistent monochrome symbol family for CPU tiers. These are identities,
/// not disclosure indicators: tapping a cluster swaps its content in place.
enum CoreTierSymbol {
    case efficiency, performance, superCore

    var name: String {
        switch self {
        case .efficiency: "leaf"
        case .performance: "gauge.with.dots.needle.50percent"
        case .superCore: "bolt.fill"
        }
    }

    static func cluster(_ cluster: CoreCluster) -> CoreTierSymbol {
        cluster == .s ? .superCore : .performance
    }
}

struct CoreTierIcon: View {
    let tier: CoreTierSymbol

    var body: some View {
        Image(systemName: tier.name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}

/// 12 pt rounded, non-glass content card.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var stretches = false
    @ViewBuilder var content: Content

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: stretches ? .infinity : nil, alignment: .topLeading)
            .background(.fill.quinary, in: .rect(cornerRadius: 12))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1)
                }
            }
    }
}

/// Uppercase section label used in the panel.
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.pmSectionTitle)
            .tracking(0.3)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Title row used by main window cards.
struct CardHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.pmCardTitle)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Horizontal meter drawn in one pass.
struct Meter: View {
    let fraction: Double?
    let color: Color
    var height: CGFloat = 6

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius), with: .style(.fill.tertiary))
            guard let fraction, fraction > 0 else { return }
            let width = max(size.height, size.width * min(1, fraction))
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: radius),
                with: .color(color.opacity(paused ? 0.45 : 1))
            )
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A label-value row with a trailing value.
struct ValueRow<Value: View>: View {
    let label: String
    var dot: Color?
    var indent = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(label)
                .foregroundStyle(.secondary)
                .padding(.leading, indent ? 12 : 0)
            Spacer(minLength: 8)
            value
        }
        .font(.pmBody)
        .accessibilityElement(children: .combine)
    }
}

struct PressureBadge: View {
    let reading: MetricReading
    var font: Font = .pmCaption

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        if let value = reading.shownValue {
            let level = MemoryPressureLevel(value: value)
            HStack(spacing: 4) {
                Image(systemName: level.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.pressure(level).opacity(paused ? 0.5 : 1))
                Text(level.title)
                    .font(font)
                    .foregroundStyle(paused ? .secondary : .primary)
            }
            .opacity(reading.isStale ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory pressure \(level.title)")
        } else {
            ReadingText(reading: reading, format: { _ in "" }, font: font)
        }
    }
}

/// What the battery is doing, combining the reported charge state with adapter presence.
/// Not charging while an adapter is connected reads as "AC Power".
enum BatteryStatus: Equatable {
    case charging
    case discharging
    case acPower
    case notCharging

    init?(power: PowerSnapshot) {
        guard let state = power.chargeState else { return nil }
        switch state {
        case .charging: self = .charging
        case .discharging: self = .discharging
        case .notCharging: self = power.hasAdapter == true ? .acPower : .notCharging
        }
    }

    var title: String {
        switch self {
        case .charging: "Charging"
        case .discharging: "Discharging"
        case .acPower: "AC Power"
        case .notCharging: "Not Charging"
        }
    }

    var color: Color {
        switch self {
        case .charging: Palette.charge(.charging)
        case .discharging: Palette.charge(.discharging)
        case .acPower, .notCharging: Palette.charge(.notCharging)
        }
    }

    var help: String {
        switch self {
        case .charging: "The battery is charging."
        case .discharging: "The battery is supplying power."
        case .acPower: "Running on the power adapter. The battery isn't charging or discharging."
        case .notCharging: "The battery isn't charging."
        }
    }
}

/// "Charging", "Discharging", "AC Power", or "Not Charging" with a small state dot.
struct BatteryStatusLabel: View {
    let power: PowerSnapshot

    var body: some View {
        let reading = power.batteryState
        if let status = BatteryStatus(power: power) {
            HStack(spacing: 4) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(status.title)
            }
            .font(.pmCaption)
            .foregroundStyle(.secondary)
            .opacity(reading.isStale || power.adapterConnected.isStale ? 0.45 : 1)
            .help(status.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.title)
            .accessibilityHint(status.help)
        } else {
            Text(Format.placeholder)
                .font(.pmCaption)
                .foregroundStyle(.tertiary)
                .help(ReadingText.placeholderHelp(reading))
                .accessibilityLabel("Battery status \(ReadingText.placeholderHelp(reading))")
        }
    }
}

/// Matches the memory badge's compact status dot and label in panel headers.
struct ThermalStatusBadge: View {
    let status: ThrottleStatus
    let device: String

    @Environment(\.monitorPaused) private var paused

    private var title: String { status.isActive ? "Throttling" : "Normal" }
    private var explanation: String {
        if !status.isAvailable { return "\(device) throttling status is not available." }
        return status.explanation.isEmpty ? "No \(device) thermal throttling detected." : status.explanation
    }

    var body: some View {
        Group {
            if status.isAvailable {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.pressure(status.isActive ? .warning : .normal).opacity(paused ? 0.5 : 1))
                    Text(title)
                        .font(.pmCaption)
                        .foregroundStyle(paused ? .secondary : .primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(device) \(title)")
                .accessibilityValue(explanation)
            } else {
                Text(Format.placeholder)
                    .font(.pmCaption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(device) throttling status unavailable")
            }
        }
        .fixedSize()
        .help(explanation)
    }
}

/// Shown only while the data layer reports active thermal throttling. Never inferred by the UI.
struct ThrottleBadge: View {
    let status: ThrottleStatus

    @Environment(\.monitorPaused) private var paused
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if status.isAvailable, status.isActive {
            Text("Throttle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.orange.opacity(paused ? 0.08 : 0.18), in: Capsule())
                .overlay {
                    if contrast == .increased {
                        Capsule().strokeBorder(Color.orange, lineWidth: 1)
                    }
                }
                .opacity(paused ? 0.6 : 1)
                .fixedSize()
                .help(explanation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Throttle")
                .accessibilityValue(explanation)
        }
    }

    private var explanation: String {
        status.explanation.isEmpty ? "macOS is limiting CPU performance." : status.explanation
    }
}

/// "S 3.0 · P 2.1 GHz": one shared unit when both values are in gigahertz, so it never truncates.
struct FrequencyPair: View {
    let s: MetricReading
    let p: MetricReading
    var font: Font = .pmBodyNumber

    var body: some View {
        let shared = (s.shownValue ?? 0) >= 1 && (p.shownValue ?? 0) >= 1
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("S").foregroundStyle(.secondary)
            ReadingText(reading: s, format: { value in
                if shared { return String(format: "%.1f", value) }
                return Format.frequency(value)
            }, font: font)
            Text("·").foregroundStyle(.tertiary).padding(.horizontal, 1)
            Text("P").foregroundStyle(.secondary)
            ReadingText(reading: p, format: { value in
                if shared { return String(format: "%.1f", value) }
                return Format.frequency(value)
            }, font: font)
            if shared {
                Text("GHz")
            }
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frequency")
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        func part(_ title: String, _ reading: MetricReading) -> String {
            "\(title) \(reading.shownValue.map(Format.spokenFrequency) ?? ReadingText.placeholderHelp(reading))"
        }
        return [part("S-Core", s), part("P-Core", p)].joined(separator: ", ")
    }
}

/// Makes a summary row expand and collapse on click, Return, or Space.
/// The system focus ring is replaced by a soft neutral highlight that appears only for
/// keyboard focus (with Keyboard Navigation on); clicking never leaves an outline.
struct DisclosureInteraction: ViewModifier {
    @Binding var isExpanded: Bool
    let label: String
    let value: String
    let hint: String
    var preservesChildren = false

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.return, .space]) { _ in
                isExpanded.toggle()
                return .handled
            }
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.fill.tertiary)
                    .padding(-5)
                    .opacity(focused ? 1 : 0)
            }
            .accessibilityElement(children: preservesChildren ? .contain : .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .accessibilityAction { isExpanded.toggle() }
    }
}

extension View {
    func disclosureInteraction(isExpanded: Binding<Bool>, label: String, value: String, hint: String, preservesChildren: Bool = false) -> some View {
        modifier(DisclosureInteraction(isExpanded: isExpanded, label: label, value: value, hint: hint, preservesChildren: preservesChildren))
    }
}

/// An ⓘ button that shows a short explanation in a popover.
struct InfoButton<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
                .font(.pmBody)
                .padding(14)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Small colored legend key.
struct LegendKey: View {
    let title: String
    let color: Color
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 2] : []))
            }
            .frame(width: 12, height: 6)
            Text(title)
        }
        .font(.pmCaption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// Vertical hairline between columns.
struct ColumnDivider: View {
    var body: some View {
        Rectangle().fill(.separator).frame(width: 1).padding(.vertical, 2)
    }
}
