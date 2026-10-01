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
        return ["image/jpeg", "image/png", "image/heic", "image/heif"].contains(mimeType.lowercased())
    }

    /// Returns a new upload file. The selected original and its encoded pixels are not edited.
    public static func cleanedCopy(path: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: path)
        let attributes = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 128 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw ExportError.invalidImage
        }
        guard ["public.jpeg", "public.png", "public.heic", "public.heif"].contains(type as String), CGImageSourceGetCount(source) == 1 else {
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
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw ExportError.metadataCopyFailed
        }
        // CopyImageSource completes the destination; calling Finalize again is not valid.
        let data = result as Data
        try self.verify(data, original: properties, orientation: orientation, type: type)
        let suffix = sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whitegram-photo-\(UUID().uuidString).\(suffix)")
        try data.write(to: output, options: [.atomic])
        return output.path
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
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let values = properties[key as String] as? [String: Any], !values.isEmpty { throw ExportError.verificationFailed }
        }
        let allowedExif = Set(["ColorSpace", "PixelXDimension", "PixelYDimension", "ExifVersion", "FlashPixVersion", "ComponentsConfiguration"])
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any], !Set(exif.keys).isSubset(of: allowedExif) {
            throw ExportError.verificationFailed
        }
        let allowedTiff = Set(["Orientation", "XResolution", "YResolution", "ResolutionUnit"])
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any], !Set(tiff.keys).isSubset(of: allowedTiff) {
            throw ExportError.verificationFailed
        }
    }

}
