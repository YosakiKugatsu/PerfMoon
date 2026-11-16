// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import PerfMoonNative

/// Owns native resources. Access is serialized by the provider's MainActor.
/// Read work is bounded; source discovery and key metadata are cached.
private final class NativeResources: @unchecked Sendable {
    var smc: OpaquePointer?
    var report: OpaquePointer?
    var battery: io_service_t = 0
    let host = mach_host_self()
    deinit {
        pm_smc_close(smc)
        pm_report_close(report)
        if battery != 0 { IOObjectRelease(battery) }
        mach_port_deallocate(mach_task_self_, host)
    }
}

@MainActor
public final class NativeMetricProvider: MetricProvider {
    public let machine: MachineInfo
    public private(set) var sensors: [SensorInfo] = []
    public private(set) var throttleStatus: ThrottleStatus = .normal
    public private(set) var gpuThrottleStatus: ThrottleStatus = .unavailable
    public private(set) var processMemory = ProcessMemorySnapshot()
    public var isLive: Bool { true }

    private let resources = NativeResources()
    private var opened: Set<SourceID> = []
    private var cpuUsage: CPUUsageAccumulator
    private var previousMemory: (time: TimeInterval, ins: UInt64, outs: UInt64, swapIns: UInt64, swapOuts: UInt64)?
    private var reportNeedsRebuild = false
    private var lastThrottleEvidence: TimeInterval = -.infinity
    private var lastGPUThrottleEvidence: TimeInterval = -.infinity
    private var lastGPUThrottleSample: TimeInterval = -.infinity
    private var gpuThrottleValidity: TimeInterval = 6
    private var names: [Int32: (start: UInt64, name: String)] = [:]
    private var temperatureTick: TimeInterval?
    private var temperatureValues: [String: Double?] = [:]
    private let reusableMIB: [Int32]? = {
        var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var count = mib.count
        guard sysctlnametomib("vm.page_reusable_count", &mib, &count) == 0 else { return nil }
        return Array(mib.prefix(count))
    }()
    private let recordTimings: Bool
    public private(set) var maximumSampleMilliseconds: [JobID: Double] = [:]

    private static let reportSources: Set<SourceID> = [.cpuFrequency, .energy, .gpuActivity]

    public init(recordTimings: Bool = false) {
        self.recordTimings = recordTimings
        let chip = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let topology = Self.discoverCPUTopology()
        machine = MachineInfo(chipName: chip, shortChipName: chip.replacingOccurrences(of: "Apple ", with: ""),
                              gpuCoreCount: Self.gpuCoreCount(), physicalMemory: Double(ProcessInfo.processInfo.physicalMemory),
                              cpuTopology: topology)
        cpuUsage = CPUUsageAccumulator(topology: topology)
        resources.smc = pm_smc_open()
        discoverSensors()
    }

