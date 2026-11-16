// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct ThrottleStatus: Sendable, Equatable {
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

public struct ProcessMemoryEntry: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var memoryBytes: Double
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, memoryBytes: Double) {
        self.pid = pid
        self.name = name
        self.memoryBytes = memoryBytes
    }
}

public struct ProcessMemorySnapshot: Sendable, Equatable {
    public var entries: [ProcessMemoryEntry]
    public var status: ReadingStatus
    public var timestamp: TimeInterval?
    public var inaccessibleProcessCount: Int

    public init(entries: [ProcessMemoryEntry] = [], status: ReadingStatus = .warming, timestamp: TimeInterval? = nil, inaccessibleProcessCount: Int = 0) {
        self.entries = entries
        self.status = status
        self.timestamp = timestamp
        self.inaccessibleProcessCount = inaccessibleProcessCount
    }

}
