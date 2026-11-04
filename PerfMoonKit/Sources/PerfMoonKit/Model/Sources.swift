import Foundation

/// A collection source. Failures are isolated per source.
public enum SourceID: String, Sendable, CaseIterable, Identifiable, Hashable {
    case cpuActivity
    case cpuFrequency
    case energy
    case gpuActivity
    case sensors
    case battery
    case memory
    case memoryPressure
    case thermal
    case processMemory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuActivity: "CPU Activity"
        case .cpuFrequency: "CPU Frequency"
        case .energy: "Energy Counters"
        case .gpuActivity: "GPU Activity"
        case .sensors: "System Sensors"
        case .battery: "Battery"
        case .memory: "Memory"
        case .memoryPressure: "Memory Pressure"
        case .thermal: "Thermal Limits"
        case .processMemory: "Process Memory"
        }
    }

    public var technicalName: String {
        switch self {
        case .cpuActivity: "Mach"
        case .cpuFrequency: "IOReport"
        case .energy: "IOReport"
        case .gpuActivity: "IOReport"
        case .sensors: "SMC"
        case .battery: "AppleSmartBattery"
        case .memory: "Mach VM"
        case .memoryPressure: "Kernel"
        case .thermal: "Power Management"
        case .processMemory: "libproc"
        }
    }

    /// Differenced sources need one baseline cycle after (re)subscribing, resuming, or waking.
    public var isDifferenced: Bool {
        switch self {
        case .cpuActivity, .cpuFrequency, .energy, .gpuActivity, .memory: true
        case .sensors, .battery, .memoryPressure, .thermal, .processMemory: false
        }
    }

    public var jobs: [JobID] {
        JobID.allCases.filter { $0.source == self }
    }

    /// Metrics described on the Data Sources page.
    public var metrics: [MetricDescriptor] {
        switch self {
        case .cpuActivity:
            [
                MetricDescriptor("CPU Usage", quality: .derived, window: .updateInterval),
                MetricDescriptor("S-Core and P-Core Usage", quality: .derived, window: .updateInterval),
                MetricDescriptor("Per-Core Usage", quality: .derived, window: .updateInterval),
            ]
        case .cpuFrequency:
            [MetricDescriptor("Frequency", quality: .derived, window: .updateInterval)]
        case .energy:
            [
                MetricDescriptor("CPU Power", quality: .estimated, window: .updateInterval),
                MetricDescriptor("GPU Power", quality: .estimated, window: .updateInterval),
                MetricDescriptor("ANE Power", quality: .estimated, window: .updateInterval),
            ]
        case .gpuActivity:
            [
                MetricDescriptor("GPU Usage", quality: .derived, window: .updateInterval),
                MetricDescriptor("GPU Frequency", quality: .derived, window: .updateInterval),
            ]
        case .sensors:
            [
                MetricDescriptor("Temperatures", quality: .observed, window: .instant),
                MetricDescriptor("Power Input", quality: .observed, window: .instant),
                MetricDescriptor("System Power", quality: .observed, window: .instant),
                MetricDescriptor("Battery Power", quality: .observed, window: .instant),
                MetricDescriptor("CPU Package Power", unavailable: .unsupported),
            ]
        case .battery:
            [MetricDescriptor("Charge State", quality: .observed, window: .instant)]
        case .memory:
            [
                MetricDescriptor("Used", quality: .derived, window: .instant),
                MetricDescriptor("App, Wired, Compressed, Cached, Free", quality: .observed, window: .instant),
                MetricDescriptor("Swap Used", quality: .observed, window: .instant),
                MetricDescriptor("Paging and Swapping Rates", quality: .derived, window: .updateInterval),
            ]
        case .memoryPressure:
            [MetricDescriptor("Pressure Level", quality: .observed, window: .instant)]
        case .thermal:
            [MetricDescriptor("Thermal Throttling", quality: .observed, window: .instant)]
        case .processMemory:
            [MetricDescriptor("Top 10 Physical Footprints", quality: .observed, window: .instant)]
        }
    }
}

public struct MetricDescriptor: Sendable, Identifiable, Hashable {
    public enum Window: Sendable, Hashable {
        case instant
        case updateInterval
    }

    public var name: String
    public var quality: MetricQuality?
    public var window: Window?
    public var unavailable: UnavailableReason?

    public var id: String { name }

    public init(_ name: String, quality: MetricQuality, window: Window) {
        self.name = name
        self.quality = quality
        self.window = window
        self.unavailable = nil
    }

    public init(_ name: String, unavailable: UnavailableReason) {
        self.name = name
        self.quality = nil
        self.window = nil
        self.unavailable = unavailable
    }
}

/// A unit of scheduled work. Several jobs can share one source.
public enum JobID: String, Sendable, CaseIterable, Hashable {
    case cpuActivity
    case cpuFrequency
    case energy
    case gpuActivity
    case powerSensors
    case temperatures
    case battery
    case memory
    case memoryPressure
    case sensorCatalog
    case selfUsage
    case thermal
    case processMemory

    public var source: SourceID? {
        switch self {
        case .cpuActivity: .cpuActivity
        case .cpuFrequency: .cpuFrequency
        case .energy: .energy
        case .gpuActivity: .gpuActivity
        case .powerSensors, .temperatures, .sensorCatalog: .sensors
        case .battery: .battery
        case .memory: .memory
        case .memoryPressure: .memoryPressure
        case .selfUsage: nil
        case .thermal: .thermal
        case .processMemory: .processMemory
        }
    }