    public func open(_ source: SourceID, at time: TimeInterval) -> OpenResult {
        if Self.reportSources.contains(source) {
            if reportNeedsRebuild {
                pm_report_close(resources.report)
                resources.report = nil
                reportNeedsRebuild = false
            }
            if resources.report == nil {
                var roles: UInt32 = 0
                for cluster in machine.cpuTopology.clusters {
                    switch cluster.role {
                    case .e: roles |= UInt32(PM_REPORT_CPU_FREQUENCY_E)
                    case .s: roles |= UInt32(PM_REPORT_CPU_FREQUENCY_S)
                    case .p: roles |= UInt32(PM_REPORT_CPU_FREQUENCY_P)
                    }
                }
                resources.report = pm_report_open(roles)
            }
            guard let report = resources.report else { return .failed(.transient) }
            let capabilities = pm_report_capabilities(report)
            let required: UInt32
            switch source {
            case .cpuFrequency: required = UInt32(PM_REPORT_CPU_FREQUENCY_E | PM_REPORT_CPU_FREQUENCY_S | PM_REPORT_CPU_FREQUENCY_P)
            case .gpuActivity: required = UInt32(PM_REPORT_GPU_ACTIVITY | PM_REPORT_GPU_FREQUENCY)
            case .energy: required = UInt32(PM_REPORT_CPU_POWER | PM_REPORT_GPU_POWER | PM_REPORT_ANE_POWER)
            default: required = 0
            }
            guard capabilities & required != 0 else { return .failed(.unsupported) }
        }
        if source == .sensors {
            if resources.smc == nil { resources.smc = pm_smc_open() }
            guard resources.smc != nil else { return .failed(.transient) }
            if sensors.isEmpty { discoverSensors() }
        }
        if source == .battery {
            if resources.battery == 0 { resources.battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")) }
            guard resources.battery != 0 else { return .failed(.unsupported) }
        }
        opened.insert(source)
        rebaseline(source, at: time)
        return .opened
    }

    public func close(_ source: SourceID) {
        opened.remove(source)
        if Self.reportSources.contains(source), opened.isDisjoint(with: Self.reportSources) {
            pm_report_close(resources.report); resources.report = nil
            lastGPUThrottleSample = -.infinity
            gpuThrottleStatus = .unavailable
        }
        if source == .sensors {
            pm_smc_close(resources.smc); resources.smc = nil
            temperatureTick = nil; temperatureValues.removeAll(keepingCapacity: true)
        }
        if source == .battery, resources.battery != 0 { IOObjectRelease(resources.battery); resources.battery = 0 }
        if source == .cpuActivity { cpuUsage.reset() }
        if source == .memory { previousMemory = nil }
        if source == .processMemory {
            processMemory = ProcessMemorySnapshot()
            names.removeAll()
        }
    }

    public func rebaseline(_ source: SourceID, at time: TimeInterval) {
        if source == .cpuActivity { cpuUsage.reset() }
        if source == .memory { previousMemory = nil }
        // A shared IOReport connection coalesces frequency/energy/GPU reads.
        if Self.reportSources.contains(source) { pm_report_rebaseline(resources.report) }
    }

    public func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome {
        let start = recordTimings ? ProcessInfo.processInfo.systemUptime : 0
        defer {
            if recordTimings {
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                maximumSampleMilliseconds[job] = max(maximumSampleMilliseconds[job] ?? 0, elapsed)
            }
        }
        switch job {
        case .cpuActivity: return sampleCPU()
        case .cpuFrequency, .energy, .gpuActivity: return sampleReport(job)
        case .temperatures, .sensorCatalog:
            var values: [MetricKey: Double] = [:]
            for key in request.sensorIDs {
                if let value = temperature(key, at: time) { values[.sensor(key)] = value }
            }
            return values.isEmpty && !request.sensorIDs.isEmpty ? .failed(.transient) : .values(values)
        case .powerSensors:
            var values: [MetricKey: Double] = [:]
            if let value = smc("PSTR"), value >= 0 { values[.powerSystem] = value }
            if let value = smc("PDTR"), value >= 0 { values[.powerInput] = value }
            if let value = smc("PPBR") { values[.powerBattery] = abs(value) }
            return values.isEmpty ? .failed(.transient) : .values(values)
        case .battery: return sampleBattery()
        case .memory: return sampleMemory()
        case .disk: return .noNewData // The scheduler runs diskBackgroundSample off the main actor.
        case .memoryPressure:
            var value: Int32 = 0
            var size = MemoryLayout.size(ofValue: value)
            guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .failed(.unsupported) }
            let level: Double = value == 4 ? 2 : (value == 2 ? 1 : 0)
            return .values([.memoryPressure: level])
        case .thermal:
            sampleThermal()
            return .values([:])
        case .processMemory:
            sampleProcesses(at: time)
            return .values([:])
        case .selfUsage: return .values([:])
        }
    }

