import Foundation
import CoreFoundation
#if canImport(TelegramCore)
import TelegramCore
#endif

struct WhitegramPluginError: Error, LocalizedError {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    var errorDescription: String? { return "\(self.code): \(self.message)" }
    var json: [String: Any] { return ["code": self.code, "message": self.message] }

    static func wrap(_ error: Error) -> WhitegramPluginError {
        return (error as? WhitegramPluginError) ?? WhitegramPluginError("IO_ERROR", error.localizedDescription)
    }
}

enum WhitegramPluginPermission: String, CaseIterable {
    case storage
    case uiMutation
    case account
    case messages
    case media
    case network
    case settings
    case clipboard

    var title: String {
        switch self {
        case .storage: return "Plugin files and storage"
        case .uiMutation: return "Plugin screens and dialogs"
        case .account: return "Read your account profile"
        case .messages: return "Read and send messages"
        case .media: return "Send plugin files"
        case .network: return "HTTP requests"
        case .settings: return "Read and change Whitegram settings"
        case .clipboard: return "Read and write clipboard"
        }
    }

    var defaultGranted: Bool { return self == .storage || self == .uiMutation }

    static func key(accountId: String, pluginId: String) -> String {
        return "pluginRuntime.permissions.\(accountId).\(pluginId)"
    }

    static func grants(accountId: String, pluginId: String) -> [String: Bool] {
        let stored = (WhitegramPreferences.values()[self.key(accountId: accountId, pluginId: pluginId)] as? [String: Bool]) ?? [:]
        return Dictionary(uniqueKeysWithValues: self.allCases.map { ($0.rawValue, stored[$0.rawValue] ?? $0.defaultGranted) })
    }
}

struct WhitegramPluginRecord: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let entry: String
    let permissions: [String]
    let installedAt: Date
}

// No caller-controlled path is passed to Foundation before lexical validation.
// Existing path components are checked as well: standardizing a URL alone does
// not prevent escaping through a symlink.
enum WhitegramPluginPath {
    static func components(_ path: String, allowEmpty: Bool = false) throws -> [String] {
        if allowEmpty && path.isEmpty { return [] }
        guard !path.isEmpty, path.utf8.count <= 1024,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw WhitegramPluginError("INVALID_PATH", "Expected a relative plugin path")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw WhitegramPluginError("INVALID_PATH", "Empty, dot and parent path components are not allowed")
        }
        return parts
    }

    static func url(root: URL, path: String, allowEmpty: Bool = false) throws -> URL {
        let parts = try self.components(path, allowEmpty: allowEmpty)
        guard root.isFileURL else { throw WhitegramPluginError("INVALID_PATH", "Plugin roots must be local directories") }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: root.standardizedFileURL.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw WhitegramPluginError("INVALID_PATH", "Symbolic links are not permitted as plugin roots")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var result = base
        for part in parts {
            result.appendPathComponent(part, isDirectory: false)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: result.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw WhitegramPluginError("INVALID_PATH", "Symbolic links are not permitted in plugin files")
            }
        }
        let resolved = result.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else {
            throw WhitegramPluginError("INVALID_PATH", "Path escapes the plugin directory")
        }
        return resolved
    }

    static func modulePath(directory: String, name: String) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw WhitegramPluginError("INVALID_PATH", "Invalid module name")
        }
        var parts = try self.components(directory, allowEmpty: true)
        for part in name.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw WhitegramPluginError("INVALID_PATH", "Module escapes the package") }
                parts.removeLast()
            } else {
                _ = try self.components(part)
                parts.append(part)
            }
        }
        let path = parts.joined(separator: "/")
        _ = try self.components(path)
        return path
    }
}

final class WhitegramPluginStorage {
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumPackageBytes = 8 * 1024 * 1024
    static let maximumImportBytes = 12 * 1024 * 1024
    static let maximumDataBytes = 16 * 1024 * 1024
    static let maximumFiles = 256
    let root: URL

    init(accountId: String) throws {
        guard try WhitegramPluginPath.components(accountId).count == 1 else { throw WhitegramPluginError("INVALID_PATH", "Invalid account directory") }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.root = try WhitegramPluginPath.url(root: base, path: "WhitegramPlugins/v1/" + accountId)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func pluginRoot(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw WhitegramPluginError("INVALID_PLUGIN", "Invalid installation identifier") }
        return try WhitegramPluginPath.url(root: self.root, path: id)
    }

