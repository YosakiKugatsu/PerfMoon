// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

// SMC key assignments adapted from the MIT-licensed Stats sensor catalog:
// https://github.com/exelban/stats/blob/ed5ac2677fde44fbeee9fcff557228bc7b31a440/Modules/Sensors/values.swift
// See THIRD_PARTY_NOTICES.txt.

enum ThermalSensorCatalog {
    static func sensors(for machine: MachineInfo) -> [String: SensorInfo] {
        let tokens = machine.chipName.split(separator: " ")
        guard tokens.first == "Apple", tokens.count >= 2 else { return [:] }

        let cpu: [String]
        let gpu: [String]
        let m5Super = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]
        let m5Performance = ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        switch tokens[1] {
        case "M1":
            cpu = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
            gpu = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case "M2":
            cpu = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
            gpu = ["Tg0f", "Tg0j"]
        case "M3":
            cpu = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                   "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
            gpu = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case "M4":
            cpu = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
            let base = ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
            gpu = (tokens.count == 2 ? ["Tg0G", "Tg0H"] : ["Tg1U", "Tg1k"]) + base
        case "M5":
            cpu = m5Super + m5Performance
            gpu = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        case "M6":
            cpu = ["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E",
                   "Tp0G", "Tp0b", "Tp05", "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"]
            gpu = ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"]
        case "A18" where tokens.count == 3 && tokens[2] == "Pro":
            cpu = ["Te05", "Te0S", "Tp05", "Tp0D"]
            gpu = ["Tg05", "Tg0D", "Tg0L", "Tg0e"]
        default:
            return [:]
        }

        var known = Dictionary(uniqueKeysWithValues: cpu.map {
            ($0, SensorInfo(id: $0, name: "CPU Sensor \($0)", category: .cpu))
        })
        for (index, key) in gpu.enumerated() {
            known[key] = SensorInfo(id: key, name: "GPU Sensor \(index + 1)", category: .gpu)
        }
        // Family catalogs identify aggregate sensor groups, not the exact core
        // index on every variant. Keep exact core labels only for the verified map.
        if machine.chipName == "Apple M5 Pro",
           let superCluster = machine.cpuTopology.cluster(.s), superCluster.cores.count == m5Super.count,
           let performance = machine.cpuTopology.cluster(.p), performance.cores.count == m5Performance.count {
            for (cluster, keys) in [(superCluster, m5Super), (performance, m5Performance)] {
                for (core, key) in zip(cluster.cores, keys) {
                    known[key] = SensorInfo(id: key, name: "\(cluster.title) \(core.index) Temperature",
                                            category: .cpu, mappedCore: core)
                }
            }
        }
        return known
    }
}
