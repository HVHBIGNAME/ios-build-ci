import Foundation
import TelegramCore
#if canImport(Darwin)
import Darwin
#endif

enum WhitegramSettingsTransferDocumentError: Error, LocalizedError {
    case unavailable, unreadable, notRegular, changed, cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "File import requires iOS 13.4 or later."
        case .unreadable: return "The settings document could not be read. Try downloading it in Files first."
        case .notRegular: return "Choose a regular JSON settings file, not a folder, package or symbolic link."
        case .changed: return "The document changed while it was being read. Nothing was imported."
        case .cancelled: return "Settings document import cancelled."
        }
    }
}

final class WhitegramSettingsTransferWork {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !started else { return false }
        started = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class WhitegramSettingsTransferDocumentRead {
    private let lock = NSLock()
    private var cancelled = false
    #if canImport(Darwin)
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    #endif

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        #if canImport(Darwin)
        coordinator.cancel()
        #endif
    }

    private func checkCancellation() throws {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { throw WhitegramSettingsTransferDocumentError.cancelled }
    }

    func read(_ url: URL) throws -> WhitegramSettingsArchive {
        #if canImport(Darwin)
        guard url.isFileURL else { throw WhitegramSettingsTransferDocumentError.notRegular }
        guard #available(iOS 13.4, macOS 10.15.4, *) else { throw WhitegramSettingsTransferDocumentError.unavailable }
        try checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var local = stat()
        if lstat(url.path, &local) == 0 {
            guard (local.st_mode & S_IFMT) == S_IFREG else { throw WhitegramSettingsTransferDocumentError.notRegular }
            guard local.st_size <= WhitegramSettingsArchive.maximumBytes else { throw WhitegramSettingsArchiveError.tooLarge }
        }
        var error: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { location in
            result = Result { try readBounded(location) }
        }
        try checkCancellation()
        guard error == nil, let result else { throw WhitegramSettingsTransferDocumentError.unreadable }
        return try WhitegramSettingsArchive(data: result.get())
        #else
        throw WhitegramSettingsTransferDocumentError.unavailable
        #endif
    }

    #if canImport(Darwin)
    @available(iOS 13.4, macOS 10.15.4, *)
    private func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true else { throw WhitegramSettingsTransferDocumentError.notRegular }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw WhitegramSettingsTransferDocumentError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw WhitegramSettingsTransferDocumentError.notRegular }
        guard before.st_size >= 0, before.st_size <= WhitegramSettingsArchive.maximumBytes else { throw WhitegramSettingsArchiveError.tooLarge }
        var data = Data()
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: min(16384, WhitegramSettingsArchive.maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= WhitegramSettingsArchive.maximumBytes else { throw WhitegramSettingsArchiveError.tooLarge }
        }
        var after = stat()
        var path = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              before.st_size == data.count, before.st_size == after.st_size,
              before.st_dev == path.st_dev, before.st_ino == path.st_ino, (path.st_mode & S_IFMT) == S_IFREG,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw WhitegramSettingsTransferDocumentError.changed }
        try handle.close()
        return data
    }
    #endif
}

final class WhitegramSettingsTransferExportFile {
    let url: URL
    private let directory: URL

    init(_ archive: WhitegramSettingsArchive, parent: URL = FileManager.default.temporaryDirectory) throws {
        directory = parent.appendingPathComponent("WhitegramSettingsTransfer-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Whitegram-Settings.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try archive.encoded().write(to: url, options: options)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("Whitegram: settings export staging cleanup failed") }
            throw error
        }
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    deinit {
        do { try remove() }
        catch { NSLog("Whitegram: settings export cleanup failed") }
    }
}
