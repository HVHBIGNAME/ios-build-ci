import Foundation
import CoreFoundation

public struct WhitegramTransferSettings: Equatable {
    public enum DownloadMode: Int, CaseIterable {
        case telegram = 0
        case conservative = 1
        case balanced = 2
        case maximum = 3
    }

    public let downloadMode: DownloadMode
    public let maxDownloadSpeed: Bool
    public let sendAccelerationEnabled: Bool

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func value(_ key: String) -> Any? {
            return values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)
        }
        func boolean(_ key: String) -> Bool {
            guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        if let number = value("downloadAccelMode") as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           let rawValue = Int(exactly: number.doubleValue), let mode = DownloadMode(rawValue: rawValue) {
            self.downloadMode = mode
        } else {
            self.downloadMode = .telegram
        }
        self.maxDownloadSpeed = boolean("maxDownloadSpeed")
        self.sendAccelerationEnabled = boolean("sendAccelerationEnabled")
    }

    public static var current: WhitegramTransferSettings {
        return WhitegramTransferSettings(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public var usesAcceleratedDownload: Bool {
        return self.downloadMode != .telegram || self.maxDownloadSpeed
    }

    public var downloadParallelParts: Int {
        // Original Core 0x178644, jump table 0xd5f708: explicit modes take
        // precedence over the legacy maximum-speed switch.
        switch self.downloadMode {
        case .telegram: return self.maxDownloadSpeed ? 16 : 6
        case .conservative: return 4
        case .balanced: return 8
        case .maximum: return 16
        }
    }

    public func uploadParallelParts(increaseParallelParts: Bool) -> Int {
        // Original MultipartUploadManager 0x199d00..0x199e00. Telegram's
        // explicit high-parallelism callers keep priority over both switches.
        if increaseParallelParts { return 30 }
        return self.sendAccelerationEnabled || self.maxDownloadSpeed ? 16 : 3
    }

    public static let resetValues: [String: Any] = [
        "downloadAccelMode": 0, "maxDownloadSpeed": false, "sendAccelerationEnabled": false
    ]
}
