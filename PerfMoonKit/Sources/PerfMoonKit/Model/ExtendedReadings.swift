// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct ThrottleStatus: Sendable, Equatable, Codable {
    public var isActive: Bool
    public var isAvailable: Bool
    public var explanation: String

    public init(isActive: Bool, isAvailable: Bool = true, explanation: String = "") {
        self.isActive = isActive
        self.isAvailable = isAvailable
        self.explanation = explanation
    }

    public static let unavailable = ThrottleStatus(isActive: false, isAvailable: false)
    public static let normal = ThrottleStatus(isActive: false)
}

public struct ProcessMemoryEntry: Sendable, Equatable, Identifiable, Codable {
    public var pid: Int32
    public var name: String
    public var memoryBytes: Double
    public var cpuPercent: Double = 0
    public var readBytesPerSecond: Double = 0
    public var writeBytesPerSecond: Double = 0
    public var id: Int32 { pid }

    public func value(for ranking: ProcessRanking) -> Double {
        switch ranking {
        case .memory: memoryBytes
        case .cpu: cpuPercent
        case .diskRead: readBytesPerSecond
        case .diskWrite: writeBytesPerSecond
        }
    }

    public init(pid: Int32, name: String, memoryBytes: Double) {
        self.pid = pid
        self.name = name
        self.memoryBytes = memoryBytes
    }
}

public struct ProcessMemorySnapshot: Sendable, Equatable, Codable {
    public var entries: [ProcessMemoryEntry]
    public var status: ReadingStatus
    public var timestamp: TimeInterval?
    public var byCPU: [ProcessMemoryEntry] = []
    public var byRead: [ProcessMemoryEntry] = []
    public var byWrite: [ProcessMemoryEntry] = []
    public var rateWindow: TimeInterval?
    public var inaccessibleProcessCount: Int

    public func entries(for ranking: ProcessRanking) -> [ProcessMemoryEntry] {
        switch ranking {
        case .memory: entries
        case .cpu: byCPU
        case .diskRead: byRead
        case .diskWrite: byWrite
        }
    }

    public init(entries: [ProcessMemoryEntry] = [], status: ReadingStatus = .warming, timestamp: TimeInterval? = nil, inaccessibleProcessCount: Int = 0) {
        self.entries = entries
        self.status = status
        self.timestamp = timestamp
        self.inaccessibleProcessCount = inaccessibleProcessCount
    }

}
public enum ProcessRanking: String, CaseIterable, Sendable, Identifiable {
    case memory, cpu, diskRead, diskWrite
    public var id: Self { self }
    public var title: String {
        switch self {
        case .memory: "Memory"
        case .cpu: "CPU"
        case .diskRead: "Disk Read"
        case .diskWrite: "Disk Write"
        }
    }
}
