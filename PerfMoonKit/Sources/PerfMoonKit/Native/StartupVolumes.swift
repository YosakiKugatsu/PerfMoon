// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import IOKit

/// Resolves mounted volumes to whole disks. APFS snapshots use the owning volume's
/// consumption; shared space is accounted only once, at container level.
final class StartupVolumes: @unchecked Sendable {
    // Each mount/rename event installs a fresh inventory. Any in-flight query
    // finishes against its old cache on the utility queue.
    private let lock = NSLock()
    private struct DriveInfo {
        var name: String?
        var isInternal: Bool?
        var registryID: UInt64?
    }
    private var metadata: [String: DriveInfo] = [:]
    private var expires: TimeInterval = 0

    func sample(at time: TimeInterval) -> SampleOutcome {
        lock.withLock {
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime >= expires {
                metadata.removeAll(keepingCapacity: true)
                expires = uptime + 300
            }
            return Self.sample(at: time, metadata: &metadata)
        }
    }

    private typealias Record = [String: Any]

    private struct Space {
        let total: Double
        let free: Double

        init?(total: Double?, free: Double?) {
            guard let total, let free, total > 0, (0...total).contains(free) else { return nil }
            self.total = total
            self.free = free
        }
    }

    private struct Container {
        let id: String
        let stores: [String]
        let owners: Set<String>
        let space: Space?
        let volumes: [Record]

        var group: String { owners.count == 1 ? owners.first! : id }

        func volume(_ device: String) -> Record? {
            volumes.first {
                guard let id = $0["DeviceIdentifier"] as? String else { return false }
                // A mounted APFS snapshot adds an sN suffix to its volume's BSD name.
                return device == id || (device.hasPrefix(id + "s") && device.dropFirst(id.count + 1).allSatisfy(\.isNumber))
            }
        }
    }

