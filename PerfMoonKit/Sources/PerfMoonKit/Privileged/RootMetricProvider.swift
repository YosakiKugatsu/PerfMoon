// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The window and menu remain in the user's login session. Only native reads
/// cross the private socket, normally as one request/reply per scheduler tick.
@MainActor
public final class RootMetricProvider: MetricProvider {
    public private(set) var machine = MachineInfo(chipName: "Apple Silicon", shortChipName: "Mac",
        gpuCoreCount: 0, physicalMemory: 0, cpuTopology: CPUTopology(logicalCPUCount: 0))
    public private(set) var sensors: [SensorInfo] = []
    public private(set) var throttleStatus = ThrottleStatus.unavailable
    public private(set) var gpuThrottleStatus = ThrottleStatus.unavailable
    public private(set) var processMemory = ProcessMemorySnapshot()
    public var isLive: Bool { true }
    public var preparesBatches: Bool { true }
    public var isRootConnected: Bool { channel?.isConnected == true }
    private let executable: URL
    private var channel: CollectorChannel?
    private var networkInterfaces: [NetworkInterfaceInfo] = []
    private var results: [JobID: SampleOutcome] = [:]
    private var lastConnectionAttempt = -Double.infinity
    private var opened: Set<SourceID> = []

    public init(executable: URL) {
        self.executable = executable
        connectIfPermitted()
    }

    private func connectIfPermitted() {
        guard !isRootConnected else { return }
        lastConnectionAttempt = ProcessInfo.processInfo.systemUptime
        if let new = try? CollectorChannel.launch(executable: executable, allowDialog: false) { adopt(new) }
    }

    /// Keep the UI responsive while SecurityAgent obtains authorization.
    public func authorize() async {
        guard !isRootConnected else { return }
        let executable = executable
        let new = await Task.detached(priority: .userInitiated) {
            try? CollectorChannel.launch(executable: executable, allowDialog: true)
        }.value
        if let new, !isRootConnected { adopt(new) }
    }

    private func adopt(_ new: CollectorChannel) {
        guard let identity = new.call(.identify), identity.uid == 0, let machine = identity.machine else { return }
        self.machine = machine
        sensors = identity.sensors ?? []
        results.removeAll()
        networkInterfaces = []
        channel = new
        for source in opened {
            _ = new.call(.open(source, MonitorEngine.now))
        }
    }

    public func open(_ source: SourceID, at time: TimeInterval) -> OpenResult {
        if !isRootConnected, ProcessInfo.processInfo.systemUptime - lastConnectionAttempt >= 2 {
            connectIfPermitted()
        }
        guard let channel else { return .failed(.permissionDenied) }
        guard channel.isConnected else { return .failed(.transient) }
        guard let reply = channel.call(.open(source, time)), let result = reply.opened else { return .failed(.transient) }
        if result == .opened { opened.insert(source) }
        if let sensors = reply.sensors { self.sensors = sensors }
        return result
    }

    public func close(_ source: SourceID) {
        guard opened.remove(source) != nil else { return }
        _ = channel?.call(.close(source))
        if source == .processMemory { processMemory = ProcessMemorySnapshot() }
        if source == .thermal { throttleStatus = .unavailable; gpuThrottleStatus = .unavailable }
    }

    public func rebaseline(_ source: SourceID, at time: TimeInterval) {
        _ = channel?.call(.baseline(source, time))
    }

    public func invalidateDiskDevices() {
        _ = channel?.call(.volumesChanged)
    }

    public func diskHealth(for device: String) async -> DiskHealthReport? {
        guard let channel, channel.isConnected else { return nil }
        return await Task.detached(priority: .utility) {
            channel.call(.diskHealth(device), timeout: 10)?.diskHealth
        }.value
    }

    private func sampleBatch(_ requests: [JobID: SampleRequest], at time: TimeInterval) -> [JobID: SampleOutcome] {
        guard let reply = channel?.call(.sample(requests, time)), var outcomes = reply.outcomes else {
            return requests.mapValues { _ in .failed(.transient) }
        }
        if let interfaces = reply.networkInterfaces { networkInterfaces = interfaces }
        if case .network(var network) = outcomes[.network] {
            network.interfaces = networkInterfaces
            outcomes[.network] = .network(network)
        }
        if let status = reply.cpuThrottle { throttleStatus = status }
        if let status = reply.gpuThrottle { gpuThrottleStatus = status }
        return outcomes
    }

    public func prepare(_ requests: [JobID: SampleRequest], at time: TimeInterval) {
        results = sampleBatch(requests, at: time)
    }

    public func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome {
        if let outcome = results.removeValue(forKey: job) { return outcome }
        return sampleBatch([job: request], at: time)[job] ?? .failed(.transient)
    }

    public var diskBackgroundSample: (@Sendable (Double) -> SampleOutcome)? {
        guard let channel else { return nil }
        return { time in channel.call(.disks(time), timeout: 30)?.outcomes?[.disk] ?? .failed(.transient) }
    }

    public var processBackgroundSample: (@MainActor (Double, Bool) async -> ProcessMemorySnapshot)? {
        guard let channel else { return nil }
        return { [weak self] time, rates in
            let snapshot = await Task.detached(priority: .utility) {
                channel.call(.processes(time, rates))?.processes ?? ProcessMemorySnapshot(status: .unavailable(.retrying))
            }.value
            if !Task.isCancelled { self?.processMemory = snapshot }
            return snapshot
        }
    }

    public func diagnosticUsage(at time: TimeInterval, window: TimeInterval) -> SelfUsage {
        channel?.call(.overhead(time, window, diagnostics: true))?.usage ?? .pending
    }

    public func selfUsage(at time: TimeInterval, window: TimeInterval) -> SelfUsage? {
        channel?.call(.overhead(time, window, diagnostics: false))?.usage ?? SelfUsage.pending
    }
}
