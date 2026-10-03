import Foundation
import ImageIO

public enum WhitegramPhotoMetadata {
    public enum ExportError: Error {
        case invalidImage
        case unsupportedImage
        case metadataCopyFailed
        case verificationFailed
    }

    public static func supportsMetadataCleaning(mimeType: String) -> Bool {
        return ["image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/tiff", "image/bmp", "image/gif"].contains(mimeType.lowercased())
    }

    /// The original cleaner probes the file with ImageIO, not its name or MIME
    /// label. Animated/multipage images and documents retain their native path.
    public static func cleanedCopyIfSupported(path: String, mimeType: String) throws -> String? {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ExportError.invalidImage }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else {
            if self.supportsMetadataCleaning(mimeType: mimeType) { throw ExportError.invalidImage }
            return nil
        }
        guard CGImageSourceGetCount(source) > 0 else { throw ExportError.invalidImage }
        guard CGImageSourceGetCount(source) == 1 else { return nil }
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type as String) else {
            throw ExportError.unsupportedImage
        }
        return try self.cleanedCopy(path: path)
    }

    /// Returns a verified upload copy; the selected original's bytes are unchanged.
    public static func cleanedCopy(path: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: path)
        let attributes = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 128 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw ExportError.invalidImage
        }
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type as String), CGImageSourceGetCount(source) == 1 else {
            throw ExportError.unsupportedImage
        }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw ExportError.invalidImage }
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, NSNumber(value: orientation)) else {
            throw ExportError.metadataCopyFailed
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result as CFMutableData, type, 1, nil) else { throw ExportError.unsupportedImage }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageDestinationEmbedThumbnail: false
        ]
        var error: Unmanaged<CFError>?
        let supportsLosslessCopy = ["public.jpeg", "public.png", "public.heic", "public.heif"].contains(type as String)
        let copied = supportsLosslessCopy && CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
        if let error { _ = error.takeRetainedValue() }
        // CopyImageSource completes the destination; do not Finalize it again.
        var verifiedCopy: Data?
        if copied {
            do {
                let data = result as Data
                try self.verify(data, original: properties, orientation: orientation, type: type)
                verifiedCopy = data
            } catch {
                // Some ImageIO codecs copy private ancillary chunks despite the
                // metadata replacement. Rebuild below, then verify again.
            }
        }
        let data: Data
        if let verifiedCopy {
            data = verifiedCopy
        } else {
            data = try self.reencodedData(source: source, type: type, properties: properties, orientation: orientation)
        }
        let suffix = sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whitegram-photo-\(UUID().uuidString).\(suffix)")
        try data.write(to: output, options: [.atomic])
        return output.path
    }

    private static func reencodedData(source: CGImageSource, type: CFString, properties: [String: Any], orientation: Int) throws -> Data {
        // Bound the fallback decode separately from the 128 MiB input limit.
        // Ordinary 48 MP photos fit; lossless copies need no pixel allocation.
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue >= 1, height.doubleValue >= 1,
              width.doubleValue * height.doubleValue <= 64.0 * 1024.0 * 1024.0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ExportError.metadataCopyFailed
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result as CFMutableData, type, 1, nil) else { throw ExportError.unsupportedImage }
        var outputProperties: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationEmbedThumbnail: false]
        if type as String == "public.jpeg" {
            // Original still-file cleaner 0x2825eac uses JPEG quality 0.95.
            outputProperties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.metadataCopyFailed }
        let data = result as Data
        try self.verify(data, original: properties, orientation: orientation, type: type)
        return data
    }

    private static func verify(_ data: Data, original: [String: Any], orientation: Int, type: CFString) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source).map({ $0 as String }) == (type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ExportError.verificationFailed }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyProfileName] {
            if let expected = original[key as String] as? NSObject, !expected.isEqual(properties[key as String]) {
                throw ExportError.verificationFailed
            }
        }
        let resultOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard resultOrientation == orientation else { throw ExportError.verificationFailed }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let values = properties[key as String] as? [String: Any], !values.isEmpty { throw ExportError.verificationFailed }
        }
        let allowedExif = Set(["ColorSpace", "PixelXDimension", "PixelYDimension", "ExifVersion", "FlashPixVersion", "ComponentsConfiguration"])
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any], !Set(exif.keys).isSubset(of: allowedExif) {
            throw ExportError.verificationFailed
        }
        let allowedTiff = Set(["Orientation", "XResolution", "YResolution", "ResolutionUnit", "Compression", "PhotometricInterpretation", "TransferFunction", "WhitePoint", "PrimaryChromaticities", "TileWidth", "TileLength"])
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any], !Set(tiff.keys).isSubset(of: allowedTiff) {
            throw ExportError.verificationFailed
        }
        let allowedPNG = Set(["Gamma", "InterlaceType", "XPixelsPerMeter", "YPixelsPerMeter", "Chromaticities", "sRGBIntent"])
        if let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any], !Set(png.keys).isSubset(of: allowedPNG) {
            throw ExportError.verificationFailed
        }
        // ImageIO's property dictionaries do not expose every XMP tag. Verify
        // that the replacement metadata has no author/location/private fields.
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let allowedTags = Set(allowedTiff.map { "tiff:" + $0 }).union(["tiff:ImageWidth", "tiff:ImageLength", "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PlanarConfiguration", "tiff:YCbCrCoefficients", "tiff:YCbCrSubSampling", "tiff:YCbCrPositioning", "tiff:ReferenceBlackWhite", "exif:ColorSpace", "exif:PixelXDimension", "exif:PixelYDimension", "exif:ExifVersion", "exif:FlashPixVersion", "exif:ComponentsConfiguration"])
            var invalidMetadata = false
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
                if !allowedTags.contains(path as String) { invalidMetadata = true }
                return true
            }
            if invalidMetadata { throw ExportError.verificationFailed }
        }
    }

}
