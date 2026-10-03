import Foundation

struct WhitegramFontArchiveError: LocalizedError {
    let message: String
    var errorDescription: String? { return self.message }
}

enum WhitegramFontArchivePlan {
    struct Entry: Equatable {
        let path: String
        let size: UInt64
    }

    static let maximumArchiveBytes: UInt64 = 128 * 1024 * 1024
    static let maximumFontBytes: UInt64 = 32 * 1024 * 1024

    static func fonts(in entries: [Entry]) throws -> [Entry] {
        guard !entries.isEmpty, entries.count <= 512 else {
            throw WhitegramFontArchiveError(message: "Font archives must contain between 1 and 512 entries.")
        }
        var seen = Set<String>()
        var bytes: UInt64 = 0
        var fonts: [Entry] = []
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  seen.insert(path.lowercased()).inserted else {
                throw WhitegramFontArchiveError(message: "The font archive contains an unsafe or duplicate path.")
            }
            guard entry.size <= Self.maximumFontBytes, bytes <= Self.maximumArchiveBytes - entry.size else {
                throw WhitegramFontArchiveError(message: "The font archive exceeds the file or total size limit.")
            }
            bytes += entry.size
            if entry.path.hasSuffix("/") || components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { continue }
            if ["ttf", "otf"].contains((path as NSString).pathExtension.lowercased()) {
                guard entry.size > 0 else { throw WhitegramFontArchiveError(message: "The font archive contains an empty font.") }
                fonts.append(entry)
            }
        }
        guard !fonts.isEmpty else { throw WhitegramFontArchiveError(message: "The archive contains no TrueType or OpenType fonts.") }
        return fonts.sorted { $0.path < $1.path }
    }
}
