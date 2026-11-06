import Foundation

/// Everything the simulated Mac reports at one instant.
struct FixtureWorld: Sendable {
    var cores: [Double]
    var sMean: Double
    var pMean: Double
    var total: Double
    var sFrequency: Double
    var pFrequency: Double
    var gpuUsage: Double
    var gpuFrequency: Double
    var cpuPower: Double
    var gpuPower: Double
    var anePower: Double
    var powerInput: Double
    var powerSystem: Double
    var powerBattery: Double
    var batteryState: BatteryChargeState
    var adapterConnected: Bool
    var memory: [MetricKey: Double]
    var pressure: MemoryPressureLevel
    var temperatures: [String: Double]

    func cpuTemperature(for source: TemperatureSource) -> Double? {
        switch source {
        case .cpuMax:
            return FixtureSensors.all.filter { $0.category == .cpu }.compactMap { temperatures[$0.id] }.max()
        case .cpuAverage:
            let values = FixtureSensors.all.filter { $0.category == .cpu }.compactMap { temperatures[$0.id] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        case .sensor(let id):
            return temperatures[id]
        }
    }

    var gpuTemperature: Double? {
        FixtureSensors.gpuKeys.compactMap { temperatures[$0] }.max()
    }
}

/// Pure, seeded functions of time. No randomness is drawn per redraw.
struct FixtureModel: Sendable {
    let scenario: FixtureScenario
    /// When the scenario was applied; scripted transitions are relative to it.
    let anchor: TimeInterval
    let noise: SmoothNoise

    init(scenario: FixtureScenario, anchor: TimeInterval) {
        self.scenario = scenario
        self.anchor = anchor
        self.noise = SmoothNoise(seed: scenario.seed)
    }

    // MARK: Load

    func clusterLoad(_ cluster: CoreCluster, _ t: Double) -> Double {
        let channel: UInt64 = cluster == .s ? 1 : 2
        let isS = cluster == .s
        switch scenario.load {
        case .idle:
            return isS
                ? 3.2 + 2.2 * noise.fbm(channel, t, period: 30) + 9 * noise.burst(channel + 10, t, period: 41, threshold: 0.72)
                : 1.8 + 1.2 * noise.fbm(channel, t, period: 34) + 4 * noise.burst(channel + 10, t, period: 47, threshold: 0.72)
        case .light:
            return isS
                ? 9 + 6 * noise.fbm(channel, t, period: 30) + 22 * noise.burst(channel + 10, t, period: 29)
                : 4 + 3 * noise.fbm(channel, t, period: 34) + 9 * noise.burst(channel + 10, t, period: 37)
        case .typical:
            return isS
                ? 22 + 14 * noise.fbm(channel, t, period: 40) + 48 * noise.burst(channel + 10, t, period: 26)
                : 8 + 5 * noise.fbm(channel, t, period: 45) + 16 * noise.burst(channel + 10, t, period: 33)
        case .heavy:
            return isS ? 93 + 6 * noise.fbm(channel, t, period: 25) : 89 + 8 * noise.fbm(channel, t, period: 28)
        case .extreme:
            return isS ? 97 + 3 * noise.fbm(channel, t, period: 25) : 95 + 4 * noise.fbm(channel, t, period: 28)
        case .singleCore:
            return 0
        }
    }

    func coreLoads(_ t: Double) -> [Double] {
        if scenario.load == .singleCore {
            return CoreID.all.map { $0.flatIndex == 0 ? 100 : 0 }
        }
        let s = clusterLoad(.s, t)
        let p = clusterLoad(.p, t)
        let jitter: Double
        switch scenario.load {
        case .idle: jitter = 1.1
        case .light: jitter = 2
        case .heavy, .extreme: jitter = 3
        default: jitter = 4
        }
        var result: [Double] = []
        result.reserveCapacity(CoreID.count)
        for core in CoreID.all {
            let base = core.cluster == .s ? s : p
            let index = Double(core.index)
            let weight: Double
            switch scenario.load {
            case .heavy, .extreme:
                weight = 1.0 - 0.012 * index
            default:
                weight = core.cluster == .s ? 1.38 - 0.13 * index : 1.5 - 0.075 * index
            }
            let channel = UInt64(100 + core.flatIndex)
            let wobble = 1 + 0.3 * noise.fbm(channel, t, period: 9)
            let shake = jitter * noise.smooth(channel &+ 50, t, period: 2.3)
            result.append(clamp(base * weight * wobble + shake, 0, 100))
        }
        return result
    }

