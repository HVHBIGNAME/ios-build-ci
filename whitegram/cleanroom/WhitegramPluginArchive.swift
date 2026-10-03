import Foundation
import zlib

// ZIP is decoded in memory before installation, so no archive path reaches an
// extractor or the filesystem. The central directory is cross-checked against
// each local header and every stream is bounded independently of its size claim.
enum WhitegramPluginArchive {
    private struct Entry {
        let path: String
        let directory: Bool
        let method: UInt16
        let crc: UInt32
        let size: Int
        let compressed: Range<Int>
        let record: Range<Int>
    }

    static func isZIP(_ data: Data) -> Bool {
        return data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0x50, 0x4b, 0x05, 0x06])
    }

    static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22, data.count <= WhitegramPluginStorage.maximumImportBytes else {
            throw WhitegramPluginError("INVALID_ARCHIVE", "ZIP is truncated or exceeds the import limit")
        }
        let bytes = [UInt8](data)
        guard let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1).first(where: {
            self.u32(bytes, $0) == 0x06054b50 && $0 + 22 + Int(self.u16(bytes, $0 + 20)) == bytes.count
        }) else { throw WhitegramPluginError("INVALID_ARCHIVE", "ZIP end record is missing") }
        let count = Int(self.u16(bytes, end + 10))
        let directorySize = Int(self.u32(bytes, end + 12))
        let directoryStart = Int(self.u32(bytes, end + 16))
        guard self.u16(bytes, end + 4) == 0, self.u16(bytes, end + 6) == 0,
              Int(self.u16(bytes, end + 8)) == count, count > 0, count <= 512,
              directoryStart <= end, directorySize == end - directoryStart else {
            throw WhitegramPluginError("INVALID_ARCHIVE", "Expected a single-volume, non-ZIP64 plugin archive")
        }
        var cursor = directoryStart
        var entries: [Entry] = []
        var paths = Set<String>()
        var total = 0
        for _ in 0 ..< count {
            guard cursor <= end - 46, self.u32(bytes, cursor) == 0x02014b50 else {
                throw WhitegramPluginError("INVALID_ARCHIVE", "Invalid ZIP central directory")
            }
            let length = 46 + Int(self.u16(bytes, cursor + 28)) + Int(self.u16(bytes, cursor + 30)) + Int(self.u16(bytes, cursor + 32))
            guard length <= end - cursor else { throw WhitegramPluginError("INVALID_ARCHIVE", "Truncated ZIP entry") }
            let entry = try self.entry(bytes, at: cursor, directoryStart: directoryStart)
            let canonical = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(canonical).inserted else { throw WhitegramPluginError("INVALID_PACKAGE", "Duplicate or case-colliding ZIP path") }
            entries.append(entry)
            total += entry.size
            guard total <= WhitegramPluginStorage.maximumPackageBytes else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Expanded ZIP is too large") }
            cursor += length
        }
        guard cursor == end else { throw WhitegramPluginError("INVALID_ARCHIVE", "Unexpected bytes in the central directory") }
        let sorted = entries.sorted { $0.record.lowerBound < $1.record.lowerBound }
        for index in 1 ..< sorted.count where sorted[index - 1].record.upperBound > sorted[index].record.lowerBound {
            throw WhitegramPluginError("INVALID_ARCHIVE", "Overlapping ZIP entries")
        }
        let regularPaths = Set(entries.filter { !$0.directory }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
        for path in paths {
            let parts = path.split(separator: "/")
            for length in 1 ..< parts.count where regularPaths.contains(parts.prefix(length).joined(separator: "/")) {
                throw WhitegramPluginError("INVALID_PACKAGE", "A ZIP file cannot also be a directory")
            }
        }
        var files: [String: Data] = [:]
        for entry in entries {
            let compressed = Data(bytes[entry.compressed])
            let expanded = entry.method == 0 ? compressed : try self.inflate(compressed, size: entry.size)
            guard expanded.count == entry.size, self.checksum(expanded) == entry.crc else {
                throw WhitegramPluginError("INVALID_ARCHIVE", "ZIP size or CRC mismatch: \(entry.path)")
            }
            if !entry.directory { files[entry.path] = expanded }
        }
        // The original importer ignores Finder metadata and unwraps one outer
        // directory (image 55, 0xc5b578). Hidden package files remain unexecuted.
        files = files.filter { path, _ in
            let first = path.split(separator: "/").first.map(String.init) ?? ""
            return first != "__MACOSX" && !first.hasPrefix(".")
        }
        let roots = Set(files.keys.map { String($0.split(separator: "/")[0]) })
        if roots.count == 1, let root = roots.first, files[root] == nil {
            files = Dictionary(uniqueKeysWithValues: files.map { (String($0.key.dropFirst(root.count + 1)), $0.value) })
        }
        guard !files.isEmpty, files.count <= WhitegramPluginStorage.maximumFiles else {
            throw WhitegramPluginError("QUOTA_EXCEEDED", "ZIP must contain 1–256 package files")
        }
        return files
    }

    private static func entry(_ bytes: [UInt8], at offset: Int, directoryStart: Int) throws -> Entry {
        let flags = self.u16(bytes, offset + 8)
        let method = self.u16(bytes, offset + 10)
        let crc = self.u32(bytes, offset + 16)
        let compressedSize = Int(self.u32(bytes, offset + 20))
        let size = Int(self.u32(bytes, offset + 24))
        let nameSize = Int(self.u16(bytes, offset + 28))
        let nameBytes = Array(bytes[(offset + 46) ..< (offset + 46 + nameSize)])
        guard flags & ~UInt16(0x080e) == 0, [UInt16(0), 8].contains(method), self.u16(bytes, offset + 34) == 0 else {
            throw WhitegramPluginError("UNSUPPORTED_ARCHIVE", "ZIP encryption, split volumes and this compression method are unsupported")
        }
        guard size <= WhitegramPluginStorage.maximumFileBytes, compressedSize <= WhitegramPluginStorage.maximumImportBytes else {
            throw WhitegramPluginError("QUOTA_EXCEEDED", "ZIP entry exceeds its size limit")
        }
        guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw WhitegramPluginError("INVALID_ENCODING", "ZIP paths must use UTF-8") }
        let directory = name.hasSuffix("/")
        let path = directory ? String(name.dropLast()) : name
        _ = try WhitegramPluginPath.components(path)
        let mode = self.u32(bytes, offset + 38) >> 16
        let kind = mode & 0xf000
        guard kind == 0 || kind == (directory ? 0x4000 : 0x8000), !directory || size == 0 else {
            throw WhitegramPluginError("INVALID_PATH", "ZIP links and special files are not permitted")
        }
        let local = Int(self.u32(bytes, offset + 42))
        guard local <= directoryStart - 30, self.u32(bytes, local) == 0x04034b50,
              self.u16(bytes, local + 6) == flags, self.u16(bytes, local + 8) == method,
              Int(self.u16(bytes, local + 26)) == nameSize else { throw WhitegramPluginError("INVALID_ARCHIVE", "ZIP local and central headers disagree") }
        let start = local + 30 + nameSize + Int(self.u16(bytes, local + 28))
        guard start <= directoryStart, compressedSize <= directoryStart - start,
              Array(bytes[(local + 30) ..< (local + 30 + nameSize)]) == nameBytes else {
            throw WhitegramPluginError("INVALID_ARCHIVE", "Truncated or inconsistent ZIP local record")
        }
        var end = start + compressedSize
        if flags & 8 != 0 {
            if end <= directoryStart - 4, self.u32(bytes, end) == 0x08074b50 { end += 4 }
            guard end <= directoryStart - 12, self.u32(bytes, end) == crc,
                  Int(self.u32(bytes, end + 4)) == compressedSize, Int(self.u32(bytes, end + 8)) == size else {
                throw WhitegramPluginError("INVALID_ARCHIVE", "Invalid ZIP data descriptor")
            }
            end += 12
        } else if self.u32(bytes, local + 14) != crc || Int(self.u32(bytes, local + 18)) != compressedSize || Int(self.u32(bytes, local + 22)) != size {
            throw WhitegramPluginError("INVALID_ARCHIVE", "ZIP local sizes or CRC disagree")
        }
        return Entry(path: path, directory: directory, method: method, crc: crc, size: size, compressed: start ..< (start + compressedSize), record: local ..< end)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(self.u16(bytes, offset)) | UInt32(self.u16(bytes, offset + 2)) << 16
    }

    private static func checksum(_ data: Data) -> UInt32 {
        return data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WhitegramPluginError("INVALID_ARCHIVE", "Could not initialize ZIP decompression")
        }
        defer { inflateEnd(&stream) }
        var result = Data(count: size + 1)
        let status: Int32 = data.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
            throw WhitegramPluginError("INVALID_ARCHIVE", "Invalid, truncated or oversized DEFLATE stream")
        }
        result.removeLast()
        return result
    }
}

