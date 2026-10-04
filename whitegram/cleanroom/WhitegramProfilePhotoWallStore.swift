import Foundation
import CoreFoundation

final class WhitegramProfilePhotoWallStore {
    static let updated = Notification.Name("WhitegramProfilePhotoWallUpdated")
    private let directory: URL
    private let defaults: UserDefaults

    init(documents: URL? = nil, defaults: UserDefaults = .standard) throws {
        guard let root = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              root.isFileURL else { throw WhitegramBackendError.localStorage }
        directory = root.appendingPathComponent("WallpapersProfile", isDirectory: true)
        self.defaults = defaults
    }

    private func url(userId: Int64) throws -> URL {
        guard userId > 0 else { throw WhitegramBackendError.accountMismatch }
        return directory.appendingPathComponent("my_wall_\(userId).jpg")
    }

    func load(userId: Int64) throws -> Data? {
        let file = try url(userId: userId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size <= WhitegramBackendProtocol.maximumResponseBytes else { throw WhitegramBackendError.localStorage }
        guard let stream = InputStream(url: file) else { throw WhitegramBackendError.localStorage }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? WhitegramBackendError.localStorage }
            if count == 0 { break }
            guard count <= WhitegramBackendProtocol.maximumResponseBytes - data.count else { throw WhitegramBackendError.localStorage }
            data.append(contentsOf: buffer.prefix(count))
        }
        try validate(data)
        return data
    }

    func save(_ jpeg: Data, userId: Int64) throws {
        let file = try url(userId: userId)
        try validate(jpeg)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: file, options: .atomic)
        notify(userId: userId)
    }

    func removeLocal(userId: Int64) throws {
        let file = try url(userId: userId)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        notify(userId: userId)
    }

    func savedPublicationPreference(userId: Int64) -> Bool? {
        guard userId > 0, let value = defaults.object(forKey: "wg_profilePhotoWallPublic_\(userId)") as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    func confirmedPublication(_ isPublic: Bool, userId: Int64) throws {
        guard userId > 0 else { throw WhitegramBackendError.accountMismatch }
        defaults.set(isPublic, forKey: "wg_profilePhotoWallPublic_\(userId)")
        notify(userId: userId)
    }

    private func validate(_ data: Data) throws {
        guard data.count >= 3, data.count <= WhitegramBackendProtocol.maximumResponseBytes,
              data.prefix(3) == Data([0xff, 0xd8, 0xff]) else { throw WhitegramBackendError.localStorage }
    }

    private func notify(userId: Int64) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updated, object: nil, userInfo: ["userId": userId]) }
    }
}

public let whitegramProfilePhotoWallUpdated = WhitegramProfilePhotoWallStore.updated

/// Local wallpaper uses the original account-specific Documents/WallpapersProfile filename.
public func whitegramProfileLocalWallpaperData(userId: Int64) throws -> Data? {
    return try WhitegramProfilePhotoWallStore().load(userId: userId)
}
