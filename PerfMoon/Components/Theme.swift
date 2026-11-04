import PerfMoonKit
import SwiftUI

/// Semantic colors only; no hard-coded hex values.
enum Palette {
    static let cpu = Color.blue
    static let sCore = Color.blue
    static let pCore = Color.blue.opacity(0.55)
    static let gpu = Color.teal
    static let ane = Color.purple
    static let power = Color.orange
    static let temperature = Color.pink
    /// Memory stays neutral so pressure color carries the meaning.
    static let memory = Color.primary.opacity(0.62)

    static func cluster(_ cluster: CoreCluster) -> Color {
        cluster == .s ? sCore : pCore
    }

    static func pressure(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    static func charge(_ state: BatteryChargeState) -> Color {
        switch state {
        case .charging: .green
        case .discharging: .orange
        case .notCharging: .gray
        }
    }
}

extension MemoryPressureLevel {
    /// Shape plus text, so the level never depends on color alone.
    var symbol: String {
        switch self {
        case .normal: "circle.fill"
        case .warning: "triangle.fill"
        case .critical: "square.fill"
        }
    }
}

extension Font {
    /// Panel headline numbers.
    static let pmHeadline = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    /// Main window card numbers.
    static let pmCardNumber = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    static let pmStatNumber = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    static let pmTileNumber = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let pmSectionTitle = Font.system(size: 11, weight: .semibold)
    static let pmCardTitle = Font.system(size: 13, weight: .semibold)
    static let pmBody = Font.system(size: 13)
    static let pmBodyNumber = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let pmCaption = Font.system(size: 11)
    static let pmCaptionNumber = Font.system(size: 11).monospacedDigit()
}

extension EnvironmentValues {
    /// True while the user has paused monitoring; values are shown dimmed.
    @Entry var monitorPaused = false
    @Entry var temperatureUnit: TemperatureUnit = .celsius
    @Entry var historyStore: HistoryStore? = nil
    /// Mapped sensor key per core, S0–S5 then P0–P11; nil when a core has no mapped sensor.
    @Entry var coreSensorKeys: [String?] = []
    /// True when readings come from this Mac rather than preview fixtures.
    /// Injected at the root; controls the "Simulated Data" wording only.
    @Entry var isLiveData = false
}

extension View {
    /// Adds a tooltip only when there is something to say.
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}
