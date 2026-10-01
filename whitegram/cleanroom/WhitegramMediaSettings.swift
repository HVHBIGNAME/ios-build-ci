import Foundation
import CoreFoundation

public struct WhitegramMediaSettings: Equatable {
    public let cleanMetadataOnSend: Bool
    public let sendLargePhotos: Bool
    public let alwaysSendHD: Bool
    public let photoCompressionQuality: Double
    public let rememberLastCamera: Bool
    public let videoMessageCamera: Int?
    public let useTelegramCameraSettings: Bool
    public let backCameraPreset: String
    public let frontCameraPreset: String
    public let backCameraFPS: Int
    public let frontCameraFPS: Int
    public let roundVideoBitrate: String

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func value(_ key: String) -> Any? {
            return values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)
        }
        func boolean(_ key: String, default fallback: Bool = false) -> Bool {
            guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
            return number.boolValue
        }
        func number(_ key: String) -> Double? {
            guard let number = value(key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        func integer(_ key: String) -> Int? {
            return number(key).flatMap(Int.init(exactly:))
        }
        self.cleanMetadataOnSend = boolean("cleanMetadataOnSend")
        self.sendLargePhotos = boolean("sendLargePhotos")
        self.alwaysSendHD = boolean("alwaysSendHD")
        self.photoCompressionQuality = min(1.0, max(0.1, number("photoCompressionQuality") ?? 0.8))
        self.rememberLastCamera = boolean("rememberLastCamera")
        self.videoMessageCamera = integer("videoMessageCamera")
        self.useTelegramCameraSettings = boolean("useTelegramCameraSettings", default: true)
        self.backCameraPreset = (value("backCameraPreset") as? String) ?? ""
        self.frontCameraPreset = (value("frontCameraPreset") as? String) ?? ""
        self.backCameraFPS = integer("backCameraFPS") ?? 0
        self.frontCameraFPS = integer("frontCameraFPS") ?? 0
        self.roundVideoBitrate = (value("roundVideoBitrate") as? String) ?? ""
    }

    public static var current: WhitegramMediaSettings {
        return WhitegramMediaSettings(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public func photoMaxDimension(hd: Bool) -> Int32 {
        // 4096 and the quality range are this port's explicit large-photo policy.
        if self.sendLargePhotos { return 4096 }
        return hd || self.alwaysSendHD ? 2560 : 1280
    }

    public func jpegQuality(default value: Double) -> Double {
        return self.sendLargePhotos ? self.photoCompressionQuality : value
    }

    public var roundVideoBitrateValue: Int? {
        guard !self.useTelegramCameraSettings,
              !self.roundVideoBitrate.isEmpty,
              self.roundVideoBitrate.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(self.roundVideoBitrate), (500_000...8_000_000).contains(value) else { return nil }
        return value
    }

    public static let resetValues: [String: Any] = [
        "cleanMetadataOnSend": false, "sendLargePhotos": false, "alwaysSendHD": false,
        "photoCompressionQuality": 0.8, "rememberLastCamera": false,
        "useTelegramCameraSettings": true, "backCameraPreset": "", "frontCameraPreset": "",
        "backCameraFPS": 0, "frontCameraFPS": 0, "roundVideoBitrate": ""
    ]

    public static func rememberCamera(front: Bool) {
        guard Self.current.rememberLastCamera else { return }
        if !WhitegramPreferences.set(front ? 0 : 1, for: "videoMessageCamera") {
            NSLog("Whitegram: could not remember the selected video-message camera")
        }
    }
}
