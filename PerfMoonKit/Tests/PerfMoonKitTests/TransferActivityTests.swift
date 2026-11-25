// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Testing
import Foundation
@testable import PerfMoonKit

@Suite("Transfer and process activity")
struct TransferActivityTests {
    @Test("Range totals clip boundary samples, exclude gaps, and distinguish idle from missing data")
    func periodTotals() throws {
        var data = TransferHistory()
        data.append(TransferRates(incoming: 20, outgoing: 10, at: 10, window: 5, source: .network))
        data.append(TransferRates(status: .unavailable(.interfaceDisconnected), source: .network))
        data.append(TransferRates(incoming: 100, outgoing: 0, at: 23, window: 3, source: .network))
        data.append(TransferRates(incoming: 900, outgoing: 900, at: 23, window: 1, source: .network))
        let slice = try #require(data.total(from: 7, to: 22))
        #expect(slice.incoming == 260 && slice.outgoing == 30 && slice.recordedSeconds == 5)
        #expect(data.total(from: 10, to: 20) == nil)
        data.append(TransferRates(incoming: 0, outgoing: 0, at: 28, window: 5, source: .network))
        let idle = try #require(data.total(from: 23, to: 28))
        #expect(idle.incoming == 0 && idle.outgoing == 0 && idle.recordedSeconds == 5)
    }

    @Test("Six-hour totals retain every burst after chart decimation and expire old transfers")
    func sixHourTransfers() throws {
        var data = TransferHistory()
        for second in 1...44_000 {
            data.append(TransferRates(incoming: second.isMultiple(of: 7) ? 5_000_000 : 0, outgoing: 45,
                                      at: Double(second), window: 1, source: .diskActivity))
        }
        for range in TimeRange.allCases {
            let lower = 44_000 - range.rawValue
            let total = try #require(data.total(from: Double(lower), to: 44_000))
            #expect(total.incoming == Double((44_000 / 7 - lower / 7) * 5_000_000))
            #expect(total.outgoing == range.seconds * 45)
            #expect(total.recordedSeconds == range.seconds)
        }
        #expect(data.total(from: 1, to: 2) == nil)
    }

