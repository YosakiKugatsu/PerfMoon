// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Debug and preview scenarios. Each one is a reproducible, seeded state for UI review.
public enum FixtureScenario: String, CaseIterable, Identifiable, Sendable {
    case typical
    case idle
    case heavyLoad
    case thermalThrottle
    case singleCoreSaturated
    case memoryWarning
    case memoryCritical
    case charging
    case discharging
    case notCharging
    case noAdapter
    case threeDigitPower
    case missingData
    case missingHistory
    case longestReason
    case sensorFailed
    case nonCPUSensor
    case longSensorName
    case negativeTemperature
    case retrySuccess
    case retryFailure
    case paused
    case wakeRecovery
    case pauseSleepWake
    case intervalChanges

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case load = "Load"
        case memory = "Memory"
        case power = "Power"
        case dataQuality = "Data Quality"
        case layout = "Layout Stress"
        case recovery = "Recovery"
        case runState = "Run State"

        public var id: String { rawValue }

        public var scenarios: [FixtureScenario] {
            FixtureScenario.allCases.filter { $0.group == self }
        }
    }

    public var group: Group {
        switch self {
        case .typical, .idle, .heavyLoad, .thermalThrottle, .singleCoreSaturated: .load
        case .memoryWarning, .memoryCritical: .memory
        case .charging, .discharging, .notCharging, .noAdapter, .threeDigitPower: .power
        case .missingData, .missingHistory, .sensorFailed, .nonCPUSensor: .dataQuality
        case .longestReason, .longSensorName, .negativeTemperature: .layout
        case .retrySuccess, .retryFailure: .recovery
        case .paused, .wakeRecovery, .pauseSleepWake, .intervalChanges: .runState
        }
    }

    public var title: String {
        switch self {
        case .typical: "Typical"
        case .idle: "Idle"
        case .heavyLoad: "Heavy Load"
        case .thermalThrottle: "Thermal Throttle"
        case .singleCoreSaturated: "One S-Core at 100%"
        case .memoryWarning: "Memory Warning"
        case .memoryCritical: "Memory Critical"
        case .charging: "Charging"
        case .discharging: "Discharging"
        case .notCharging: "Not Charging"
        case .noAdapter: "No Adapter"
        case .threeDigitPower: "Three-Digit Power"
        case .missingData: "Missing Data"
        case .missingHistory: "Missing History"
        case .longestReason: "Longest Unavailable Reason"
        case .sensorFailed: "Selected Sensor Failed"
        case .nonCPUSensor: "Non-CPU Sensor Selected"
        case .longSensorName: "Long Sensor Name"
        case .negativeTemperature: "Negative Temperature"
        case .retrySuccess: "Retry Succeeds"
        case .retryFailure: "Retry Fails"
        case .paused: "Paused"
        case .wakeRecovery: "Wake Recovery"
        case .pauseSleepWake: "Pause, Sleep, Wake"
        case .intervalChanges: "Interval Changes"
        }
    }

    public var summary: String {
        switch self {
        case .typical: "Moderate mixed load, charging on a 96 W adapter, 15 minutes of history."
        case .idle: "Near-idle CPU and GPU. ANE Power is a valid 0.0 W."
        case .heavyLoad: "Sustained load on all 18 cores and the GPU; high temperatures."
        case .thermalThrottle: "Explicit thermal-throttle evidence; verifies the Throttle marker."
        case .singleCoreSaturated: "S0 at exactly 100%, every other core at 0%. S-Core average 16.7%, CPU total 5.6%."
        case .memoryWarning: "Pressure rose to Warning six minutes ago; swap and paging are active."
        case .memoryCritical: "Pressure went Normal → Warning → Critical; heavy swapping."
        case .charging: "Adapter connected and the battery charging quickly."
        case .discharging: "Heavy load on a 60 W adapter; the battery makes up the difference."
        case .notCharging: "Adapter connected, battery neither charging nor discharging. Magnitude stays measured."
        case .noAdapter: "Running on battery. Power Input shows No Adapter."
        case .threeDigitPower: "System Power above 100 W to check widths in the menu bar and panel."
        case .missingData: "Energy Counters unsupported on this macOS version, GPU Activity unavailable, System Sensors stale."
        case .missingHistory: "Only the last 45 seconds of history, with a gap. Charts must not bridge it."
        case .longestReason: "Shows the longest unavailable reason in cards, tooltips, and Data Sources."
        case .sensorFailed: "Selected sensor Tp0X disappears. The selection is kept; the panel offers Use CPU Max."
        case .nonCPUSensor: "Temperature source is a battery sensor (TB1T)."
        case .longSensorName: "Temperature source has a very long name; compact places show its ID."
        case .negativeTemperature: "Temperature source reads −20 °C."
        case .retrySuccess: "Energy Counters stopped after six attempts. Retry succeeds with one warm-up cycle."
        case .retryFailure: "Energy Counters stopped. Retry fails and the backoff runs again before stopping."
        case .paused: "Monitoring paused by the user. History ends at the pause."
        case .wakeRecovery: "Woke after a four-minute sleep. History has a gap; differenced values warm up for one cycle."
        case .pauseSleepWake: "Paused, then use Sleep and Wake. Waking must not resume monitoring."
        case .intervalChanges: "History recorded at 1 s, 5 s, and 2 s intervals with no false gaps; live at 5 s."
        }
    }

    // MARK: - Configuration

    var load: FixtureLoad {
        switch self {
        case .idle, .negativeTemperature: .idle
        case .heavyLoad, .thermalThrottle, .discharging: .heavy
        case .threeDigitPower: .extreme
        case .singleCoreSaturated: .singleCore
        case .noAdapter: .light
        default: .typical
        }
    }

    var memory: FixtureMemory {
        switch self {
        case .memoryWarning: .warning
        case .memoryCritical: .critical
        default: .normal
        }
    }

    var power: FixturePower {
        switch self {
        case .idle, .singleCoreSaturated, .notCharging, .negativeTemperature: .notCharging
        case .charging: .fastCharging
        case .discharging: .discharging
        case .noAdapter: .noAdapter
        case .threeDigitPower: .highPower
        default: .charging
        }
    }

    var behaviors: [SourceID: SimulatedBehavior] {
        switch self {
        case .missingData: [.energy: .unknownOSVersion, .gpuActivity: .unsupported, .sensors: .stale]
        case .longestReason: [.energy: .unknownOSVersion]
        case .retryFailure: [.energy: .failing]
        default: [:]
        }
    }

    /// Sources placed directly in the stopped state when the scenario is applied.
    public var startsStopped: [SourceID] {
        switch self {
        case .retrySuccess, .retryFailure: [.energy]
        default: []
        }
    }

    var missingSensors: Set<String> {
        self == .sensorFailed ? ["Tp0X"] : []
    }

    /// Temperature source the scenario selects, or nil to keep the current one.
    public var temperatureSource: TemperatureSource? {
        switch self {
        case .sensorFailed: .sensor("Tp0X")
        case .nonCPUSensor: .sensor("TB1T")
        case .longSensorName: .sensor("TR1B")
        case .negativeTemperature: .sensor("TaTP")
        default: nil
        }
    }

    public var updateInterval: UpdateInterval? {
        self == .intervalChanges ? .five : nil
    }

    public var startsPaused: Bool {
        self == .paused || self == .pauseSleepWake
    }

    public var wakesOnApply: Bool {
        self == .wakeRecovery
    }

    var seed: UInt64 {
        // Stable per scenario so screenshots are reproducible.
        UInt64(FixtureScenario.allCases.firstIndex(of: self)!) &* 0x2545_F491_4F6C_DD1D &+ 0x5EED
    }

    var historyPlan: FixtureHistoryPlan {
        switch self {
        case .missingHistory: .recent(seconds: 45, gapFrom: 30, gapTo: 18)
        case .wakeRecovery: .sleepGap(from: 420, to: 2)
        case .intervalChanges: .mixedIntervals
        default: .full
        }
    }
}

