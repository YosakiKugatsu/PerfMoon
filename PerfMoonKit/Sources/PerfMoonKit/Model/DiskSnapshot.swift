// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

/// Capacity and consumed bytes for a mounted filesystem.
public struct DiskSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let mountPath: String
    public let deviceIdentifier: String?
    public let isStartup: Bool
    public let isInternal: Bool?
    public let fileSystem: String
    public let sharesCapacity: Bool
    private let individualUsed: Double?
    private let total: MetricReading
    public let available: MetricReading

    init(id: String, name: String, mountPath: String, deviceIdentifier: String?, isInternal: Bool?,
         totalBytes: Double?, availableBytes: Double?, at time: Double?, status: ReadingStatus = .valid,
         fileSystem: String = "Unknown", sharesCapacity: Bool = false, individualUsed: Double? = nil) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
        self.deviceIdentifier = deviceIdentifier
        self.isStartup = mountPath == "/"
        self.isInternal = isInternal
        self.fileSystem = fileSystem
        self.sharesCapacity = sharesCapacity
        self.individualUsed = individualUsed
        total = MetricReading(value: totalBytes, unit: .bytes, status: status, timestamp: time, source: .disk)
        available = MetricReading(value: availableBytes, unit: .bytes, status: status, timestamp: time, source: .disk)
    }

    static func placeholder(status: ReadingStatus) -> DiskSnapshot {
        DiskSnapshot(id: "startup-pending", name: "Startup Disk", mountPath: "/", deviceIdentifier: nil,
                     isInternal: nil, totalBytes: nil, availableBytes: nil, at: nil, status: status)
    }

    public var totalBytes: Double? { total.shownValue }

    public var used: MetricReading {
        var reading = available
        reading.quality = sharesCapacity ? .observed : .derived
        if sharesCapacity {
            reading.value = individualUsed
        } else if let total = totalBytes, let free = available.shownValue {
            reading.value = total - free
        } else {
            reading.value = nil
        }
        return reading
    }

    public var usedFraction: Double? {
        guard !sharesCapacity, let total = totalBytes, total > 0, let used = used.shownValue else { return nil }
        return used / total
    }
}


/// The startup container's system estimate and its raw APFS accounting, in the same scope.
struct DiskSystemCapacity: Sendable, Equatable {
    let name: String
    let total: Double
    let free: Double
    let available: Double

    init?(name: String, total: Double, free: Double, available: Double) {
        guard total.isFinite, total > 0, free >= 0, free <= total,
              available.isFinite, available >= free, available <= total else { return nil }
        self.name = name
        self.total = total
        self.free = free
        self.available = available
    }
}

/// One device group. The startup disk's headline uses macOS Storage's startup container scope;
/// other devices use their independently accounted filesystems, each counted at most once.
public struct DiskDriveSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isInternal: Bool?
    public let volumes: [DiskSnapshot]
    public let totalBytes: Double?
    public let available: MetricReading
    private let systemCapacity: DiskSystemCapacity?

    init(id: String, name: String, isInternal: Bool?, volumes: [DiskSnapshot],
         totalBytes: Double?, availableBytes: Double?, at time: Double,
         systemCapacity: DiskSystemCapacity? = nil) {
        self.id = id
        self.name = name
        self.isInternal = isInternal
        self.volumes = volumes
        self.systemCapacity = systemCapacity
        self.totalBytes = systemCapacity?.total ?? totalBytes
        let reportedAvailable = systemCapacity?.available ?? availableBytes
        available = MetricReading(value: reportedAvailable, unit: .bytes,
                                  status: reportedAvailable == nil ? .unavailable(.unsupported) : .valid,
                                  timestamp: reportedAvailable == nil ? nil : time, source: .disk,
                                  quality: systemCapacity == nil ? .observed : .estimated)
    }

    public var capacityScopeName: String? { systemCapacity?.name }
    public var allocated: MetricReading? {
        systemCapacity.map { derivedReading($0.total - $0.free, quality: .derived) }
    }
    public var reclaimable: MetricReading? {
        systemCapacity.map { derivedReading($0.available - $0.free, quality: .estimated) }
    }

    public var used: MetricReading {
        derivedReading(totalBytes.flatMap { total in available.shownValue.map { total - $0 } },
                       quality: systemCapacity == nil ? .derived : .estimated)
    }

    public var usedFraction: Double? {
        guard let total = totalBytes, total > 0, let used = used.shownValue else { return nil }
        return used / total
    }

    private func derivedReading(_ value: Double?, quality: MetricQuality) -> MetricReading {
        var reading = available
        reading.value = value
        reading.quality = quality
        return reading
    }
}
