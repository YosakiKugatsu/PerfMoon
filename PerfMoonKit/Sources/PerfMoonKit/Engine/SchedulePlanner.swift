import Foundation

/// Turns what is on screen into one effective interval per job.
///
/// - Visible primary metrics follow the user's Update Interval.
/// - Background (menu bar, overview history) runs at max(interval, 2 s).
/// - Temperatures run at max(interval, 2 s).
/// - The sensor table preview runs at max(interval, 5 s), only while visible.
/// - PerfMoon's own usage is sampled every 10 s, only while the Performance page is visible.
public enum SchedulePlanner {
    public static let backgroundFloor: TimeInterval = 2
    public static let temperatureFloor: TimeInterval = 2
    public static let catalogFloor: TimeInterval = 5
    public static let selfUsageInterval: TimeInterval = 10

    public static func intervals(userInterval: TimeInterval, demands: Set<Demand>) -> [JobID: TimeInterval] {
        var visible = Set<JobID>()
        for demand in demands {
            switch demand {
            case .popover:
                visible.formUnion(JobID.allCases.filter(\.isPrimary))
            case .window(let page):
                visible.formUnion(page.primaryJobs)
            case .sensorTable, .performancePage, .memoryProcesses:
                break
            }
        }

        var result: [JobID: TimeInterval] = [:]
        for job in JobID.allCases {
            switch job {
            case .temperatures:
                result[job] = max(userInterval, temperatureFloor)
            case .sensorCatalog:
                if demands.contains(.sensorTable) {
                    result[job] = max(userInterval, catalogFloor)
                }
            case .selfUsage:
                if demands.contains(.performancePage) {
                    result[job] = selfUsageInterval
                }
            case .thermal:
                result[job] = max(userInterval, 5)
            case .processMemory:
                if demands.contains(.memoryProcesses) || demands.contains(.window(.memory)) {
                    result[job] = max(userInterval, 5)
                }
            default:
                result[job] = visible.contains(job) ? userInterval : max(userInterval, backgroundFloor)
            }
        }
        return result
    }
}

/// Automatic recovery for transient failures: 1, 2, 4, 8, 16, 30 s, then stop.
public enum RecoveryPolicy {
    public static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    public static var maxAttempts: Int { delays.count }
}