struct WhitegramPluginPackage {
    let metadata: [String: Any]
    let entry: String
    let files: [String: Data]

    static func archive(_ data: Data, name: String) throws -> WhitegramPluginPackage {
        let files = try WhitegramPluginArchive.decode(data)
        var metadata: [String: Any] = [:]
        // Original manifest aliases: image 55, 0xc5c560–0xc5c5c4.
        let manifestNames = ["plugin.json", "manifest.json", "whitegram.json"]
        let manifests = files.keys.filter { manifestNames.contains($0.lowercased()) }.sorted()
        guard manifests.count <= 1 else { throw WhitegramPluginError("INVALID_PACKAGE", "Package has multiple manifests") }
        if let manifest = manifests.first, let bytes = files[manifest] {
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw WhitegramPluginError("INVALID_PACKAGE", "Plugin manifest must be a JSON object")
            }
            metadata = value
        }
        let entry: String
        if let main = metadata["main"] {
            guard let main = main as? String else { throw WhitegramPluginError("INVALID_PACKAGE", "Manifest main must be a path") }
            entry = main.hasPrefix("./") ? String(main.dropFirst(2)) : main
            _ = try WhitegramPluginPath.components(entry)
        } else {
            // Image 55, 0xc5c93c–0xc5ca50: named entries, then first script.
            let candidates = ["main.js", "plugin.js", "index.js", name + ".js", "main.ts", "index.ts"]
            guard let main = candidates.first(where: { files[$0] != nil }) ?? files.keys.sorted().first(where: { ["js", "ts"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) else {
                throw WhitegramPluginError("ENTRY_MISSING", "Package has no JavaScript or TypeScript entry")
            }
            entry = main
        }
        if metadata["name"] == nil { metadata["name"] = name }
        return WhitegramPluginPackage(metadata: metadata, entry: entry, files: files)
    }
}
