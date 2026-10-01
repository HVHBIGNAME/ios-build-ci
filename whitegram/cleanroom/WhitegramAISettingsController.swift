import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore

private final class WhitegramAICoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private var observers: [NSObjectProtocol] = []
    private var prompt: String
    private var openInitialComposer: Bool
    private let historyDirectory: URL
    private let accountId: Int64
    private var drafts: [WhitegramAIProvider: String] = [:]
    private var historyProvider: WhitegramAIProvider?
    private var hasLoadedHistory = false
    private var historyStore: WhitegramAIConversationStore?
    private var history: WhitegramAIConversationSession?
    private var historyLoadError: WhitegramServiceError?
    private var configuration: [String]?
    private var refreshing = false
    private var status = ""
    private var connection = "Not checked. Send a prompt to check the configured model."

    init(context: AccountContext, text: String?) {
        self.prompt = text ?? ""
        self.openInitialComposer = text != nil
        self.accountId = context.account.id.int64
        self.historyDirectory = URL(fileURLWithPath: context.account.basePath, isDirectory: true).appendingPathComponent("whitegram-ai-v1", isDirectory: true)
        self.presenter.changed = { [weak self] in self?.refresh() }
        self.observers.append(whitegramServiceObserve(WhitegramPreferences.updatedNotification) { [weak self] _ in self?.refresh() })
        self.observers.append(whitegramServiceObserve(WhitegramServiceCredential.updatedNotification) { [weak self] notification in
            guard let self = self, let credential = notification.object as? WhitegramServiceCredential, credential == self.historyProvider?.credential else { return }
            self.cancel(message: "API key changed. Request cancelled.")
            self.connection = "Not checked for this API key."
            self.refresh()
        })
        self.observers.append(whitegramServiceObserve(UIApplication.didEnterBackgroundNotification) { [weak self] _ in self?.cancel() })
        self.observers.append(whitegramServiceObserve(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.refresh() })
        self.refresh()
    }

    deinit {
        self.history?.changed = nil
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func appeared() {
        if self.history?.isRequesting != true { self.loadHistory() }
        self.refresh()
        if self.openInitialComposer {
            self.openInitialComposer = false
            self.perform("compose")
        }
    }

    func disappeared() {
        if !self.presenter.isPresenting { self.cancel() }
    }

    func refresh() {
        guard !self.refreshing else { return }
        self.refreshing = true
        defer { self.refreshing = false }
        let provider = WhitegramAIProvider.configured
        if !self.hasLoadedHistory || self.historyProvider != provider {
            self.history?.changed = nil
            self.history?.cancel()
            if self.hasLoadedHistory {
                if let previous = self.historyProvider { self.drafts[previous] = self.prompt }
                self.prompt = provider.flatMap { self.drafts[$0] } ?? ""
                self.status = ""
                self.connection = "Not checked for this provider."
            }
            self.hasLoadedHistory = true
            self.historyProvider = provider
            self.historyStore = provider.map { WhitegramAIConversationStore(directory: self.historyDirectory, accountId: self.accountId, provider: $0) }
            self.loadHistory()
        }
        let enabled = WhitegramPreferences.bool("geminiEnabled")
        let model = provider.map { WhitegramPreferences.string($0.modelPreference) } ?? ""
        var keyAvailable = false
        var credentialError: WhitegramServiceError?
        if let provider = provider {
            do { keyAvailable = try WhitegramServiceCredentials.vault.token(for: provider.credential) != nil }
            catch { credentialError = error as? WhitegramServiceError ?? .preferences }
        }
        let configuration = [provider?.rawValue ?? "", model, enabled ? "1" : "0", keyAvailable ? "1" : "0"]
        if let previous = self.configuration, previous != configuration {
            self.cancel(message: "Configuration changed. Request cancelled.")
            self.connection = "Not checked for these settings."
        }
        self.configuration = configuration
        let requesting = self.history?.isRequesting == true
        let idle = !requesting && !self.presenter.isPresenting
        let historyError = self.historyLoadError ?? self.history?.storageError
        let canSend = idle && enabled && provider != nil && keyAvailable && !model.isEmpty && self.history != nil && historyError == nil
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ section: Int32, _ content: WhitegramServiceEntry.Content) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("enabled", 0, .toggle("Enable AI Requests", enabled, idle))
        add("provider", 0, .disclosure("Provider", provider?.title ?? "Choose", idle))
        add("model", 0, .disclosure("Model ID", model.isEmpty ? "Enter model ID" : String(model.prefix(80)), idle && provider != nil))
        add("key", 0, .disclosure("API Key", keyAvailable ? "•••••••• · Keychain" : "Not set", idle && provider != nil))
        add("removeKey", 0, .action("Remove This Provider's API Key", idle && provider != nil && (keyAvailable || credentialError != nil)))
        if let error = credentialError { add("credentialError", 0, .text(error.localizedDescription)) }
        add("modelInfo", 0, .text("Enter a text-capable model ID available to your provider account. Each provider keeps its own model ID and API key. Keys are stored in this device's Keychain."))
        add("network", 0, .text("Official Gemini and Groq APIs via Apple URLSession and system network settings. Replies have a 4,096-token output limit."))
        add("promptHeader", 1, .header("PROMPT"))
        add("compose", 1, .action("Compose Prompt…", idle))
        add("prompt", 1, .text(self.prompt.isEmpty ? "Write or paste the text you want to send." : String(self.prompt.prefix(500)) + (self.prompt.count > 500 ? "…" : "")))
        add("promptPrivacy", 1, .text("Send Prompt sends your text and all completed turns in this provider's conversation. History is saved on this device separately for each Telegram account and provider. Failed or cancelled prompts are not sent as context. Clear History starts a new conversation."))
        add("send", 1, .action("Send Prompt", canSend && !self.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        if self.history?.canRetry == true { add("retry", 1, .action("Retry Last Prompt", canSend)) }
        if requesting { add("cancel", 1, .action("Cancel Request", true)) }
        add("connection", 1, .text("Connection: " + self.connection))
        if !self.status.isEmpty { add("status", 1, .text(self.status)) }
        add("historyHeader", 2, .header((provider?.title.uppercased() ?? "AI") + " CONVERSATION"))
        if let error = historyError {
            add("historyError", 2, .text(error.localizedDescription + " Any reply shown after a save failure is available to copy but may not be saved."))
            add("reloadHistory", 2, .action("Reload Saved History", idle))
        }
        let turns = self.history?.snapshot.turns ?? []
        if turns.isEmpty { add("emptyHistory", 2, .text("No saved conversation for this account and provider.")) }
        for turn in turns.suffix(8) {
            let prefix = "turn:" + turn.id.uuidString
            add(prefix + ":user", 2, .text("You · " + whitegramServiceDate(turn.date) + "\n" + whitegramAIPreview(turn.prompt, limit: 500)))
            if let response = turn.response {
                add(prefix + ":reply", 2, .text(response.provider.title + " · " + response.model + "\n" + whitegramAIPreview(response.text, limit: 800)))
                if response.isTruncated { add(prefix + ":partial", 2, .text("The provider reached the output limit. This reply is partial.")) }
            } else {
                let state: String
                switch turn.state {
                case .pending: state = requesting ? "Waiting for a reply…" : "Interrupted. Retry Last Prompt resubmits it explicitly."
                case .cancelled: state = "Cancelled. No reply was saved."
                case .failed: state = "Request failed. No reply was saved."
                case .answered: state = "Reply unavailable."
                }
                add(prefix + ":state", 2, .text(state))
            }
        }
        if turns.count > 8 { add("moreHistory", 2, .text("Showing the latest 8 of \(turns.count) turns. View Full Transcript includes all saved turns.")) }
        add("viewHistory", 2, .action("View Full Transcript", idle && !turns.isEmpty))
        add("clearHistory", 2, .action("Clear This Provider's History…", !self.presenter.isPresenting && self.historyStore != nil))
        if let response = turns.last?.response {
            add("viewResponse", 2, .action("View Last Reply", idle))
            add("copyResponse", 2, .action("Copy Last Reply", idle))
            var usage: [String] = []
            if let input = response.inputTokens { usage.append("Input: \(input)") }
            if let output = response.outputTokens { usage.append("Output: \(output)") }
            if let total = response.totalTokens { usage.append("Total: \(total)") }
            if !usage.isEmpty { add("usage", 2, .text("Last reply's provider-reported tokens — " + usage.joined(separator: " · "))) }
        }
        self.entries.set(rows)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.history?.isRequesting != true, !self.presenter.isPresenting else { return }
        self.save(["geminiEnabled": enabled])
    }

    private func save(_ changes: [String: Any]) {
        if WhitegramPreferences.update(changes) {
            self.status = "Settings saved."
        } else {
            self.status = WhitegramServiceError.preferences.localizedDescription
        }
        self.refresh()
    }

    func perform(_ id: String) {
        if id == "cancel" { self.cancel(); return }
        if id == "clearHistory", !self.presenter.isPresenting { self.clearHistory(); return }
        guard self.history?.isRequesting != true, !self.presenter.isPresenting else { return }
        switch id {
        case "provider": self.chooseProvider()
        case "model": self.editModel()
        case "key": self.editKey()
        case "removeKey": self.removeKey()
        case "compose":
            let provider = self.historyProvider
            self.checkPresentation(self.presenter.showText(title: "AI Prompt", text: self.prompt, editable: true, saved: { [weak self] text in
                guard let self = self, self.historyProvider == provider else { return }
                self.prompt = text
                self.status = "Prompt ready. Tap Send Prompt to submit it."
                self.refresh()
            }))
        case "send": self.send(retry: false)
        case "retry": self.send(retry: true)
        case "reloadHistory": self.loadHistory(); self.refresh()
        case "viewHistory":
            if let history = self.history {
                self.checkPresentation(self.presenter.showText(title: history.provider.title + " Conversation", text: whitegramAITranscript(history.snapshot.turns)))
            }
        case "viewResponse":
            if let response = self.history?.snapshot.turns.last?.response { self.checkPresentation(self.presenter.showText(title: response.provider.title + " Response", text: response.text)) }
        case "copyResponse":
            if let response = self.history?.snapshot.turns.last?.response {
                whitegramServiceCopy(response.text)
                self.status = "Response copied to this device's clipboard for one hour."
                self.refresh()
            }
        default: break
        }
    }

    private func chooseProvider() {
        let alert = UIAlertController(title: "AI Provider", message: "Choose the provider that will receive your submitted text.", preferredStyle: .alert)
        for provider in WhitegramAIProvider.allCases {
            alert.addAction(UIAlertAction(title: provider.title, style: .default, handler: { [weak self] _ in
                self?.presenter.close()
                self?.save(["aiProvider": provider.rawValue])
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in self?.presenter.close() }))
        self.checkPresentation(self.presenter.present(alert))
    }

    private func editModel() {
        guard let provider = WhitegramAIProvider.configured else { return }
        self.checkPresentation(self.presenter.editValue(title: provider.title + " Model ID", message: "Use an exact text-generation model ID from your provider account.",
            value: WhitegramPreferences.string(provider.modelPreference), placeholder: "Model ID", saved: { [weak self] value in
                do { self?.save([provider.modelPreference: try provider.validatedModel(value)]) }
                catch { self?.status = (error as? WhitegramServiceError ?? .invalidModel).localizedDescription; self?.refresh() }
            }))
    }

    private func editKey() {
        guard let provider = WhitegramAIProvider.configured else { return }
        self.checkPresentation(self.presenter.editValue(title: provider.title + " API Key", message: "Paste a new API key. The saved key is never displayed. Saving a key does not test the connection.",
            placeholder: "API key", secure: true, saved: { [weak self] value in
                do {
                    try WhitegramServiceCredentials.vault.save(value, for: provider.credential)
                    self?.status = "API key saved in Keychain. Send a prompt to test it."
                } catch {
                    self?.status = (error as? WhitegramServiceError ?? .preferences).localizedDescription
                }
                self?.refresh()
            }))
    }

    private func removeKey() {
        guard let provider = WhitegramAIProvider.configured else { return }
        do {
            try WhitegramServiceCredentials.vault.remove(provider.credential)
            self.status = "API key removed."
        } catch {
            self.status = (error as? WhitegramServiceError ?? .preferences).localizedDescription
        }
        self.refresh()
    }

    private func loadHistory() {
        guard self.history?.isRequesting != true else { return }
        self.history?.changed = nil
        self.history = nil
        self.historyLoadError = nil
        guard let store = self.historyStore, let provider = self.historyProvider else { return }
        do {
            let history = try WhitegramAIConversationSession(provider: provider, storage: store)
            history.changed = { [weak self] in self?.historyChanged() }
            self.history = history
        } catch {
            self.historyLoadError = error as? WhitegramServiceError ?? .conversationStorage
        }
    }

    private func historyChanged() {
        if let result = self.history?.lastResult {
            switch result {
            case let .success(response):
                self.connection = "Response received from \(response.provider.title) (\(response.model)) at \(whitegramServiceDate(Date()))."
                self.status = self.history?.storageError == nil ? "Reply received and saved." : "Reply received but could not be saved."
            case let .failure(error):
                self.status = error.localizedDescription
                switch error {
                case .httpStatus, .outputBlocked, .noText, .invalidResponse, .responseTooLarge:
                    self.connection = "The request did not produce a usable response at \(whitegramServiceDate(Date()))."
                case .network, .timedOut, .redirectRefused:
                    self.connection = "Connection failed at \(whitegramServiceDate(Date()))."
                default: break
                }
            }
        }
        self.refresh()
    }

    private func send(retry: Bool) {
        guard let history = self.history, let provider = self.historyProvider else { return }
        let sender: WhitegramAIConversationSession.Sender = { messages, model, completion in
            do {
                guard WhitegramPreferences.bool("geminiEnabled") else { throw WhitegramServiceError.disabled }
                guard WhitegramAIProvider.configured == provider else { throw WhitegramServiceError.invalidProvider }
                guard let key = try WhitegramServiceCredentials.vault.token(for: provider.credential) else { throw WhitegramServiceError.missingAPIKey }
                return WhitegramAIService.shared.generate(messages: messages, provider: provider, model: model, apiKey: key, completion: completion)
            } catch {
                let operation = WhitegramServiceOperation(completion: completion)
                operation.finish(.failure(error as? WhitegramServiceError ?? .preferences))
                return operation.task
            }
        }
        do {
            let model = WhitegramPreferences.string(provider.modelPreference)
            if retry {
                try history.retry(model: model, sender: sender)
            } else {
                try history.send(text: self.prompt, model: model, sender: sender)
                self.prompt = ""
            }
            self.status = "Sending this prompt with the completed conversation…"
        } catch {
            let error = error as? WhitegramServiceError ?? .conversationStorage
            self.status = error == .requestTooLarge ? "The complete conversation exceeds the 256 KiB request limit. Clear History to start a new conversation. No request was sent." : error.localizedDescription
        }
        self.refresh()
    }

    private func clearHistory() {
        guard let provider = self.historyProvider, let store = self.historyStore else { return }
        let alert = UIAlertController(title: "Clear \(provider.title) History?", message: "Deletes this provider's local conversation for the current Telegram account and cancels its active reply. It cannot remove text already received by the provider.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in self?.presenter.close() }))
        alert.addAction(UIAlertAction(title: "Clear History", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            self.presenter.close()
            guard self.historyProvider == provider else { return }
            do {
                if let history = self.history { try history.clear() } else { _ = try store.clear() }
                self.prompt = ""
                self.drafts[provider] = nil
                self.loadHistory()
                self.status = "History cleared. Your next prompt starts a new conversation."
            } catch {
                self.status = (error as? WhitegramServiceError ?? .conversationStorage).localizedDescription
            }
            self.refresh()
        }))
        self.checkPresentation(self.presenter.present(alert))
    }

    private func cancel(message: String = "Request cancelled.") {
        guard self.history?.isRequesting == true else { return }
        self.history?.cancel()
        self.status = message
        self.refresh()
    }

    private func checkPresentation(_ success: Bool) {
        if !success { self.status = "The screen is not ready to present an editor. Try again after the transition."; self.refresh() }
    }
}

private func whitegramAIPreview(_ text: String, limit: Int) -> String {
    let preview = String(text.prefix(limit))
    return preview + (preview.endIndex == text.endIndex ? "" : "…")
}

private func whitegramAITranscript(_ turns: [WhitegramAIConversationTurn]) -> String {
    return turns.map { turn in
        var text = "You · " + whitegramServiceDate(turn.date) + "\n" + turn.prompt
        if let response = turn.response {
            text += "\n\n" + response.provider.title + " · " + response.model + (response.isTruncated ? " (partial)" : "") + "\n" + response.text
        } else {
            text += "\n\n[" + (turn.state == .pending ? "interrupted" : turn.state.rawValue) + "]"
        }
        return text
    }.joined(separator: "\n\n──────────\n\n")
}

public func whitegramAISettingsController(context: AccountContext) -> ViewController {
    return whitegramAISettingsController(context: context, text: nil)
}

/// Prefills the composer with selected message text. Nothing is submitted until the user taps Send Prompt.
public func whitegramAISettingsController(context: AccountContext, text: String?) -> ViewController {
    let coordinator = WhitegramAICoordinator(context: context, text: text)
    let controller = whitegramServiceListController(context: context, title: "AI", entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.appeared() }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
