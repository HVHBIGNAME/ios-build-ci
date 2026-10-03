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
    public let roundCameraWideAngle: Bool
    public let staticZoomEnabled: Bool
    public let roundVideoBitrate: String

    public struct CapturePolicy: Equatable {
        public let width: Int32
        public let height: Int32
        public let fps: Int
    }

    // Original camera controls: TelegramUI 0xcab938 / 0xcaba64 / 0xcabb30.
    public static let cameraPresets = ["4k", "1080p", "720p"]
    public static let cameraFrameRates = [30, 60]
    public static let roundVideoBitrates = ["low", "medium", "high"]

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
        let quality = number("photoCompressionQuality") ?? 0.7
        self.photoCompressionQuality = quality > 0.0 ? min(1.0, max(0.1, quality)) : 0.7
        self.rememberLastCamera = boolean("rememberLastCamera")
        self.videoMessageCamera = integer("videoMessageCamera").flatMap { (0...2).contains($0) ? $0 : nil }
        // The original getter selects custom mode for installations with any of
        // these six keys but no explicit stock/custom choice (Core 0x200438).
        let customKeys = ["backCameraPreset", "frontCameraPreset", "backCameraFPS", "frontCameraFPS", "roundCameraWideAngle", "roundVideoBitrate"]
        self.useTelegramCameraSettings = boolean("useTelegramCameraSettings", default: !customKeys.contains(where: { value($0) != nil }))
        self.backCameraPreset = Self.canonicalPreset(value("backCameraPreset") as? String)
        self.frontCameraPreset = Self.canonicalPreset(value("frontCameraPreset") as? String)
        func frameRate(_ key: String) -> Int {
            // 24 FPS was offered by the earlier port; keep saved selections.
            guard let fps = integer(key), [24, 30, 60].contains(fps) else { return 30 }
            return fps
        }
        self.backCameraFPS = frameRate("backCameraFPS")
        self.frontCameraFPS = frameRate("frontCameraFPS")
        self.roundCameraWideAngle = boolean("roundCameraWideAngle")
        self.staticZoomEnabled = boolean("staticZoomEnabled")
        let bitrate = (value("roundVideoBitrate") as? String) ?? "medium"
        self.roundVideoBitrate = bitrate.isEmpty ? "medium" : bitrate
    }

    public static var current: WhitegramMediaSettings {
        return WhitegramMediaSettings(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public func photoMaxDimension(hd: Bool) -> Int32 {
        // Original photo-library consumer 0x31ca954: HD OR large -> 2560.
        return hd || self.alwaysSendHD || self.sendLargePhotos ? 2560 : 1280
    }

    public func jpegQuality(default value: Double) -> Double {
        return self.sendLargePhotos ? self.photoCompressionQuality : value
    }

    public var photoQualityPercent: Int32 {
        return Int32((self.photoCompressionQuality * 100.0).rounded())
    }

    public func photoLibraryTargetDimensions(width: Int32?, height: Int32?, hd: Bool) -> (width: Int32, height: Int32) {
        // Honour the compiling baseline's already queued 4096-pixel resources.
        // New large-photo resources use the recovered 2560-pixel policy.
        if let width, let height, (1...4096).contains(width), (1...4096).contains(height) {
            return (width, height)
        }
        let side = self.photoMaxDimension(hd: hd)
        return (side, side)
    }

    public func photoLibraryJPEGQuality(storedQuality: Int32?) -> Float {
        if let quality = storedQuality {
            return Float(min(100, max(10, quality))) / 100.0
        }
        // Applies to normal as well as large photos in the original fetcher.
        return Float(self.photoCompressionQuality)
    }

    public func shouldCompressLibraryVideo(asFile: Bool) -> Bool {
        // Original 0x282f7a0: cleaning disables the raw Photos-library copy.
        return !asFile || self.cleanMetadataOnSend
    }

    public static func canonicalPreset(_ value: String?) -> String {
        switch value {
        case nil, "", "AVCaptureSessionPreset1920x1080": return "1080p"
        case "AVCaptureSessionPreset1280x720": return "720p"
        case "AVCaptureSessionPreset3840x2160": return "4k"
        case "AVCaptureSessionPreset640x480": return "480p" // Earlier port.
        default: return value!
        }
    }

    public var requiresSingleCameraForRoundVideo: Bool {
        // Original 0x28ecbcc. This must affect session creation, not just a
        // format applied after a MultiCam session has already been created.
        return !self.useTelegramCameraSettings && (self.backCameraPreset == "4k" || self.frontCameraPreset == "4k" || self.backCameraFPS > 30 || self.frontCameraFPS > 30 || self.roundCameraWideAngle)
    }

    public func capturePolicy(front: Bool, isRoundVideo: Bool, exclusive: Bool, additional: Bool, preferWide: Bool, preferLowerFramerate: Bool) -> CapturePolicy? {
        guard !self.useTelegramCameraSettings else { return nil }
        let preset = front ? self.frontCameraPreset : self.backCameraPreset
        guard Self.cameraPresets.contains(preset) || preset == "480p" else { return nil }
        let fps: Int
        if additional || preferLowerFramerate {
            fps = 30
        } else {
            let requested = front ? self.frontCameraFPS : self.backCameraFPS
            fps = exclusive ? requested : min(30, requested)
        }
        // Original CameraDeviceContext 0x28e7a1c / 0x28e7c14: round capture,
        // additional camera and wide preview impose their own size/FPS limits.
        if isRoundVideo && exclusive {
            return CapturePolicy(width: 640, height: 480, fps: fps)
        } else if additional || (exclusive && preferWide) {
            return CapturePolicy(width: 1920, height: 1440, fps: fps)
        } else if preset == "4k" && exclusive {
            return CapturePolicy(width: 3840, height: 2160, fps: fps)
        } else if preset == "720p" {
            return CapturePolicy(width: 1280, height: 720, fps: fps)
        } else if preset == "480p" {
            return CapturePolicy(width: 640, height: 480, fps: fps)
        } else {
            return CapturePolicy(width: 1920, height: 1080, fps: fps)
        }
    }

    public var roundVideoBitrateValue: Int? {
        guard !self.useTelegramCameraSettings else { return nil }
        // Original H.264 encoder 0x28f41e4 / 0x28f4b14, in bits/second.
        switch self.roundVideoBitrate {
        case "low": return 500_000
        case "medium": return 1_000_000
        case "high": return 3_000_000
        default: break
        }
        // Preserve bounded numeric selections saved by the compiling baseline.
        guard !self.roundVideoBitrate.isEmpty,
              self.roundVideoBitrate.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(self.roundVideoBitrate), (500_000...8_000_000).contains(value) else { return nil }
        return value
    }

    public static func videoRecordingDimensions(encodedWidth: Int, encodedHeight: Int, portrait: Bool) -> (width: Int, height: Int)? {
        guard (1...4096).contains(encodedWidth), (1...4096).contains(encodedHeight) else { return nil }
        // VideoRecorder rotates the encoded sensor frame for portrait capture.
        // Report that frame's actual size, including 720p and 4K selections.
        return portrait ? (encodedHeight, encodedWidth) : (encodedWidth, encodedHeight)
    }

    public static let resetValues: [String: Any] = [
        "cleanMetadataOnSend": false, "sendLargePhotos": false, "alwaysSendHD": false,
        "photoCompressionQuality": 0.7, "rememberLastCamera": false, "videoMessageCamera": 0,
        "useTelegramCameraSettings": true, "backCameraPreset": "1080p", "frontCameraPreset": "1080p",
        "backCameraFPS": 30, "frontCameraFPS": 30, "roundVideoBitrate": "medium",
        "roundCameraWideAngle": false, "staticZoomEnabled": false
    ]

    public static func rememberCamera(front: Bool) {
        guard Self.current.rememberLastCamera else { return }
        if !WhitegramPreferences.set(front ? 0 : 1, for: "videoMessageCamera") {
            NSLog("Whitegram: could not remember the selected video-message camera")
        }
    }
}
