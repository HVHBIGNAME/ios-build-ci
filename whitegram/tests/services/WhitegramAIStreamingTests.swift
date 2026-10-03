import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WhitegramServiceHost

final class WhitegramAIStreamingTests: XCTestCase {
    private func event(_ value: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value)
        return Data(("data: " + String(decoding: data, as: UTF8.self) + "\r\n\r\n").utf8)
    }

    func testGroqSSEHandlesEveryUTF8AndCRLFBoundaryAndKeepsUsage() throws {
        var updates: [String] = []
        let decoder = WhitegramGroqStreamDecoder(model: "requested", onText: { updates.append($0) })
        var data = Data(": keepalive\r\n\r\n".utf8)
        data += try event(["model": "actual", "choices": [["index": 0, "delta": ["role": "assistant", "content": "Привет "]]]])
        data += try event(["choices": [["index": 0, "delta": ["content": "😀", "reasoning": "not visible"]]]])
        data += try event(["choices": [["index": 0, "delta": [:], "finish_reason": "length"]]])
        data += try event(["choices": [], "x_groq": ["usage": ["prompt_tokens": 4, "completion_tokens": 7, "total_tokens": 11]]])
        data += Data("data: [DONE]\r\n\r\n".utf8)
        for byte in data { try decoder.append(Data([byte])) }
        let response = try decoder.finish()
        XCTAssertEqual(updates, ["Привет ", "Привет 😀"])
        XCTAssertEqual(response.text, "Привет 😀")
        XCTAssertEqual(response.model, "actual")
        XCTAssertTrue(response.isTruncated)
        XCTAssertEqual(response.inputTokens, 4)
        XCTAssertEqual(response.outputTokens, 7)
        XCTAssertEqual(response.totalTokens, 11)
    }

    func testSSEMissingDoneOrTerminalReasonIsNotSuccess() throws {
        let chunk = try event(["choices": [["delta": ["content": "partial"]]]])
        let decoder = WhitegramGroqStreamDecoder(model: "model", onText: { _ in })
        try decoder.append(chunk)
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try decoder.append(Data("data: [DONE]\n\n".utf8)))
        let second = WhitegramGroqStreamDecoder(model: "model", onText: { _ in })
        try second.append(try event(["choices": [["delta": ["content": "answer"], "finish_reason": "stop"]]]))
        XCTAssertThrowsError(try second.finish())
    }

    func testSSERejectsToolsRefusalsWrongTypesAndInvalidUTF8() throws {
        let tools = WhitegramGroqStreamDecoder(model: "model", onText: { _ in XCTFail("No fabricated tool result") })
        XCTAssertThrowsError(try tools.append(try event(["choices": [["delta": ["tool_calls": [["index": 0]]]]]]))) { error in
            XCTAssertEqual(error as? WhitegramServiceError, .unsupportedToolCall)
        }
        let refused = WhitegramGroqStreamDecoder(model: "model", onText: { _ in XCTFail("Refusal must not surface as a reply") })
        XCTAssertThrowsError(try refused.append(try event(["choices": [["delta": ["refusal": "filtered"]]]]))) { error in
            XCTAssertEqual(error as? WhitegramServiceError, .outputBlocked)
        }
        let malformed = WhitegramGroqStreamDecoder(model: "model", onText: { _ in })
        XCTAssertThrowsError(try malformed.append(Data([0xff, 10])))
        let oversized = WhitegramGroqStreamDecoder(model: "model", onText: { _ in })
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: WhitegramServiceLimits.maximumAIResponseBytes + 1))) { error in
            XCTAssertEqual(error as? WhitegramServiceError, .responseTooLarge)
        }
        let usage = WhitegramGroqStreamDecoder(model: "model", onText: { _ in })
        XCTAssertThrowsError(try usage.append(try event(["choices": [], "usage": ["total_tokens": -1]])))
    }

    func testModelDiscoveryUsesProviderContractsWithoutPromptsOrCredentialsInURL() throws {
        let request = try WhitegramAIModelsWire.request(provider: .gemini, apiKey: "fixture-secret", pageToken: "opaque+/token")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-secret")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-secret"))
        let items = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "pageToken" })?.value, "opaque+/token")
        let body: [String: Any] = ["models": [
            ["name": "models/text-model", "displayName": "Text Model", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/embedding", "supportedGenerationMethods": ["embedContent"]]
        ], "nextPageToken": "next"]
        let page = try WhitegramAIModelsWire.response(.init(statusCode: 200, data: JSONSerialization.data(withJSONObject: body)), provider: .gemini)
        XCTAssertEqual(page.models.map { $0.id }, ["text-model"])
        XCTAssertEqual(page.nextPageToken, "next")
        let groq = try WhitegramAIModelsWire.request(provider: .groq, apiKey: "fixture-secret", pageToken: nil)
        XCTAssertEqual(groq.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(groq.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertThrowsError(try WhitegramAIModelsWire.request(provider: .groq, apiKey: "fixture-secret", pageToken: "invalid"))
        let groqBody: [String: Any] = ["data": [["id": "model", "active": true], ["id": "retired", "active": false]]]
        XCTAssertEqual(try WhitegramAIModelsWire.response(.init(statusCode: 200, data: JSONSerialization.data(withJSONObject: groqBody)), provider: .groq).models.map { $0.id }, ["model"])
    }
}
