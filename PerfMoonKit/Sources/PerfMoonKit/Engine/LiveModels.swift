// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation

/// Observable state for one surface (the panel or the main window).
/// It only receives updates while the surface is visible, so hidden views do no work.
@MainActor
@Observable
public final class DashboardModel {
    public private(set) var run: RunState
    /// Time of the latest sample; frozen while paused.
    public private(set) var time: TimeInterval
    public private(set) var cpu: CPUSnapshot
    public private(set) var gpu: GPUSnapshot
    public private(set) var memory: MemorySnapshot
    public private(set) var disk: DiskSnapshot
    public private(set) var diskActivity: [DiskActivity]
    public private(set) var diskActivityStatus: ReadingStatus
    public private(set) var network: NetworkActivity
    public private(set) var diskDrives: [DiskDriveSnapshot]
    public var diskVolumes: [DiskSnapshot] { diskDrives.flatMap(\.volumes) }
    public private(set) var power: PowerSnapshot
    public private(set) var prompt: PanelPrompt?
    public private(set) var historyRevision: Int

    public init(snapshot: MonitorSnapshot) {
        run = snapshot.run
        time = snapshot.time
        cpu = snapshot.cpu
        gpu = snapshot.gpu
        memory = snapshot.memory
        disk = snapshot.disk
        diskActivity = snapshot.diskActivity
        diskActivityStatus = snapshot.diskActivityStatus
        network = snapshot.network
        diskDrives = snapshot.diskDrives
        power = snapshot.power
        prompt = snapshot.prompt
        historyRevision = snapshot.historyRevision
    }

    public func apply(_ snapshot: MonitorSnapshot) {
        if run != snapshot.run { run = snapshot.run }
        if time != snapshot.time { time = snapshot.time }
        if cpu != snapshot.cpu { cpu = snapshot.cpu }
        if gpu != snapshot.gpu { gpu = snapshot.gpu }
        if memory != snapshot.memory { memory = snapshot.memory }
        if disk != snapshot.disk { disk = snapshot.disk }
        if diskActivity != snapshot.diskActivity { diskActivity = snapshot.diskActivity }
        if diskActivityStatus != snapshot.diskActivityStatus { diskActivityStatus = snapshot.diskActivityStatus }
        if network != snapshot.network { network = snapshot.network }
        if diskDrives != snapshot.diskDrives { diskDrives = snapshot.diskDrives }
        if power != snapshot.power { power = snapshot.power }
        if prompt != snapshot.prompt { prompt = snapshot.prompt }
        if historyRevision != snapshot.historyRevision { historyRevision = snapshot.historyRevision }
    }
}

/// Observable state for Settings and the Design Gallery.
@MainActor
@Observable
public final class SupportModel {
    public private(set) var sources: [SourceStatus] = []
    public private(set) var catalog: [SensorReading] = []
    public private(set) var selfUsage = SelfUsage.pending
    public private(set) var intervals: [JobID: TimeInterval] = [:]
    public private(set) var cpuTemperature = MetricReading.pending(.celsius)
    public private(set) var run = RunState(userPaused: false, systemSuspended: false)
    /// Latest snapshot, for previews such as the menu bar glyph.
    public private(set) var snapshot: MonitorSnapshot?

    public init() {}

    public func apply(_ engine: MonitorEngine, includeCatalog: Bool = true) {
        let core = engine.core
        let sources = core.sourceStatuses()
        if sources != self.sources { self.sources = sources }
        if includeCatalog {
            let catalog = core.catalogReadings()
            if catalog != self.catalog { self.catalog = catalog }
        }
        if core.selfUsage != selfUsage { selfUsage = core.selfUsage }
        if core.intervals != intervals { intervals = core.intervals }
        let temperature = engine.snapshot.cpu.temperature
        if temperature != cpuTemperature { cpuTemperature = temperature }
        if engine.snapshot.run != run { run = engine.snapshot.run }
        if engine.snapshot != snapshot { snapshot = engine.snapshot }
    }
}
