// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum SourceFailure: Sendable, Equatable, Codable {
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

public enum OpenResult: Sendable, Equatable, Codable {
    case opened
    case failed(SourceFailure)
}

public struct SampleRequest: Sendable, Equatable, Codable {
    /// Sensor keys for temperature and catalog jobs.
    public var interval: TimeInterval = 1
    public var networkInterface: String?
    public var sensorIDs: [String]
    /// Differenced keys still inside their baseline cycle; providers may skip them.
    public var warmingKeys: Set<MetricKey>

    public init(sensorIDs: [String] = [], warmingKeys: Set<MetricKey> = []) {
        self.sensorIDs = sensorIDs
        self.warmingKeys = warmingKeys
    }
}

public enum SampleOutcome: Sendable, Equatable, Codable {
    /// Missing sensor keys mean the sensor is no longer reported.
    case values([MetricKey: Double])
    /// A full replacement for the mounted volume list, including removals.
    case diskDrives([DiskDriveSnapshot])
    case diskActivity([DiskActivity])
    case network(NetworkActivity)
    case measured([MetricKey: Double], window: TimeInterval)
    /// Only mark keys the collector knows the current machine cannot supply.
    case measuredPartial([MetricKey: Double], window: TimeInterval, unsupported: Set<MetricKey>)
    /// Position is the topology flat index. An absent value marks an unmapped channel.
    case coreEnergy(watts: [Double?], measuredAt: TimeInterval, window: TimeInterval)
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
    var diskBackgroundSample: (@Sendable (Double) -> SampleOutcome)? { get }
    var processBackgroundSample: (@MainActor (Double, Bool) async -> ProcessMemorySnapshot)? { get }
    func invalidateDiskDevices()
    var preparesBatches: Bool { get }
    func prepare(_ requests: [JobID: SampleRequest], at time: TimeInterval)
    func selfUsage(at time: TimeInterval, window: TimeInterval) -> SelfUsage?

    /// Subscribes to a source and captures a baseline for differenced metrics.
    func open(_ source: SourceID, at time: TimeInterval) -> OpenResult
    /// Releases any subscription state for a source.
    func close(_ source: SourceID)
    /// Captures a fresh baseline after pause, sleep, or a long gap.
    func rebaseline(_ source: SourceID, at time: TimeInterval)
    func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome
}

public extension MetricProvider {
    var preparesBatches: Bool { false }
    func prepare(_ requests: [JobID: SampleRequest], at time: TimeInterval) {}
    func selfUsage(at time: TimeInterval, window: TimeInterval) -> SelfUsage? { nil }
    var processBackgroundSample: (@MainActor (Double, Bool) async -> ProcessMemorySnapshot)? { nil }
    func invalidateDiskDevices() {}
    var throttleStatus: ThrottleStatus { .unavailable }
    var gpuThrottleStatus: ThrottleStatus { .unavailable }
    var processMemory: ProcessMemorySnapshot { ProcessMemorySnapshot() }
    var isLive: Bool { false }
    var diskBackgroundSample: (@Sendable (Double) -> SampleOutcome)? { nil }
}