    func records() throws -> [WhitegramPluginRecord] {
        let directories = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)
        var result: [WhitegramPluginRecord] = []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let manifest = try WhitegramPluginPath.url(root: self.root, path: directory.lastPathComponent + "/manifest.json")
            let record = try JSONDecoder().decode(WhitegramPluginRecord.self, from: Self.readLimited(manifest))
            guard record.id == directory.lastPathComponent else { throw WhitegramPluginError("INVALID_PLUGIN", "Installation manifest does not match its directory") }
            _ = try WhitegramPluginPath.components(record.entry)
            result.append(record)
        }
        return result.sorted { $0.installedAt < $1.installedAt }
    }

    func install(from url: URL) throws -> WhitegramPluginRecord {
        let data = try Self.readLimited(url, limit: Self.maximumImportBytes)
        let name: String
        let version: String
        let entry: String
        let permissions: [String]
        var files: [String: Data] = [:]
        if url.pathExtension.lowercased() == "js" {
            guard String(data: data, encoding: .utf8) != nil else { throw WhitegramPluginError("INVALID_PACKAGE", "JavaScript must be UTF-8") }
            name = url.deletingPathExtension().lastPathComponent
            version = "1.0"
            entry = "main.js"
            permissions = []
            files[entry] = data
        } else {
            guard ["json", "wgplugin"].contains(url.pathExtension.lowercased()),
                  let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sourceFiles = package["files"] as? [String: Any],
                  let packageName = package["name"] as? String,
                  let packageEntry = (package["entry"] ?? package["main"]) as? String else {
                throw WhitegramPluginError("INVALID_PACKAGE", "Import a .js file or a JSON package with name, entry and files")
            }
            if let runtime = package["runtime"] {
                guard let runtime = runtime as? String, ["javascript", "js"].contains(runtime.lowercased()) else {
                    throw WhitegramPluginError("UNSUPPORTED_LANGUAGE", "This build runs JavaScript plugins only")
                }
            }
            if let version = package["version"], !(version is String) {
                throw WhitegramPluginError("INVALID_PACKAGE", "version must be a string")
            }
            if let permissions = package["permissions"], !(permissions is [String]) {
                throw WhitegramPluginError("INVALID_PACKAGE", "permissions must be an array of strings")
            }
            name = packageName
            version = (package["version"] as? String) ?? "1.0"
            entry = packageEntry
            permissions = (package["permissions"] as? [String]) ?? []
            for (path, value) in sourceFiles {
                if let source = value as? String {
                    files[path] = Data(source.utf8)
                } else if let encoded = value as? [String: String], let base64 = encoded["base64"], let bytes = Data(base64Encoded: base64) {
                    files[path] = bytes
                } else {
                    throw WhitegramPluginError("INVALID_PACKAGE", "File \(path) must be UTF-8 text or {base64: ...}")
                }
            }
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512, version.utf8.count <= 128,
              entry.hasSuffix(".js"), let source = files[entry], String(data: source, encoding: .utf8) != nil else {
            throw WhitegramPluginError("INVALID_PACKAGE", "A nonempty name and UTF-8 JavaScript entry are required")
        }
        guard permissions.allSatisfy({ WhitegramPluginPermission(rawValue: $0) != nil }) else {
            throw WhitegramPluginError("UNSUPPORTED_PERMISSION", "Package declares permissions not implemented by this runtime")
        }
        guard !files.isEmpty, files.count <= Self.maximumFiles,
              files.values.allSatisfy({ $0.count <= Self.maximumFileBytes }),
              files.values.reduce(0, { $0 + $1.count }) <= Self.maximumPackageBytes else {
            throw WhitegramPluginError("QUOTA_EXCEEDED", "Package exceeds its file count or size limit")
        }
        for path in files.keys { _ = try WhitegramPluginPath.components(path) }
        let canonicalPaths = files.keys.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(canonicalPaths).count == files.count else {
            throw WhitegramPluginError("INVALID_PACKAGE", "Package paths collide on a case-insensitive filesystem")
        }
        let filePaths = Set(canonicalPaths)
        for path in canonicalPaths {
            let components = path.split(separator: "/")
            for length in 1 ..< components.count where filePaths.contains(components.prefix(length).joined(separator: "/")) {
                throw WhitegramPluginError("INVALID_PACKAGE", "A package file cannot also be a directory")
            }
        }
        let record = WhitegramPluginRecord(id: UUID().uuidString.lowercased(), name: name, version: version, entry: entry, permissions: permissions, installedAt: Date())
        let destination = try self.pluginRoot(record.id)
        let directory = try WhitegramPluginPath.url(root: self.root, path: ".install-" + record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let packageRoot = directory.appendingPathComponent("package", isDirectory: true)
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
            for (path, bytes) in files {
                let target = try WhitegramPluginPath.url(root: packageRoot, path: path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("data/files", isDirectory: true), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            try FileManager.default.moveItem(at: directory, to: destination)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw WhitegramPluginError("IO_ERROR", "Import failed and its incomplete directory could not be removed: \(error.localizedDescription)") }
            throw error
        }
        return record
    }

    func remove(_ id: String) throws {
        try FileManager.default.removeItem(at: self.pluginRoot(id))
    }

    static func readLimited(_ url: URL, limit: Int = maximumFileBytes) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WhitegramPluginError("INVALID_PATH", "Expected a regular file") }
        guard let size = values.fileSize, size <= limit else { throw WhitegramPluginError("QUOTA_EXCEEDED", "File exceeds \(limit) bytes") }
        guard let stream = InputStream(url: url) else { throw WhitegramPluginError("IO_ERROR", "Could not open the plugin file") }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        // A selected document can change after stat; never allocate its new,
        // unbounded size just to reject it after the read.
        while data.count <= limit {
            let remaining = limit - data.count
            let count = stream.read(&buffer, maxLength: remaining >= buffer.count ? buffer.count : remaining + 1)
            guard count >= 0 else { throw WhitegramPluginError("IO_ERROR", stream.streamError?.localizedDescription ?? "Could not read the plugin file") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { throw WhitegramPluginError("QUOTA_EXCEEDED", "File exceeds \(limit) bytes") }
        return data
    }
}

// Owned exclusively by a plugin's JavaScript queue.
final class WhitegramPluginFiles {
    private let root: URL
    private var state: [String: Any]?

    init(root: URL) throws {
        self.root = try WhitegramPluginPath.url(root: root, path: "", allowEmpty: true)
        for path in ["package", "data", "data/files"] { _ = try self.directory(path) }
    }

    private func directory(_ path: String) throws -> URL {
        return try WhitegramPluginPath.url(root: self.root, path: path)
    }

    func packageFile(_ path: String) throws -> Data? {
        let url = try WhitegramPluginPath.url(root: self.directory("package"), path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try WhitegramPluginStorage.readLimited(url)
    }

    func resolveModule(directory: String, name: String) throws -> [String: Any] {
        let path = try WhitegramPluginPath.modulePath(directory: directory, name: name)
        let packageRoot = try self.directory("package")
        for candidate in [path, path + ".js", path + ".json", path + "/index.js", path + "/index.json"] {
            let url = try WhitegramPluginPath.url(root: packageRoot, path: candidate)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let kind = url.pathExtension.lowercased()
            guard ["js", "json"].contains(kind) else { throw WhitegramPluginError("UNSUPPORTED_LANGUAGE", "require supports .js and .json modules only") }
            guard let source = String(data: try WhitegramPluginStorage.readLimited(url), encoding: .utf8) else { throw WhitegramPluginError("INVALID_ENCODING", "Module is not UTF-8") }
            let directory = candidate.split(separator: "/").dropLast().joined(separator: "/")
            return ["path": candidate, "dir": directory, "kind": kind, "source": source]
        }
        throw WhitegramPluginError("MODULE_NOT_FOUND", "Cannot resolve \(name) from \(directory)")
    }

    private func list(root: URL, path: String = "") throws -> [String] {
        let start = try WhitegramPluginPath.url(root: root, path: path, allowEmpty: true)
        var result: [String] = []
        func visit(_ directory: URL, prefix: String) throws {
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let relative = prefix + item.lastPathComponent
                _ = try WhitegramPluginPath.url(root: root, path: relative)
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw WhitegramPluginError("INVALID_PATH", "Symbolic links are not allowed") }
                if values.isDirectory == true {
                    try visit(item, prefix: relative + "/")
                } else {
                    result.append(relative)
                    guard result.count <= WhitegramPluginStorage.maximumFiles else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Too many plugin files") }
                }
            }
        }
        try visit(start, prefix: path.isEmpty ? "" : path + "/")
        return result.sorted()
    }

    func packageFiles() throws -> [String] { return try self.list(root: self.directory("package")) }

    func storage(_ operation: String, arguments: [Any]) throws -> Any {
        let dataRoot = try self.directory("data")
        if self.state == nil {
            let url = try WhitegramPluginPath.url(root: dataRoot, path: "state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                guard let state = try JSONSerialization.jsonObject(with: WhitegramPluginStorage.readLimited(url)) as? [String: Any] else {
                    throw WhitegramPluginError("INVALID_STORAGE", "Plugin state must be a JSON object")
                }
                self.state = state
            } else {
                self.state = [:]
            }
        }
        var state = self.state ?? [:]
        if operation == "keys" { return state.keys.sorted() }
        if operation == "get" {
            let key = try whitegramPluginString(arguments, 0)
            return state[key] ?? (arguments.count > 1 ? arguments[1] : NSNull())
        }
        switch operation {
        case "set":
            let key = try whitegramPluginString(arguments, 0)
            guard key.utf8.count <= 1024, arguments.count == 2 else { throw WhitegramPluginError("INVALID_ARGUMENT", "storage.set expects key and JSON value") }
            state[key] = arguments[1]
        case "remove": state.removeValue(forKey: try whitegramPluginString(arguments, 0))
        case "clear": state.removeAll()
        default: throw WhitegramPluginError("UNSUPPORTED_API", "storage.\(operation)")
        }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard data.count <= WhitegramPluginStorage.maximumFileBytes else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Plugin JSON storage is full") }
        try data.write(to: WhitegramPluginPath.url(root: dataRoot, path: "state.json"), options: .atomic)
        self.state = state
        return true
    }

    func file(_ operation: String, arguments: [Any]) throws -> Any {
        let filesRoot = try self.directory("data/files")
        if operation == "list" { return try self.list(root: filesRoot, path: arguments.isEmpty || arguments[0] is NSNull ? "" : whitegramPluginString(arguments, 0)) }
        let path = try whitegramPluginString(arguments, 0)
        let url = try WhitegramPluginPath.url(root: filesRoot, path: path)
        switch operation {
        case "exists": return FileManager.default.fileExists(atPath: url.path)
        case "read", "readBase64", "readBytes":
            guard FileManager.default.fileExists(atPath: url.path) else { return NSNull() }
            let data = try WhitegramPluginStorage.readLimited(url)
            if operation == "readBase64" { return data.base64EncodedString() }
            if operation == "readBytes" { return ["__wgBase64": data.base64EncodedString()] }
            guard let text = String(data: data, encoding: .utf8) else { throw WhitegramPluginError("INVALID_ENCODING", "File is not UTF-8; use readBase64 or readBytes") }
            return text
        case "write", "writeBase64", "writeBytes":
            let bytes: Data
            if operation == "write" {
                bytes = Data(try whitegramPluginString(arguments, 1).utf8)
            } else {
                let base64: String
                if operation == "writeBytes", arguments.count > 1, let value = arguments[1] as? [String: String], let encoded = value["__wgBase64"] {
                    base64 = encoded
                } else {
                    base64 = try whitegramPluginString(arguments, 1)
                }
                guard let decoded = Data(base64Encoded: base64) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid base64 data") }
                bytes = decoded
            }
            guard bytes.count <= WhitegramPluginStorage.maximumFileBytes else { throw WhitegramPluginError("QUOTA_EXCEEDED", "File is too large") }
            let files = try self.list(root: filesRoot)
            guard files.contains(path) || files.count < WhitegramPluginStorage.maximumFiles else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Too many plugin files") }
            var size = bytes.count
            for file in files where file != path {
                let existing = try WhitegramPluginPath.url(root: filesRoot, path: file)
                size += try existing.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
            guard size <= WhitegramPluginStorage.maximumDataBytes else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Plugin file storage is full") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            return true
        case "remove":
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        default: throw WhitegramPluginError("UNSUPPORTED_API", "fs.\(operation)")
        }
    }
}

