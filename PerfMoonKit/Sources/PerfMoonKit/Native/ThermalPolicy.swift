import Foundation

/// A low clock or a high sensor temperature alone is not evidence of throttling.
public enum ThermalPolicy {
    public static func evaluate(thermalState: Int, cpuLimitPercent: Double?, hardwareThrottleRecent: Bool) -> ThrottleStatus {
        if thermalState >= 3 {
            return ThrottleStatus(isActive: true, explanation: "macOS reports critical thermal pressure.")
        }
        if thermalState >= 1, let limit = cpuLimitPercent, limit >= 0, limit < 100 {
            return ThrottleStatus(isActive: true, explanation: "Thermal CPU performance cap: \(Int(limit))%.")
        }
        if thermalState >= 2 && hardwareThrottleRecent {
            return ThrottleStatus(isActive: true, explanation: "CPU throttle activity and high thermal pressure.")
        }
        return .normal
    }
}
