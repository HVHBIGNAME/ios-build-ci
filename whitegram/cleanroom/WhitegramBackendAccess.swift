import Foundation
import CryptoKit

public enum WhitegramBackendAccessState: Int {
    case unknown = 0, allowed = 1, denied = 2
}

struct WhitegramBackendAccessVerdict: Decodable, Equatable {
    // Image 55, 0x55b528: Ed25519 verification; image 46, 0x217fa0: signed payload.
    static let publicKeyBase64 = "mZIY2qc74RLvkLLT6MXy5fG2vsOLPRRhYJ90JJdPDII="
    let userId: Int64
    let allowed: Bool
    let issuedAt: Int64
    let expiresAt: Int64
    let nonce: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", allowed, issuedAt = "issued_at", expiresAt = "expires_at", nonce, signature = "sig"
    }

    var signedPayload: String {
        return "whitegram.beta.status.v1|\(userId)|\(allowed ? 1 : 0)|\(issuedAt)|\(expiresAt)|\(nonce)"
    }

    func validate(userId: Int64, nonce: String, now: Date, publicKey: Data? = nil) throws {
        let time = now.timeIntervalSince1970.rounded(.towardZero)
        guard time.isFinite, self.userId == userId, userId > 0, self.nonce == nonce,
              nonce.count == 32, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              issuedAt > 0, expiresAt > issuedAt, Double(expiresAt) > time,
              Double(issuedAt) <= time + 120, expiresAt - issuedAt <= 600,
              let signature = Data(base64Encoded: signature), signature.count == 64,
              let key = publicKey ?? Data(base64Encoded: Self.publicKeyBase64) else { throw WhitegramBackendError.invalidBetaVerdict }
        do {
            guard try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: Data(signedPayload.utf8)) else {
                throw WhitegramBackendError.invalidBetaVerdict
            }
        } catch { throw WhitegramBackendError.invalidBetaVerdict }
    }
}

final class WhitegramBackendAccessStore {
    static let shared = WhitegramBackendAccessStore()
    static let updated = Notification.Name("WhitegramBackendAccessUpdated")
    private let lock = NSLock()
    private struct Entry { let verdict: WhitegramBackendAccessVerdict; let receivedAt: Date }
    private var verdicts: [Int64: Entry] = [:]
    private var generations: [Int64: UUID] = [:]

    // Original critical paths in image 46, 0x217afc. Query strings do not affect eligibility.
    static func isCritical(path: String) -> Bool {
        return ["/v1/status", "/v1/status/probe", "/v1/config", "/v1/config/profanity",
            "/v1/plugin-languages", "/v1/announcements/active", "/v1/auth/bot", "/v1/auth/session",
            "/v1/auth/me", "/v1/beta/status", "/v1/blacklist/snapshot", "/v1/scammers/snapshot", "/auth"].contains(path)
            || path.hasPrefix("/v1/auth-media/")
    }

    func state(userId: Int64, now: Date) -> WhitegramBackendAccessState {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = verdicts[userId] else { return .unknown }
        let verdict = entry.verdict
        let age = now.timeIntervalSince(entry.receivedAt)
        // Original positive/negative cache bounds are 900/30 seconds; a signed expiry is also enforced.
        guard age >= 0, age < (verdict.allowed ? 900 : 30), Double(verdict.expiresAt) > now.timeIntervalSince1970,
              Double(verdict.issuedAt) <= now.timeIntervalSince1970 + 120 else { return .unknown }
        return verdict.allowed ? .allowed : .denied
    }

    func require(userId: Int64, path: String, now: Date) throws {
        guard !Self.isCritical(path: path) else { return }
        switch state(userId: userId, now: now) {
        case .allowed: return
        case .unknown: throw WhitegramBackendError.betaAccessUnknown
        case .denied: throw WhitegramBackendError.betaAccessDenied
        }
    }

    func begin(userId: Int64) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let generation = UUID()
        generations[userId] = generation
        return generation
    }

    func finish(userId: Int64, generation: UUID, verdict: WhitegramBackendAccessVerdict?, now: Date = Date()) throws {
        lock.lock()
        guard generations[userId] == generation else { lock.unlock(); throw WhitegramBackendError.sessionChanged }
        verdicts[userId] = verdict.map { Entry(verdict: $0, receivedAt: now) }
        generations.removeValue(forKey: userId)
        lock.unlock()
        notify(userId: userId)
    }

    func reset(userId: Int64) {
        lock.lock()
        verdicts.removeValue(forKey: userId)
        generations.removeValue(forKey: userId)
        lock.unlock()
        notify(userId: userId)
    }

    private func notify(userId: Int64) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updated, object: nil, userInfo: ["userId": userId]) }
    }
}

extension WhitegramBackendClient {
    @discardableResult
    func refreshAccess(completion: @escaping (Result<WhitegramBackendAccessState, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        var generator = SystemRandomNumberGenerator()
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        let generation = access.begin(userId: userId)
        return request(WhitegramBackendAccessVerdict.self, path: "/v1/beta/status",
            query: [URLQueryItem(name: "user_id", value: String(userId)), URLQueryItem(name: "nonce", value: nonce)],
            authenticated: false) { [self] result in
            do {
                let verdict = try result.get()
                try verdict.validate(userId: userId, nonce: nonce, now: now())
                try access.finish(userId: userId, generation: generation, verdict: verdict, now: now())
                completion(.success(verdict.allowed ? .allowed : .denied))
            } catch {
                do { try access.finish(userId: userId, generation: generation, verdict: nil, now: now()) }
                catch { completion(.failure(.sessionChanged)); return }
                completion(.failure(error as? WhitegramBackendError ?? .invalidBetaVerdict))
            }
        }
    }
}

public func whitegramBackendAccessState(userId: Int64) -> WhitegramBackendAccessState {
    return WhitegramBackendAccessStore.shared.state(userId: userId, now: Date())
}

public let whitegramBackendAccessUpdated = WhitegramBackendAccessStore.updated
