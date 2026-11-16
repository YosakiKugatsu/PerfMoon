// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PerfMoonKit
import SwiftUI

/// Disk sizes in decimal units, as Finder and System Settings show them, so the numbers
/// match what people see elsewhere. Memory keeps its binary units.
enum StorageFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// "1.99 TB", "412 GB", "8.6 GB", "640 MB".
    static func bytes(_ value: Double) -> String {
        let value = max(0, value)
        if value >= 0.9995e12 { return String(format: "%.2f TB", locale: posix, value / 1e12) }
        if value >= 99.5e9 { return "\(Int((value / 1e9).rounded())) GB" }
        if value >= 0.995e9 { return String(format: "%.1f GB", locale: posix, value / 1e9) }
        return "\(Int((value / 1e6).rounded())) MB"
    }

    static func spoken(_ value: Double) -> String {
        bytes(value)
            .replacingOccurrences(of: " TB", with: " terabytes")
            .replacingOccurrences(of: " GB", with: " gigabytes")
            .replacingOccurrences(of: " MB", with: " megabytes")
    }
}

extension ReadingText {
    static func storage(_ reading: MetricReading, font: Font = .pmBodyNumber, emphasis: Emphasis = .primary) -> ReadingText {
        ReadingText(reading: reading, format: StorageFormat.bytes, font: font, emphasis: emphasis, spoken: StorageFormat.spoken)
    }
}

// MARK: - Capacity

/// Readings a physical drive and a volume have in common, so one set of views draws both.
protocol StorageCapacity {
    var totalBytes: Double? { get }
    var used: MetricReading { get }
    var available: MetricReading { get }
    var usedFraction: Double? { get }
}

extension DiskSnapshot: StorageCapacity {}
extension DiskDriveSnapshot: StorageCapacity {}

extension StorageCapacity {
    /// "412 gigabytes used of 995 gigabytes, 582 gigabytes available", or the reason a value is missing.
    @MainActor var spokenCapacity: String {
        let usedText: String
        if let value = used.shownValue {
            usedText = "\(StorageFormat.spoken(value)) used" + (totalBytes.map { " of \(StorageFormat.spoken($0))" } ?? "")
                + (used.isStale ? ", stale" : "")
        } else {
            usedText = "Used \(ReadingText.placeholderHelp(used))"
        }
        let availableText = available.shownValue == nil
            ? "Available \(ReadingText.placeholderHelp(available))"
            : "\(ReadingText.spoken(available, StorageFormat.spoken)) available"
        return "\(usedText), \(availableText)"
    }
}

// MARK: - Drives and volumes

extension DiskDriveSnapshot {
    /// "Internal Storage" or "External Storage"; the media name when the system doesn't say.
    var storageTitle: String {
        switch isInternal {
        case true?: "Internal Storage"
        case false?: "External Storage"
        case nil: name
        }
    }

    var symbol: String {
        isInternal == false ? "externaldrive" : "internaldrive"
    }

    /// The startup volume if it's on this drive, otherwise the first volume.
    var leadingVolume: DiskSnapshot? {
        volumes.first(where: \.isStartup) ?? volumes.first
    }

    /// "Macintosh HD · APFS", "Macintosh HD and 2 more", or "No mounted volumes".
    var volumeSummary: String {
        guard let first = leadingVolume else { return "No mounted volumes" }
        if volumes.count == 1 {
            return first.fileSystem.isEmpty ? first.name : "\(first.name) · \(first.fileSystem)"
        }
        return "\(first.name) and \(volumes.count - 1) more"
    }

    /// Menu and tooltip text: "Internal Storage · disk0 · APPLE SSD AP1024Z".
    var menuTitle: String {
        ([storageTitle, id] + (name == storageTitle ? [] : [name])).joined(separator: " · ")
    }

    /// Names whose Used and Available these are: the startup volume's, as macOS reports them,
    /// or the space allocated on the drive when macOS gives no estimate.
    var capacityHelp: String {
        if let scope = capacityScopeName {
            return "Used and Available for \(scope), as macOS reports them. Space macOS can reclaim counts as available."
        }
        return "Space allocated on this drive's file systems."
    }

