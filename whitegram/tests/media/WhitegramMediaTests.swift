import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import TelegramCore
import LocalMediaResources

final class WhitegramMediaTests: XCTestCase {
    func testRecoveredDefaultsAndBoundedOverrides() {
        let defaults = WhitegramMediaSettings(values: [:])
        XCTAssertEqual(defaults.photoMaxDimension(hd: false), 1280)
        XCTAssertEqual(defaults.photoMaxDimension(hd: true), 2560)
        XCTAssertEqual(defaults.jpegQuality(default: 0.6), 0.6)
        XCTAssertTrue(defaults.useTelegramCameraSettings)
        XCTAssertNil(defaults.roundVideoBitrateValue)
        XCTAssertEqual(defaults.photoCompressionQuality, 0.7)
        XCTAssertEqual(defaults.photoQualityPercent, 70)
        XCTAssertEqual(defaults.backCameraPreset, "1080p")
        XCTAssertEqual(defaults.frontCameraPreset, "1080p")
        XCTAssertEqual(defaults.backCameraFPS, 30)
        XCTAssertEqual(defaults.frontCameraFPS, 30)
        XCTAssertEqual(defaults.roundVideoBitrate, "medium")
        XCTAssertFalse(defaults.roundCameraWideAngle)
        XCTAssertFalse(defaults.staticZoomEnabled)
        let custom = WhitegramMediaSettings(values: ["sendLargePhotos": true, "photoCompressionQuality": 0.9, "useTelegramCameraSettings": false, "roundVideoBitrate": "2000000"])
        XCTAssertEqual(custom.photoMaxDimension(hd: false), 2560)
        XCTAssertEqual(custom.jpegQuality(default: 0.6), 0.9)
        XCTAssertEqual(custom.roundVideoBitrateValue, 2_000_000)
        let invalid = WhitegramMediaSettings(values: ["sendLargePhotos": 1, "photoCompressionQuality": Double.nan, "useTelegramCameraSettings": false, "roundVideoBitrate": "99999999999999999999"])
        XCTAssertFalse(invalid.sendLargePhotos)
        XCTAssertEqual(invalid.photoCompressionQuality, 0.7)
        XCTAssertNil(invalid.roundVideoBitrateValue)
        XCTAssertEqual(WhitegramMediaSettings(values: ["photoCompressionQuality": 0]).photoCompressionQuality, 0.7)
        XCTAssertEqual(WhitegramMediaSettings(values: ["photoCompressionQuality": 5]).photoCompressionQuality, 1.0)
        XCTAssertEqual(WhitegramMediaSettings(values: ["photoCompressionQuality": 0.01]).photoCompressionQuality, 0.1)
        XCTAssertEqual(WhitegramMediaSettings(values: ["backCameraFPS": true]).backCameraFPS, 30)
        XCTAssertEqual(WhitegramMediaSettings(values: ["backCameraFPS": 59.9]).backCameraFPS, 30)
        XCTAssertEqual(WhitegramMediaSettings(values: ["frontCameraFPS": Int.max]).frontCameraFPS, 30)
        XCTAssertNil(WhitegramMediaSettings(values: ["videoMessageCamera": 3]).videoMessageCamera)
    }

    func testOriginalCameraMigrationAndEarlierPortSelectionsArePreserved() throws {
        let suite = "whitegram-media-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("4k", forKey: "wg_backCameraPreset")
        defaults.set(60, forKey: "wg_backCameraFPS")
        defaults.set(true, forKey: "wg_roundCameraWideAngle")
        let migrated = WhitegramMediaSettings(values: [:], legacyDefaults: defaults)
        XCTAssertFalse(migrated.useTelegramCameraSettings)
        XCTAssertEqual(migrated.backCameraPreset, "4k")
        XCTAssertEqual(migrated.backCameraFPS, 60)
        XCTAssertTrue(migrated.roundCameraWideAngle)
        let canonical = WhitegramMediaSettings(values: ["useTelegramCameraSettings": true, "backCameraFPS": 30], legacyDefaults: defaults)
        XCTAssertTrue(canonical.useTelegramCameraSettings)
        XCTAssertEqual(canonical.backCameraFPS, 30)
        let oldPort = WhitegramMediaSettings(values: ["backCameraPreset": "AVCaptureSessionPreset640x480", "frontCameraPreset": "AVCaptureSessionPreset1280x720", "backCameraFPS": 24, "roundVideoBitrate": "8000000"])
        XCTAssertEqual(oldPort.backCameraPreset, "480p")
        XCTAssertEqual(oldPort.frontCameraPreset, "720p")
        XCTAssertEqual(oldPort.backCameraFPS, 24)
        XCTAssertEqual(oldPort.roundVideoBitrateValue, 8_000_000)
        XCTAssertEqual(WhitegramMediaSettings.canonicalPreset("AVCaptureSessionPreset3840x2160"), "4k")
    }

