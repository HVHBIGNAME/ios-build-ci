import Foundation
import Display
import ZipArchive

enum WhitegramFontArchiveImport {
    /// The caller holds coordinated, security-scoped access for the whole import.
    static func read(_ source: URL) throws -> [WhitegramFontRecord] {
        guard source.pathExtension.lowercased() == "zip" else {
            return try WhitegramFontRegistry.shared.importFont(from: source)
        }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, UInt64(size) <= WhitegramFontArchivePlan.maximumArchiveBytes else {
            throw WhitegramFontArchiveError(message: "Choose a regular font archive smaller than 128 MiB.")
        }
        guard let entries = SSZipArchive.getEntriesForFile(atPath: source.path) else {
            throw WhitegramFontArchiveError(message: "The font archive could not be opened.")
        }
        let plan = try WhitegramFontArchivePlan.fonts(in: entries.map { .init(path: $0.path, size: UInt64($0.uncompressedSize)) })
        let files = FileManager.default
        let staging = files.temporaryDirectory.appendingPathComponent("whitegram-font-import-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: nil)
        defer {
            do { try files.removeItem(at: staging) }
            catch { NSLog("Whitegram: could not remove font staging directory (%@)", String(describing: type(of: error))) }
        }
        var sources: [URL] = []
        for entry in plan {
            let destination = staging.appendingPathComponent(entry.path, isDirectory: false)
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            guard SSZipArchive.extractFileFromArchive(atPath: source.path, filePath: entry.path, toPath: destination.path) else {
                throw WhitegramFontArchiveError(message: "Could not extract \(entry.path).")
            }
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                  size > 0, UInt64(size) == entry.size else {
                throw WhitegramFontArchiveError(message: "An extracted font has an invalid size or file type.")
            }
            sources.append(destination)
        }
        return try WhitegramFontRegistry.shared.importFonts(from: sources)
    }
}
