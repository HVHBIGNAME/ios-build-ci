import Foundation

public enum WhitegramLocalizationStoreError: Error {
    case invalidFile
    case emptyPack
    case oversizedFile
}

public final class WhitegramLocalizationStore {
    public static let changedNotification = Notification.Name("WhitegramLocalizationUpdated")
    public static let maximumFileBytes = 8 * 1024 * 1024
    public static let shared = WhitegramLocalizationStore(
        fileURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wg_localization.json"),
        defaults: .standard
    )

    private let fileURL: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var loaded = false
    private var cached: WhitegramLocalizationPack?
    private var loadError: Error?

    public init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    public func activePack() throws -> WhitegramLocalizationPack? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            do { cached = try load() }
            catch { loadError = error }
            loaded = true
        }
        if let loadError { throw loadError }
        return cached
    }

    private func load() throws -> WhitegramLocalizationPack? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Self.readRegularFile(fileURL)
        let entries = try JSONDecoder().decode([String: String].self, from: data)
        guard !entries.isEmpty else { throw WhitegramLocalizationStoreError.emptyPack }
        return WhitegramLocalizationPack(
            name: defaults.string(forKey: "wg_customLocalizationName") ?? "Localization",
            author: defaults.string(forKey: "wg_customLocalizationAuthor") ?? "",
            languageCode: defaults.string(forKey: "wg_customLocalizationLanguage") ?? "",
            entries: entries
        )
    }

    public func apply(_ pack: WhitegramLocalizationPack) throws {
        guard !pack.entries.isEmpty else { throw WhitegramLocalizationStoreError.emptyPack }
        let data = try JSONEncoder().encode(pack.entries)
        guard data.count <= Self.maximumFileBytes else { throw WhitegramLocalizationStoreError.oversizedFile }
        lock.lock()
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try Self.readRegularFile(fileURL)
            }
            try data.write(to: fileURL, options: .atomic)
            defaults.set(pack.name, forKey: "wg_customLocalizationName")
            defaults.set(pack.author, forKey: "wg_customLocalizationAuthor")
            defaults.set(pack.languageCode, forKey: "wg_customLocalizationLanguage")
            cached = pack
            loaded = true
            loadError = nil
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    public func remove() throws {
        lock.lock()
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            for key in ["wg_customLocalizationName", "wg_customLocalizationAuthor", "wg_customLocalizationLanguage"] {
                defaults.removeObject(forKey: key)
            }
            cached = nil
            loadError = nil
            loaded = true
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    public static func readRegularFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw WhitegramLocalizationStoreError.invalidFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WhitegramLocalizationStoreError.invalidFile }
        guard let size = values.fileSize, size <= maximumFileBytes else { throw WhitegramLocalizationStoreError.oversizedFile }
        guard let stream = InputStream(url: url) else { throw WhitegramLocalizationStoreError.invalidFile }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let chunkSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = stream.read(&buffer, maxLength: chunkSize)
            guard count >= 0 else { throw stream.streamError ?? WhitegramLocalizationStoreError.invalidFile }
            if count == 0 { break }
            guard result.count <= maximumFileBytes - count else { throw WhitegramLocalizationStoreError.oversizedFile }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
