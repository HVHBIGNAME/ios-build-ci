import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WhitegramAIProvider: String, CaseIterable {
    case gemini
    case groq

    public var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        }
    }

    func validatedModel(_ value: String) throws -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .gemini && value.hasPrefix("models/") {
            value = String(value.dropFirst(7))
        }
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_." + (self == .groq ? "/" : "")
        guard !value.isEmpty, value.utf8.count <= 200, value.utf8.allSatisfy({ characters.utf8.contains($0) }),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WhitegramServiceError.invalidModel
        }
        return value
    }
}

public struct WhitegramAIResponse: Equatable {
    public let provider: WhitegramAIProvider
    public let model: String
    public let text: String
    public let finishReason: String?
    public let isTruncated: Bool
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
}

/// Single-turn text generation. Only `text` is sent; no account, chat history or device identifiers are added.
public final class WhitegramAIService {
    public static let shared = WhitegramAIService()
    private let transport: WhitegramServiceTransport
    private let gate: WhitegramServiceRequestGate

    public init(transport: WhitegramServiceTransport = WhitegramURLSessionTransport(), minimumRequestInterval: TimeInterval = 1) {
        self.transport = transport
        self.gate = WhitegramServiceRequestGate(minimumInterval: minimumRequestInterval)
    }

    @discardableResult
    public func generate(text: String, provider: WhitegramAIProvider, model: String, apiKey: String, completion: @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let operation = WhitegramServiceOperation(completion: completion)
        let prepared = whitegramServiceResult { () -> URLRequest in
            let request = try WhitegramAIWire.request(text: text, provider: provider, model: model, apiKey: apiKey)
            try self.gate.begin()
            return request
        }
        switch prepared {
        case let .failure(error): operation.finish(.failure(error))
        case let .success(request):
            let gate = self.gate
            let child = self.transport.send(request, maximumResponseBytes: WhitegramServiceLimits.maximumAIResponseBytes) { result in
                if case let .success(response) = result {
                    gate.end(retryAfter: response.cooldownSeconds)
                } else {
                    gate.end()
                }
                operation.finish(result.flatMap { response in
                    whitegramServiceResult { try WhitegramAIWire.response(response, provider: provider, model: model) }
                })
            }
            operation.attach(child)
        }
        return operation.task
    }
}

enum WhitegramAIWire {
    static func request(text: String, provider: WhitegramAIProvider, model: String, apiKey: String) throws -> URLRequest {
        let key = try whitegramValidatedAPIKey(apiKey)
        let model = try provider.validatedModel(model)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WhitegramServiceError.emptyPrompt }
        guard text.utf8.count <= WhitegramServiceLimits.maximumPromptBytes else { throw WhitegramServiceError.promptTooLarge }
        let address: String
        let body: [String: Any]
        let header: String
        let headerValue: String
        switch provider {
        case .gemini:
            address = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
            header = "x-goog-api-key"
            headerValue = key
            body = [
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["maxOutputTokens": WhitegramServiceLimits.maximumOutputTokens]
            ]
        case .groq:
            address = "https://api.groq.com/openai/v1/chat/completions"
            header = "Authorization"
            headerValue = "Bearer " + key
            body = [
                "model": model,
                "messages": [["role": "user", "content": text]],
                "max_completion_tokens": WhitegramServiceLimits.maximumOutputTokens,
                "stream": false
            ]
        }
        guard let url = URL(string: address) else { throw WhitegramServiceError.invalidModel }
        return try whitegramServiceRequest(url: url, method: "POST", apiKey: headerValue, header: header, body: JSONSerialization.data(withJSONObject: body))
    }

    static func response(_ response: WhitegramServiceHTTPResponse, provider: WhitegramAIProvider, model: String) throws -> WhitegramAIResponse {
        if let error = whitegramHTTPError(status: response.statusCode, retryAfter: response.retryAfter) { throw error }
        guard response.data.count <= WhitegramServiceLimits.maximumAIResponseBytes else { throw WhitegramServiceError.responseTooLarge }
        let result: WhitegramAIResponse
        switch provider {
        case .gemini: result = try self.gemini(response.data, model: model)
        case .groq: result = try self.groq(response.data, model: model)
        }
        guard result.model.utf8.count <= 256, [result.inputTokens, result.outputTokens, result.totalTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw WhitegramServiceError.invalidResponse
        }
        return result
    }

    private static func gemini(_ data: Data, model: String) throws -> WhitegramAIResponse {
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        if let reason = response.promptFeedback?.blockReason, reason != "BLOCK_REASON_UNSPECIFIED", !reason.isEmpty {
            throw WhitegramServiceError.outputBlocked
        }
        guard let candidates = response.candidates else { throw WhitegramServiceError.invalidResponse }
        guard let candidate = candidates.first(where: { $0.index == 0 }) ?? candidates.first else { throw WhitegramServiceError.noText }
        let blockedReasons = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_RECITATION"]
        if blockedReasons.contains(candidate.finishReason ?? "") || candidate.safetyRatings?.contains(where: { $0.blocked == true }) == true {
            throw WhitegramServiceError.outputBlocked
        }
        let text = (candidate.content?.parts ?? []).filter { $0.thought != true }.compactMap { $0.text }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WhitegramServiceError.noText }
        guard candidate.finishReason == "STOP" || candidate.finishReason == "MAX_TOKENS" else { throw WhitegramServiceError.invalidResponse }
        return WhitegramAIResponse(provider: .gemini, model: response.modelVersion ?? model, text: text,
            finishReason: candidate.finishReason, isTruncated: candidate.finishReason == "MAX_TOKENS",
            inputTokens: response.usageMetadata?.promptTokenCount, outputTokens: response.usageMetadata?.candidatesTokenCount,
            totalTokens: response.usageMetadata?.totalTokenCount)
    }

    private static func groq(_ data: Data, model: String) throws -> WhitegramAIResponse {
        let response = try JSONDecoder().decode(GroqResponse.self, from: data)
        guard let choices = response.choices else { throw WhitegramServiceError.invalidResponse }
        guard let choice = choices.first(where: { $0.index == 0 }) ?? choices.first else { throw WhitegramServiceError.noText }
        if choice.finishReason == "content_filter" || !(choice.message?.refusal ?? "").isEmpty { throw WhitegramServiceError.outputBlocked }
        guard let text = choice.message?.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WhitegramServiceError.noText }
        guard choice.finishReason == "stop" || choice.finishReason == "length" else { throw WhitegramServiceError.invalidResponse }
        return WhitegramAIResponse(provider: .groq, model: response.model ?? model, text: text,
            finishReason: choice.finishReason, isTruncated: choice.finishReason == "length",
            inputTokens: response.usage?.promptTokens, outputTokens: response.usage?.completionTokens, totalTokens: response.usage?.totalTokens)
    }

    private struct GeminiResponse: Decodable {
        struct Feedback: Decodable { let blockReason: String? }
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let totalTokenCount: Int?
        }
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            struct SafetyRating: Decodable { let blocked: Bool? }
            let index: Int?
            let content: Content?
            let finishReason: String?
            let safetyRatings: [SafetyRating]?
        }
        let candidates: [Candidate]?
        let promptFeedback: Feedback?
        let usageMetadata: Usage?
        let modelVersion: String?
    }

    private struct GroqResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let refusal: String?
            }
            let index: Int?
            let message: Message?
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case index, message
                case finishReason = "finish_reason"
            }
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }
        let choices: [Choice]?
        let model: String?
        let usage: Usage?
    }
}
