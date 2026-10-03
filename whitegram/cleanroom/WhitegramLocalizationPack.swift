import Foundation

public struct WhitegramLocalizationPack: Equatable {
    public let name: String
    public let author: String
    public let languageCode: String
    public let entries: [String: String]

    public init(name: String, author: String, languageCode: String, entries: [String: String]) {
        self.name = name
        self.author = author
        self.languageCode = languageCode
        self.entries = entries
    }

    // Original WGCustomLocalization.parse at image 55:0x324e190.
    public static func parse(_ text: String) -> WhitegramLocalizationPack? {
        var name = ""
        var author = ""
        var languageCode = ""
        var entries: [String: String] = [:]
        for sourceLine in text.components(separatedBy: .newlines) {
            let line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let header = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = header.firstIndex(of: ":") else { continue }
                let key = header[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = header[header.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "name": name = value
                case "author": author = value
                case "language", "lang", "code": languageCode = value
                default: break
                }
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            value = value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            if !value.isEmpty { entries[key] = value }
        }
        guard !entries.isEmpty else { return nil }
        return WhitegramLocalizationPack(name: name.isEmpty ? "Localization" : name, author: author, languageCode: languageCode, entries: entries)
    }

    // The recovered format uses colon-separated text, not a JSON package.
    public func serialized() -> String {
        var lines = [
            "# Whitegram localization", "# name: \(name)", "# author: \(author)", "# language: \(languageCode)", "#",
            "# Переведите ТОЛЬКО текст внутри кавычек. Ключи слева менять нельзя.",
            "# Translate ONLY the text inside the quotes. Do not change the keys.", ""
        ]
        for key in entries.keys.sorted() {
            guard let value = entries[key] else { continue }
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            lines.append("\(key): \"\(escaped)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