    func gpuLoad(_ t: Double) -> Double {
        let channel: UInt64 = 3
        let value: Double
        switch scenario.load {
        case .idle: value = 1.5 + 1.2 * noise.fbm(channel, t, period: 20) + 6 * noise.burst(channel + 10, t, period: 37, threshold: 0.8)
        case .light: value = 5 + 4 * noise.fbm(channel, t, period: 20) + 15 * noise.burst(channel + 10, t, period: 31)
        case .typical: value = 14 + 10 * noise.fbm(channel, t, period: 24) + 40 * noise.burst(channel + 10, t, period: 28, threshold: 0.45)
        case .heavy: value = 86 + 9 * noise.fbm(channel, t, period: 18)
        case .extreme: value = 96 + 3 * noise.fbm(channel, t, period: 18)
        case .singleCore: value = 1.8 + 1 * noise.fbm(channel, t, period: 20)
        }
        return clamp(value, 0, 100)
    }

    func anePower(_ t: Double) -> Double {
        let channel: UInt64 = 4
        switch scenario.load {
        case .idle, .light, .singleCore:
            return 0
        case .typical:
            return 2.4 * noise.burst(channel, t, period: 19, threshold: 0.55)
        case .heavy:
            return 1.6 + 0.9 * (noise.fbm(channel, t, period: 15) + 1)
        case .extreme:
            return 7.4 + 0.5 * noise.fbm(channel, t, period: 15)
        }
    }

    // MARK: Memory

    func pressureIntensity(_ t: Double) -> Double {
        let age = anchor - t
        func ramp(_ start: Double, _ end: Double) -> Double {
            clamp((start - age) / (start - end), 0, 1)
        }
        switch scenario.memory {
        case .normal: return 0
        case .warning: return ramp(370, 350)
        case .critical: return ramp(560, 540) + ramp(260, 240)
        }
    }

    func memory(_ t: Double) -> (values: [MetricKey: Double], level: MemoryPressureLevel) {
        let intensity = pressureIntensity(t)
        // wired, app, compressed, cached, purgeable, swap in GiB
        let normal: [Double] = [4.3, 21.5, 1.2, 19.4, 1.6, 0]
        let warning: [Double] = [5.0, 40.8, 11.9, 4.6, 0.35, 2.3]
        let critical: [Double] = [5.3, 44.4, 13.6, 0.55, 0.04, 11.4]
        let mixed: [Double]
        if intensity <= 1 {
            mixed = zip(normal, warning).map { $0 + ($1 - $0) * intensity }
        } else {
            mixed = zip(warning, critical).map { $0 + ($1 - $0) * (intensity - 1) }
        }
        let gib = 1024.0 * 1024 * 1024
        let wired = mixed[0] + 0.12 * noise.fbm(20, t, period: 90)
        let app = mixed[1] + 0.9 * noise.fbm(21, t, period: 150)
        let compressed = max(0.05, mixed[2] + 0.25 * noise.fbm(22, t, period: 120))
        let cached = max(0.2, mixed[3] + 0.4 * noise.fbm(23, t, period: 110))
        let purgeable = min(cached, max(0, mixed[4] + 0.1 * noise.fbm(24, t, period: 100)))
        let used = wired + app + compressed
        let free = max(0.12, 64 - used - cached)
        let swap = mixed[5] > 0.01 ? mixed[5] + 0.15 * noise.fbm(25, t, period: 200) : 0

        let level: MemoryPressureLevel = intensity < 0.5 ? .normal : (intensity < 1.5 ? .warning : .critical)
        let stress = min(intensity, 2) / 2
        let pageIns = intensity < 0.05
            ? 30 + 180 * noise.burst(26, t, period: 21)
            : 650 * stress * 2 + 300 * noise.fbm(26, t, period: 12)
        let pageOuts = intensity < 0.05 ? 0 : max(0, 2200 * stress * stress + 250 * noise.fbm(27, t, period: 11))
        let swapIns = intensity < 0.05 ? 0 : max(0, 280 * stress * stress + 40 * noise.fbm(28, t, period: 13))
        let swapOuts = intensity < 0.05 ? 0 : max(0, 680 * stress * stress + 80 * noise.fbm(29, t, period: 13))

        return ([
            .memoryUsed: used * gib,
            .memoryApp: app * gib,
            .memoryWired: wired * gib,
            .memoryCompressed: compressed * gib,
            .memoryCached: cached * gib,
            .memoryPurgeable: purgeable * gib,
            .memoryReusable: min(app, max(0, app * 0.28)) * gib,
            .memoryFree: free * gib,
            .swapUsed: swap * gib,
            .pageIns: max(0, pageIns),
            .pageOuts: pageOuts,
            .swapIns: swapIns,
            .swapOuts: swapOuts,
        ], level)
    }