    private func sampleCPU() -> SampleOutcome {
        var cpuCount: natural_t = 0
        var data: processor_info_array_t?
        var dataCount: mach_msg_type_number_t = 0
        let result = host_processor_info(resources.host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &data, &dataCount)
        guard result == KERN_SUCCESS, let data else { return .failed(.transient) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: data)), vm_size_t(dataCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        guard cpuCount > 0, Int(dataCount) == Int(cpuCount) * 4 else { return .failed(.transient) }
        let time = ProcessInfo.processInfo.systemUptime
        guard let usage = cpuUsage.sample(UnsafeBufferPointer(start: data, count: Int(dataCount)), cpuCount: Int(cpuCount), at: time) else { return .noNewData }
        var values: [MetricKey: Double] = [.cpuTotal: usage.total]
        var unsupported: Set<MetricKey> = []
        values.reserveCapacity(4 + usage.cores.count)
        if let e = usage.eCore { values[.cpuE] = e } else { unsupported.insert(.cpuE) }
        if let s = usage.sCore { values[.cpuS] = s } else { unsupported.insert(.cpuS) }
        if let p = usage.pCore { values[.cpuP] = p } else { unsupported.insert(.cpuP) }
        if usage.cores.isEmpty {
            unsupported.formUnion(machine.cpuTopology.cores.map { .core($0.flatIndex) })
        }
        for (index, value) in usage.cores.enumerated() { values[.core(index)] = value }
        return unsupported.isEmpty ? .measured(values, window: usage.window)
            : .measuredPartial(values, window: usage.window, unsupported: unsupported)
    }

    private func sampleReport(_ job: JobID) -> SampleOutcome {
        guard let report = resources.report else { return .failed(.transient) }
        var sample = PMReportValues()
        let result = pm_report_read(report, &sample)
        guard result >= 0 else {
            reportNeedsRebuild = true
            return .failed(.transient)
        }
        guard result > 0 else { return .noNewData }
        if sample.cpu_throttle_active > 0 { lastThrottleEvidence = ProcessInfo.processInfo.systemUptime }
        if sample.valid & UInt32(PM_REPORT_GPU_THROTTLE) != 0 {
            let now = ProcessInfo.processInfo.systemUptime
            lastGPUThrottleSample = now
            gpuThrottleValidity = max(6, 3 * sample.elapsed_seconds)
            if sample.gpu_throttle_active > 0 { lastGPUThrottleEvidence = now }
        }
        let capabilities = pm_report_capabilities(report)
        let metrics: [(MetricKey, Int, Double)]
        switch job {
        case .cpuFrequency:
            metrics = [(.cpuFrequencyE, PM_REPORT_CPU_FREQUENCY_E, sample.e_ghz),
                       (.cpuFrequencyS, PM_REPORT_CPU_FREQUENCY_S, sample.s_ghz),
                       (.cpuFrequencyP, PM_REPORT_CPU_FREQUENCY_P, sample.p_ghz)]
        case .energy:
            metrics = [(.cpuPower, PM_REPORT_CPU_POWER, sample.cpu_watts),
                       (.gpuPower, PM_REPORT_GPU_POWER, sample.gpu_watts),
                       (.anePower, PM_REPORT_ANE_POWER, sample.ane_watts)]
        case .gpuActivity:
            metrics = [(.gpuUsage, PM_REPORT_GPU_ACTIVITY, sample.gpu_percent),
                       (.gpuFrequency, PM_REPORT_GPU_FREQUENCY, sample.gpu_ghz)]
        default: return .failed(.unsupported)
        }
        var values: [MetricKey: Double] = [:]
        var unsupported: Set<MetricKey> = []
        for (key, bit, value) in metrics {
            let flag = UInt32(bit)
            if sample.valid & flag != 0 { values[key] = value }
            else if capabilities & flag == 0 || sample.unavailable & flag != 0 { unsupported.insert(key) }
        }
        guard !values.isEmpty || unsupported.count == metrics.count else { return .failed(.transient) }
        return .measuredPartial(values, window: sample.elapsed_seconds, unsupported: unsupported)
    }

