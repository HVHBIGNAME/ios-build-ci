import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import TelegramCore
import LocalMediaResources

final class WhitegramMediaTests: XCTestCase {
    func testDefaultsPreserveTelegramAndOverridesRemainBounded() {
        let defaults = WhitegramMediaSettings(values: [:])
        XCTAssertEqual(defaults.photoMaxDimension(hd: false), 1280)
        XCTAssertEqual(defaults.photoMaxDimension(hd: true), 2560)
        XCTAssertEqual(defaults.jpegQuality(default: 0.6), 0.6)
        XCTAssertTrue(defaults.useTelegramCameraSettings)
        XCTAssertNil(defaults.roundVideoBitrateValue)
        let custom = WhitegramMediaSettings(values: ["sendLargePhotos": true, "photoCompressionQuality": 0.9, "useTelegramCameraSettings": false, "roundVideoBitrate": "2000000"])
        XCTAssertEqual(custom.photoMaxDimension(hd: false), 4096)
        XCTAssertEqual(custom.jpegQuality(default: 0.6), 0.9)
        XCTAssertEqual(custom.roundVideoBitrateValue, 2_000_000)
        let invalid = WhitegramMediaSettings(values: ["sendLargePhotos": 1, "photoCompressionQuality": Double.nan, "useTelegramCameraSettings": false, "roundVideoBitrate": "99999999999999999999"])
        XCTAssertFalse(invalid.sendLargePhotos)
        XCTAssertEqual(invalid.photoCompressionQuality, 0.8)
        XCTAssertNil(invalid.roundVideoBitrateValue)
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
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TEST-CAMERA-MARKER"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = directory.appendingPathComponent("photo.jpg")
        try (data as Data).write(to: original)
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
        let exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertFalse(String(decoding: try Data(contentsOf: cleaned), as: UTF8.self).contains("TEST-CAMERA-MARKER"))
    }

    func testUnsupportedAndInvalidInputsDoNotProduceAnUpload() throws {
        XCTAssertFalse(WhitegramPhotoMetadata.supportsMetadataCleaning(mimeType: "image/gif"))
        XCTAssertTrue(WhitegramPhotoMetadata.supportsMetadataCleaning(mimeType: "image/jpeg"))
        XCTAssertThrowsError(try WhitegramPhotoMetadata.cleanedCopy(path: FileManager.default.temporaryDirectory.path))
        XCTAssertThrowsError(try WhitegramPhotoMetadata.cleanedCopy(path: "/whitegram-nonexistent-photo.jpg"))
    }
}
