import Foundation

public enum SourceFailure: Sendable, Equatable {
    /// Temporary I/O failure; eligible for automatic backoff.
    case transient
    case unsupported
    case unknownOSVersion
    case permissionDenied

    public var reason: UnavailableReason {
        switch self {
        case .transient: .retrying
        case .unsupported: .unsupported
        case .unknownOSVersion: .unknownOSVersion
        case .permissionDenied: .permissionDenied
        }
    }
}

public enum OpenResult: Sendable, Equatable {
    case opened
    case failed(SourceFailure)
}

public struct SampleRequest: Sendable, Equatable {
    /// Sensor keys for temperature and catalog jobs.
    public var sensorIDs: [String]
    /// Differenced keys still inside their baseline cycle; providers may skip them.
    public var warmingKeys: Set<MetricKey>

    public init(sensorIDs: [String] = [], warmingKeys: Set<MetricKey> = []) {
        self.sensorIDs = sensorIDs
        self.warmingKeys = warmingKeys
    }
}

public enum SampleOutcome: Sendable, Equatable {
    /// Missing sensor keys mean the sensor is no longer reported.
    case values([MetricKey: Double])
    case measured([MetricKey: Double], window: TimeInterval)
    /// The source has not produced a new value since the last sample.
    case noNewData
    case failed(SourceFailure)
}

/// The shared contract used by native hardware collection and deterministic fixtures.
@MainActor
public protocol MetricProvider: AnyObject {
    var machine: MachineInfo { get }
    var sensors: [SensorInfo] { get }
    var throttleStatus: ThrottleStatus { get }
    var gpuThrottleStatus: ThrottleStatus { get }
    var processMemory: ProcessMemorySnapshot { get }
    var isLive: Bool { get }

    /// Subscribes to a source and captures a baseline for differenced metrics.
    func open(_ source: SourceID, at time: TimeInterval) -> OpenResult
    /// Releases any subscription state for a source.
    func close(_ source: SourceID)
    /// Captures a fresh baseline after pause, sleep, or a long gap.
    func rebaseline(_ source: SourceID, at time: TimeInterval)
    func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome
}

public extension MetricProvider {
    var throttleStatus: ThrottleStatus { .unavailable }
    var gpuThrottleStatus: ThrottleStatus { .unavailable }
    var processMemory: ProcessMemorySnapshot { ProcessMemorySnapshot() }
    var isLive: Bool { false }
}