    private static func sample(at time: Double, metadata: inout [String: DriveInfo]) -> SampleOutcome {
        guard let diskList = plist(["list", "-plist"])?["AllDisksAndPartitions"] as? [Record],
              let apfsList = plist(["apfs", "list", "-plist"])?["Containers"] as? [Record],
              let mounts = mountedFilesystems() else { return .failed(.transient) }

        var records: [String: Record] = [:]
        var owner: [String: String] = [:]
        var parts: [String: Set<String>] = [:]
        for disk in diskList where disk["APFSPhysicalStores"] == nil && disk["Content"] as? String != "Apple_APFS_Container" {
            guard let id = disk["DeviceIdentifier"] as? String else { continue }
            records[id] = disk
            owner[id] = id
            for part in disk["Partitions"] as? [Record] ?? [] {
                guard let device = part["DeviceIdentifier"] as? String else { continue }
                owner[device] = id
                if part["Content"] as? String != "EFI" { parts[id, default: []].insert(device) }
            }
        }
        let containers = apfsList.compactMap { item -> Container? in
            guard let id = item["ContainerReference"] as? String else { return nil }
            let stores = (item["PhysicalStores"] as? [Record] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
            let owners = Set(stores.compactMap { owner[$0] })
            let resolvedOwners = stores.allSatisfy { owner[$0] != nil } ? owners : []
            return Container(id: id, stores: stores, owners: resolvedOwners,
                             space: Space(total: bytes(item["CapacityCeiling"]), free: bytes(item["CapacityFree"])),
                             volumes: item["Volumes"] as? [Record] ?? [])
        }
        var groups: [String: [DiskSnapshot]] = [:]
        var spaces: [String: [String: Space]] = [:]
        var accounted: [String: Set<String>] = [:]
        var startupCapacityByGroup: [String: DiskSystemCapacity] = [:]
        for container in containers {
            guard let space = container.space else { continue }
            spaces[container.group, default: [:]][container.id] = space
            if container.owners.count == 1 { accounted[container.group, default: []].formUnion(container.stores) }
        }
        for mount in mounts {
            let path = mountString(mount.f_mntonname)
            let device = mountString(mount.f_mntfromname)
            // The startup volume group has a real, separately accounted Data volume.
            // Other hidden service mounts (VM, Preboot, Recovery, etc.) don't clutter the list.
            guard device.hasPrefix("/dev/disk"), mount.f_flags & UInt32(MNT_LOCAL) != 0,
                  path == "/" || path == "/System/Volumes/Data" || mount.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
            let deviceID = String(device.dropFirst("/dev/".count))
            let fsType = mountString(mount.f_fstypename)
            let container = fsType == "apfs" ? containers.first { $0.volume(deviceID) != nil } : nil
            let group = container?.group ?? owner[deviceID] ?? deviceID
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsInternalKey])
            let volume = container?.volume(deviceID)
            // Foundation may return the shared Finder display name for both boot volumes.
            let name = (volume?["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? values?.volumeName.flatMap { $0.isEmpty ? nil : $0 }
                ?? (path == "/" ? "Startup Disk" : url.lastPathComponent)
            if path == "/", let containerSpace = container?.space,
               let estimate = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let available = estimate.volumeAvailableCapacityForImportantUsage {
                startupCapacityByGroup[group] = DiskSystemCapacity(
                    name: name, total: containerSpace.total, free: containerSpace.free, available: Double(available)
                )
            }
            var space = container?.space
            let individualUsed = bytes(volume?["CapacityInUse"])
            if fsType != "apfs" {
                var fresh = statfs()
                if statfs(path, &fresh) == 0 {
                    // An unplugged mount directory may resolve to the startup volume.
                    guard mountString(fresh.f_mntfromname) == device, mountString(fresh.f_mntonname) == path else { continue }
                    let block = Double(fresh.f_bsize)
                    space = Space(total: Double(fresh.f_blocks) * block, free: Double(fresh.f_bavail) * block)
                }
                if let space {
                    spaces[group, default: [:]][deviceID] = space
                    accounted[group, default: []].insert(deviceID)
                }
            }
            let valid = fsType == "apfs" ? individualUsed != nil : space != nil
            let reading = DiskSnapshot(id: deviceID, name: name, mountPath: path, deviceIdentifier: deviceID,
                                       isInternal: values?.volumeIsInternal, totalBytes: space?.total, availableBytes: space?.free,
                                       at: valid ? time : nil, status: valid ? .valid : .unavailable(.unsupported),
                                       fileSystem: filesystem(fsType), sharesCapacity: fsType == "apfs", individualUsed: individualUsed)
            groups[group, default: []].append(reading)
        }
        metadata = metadata.filter { records[$0.key] != nil }
        let drives = Set(records.keys).union(groups.keys).map { id -> DiskDriveSnapshot in
            let volumes = (groups[id] ?? []).sorted { a, b in
                if a.isStartup != b.isStartup { return a.isStartup }
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            if records[id] != nil, metadata[id] == nil, let info = plist(["info", "-plist", id]) {
                metadata[id] = DriveInfo(name: info["MediaName"] as? String, isInternal: info["Internal"] as? Bool,
                                         registryID: mediaRegistryID(id))
            }
            let internalDrive = metadata[id]?.isInternal ?? volumes.first?.isInternal
            let shared = containers.contains { $0.id == id && $0.owners.count > 1 }
            let name = metadata[id]?.name ?? (shared ? "Shared APFS Storage" : volumes.first?.name ?? id)
            let covered = parts[id, default: []].isSubset(of: accounted[id, default: []])
            let capacity = spaces[id]?.values
            let total = covered ? capacity?.reduce(0) { $0 + $1.total } : nil
            let free = covered ? capacity?.reduce(0) { $0 + $1.free } : nil
            return DiskDriveSnapshot(id: id, name: name, isInternal: internalDrive, volumes: volumes,
                                     totalBytes: total, availableBytes: free, at: time,
                                     systemCapacity: startupCapacityByGroup[id], registryID: metadata[id]?.registryID)
        }.sorted { a, b in
            let bootA = a.volumes.contains(where: \.isStartup)
            let bootB = b.volumes.contains(where: \.isStartup)
            if bootA != bootB { return bootA }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
        return drives.isEmpty ? .failed(.transient) : .diskDrives(drives)
    }

    private static func mediaRegistryID(_ name: String) -> UInt64? {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }

    private static func mountedFilesystems() -> ArraySlice<statfs>? {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0 else { return nil }
        var mounts = Array(repeating: statfs(), count: count + 8)
        let length = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard length > 0, Int(length) <= mounts.count else { return nil }
        return mounts.prefix(Int(length))
    }

    static func health(for device: String) -> DiskHealthReport? {
        // The collector accepts a whole-disk BSD identifier only.
        guard device.hasPrefix("disk"), (5...16).contains(device.utf8.count),
              device.utf8.dropFirst(4).allSatisfy({ (48...57).contains($0) }),
              let info = plist(["info", "-plist", device]) else { return nil }
        return DiskHealthReport(device: device, info: info)
    }

    private static func plist(_ arguments: [String]) -> Record? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? Record
    }

    private static func bytes(_ value: Any?) -> Double? {
        guard let bytes = (value as? NSNumber)?.doubleValue, bytes.isFinite, bytes >= 0 else { return nil }
        return bytes
    }

    private static func filesystem(_ type: String) -> String {
        switch type {
        case "apfs": "APFS"
        case "exfat": "exFAT"
        case "hfs": "HFS+"
        case "msdos": "FAT"
        case "ntfs": "NTFS"
        default: type.isEmpty ? "Unknown" : type.uppercased()
        }
    }

    private static func mountString<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