    func testStockModeMigrationChecksEachOriginalKeyAndPreservesCameraChoice() throws {
        let suite = "whitegram-camera-keys-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalKeys: [(String, Any)] = [
            ("backCameraPreset", "1080p"), ("frontCameraPreset", "1080p"),
            ("backCameraFPS", 30), ("frontCameraFPS", 30),
            ("roundCameraWideAngle", false), ("roundVideoBitrate", "medium")
        ]
        for (key, value) in originalKeys {
            defaults.set(value, forKey: "wg_" + key)
            XCTAssertFalse(WhitegramMediaSettings(values: [:], legacyDefaults: defaults).useTelegramCameraSettings, key)
            XCTAssertTrue(WhitegramMediaSettings(values: ["useTelegramCameraSettings": true], legacyDefaults: defaults).useTelegramCameraSettings, key)
            defaults.removeObject(forKey: "wg_" + key)
            XCTAssertFalse(WhitegramMediaSettings(values: [key: value]).useTelegramCameraSettings, key)
        }
        defaults.set(1, forKey: "wg_videoMessageCamera")
        defaults.set(true, forKey: "wg_rememberLastCamera")
        let legacy = WhitegramMediaSettings(values: [:], legacyDefaults: defaults)
        XCTAssertTrue(legacy.useTelegramCameraSettings)
        XCTAssertEqual(legacy.videoMessageCamera, 1)
        XCTAssertTrue(legacy.rememberLastCamera)
        XCTAssertEqual(WhitegramMediaSettings(values: ["videoMessageCamera": 2], legacyDefaults: defaults).videoMessageCamera, 2)
        let reset = WhitegramMediaSettings(values: WhitegramMediaSettings.resetValues, legacyDefaults: defaults)
        XCTAssertTrue(reset.useTelegramCameraSettings)
        XCTAssertEqual(reset.videoMessageCamera, 0)
        XCTAssertFalse(reset.rememberLastCamera)
    }

    func testCameraCaptureLimitsMatchModeAndSelectedSide() throws {
        let settings = WhitegramMediaSettings(values: ["useTelegramCameraSettings": false, "frontCameraPreset": "4k", "frontCameraFPS": 60, "backCameraPreset": "720p", "backCameraFPS": 30])
        let front = try XCTUnwrap(settings.capturePolicy(front: true, isRoundVideo: false, exclusive: true, additional: false, preferWide: false, preferLowerFramerate: false))
        XCTAssertEqual(front.width, 3840)
        XCTAssertEqual(front.height, 2160)
        XCTAssertEqual(front.fps, 60)
        let back = try XCTUnwrap(settings.capturePolicy(front: false, isRoundVideo: false, exclusive: true, additional: false, preferWide: false, preferLowerFramerate: false))
        XCTAssertEqual(back.width, 1280)
        XCTAssertEqual(back.height, 720)
        XCTAssertEqual(back.fps, 30)
        let dual = try XCTUnwrap(settings.capturePolicy(front: true, isRoundVideo: false, exclusive: false, additional: false, preferWide: false, preferLowerFramerate: false))
        XCTAssertEqual(dual.width, 1920)
        XCTAssertEqual(dual.height, 1080)
        XCTAssertEqual(dual.fps, 30)
        let additional = try XCTUnwrap(settings.capturePolicy(front: true, isRoundVideo: true, exclusive: false, additional: true, preferWide: false, preferLowerFramerate: false))
        XCTAssertEqual(additional.width, 1920)
        XCTAssertEqual(additional.height, 1440)
        XCTAssertEqual(additional.fps, 30)
        let round = try XCTUnwrap(settings.capturePolicy(front: true, isRoundVideo: true, exclusive: true, additional: false, preferWide: true, preferLowerFramerate: true))
        XCTAssertEqual(round.width, 640)
        XCTAssertEqual(round.height, 480)
        XCTAssertEqual(round.fps, 30)
        XCTAssertNil(WhitegramMediaSettings(values: [:]).capturePolicy(front: true, isRoundVideo: false, exclusive: true, additional: false, preferWide: false, preferLowerFramerate: false))
        XCTAssertNil(WhitegramMediaSettings(values: ["frontCameraPreset": "invalid"]).capturePolicy(front: true, isRoundVideo: false, exclusive: true, additional: false, preferWide: false, preferLowerFramerate: false))
    }

    func testWidePreviewCannotOverrideTheOriginalDualMainResolutionBranch() throws {
        let settings = WhitegramMediaSettings(values: ["backCameraPreset": "720p", "backCameraFPS": 60])
        for round in [false, true] {
            let main = try XCTUnwrap(settings.capturePolicy(front: false, isRoundVideo: round, exclusive: false, additional: false, preferWide: true, preferLowerFramerate: false))
            XCTAssertEqual(main.width, 1280)
            XCTAssertEqual(main.height, 720)
            XCTAssertEqual(main.fps, 30)
            let additional = try XCTUnwrap(settings.capturePolicy(front: false, isRoundVideo: round, exclusive: false, additional: true, preferWide: true, preferLowerFramerate: false))
            XCTAssertEqual(additional.width, 1920)
            XCTAssertEqual(additional.height, 1440)
            XCTAssertEqual(additional.fps, 30)
        }
        let exclusive = try XCTUnwrap(settings.capturePolicy(front: false, isRoundVideo: false, exclusive: true, additional: false, preferWide: true, preferLowerFramerate: false))
        XCTAssertEqual(exclusive.width, 1920)
        XCTAssertEqual(exclusive.height, 1440)
        XCTAssertEqual(exclusive.fps, 60)
    }

    func testRecordingResultDimensionsFollowTheEncoderAndPortraitTransform() throws {
        for (width, height) in [(640, 480), (1280, 720), (1920, 1080), (1920, 1440), (3840, 2160)] {
            let landscape = try XCTUnwrap(WhitegramMediaSettings.videoRecordingDimensions(encodedWidth: width, encodedHeight: height, portrait: false))
            XCTAssertEqual(landscape.width, width)
            XCTAssertEqual(landscape.height, height)
            let portrait = try XCTUnwrap(WhitegramMediaSettings.videoRecordingDimensions(encodedWidth: width, encodedHeight: height, portrait: true))
            XCTAssertEqual(portrait.width, height)
            XCTAssertEqual(portrait.height, width)
        }
        for size in [Int.min, -1, 0, 4097, Int.max] {
            XCTAssertNil(WhitegramMediaSettings.videoRecordingDimensions(encodedWidth: size, encodedHeight: 1080, portrait: false))
            XCTAssertNil(WhitegramMediaSettings.videoRecordingDimensions(encodedWidth: 1920, encodedHeight: size, portrait: true))
        }
    }

    func testRoundSessionAndEncoderControlsAreIndependent() {
        for (key, value) in [("backCameraPreset", "4k" as Any), ("frontCameraPreset", "4k"), ("backCameraFPS", 60), ("frontCameraFPS", 60), ("roundCameraWideAngle", true)] {
            XCTAssertTrue(WhitegramMediaSettings(values: [key: value]).requiresSingleCameraForRoundVideo)
            XCTAssertFalse(WhitegramMediaSettings(values: [key: value, "useTelegramCameraSettings": true]).requiresSingleCameraForRoundVideo)
        }
        for (key, expected) in [("low", 500_000), ("medium", 1_000_000), ("high", 3_000_000)] {
            let settings = WhitegramMediaSettings(values: ["roundVideoBitrate": key])
            XCTAssertEqual(settings.roundVideoBitrateValue, expected)
            XCTAssertFalse(settings.requiresSingleCameraForRoundVideo)
        }
        XCTAssertNil(WhitegramMediaSettings(values: ["roundVideoBitrate": "-1000"]).roundVideoBitrateValue)
        XCTAssertNil(WhitegramMediaSettings(values: ["roundVideoBitrate": "3000000x"]).roundVideoBitrateValue)
    }

    func testPhotoOptionsSurviveSettingChangesAndMalformedResourceDimensions() {
        let queued = WhitegramMediaSettings(values: ["sendLargePhotos": true, "photoCompressionQuality": 0.93])
        let changed = WhitegramMediaSettings(values: ["photoCompressionQuality": 0.2])
        let side = queued.photoMaxDimension(hd: false)
        let fetched = changed.photoLibraryTargetDimensions(width: side, height: side, hd: false)
        XCTAssertEqual(fetched.width, 2560)
        XCTAssertEqual(fetched.height, 2560)
        XCTAssertEqual(changed.photoLibraryJPEGQuality(storedQuality: queued.photoQualityPercent), 0.93, accuracy: 0.00001)
        XCTAssertEqual(changed.photoLibraryJPEGQuality(storedQuality: nil), 0.2, accuracy: 0.00001)
        XCTAssertEqual(changed.photoLibraryTargetDimensions(width: 4096, height: 3072, hd: false).width, 4096)
        XCTAssertEqual(changed.photoLibraryTargetDimensions(width: Int32.max, height: Int32.max, hd: false).width, 1280)
        XCTAssertEqual(changed.photoLibraryTargetDimensions(width: 2560, height: nil, hd: true).height, 2560)
        XCTAssertEqual(changed.photoLibraryTargetDimensions(width: 0, height: -1, hd: false).height, 1280)
        XCTAssertEqual(WhitegramMediaSettings(values: ["alwaysSendHD": true]).photoMaxDimension(hd: false), 2560)
    }

    func testLibraryVideoMetadataCleaningIsStoredAsConversionChoice() {
        for asFile in [true, false] {
            XCTAssertTrue(WhitegramMediaSettings(values: ["cleanMetadataOnSend": true]).shouldCompressLibraryVideo(asFile: asFile))
        }
        XCTAssertFalse(WhitegramMediaSettings(values: [:]).shouldCompressLibraryVideo(asFile: true))
        XCTAssertTrue(WhitegramMediaSettings(values: [:]).shouldCompressLibraryVideo(asFile: false))
        XCTAssertFalse(WhitegramMediaSettings(values: ["cleanMetadataOnSend": 1]).shouldCompressLibraryVideo(asFile: true))
    }

    func testJPEGMetadataCleaningPreservesOriginalAndOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-media-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 37.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: "PRIVATE-IPTC-MARKER"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TEST-CAMERA-MARKER"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = directory.appendingPathComponent("photo.jpg")
        try (data as Data).write(to: original)
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual((originalProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] as? String, "TEST-CAMERA-MARKER")
        XCTAssertEqual((originalProperties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCObjectName as String] as? String, "PRIVATE-IPTC-MARKER")
        let cleaned = URL(fileURLWithPath: try WhitegramPhotoMetadata.cleanedCopy(path: original.path))
        defer { try? FileManager.default.removeItem(at: cleaned) }
        XCTAssertNotEqual(cleaned, original)
        XCTAssertEqual(try Data(contentsOf: original), data as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(cleaned as CFURL, nil))
        let result = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual((result[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 16)
        XCTAssertEqual((result[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 8)
        XCTAssertEqual((result[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)
        XCTAssertNil(result[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(result[kCGImagePropertyIPTCDictionary as String])
        let exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertFalse(String(decoding: try Data(contentsOf: cleaned), as: UTF8.self).contains("TEST-CAMERA-MARKER"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: cleaned), as: UTF8.self).contains("PRIVATE-IPTC-MARKER"))
    }

    func testJPEGCleaningPreservesPixelOrientationAcrossRotationsAndMirroring() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-pixel-orientation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 16, y: 0, width: 16, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        for orientation in 1...8 {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = directory.appendingPathComponent("orientation-\(orientation).jpg")
            try (data as Data).write(to: original)
            let cleaned = URL(fileURLWithPath: try WhitegramPhotoMetadata.cleanedCopy(path: original.path))
            defer { try? FileManager.default.removeItem(at: cleaned) }
            let cleanedData = try Data(contentsOf: cleaned)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(cleanedData as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, orientation)
            let before = try self.decodedPixels(data as Data)
            let after = try self.decodedPixels(cleanedData)
            XCTAssertEqual(before.count, after.count)
            let difference = zip(before, after).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            XCTAssertLessThan(Double(difference) / Double(before.count), 5.0, "Pixels were rotated or mirrored twice for orientation \(orientation)")
            XCTAssertEqual(try Data(contentsOf: original), data as Data)
        }
    }

    private func decodedPixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }

    func testOversizedSupportedImagesFailWithoutReplacingTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-image-bound-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = directory.appendingPathComponent("oversized.jpg")
        try (data as Data).write(to: original)
        let handle = try FileHandle(forWritingTo: original)
        defer { try? handle.close() }
        let size = 128 * 1024 * 1024 + 1
        try handle.truncate(atOffset: UInt64(size))
        XCTAssertThrowsError(try WhitegramPhotoMetadata.cleanedCopyIfSupported(path: original.path, mimeType: "image/jpeg")) { error in
            guard case WhitegramPhotoMetadata.ExportError.invalidImage = error else {
                return XCTFail("Unexpected oversized image error: \(error)")
            }
        }
        XCTAssertEqual(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize, size)
    }

    func testUnsupportedAndInvalidInputsDoNotProduceAnUpload() throws {
        XCTAssertFalse(WhitegramPhotoMetadata.supportsMetadataCleaning(mimeType: "video/mp4"))
        XCTAssertTrue(WhitegramPhotoMetadata.supportsMetadataCleaning(mimeType: "image/jpeg"))
        XCTAssertThrowsError(try WhitegramPhotoMetadata.cleanedCopy(path: FileManager.default.temporaryDirectory.path))
        XCTAssertThrowsError(try WhitegramPhotoMetadata.cleanedCopy(path: "/whitegram-nonexistent-photo.jpg"))
    }

    func testPNGTextIsRemovedAndColorIsPreservedEvenWithGenericMIME() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-png-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.8, 0.2, 0.1, 0.7])!)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: "PRIVATE-AUTHOR-MARKER", kCGImagePropertyPNGDescription: "PRIVATE-DESCRIPTION-MARKER"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = directory.appendingPathComponent("image-without-extension")
        try (data as Data).write(to: original)
        let before = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let beforeProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(before, 0, nil) as? [String: Any])
        XCTAssertNotNil((beforeProperties[kCGImagePropertyPNGDictionary as String] as? [String: Any])?[kCGImagePropertyPNGAuthor as String])
        let cleaned = try XCTUnwrap(WhitegramPhotoMetadata.cleanedCopyIfSupported(path: original.path, mimeType: "application/octet-stream"))
        defer { try? FileManager.default.removeItem(atPath: cleaned) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: cleaned) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyProfileName as String] as? String, beforeProperties[kCGImagePropertyProfileName as String] as? String)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 16)
        XCTAssertEqual(try Data(contentsOf: original), data as Data)
        let bytes = String(decoding: try Data(contentsOf: URL(fileURLWithPath: cleaned)), as: UTF8.self)
        XCTAssertFalse(bytes.contains("PRIVATE-AUTHOR-MARKER"))
        XCTAssertFalse(bytes.contains("PRIVATE-DESCRIPTION-MARKER"))
    }

    func testAnimatedImagesAreNotFlattenedAndCorruptImagesDoNotPassThrough() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-animation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "com.compuserve.gif" as CFString, 2, nil))
        for _ in 0..<2 { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let animated = directory.appendingPathComponent("animated.gif")
        try (data as Data).write(to: animated)
        XCTAssertNil(try WhitegramPhotoMetadata.cleanedCopyIfSupported(path: animated.path, mimeType: "image/gif"))
        XCTAssertEqual(try Data(contentsOf: animated), data as Data)
        let document = directory.appendingPathComponent("document.txt")
        try Data("not an image".utf8).write(to: document)
        XCTAssertNil(try WhitegramPhotoMetadata.cleanedCopyIfSupported(path: document.path, mimeType: "text/plain"))
        XCTAssertThrowsError(try WhitegramPhotoMetadata.cleanedCopyIfSupported(path: document.path, mimeType: "image/jpeg"))
    }

    func testTIFFFallbackPreservesOrientationAndDropsCameraMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-tiff-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PRIVATE-TIFF-MAKE"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = directory.appendingPathComponent("photo.tiff")
        try (data as Data).write(to: original)
        let cleaned = try XCTUnwrap(WhitegramPhotoMetadata.cleanedCopyIfSupported(path: original.path, mimeType: "image/tiff"))
        defer { try? FileManager.default.removeItem(atPath: cleaned) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: cleaned) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 16)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 8)
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String])
        XCTAssertFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: cleaned)), as: UTF8.self).contains("PRIVATE-TIFF-MAKE"))
        XCTAssertEqual(try Data(contentsOf: original), data as Data)
    }
}