    // MARK: World

    func world(at t: Double) -> FixtureWorld {
        let cores = coreLoads(t)
        let sMean = cores[0..<CoreID.sCount].reduce(0, +) / Double(CoreID.sCount)
        let pMean = cores[CoreID.sCount...].reduce(0, +) / Double(CoreID.pCount)
        let total = cores.reduce(0, +) / Double(CoreID.count)
        let sMax = cores[0..<CoreID.sCount].max() ?? 0
        let pMax = cores[CoreID.sCount...].max() ?? 0

        let sFrequency = min(4.51, 1.26 + 3.25 * (0.65 * (sMax / 100).squareRoot() + 0.35 * (sMean / 100).squareRoot()) + 0.03 * noise.smooth(30, t, period: 3))
        let pFrequency = min(3.62, 1.05 + 2.55 * (0.65 * (pMax / 100).squareRoot() + 0.35 * (pMean / 100).squareRoot()) + 0.03 * noise.smooth(31, t, period: 3))
        let gpu = gpuLoad(t)
        let gpuFrequency = 0.338 + 1.24 * (gpu / 100).squareRoot()

        let boost = scenario.load == .extreme
        var cpuPower = 0.16 + sMean / 100 * 26.5 + pMean / 100 * 12.5 + 0.08 * noise.smooth(32, t, period: 2)
        var gpuPower = 0.05 + gpu / 100 * 20 + 0.05 * noise.smooth(33, t, period: 2)
        if boost {
            cpuPower *= 1.9
            gpuPower *= 2.3
        }
        cpuPower = max(0.05, cpuPower)
        gpuPower = max(0.02, gpuPower)
        let ane = anePower(t)
        let system = 6.4 + cpuPower + gpuPower + ane + 1.4 + 1.2 * noise.fbm(34, t, period: 18)

        var input: Double
        var battery: Double
        var state: BatteryChargeState
        var adapter = true
        switch scenario.power {
        case .charging:
            battery = 23.5 + 3 * noise.fbm(35, t, period: 120)
            input = system + battery + 2.2 + 0.4 * noise.fbm(36, t, period: 9)
            state = .charging
        case .fastCharging:
            battery = 46 + 4 * noise.fbm(35, t, period: 120)
            input = system + battery + 3.4 + 0.5 * noise.fbm(36, t, period: 9)
            state = .charging
        case .discharging:
            input = 57.6 + 0.7 * noise.fbm(36, t, period: 9)
            battery = max(0.5, system + 1.5 - input * 0.97)
            state = .discharging
        case .notCharging:
            input = system + 0.8 + 0.3 * noise.fbm(36, t, period: 9)
            battery = max(0.05, 0.14 + 0.07 * noise.fbm(35, t, period: 30))
            state = .notCharging
        case .noAdapter:
            input = 0
            battery = system + 0.35
            state = .discharging
            adapter = false
        case .highPower:
            battery = 9.6 + 0.8 * noise.fbm(35, t, period: 60)
            input = min(139.5, system + battery + 4.1)
            state = .charging
        }

        let memory = memory(t)
        let temperatures = temperatures(t, cores: cores, gpu: gpu, total: total)

        return FixtureWorld(
            cores: cores, sMean: sMean, pMean: pMean, total: total,
            sFrequency: sFrequency, pFrequency: pFrequency,
            gpuUsage: gpu, gpuFrequency: gpuFrequency,
            cpuPower: cpuPower, gpuPower: gpuPower, anePower: ane,
            powerInput: input, powerSystem: system, powerBattery: battery,
            batteryState: state, adapterConnected: adapter,
            memory: memory.values, pressure: memory.level,
            temperatures: temperatures
        )
    }

