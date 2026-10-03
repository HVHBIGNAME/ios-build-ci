import Foundation

struct WhitegramAIConversationTurn: Codable, Equatable {
    enum State: String, Codable {
        case pending
        case answered
        case failed
        case cancelled
    }

    let id: UUID
    let date: Date
    let prompt: String
    var model: String
    var state: State
    var response: WhitegramAIResponse?
    var partialText: String? = nil
}

struct WhitegramAIConversationSnapshot: Equatable {
    var revision: UUID?
    var turns: [WhitegramAIConversationTurn]
    var legacyHistory: WhitegramAILegacyHistory? = nil

    static let empty = WhitegramAIConversationSnapshot(revision: nil, turns: [])
}

protocol WhitegramAIConversationStorage: AnyObject {
    func load() throws -> WhitegramAIConversationSnapshot
    func save(_ turns: [WhitegramAIConversationTurn], replacing revision: UUID?) throws -> WhitegramAIConversationSnapshot
    func clear() throws -> WhitegramAIConversationSnapshot
}

/// One file per account/provider, under the account's own directory. No credentials are serialized.
final class WhitegramAIConversationStore: WhitegramAIConversationStorage {
    private struct Record: Codable {
        let version: Int
        let accountId: Int64
        let provider: WhitegramAIProvider
        let revision: UUID
        let turns: [WhitegramAIConversationTurn]
        let legacyHistory: WhitegramAILegacyHistory?
    }

    // Serializes compare-and-replace across separate screens/store instances in this process.
    private static let lock = NSLock()
    private let directory: URL
    private let accountId: Int64
    private let provider: WhitegramAIProvider
    var fileURL: URL { return self.directory.appendingPathComponent(self.provider.rawValue + ".json") }

    init(directory: URL, accountId: Int64, provider: WhitegramAIProvider) {
        self.directory = directory.appendingPathComponent(String(accountId), isDirectory: true)
        self.accountId = accountId
        self.provider = provider
    }

    func load() throws -> WhitegramAIConversationSnapshot {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try self.readRecord()
    }

    func save(_ turns: [WhitegramAIConversationTurn], replacing revision: UUID?) throws -> WhitegramAIConversationSnapshot {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = try self.readRecord()
        guard previous.revision == revision else { throw WhitegramServiceError.conversationChanged }
        return try self.writeRecord(turns, legacyHistory: previous.legacyHistory)
    }

    func clear() throws -> WhitegramAIConversationSnapshot {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Keep a new empty revision: deleting the file would let a stale first request recreate it.
        return try self.writeRecord([], legacyHistory: nil)
    }

    /// Original histories were app-wide. The native screen asks which account should receive the copy.
    /// Never removes the original Data or replaces a nonempty current conversation.
    func importLegacy(_ data: Data, replacing revision: UUID?) throws -> WhitegramAIConversationSnapshot {
        let history = try WhitegramAILegacyHistory.decode(data, provider: self.provider)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = try self.readRecord()
        guard previous.revision == revision else { throw WhitegramServiceError.conversationChanged }
        if previous.legacyHistory == history { return previous }
        guard previous.turns.isEmpty, previous.legacyHistory == nil else { throw WhitegramServiceError.conversationChanged }
        return try self.writeRecord([], legacyHistory: history)
    }

