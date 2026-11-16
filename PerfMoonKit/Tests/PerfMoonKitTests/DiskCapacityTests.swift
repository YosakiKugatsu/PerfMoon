// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Testing
@testable import PerfMoonKit

@Test("Startup Storage uses its own container and preserves raw APFS allocation")
func startupStorageAccounting() throws {
    let capacity = try #require(DiskSystemCapacity(name: "Macintosh HD", total: 995, free: 279, available: 699))
    let drive = DiskDriveSnapshot(id: "disk0", name: "Internal SSD", isInternal: true,
                                 volumes: [], totalBytes: 1000, availableBytes: 283, at: 1000,
                                 systemCapacity: capacity)
    #expect(drive.totalBytes == 995)
    #expect(drive.available.shownValue == 699)
    #expect(drive.used.shownValue == 296)
    #expect(drive.allocated?.shownValue == 716)
    #expect(drive.reclaimable?.shownValue == 420)
    #expect(drive.used.quality == .estimated)

    let invalid = DiskSystemCapacity(name: "Macintosh HD", total: 995, free: 279, available: 1005)
    #expect(invalid == nil)
    let fallback = DiskDriveSnapshot(id: "disk0", name: "Internal SSD", isInternal: true,
                                    volumes: [], totalBytes: 1000, availableBytes: 283, at: 1000,
                                    systemCapacity: invalid)
    #expect(fallback.used.shownValue == 717)
    #expect(fallback.capacityScopeName == nil)
    #expect(fallback.reclaimable == nil)
}