    private func temperatures(_ t: Double, cores: [Double], gpu: Double, total: Double) -> [String: Double] {
        // Thermal inertia: temperatures follow the load of the last ~10 seconds.
        var lagged = cores
        var laggedGPU = gpu
        for step in 1...3 {
            let past = coreLoads(t - Double(step) * 3)
            for index in lagged.indices { lagged[index] += past[index] }
            laggedGPU += gpuLoad(t - Double(step) * 3)
        }
        lagged = lagged.map { $0 / 4 }
        laggedGPU /= 4
        let laggedTotal = lagged.reduce(0, +) / Double(lagged.count)
        let hot: Double = (scenario.load == .heavy || scenario.load == .extreme) ? 2 : 0

        var result: [String: Double] = [:]
        let cpuKeys = FixtureSensors.sCoreKeys + FixtureSensors.pCoreKeys
        for (index, key) in cpuKeys.enumerated() {
            result[key] = 33.5 + 0.56 * lagged[index] + 1.1 * noise.fbm(UInt64(300 + index), t, period: 17) + hot
        }
        for (index, key) in FixtureSensors.gpuKeys.enumerated() {
            result[key] = 32.5 + 0.42 * laggedGPU + FixtureSensors.gpuOffsets[index] + 0.8 * noise.fbm(UInt64(400 + index), t, period: 15)
        }
        result["Ts0P"] = 35.5 + 0.3 * laggedTotal + 0.15 * laggedGPU
        result["Ts1P"] = 37.3 + 0.3 * laggedTotal + 0.15 * laggedGPU
        result["TPMP"] = 38 + 0.12 * laggedTotal + 0.6 * noise.fbm(410, t, period: 40)
        let pressureHeat = 3.5 * min(1, pressureIntensity(t))
        result["Tm0P"] = 33.8 + 0.08 * laggedTotal + pressureHeat
        result["Tm1P"] = 34.9 + 0.08 * laggedTotal + pressureHeat

        let batteryBase: Double
        switch scenario.power {
        case .charging: batteryBase = 32.6
        case .fastCharging: batteryBase = 34.8
        case .discharging: batteryBase = 31.6
        case .highPower: batteryBase = 33.0
        case .notCharging, .noAdapter: batteryBase = 29.4
        }
        let batteryNoise = 0.5 * noise.fbm(420, t, period: 120)
        result["TB0T"] = batteryBase + batteryNoise
        result["TB1T"] = batteryBase + 0.6 + batteryNoise
        result["TB2T"] = batteryBase + 0.3 + batteryNoise
        result["TH0x"] = 34 + 3 * noise.fbm(430, t, period: 90)
        result["TH0a"] = 31 + 2 * noise.fbm(431, t, period: 90)
        result["TaLP"] = 29.5 + 0.1 * laggedTotal
        result["TaRF"] = 30.2 + 0.1 * laggedTotal
        result[FixtureSensors.ambientKey] = scenario == .negativeTemperature
            ? -20.2 + 0.3 * noise.fbm(440, t, period: 60)
            : 26.8 + 0.4 * noise.fbm(440, t, period: 60)
        result["TW0P"] = 37.5 + 1.2 * noise.fbm(441, t, period: 50)
        result[FixtureSensors.longNameKey] = 45.6 + 1.4 * noise.fbm(442, t, period: 50)
        return result
    }
}
