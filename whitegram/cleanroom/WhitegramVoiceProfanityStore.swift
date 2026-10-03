import Foundation

/// Original /v1/config/profanity dictionary and UserDefaults cache. The parent
/// supplies its signed/pinned backend transport; no alternate endpoint is used.
public final class WhitegramVoiceProfanityStore {
    public typealias Loader = (@escaping (Result<Data, Error>) -> Void) -> WhitegramVoiceTask
    public static let shared = WhitegramVoiceProfanityStore()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var loader: Loader?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func configure(loader: Loader?) {
        self.lock.lock()
        self.loader = loader
        self.lock.unlock()
    }

    public func matcher() -> WhitegramVoiceProfanityMatcher {
        self.lock.lock()
        defer { self.lock.unlock() }
        let roots = self.defaults.stringArray(forKey: "wg_profanityRoots_v2") ?? []
        let prefixes = self.defaults.stringArray(forKey: "wg_profanityPrefixes_v2") ?? []
        return WhitegramVoiceProfanityMatcher(roots: roots.isEmpty ? WhitegramVoiceProfanityMatcher.originalRoots : roots, prefixes: prefixes.isEmpty ? WhitegramVoiceProfanityMatcher.originalPrefixes : prefixes)
    }

    public func update(data: Data, now: Date = Date()) throws {
        struct Response: Decodable { let roots: [String]; let prefixes: [String]? }
        guard data.count <= 2 * 1024 * 1024 else { throw WhitegramVoiceProcessingError.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.roots.isEmpty, response.roots.count <= 10000,
              response.roots.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 }),
              response.prefixes.map({ $0.count <= 512 && $0.allSatisfy({ $0.utf8.count <= 128 }) }) ?? true else { throw WhitegramVoiceProcessingError.invalidResponse }
        self.lock.lock()
        self.defaults.set(response.roots.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }, forKey: "wg_profanityRoots_v2")
        if let prefixes = response.prefixes {
            self.defaults.set(prefixes.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }, forKey: "wg_profanityPrefixes_v2")
        }
        self.defaults.set(now.timeIntervalSince1970, forKey: "wg_profanityRootsUpdatedAt_v2")
        self.lock.unlock()
    }

    func ensureLoaded(task: WhitegramVoiceTask, completion: @escaping (WhitegramVoiceProfanityMatcher) -> Void) {
        self.lock.lock()
        let loader = self.loader
        let age = Date().timeIntervalSince1970 - self.defaults.double(forKey: "wg_profanityRootsUpdatedAt_v2")
        let fresh = !(self.defaults.stringArray(forKey: "wg_profanityRoots_v2") ?? []).isEmpty && age >= 0 && age < 86400
        self.lock.unlock()
        guard !task.isCancelled else { return }
        guard !fresh, let loader else { completion(self.matcher()); return }
        let operation = WhitegramVoiceDictionaryLoad { [weak self] data in
            guard let self, !task.isCancelled else { return }
            if let data {
                do { try self.update(data: data) }
                catch { NSLog("WhitegramVoice: invalid profanity response; retaining cached dictionary") }
            }
            completion(self.matcher())
        }
        task.onCancel { operation.cancel() }
        operation.start(loader: loader)
    }
}

private final class WhitegramVoiceDictionaryLoad {
    private let lock = NSLock()
    private var completion: ((Data?) -> Void)?
    private var request: WhitegramVoiceTask?
    private var timeout: DispatchWorkItem?

    init(completion: @escaping (Data?) -> Void) { self.completion = completion }

    func start(loader: WhitegramVoiceProfanityStore.Loader) {
        let timeout = DispatchWorkItem { [weak self] in self?.finish(data: nil) }
        self.lock.lock()
        guard self.completion != nil else { self.lock.unlock(); return }
        self.timeout = timeout
        self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        let request = loader { [weak self] result in
            switch result {
            case let .success(data): self?.finish(data: data)
            case .failure: self?.finish(data: nil)
            }
        }
        self.lock.lock()
        if self.completion == nil {
            self.lock.unlock()
            request.cancel()
        } else {
            self.request = request
            self.lock.unlock()
        }
    }

    func cancel() { self.finish(data: nil, deliver: false) }

    private func finish(data: Data?, deliver: Bool = true) {
        self.lock.lock()
        let completion = self.completion
        self.completion = nil
        let request = self.request
        self.request = nil
        let timeout = self.timeout
        self.timeout = nil
        self.lock.unlock()
        timeout?.cancel()
        request?.cancel()
        if deliver { completion?(data) }
    }
}
