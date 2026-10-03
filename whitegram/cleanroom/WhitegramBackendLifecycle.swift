import Foundation
import CoreFoundation

enum WhitegramBackendSessionMigration {
    enum Outcome: Equatable { case noLegacySession, alreadyStored, imported, expired }
    static let completed = Notification.Name("WhitegramBackendSessionMigrationCompleted")
    private static let queue = DispatchQueue(label: "com.whitegram.backend.session-migration", qos: .utility)

    static func schedule(userId: Int64) {
        queue.async {
            do {
                _ = try migrate(userId: userId, defaults: .standard, storage: WhitegramBackendKeychain.shared, now: Date())
                DispatchQueue.main.async { NotificationCenter.default.post(name: completed, object: nil, userInfo: ["userId": userId]) }
            } catch { NSLog("Whitegram: legacy backend session migration failed; source credentials were retained") }
        }
    }

    static func migrate(userId: Int64, defaults: UserDefaults, storage: WhitegramBackendSessionStorage, now: Date) throws -> Outcome {
        guard userId > 0 else { throw WhitegramBackendError.accountMismatch }
        if try storage.load(userId: userId) != nil { return .alreadyStored }
        let suffix = String(userId)
        let tokenKey = "wg_apiSessionToken_" + suffix
        let expiresKey = "wg_apiSessionExpires_" + suffix
        let sessionKey = "wg_apiSessionKey_" + suffix
        guard let tokenObject = defaults.object(forKey: tokenKey) else { return .noLegacySession }
        guard let token = tokenObject as? String, let expires = defaults.object(forKey: expiresKey) as? NSNumber,
              CFGetTypeID(expires) != CFBooleanGetTypeID(), expires.doubleValue.isFinite else { throw WhitegramBackendError.invalidResponse }
        if expires.doubleValue <= now.timeIntervalSince1970 { return .expired }
        let data: Data?
        if let object = defaults.object(forKey: sessionKey) {
            guard let string = object as? String, let decoded = Data(base64Encoded: string), !decoded.isEmpty else { throw WhitegramBackendError.invalidResponse }
            data = decoded
        } else { data = nil }
        let session = WhitegramBackendSession(userId: userId, token: token, expiresAt: Date(timeIntervalSince1970: expires.doubleValue), sessionKey: data)
        try session.validate(userId: userId, now: now)
        try storage.save(session)
        guard try storage.load(userId: userId) == session else { throw WhitegramBackendError.invalidResponse }
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: expiresKey)
        defaults.removeObject(forKey: sessionKey)
        return .imported
    }
}
