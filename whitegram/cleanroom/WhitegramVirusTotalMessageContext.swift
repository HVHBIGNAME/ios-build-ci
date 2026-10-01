import Foundation
#if canImport(TelegramCore) && canImport(Security)
import TelegramCore

/// Extracts only targets from message text and its actual link entities; performs no request.
public func whitegramVirusTotalTargets(text: String, entities: [MessageTextEntity]) -> [WhitegramVirusTotalTarget] {
    let links = entities.compactMap { entity -> WhitegramVirusTotalTextLink? in
        let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
        switch entity.type {
        case .Url: return WhitegramVirusTotalTextLink(range: range)
        case let .TextUrl(url): return WhitegramVirusTotalTextLink(range: range, url: url)
        default: return nil
        }
    }
    return WhitegramVirusTotalTargets.extractAllTargets(from: text, links: links)
}

/// Call only after the user explicitly submits a reviewed target.
@discardableResult
public func whitegramLookupVirusTotalTarget(_ target: WhitegramVirusTotalTarget, completion: @escaping (Result<WhitegramVirusTotalTargetLookupResult, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    do {
        guard WhitegramPreferences.bool("virusTotalEnabled") else { throw WhitegramServiceError.disabled }
        guard let key = try WhitegramServiceCredentials.vault.token(for: .virusTotal) else { throw WhitegramServiceError.missingAPIKey }
        return WhitegramVirusTotalService.shared.lookup(target: target, apiKey: key, completion: completion)
    } catch {
        let operation = WhitegramServiceOperation(completion: completion)
        operation.finish(.failure(error as? WhitegramServiceError ?? .preferences))
        return operation.task
    }
}
#endif
