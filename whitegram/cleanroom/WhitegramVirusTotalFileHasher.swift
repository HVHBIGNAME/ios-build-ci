import Foundation
#if canImport(CryptoKit) && canImport(Darwin)
import CryptoKit
import Darwin
#endif

public struct WhitegramVirusTotalFileHash: Equatable {
    public let sha256: String
    public let byteCount: Int64
    public let fileName: String
}

public enum WhitegramVirusTotalFileHasher {
    private static let queue = DispatchQueue(label: "Whitegram.VirusTotal.Hash", qos: .userInitiated)

    /// Reads a security-scoped file in bounded chunks on a background queue. No bytes are uploaded or copied to app storage.
    /// Completion and optional (bytes read, total bytes) progress run on the main queue.
    @discardableResult
    public static func hash(url: URL, progress: ((Int64, Int64) -> Void)? = nil, completion: @escaping (Result<WhitegramVirusTotalFileHash, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let operation = WhitegramServiceOperation(completion: completion)
        #if canImport(CryptoKit) && canImport(Darwin)
        if #available(iOS 13.4, macOS 10.15.4, *) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            operation.task.onCancel { coordinator.cancel() }
            self.queue.async {
                let result = whitegramServiceResult {
                    try self.coordinatedHash(url: url, coordinator: coordinator, task: operation.task, progress: progress)
                }
                operation.finish(result)
            }
        } else {
            operation.finish(.failure(.hashingUnavailable))
        }
        #else
        operation.finish(.failure(.hashingUnavailable))
        #endif
        return operation.task
    }
}

#if canImport(CryptoKit) && canImport(Darwin)
extension WhitegramVirusTotalFileHasher {
    @available(iOS 13.4, macOS 10.15.4, *)
    private static func coordinatedHash(url: URL, coordinator: NSFileCoordinator, task: WhitegramServiceTask, progress: ((Int64, Int64) -> Void)?) throws -> WhitegramVirusTotalFileHash {
        guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
        guard url.isFileURL else { throw WhitegramServiceError.fileUnreadable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Reject an already-local oversized file or symlink before a file provider can resolve it.
        var local = stat()
        if lstat(url.path, &local) == 0 {
            guard (local.st_mode & S_IFMT) == S_IFREG else { throw WhitegramServiceError.notRegularFile }
            guard local.st_size <= WhitegramServiceLimits.maximumFileBytes else { throw WhitegramServiceError.fileTooLarge }
        }
        var coordinationError: NSError?
        var result: Result<WhitegramVirusTotalFileHash, WhitegramServiceError>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            result = whitegramServiceResult { try self.readHash(url: readableURL, task: task, progress: progress) }
        }
        guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
        guard coordinationError == nil, let result = result else { throw WhitegramServiceError.fileUnreadable }
        return try result.get()
    }

    @available(iOS 13.4, macOS 10.15.4, *)
    private static func readHash(url: URL, task: WhitegramServiceTask, progress: ((Int64, Int64) -> Void)?) throws -> WhitegramVirusTotalFileHash {
        do {
            guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true else { throw WhitegramServiceError.notRegularFile }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(handle.fileDescriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw WhitegramServiceError.notRegularFile }
            guard before.st_size >= 0 else { throw WhitegramServiceError.fileUnreadable }
            guard before.st_size <= WhitegramServiceLimits.maximumFileBytes else { throw WhitegramServiceError.fileTooLarge }
            var hasher = SHA256()
            var count: Int64 = 0
            var lastProgress: TimeInterval = 0
            while true {
                guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
                let chunk = try autoreleasepool { try handle.read(upToCount: WhitegramServiceLimits.fileChunkBytes) ?? Data() }
                if chunk.isEmpty { break }
                count += Int64(chunk.count)
                guard count <= WhitegramServiceLimits.maximumFileBytes else { throw WhitegramServiceError.fileTooLarge }
                hasher.update(data: chunk)
                let now = ProcessInfo.processInfo.systemUptime
                if let progress = progress, now - lastProgress >= 0.2 {
                    lastProgress = now
                    let bytesRead = count
                    let total = Int64(before.st_size)
                    DispatchQueue.main.async {
                        if !task.isCancelled { progress(bytesRead, total) }
                    }
                }
            }
            guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
            var after = stat()
            var pathInfo = stat()
            guard fstat(handle.fileDescriptor, &after) == 0, lstat(url.path, &pathInfo) == 0,
                  count == before.st_size, before.st_size == after.st_size,
                  before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino,
                  (pathInfo.st_mode & S_IFMT) == S_IFREG,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw WhitegramServiceError.fileChanged
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return WhitegramVirusTotalFileHash(sha256: digest, byteCount: count, fileName: url.lastPathComponent)
        } catch let error as WhitegramServiceError {
            throw error
        } catch {
            throw WhitegramServiceError.fileUnreadable
        }
    }
}
#endif
