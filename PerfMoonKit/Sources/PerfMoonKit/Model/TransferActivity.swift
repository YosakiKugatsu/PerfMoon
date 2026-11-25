// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Both directions come from the same counter snapshot and monotonic time window.
struct TransferCounters: Equatable {
    let incoming: UInt64
    let outgoing: UInt64

    func rates(since previous: Self?, elapsed: TimeInterval, at time: TimeInterval,
               source: SourceID, unit: MetricUnit = .bytesPerSecond) -> TransferRates {
        guard let previous, elapsed > 0, incoming >= previous.incoming, outgoing >= previous.outgoing else {
            return TransferRates(status: .warming, source: source, unit: unit)
        }
        return TransferRates(incoming: Double(incoming - previous.incoming) / elapsed,
                             outgoing: Double(outgoing - previous.outgoing) / elapsed,
                             at: time, window: elapsed, source: source, unit: unit)
    }
}

public struct TransferRates: Sendable, Equatable, Codable {
    public let incoming: MetricReading
    public let outgoing: MetricReading

    init(status: ReadingStatus, source: SourceID, unit: MetricUnit = .bytesPerSecond) {
        incoming = MetricReading(value: nil, unit: unit, status: status, source: source, quality: .derived)
        outgoing = incoming
    }

    init(incoming: Double, outgoing: Double, at time: TimeInterval, window: TimeInterval,
         source: SourceID, unit: MetricUnit = .bytesPerSecond) {
        self.incoming = MetricReading(value: incoming, unit: unit, status: .valid, timestamp: time,
                                      window: window, source: source, quality: .derived)
        self.outgoing = MetricReading(value: outgoing, unit: unit, status: .valid, timestamp: time,
                                      window: window, source: source, quality: .derived)
    }
}

public enum DiskActivityMetric: String, CaseIterable, Sendable {
    case read, write, readIOPS, writeIOPS
}

public struct DiskActivity: Sendable, Equatable, Identifiable, Codable {
    /// Registry identity of the whole media. A replacement can reuse the BSD name.
    public let id: UInt64
    public let device: String
    public let bytes: TransferRates
    public let operations: TransferRates

    func reading(_ metric: DiskActivityMetric) -> MetricReading {
        switch metric {
        case .read: bytes.incoming
        case .write: bytes.outgoing
        case .readIOPS: operations.incoming
        case .writeIOPS: operations.outgoing
        }
    }
}

public struct NetworkInterfaceInfo: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let index: UInt32
    public let name: String
    public let isHardware: Bool
}

public struct NetworkActivity: Sendable, Equatable, Codable {
    public internal(set) var interfaces: [NetworkInterfaceInfo]
    public let selected: NetworkInterfaceInfo?
    public let rates: TransferRates
    /// Link-layer counters over the lifetime reported by the interface.
    public let receivedBytes: UInt64?
    public let sentBytes: UInt64?

    init(interfaces: [NetworkInterfaceInfo] = [], selected: NetworkInterfaceInfo? = nil,
         rates: TransferRates = TransferRates(status: .warming, source: .network),
         receivedBytes: UInt64? = nil, sentBytes: UInt64? = nil) {
        self.interfaces = interfaces
        self.selected = selected
        self.rates = rates
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}
