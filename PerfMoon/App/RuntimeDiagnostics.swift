// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PerfMoonKit

/// Opt-in QA capture, disabled in ordinary builds/launches. Records the actual visible
/// surfaces alongside external CPU/footprint samples so mixed sessions aren't mislabeled.
@MainActor
final class RuntimeDiagnostics {
    private var output: FileHandle?
    private var lastTime = -Double.infinity
    private var lastMode = ""
    private var usage = SelfUsageSampler()
    private var written = 0
    var isEnabled: Bool { output != nil }

    init() {
        guard let path = ProcessInfo.processInfo.environment["PERFMOON_DIAGNOSTICS_PATH"] else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        output = try? FileHandle(forWritingTo: url)
        _ = try? output?.seekToEnd()
    }

    func record(_ engine: MonitorEngine, settingsTab: String?, details: [String: Any] = [:]) {
        guard let output, written < 8 * 1024 * 1024 else { return }
        let demands = engine.core.demands.map { demand in
            switch demand {
            case .popover: "panel"
            case .window(let page): "window:\(page.rawValue)"
            case .sensorTable: "sensors"
            case .performancePage: "selfUsage"
            case .memoryProcesses: "processes"
            case .windowMemoryProcesses: "windowProcesses"
            case .coreHistory: "coreHistory"
            }
        }.sorted()
        let mode = demands.joined(separator: ",") + "/" + (settingsTab ?? "") + "/\(engine.core.userPaused)/\(engine.core.systemSuspended)"
        let now = MonitorEngine.now
        guard mode != lastMode || now - lastTime >= 10 else { return }
        let cost = usage.sample(at: now, window: now - lastTime)
        lastTime = now; lastMode = mode
        let coreHistoryKeys = engine.history.recordedKeys.filter(\.isPerCore)
        var object: [String: Any] = [
            "epoch": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier,
            "demands": demands, "settings": settingsTab as Any? ?? NSNull(),
            "paused": engine.core.userPaused, "suspended": engine.core.systemSuspended,
            "samples": engine.core.sampleCount, "wakes": engine.wakeCount,
            "footprintBytes": cost.footprint.value ?? 0,
            "requestedInterval": engine.core.userInterval,
            "intervals": Dictionary(uniqueKeysWithValues: engine.core.intervals.map { ($0.key.rawValue, $0.value) }),
            "coreHistorySeries": coreHistoryKeys.count,
            "coreHistorySamples": coreHistoryKeys.reduce(0) { $0 + engine.history.count($1) },
            "processTimestamp": engine.snapshot.memory.processes.timestamp as Any? ?? NSNull(),
            "processRows": engine.snapshot.memory.processes.entries.count,
        ]
        if let cpu = cost.cpu.value { object["cpuOneCorePercent"] = cpu }
        object.merge(details) { _, value in value }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? output.write(contentsOf: data + Data([10]))
            written += data.count + 1
        }
    }
}