    private func readRecord() throws -> WhitegramAIConversationSnapshot {
        guard self.directory.isFileURL else { throw WhitegramServiceError.conversationStorage }
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return .empty }
        do {
            let values = try self.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= WhitegramServiceLimits.maximumAIHistoryBytes else {
                throw WhitegramServiceError.conversationStorage
            }
            let handle = try FileHandle(forReadingFrom: self.fileURL)
            defer { handle.closeFile() }
            let data = handle.readData(ofLength: WhitegramServiceLimits.maximumAIHistoryBytes + 1)
            guard data.count <= WhitegramServiceLimits.maximumAIHistoryBytes else { throw WhitegramServiceError.conversationStorage }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.version == 1, record.accountId == self.accountId, record.provider == self.provider else {
                throw WhitegramServiceError.conversationStorage
            }
            try self.validate(record.turns)
            try record.legacyHistory?.validate(provider: self.provider)
            return WhitegramAIConversationSnapshot(revision: record.revision, turns: record.turns, legacyHistory: record.legacyHistory)
        } catch {
            throw WhitegramServiceError.conversationStorage
        }
    }

    private func validate(_ turns: [WhitegramAIConversationTurn]) throws {
        guard turns.count <= WhitegramServiceLimits.maximumAIConversationTurns,
              Set(turns.map { $0.id }).count == turns.count else { throw WhitegramServiceError.conversationFull }
        for (index, turn) in turns.enumerated() {
            let time = turn.date.timeIntervalSince1970
            guard time.isFinite, time >= 0, time <= 253402300799,
                  !turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn.prompt.utf8.count <= WhitegramServiceLimits.maximumPromptBytes,
                  try self.provider.validatedModel(turn.model) == turn.model,
                  (turn.state == .answered) == (turn.response != nil),
                  turn.state != .pending || index == turns.count - 1 else { throw WhitegramServiceError.invalidConversation }
            if let response = turn.response {
                guard response.provider == self.provider, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      response.text.utf8.count <= WhitegramServiceLimits.maximumAIResponseBytes, response.model.utf8.count <= 256,
                      [response.inputTokens, response.outputTokens, response.totalTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                    throw WhitegramServiceError.invalidConversation
                }
            }
            if let partial = turn.partialText {
                guard turn.response == nil, partial.utf8.count <= WhitegramServiceLimits.maximumAIResponseBytes else { throw WhitegramServiceError.invalidConversation }
            }
        }
    }

    private func writeRecord(_ turns: [WhitegramAIConversationTurn], legacyHistory: WhitegramAILegacyHistory?) throws -> WhitegramAIConversationSnapshot {
        guard self.directory.isFileURL else { throw WhitegramServiceError.conversationStorage }
        try self.validate(turns)
        try legacyHistory?.validate(provider: self.provider)
        let revision = UUID()
        let record = Record(version: 1, accountId: self.accountId, provider: self.provider, revision: revision, turns: turns, legacyHistory: legacyHistory)
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= WhitegramServiceLimits.maximumAIHistoryBytes else { throw WhitegramServiceError.conversationFull }
            let manager = FileManager.default
            try manager.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: nil)
            let values = try self.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw WhitegramServiceError.conversationStorage }
            #if os(iOS)
            var directory = self.directory
            var protection = URLResourceValues()
            protection.isExcludedFromBackup = true
            try directory.setResourceValues(protection)
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            try data.write(to: self.fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: self.fileURL, options: .atomic)
            #endif
            return WhitegramAIConversationSnapshot(revision: revision, turns: turns, legacyHistory: legacyHistory)
        } catch let error as WhitegramServiceError {
            throw error
        } catch {
            throw WhitegramServiceError.conversationStorage
        }
    }
}

