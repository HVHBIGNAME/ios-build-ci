import Foundation
import CoreFoundation

final class WhitegramScammerDatabase {
    struct LegacySnapshot: Equatable {
        let ids: Set<Int64>
        let savedAt: Date?
        let ignoredEntries: Int
    }
    enum CacheError: Error, LocalizedError {
        case invalidCache, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidCache: return "The saved Whitegram scammer list could not be read."
            case .tooLarge: return "The saved Whitegram scammer list exceeds the size limit."
            }
        }
    }
    static let shared = WhitegramScammerDatabase()
    static let cacheKey = "wg_scammerRemoteIdsV1"
    static let timestampKey = "wg_scammerRemoteIdsV1Timestamp"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func parse(_ text: String, savedAt: Date? = nil) throws -> LegacySnapshot {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw CacheError.tooLarge }
        var ids = Set<Int64>()
        var ignored = 0
        for part in text.split(separator: ",") {
            if let id = Int64(part), id > 0 { ids.insert(id) }
            else { ignored += 1 }
            guard ids.count <= 100000 else { throw CacheError.tooLarge }
        }
        return LegacySnapshot(ids: ids, savedAt: savedAt, ignoredEntries: ignored)
    }

    func snapshot() throws -> LegacySnapshot? {
        guard let value = defaults.object(forKey: Self.cacheKey) else { return nil }
        guard let text = value as? String else { throw CacheError.invalidCache }
        let savedAt: Date?
        if let number = defaults.object(forKey: Self.timestampKey) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 {
            savedAt = Date(timeIntervalSince1970: number.doubleValue)
        } else { savedAt = nil }
        return try Self.parse(text, savedAt: savedAt)
    }
}

public enum WhitegramScammerAssessment: Equatable {
    case unavailable
    case invalidCache
    case listed(savedAt: Date?)
    case notListed(savedAt: Date?)
}

/// The audited 3.1.1 refresh method is RET (image 46, 0x1f0008); only its saved list is available.
public func whitegramScammerAssessment(userId: Int64) -> WhitegramScammerAssessment {
    guard userId > 0 else { return .unavailable }
    do {
        guard let snapshot = try WhitegramScammerDatabase.shared.snapshot() else { return .unavailable }
        return snapshot.ids.contains(userId) ? .listed(savedAt: snapshot.savedAt) : .notListed(savedAt: snapshot.savedAt)
    } catch { return .invalidCache }
}
