import Foundation

/// Fixed English formatting with `.` decimals, independent of the system region,
/// so widths are predictable. Menu bar strings never exceed four characters.
public enum Format {
    public static let minus = "\u{2212}"
    public static let placeholder = "—"

    // MARK: Percent

    public static func percent(_ value: Double) -> String {
        if value > 0, value < 0.5 { return "<1%" }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }

    /// One decimal, used for PerfMoon's own CPU share.
    public static func precisePercent(_ value: Double) -> String {
        String(format: "%.1f%%", locale: posix, max(0, value))
    }

    // MARK: Power

    public static func watts(_ value: Double) -> String {
        let value = max(0, value)
        if value < 99.95 { return String(format: "%.1f W", locale: posix, value) }
        return "\(Int(value.rounded())) W"
    }

    public static func wattsCompact(_ value: Double) -> String {
        let value = max(0, value)
        if value < 9.95 { return String(format: "%.1fW", locale: posix, value) }
        return "\(min(999, Int(value.rounded())))W"
    }

    // MARK: Temperature

    public static func temperatureValue(_ celsius: Double, unit: TemperatureUnit) -> Int {
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        let rounded = Int(value.rounded())
        return rounded == 0 ? 0 : rounded
    }

    public static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        "\(signed(temperatureValue(celsius, unit: unit))) \(unit == .celsius ? "°C" : "°F")"
    }

    /// Menu bar: "72°", "−20°", "100°".
    public static func temperatureCompact(_ celsius: Double, unit: TemperatureUnit) -> String {
        let value = max(-99, min(999, temperatureValue(celsius, unit: unit)))
        return "\(signed(value))°"
    }

    private static func signed(_ value: Int) -> String {
        value < 0 ? minus + String(-value) : String(value)
    }

    // MARK: Frequency

    public static func frequency(_ gigahertz: Double) -> String {
        if gigahertz < 1 { return "\(Int((gigahertz * 1000).rounded())) MHz" }
        return String(format: "%.1f GHz", locale: posix, gigahertz)
    }

    // MARK: Memory

    public static let gibibyte = 1024.0 * 1024 * 1024
    public static let mebibyte = 1024.0 * 1024

    public static func bytes(_ value: Double) -> String {
        if value >= gibibyte * 0.995 {
            return String(format: "%.1f GB", locale: posix, value / gibibyte)
        }
        return "\(Int((max(0, value) / mebibyte).rounded())) MB"
    }

    /// Whole gigabytes, e.g. "64 GB" for physical memory.
    public static func wholeGigabytes(_ value: Double) -> String {
        "\(Int((value / gibibyte).rounded())) GB"
    }

    /// Menu bar: "41G", "9.8G", "512M".
    public static func bytesCompact(_ value: Double) -> String {
        let gigabytes = max(0, value) / gibibyte
        if gigabytes >= 9.95 { return "\(min(999, Int(gigabytes.rounded())))G" }
        if gigabytes >= 0.995 { return String(format: "%.1fG", locale: posix, gigabytes) }
        let megabytes = Int((max(0, value) / mebibyte).rounded())
        return megabytes < 1000 ? "\(megabytes)M" : "1.0G"
    }

    // MARK: Rates

    public static func rate(_ value: Double) -> String {
        let value = max(0, value)
        if value < 999.5 { return "\(Int(value.rounded()))/s" }
        if value < 9_950 { return String(format: "%.1fK/s", locale: posix, value / 1000) }
        return "\(Int((value / 1000).rounded()))K/s"
    }

    // MARK: Time

    public static func clockTime(_ time: TimeInterval) -> String {
        clockFormatter.string(from: Date(timeIntervalSinceReferenceDate: time))
    }

    public static func interval(_ seconds: TimeInterval) -> String {
        "\(Int(seconds.rounded())) s"
    }

    // MARK: Spoken forms for VoiceOver

    public static func spokenPercent(_ value: Double) -> String {
        if value > 0, value < 0.5 { return "less than 1 percent" }
        return "\(Int(min(100, max(0, value)).rounded())) percent"
    }

    public static func spokenWatts(_ value: Double) -> String {
        "\(watts(value).replacingOccurrences(of: " W", with: "")) watts"
    }

    public static func spokenTemperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        let value = temperatureValue(celsius, unit: unit)
        let scale = unit == .celsius ? "degrees Celsius" : "degrees Fahrenheit"
        return value < 0 ? "minus \(-value) \(scale)" : "\(value) \(scale)"
    }

    public static func spokenFrequency(_ gigahertz: Double) -> String {
        if gigahertz < 1 { return "\(Int((gigahertz * 1000).rounded())) megahertz" }
        return String(format: "%.1f gigahertz", locale: posix, gigahertz)
    }

    public static func spokenBytes(_ value: Double) -> String {
        bytes(value).replacingOccurrences(of: " GB", with: " gigabytes").replacingOccurrences(of: " MB", with: " megabytes")
    }

    public static func spokenRate(_ value: Double) -> String {
        "\(Int(max(0, value).rounded())) per second"
    }

    // MARK: Private

    private static let posix = Locale(identifier: "en_US_POSIX")

    // DateFormatter is thread-safe for formatting on supported macOS versions.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
