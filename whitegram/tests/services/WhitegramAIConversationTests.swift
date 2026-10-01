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
}