    private func sampleMemory() -> SampleOutcome {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(resources.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return .failed(.transient) }
        let page = Double(getpagesize())
        let wired = Double(vm.wire_count) * page
        let compressed = Double(vm.compressor_page_count) * page
        let cache = Double(vm.external_page_count + vm.purgeable_count) * page
        let resident = (Double(vm.active_count) + Double(vm.inactive_count) + Double(vm.speculative_count)) * page
        let app = max(0, resident - cache)
        let used = min(machine.physicalMemory, app + wired + compressed)
        var values: [MetricKey: Double] = [
            .memoryUsed: used, .memoryApp: app, .memoryWired: wired, .memoryCompressed: compressed,
            .memoryCached: cache, .memoryPurgeable: Double(vm.purgeable_count) * page,
            .memoryFree: Double(vm.free_count) * page,
        ]
        if var mib = reusableMIB {
            // XNU exposes this unsigned page counter through SYSCTL_INT.
            var pages: UInt32 = 0
            var size = MemoryLayout<UInt32>.size
            if sysctl(&mib, u_int(mib.count), &pages, &size, nil, 0) == 0, size == MemoryLayout<UInt32>.size {
                values[.memoryReusable] = Double(pages) * page
            }
        }
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { values[.swapUsed] = Double(swap.xsu_used) }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousMemory.map { now - $0.time } ?? 0
        if let previousMemory, elapsed > 0 {
            func rate(_ current: UInt64, _ previous: UInt64) -> Double { current >= previous ? Double(current - previous) / elapsed : 0 }
            values[.pageIns] = rate(vm.pageins, previousMemory.ins)
            values[.pageOuts] = rate(vm.pageouts, previousMemory.outs)
            values[.swapIns] = rate(vm.swapins, previousMemory.swapIns)
            values[.swapOuts] = rate(vm.swapouts, previousMemory.swapOuts)
        }
        previousMemory = (now, vm.pageins, vm.pageouts, vm.swapins, vm.swapouts)
        return .measured(values, window: elapsed)
    }

