import Foundation

/// Disjoint physical-capacity segments. Reusable is split out of App, never
/// added to Used again. Cached/Free/Purgeable overlap VM accounting and remain
/// separate diagnostic readings rather than extra segments in this partition.
public struct MemoryComposition: Sendable, Equatable {
    public var physical: Double
    public var app: Double
    public var reusable: Double?
    public var wired: Double
    public var compressed: Double
    public var available: Double
}

extension MemorySnapshot {
    public var composition: MemoryComposition? {
        guard physical.isFinite, physical > 0,
              let used = used.shownValue, used.isFinite,
              let app = app.shownValue, app.isFinite,
              let wired = wired.shownValue, wired.isFinite,
              let compressed = compressed.shownValue, compressed.isFinite else { return nil }
        let usedBytes = min(physical, max(0, used))
        let componentTotal = max(0, app) + max(0, wired) + max(0, compressed)
        guard componentTotal > 0 || usedBytes == 0 else { return nil }
        let scale = componentTotal > 0 ? usedBytes / componentTotal : 0
        let wiredBytes = max(0, wired) * scale
        let compressedBytes = max(0, compressed) * scale
        let appBytes = max(0, usedBytes - wiredBytes - compressedBytes)
        // Mach VM and the sysctl are adjacent reads, not an atomic snapshot.
        // Bound the optional subset to its parent during fast VM transitions.
        let reusableBytes = reusable.shownValue.flatMap { value in
            value.isFinite ? min(appBytes, max(0, value) * scale) : nil
        }
        return MemoryComposition(
            physical: physical, app: appBytes - (reusableBytes ?? 0),
            reusable: reusableBytes, wired: wiredBytes, compressed: compressedBytes,
            available: physical - usedBytes
        )
    }
}
