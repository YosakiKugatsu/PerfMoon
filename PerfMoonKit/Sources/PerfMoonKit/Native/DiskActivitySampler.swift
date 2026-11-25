// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import IOKit

/// Cache the driver handle and whole-media identity. Each fast tick requests
/// just Statistics, independently of the slow APFS inventory.
final class DiskActivitySampler {
    private final class Device {
        let driver: io_service_t
        let id: UInt64
        let name: String
        var previous: (bytes: TransferCounters?, operations: TransferCounters?, uptime: TimeInterval)?

        init(driver: io_service_t, id: UInt64, name: String) {
            self.driver = driver
            self.id = id
            self.name = name
            IOObjectRetain(driver)
        }
        deinit { IOObjectRelease(driver) }
    }

    private var devices: [Device] = []
    private var nextDiscovery: TimeInterval = 0

    func invalidateDevices() { nextDiscovery = 0 }

    func sample(at time: TimeInterval) -> SampleOutcome {
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime >= nextDiscovery {
            guard discover() else { return .failed(.transient) }
            nextDiscovery = uptime + 30
        }
        var activity: [DiskActivity] = []
        activity.reserveCapacity(devices.count)
        for device in devices {
            let stats = IORegistryEntryCreateCFProperty(device.driver, "Statistics" as CFString, nil, 0)?.takeRetainedValue() as? NSDictionary
            func counters(_ read: String, _ write: String) -> TransferCounters? {
                guard let r = stats?[read] as? NSNumber, let w = stats?[write] as? NSNumber else { return nil }
                return TransferCounters(incoming: r.uint64Value, outgoing: w.uint64Value)
            }
            let bytes = counters("Bytes (Read)", "Bytes (Write)")
            let operations = counters("Operations (Read)", "Operations (Write)")
            let elapsed = device.previous.map { uptime - $0.uptime } ?? 0
            let transfer = bytes?.rates(since: device.previous?.bytes, elapsed: elapsed, at: time, source: .diskActivity)
            let iops = operations?.rates(since: device.previous?.operations, elapsed: elapsed, at: time,
                                         source: .diskActivity, unit: .perSecond)
            device.previous = (bytes, operations, uptime)
            activity.append(DiskActivity(id: device.id, device: device.name,
                                         bytes: transfer ?? TransferRates(status: .unavailable(.unsupported), source: .diskActivity),
                                         operations: iops ?? TransferRates(status: .unavailable(.unsupported), source: .diskActivity, unit: .perSecond)))
        }
        return .diskActivity(activity)
    }

    private func discover() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var found: [Device] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let media = IOIteratorNext(children), media != 0 {
                defer { IOObjectRelease(media) }
                guard IOObjectConformsTo(media, "IOMedia") != 0,
                      IORegistryEntryCreateCFProperty(media, "Whole" as CFString, nil, 0)?.takeRetainedValue() as? Bool == true,
                      let name = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString, nil, 0)?.takeRetainedValue() as? String else { continue }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS else { continue }
                found.append(devices.first { $0.id == id } ?? Device(driver: driver, id: id, name: name))
                // Statistics belong to the driver and can only be counted once.
                break
            }
        }
        devices = found
        return true
    }
}
