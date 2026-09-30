import Foundation

/// Bounds nesting and rejects duplicate object keys before Foundation decodes values.
struct WhitegramSettingsArchiveJSON {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) throws {
        guard data.count <= WhitegramSettingsArchive.maximumBytes else { throw WhitegramSettingsArchiveError.tooLarge }
        self.bytes = Array(data)
    }

    mutating func check() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw WhitegramSettingsArchiveError.invalidJSON }
    }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        if index < bytes.count, bytes[index] == byte { index += 1; return true }
        return false
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 4 else { throw WhitegramSettingsArchiveError.tooLarge }
        whitespace()
        guard index < bytes.count else { throw WhitegramSettingsArchiveError.invalidJSON }
        switch bytes[index] {
        case 123: try object(depth: depth)
        case 91: try array(depth: depth)
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw WhitegramSettingsArchiveError.invalidJSON }
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        if take(125) { return }
        var keys = Set<String>()
        repeat {
            whitespace()
            let key = try string()
            guard key.utf8.count <= 256, keys.count < 384 else { throw WhitegramSettingsArchiveError.tooLarge }
            guard keys.insert(key).inserted else { throw WhitegramSettingsArchiveError.duplicateKey }
            guard take(58) else { throw WhitegramSettingsArchiveError.invalidJSON }
            try value(depth: depth + 1)
            if take(125) { return }
        } while take(44)
        throw WhitegramSettingsArchiveError.invalidJSON
    }

    private mutating func array(depth: Int) throws {
        index += 1
        if take(93) { return }
        var count = 0
        repeat {
            count += 1
            guard count <= 384 else { throw WhitegramSettingsArchiveError.tooLarge }
            try value(depth: depth + 1)
            if take(93) { return }
        } while take(44)
        throw WhitegramSettingsArchiveError.invalidJSON
    }

    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw WhitegramSettingsArchiveError.invalidJSON }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                let data = Data(bytes[start..<index])
                guard let result = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw WhitegramSettingsArchiveError.invalidJSON }
                return result
            }
            if byte == 92 { index += 1 }
        }
        throw WhitegramSettingsArchiveError.invalidJSON
    }
}
