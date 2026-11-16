// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The simulated temperature sensor catalog: every category, including non-CPU sensors.
enum FixtureSensors {
    /// Community mapping used by the core matrix (S-Cores then P-Cores).
    static let sCoreKeys = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]
    static let pCoreKeys = ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
    static let gpuKeys = ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg1U", "Tg1k"]
    static let gpuOffsets: [Double] = [0, 1.2, -0.8, 2.1, -1.5, 0.6, 1.8, -0.3]

    static let longNameKey = "TR1B"
    static let ambientKey = "TaTP"

    static let all: [SensorInfo] = {
        var sensors: [SensorInfo] = []
        let cpuKeys = sCoreKeys + pCoreKeys
        for (index, key) in cpuKeys.enumerated() {
            sensors.append(SensorInfo(id: key, name: "CPU Sensor \(index + 1)", category: .cpu, mappedCore: CoreID(flatIndex: index)))
        }
        for (index, key) in gpuKeys.enumerated() {
            sensors.append(SensorInfo(id: key, name: "GPU Sensor \(index + 1)", category: .gpu))
        }
        sensors += [
            SensorInfo(id: "Ts0P", name: "SoC Proximity 1", category: .soc),
            SensorInfo(id: "Ts1P", name: "SoC Proximity 2", category: .soc),
            SensorInfo(id: "TPMP", name: "Power Manager Die", category: .soc),
            SensorInfo(id: "Tm0P", name: "Memory Proximity 1", category: .memory),
            SensorInfo(id: "Tm1P", name: "Memory Proximity 2", category: .memory),
            SensorInfo(id: "TB0T", name: "Battery Gas Gauge", category: .battery),
            SensorInfo(id: "TB1T", name: "Battery Cell 1", category: .battery),
            SensorInfo(id: "TB2T", name: "Battery Cell 2", category: .battery),
            SensorInfo(id: "TH0x", name: "SSD Controller", category: .storage),
            SensorInfo(id: "TH0a", name: "SSD NAND", category: .storage),
            SensorInfo(id: "TaLP", name: "Airflow Left", category: .other),
            SensorInfo(id: "TaRF", name: "Airflow Right", category: .other),
            SensorInfo(id: ambientKey, name: "Ambient Air Intake", category: .other),
            SensorInfo(id: "TW0P", name: "Wireless Module", category: .other),
            SensorInfo(id: longNameKey, name: "Thunderbolt 5 Retimer, Left Rear Port (Controller B) Thermal Diode", category: .other),
        ]
        return sensors
    }()
}
