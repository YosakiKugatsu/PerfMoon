// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Hardware CPU tier. A machine may have any verified subset of these tiers.
public enum CoreCluster: String, Sendable, CaseIterable, Hashable, Codable {
    case s
    case p
    case e

    public var title: String {
        switch self {
        case .e: "E-Core"
        case .s: "S-Core"
        case .p: "P-Core"
        }
    }

    public var spokenTitle: String {
        title
    }

    public var count: Int {
        switch self {
        case .e: 0 // The original preview fixture has no E cores.
        case .s: CoreID.sCount
        case .p: CoreID.pCount
        }
    }

    public var cores: [CoreID] {
        (0..<count).map { CoreID(cluster: self, index: $0) }
    }
}

/// A core in display order, with its independently verified Mach slot.
public struct CoreID: Hashable, Sendable, Identifiable, Codable {
    // Retained for the original preview fixture, not for live hardware discovery.
    public static let sCount = 6
    public static let pCount = 12
    public static let count = sCount + pCount
    public static let all: [CoreID] = CoreCluster.allCases.flatMap(\.cores)

    public let cluster: CoreCluster
    public let index: Int
    public let flatIndex: Int
    public let label: String
    let machIndex: Int

    public init(cluster: CoreCluster, index: Int) {
        switch cluster {
        case .e:
            self.init(cluster: cluster, index: index, flatIndex: Self.count + index, machIndex: index, prefix: "E")
        case .s:
            self.init(cluster: cluster, index: index, flatIndex: index, machIndex: Self.pCount + index, prefix: "S")
        case .p:
            self.init(cluster: cluster, index: index, flatIndex: Self.sCount + index, machIndex: index, prefix: "P")
        }
    }

    public init(flatIndex: Int) {
        if flatIndex < CoreID.sCount {
            self.init(cluster: .s, index: flatIndex)
        } else {
            self.init(cluster: .p, index: flatIndex - CoreID.sCount)
        }
    }

    init(cluster: CoreCluster, index: Int, flatIndex: Int, machIndex: Int, prefix: String) {
        self.cluster = cluster
        self.index = index
        self.flatIndex = flatIndex
        self.machIndex = machIndex
        self.label = "\(prefix)\(index)"
    }

    public var id: Int { flatIndex }
}

public struct CPUClusterTopology: Sendable, Equatable, Identifiable, Codable {
    public let role: CoreCluster
    public let title: String
    public let cores: [CoreID]
    public var count: Int { cores.count }
    public var id: CoreCluster { role }
}

public struct CPUTopology: Sendable, Equatable, Codable {
    public let logicalCPUCount: Int
    public let clusters: [CPUClusterTopology]
    public let cores: [CoreID]

    public func cluster(_ role: CoreCluster) -> CPUClusterTopology? { clusters.first { $0.role == role } }
    public func core(atFlatIndex index: Int) -> CoreID? { cores.indices.contains(index) ? cores[index] : nil }

    public init(logicalCPUCount: Int) {
        self.init(logicalCPUCount: max(0, logicalCPUCount), clusters: [])
    }

    private init(logicalCPUCount: Int, clusters: [CPUClusterTopology]) {
        self.logicalCPUCount = logicalCPUCount
        // UI order is independent of flat indices used by stored selections,
        // temperature mappings and history. Keep those identities stable.
        self.clusters = CoreCluster.allCases.compactMap { role in clusters.first { $0.role == role } }
        self.cores = clusters.flatMap(\.cores)
    }

    public static let fixture = CPUTopology(logicalCPUCount: CoreID.count, clusters: [
        CPUClusterTopology(role: .s, title: "S-Core", cores: CoreCluster.s.cores),
        CPUClusterTopology(role: .p, title: "P-Core", cores: CoreCluster.p.cores),
    ])

    enum Tier: String, Hashable {
        case efficiency, performance, `super`

        var role: CoreCluster {
            switch self {
            case .efficiency: .e
            case .performance: .p
            case .super: .s
            }
        }
    }

