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
        Preset(value: AVCaptureSession.Preset.vga640x480.rawValue, title: "640 × 480", width: 640, height: 480),
        Preset(value: AVCaptureSession.Preset.hd1280x720.rawValue, title: "1280 × 720", width: 1280, height: 720),
        Preset(value: AVCaptureSession.Preset.hd1920x1080.rawValue, title: "1920 × 1080", width: 1920, height: 1080)
    ]
    public static let frameRates = [24, 30, 60]

    public static func supported(front: Bool, preset: String, fps: Int) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
        let size = self.presets.first(where: { $0.value == preset })
        return discovery.devices.contains { device in
            device.formats.contains { format in
                guard self.isUsable(format, multiCam: false) else { return false }
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if let size, dimensions.width != size.width || dimensions.height != size.height { return false }
                return fps == 0 || format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) })
            }
        }
    }

    private static func isUsable(_ format: AVCaptureDevice.Format, multiCam: Bool) -> Bool {
        guard format.mediaType == .video else { return false }
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
        if #available(iOS 13.0, *), multiCam && !format.isMultiCamSupported { return false }
        return true
    }

    /// Called inside CameraDevice's existing configuration lock and capture-session transaction.
    static func apply(to device: AVCaptureDevice, multiCam: Bool, defaultFPS: Double, settings: WhitegramMediaSettings) -> Double? {
        guard !settings.useTelegramCameraSettings else { return nil }
        let front = device.position == .front
        let rawPreset = front ? settings.frontCameraPreset : settings.backCameraPreset
        let requestedFPS = front ? settings.frontCameraFPS : settings.backCameraFPS
        guard !rawPreset.isEmpty || requestedFPS != 0 else { return nil }
        let preset = self.presets.first(where: { $0.value == rawPreset })
        guard (rawPreset.isEmpty || preset != nil), requestedFPS == 0 || self.frameRates.contains(requestedFPS) else {
            Logger.shared.log("WhitegramCamera", "Unrecognized capture preference; retaining Telegram configuration")
            return nil
        }
        let originalDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let width = preset?.width ?? originalDimensions.width
        let height = preset?.height ?? originalDimensions.height
        let fps = requestedFPS == 0 ? defaultFPS : Double(requestedFPS)
        guard fps.isFinite, fps > 0.0 else { return nil }
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
            Logger.shared.log("WhitegramCamera", "Unsupported capture size/FPS or MultiCam format; retaining Telegram configuration")
            return nil
        }
        let duration = CMTime(seconds: 1.0 / fps, preferredTimescale: 60_000)
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        Logger.shared.log("WhitegramCamera", "Applied \(front ? "front" : "back") \(width)x\(height) at \(fps) fps")
        return fps
    }
}
