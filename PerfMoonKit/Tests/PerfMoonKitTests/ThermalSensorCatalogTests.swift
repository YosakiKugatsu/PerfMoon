// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Testing
@testable import PerfMoonKit

@Suite("Apple silicon temperature catalog")
struct ThermalSensorCatalogTests {
    private func machine(_ chip: String, topology: CPUTopology = .init(logicalCPUCount: 10)) -> MachineInfo {
        MachineInfo(chipName: chip, shortChipName: chip, gpuCoreCount: 0, physicalMemory: 0,
                    cpuTopology: topology)
    }

    @Test("Standard M5 gets temperature groups without inheriting M5 Pro's per-core assignments")
    func standardM5() {
        let base = ThermalSensorCatalog.sensors(for: machine("Apple M5"))
        #expect(base["Tp00"]?.category == .cpu)
        #expect(base["Tg0U"]?.category == .gpu)
        #expect(base.values.allSatisfy { $0.mappedCore == nil })

        let verified = ThermalSensorCatalog.sensors(for: machine("Apple M5 Pro", topology: .fixture))
        #expect(verified["Tp00"]?.mappedCore?.label == "S0")
        #expect(verified["Tp0y"]?.mappedCore?.label == "P11")

        let smaller = ThermalSensorCatalog.sensors(for: machine("Apple M5 Pro", topology: .init(logicalCPUCount: 15)))
        #expect(smaller["Tp00"]?.category == .cpu)
        #expect(smaller.values.allSatisfy { $0.mappedCore == nil })
    }

    @Test("Distinguishes known chip generations and does not assign unknown keys by prefix")
    func familyMatching() {
        let m3 = ThermalSensorCatalog.sensors(for: machine("Apple M3 Max"))
        #expect(m3["Tf04"]?.category == .cpu)
        #expect(m3["Tf14"]?.category == .gpu)
        #expect(m3["Tg0U"] == nil)
        #expect(ThermalSensorCatalog.sensors(for: machine("Apple A18 Pro"))["Tg05"]?.category == .gpu)
        #expect(ThermalSensorCatalog.sensors(for: machine("Apple M50")).isEmpty)
    }
}
