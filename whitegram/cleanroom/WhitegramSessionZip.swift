import Foundation
import zlib

public enum WhitegramSessionZip {
    public struct Entry {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    public static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= WhitegramSessionFiles.maximumTotalBytes else { throw WhitegramSessionError.tooLarge }
        guard data.count >= 22 else { throw WhitegramSessionError.invalidFormat }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try integer(data, at: offset, size: 4) == 0x06054b50,
               offset + 22 + Int(try integer(data, at: offset + 20, size: 2)) == data.count { end = offset; break }
        }
        guard let end, try integer(data, at: end + 4, size: 2) == 0, try integer(data, at: end + 6, size: 2) == 0 else { throw WhitegramSessionError.invalidFormat }
        let count = Int(try integer(data, at: end + 10, size: 2))
        guard count > 0, count <= 1024, try integer(data, at: end + 8, size: 2) == count else { throw WhitegramSessionError.tooLarge }
        let directoryLength = Int(try integer(data, at: end + 12, size: 4))
        let directoryOffset = Int(try integer(data, at: end + 16, size: 4))
        guard directoryOffset <= end, directoryLength == end - directoryOffset else { throw WhitegramSessionError.invalidFormat }
        var offset = directoryOffset
        var names = Set<String>()
        var total = 0
        var entries: [Entry] = []
        for _ in 0..<count {
            guard try integer(data, at: offset, size: 4) == 0x02014b50 else { throw WhitegramSessionError.invalidFormat }
            let flags = try integer(data, at: offset + 8, size: 2)
            let method = try integer(data, at: offset + 10, size: 2)
            guard flags & 0x41 == 0 else { throw WhitegramSessionError.encryptedArchive }
            guard method == 0 || method == 8 else { throw WhitegramSessionError.invalidFormat }
            let crc = UInt32(try integer(data, at: offset + 16, size: 4))
            let compressed = Int(try integer(data, at: offset + 20, size: 4))
            let uncompressed = Int(try integer(data, at: offset + 24, size: 4))
            let nameLength = Int(try integer(data, at: offset + 28, size: 2))
            let extraLength = Int(try integer(data, at: offset + 30, size: 2))
            let commentLength = Int(try integer(data, at: offset + 32, size: 2))
            let attributes = try integer(data, at: offset + 38, size: 4)
            let localOffset = Int(try integer(data, at: offset + 42, size: 4))
            guard try integer(data, at: offset + 34, size: 2) == 0, (attributes >> 16) & 0xf000 != 0xa000 else { throw WhitegramSessionError.unsafeFile }
            let rawName = try slice(data, offset + 46, nameLength)
            guard let name = String(data: rawName, encoding: .utf8), safePath(name), names.insert(name.lowercased()).inserted else { throw WhitegramSessionError.unsafeFile }
            offset += 46 + nameLength + extraLength + commentLength
            guard offset <= end, compressed <= WhitegramSessionFiles.maximumFileBytes, uncompressed <= WhitegramSessionFiles.maximumFileBytes,
                  uncompressed <= WhitegramSessionFiles.maximumTotalBytes - total else { throw WhitegramSessionError.tooLarge }
            total += uncompressed
            guard localOffset < directoryOffset, try integer(data, at: localOffset, size: 4) == 0x04034b50,
                  try integer(data, at: localOffset + 6, size: 2) == flags,
                  try integer(data, at: localOffset + 8, size: 2) == method else { throw WhitegramSessionError.invalidFormat }
            let localNameLength = Int(try integer(data, at: localOffset + 26, size: 2))
            let localExtraLength = Int(try integer(data, at: localOffset + 28, size: 2))
            guard try slice(data, localOffset + 30, localNameLength) == rawName else { throw WhitegramSessionError.invalidFormat }
            let payloadOffset = localOffset + 30 + localNameLength + localExtraLength
            guard payloadOffset <= directoryOffset, compressed <= directoryOffset - payloadOffset else { throw WhitegramSessionError.invalidFormat }
            let compressedData = try slice(data, payloadOffset, compressed)
            let content = method == 0 ? compressedData : try inflate(compressedData, size: uncompressed)
            guard content.count == uncompressed, checksum(content) == crc else { throw WhitegramSessionError.invalidFormat }
            if name.hasSuffix("/") {
                guard content.isEmpty else { throw WhitegramSessionError.invalidFormat }
            } else { entries.append(Entry(name: name, data: content)) }
        }
        guard offset == end else { throw WhitegramSessionError.invalidFormat }
        return entries
    }

    public static func encode(_ entries: [Entry]) throws -> Data {
        guard !entries.isEmpty, entries.count <= 1024 else { throw WhitegramSessionError.tooLarge }
        var names = Set<String>()
        var data = Data()
        var directory = Data()
        for entry in entries {
            guard safePath(entry.name), !entry.name.hasSuffix("/"), names.insert(entry.name.lowercased()).inserted else { throw WhitegramSessionError.unsafeFile }
            let name = Data(entry.name.utf8)
            guard name.count <= 1024, entry.data.count <= WhitegramSessionFiles.maximumFileBytes,
                  data.count + entry.data.count < WhitegramSessionFiles.maximumTotalBytes else { throw WhitegramSessionError.tooLarge }
            let offset = data.count
            let crc = checksum(entry.data)
            append(0x04034b50, size: 4, to: &data)
            for value in [20, 0x800, 0, 0, 0] { append(UInt64(value), size: 2, to: &data) }
            for value in [UInt64(crc), UInt64(entry.data.count), UInt64(entry.data.count)] { append(value, size: 4, to: &data) }
            append(UInt64(name.count), size: 2, to: &data); append(0, size: 2, to: &data)
            data.append(name); data.append(entry.data)
            append(0x02014b50, size: 4, to: &directory)
            for value in [20, 20, 0x800, 0, 0, 0] { append(UInt64(value), size: 2, to: &directory) }
            for value in [UInt64(crc), UInt64(entry.data.count), UInt64(entry.data.count)] { append(value, size: 4, to: &directory) }
            for value in [name.count, 0, 0, 0, 0] { append(UInt64(value), size: 2, to: &directory) }
            append(0, size: 4, to: &directory); append(UInt64(offset), size: 4, to: &directory)
            directory.append(name)
        }
        let directoryOffset = data.count
        data.append(directory)
        append(0x06054b50, size: 4, to: &data)
        for value in [0, 0, entries.count, entries.count] { append(UInt64(value), size: 2, to: &data) }
        append(UInt64(directory.count), size: 4, to: &data); append(UInt64(directoryOffset), size: 4, to: &data); append(0, size: 2, to: &data)
        guard data.count <= WhitegramSessionFiles.maximumTotalBytes else { throw WhitegramSessionError.tooLarge }
        return data
    }

    static func safePath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else { return false }
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func slice(_ data: Data, _ start: Int, _ count: Int) throws -> Data {
        guard start >= 0, count >= 0, start <= data.count, count <= data.count - start else { throw WhitegramSessionError.invalidFormat }
        return data.subdata(in: start..<start + count)
    }
    private static func integer(_ data: Data, at offset: Int, size: Int) throws -> UInt64 {
        return try slice(data, offset, size).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    private static func append(_ value: UInt64, size: Int, to data: inout Data) {
        for offset in 0..<size { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
    private static func checksum(_ data: Data) -> UInt32 {
        return data.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt($0.count))) }
    }
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var output = Data(count: max(1, size))
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw WhitegramSessionError.invalidFormat }
        defer { inflateEnd(&stream) }
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(output.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_in == data.count, stream.total_out == size else { throw WhitegramSessionError.invalidFormat }
        output.count = size
        return output
    }
}
