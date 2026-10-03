import Foundation
import CoreFoundation

public enum WhitegramContentLocation {
    public struct Coordinate: Equatable {
        public let latitude: Double
        public let longitude: Double
    }

    private static func number(_ key: String, values: [String: Any]) -> Double? {
        guard let value = values[key] ?? UserDefaults.standard.object(forKey: "wg_" + key) else { return 0.0 }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    public static var configured: Coordinate? {
        let values = WhitegramPreferences.values()
        guard let latitude = number("fakeLat", values: values), let longitude = number("fakeLon", values: values),
            (-90.0 ... 90.0).contains(latitude), (-180.0 ... 180.0).contains(longitude),
            latitude != 0.0 || longitude != 0.0 else { return nil }
        // Original LocationMapNode treats only the pair (0, 0) as unconfigured.
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    public static var effective: Coordinate? {
        return WhitegramContentSettings.bool("fakeLocationEnabled") ? configured : nil
    }

    @discardableResult
    public static func set(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite,
            (-90.0 ... 90.0).contains(latitude), (-180.0 ... 180.0).contains(longitude) else { return false }
        return WhitegramPreferences.update(["fakeLat": latitude, "fakeLon": longitude])
    }
}
