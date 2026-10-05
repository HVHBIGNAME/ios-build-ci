import Foundation
#if canImport(TelegramCore) && canImport(Security)
import TelegramCore
import AccountContext
import SwiftSignalKit

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
public func whitegramLookupVirusTotalTarget(_ target: WhitegramVirusTotalTarget, account: WhitegramAccountServices? = nil, completion: @escaping (Result<WhitegramVirusTotalTargetLookupResult, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    return whitegramWithVirusTotalCredential(account: account, completion: completion) { key, service in
        service.lookup(target: target, apiKey: key, completion: completion)
    }
}

func whitegramWithVirusTotalCredential<Value>(account: WhitegramAccountServices? = nil, completion: @escaping (Result<Value, WhitegramServiceError>) -> Void, request: (String, WhitegramVirusTotalService) -> WhitegramServiceTask) -> WhitegramServiceTask {
    do {
        guard WhitegramPreferences.bool("virusTotalEnabled") else { throw WhitegramServiceError.disabled }
        let service = try WhitegramServiceRoute.configuredVirusTotal.virusTotalService(account: account)
        guard let key = try WhitegramServiceCredentials.vault.token(for: .virusTotal) else { throw WhitegramServiceError.missingAPIKey }
        return request(key, service)
    } catch {
        let operation = WhitegramServiceOperation(completion: completion)
        operation.finish(.failure(error as? WhitegramServiceError ?? .preferences))
        return operation.task
    }
}

@discardableResult
public func whitegramScanVirusTotalTarget(_ target: WhitegramVirusTotalTarget, account: WhitegramAccountServices? = nil, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    return whitegramWithVirusTotalCredential(account: account, completion: completion) { key, service in
        service.scan(target: target, progress: progress, apiKey: key, completion: completion)
    }
}

@discardableResult
public func whitegramUploadAndScanVirusTotalFile(url: URL, fileName: String? = nil, expectedHash: String? = nil, account: WhitegramAccountServices? = nil, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    return whitegramWithVirusTotalCredential(account: account, completion: completion) { key, service in
        service.uploadAndScan(fileURL: url, fileName: fileName, expectedHash: expectedHash, progress: progress, apiKey: key, completion: completion)
    }
}

struct WhitegramVirusTotalMessageFile {
    let url: URL
    let fileName: String
}

/// Downloads only the selected Telegram attachment. Upload still requires a separate explicit action.
func whitegramFetchVirusTotalMessageFile(context: AccountContext, message: EngineMessage, progress: @escaping (Int64) -> Void, completion: @escaping (Result<WhitegramVirusTotalMessageFile, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    let operation = WhitegramServiceOperation(completion: completion)
    guard let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
        operation.finish(.failure(.notRegularFile))
        return operation.task
    }
    if let size = file.size, size > WhitegramServiceLimits.maximumFileBytes {
        operation.finish(.failure(.fileTooLarge))
        return operation.task
    }
    let fetch = MetaDisposable()
    let data = MetaDisposable()
    let timeout = WhitegramServiceMainScheduler().schedule(after: 300) {
        fetch.dispose()
        data.dispose()
        operation.finish(.failure(.timedOut))
    }
    operation.task.onCancel { fetch.dispose(); data.dispose(); timeout.cancel() }
    fetch.set(context.engine.resources.fetch(reference: FileMediaReference.message(message: MessageReference(message._asMessage()), media: file).resourceReference(file.resource), userLocation: .peer(message.id.peerId), userContentType: .file).start(error: { _ in
        data.dispose()
        timeout.cancel()
        operation.finish(.failure(.fileUnreadable))
    }))
    data.set((context.engine.resources.data(resource: EngineMediaResource(file.resource), incremental: true)
    |> deliverOnMainQueue).start(next: { value in
        guard !operation.task.isCancelled else { return }
        if value.availableSize > WhitegramServiceLimits.maximumFileBytes {
            fetch.dispose(); data.dispose(); timeout.cancel()
            operation.finish(.failure(.fileTooLarge))
        } else if value.isComplete {
            fetch.dispose(); data.dispose(); timeout.cancel()
            operation.finish(.success(WhitegramVirusTotalMessageFile(url: URL(fileURLWithPath: value.path), fileName: file.fileName ?? "file")))
        } else {
            progress(value.availableSize)
        }
    }))
    return operation.task
}
#endif