    @Test("SMART reports preserve device-specific data and both halves of NVMe counters")
    func diskHealth() throws {
        let info: [String: Any] = ["DeviceIdentifier": "disk4", "WholeDisk": true, "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["TEMPERATURE": 310, "DATA_UNITS_READ_0": 17,
                "DATA_UNITS_READ_1": 1, "Vendor": ["Status": "OK"], "MEDIA_ERRORS_0": 0]]
        let report = try #require(DiskHealthReport(device: "disk4", info: info))
        #expect(report.status == "Verified" && report.attributes["Vendor.Status"] == "OK")
        #expect(report.counter("DATA_UNITS_READ") == (UInt128(1) << 64) + 17)
        #expect(report.counter("MEDIA_ERRORS") == 0 && report.counter("POWER_CYCLES") == nil)
        #expect(abs((report.temperatureCelsius ?? 0) - 36.85) < 0.001)
        #expect(DiskHealthReport(device: "disk5", info: info) == nil)
        let unsupported = try #require(DiskHealthReport(device: "disk4", info: ["DeviceIdentifier": "disk4", "WholeDisk": true]))
        #expect(unsupported.status == nil && unsupported.attributes.isEmpty)
    }
    @Test("Rates use measured time, distinguish idle from baseline, and restart when the interface resets")
    func deltas() {
        let base = TransferCounters(incoming: 6_000_000_000, outgoing: 7_000_000_000)
        let next = TransferCounters(incoming: 6_000_012_000, outgoing: 7_000_006_000)
        let result = next.rates(since: base, elapsed: 1.5, at: 10, source: .network)
        #expect(result.incoming.value == 8000)
        #expect(result.outgoing.value == 4000)
        #expect(result.incoming.window == 1.5)
        #expect(base.rates(since: next, elapsed: 1, at: 11, source: .network).incoming.status == .warming)
        #expect(next.rates(since: nil, elapsed: 0, at: 11, source: .network).outgoing.shownValue == nil)
        #expect(next.rates(since: next, elapsed: 1, at: 11, source: .network).outgoing.shownValue == 0)
        let rollover = UInt64(UInt32.max) + 1
        let across = TransferCounters(incoming: rollover + 1024, outgoing: 2 * rollover + 128)
            .rates(since: TransferCounters(incoming: rollover - 1024, outgoing: 2 * rollover - 128),
                   elapsed: 2, at: 12, source: .network)
        #expect(across.incoming.value == 1024 && across.outgoing.value == 128)
    }

    @Test("A VPN default selects its physical service, never an unrelated or offline link")
    func primaryLink() {
        let links = [
            NetworkInterfaceInfo(id: "en4", index: 5, name: "Ethernet", isHardware: true),
            NetworkInterfaceInfo(id: "en0", index: 6, name: "Wi-Fi", isHardware: true),
            NetworkInterfaceInfo(id: "utun2", index: 12, name: "Tunnel", isHardware: false),
        ]
        #expect(NetworkActivitySampler.primaryInterface(interfaces: links, globals: ["utun2"], routed: ["en0", "en4"]) == "en0")
        #expect(NetworkActivitySampler.primaryInterface(interfaces: links, globals: ["en4"], routed: ["en0"]) == "en4")
        #expect(NetworkActivitySampler.primaryInterface(interfaces: links, globals: ["utun2"], routed: ["en9"]) == nil)
    }

    @Test("PID reuse never inherits CPU or I/O, and multithreaded work may exceed one core")
    func processIdentity() {
        let old = ProcessCounters(start: 42, cpu: 2400, read: 700, written: 1000)
        let new = ProcessCounters(start: 42, cpu: 4700, read: 5060, written: 6500)
        var row = ProcessMemoryEntry(pid: 23, name: "", memoryBytes: 0)
        new.applyRates(to: &row, since: old, ticks: 1000, seconds: 2)
        #expect(abs(row.cpuPercent - 230) < 0.001)
        #expect(row.readBytesPerSecond == 2180)
        #expect(row.writeBytesPerSecond == 2750)
        let reused = ProcessCounters(start: 101, cpu: 5200, read: 9000, written: 7500)
        var replacement = ProcessMemoryEntry(pid: 23, name: "", memoryBytes: 0)
        reused.applyRates(to: &replacement, since: new, ticks: 1000, seconds: 2)
        #expect(replacement.cpuPercent == 0 && replacement.writeBytesPerSecond == 0)
    }

    @MainActor
    @Test("Optional collectors follow their last consumer; per-core power closes even on pause")
    func lifecycle() {
        let provider = FixtureProvider()
        let core = MonitorCore(provider: provider)
        core.start(now: 100)
        #expect(core.intervals[.diskActivity] == nil && core.intervals[.network] == nil && core.intervals[.corePower] == nil)
        core.setDemand(.menuNetwork, active: true, now: 100)
        core.setDemand(.popover, active: true, now: 100)
        #expect(core.intervals[.diskActivity] == nil)
        core.setDemand(.panelDiskActivity, active: true, now: 100)
        core.setDemand(.panelCorePower, active: true, now: 100)
        core.tick(now: 100)
        core.tick(now: 101)
        #expect(core.snapshot(now: 101).cpu.corePowers.allSatisfy { $0.shownValue != nil })
        #expect(core.history.last(.diskActivity(1, .readIOPS)) != nil)
        #expect(core.history.count(.networkDownload) > 0)
        #expect(core.history.transferTotal(for: .disk(1), from: 99, to: 101)?.incoming ?? 0 > 0)
        #expect(core.history.transferTotal(for: .network, from: 99, to: 101)?.incoming ?? 0 > 0)
        core.setNetworkInterface("utun2", now: 101.2)
        #expect(core.history.count(.networkDownload) == 0)
        #expect(core.history.transferTotal(for: .network, from: 99, to: 101.2) == nil)
        core.tick(now: 102)
        #expect(core.snapshot(now: 102).network.selected?.id == "utun2")
        core.setUserPaused(true, now: 103)
        #expect(!provider.openSources.contains(.corePower))
        core.setUserPaused(false, now: 110)
        core.tick(now: 110)
        #expect(core.snapshot(now: 110).cpu.corePowers.first?.status == .warming)
        core.setDemand(.popover, active: false, now: 111)
        #expect(core.intervals[.corePower] == nil && core.intervals[.diskActivity] == nil)
        #expect(core.intervals[.network] == 2)
        core.setDemand(.menuNetwork, active: false, now: 112)
        #expect(!provider.openSources.contains(.network))
    }
}
