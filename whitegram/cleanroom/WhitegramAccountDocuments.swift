import Foundation
import TelegramCore

final class WhitegramAccountDocuments {
    let staging: WhitegramSessionStagingDirectory
    private let lock = NSLock()
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    private var cancelled = false
    private var totalBytes = 0
    private var sources: [Source] = []

    private enum Source { case archive(URL), telethon(URL, Data?), tdata(URL) }

    init() throws { staging = try WhitegramSessionStagingDirectory() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); coordinator.cancel() }
    private func checkCancellation() throws {
        lock.lock(); let cancelled = self.cancelled; lock.unlock()
        if cancelled { throw WhitegramSessionError.cancelled }
    }

    func prepare(_ urls: [URL]) throws {
        guard !urls.isEmpty, urls.count <= 300 else { throw WhitegramSessionError.tooLarge }
        var groups: [String: URL] = [:]
        var looseFiles: [URL] = []
        for url in urls {
            try checkCancellation()
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { location in
                result = Result {
                    let values = try location.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw WhitegramSessionError.unsafeFile }
                    if values.isDirectory == true {
                        let folder = staging.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        try copyTData(location, to: folder)
                        sources.append(.tdata(folder))
                    } else if location.pathExtension.lowercased() == "zip" {
                        let data = try boundedRead(location, limit: WhitegramSessionFiles.maximumTotalBytes)
                        let entries = try WhitegramSessionZip.decode(data)
                        let folder = staging.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        var files: [URL] = []
                        for entry in entries {
                            try checkCancellation()
                            guard entry.data.count <= WhitegramSessionFiles.maximumTotalBytes - totalBytes else { throw WhitegramSessionError.tooLarge }
                            totalBytes += entry.data.count
                            let destination = folder.appendingPathComponent(entry.name)
                            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try WhitegramSessionFiles.write(entry.data, to: destination)
                            files.append(destination)
                        }
                        try discover(files)
                    } else {
                        let group = url.deletingLastPathComponent().absoluteString
                        let folder: URL
                        if let existing = groups[group] { folder = existing }
                        else {
                            folder = staging.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                            groups[group] = folder
                        }
                        let destination = folder.appendingPathComponent(location.lastPathComponent)
                        try WhitegramSessionFiles.write(boundedRead(location), to: destination)
                        looseFiles.append(destination)
                    }
                }
            }
            guard error == nil, let result else { throw WhitegramSessionError.unreadable }
            try result.get()
        }
        try discover(looseFiles)
        guard !sources.isEmpty, sources.count <= WhitegramSessionBackup.maximumAccounts else { throw WhitegramSessionError.invalidFormat }
    }

    func parse(passcode: String = "") throws -> [WhitegramSessionBackup] {
        var result: [WhitegramSessionBackup] = []
        for source in sources {
            try checkCancellation()
            let items: [WhitegramSessionBackup]
            switch source {
            case let .archive(url): items = [try WhitegramSessionBackup(data: WhitegramSessionFiles.read(url, maximumBytes: WhitegramSessionBackup.maximumBytes))]
            case let .telethon(url, sidecar):
                let account = try WhitegramSessionTelethon.read(at: url, sidecar: sidecar)
                items = [try WhitegramSessionBackup(account: account, recordId: account.identity.userId)]
            case let .tdata(folder):
                items = try WhitegramSessionTData.read(directory: folder, passcode: passcode).map { try WhitegramSessionBackup(account: $0, recordId: $0.identity.userId) }
            }
            result = try WhitegramSessionBackup.unique(result + items)
        }
        try checkCancellation()
        guard !result.isEmpty else { throw WhitegramSessionError.invalidFormat }
        return result
    }

    private func boundedRead(_ url: URL, limit: Int = WhitegramSessionFiles.maximumFileBytes) throws -> Data {
        let data = try WhitegramSessionFiles.read(url, maximumBytes: min(limit, WhitegramSessionFiles.maximumTotalBytes - totalBytes))
        totalBytes += data.count
        return data
    }

    private func copyTData(_ source: URL, to destination: URL) throws {
        var source = source
        if !["s", "0", "1"].contains(where: { FileManager.default.fileExists(atPath: source.appendingPathComponent("key_data" + $0).path) }) {
            source = source.appendingPathComponent("tdata", isDirectory: true)
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw WhitegramSessionError.unsafeFile }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        var count = 0
        for url in files where Self.isTDataAuthFile(url.lastPathComponent) {
            try checkCancellation()
            count += 1
            guard count <= 303 else { throw WhitegramSessionError.tooLarge }
            try WhitegramSessionFiles.write(boundedRead(url), to: destination.appendingPathComponent(url.lastPathComponent))
        }
        guard count > 0 else { throw WhitegramSessionError.unsupportedTData }
    }

    private static func isTDataAuthFile(_ name: String) -> Bool {
        if ["key_datas", "key_data0", "key_data1"].contains(name) { return true }
        return name.utf8.count == 17 && ["s", "0", "1"].contains(String(name.suffix(1))) && name.dropLast().utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }

    private func discover(_ files: [URL]) throws {
        var consumed = Set<URL>()
        let fileSet = Set(files)
        for url in files where ["key_datas", "key_data0", "key_data1"].contains(url.lastPathComponent) {
            let directory = url.deletingLastPathComponent()
            if !sources.contains(where: { if case let .tdata(existing) = $0 { return existing == directory }; return false }) { sources.append(.tdata(directory)) }
            for file in files where file.deletingLastPathComponent() == directory && Self.isTDataAuthFile(file.lastPathComponent) { consumed.insert(file) }
        }
        for url in files where url.pathExtension.lowercased() == "session" {
            let sidecarURL = url.deletingPathExtension().appendingPathExtension("json")
            let sidecar: Data?
            if fileSet.contains(sidecarURL) {
                sidecar = try WhitegramSessionFiles.read(sidecarURL, maximumBytes: WhitegramSessionBackup.maximumBytes)
                consumed.insert(sidecarURL)
            } else { sidecar = nil }
            // A live SQLite WAL is not a complete, portable session snapshot.
            if files.contains(where: { $0.path == url.path + "-wal" }) { throw WhitegramSessionError.changedFile }
            sources.append(.telethon(url, sidecar)); consumed.insert(url)
        }
        for url in files where !consumed.contains(url) {
            if ["json", "wgsession"].contains(url.pathExtension.lowercased()) { sources.append(.archive(url)) }
        }
    }
}
