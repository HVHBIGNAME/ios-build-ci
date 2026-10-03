import Foundation
import XCTest
@testable import WhitegramServiceHost

final class WhitegramAIConversationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-conversation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func response(_ provider: WhitegramAIProvider = .groq) -> WhitegramAIResponse {
        return WhitegramAIResponse(provider: provider, model: "model", text: "reply", finishReason: "stop", isTruncated: false, inputTokens: 1, outputTokens: 1, totalTokens: 2)
    }

    func testMultiturnRolesUseProviderContractsWithoutLocalMetadata() throws {
        let messages = [WhitegramAIMessage(role: .user, text: "question"), WhitegramAIMessage(role: .assistant, text: "reply"), WhitegramAIMessage(role: .user, text: "follow-up")]
        let gemini = try WhitegramAIWire.requestBody(messages: messages, provider: .gemini, model: "model")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: gemini) as? [String: Any])
        let contents = try XCTUnwrap(root["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.compactMap { $0["role"] as? String }, ["user", "model", "user"])
        let groq = try WhitegramAIWire.requestBody(messages: messages, provider: .groq, model: "model")
        let groqRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: groq) as? [String: Any])
        let outgoing = try XCTUnwrap(groqRoot["messages"] as? [[String: String]])
        XCTAssertEqual(outgoing.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(outgoing.map { $0["content"] }, ["question", "reply", "follow-up"])
        for data in [gemini, groq] {
            let text = String(decoding: data, as: UTF8.self)
            for key in ["accountId", "revision", "apiKey", "createdAt"] { XCTAssertFalse(text.contains(key)) }
        }
        XCTAssertThrowsError(try WhitegramAIWire.requestBody(messages: Array(messages.dropFirst()), provider: .groq, model: "model"))
        XCTAssertThrowsError(try WhitegramAIWire.requestBody(messages: [WhitegramAIMessage(role: .assistant, text: "orphan")], provider: .groq, model: "model"))
    }

    func testStorageIsAccountProviderScopedAndClearInvalidatesOldRevision() throws {
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let turn = WhitegramAIConversationTurn(id: UUID(), date: Date(), prompt: "question", model: "model", state: .answered, response: response())
        let saved = try store.save([turn], replacing: nil)
        XCTAssertEqual(try store.load().turns, [turn])
        XCTAssertTrue(try WhitegramAIConversationStore(directory: directory, accountId: 2, provider: .groq).load().turns.isEmpty)
        XCTAssertTrue(try WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .gemini).load().turns.isEmpty)
        let otherScreen = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let cleared = try otherScreen.clear()
        XCTAssertNotEqual(saved.revision, cleared.revision)
        XCTAssertThrowsError(try store.save([turn], replacing: saved.revision)) { error in
            XCTAssertEqual(error as? WhitegramServiceError, .conversationChanged)
        }
        XCTAssertTrue(try store.load().turns.isEmpty)
    }

    func testCancelledLateReplyCannotRecreateClearedHistory() throws {
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let session = try WhitegramAIConversationSession(provider: .groq, storage: store)
        var completion: ((Result<WhitegramAIResponse, WhitegramServiceError>) -> Void)?
        let task = WhitegramServiceTask()
        try session.send(text: "question", model: "model", sender: { _, _, callback in
            completion = callback
            return task
        })
        XCTAssertTrue(session.isRequesting)
        try session.clear()
        XCTAssertTrue(task.isCancelled)
        completion?(.success(response()))
        let drained = expectation(description: "late reply drained")
        DispatchQueue.main.async {
            XCTAssertTrue(session.snapshot.turns.isEmpty)
            XCTAssertFalse(session.isRequesting)
            XCTAssertTrue((try? store.load().turns.isEmpty) == true)
            drained.fulfill()
        }
        wait(for: [drained], timeout: 2)
    }

    func testRetryDoesNotSendFailedPromptsAsAssistantContext() throws {
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let first = WhitegramAIConversationTurn(id: UUID(), date: Date(), prompt: "first", model: "model", state: .answered, response: response())
        let failed = WhitegramAIConversationTurn(id: UUID(), date: Date(), prompt: "retry me", model: "model", state: .failed, response: nil)
        _ = try store.save([first, failed], replacing: nil)
        let session = try WhitegramAIConversationSession(provider: .groq, storage: store)
        var sent: [WhitegramAIMessage] = []
        try session.retry(model: "model", sender: { messages, _, _ in sent = messages; return WhitegramServiceTask() })
        XCTAssertEqual(sent.map { $0.text }, ["first", "reply", "retry me"])
        XCTAssertEqual(session.snapshot.turns.count, 2)
        XCTAssertEqual(session.snapshot.turns.last?.id, failed.id)
        session.cancel()
        XCTAssertEqual(try store.load().turns.last?.state, .cancelled)
    }

    func testOriginalV5HistoryRoundTripsWithoutInventedAccountDatesOrModel() throws {
        // Both original providers stored user/model + text, including Groq.
        let source = Data(#"[{"role":"model","text":"orphan"},{"role":"user","text":"  вопрос 😀\n"},{"role":"model","text":"ответ"},{"role":"user","text":"interrupted"}]"#.utf8)
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let imported = try store.importLegacy(source, replacing: nil)
        let legacy = try XCTUnwrap(imported.legacyHistory)
        XCTAssertEqual(legacy.sourceKey, "wg_groqChatHistory_v5")
        XCTAssertEqual(legacy.entries.map { $0.text }, ["orphan", "  вопрос 😀\n", "ответ", "interrupted"])
        XCTAssertEqual(legacy.completedMessages.map { $0.text }, ["  вопрос 😀\n", "ответ"])
        XCTAssertTrue(imported.turns.isEmpty, "Original entries must not receive invented turn timestamps or model IDs")
        XCTAssertEqual(try store.load().legacyHistory, legacy)
        XCTAssertEqual(try store.importLegacy(source, replacing: imported.revision), imported)
        XCTAssertNil(try WhitegramAIConversationStore(directory: directory, accountId: 2, provider: .groq).load().legacyHistory)
        XCTAssertNil(try WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .gemini).load().legacyHistory)
        let session = try WhitegramAIConversationSession(provider: .groq, storage: store)
        var outgoing: [WhitegramAIMessage] = []
        try session.send(text: "next", model: "model", sender: { messages, _, _ in outgoing = messages; return WhitegramServiceTask() })
        XCTAssertEqual(outgoing.map { $0.text }, ["  вопрос 😀\n", "ответ", "next"])
        session.cancel()
        XCTAssertEqual(try store.load().legacyHistory, legacy)
        try session.clear()
        XCTAssertNil(try store.load().legacyHistory)
        XCTAssertThrowsError(try store.importLegacy(source, replacing: imported.revision))
    }

    func testMalformedLegacyEnvelopeAndNewHistoryAreNeverOverwritten() throws {
        for invalid in [#"{"turns":[]}"#, #"[{"role":"assistant","text":"not the v5 wire role"}]"#, #"[{"role":"user","content":"wrong provider envelope"}]"#] {
            XCTAssertThrowsError(try WhitegramAILegacyHistory.decode(Data(invalid.utf8), provider: .gemini))
        }
        let valid = Data(#"[{"role":"user","text":"one"},{"role":"model","text":"two"}]"#.utf8)
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .gemini)
        let turn = WhitegramAIConversationTurn(id: UUID(), date: Date(), prompt: "existing", model: "model", state: .failed, response: nil)
        let previous = try store.save([turn], replacing: nil)
        XCTAssertThrowsError(try store.importLegacy(valid, replacing: previous.revision))
        XCTAssertEqual(try store.load(), previous)
        let tooMany = try JSONEncoder().encode((0..<201).map { WhitegramAILegacyEntry(role: "user", text: String($0)) })
        XCTAssertThrowsError(try WhitegramAILegacyHistory.decode(tooMany, provider: .gemini))
    }

    func testLateStreamingChunksCannotChangeANewTurnOrRestoreClearedHistory() throws {
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let session = try WhitegramAIConversationSession(provider: .groq, storage: store)
        var oldChunk: ((String) -> Void)?
        try session.sendStreaming(text: "old", model: "model", sender: { _, _, chunk, _ in oldChunk = chunk; return WhitegramServiceTask() })
        oldChunk?("partial old")
        let firstDrain = expectation(description: "partial")
        DispatchQueue.main.async { firstDrain.fulfill() }
        wait(for: [firstDrain], timeout: 2)
        session.cancel()
        XCTAssertEqual(try store.load().turns.last?.partialText, "partial old")
        var context: [WhitegramAIMessage] = []
        var newChunk: ((String) -> Void)?
        try session.sendStreaming(text: "new", model: "model", sender: { messages, _, chunk, _ in context = messages; newChunk = chunk; return WhitegramServiceTask() })
        XCTAssertEqual(context.map { $0.text }, ["new"])
        newChunk?("new partial")
        oldChunk?("late old data")
        let secondDrain = expectation(description: "stale partial")
        DispatchQueue.main.async { secondDrain.fulfill() }
        wait(for: [secondDrain], timeout: 2)
        XCTAssertEqual(session.snapshot.turns.last?.partialText, "new partial")
        try session.clear()
        newChunk?("too late")
        let thirdDrain = expectation(description: "cleared partial")
        DispatchQueue.main.async { thirdDrain.fulfill() }
        wait(for: [thirdDrain], timeout: 2)
        XCTAssertTrue(session.snapshot.turns.isEmpty)
        XCTAssertTrue(try store.load().turns.isEmpty)
    }

    func testNewPromptAfterRestartSupersedesPendingTurnWithoutSendingItsPartialText() throws {
        let store = WhitegramAIConversationStore(directory: directory, accountId: 1, provider: .groq)
        let interrupted = WhitegramAIConversationTurn(id: UUID(), date: Date(), prompt: "interrupted", model: "model", state: .pending, response: nil, partialText: "incomplete")
        let previous = try store.save([interrupted], replacing: nil)
        let session = try WhitegramAIConversationSession(provider: .groq, storage: store)
        var sent: [WhitegramAIMessage] = []
        try session.send(text: "new prompt", model: "model", sender: { messages, _, _ in sent = messages; return WhitegramServiceTask() })
        XCTAssertEqual(sent, [WhitegramAIMessage(role: .user, text: "new prompt")])
        XCTAssertEqual(session.snapshot.turns.first?.state, .cancelled)
        XCTAssertEqual(session.snapshot.turns.first?.partialText, "incomplete")
        XCTAssertThrowsError(try store.save([interrupted], replacing: previous.revision)) { error in
            XCTAssertEqual(error as? WhitegramServiceError, .conversationChanged)
        }
        session.cancel()
        XCTAssertEqual(try store.load().turns.count, 2)
    }
}
