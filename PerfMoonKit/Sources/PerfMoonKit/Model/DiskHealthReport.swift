// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// One read-only diskutil snapshot. Keep device-specific fields, including keys
/// unknown to this build, so the full SMART report can be inspected.
public struct DiskHealthReport: Codable, Sendable {
    public let device: String
    public let model: String?
    public let status: String?
    public let bus: String?
    public let readAt: Date
    public let attributes: [String: String]

    init?(device: String, info: [String: Any], at time: Date = Date()) {
        guard info["DeviceIdentifier"] as? String == device, info["WholeDisk"] as? Bool == true else { return nil }
        self.device = device
        model = info["MediaName"] as? String
        status = info["SMARTStatus"] as? String
        bus = info["BusProtocol"] as? String
        readAt = time
        var fields: [String: String] = [:]
        func collect(_ key: String, _ value: Any) {
            switch value {
            case let nested as [String: Any]:
                for (child, item) in nested { collect(key.isEmpty ? child : "\(key).\(child)", item) }
            case let array as [Any]:
                for (index, item) in array.enumerated() { collect("\(key)[\(index)]", item) }
            case let data as Data: fields[key] = data.map { String(format: "%02x", $0) }.joined()
            default: fields[key] = String(describing: value)
            }
        }
        for (key, value) in info where key != "SMARTStatus" &&
            (key.localizedCaseInsensitiveContains("smart") || key.localizedCaseInsensitiveContains("health")) {
            collect(key == "SMARTDeviceSpecificKeysMayVaryNotGuaranteed" ? "" : key, value)
        }
        attributes = fields
    }

    public var temperatureCelsius: Double? {
        // Only interpret this vendor-specific field as kelvin on an NVMe health log.
        guard attributes["DATA_UNITS_READ_0"] != nil || attributes["AVAILABLE_SPARE_THRESHOLD"] != nil,
              let raw = attributes["TEMPERATURE"], let kelvin = UInt16(raw), kelvin > 0, kelvin < .max else { return nil }
        return Double(kelvin) - 273.15
    }

    /// diskutil exports NVMe's little-endian 128-bit counters as two 64-bit words.
    public func counter(_ name: String) -> UInt128? {
        if let raw = attributes[name], let count = UInt128(raw) { return count }
        func word(_ raw: String) -> UInt64? { UInt64(raw) ?? Int64(raw).map(UInt64.init(bitPattern:)) }
        guard let rawLow = attributes[name + "_0"], let low = word(rawLow) else { return nil }
        guard let rawHigh = attributes[name + "_1"] else { return UInt128(low) }
        guard let high = word(rawHigh) else { return nil }
        return UInt128(high) << 64 | UInt128(low)
    }
}