    /// Spoken scope plus the startup container's allocated and reclaimable space, when known.
    @MainActor var spokenScope: String {
        var parts: [String] = []
        if let scope = capacityScopeName { parts.append("for \(scope), as macOS reports it") }
        if let reading = allocated { parts.append("allocated \(ReadingText.spoken(reading, StorageFormat.spoken))") }
        if let reading = reclaimable { parts.append("reclaimable \(ReadingText.spoken(reading, StorageFormat.spoken))") }
        return parts.joined(separator: ", ")
    }
}

extension DiskSnapshot {
    /// "disk3s1s1 · /" from the parts that are known.
    var locationText: String {
        [deviceIdentifier, mountPath.isEmpty ? nil : mountPath].compactMap { $0 }.joined(separator: " · ")
    }

    /// File system, device, the volume's own used space, sharing, and mount point.
    @MainActor var spokenVolume: String {
        var parts: [String] = []
        if !fileSystem.isEmpty { parts.append(fileSystem) }
        if let device = deviceIdentifier { parts.append("device \(device)") }
        if let value = used.shownValue {
            var text = "\(StorageFormat.spoken(value)) used"
            if !sharesCapacity, let total = totalBytes { text += " of \(StorageFormat.spoken(total))" }
            parts.append(text + (used.isStale ? ", stale" : ""))
        } else {
            parts.append("Used \(ReadingText.placeholderHelp(used))")
        }
        if sharesCapacity { parts.append("shares free space with its container") }
        if !mountPath.isEmpty { parts.append("mounted at \(mountPath)") }
        return parts.joined(separator: ", ")
    }

    var usedHelp: String {
        sharesCapacity
            ? "Space allocated to this volume. It can include space macOS can reclaim, so volumes can add up to more than the drive's Used. Free space is shared by the volumes in its APFS container."
            : "Space used on this volume, of its own capacity."
    }
}

// MARK: - Views

/// Used space with the total beside it: "412 GB / 995 GB" or "412 GB of 995 GB". The total
/// appears only when it was measured.
struct DiskUsageText: View {
    let capacity: any StorageCapacity
    let font: Font
    /// Joins the two values, for example "/", "of", or "used of".
    var separator = "/"
    var captionFont: Font = .pmCaption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ReadingText.storage(capacity.used, font: font)
            if let total = capacity.totalBytes {
                Text("\(separator) \(StorageFormat.bytes(total))")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A volume's own used space. A volume that shares its container's space shows only what it
/// uses, never the shared total, so it can't read as a share of space it doesn't own.
struct VolumeUsedText: View {
    let volume: DiskSnapshot
    var font: Font = .pmCaptionNumber
    var separator = "/"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ReadingText.storage(volume.used, font: font)
            if !volume.sharesCapacity, let total = volume.totalBytes {
                Text("\(separator) \(StorageFormat.bytes(total))")
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(volume.usedHelp)
    }
}

/// "582 GB available", quiet enough for a header row.
struct DiskAvailableText: View {
    let capacity: any StorageCapacity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ReadingText.storage(capacity.available, font: .pmCaptionNumber, emphasis: .secondary)
            Text("available").foregroundStyle(.secondary)
        }
        .font(.pmCaption)
        .lineLimit(1)
        .fixedSize()
    }
}

/// "Startup" and similar context, in the same capsule size as the Throttle badge.
struct DiskContextTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.fill.tertiary, in: Capsule())
            .fixedSize()
    }
}

/// Occupancy of a drive or a volume with its own capacity. Without a measured share, only a
/// faint track is drawn, so a missing reading never looks like empty space.
struct DiskCapacityBar: View {
    let capacity: any StorageCapacity
    var height: CGFloat = 8

    var body: some View {
        Meter(fraction: capacity.usedFraction, color: Palette.disk, height: height)
            .opacity(capacity.usedFraction == nil ? 0.4 : capacity.used.isStale ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}
