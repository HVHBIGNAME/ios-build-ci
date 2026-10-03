import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WhitegramAIModel: Equatable {
    public let id: String
    public let title: String
}

public struct WhitegramAIModelPage: Equatable {
    public let models: [WhitegramAIModel]
    public let nextPageToken: String?
}

extension WhitegramAIService {
    @discardableResult
    public func fetchModels(provider: WhitegramAIProvider, apiKey: String, route: WhitegramServiceRoute = .direct, pageToken: String? = nil, completion: @escaping (Result<WhitegramAIModelPage, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.perform(prepare: {
            try route.requireAvailable()
            return try WhitegramAIModelsWire.request(provider: provider, apiKey: apiKey, pageToken: pageToken)
        }, decode: { try WhitegramAIModelsWire.response($0, provider: provider) }, completion: completion)
    }
}

enum WhitegramAIModelsWire {
    static func request(provider: WhitegramAIProvider, apiKey: String, pageToken: String?) throws -> URLRequest {
        let key = try whitegramValidatedAPIKey(apiKey)
        switch provider {
        case .gemini:
            var url = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            var items = [URLQueryItem(name: "pageSize", value: "20")]
            if let pageToken {
                guard !pageToken.isEmpty, pageToken.utf8.count <= 2048 else { throw WhitegramServiceError.invalidResponse }
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            url.queryItems = items
            guard let address = url.url else { throw WhitegramServiceError.invalidResponse }
            return try whitegramServiceRequest(url: address, method: "GET", apiKey: key, header: "x-goog-api-key")
        case .groq:
            guard pageToken == nil else { throw WhitegramServiceError.invalidResponse }
            return try whitegramServiceRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!, method: "GET", apiKey: "Bearer " + key, header: "Authorization")
        }
    }

    static func response(_ response: WhitegramServiceHTTPResponse, provider: WhitegramAIProvider) throws -> WhitegramAIModelPage {
        if let error = whitegramHTTPError(status: response.statusCode, retryAfter: response.retryAfter) { throw error }
        guard response.data.count <= WhitegramServiceLimits.maximumAIResponseBytes else { throw WhitegramServiceError.responseTooLarge }
        let models: [WhitegramAIModel]
        let token: String?
        switch provider {
        case .gemini:
            let page = try JSONDecoder().decode(GeminiPage.self, from: response.data)
            guard page.models.count <= 1000 else { throw WhitegramServiceError.invalidResponse }
            models = try page.models.filter { $0.supportedGenerationMethods?.contains("generateContent") == true }.map { entry in
                WhitegramAIModel(id: try provider.validatedModel(entry.name), title: entry.displayName ?? entry.name)
            }
            token = page.nextPageToken
        case .groq:
            let page = try JSONDecoder().decode(GroqPage.self, from: response.data)
            guard page.data.count <= 1000 else { throw WhitegramServiceError.invalidResponse }
            models = try page.data.filter { $0.active != false }.map { entry in WhitegramAIModel(id: try provider.validatedModel(entry.id), title: entry.id) }
            token = nil
        }
        guard Set(models.map { $0.id }).count == models.count, models.allSatisfy({ $0.title.utf8.count <= 512 }),
              token.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) != false else { throw WhitegramServiceError.invalidResponse }
        return WhitegramAIModelPage(models: models, nextPageToken: token)
    }

    private struct GeminiPage: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]
        let nextPageToken: String?
    }

    private struct GroqPage: Decodable {
        struct Model: Decodable { let id: String; let active: Bool? }
        let data: [Model]
    }
}
