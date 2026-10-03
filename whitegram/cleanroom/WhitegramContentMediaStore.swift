import Foundation

/// Account-local copies are kept outside MediaBox so normal expiry/cache eviction remains valid.
public enum WhitegramContentMediaStore {
    public enum Kind: String, Codable { case image, video, audio }

    public struct Entry: Codable, Equatable {
        public let id: String
        public let fileName: String
        public let kind: Kind
        public let timestamp: Int32
        public let byteCount: Int64
        public let viewOnce: Bool
        public var photoLibraryIdentifier: String?
    }

    public struct Candidate {
        public let id: String
        public let source: URL
        public let kind: Kind
        public let timestamp: Int32
        public let viewOnce: Bool

        public init(id: String, source: URL, kind: Kind, timestamp: Int32, viewOnce: Bool) {
            self.id = id
            self.source = source
            self.kind = kind
            self.timestamp = timestamp
            self.viewOnce = viewOnce
        }
    }

    public enum StoreError: Error { case invalidIdentifier, unavailableResource, invalidEntry }
    public static let updated = Notification.Name("WhitegramContentMediaUpdated")
    public static let captured = Notification.Name("WhitegramContentMediaCaptured")
    private static let lock = NSRecursiveLock()

    private static func validId(_ id: String) -> Bool {
        return !id.isEmpty && id.utf8.count < 128 && id.utf8.allSatisfy { (48 ... 57).contains($0) || $0 == 45 || $0 == 95 }
    }

    public static func root(mediaBoxPath: String) -> URL {
        return URL(fileURLWithPath: mediaBoxPath, isDirectory: true).deletingLastPathComponent().appendingPathComponent("whitegram-retained-media", isDirectory: true)
    }

    public static func fileURL(root: URL, entry: Entry) throws -> URL {
        guard validId(entry.id), ["media.jpg", "media.mp4", "media.ogg"].contains(entry.fileName) else { throw StoreError.invalidEntry }
        return root.appendingPathComponent(entry.id, isDirectory: true).appendingPathComponent(entry.fileName)
    }

    public static func entries(root: URL) throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { validId($0.lastPathComponent) }
            .map { directory in
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: directory.appendingPathComponent("entry.json")))
                guard entry.id == directory.lastPathComponent else { throw StoreError.invalidEntry }
                let file = try fileURL(root: root, entry: entry)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == entry.byteCount else { throw StoreError.invalidEntry }
                return entry
            }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
    }

    @discardableResult
    public static func capture(root: URL, candidate: Candidate) throws -> Entry {
        lock.lock()
        defer { lock.unlock() }
        guard validId(candidate.id) else { throw StoreError.invalidIdentifier }
        let manager = FileManager.default
        let destination = root.appendingPathComponent(candidate.id, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: destination.appendingPathComponent("entry.json")))
            guard entry.id == candidate.id else { throw StoreError.invalidEntry }
            let file = try fileURL(root: root, entry: entry)
            let size = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard size.isRegularFile == true, Int64(size.fileSize ?? -1) == entry.byteCount else { throw StoreError.invalidEntry }
            return entry
        }
        let values = try candidate.source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else { throw StoreError.unavailableResource }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".capture-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let name: String
        switch candidate.kind {
        case .image: name = "media.jpg"
        case .video: name = "media.mp4"
        case .audio: name = "media.ogg"
        }
        let copied = staging.appendingPathComponent(name)
        try manager.copyItem(at: candidate.source, to: copied)
        let copiedSize = try copied.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard copiedSize == size else { throw StoreError.unavailableResource }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copied.path)
        #endif
        let entry = Entry(id: candidate.id, fileName: name, kind: candidate.kind, timestamp: candidate.timestamp, byteCount: Int64(size), viewOnce: candidate.viewOnce, photoLibraryIdentifier: nil)
        try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        return entry
    }

    public static func markSavedToPhotos(root: URL, entry: Entry, identifier: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !identifier.isEmpty else { throw StoreError.invalidEntry }
        _ = try fileURL(root: root, entry: entry)
        var updatedEntry = entry
        updatedEntry.photoLibraryIdentifier = identifier
        try JSONEncoder().encode(updatedEntry).write(to: root.appendingPathComponent(entry.id).appendingPathComponent("entry.json"), options: .atomic)
    }

    public static func remove(root: URL, entry: Entry) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try fileURL(root: root, entry: entry)
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.id, isDirectory: true))
    }

    public static func lastError(root: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: root.appendingPathComponent("last-error.txt"), encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func recordError(root: URL, message: String?) {
        lock.lock()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (message ?? "").write(to: root.appendingPathComponent("last-error.txt"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("Whitegram: could not persist the retained-media error (%@)", String(describing: type(of: error)))
        }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: updated, object: root) }
    }
}
