import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension WhitegramAIService {
    /// The original Gemini manager used generateContent; Groq used an SSE completion stream.
    @discardableResult
    public func generateStreaming(messages: [WhitegramAIMessage], provider: WhitegramAIProvider, model: String, apiKey: String, route: WhitegramServiceRoute = .direct, onText: @escaping (String) -> Void, completion: @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        if provider == .gemini {
            return self.generate(messages: messages, provider: provider, model: model, apiKey: apiKey, route: route) { result in
                if case let .success(response) = result { onText(response.text) }
                completion(result)
            }
        }
        let operation = WhitegramServiceOperation(completion: completion)
        do {
            try route.requireAvailable()
            guard let transport = self.transport as? WhitegramServiceStreamingTransport else { throw WhitegramServiceError.streamingUnavailable }
            var request = try WhitegramAIWire.request(messages: messages, provider: provider, model: model, apiKey: apiKey)
            guard let body = request.httpBody, var value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw WhitegramServiceError.invalidResponse }
            value["stream"] = true
            request.httpBody = try JSONSerialization.data(withJSONObject: value)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let decoder = WhitegramGroqStreamDecoder(model: model, onText: { text in
                DispatchQueue.main.async { if !operation.task.isCancelled { onText(text) } }
            })
            try self.gate.begin()
            let child = transport.stream(request, maximumResponseBytes: WhitegramServiceLimits.maximumAIResponseBytes, received: { data in
                try decoder.append(data)
            }) { result in
                if case let .success(response) = result { self.gate.end(retryAfter: response.cooldownSeconds) } else { self.gate.end() }
                operation.finish(result.flatMap { response in
                    whitegramServiceResult {
                        if let error = whitegramHTTPError(status: response.statusCode, retryAfter: response.retryAfter) { throw error }
                        return try decoder.finish()
                    }
                })
            }
            operation.attach(child)
        } catch {
            operation.finish(.failure(error as? WhitegramServiceError ?? .invalidResponse))
        }
        return operation.task
    }
}

/// Incremental UTF-8 SSE framing. A frame can span arbitrary URLSession chunk boundaries.
final class WhitegramGroqStreamDecoder {
    private let requestedModel: String
    private let onText: (String) -> Void
    private var line = Data()
    private var fields: [String] = []
    private var afterCR = false
    private var bytes = 0
    private var done = false
    private var text = ""
    private var model: String?
    private var reason: String?
    private var usage: Chunk.Usage?

    init(model: String, onText: @escaping (String) -> Void) {
        self.requestedModel = model
        self.onText = onText
    }

    func append(_ data: Data) throws {
        guard data.count <= WhitegramServiceLimits.maximumAIResponseBytes - self.bytes else { throw WhitegramServiceError.responseTooLarge }
        self.bytes += data.count
        for byte in data {
            if byte == 13 {
                try self.endLine()
                self.afterCR = true
            } else if byte == 10 {
                if !self.afterCR { try self.endLine() }
                self.afterCR = false
            } else {
                self.afterCR = false
                self.line.append(byte)
                guard self.line.count <= WhitegramServiceLimits.maximumAIResponseBytes else { throw WhitegramServiceError.responseTooLarge }
            }
        }
    }

    private func endLine() throws {
        guard let value = String(data: self.line, encoding: .utf8) else { throw WhitegramServiceError.invalidResponse }
        self.line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            if !self.fields.isEmpty {
                let data = self.fields.joined(separator: "\n")
                self.fields.removeAll(keepingCapacity: true)
                try self.event(data)
            }
        } else if value == "data" {
            self.fields.append("")
        } else if value.hasPrefix("data:") {
            let data = value.dropFirst(5)
            self.fields.append(String(data.first == " " ? data.dropFirst() : data))
        }
    }

    private func event(_ data: String) throws {
        guard !self.done else { throw WhitegramServiceError.invalidResponse }
        if data == "[DONE]" {
            guard self.reason != nil else { throw WhitegramServiceError.invalidResponse }
            self.done = true
            return
        }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(data.utf8))
        if let model = chunk.model {
            guard !model.isEmpty, model.utf8.count <= 256, self.model == nil || self.model == model else { throw WhitegramServiceError.invalidResponse }
            self.model = model
        }
        if let usage = chunk.usage ?? chunk.xGroq?.usage {
            guard [usage.promptTokens, usage.completionTokens, usage.totalTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw WhitegramServiceError.invalidResponse }
            self.usage = usage
        }
        guard let choices = chunk.choices else { throw WhitegramServiceError.invalidResponse }
        guard let choice = choices.first(where: { $0.index == 0 }) ?? choices.first(where: { $0.index == nil }) else { return }
        guard self.reason == nil else { throw WhitegramServiceError.invalidResponse }
        if !(choice.delta?.refusal ?? "").isEmpty || choice.finishReason == "content_filter" { throw WhitegramServiceError.outputBlocked }
        if choice.delta?.toolCalls?.isEmpty == false { throw WhitegramServiceError.unsupportedToolCall }
        if let content = choice.delta?.content, !content.isEmpty {
            guard content.utf8.count <= WhitegramServiceLimits.maximumAIResponseBytes - self.text.utf8.count else { throw WhitegramServiceError.responseTooLarge }
            self.text += content
            self.onText(self.text)
        }
        if let reason = choice.finishReason {
            guard reason == "stop" || reason == "length" else { throw WhitegramServiceError.invalidResponse }
            self.reason = reason
        }
    }

    func finish() throws -> WhitegramAIResponse {
        guard self.done, self.line.isEmpty, self.fields.isEmpty, let reason = self.reason else { throw WhitegramServiceError.invalidResponse }
        guard !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WhitegramServiceError.noText }
        return WhitegramAIResponse(provider: .groq, model: self.model ?? self.requestedModel, text: self.text, finishReason: reason, isTruncated: reason == "length", inputTokens: self.usage?.promptTokens, outputTokens: self.usage?.completionTokens, totalTokens: self.usage?.totalTokens)
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Tool: Decodable { let index: Int? }
                let content: String?
                let refusal: String?
                let toolCalls: [Tool]?
                enum CodingKeys: String, CodingKey { case content, refusal; case toolCalls = "tool_calls" }
            }
            let index: Int?
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case index, delta; case finishReason = "finish_reason" }
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
            }
        }
        struct GroqMetadata: Decodable { let usage: Usage? }
        let model: String?
        let choices: [Choice]?
        let usage: Usage?
        let xGroq: GroqMetadata?
        enum CodingKeys: String, CodingKey { case model, choices, usage; case xGroq = "x_groq" }
    }
}
