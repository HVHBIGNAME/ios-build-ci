import Foundation
import AVFoundation
import TelegramCore

public enum WhitegramCameraConfiguration {
    public struct Preset {
        public let value: String
        public let title: String
        let width: Int32
        let height: Int32
    }

    public static let presets: [Preset] = [
        Preset(value: "4k", title: "4K · 3840 × 2160", width: 3840, height: 2160),
        Preset(value: "1080p", title: "1080p · 1920 × 1080", width: 1920, height: 1080),
        Preset(value: "720p", title: "720p · 1280 × 720", width: 1280, height: 720)
    ]
    public static let frameRates = WhitegramMediaSettings.cameraFrameRates

    private static func singleCamera(front: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = front ? .front : .back
        // Match CameraDevice.configure's actual discovery order. Reporting
        // support on a different physical camera produces unusable choices.
        if #available(iOS 13.0, *), !front {
            let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera]
            for type in types {
                if let device = AVCaptureDevice.default(type, for: .video, position: position) { return device }
            }
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: position).devices.first
    }

    public static func supported(front: Bool, preset: String, fps: Int) -> Bool {
        let preset = WhitegramMediaSettings.canonicalPreset(preset)
        let size = self.presets.first(where: { $0.value == preset }) ?? (preset == "480p" ? Preset(value: "480p", title: "640 × 480", width: 640, height: 480) : nil)
        guard let size, [24, 30, 60].contains(fps), let device = self.singleCamera(front: front) else { return false }
        return device.formats.contains { format in
            // These choices also configure single-camera round sessions. A
            // MultiCam-only probe would hide valid 4K/60 FPS sensor choices.
            // apply(to:) validates the actual session before changing formats.
            guard self.isUsable(format, multiCam: false) else { return false }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == size.width && dimensions.height == size.height && format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) })
        }
    }

    public static var wideAngleAvailable: Bool {
        guard let device = self.singleCamera(front: false) else { return false }
        return self.supportsWideAngle(device)
    }

    static func supportsWideAngle(_ device: AVCaptureDevice) -> Bool {
        guard device.position == .back else { return false }
        if #available(iOS 13.0, *) {
            return device.deviceType == .builtInUltraWideCamera || (device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) && device.minAvailableVideoZoomFactor < device.neutralZoomFactor)
        }
        return false
    }

    private static func isUsable(_ format: AVCaptureDevice.Format, multiCam: Bool) -> Bool {
        guard format.mediaType == .video, format.value(forKey: "isPhotoFormat") as? Bool != true else { return false }
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
        if #available(iOS 13.0, *), multiCam && !format.isMultiCamSupported { return false }
        return true
    }

    /// Called inside CameraDevice's existing configuration lock and capture-session transaction.
    static func apply(to device: AVCaptureDevice, multiCam: Bool, policy: WhitegramMediaSettings.CapturePolicy) -> Double? {
        let width = policy.width
        let height = policy.height
        let fps = Double(policy.fps)
        guard width > 0, width <= 3840, height > 0, height <= 2160, [24, 30, 60].contains(policy.fps) else { return nil }
        let candidates = device.formats.filter { format in
            guard self.isUsable(format, multiCam: multiCam) else { return false }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == width && dimensions.height == height && format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && $0.maxFrameRate >= fps })
        }
        // Keep the original optical field of view when several sensor formats fit the request.
        let format = candidates.min(by: {
            abs($0.videoFieldOfView - device.activeFormat.videoFieldOfView) < abs($1.videoFieldOfView - device.activeFormat.videoFieldOfView)
        })
        guard let format else {
            Logger.shared.log("WhitegramCamera", "Unsupported \(width)x\(height) at \(fps) fps (MultiCam: \(multiCam)); retaining Telegram configuration")
            return nil
        }
        let duration = CMTime(seconds: 1.0 / fps, preferredTimescale: 60_000)
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        Logger.shared.log("WhitegramCamera", "Applied \(device.position == .front ? "front" : "back") \(width)x\(height) at \(fps) fps")
        return fps
    }
}
