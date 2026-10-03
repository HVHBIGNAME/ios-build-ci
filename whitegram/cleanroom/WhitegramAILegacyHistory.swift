import Foundation

/// The v5 IPA stored JSONEncoder Data containing [PersistedEntry], for both providers.
/// It did not store account IDs, dates, model IDs, token counts or completion states.
struct WhitegramAILegacyEntry: Codable, Equatable {
    let role: String
    let text: String
}

struct WhitegramAILegacyHistory: Codable, Equatable {
    let sourceKey: String
    let entries: [WhitegramAILegacyEntry]

    static func key(for provider: WhitegramAIProvider) -> String {
        return provider == .gemini ? "wg_geminiChatHistory_v5" : "wg_groqChatHistory_v5"
    }

    static func decode(_ data: Data, provider: WhitegramAIProvider) throws -> WhitegramAILegacyHistory {
        guard data.count <= WhitegramServiceLimits.maximumAIHistoryBytes else { throw WhitegramServiceError.conversationFull }
        do {
            let entries = try JSONDecoder().decode([WhitegramAILegacyEntry].self, from: data)
            let history = WhitegramAILegacyHistory(sourceKey: self.key(for: provider), entries: entries)
            try history.validate(provider: provider)
            return history
        } catch let error as WhitegramServiceError {
            throw error
        } catch {
            throw WhitegramServiceError.legacyHistoryFormat
        }
    }

    func validate(provider: WhitegramAIProvider) throws {
        guard self.sourceKey == Self.key(for: provider), self.entries.count <= 200,
              self.entries.allSatisfy({ ($0.role == "user" || $0.role == "model") && $0.text.utf8.count <= WhitegramServiceLimits.maximumAIResponseBytes }) else {
            throw WhitegramServiceError.legacyHistoryFormat
        }
    }

    /// A saved suffix can start with an orphan assistant or end with an unanswered user.
    /// Preserve those entries in the transcript; only complete adjacent pairs are context.
    var completedMessages: [WhitegramAIMessage] {
        var messages: [WhitegramAIMessage] = []
        var index = 0
        while index + 1 < self.entries.count {
            let user = self.entries[index]
            let reply = self.entries[index + 1]
            if user.role == "user", reply.role == "model",
               !user.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(WhitegramAIMessage(role: .user, text: user.text))
                messages.append(WhitegramAIMessage(role: .assistant, text: reply.text))
                index += 2
            } else {
                index += 1
            }
        }
        return messages
    }

    var transcript: String {
        return self.entries.map { ($0.role == "user" ? "You" : "AI") + "\n" + $0.text }.joined(separator: "\n\n──────────\n\n")
    }
}
