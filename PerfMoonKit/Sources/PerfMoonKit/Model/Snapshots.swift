// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct CPUSnapshot: Sendable, Equatable {
    public var total: MetricReading
    public var sCore: MetricReading
    public var pCore: MetricReading
    public var sFrequency: MetricReading
    public var pFrequency: MetricReading
    public var power: MetricReading
    public var temperature: MetricReading
    public var temperatureSource: TemperatureSource
    /// S0–S5 then P0–P11.
    public var cores: [MetricReading]
    /// Mapped core temperatures; nil when the core has no mapped sensor or it is not being read.
    public var coreTemperatures: [MetricReading?]
    public var throttle: ThrottleStatus = .unavailable

    public func usage(_ cluster: CoreCluster) -> MetricReading {
        cluster == .s ? sCore : pCore
    }

    public func frequency(_ cluster: CoreCluster) -> MetricReading {
        cluster == .s ? sFrequency : pFrequency
    }
}

public struct GPUSnapshot: Sendable, Equatable {
    public var usage: MetricReading
    public var frequency: MetricReading
    public var temperature: MetricReading
    public var power: MetricReading
    public var anePower: MetricReading
    public var throttle: ThrottleStatus = .unavailable
}

public struct MemorySnapshot: Sendable, Equatable {
    public var physical: Double
    public var used: MetricReading
    public var app: MetricReading
    public var wired: MetricReading
    public var compressed: MetricReading
    public var cached: MetricReading
    public var purgeable: MetricReading
    public var reusable: MetricReading = .pending(.bytes, source: .memory)
    public var free: MetricReading
    public var swapUsed: MetricReading
    public var pageIns: MetricReading
    public var pageOuts: MetricReading
    public var swapIns: MetricReading
    public var swapOuts: MetricReading
    public var pressure: MetricReading
    public var processes: ProcessMemorySnapshot = ProcessMemorySnapshot()

    public var available: MetricReading {
        var reading = used
        reading.value = used.value.map { max(0, physical - $0) }
        reading.quality = .derived
        return reading
    }

    public var pressureLevel: MemoryPressureLevel? {
        pressure.shownValue.map(MemoryPressureLevel.init(value:))
    }
}

public struct PowerSnapshot: Sendable, Equatable {
    public var input: MetricReading
    public var system: MetricReading
    public var battery: MetricReading
    public var batteryState: MetricReading
    public var adapterConnected: MetricReading

    public var chargeState: BatteryChargeState? {
        batteryState.shownValue.map(BatteryChargeState.init(value:))
    }

    /// nil when the battery source has not reported yet.
    public var hasAdapter: Bool? {
        adapterConnected.shownValue.map { $0 >= 0.5 }
    }
}

public struct RunState: Sendable, Equatable {
    public var userPaused: Bool
    public var systemSuspended: Bool

    public init(userPaused: Bool, systemSuspended: Bool) {
        self.userPaused = userPaused
        self.systemSuspended = systemSuspended
    }

    public var isPaused: Bool { userPaused }
}

/// At most one prompt is shown in the panel. Stopped sources win.
public enum PanelPrompt: Sendable, Equatable {
    case retry([SourceID])
    case useCPUMax(sensorID: String)
}

public struct SourceStatus: Sendable, Equatable, Identifiable {
    public var id: SourceID
    public var phase: SourceRuntime.Phase
    public var lastUpdated: TimeInterval?
    /// Effective interval of the fastest job of this source, if any job is scheduled.
    public var interval: TimeInterval?

    public var reason: UnavailableReason? {
        switch phase {
        case .recovering: .retrying
        case .stopped: .stopped
        case .unavailable(let reason): reason
        case .idle, .active: nil
        }
    }
}

public struct SensorReading: Sendable, Equatable, Identifiable {
    public var info: SensorInfo
    public var reading: MetricReading
    public var id: String { info.id }
}

public struct MonitorSnapshot: Sendable, Equatable {
    public var time: TimeInterval
    public var run: RunState
    public var cpu: CPUSnapshot
    public var gpu: GPUSnapshot
    public var memory: MemorySnapshot
    public var disk: DiskSnapshot
    public var diskDrives: [DiskDriveSnapshot]
    public var diskVolumes: [DiskSnapshot] { diskDrives.flatMap(\.volumes) }
    public var power: PowerSnapshot
    public var prompt: PanelPrompt?
    public var historyRevision: Int
}
