import Foundation
import CoreFoundation

public struct WhitegramIconPackError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { return self.message }
}

public struct WhitegramIconPackManifest: Equatable {
    public let id: String
    public let name: String
    public let author: String
    public let packDescription: String
    public let version: String
    public let monochrome: Bool
    public let iconScale: Double
    public let iconCount: Int

    public init(data: Data, id: String, fallbackName: String, iconCount: Int) throws {
        guard data.count <= 256 * 1024, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhitegramIconPackError("The icon pack manifest must be a JSON object smaller than 256 KiB.")
        }
        guard iconCount > 0 else { throw WhitegramIconPackError("The archive has no supported icons or animations in icons/.") }
        self.id = id
        self.name = (json["name"] as? String) ?? fallbackName
        self.author = (json["author"] as? String) ?? ""
        self.packDescription = (json["description"] as? String) ?? ""
        self.version = (json["version"] as? String) ?? "1.0"
        if let value = json["monochrome"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            self.monochrome = value.boolValue
        } else {
            self.monochrome = true
        }
        let scale = (json["iconScale"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } ?? 1.0
        self.iconScale = scale.isFinite && scale > 0.05 && scale < 4.0 ? scale : 1.0
        self.iconCount = iconCount
    }
}

public enum WhitegramIconPackArchive {
    public static let iconExtensions: Set<String> = ["svg", "png", "pdf"]
    public static let animationExtensions: Set<String> = ["json", "tgs"]
    public static let archiveExtensions: Set<String> = ["wgicons", "zip"]
    public static let maximumFileBytes: UInt64 = 8 * 1024 * 1024
    public static let maximumArchiveBytes: UInt64 = 128 * 1024 * 1024

    public struct Entry: Equatable {
        public let path: String
        public let size: UInt64
        public init(path: String, size: UInt64) { self.path = path; self.size = size }
    }

    /// A single optional wrapper directory is accepted, as in the original inspector.
    public struct Plan {
        public let prefix: String
        public let files: [Entry]
        public let iconCount: Int
    }

    public static func identifier(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = String(name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
        return value.isEmpty ? "pack-" + UUID().uuidString.prefix(8).lowercased() : String(value.prefix(160))
    }

    public static func validRelativePath(_ path: String, directory: Bool = false) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        let value = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func plan(entries: [Entry]) throws -> Plan {
        guard !entries.isEmpty, entries.count <= 4096 else { throw WhitegramIconPackError("The archive is empty or has more than 4096 entries.") }
        var seen = Set<String>()
        var total: UInt64 = 0
        for entry in entries {
            let isDirectory = entry.path.hasSuffix("/")
            guard validRelativePath(entry.path, directory: isDirectory), seen.insert(entry.path.lowercased()).inserted else {
                throw WhitegramIconPackError("The archive contains an unsafe or duplicate path: \(entry.path)")
            }
            guard entry.size <= maximumFileBytes, total <= maximumArchiveBytes - entry.size else {
                throw WhitegramIconPackError("The archive exceeds the icon pack size limits.")
            }
            total += entry.size
        }
        let manifests = entries.filter { $0.path == "manifest.json" || ($0.path.split(separator: "/").count == 2 && $0.path.hasSuffix("/manifest.json")) }
        guard manifests.count == 1, let manifest = manifests.first else { throw WhitegramIconPackError("The archive must contain one manifest.json at its root or in one wrapper folder.") }
        let prefix = String(manifest.path.dropLast("manifest.json".count))
        let files = entries.filter { entry in
            guard entry.path.hasPrefix(prefix), !entry.path.hasSuffix("/") else { return false }
            let name = String(entry.path.dropFirst(prefix.count))
            if name == "manifest.json" || name == "preview.png" || name == "preview.jpg" { return true }
            return name.hasPrefix("icons/") && iconExtensions.union(animationExtensions).contains((name as NSString).pathExtension.lowercased())
        }
        let iconCount = files.filter { String($0.path.dropFirst(prefix.count)).hasPrefix("icons/") }.count
        guard iconCount > 0 else { throw WhitegramIconPackError("The archive has no SVG, PNG, PDF, JSON or TGS files in icons/.") }
        return Plan(prefix: prefix, files: files, iconCount: iconCount)
    }
}
