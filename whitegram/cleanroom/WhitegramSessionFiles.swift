import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum WhitegramSessionFiles {
    public static let maximumFileBytes = 16 * 1024 * 1024
    public static let maximumTotalBytes = 64 * 1024 * 1024

    public static func read(_ url: URL, maximumBytes: Int = maximumFileBytes) throws -> Data {
        guard url.isFileURL else { throw WhitegramSessionError.unsafeFile }
        #if canImport(Darwin)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw WhitegramSessionError.unreadable }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw WhitegramSessionError.unsafeFile }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw WhitegramSessionError.tooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - result.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw WhitegramSessionError.unreadable
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumBytes else { throw WhitegramSessionError.tooLarge }
        }
        var after = stat()
        var path = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              (path.st_mode & S_IFMT) == S_IFREG, before.st_size == result.count, before.st_size == after.st_size,
              before.st_dev == path.st_dev, before.st_ino == path.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw WhitegramSessionError.changedFile }
        return result
        #else
        throw WhitegramSessionError.unavailable
        #endif
    }

    public static func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.withoutOverwriting]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try data.write(to: url, options: options)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public final class WhitegramSessionCancellation {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let cancelled = self.cancelled; lock.unlock()
        if cancelled { throw WhitegramSessionError.cancelled }
    }
}

public final class WhitegramSessionStagingDirectory {
    public let url: URL

    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        self.url = parent.appendingPathComponent("WhitegramSessions-" + UUID().uuidString, isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: attributes)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = url
        try directory.setResourceValues(values)
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    deinit {
        // Explicit operation completion reports cleanup errors; deinit is the cancellation fallback.
        try? remove()
    }
}
