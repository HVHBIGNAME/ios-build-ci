import Foundation

/// Owns the private multipart snapshot until URLSession has finished with it.
final class WhitegramVirusTotalUpload {
    let bodyFile: URL
    let boundary: String
    let bodyBytes: Int64
    let file: WhitegramVirusTotalFileHash

    init(bodyFile: URL, boundary: String, bodyBytes: Int64, file: WhitegramVirusTotalFileHash) {
        self.bodyFile = bodyFile
        self.boundary = boundary
        self.bodyBytes = bodyBytes
        self.file = file
    }

    deinit {
        try? FileManager.default.removeItem(at: self.bodyFile.deletingLastPathComponent())
    }

    static func header(boundary: String, fileName: String) throws -> Data {
        guard !boundary.isEmpty, boundary.utf8.count <= 80,
              fileName.utf8.count <= 1024,
              boundary.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw WhitegramServiceError.invalidResponse
        }
        // Quoted multipart parameters cannot contain raw CR/LF, quotes or backslashes.
        let name = String(fileName.prefix(240)).replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "\0", with: "%00")
        return Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name.isEmpty ? "file" : name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
    }

    @discardableResult
    static func prepare(url: URL, expectedHash: String?, fileName: String?, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<WhitegramVirusTotalUpload, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let operation = WhitegramServiceOperation(completion: completion)
        #if canImport(CryptoKit) && canImport(Darwin)
        if #available(iOS 13.4, macOS 10.15.4, *) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            operation.task.onCancel { coordinator.cancel() }
            WhitegramVirusTotalFileHasher.queue.async {
                operation.finish(whitegramServiceResult {
                    try self.snapshot(url: url, expectedHash: expectedHash, fileName: fileName, coordinator: coordinator, task: operation.task, progress: progress)
                })
            }
        } else {
            operation.finish(.failure(.uploadUnavailable))
        }
        #else
        operation.finish(.failure(.uploadUnavailable))
        #endif
        return operation.task
    }

    #if canImport(CryptoKit) && canImport(Darwin)
    @available(iOS 13.4, macOS 10.15.4, *)
    private static func snapshot(url: URL, expectedHash: String?, fileName: String?, coordinator: NSFileCoordinator, task: WhitegramServiceTask, progress: @escaping (Int64, Int64) -> Void) throws -> WhitegramVirusTotalUpload {
        guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-vt-" + UUID().uuidString, isDirectory: true)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        do {
            #if os(iOS)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
            #else
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            #endif
            let boundary = "Whitegram-" + UUID().uuidString
            let bodyFile = directory.appendingPathComponent("body.multipart")
            let header = try self.header(boundary: boundary, fileName: fileName ?? url.lastPathComponent)
            #if os(iOS)
            try header.write(to: bodyFile, options: .completeFileProtection)
            #else
            try header.write(to: bodyFile)
            #endif
            let handle = try FileHandle(forWritingTo: bodyFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let file = try WhitegramVirusTotalFileHasher.coordinatedHash(url: url, coordinator: coordinator, task: task, progress: progress, consume: { chunk in
                try handle.write(contentsOf: chunk)
            })
            if let expectedHash, try WhitegramVirusTotalWire.validatedHash(expectedHash) != file.sha256 { throw WhitegramServiceError.fileChanged }
            guard !task.isCancelled else { throw WhitegramServiceError.cancelled }
            let footer = Data("\r\n--\(boundary)--\r\n".utf8)
            try handle.write(contentsOf: footer)
            try handle.synchronize()
            retained = true
            return WhitegramVirusTotalUpload(bodyFile: bodyFile, boundary: boundary, bodyBytes: Int64(header.count) + file.byteCount + Int64(footer.count), file: file)
        } catch let error as WhitegramServiceError {
            throw error
        } catch {
            throw WhitegramServiceError.fileUnreadable
        }
    }
    #endif
}
