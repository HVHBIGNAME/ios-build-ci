import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum WhitegramVirusTotalTarget: Equatable, Hashable {
    case file(sha256: String)
    case url(String)
    case ipAddress(String)

    public var value: String {
        switch self {
        case let .file(value), let .url(value), let .ipAddress(value): return value
        }
    }

    public var title: String {
        switch self {
        case .file: return "SHA-256"
        case .url: return "URL"
        case .ipAddress: return "IP Address"
        }
    }

    public static func parse(_ value: String) throws -> WhitegramVirusTotalTarget {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= WhitegramServiceLimits.maximumVirusTotalTargetBytes else { throw WhitegramServiceError.invalidTarget }
        if let hash = try? WhitegramVirusTotalWire.validatedHash(value) { return .file(sha256: hash) }
        if let ip = whitegramVirusTotalIPAddress(value) { return .ipAddress(ip) }
        return try WhitegramVirusTotalTarget.url(value).validated()
    }

    public func validated() throws -> WhitegramVirusTotalTarget {
        switch self {
        case let .file(hash): return .file(sha256: try WhitegramVirusTotalWire.validatedHash(hash))
        case let .ipAddress(value):
            guard let ip = whitegramVirusTotalIPAddress(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw WhitegramServiceError.invalidTarget }
            return .ipAddress(ip)
        case let .url(value): return .url(try whitegramVirusTotalURL(value))
        }
    }

    var resourcePath: String {
        switch self {
        case let .file(hash): return "files/" + hash
        case let .ipAddress(ip): return "ip_addresses/" + ip
        case let .url(url):
            // VT accepts the UTF-8 URL as URL-safe base64 without '=' padding.
            let id = Data(url.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "urls/" + id
        }
    }
}

private func whitegramVirusTotalIPAddress(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 47, value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
    if !value.contains(":") {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            !part.isEmpty && part.count <= 3 && (part.count == 1 || part.first != "0") && part.utf8.allSatisfy({ (48...57).contains($0) }) && (Int(part) ?? 256) <= 255
        }) else { return nil }
        return value
    }
    let ip = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
    guard !ip.contains("%") else { return nil }
    var address = in6_addr()
    guard ip.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let success = buffer.withUnsafeMutableBufferPointer { output in
        inet_ntop(AF_INET6, &address, output.baseAddress, socklen_t(output.count)) != nil
    }
    return success ? String(cString: buffer) : nil
}

private func whitegramVirusTotalURL(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= WhitegramServiceLimits.maximumVirusTotalTargetBytes,
          !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
          !value.contains("\\"), var components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          components.user == nil, components.password == nil, let host = components.host, !host.isEmpty,
          components.port.map({ (1...65535).contains($0) }) != false else { throw WhitegramServiceError.invalidTarget }
    let bytes = Array(value.utf8)
    for index in bytes.indices where bytes[index] == 37 {
        guard index + 2 < bytes.count, bytes[(index + 1)...(index + 2)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw WhitegramServiceError.invalidTarget
        }
    }
    components.scheme = scheme
    if host.contains(":") {
        guard let ip = whitegramVirusTotalIPAddress(host) else { throw WhitegramServiceError.invalidTarget }
        components.host = "[" + ip + "]"
    } else {
        let host = host.lowercased()
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            guard whitegramVirusTotalIPAddress(host) != nil else { throw WhitegramServiceError.invalidTarget }
        } else {
            guard host.utf8.count <= 253, host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
            }) else { throw WhitegramServiceError.invalidTarget }
        }
        components.host = host
    }
    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) { components.port = nil }
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
    components.fragment = nil
    guard let url = components.url, let normalized = components.string,
          url.host != nil, normalized.utf8.count <= WhitegramServiceLimits.maximumVirusTotalTargetBytes else { throw WhitegramServiceError.invalidTarget }
    return normalized
}

/// UTF-16 range, matching Telegram's entity offsets. A nil URL denotes a visible URL entity.
public struct WhitegramVirusTotalTextLink {
    public let range: NSRange
    public let url: String?

    public init(range: NSRange, url: String? = nil) {
        self.range = range
        self.url = url
    }
}

public enum WhitegramVirusTotalTargets {
    public static let maximumTargets = 20
    private static let patterns = [
        #"(?i)\bhttps?://[^\s<>"']+"#,
        #"(?<![A-Za-z0-9:])\[?[A-Fa-f0-9:.]*:[A-Fa-f0-9:.]+\]?(?![A-Za-z0-9:])"#,
        #"(?<![A-Za-z0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9.])"#,
        #"(?<![A-Za-z0-9])[A-Fa-f0-9]{64}(?![A-Za-z0-9])"#
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func extractTarget(from text: String, links: [WhitegramVirusTotalTextLink] = []) -> WhitegramVirusTotalTarget? {
        return self.extractAllTargets(from: text, links: links).first
    }

    public static func extractAllTargets(from text: String, links: [WhitegramVirusTotalTextLink] = []) -> [WhitegramVirusTotalTarget] {
        guard text.utf8.count <= WhitegramServiceLimits.maximumPromptBytes else { return [] }
        let length = text.utf16.count
        var occupied: [NSRange] = []
        var candidates: [(Int, WhitegramVirusTotalTarget)] = []
        for link in links.prefix(256) {
            guard link.range.location >= 0, link.range.length > 0, link.range.location <= length,
                  link.range.length <= length - link.range.location, let range = Range(link.range, in: text) else { continue }
            occupied.append(link.range)
            if let target = try? WhitegramVirusTotalTarget.parse(link.url ?? String(text[range])) {
                candidates.append((link.range.location, target))
            }
        }
        for (index, pattern) in self.patterns.enumerated() {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: length)) {
                guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }), let range = Range(match.range, in: text) else { continue }
                var value = String(text[range])
                if index == 0 {
                    occupied.append(match.range)
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!"))
                    for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
                        while value.hasSuffix(close), value.components(separatedBy: close).count > value.components(separatedBy: open).count { value.removeLast() }
                    }
                }
                if let target = try? WhitegramVirusTotalTarget.parse(value) {
                    candidates.append((match.range.location, target))
                    if index != 0 { occupied.append(match.range) }
                }
            }
        }
        var seen = Set<WhitegramVirusTotalTarget>()
        return Array(candidates.sorted { $0.0 < $1.0 }.compactMap { seen.insert($0.1).inserted ? $0.1 : nil }.prefix(self.maximumTargets))
    }
}