    /// Jobs that refresh at the visible rate when something on screen needs them.
    public var isPrimary: Bool {
        switch self {
        case .temperatures, .sensorCatalog, .selfUsage, .thermal, .processMemory: false
        default: true
        }
    }

    /// Fixed metric keys produced by the job. Temperatures are dynamic.
    public var keys: [MetricKey] {
        switch self {
        case .cpuActivity: [.cpuTotal, .cpuS, .cpuP] + (0..<CoreID.count).map(MetricKey.core)
        case .cpuFrequency: [.cpuFrequencyS, .cpuFrequencyP]
        case .energy: [.cpuPower, .gpuPower, .anePower]
        case .gpuActivity: [.gpuUsage, .gpuFrequency]
        case .powerSensors: [.powerInput, .powerSystem, .powerBattery]
        case .battery: [.batteryState, .adapterConnected]
        case .memory:
            [
                .memoryUsed, .memoryApp, .memoryWired, .memoryCompressed, .memoryCached,
                .memoryPurgeable, .memoryFree, .swapUsed, .pageIns, .pageOuts, .swapIns, .swapOuts,
            ]
        case .memoryPressure: [.memoryPressure]
        case .temperatures, .sensorCatalog, .selfUsage, .thermal, .processMemory: []
        }
    }
}

public enum MetricKey: Hashable, Sendable {
    case cpuTotal, cpuS, cpuP
    case core(Int)
    case cpuFrequencyS, cpuFrequencyP
    case cpuPower, gpuPower, anePower
    case gpuUsage, gpuFrequency
    case powerInput, powerSystem, powerBattery
    case batteryState, adapterConnected
    case memoryUsed, memoryApp, memoryWired, memoryCompressed, memoryCached, memoryPurgeable, memoryFree, swapUsed
    case pageIns, pageOuts, swapIns, swapOuts
    case memoryPressure
    case sensor(String)
    // Derived from sensor readings.
    case cpuTemperature
    case gpuTemperature
    case coreTemperature(Int)

    /// Needs a baseline sample before the first value.
    public var isDifferenced: Bool {
        switch self {
        case .cpuTotal, .cpuS, .cpuP, .core, .cpuFrequencyS, .cpuFrequencyP,
             .cpuPower, .gpuPower, .anePower, .gpuUsage, .gpuFrequency,
             .pageIns, .pageOuts, .swapIns, .swapOuts:
            true
        default:
            false
        }
    }

    public var unit: MetricUnit {
        switch self {
        case .cpuTotal, .cpuS, .cpuP, .core, .gpuUsage: .percent
        case .cpuFrequencyS, .cpuFrequencyP, .gpuFrequency: .gigahertz
        case .cpuPower, .gpuPower, .anePower, .powerInput, .powerSystem, .powerBattery: .watts
        case .batteryState, .adapterConnected, .memoryPressure: .level
        case .memoryUsed, .memoryApp, .memoryWired, .memoryCompressed, .memoryCached,
             .memoryPurgeable, .memoryFree, .swapUsed:
            .bytes
        case .pageIns, .pageOuts, .swapIns, .swapOuts: .perSecond
        case .sensor, .cpuTemperature, .gpuTemperature, .coreTemperature: .celsius
        }
    }

    public var quality: MetricQuality {
        switch self {
        case .cpuPower, .gpuPower, .anePower: .estimated
        case .cpuTotal, .cpuS, .cpuP, .core, .cpuFrequencyS, .cpuFrequencyP, .gpuUsage, .gpuFrequency,
             .memoryUsed, .pageIns, .pageOuts, .swapIns, .swapOuts, .cpuTemperature, .gpuTemperature:
            .derived
        default: .observed
        }
    }

    public var series: SeriesKey? {
        switch self {
        case .cpuTotal: .cpuTotal
        case .cpuS: .cpuS
        case .cpuP: .cpuP
        case .cpuFrequencyS: .cpuFrequencyS
        case .cpuFrequencyP: .cpuFrequencyP
        case .cpuPower: .cpuPower
        case .cpuTemperature: .cpuTemperature
        case .gpuUsage: .gpuUsage
        case .gpuFrequency: .gpuFrequency
        case .gpuTemperature: .gpuTemperature
        case .gpuPower: .gpuPower
        case .anePower: .anePower
        case .memoryUsed: .memoryUsed
        case .memoryPressure: .memoryPressure
        case .powerInput: .powerInput
        case .powerSystem: .powerSystem
        case .powerBattery: .powerBattery
        case .batteryState: .batteryState
        default: nil
        }
    }
}

/// Something on screen that needs data. The menu bar is the implicit background demand.
public enum Demand: Hashable, Sendable {
    case popover
    case window(Page)
    case sensorTable
    case performancePage
    case memoryProcesses
}

public enum Page: String, CaseIterable, Sendable, Identifiable, Hashable {
    case overview, cpu, gpu, memory, power

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .gpu: "GPU & ANE"
        case .memory: "Memory"
        case .power: "Power"
        }
    }

    /// Primary jobs refreshed at the visible rate while this page is on screen.
    public var primaryJobs: Set<JobID> {
        switch self {
        case .overview: Set(JobID.allCases.filter(\.isPrimary))
        case .cpu: [.cpuActivity, .cpuFrequency, .energy]
        case .gpu: [.gpuActivity, .energy]
        case .memory: [.memory, .memoryPressure]
        case .power: [.powerSensors, .battery, .energy]
        }
    }
}

public enum SuspendReason: Hashable, Sendable {
    case sleep
    case screenLocked
}
