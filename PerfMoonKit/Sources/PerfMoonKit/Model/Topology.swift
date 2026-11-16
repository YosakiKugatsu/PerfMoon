// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum CoreCluster: String, Sendable, CaseIterable, Hashable {
    case s
    case p

    public var title: String {
        switch self {
        case .s: "S-Core"
        case .p: "P-Core"
        }
    }

    public var spokenTitle: String {
        switch self {
        case .s: "S-Core"
        case .p: "P-Core"
        }
    }

    public var count: Int {
        switch self {
        case .s: CoreID.sCount
        case .p: CoreID.pCount
        }
    }

    public var cores: [CoreID] {
        (0..<count).map { CoreID(cluster: self, index: $0) }
    }
}

/// A core in UI order: S0–S5, then P0–P11. Collectors map hardware numbering into this order.
public struct CoreID: Hashable, Sendable, Identifiable {
    public static let sCount = 6
    public static let pCount = 12
    public static let count = sCount + pCount
    public static let all: [CoreID] = CoreCluster.allCases.flatMap(\.cores)

    public var cluster: CoreCluster
    public var index: Int

    public init(cluster: CoreCluster, index: Int) {
        self.cluster = cluster
        self.index = index
    }

    public init(flatIndex: Int) {
        if flatIndex < CoreID.sCount {
            self.init(cluster: .s, index: flatIndex)
        } else {
            self.init(cluster: .p, index: flatIndex - CoreID.sCount)
        }
    }

    public var flatIndex: Int { cluster == .s ? index : CoreID.sCount + index }
    public var label: String { (cluster == .s ? "S" : "P") + String(index) }
    public var id: Int { flatIndex }
}

public struct MachineInfo: Sendable, Equatable {
    public var chipName: String
    public var shortChipName: String
    public var gpuCoreCount: Int
    public var physicalMemory: Double

    public init(chipName: String, shortChipName: String, gpuCoreCount: Int, physicalMemory: Double) {
        self.chipName = chipName
        self.shortChipName = shortChipName
        self.gpuCoreCount = gpuCoreCount
        self.physicalMemory = physicalMemory
    }
}

public enum SensorCategory: String, Sendable, CaseIterable, Hashable, Identifiable {
    case cpu, gpu, soc, memory, battery, storage, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .memory: "Memory"
        case .battery: "Battery"
        case .storage: "Storage"
        case .other: "Other"
        }
    }
}

public struct SensorInfo: Sendable, Hashable, Identifiable {
    /// Hardware key, shown as-is and never translated.
    public var id: String
    public var name: String
    public var category: SensorCategory
    /// Core matched by a community-maintained table, if any.
    public var mappedCore: CoreID?

    public init(id: String, name: String, category: SensorCategory, mappedCore: CoreID? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.mappedCore = mappedCore
    }
}

public enum TemperatureSource: Hashable, Sendable {
    case cpuMax
    case cpuAverage
    case sensor(String)

    public init(storageValue: String) {
        switch storageValue {
        case "cpuMax": self = .cpuMax
        case "cpuAverage": self = .cpuAverage
        default:
            if storageValue.hasPrefix("sensor:") {
                self = .sensor(String(storageValue.dropFirst("sensor:".count)))
            } else {
                self = .cpuMax
            }
        }
    }

    public var storageValue: String {
        switch self {
        case .cpuMax: "cpuMax"
        case .cpuAverage: "cpuAverage"
        case .sensor(let id): "sensor:\(id)"
        }
    }

    /// Compact label used before a temperature value.
    public var compactLabel: String {
        switch self {
        case .cpuMax: "Max"
        case .cpuAverage: "Avg"
        case .sensor(let id): id
        }
    }

    public var title: String {
        switch self {
        case .cpuMax: "CPU Max"
        case .cpuAverage: "CPU Average"
        case .sensor(let id): id
        }
    }
}

public enum MemoryPressureLevel: Int, Sendable, CaseIterable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    public init(value: Double) {
        self = MemoryPressureLevel(rawValue: Int(value.rounded())) ?? .normal
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum BatteryChargeState: Int, Sendable, CaseIterable {
    case notCharging = 0
    case charging = 1
    case discharging = 2

    public init(value: Double) {
        self = BatteryChargeState(rawValue: Int(value.rounded())) ?? .notCharging
    }

    public var title: String {
        switch self {
        case .notCharging: "Not Charging"
        case .charging: "Charging"
        case .discharging: "Discharging"
        }
    }
}

public enum UpdateInterval: Double, Sendable, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case five = 5

    public var id: Double { rawValue }
    public var title: String { "\(Int(rawValue)) s" }
}

public enum TemperatureUnit: String, Sendable, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .celsius: "Celsius (°C)"
        case .fahrenheit: "Fahrenheit (°F)"
        }
    }
}

public enum TimeRange: Int, Sendable, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var shortTitle: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        }
    }

    public var spokenTitle: String {
        switch self {
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        }
    }
}

public enum MenuBarMetric: String, Sendable, CaseIterable, Identifiable {
    case cpuUsage
    case gpuUsage
    case systemPower
    case cpuTemperature
    case memoryUsed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuUsage: "CPU Usage"
        case .gpuUsage: "GPU Usage"
        case .systemPower: "System Power"
        case .cpuTemperature: "CPU Temperature"
        case .memoryUsed: "Memory Used"
        }
    }
}