    private func batteryProperty(_ key: String) -> Any? {
        guard resources.battery != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(resources.battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func sampleBattery() -> SampleOutcome {
        guard let connected = batteryProperty("ExternalConnected") as? Bool,
              let charging = batteryProperty("IsCharging") as? Bool else { return .failed(.transient) }
        let amperage = (batteryProperty("InstantAmperage") as? NSNumber)?.int64Value ?? 0
        let state: BatteryChargeState
        if charging { state = .charging }
        else if !connected || amperage < -10 { state = .discharging }
        else { state = .notCharging }
        return .values([.adapterConnected: connected ? 1 : 0, .batteryState: Double(state.rawValue)])
    }

    private func sampleThermal() {
        var dictionary: Unmanaged<CFDictionary>?
        var limit: Double?
        if IOPMCopyCPUPowerStatus(&dictionary) == kIOReturnSuccess,
           let dictionary = dictionary?.takeRetainedValue() as? [String: Any] {
            limit = ["CPU_Speed_Limit", "CPU_Scheduler_Limit"].compactMap { (dictionary[$0] as? NSNumber)?.doubleValue }.min()
        }
        let recent = ProcessInfo.processInfo.systemUptime - lastThrottleEvidence < 6
        throttleStatus = ThermalPolicy.evaluate(thermalState: ProcessInfo.processInfo.thermalState.rawValue, cpuLimitPercent: limit, hardwareThrottleRecent: recent)
        let now = ProcessInfo.processInfo.systemUptime
        gpuThrottleStatus = ThermalPolicy.evaluateGPU(
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            hardwareThrottleRecent: now - lastGPUThrottleEvidence < 6,
            hardwareAvailable: now - lastGPUThrottleSample < gpuThrottleValidity
        )
    }

    private func sampleProcesses(at time: TimeInterval) {
        let capacity = max(256, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { processMemory = ProcessMemorySnapshot(status: .unavailable(.retrying)); return }
        var usage: [(pid: Int32, bytes: UInt64, start: UInt64)] = []
        var inaccessible = 0
        usage.reserveCapacity(Int(count))
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if result == 0 && info.ri_phys_footprint > 0 { usage.append((pid, info.ri_phys_footprint, info.ri_proc_start_abstime)) }
            else if result != 0 && (errno == EPERM || errno == EACCES) { inaccessible += 1 }
        }
        let top = usage.sorted { $0.bytes > $1.bytes }.prefix(10)
        let topIDs = Set(top.map(\.pid)); names = names.filter { topIDs.contains($0.key) }
        let entries = top.map { item -> ProcessMemoryEntry in
            let name: String
            if let cached = names[item.pid], cached.start == item.start { name = cached.name }
            else { name = Self.processName(item.pid); names[item.pid] = (item.start, name) }
            return ProcessMemoryEntry(pid: item.pid, name: name, memoryBytes: Double(item.bytes))
        }
        processMemory = ProcessMemorySnapshot(entries: entries, status: .valid, timestamp: time, inaccessibleProcessCount: inaccessible)
    }

    private static func processName(_ pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let value = Self.decodeCString(path)
            return URL(fileURLWithPath: value).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &name, UInt32(name.count)) > 0 { return Self.decodeCString(name) }
        return "Process \(pid)"
    }

    private func smc(_ key: String) -> Double? {
        var value = 0.0
        return pm_smc_read(resources.smc, key, &value) ? value : nil
    }

    /// Temperature summary and the sensor table share readings in the same scheduler
    /// tick. Both failures and values are cached; the next tick always reads afresh.
    private func temperature(_ key: String, at time: TimeInterval) -> Double? {
        if temperatureTick != time {
            temperatureTick = time
            temperatureValues.removeAll(keepingCapacity: true)
        }
        if let cached = temperatureValues[key] { return cached }
        let value = smc(key).flatMap { (-40...150).contains($0) ? $0 : nil }
        temperatureValues[key] = .some(value)
        return value
    }

    private func discoverSensors() {
        guard let smc = resources.smc else { return }
        // The catalog only labels actual keys exposed by this hardware.
        let known = ThermalSensorCatalog.sensors(for: machine)
        var found: [SensorInfo] = []
        for index in 0..<pm_smc_key_count(smc) {
            var bytes = [CChar](repeating: 0, count: 5)
            guard pm_smc_key_at(smc, index, &bytes), bytes[0] == 84 else { continue }
            let key = Self.decodeCString(bytes)
            guard key.hasPrefix("T"), key.utf8.count == 4 else { continue }
            found.append(known[key] ?? SensorInfo(id: key, name: "Temperature \(key)", category: .other))
        }
        sensors = found.sorted {
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &data, &size, nil, 0) == 0 else { return nil }
        return decodeCString(data)
    }

    private static func cpuSysctlCount(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size,
              value > 0 else { return nil }
        return Int(value)
    }

    private static func discoverCPUTopology() -> CPUTopology {
        let total = cpuSysctlCount("hw.logicalcpu_max") ?? ProcessInfo.processInfo.processorCount
        let fallback = CPUTopology(logicalCPUCount: total)
        guard let tierCount = cpuSysctlCount("hw.nperflevels"), tierCount <= CoreCluster.allCases.count else { return fallback }
        var levels: [(name: String?, count: Int)] = []
        for level in 0..<tierCount {
            let key = "hw.perflevel\(level)"
            guard let count = cpuSysctlCount("\(key).logicalcpu_max") ?? cpuSysctlCount("\(key).logicalcpu") else { return fallback }
            levels.append((sysctlString("\(key).name"), count))
        }
        // These IDs describe the kernel slots; device-tree traversal order by
        // itself does not tell us which index Mach uses for a particular tier.
        let node = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard node != 0 else { return fallback }
        defer { IOObjectRelease(node) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(node, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return fallback }
        defer { IOObjectRelease(iterator) }
        var seen: [Int: String] = [:]
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard let number = IORegistryEntryCreateCFProperty(child, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                  let raw = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { continue }
            let tag = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            guard seen.updateValue(tag, forKey: number.intValue) == nil else { return fallback }
        }
        return CPUTopology(logicalCPUCount: total, performanceLevels: levels, firmwareTypes: seen)
    }

    private static func decodeCString(_ data: [CChar]) -> String {
        String(decoding: data.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func gpuCoreCount() -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber { return value.intValue }
        }
        return 0
    }
}


extension NativeMetricProvider {
    public var diskBackgroundSample: (@Sendable (Double) -> SampleOutcome)? {
        { StartupVolumes.sample(at: $0) }
    }
}
