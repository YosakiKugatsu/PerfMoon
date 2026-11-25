// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// How a value was obtained. Shown only in details and Data Sources.
public enum MetricQuality: String, Sendable, CaseIterable, Codable {
    case observed
    case estimated
    case derived

    public var title: String {
        switch self {
        case .observed: "Measured"
        case .estimated: "Estimated"
        case .derived: "Derived"
        }
    }
}

/// Why a reading has no value. Every message is at most 40 characters.
public enum UnavailableReason: String, Sendable, CaseIterable, Codable {
    case unsupported
    case unknownOSVersion
    case interfaceDisconnected
    case sensorMissing
    case retrying
    case stopped
    case permissionDenied

    public var message: String {
        switch self {
        case .unsupported: "Not available on this Mac"
        case .unknownOSVersion: "Not supported on this macOS version"
        case .interfaceDisconnected: "No active interface"
        case .sensorMissing: "Sensor no longer reported"
        case .retrying: "Couldn't read. Retrying…"
        case .stopped: "Couldn't read. Click Retry."
        case .permissionDenied: "Access denied by macOS"
        }
    }

    /// Whether a person can usefully ask for another attempt.
    public var isRetryable: Bool {
        switch self {
        case .stopped, .permissionDenied: true
        default: false
        }
    }
}

public enum ReadingStatus: Sendable, Equatable, Codable {
    case valid
    case warming
    case stale
    case unavailable(UnavailableReason)

    public static let warmingMessage = "Collecting…"
}

public enum MetricUnit: Sendable, Equatable, Codable {
    case percent
    case watts
    case celsius
    case gigahertz
    case bytes
    case bytesPerSecond
    case perSecond
    case level
}

/// The single data contract between collection and every view.
public struct MetricReading: Sendable, Equatable, Codable {
    public var value: Double?
    public var unit: MetricUnit
    public var status: ReadingStatus
    /// Time of the last value, as seconds since the reference date.
    public var timestamp: TimeInterval?
    /// Sampling window the value describes.
    public var window: TimeInterval
    public var source: SourceID?
    public var quality: MetricQuality

    public init(
        value: Double?,
        unit: MetricUnit,
        status: ReadingStatus,
        timestamp: TimeInterval? = nil,
        window: TimeInterval = 0,
        source: SourceID? = nil,
        quality: MetricQuality = .observed
    ) {
        self.value = value
        self.unit = unit
        self.status = status
        self.timestamp = timestamp
        self.window = window
        self.source = source
        self.quality = quality
    }

    public static func pending(_ unit: MetricUnit, source: SourceID? = nil, quality: MetricQuality = .observed) -> MetricReading {
        MetricReading(value: nil, unit: unit, status: .warming, source: source, quality: quality)
    }

    /// The value a view may show: valid or stale readings only.
    public var shownValue: Double? {
        switch status {
        case .valid, .stale: value
        case .warming, .unavailable: nil
        }
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let reason) = status { return reason }
        return nil
    }

    public var isStale: Bool { status == .stale }
}