    /// XNU reports the load vector in kernel logical-CPU order. Match I/O Registry
    /// IDs to their firmware tier tags, then verify counts independently via sysctl.
    /// A missing, inconsistent, or unrepresentable map leaves only system CPU usage.
    init(logicalCPUCount: Int, performanceLevels: [(name: String?, count: Int)], firmwareTypes: [Int: String]) {
        let fallback = CPUTopology(logicalCPUCount: logicalCPUCount)
        guard !performanceLevels.isEmpty, performanceLevels.count <= CoreCluster.allCases.count,
              performanceLevels.allSatisfy({ $0.count > 0 && $0.count <= logicalCPUCount }),
              performanceLevels.map(\.count).reduce(0, +) == logicalCPUCount,
              firmwareTypes.count == logicalCPUCount else {
            self = fallback
            return
        }
        var expected: [Tier: Int] = [:]
        for level in performanceLevels {
            guard let name = level.name else { continue }
            guard let tier = Tier(rawValue: name.lowercased()), expected.updateValue(level.count, forKey: tier) == nil else {
                self = fallback
                return
            }
        }
        // M is explicitly the middle Performance tier, distinguishing it
        // from the P tag naming the Super tier on this firmware. With only
        // E/P tags, keep requiring names: P can mean Performance or Super.
        let tags = Set(firmwareTypes.values)
        let unnamedTiers = expected.count != performanceLevels.count
        let hasUnambiguousFirmwareTiers = tags.contains("M") && tags.contains("P")
        guard !unnamedTiers || hasUnambiguousFirmwareTiers else { self = fallback; return }
        let highestIsSuper = expected[.super] != nil || (unnamedTiers && hasUnambiguousFirmwareTiers)

        var mapped: [Tier: [Int]] = [:]
        var tagForTier: [Tier: String] = [:]
        for cpu in 0..<logicalCPUCount {
            guard let tag = firmwareTypes[cpu] else { self = fallback; return }
            let tier: Tier
            switch tag {
            case "E": tier = .efficiency
            case "M": tier = .performance
            // Older chips call P the performance tier. On the firmware that
            // advertises a separate Super tier, P denotes Super and M Performance.
            case "P": tier = highestIsSuper ? .super : .performance
            default: self = fallback; return
            }
            guard tagForTier[tier] == nil || tagForTier[tier] == tag else {
                self = fallback
                return
            }
            tagForTier[tier] = tag
            mapped[tier, default: []].append(cpu)
        }
        guard expected.allSatisfy({ mapped[$0.key]?.count == $0.value }),
              mapped.values.map(\.count).sorted() == performanceLevels.map(\.count).sorted() else {
            self = fallback
            return
        }
        var clusters: [CPUClusterTopology] = []
        var offset = 0
        for tier in [Tier.efficiency, .super, .performance] {
            guard let ids = mapped[tier] else { continue }
            let role = tier.role
            let cores = ids.enumerated().map { index, cpu in
                CoreID(cluster: role, index: index, flatIndex: offset + index, machIndex: cpu, prefix: role.rawValue.uppercased())
            }
            clusters.append(CPUClusterTopology(role: role, title: role.title, cores: cores))
            offset += ids.count
        }
        self.init(logicalCPUCount: logicalCPUCount, clusters: clusters)
    }
}

public struct MachineInfo: Sendable, Equatable, Codable {
    public var chipName: String
    public var shortChipName: String
    public var gpuCoreCount: Int
    public var physicalMemory: Double
    public var cpuTopology: CPUTopology

    public init(chipName: String, shortChipName: String, gpuCoreCount: Int, physicalMemory: Double,
                cpuTopology: CPUTopology = .fixture) {
        self.chipName = chipName
        self.shortChipName = shortChipName
        self.gpuCoreCount = gpuCoreCount
        self.physicalMemory = physicalMemory
        self.cpuTopology = cpuTopology
    }
}

public enum SensorCategory: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
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

public struct SensorInfo: Sendable, Hashable, Identifiable, Codable {
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
    case oneHour = 3600
    case sixHours = 21600

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var shortTitle: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        case .sixHours: "6h"
        }
    }

    public var spokenTitle: String {
        switch self {
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        }
    }
}

public enum MenuBarMetric: String, Sendable, CaseIterable, Identifiable {
    case cpuUsage
    case gpuUsage
    case systemPower
    case cpuTemperature
    case memoryUsed
    case networkDownload, networkUpload

    public var usesNetwork: Bool { self == .networkDownload || self == .networkUpload }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuUsage: "CPU Usage"
        case .gpuUsage: "GPU Usage"
        case .systemPower: "System Power"
        case .cpuTemperature: "CPU Temperature"
        case .memoryUsed: "Memory Used"
        case .networkDownload: "Network Download"
        case .networkUpload: "Network Upload"
        }
    }
}