enum FixtureLoad: Sendable {
    case idle, light, typical, heavy, extreme, singleCore
}

enum FixtureMemory: Sendable {
    case normal, warning, critical
}

enum FixturePower: Sendable {
    case charging, fastCharging, discharging, notCharging, noAdapter, highPower
}

enum FixtureHistoryPlan: Sendable {
    case full
    /// Only recent history, with a gap from `gapFrom` until `gapTo` seconds ago.
    case recent(seconds: TimeInterval, gapFrom: TimeInterval, gapTo: TimeInterval)
    /// Asleep from `from` until `to` seconds ago.
    case sleepGap(from: TimeInterval, to: TimeInterval)
    case mixedIntervals
}

/// How a simulated source behaves. Debug only.
public enum SimulatedBehavior: String, CaseIterable, Identifiable, Sendable {
    case normal
    case stale
    case failing
    case recoversOnThirdAttempt
    case unsupported
    case unknownOSVersion
    case permissionDenied

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .stale: "Stale (no new data)"
        case .failing: "Fails every attempt"
        case .recoversOnThirdAttempt: "Fails, recovers on attempt 3"
        case .unsupported: "Unsupported"
        case .unknownOSVersion: "Unknown macOS version"
        case .permissionDenied: "Permission denied"
        }
    }
}