func whitegramPluginString(_ arguments: [Any], _ index: Int) throws -> String {
    guard arguments.indices.contains(index), let value = arguments[index] as? String else {
        throw WhitegramPluginError("INVALID_ARGUMENT", "Argument \(index + 1) must be a string")
    }
    return value
}

func whitegramPluginNumber(_ arguments: [Any], _ index: Int, default fallback: Double? = nil) throws -> Double {
    if !arguments.indices.contains(index) || arguments[index] is NSNull {
        if let fallback = fallback { return fallback }
    }
    guard arguments.indices.contains(index), let value = arguments[index] as? NSNumber, value.doubleValue.isFinite,
          CFGetTypeID(value) != CFBooleanGetTypeID() else {
        throw WhitegramPluginError("INVALID_ARGUMENT", "Argument \(index + 1) must be a finite number")
    }
    return value.doubleValue
}

func whitegramPluginBool(_ arguments: [Any], _ index: Int, default fallback: Bool? = nil) throws -> Bool {
    if !arguments.indices.contains(index) || arguments[index] is NSNull {
        if let fallback = fallback { return fallback }
    }
    guard arguments.indices.contains(index), let value = arguments[index] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
        throw WhitegramPluginError("INVALID_ARGUMENT", "Argument \(index + 1) must be a boolean")
    }
    return value.boolValue
}