/// Main-queue conversation lifecycle shared by the native UI and offline XCTest host.
final class WhitegramAIConversationSession {
    typealias Sender = ([WhitegramAIMessage], String, @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceTask
    typealias StreamingSender = ([WhitegramAIMessage], String, @escaping (String) -> Void, @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceTask

    let provider: WhitegramAIProvider
    private let storage: WhitegramAIConversationStorage
    private(set) var snapshot: WhitegramAIConversationSnapshot
    private(set) var storageError: WhitegramServiceError?
    private(set) var lastResult: Result<WhitegramAIResponse, WhitegramServiceError>?
    private var request: WhitegramServiceTask?
    private var requestId: UUID?
    var changed: (() -> Void)?

    var isRequesting: Bool { return self.requestId != nil }
    var canRetry: Bool { return !self.isRequesting && self.storageError == nil && self.snapshot.turns.last?.response == nil && !self.snapshot.turns.isEmpty }

    init(provider: WhitegramAIProvider, storage: WhitegramAIConversationStorage) throws {
        self.provider = provider
        self.storage = storage
        self.snapshot = try storage.load()
    }

    deinit { self.request?.cancel() }

    func reload() throws {
        precondition(Thread.isMainThread)
        guard !self.isRequesting else { throw WhitegramServiceError.busy }
        self.snapshot = try self.storage.load()
        self.storageError = nil
        self.lastResult = nil
        self.changed?()
    }

    func send(text: String, model: String, sender: Sender) throws {
        try self.submit(text: text, model: model, retry: false, sender: { messages, model, _, completion in sender(messages, model, completion) })
    }

    func retry(model: String, sender: Sender) throws {
        guard self.canRetry, let turn = self.snapshot.turns.last else { throw WhitegramServiceError.invalidConversation }
        try self.submit(text: turn.prompt, model: model, retry: true, sender: { messages, model, _, completion in sender(messages, model, completion) })
    }

    func sendStreaming(text: String, model: String, sender: StreamingSender) throws {
        try self.submit(text: text, model: model, retry: false, sender: sender)
    }

    func retryStreaming(model: String, sender: StreamingSender) throws {
        guard self.canRetry, let turn = self.snapshot.turns.last else { throw WhitegramServiceError.invalidConversation }
        try self.submit(text: turn.prompt, model: model, retry: true, sender: sender)
    }

    private func submit(text: String, model: String, retry: Bool, sender: StreamingSender) throws {
        precondition(Thread.isMainThread)
        guard !self.isRequesting else { throw WhitegramServiceError.busy }
        if let error = self.storageError { throw error }
        let model = try self.provider.validatedModel(model)
        var turns = self.snapshot.turns
        let previous = retry ? turns.removeLast() : nil
        // An explicit new prompt can supersede an interrupted pending turn after a restart.
        // Saving the new revision also prevents another screen's old request from overwriting it.
        if turns.last?.state == .pending { turns[turns.count - 1].state = .cancelled }
        guard turns.count < WhitegramServiceLimits.maximumAIConversationTurns else { throw WhitegramServiceError.conversationFull }
        // Failed/cancelled prompts are visible in history but have no assistant reply to send as context.
        let messages = (self.snapshot.legacyHistory?.completedMessages ?? []) + turns.flatMap { turn -> [WhitegramAIMessage] in
            guard let response = turn.response else { return [] }
            return [WhitegramAIMessage(role: .user, text: turn.prompt), WhitegramAIMessage(role: .assistant, text: response.text)]
        } + [WhitegramAIMessage(role: .user, text: text)]
        _ = try WhitegramAIWire.requestBody(messages: messages, provider: self.provider, model: model)
        turns.append(WhitegramAIConversationTurn(id: previous?.id ?? UUID(), date: previous?.date ?? Date(), prompt: text, model: model, state: .pending, response: nil))
        do {
            self.snapshot = try self.storage.save(turns, replacing: self.snapshot.revision)
        } catch {
            self.storageError = error as? WhitegramServiceError ?? .conversationStorage
            throw self.storageError ?? .conversationStorage
        }
        let id = UUID()
        self.requestId = id
        self.lastResult = nil
        self.request = sender(messages, model, { [weak self] text in
            DispatchQueue.main.async { self?.receivedPartial(text, id: id) }
        }, { [weak self] result in
            DispatchQueue.main.async { self?.finished(result, id: id) }
        })
        self.changed?()
    }

    private func receivedPartial(_ text: String, id: UUID) {
        guard self.requestId == id, !self.snapshot.turns.isEmpty,
              text.utf8.count <= WhitegramServiceLimits.maximumAIResponseBytes else { return }
        self.snapshot.turns[self.snapshot.turns.count - 1].partialText = text
        self.changed?()
    }

    private func finished(_ result: Result<WhitegramAIResponse, WhitegramServiceError>, id: UUID) {
        guard self.requestId == id else { return }
        self.requestId = nil
        self.request = nil
        let result = result.flatMap { response -> Result<WhitegramAIResponse, WhitegramServiceError> in
            return response.provider == self.provider ? .success(response) : .failure(.invalidResponse)
        }
        var turns = self.snapshot.turns
        guard !turns.isEmpty else { return }
        switch result {
        case let .success(response):
            turns[turns.count - 1].state = .answered
            turns[turns.count - 1].response = response
            turns[turns.count - 1].partialText = nil
        case let .failure(error):
            turns[turns.count - 1].state = error == .cancelled ? .cancelled : .failed
        }
        self.lastResult = result
        self.persistOutcome(turns)
        self.changed?()
    }

    private func persistOutcome(_ turns: [WhitegramAIConversationTurn]) {
        do {
            self.snapshot = try self.storage.save(turns, replacing: self.snapshot.revision)
        } catch {
            // Keep an unsaved reply visible for explicit copy, but fail closed for subsequent requests.
            self.snapshot.turns = turns
            self.storageError = error as? WhitegramServiceError ?? .conversationStorage
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard self.isRequesting else { return }
        self.requestId = nil
        let request = self.request
        self.request = nil
        request?.cancel()
        var turns = self.snapshot.turns
        if !turns.isEmpty { turns[turns.count - 1].state = .cancelled }
        self.lastResult = .failure(.cancelled)
        self.persistOutcome(turns)
        self.changed?()
    }

    func clear() throws {
        precondition(Thread.isMainThread)
        self.cancel()
        self.snapshot = try self.storage.clear()
        self.storageError = nil
        self.lastResult = nil
        self.changed?()
    }
}
