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
    private var response: WhitegramAIResponse?
    private var request: WhitegramServiceTask?
    private var requestId: UUID?
    private var configuration: [String]?
    private var refreshing = false
    private var status = ""
    private var connection = "Not checked. Send a prompt to check the configured model."

    init(text: String?) {
        self.prompt = text ?? ""
        self.openInitialComposer = text != nil
        self.presenter.changed = { [weak self] in self?.refresh() }
        self.observers.append(whitegramServiceObserve(WhitegramPreferences.updatedNotification) { [weak self] _ in self?.refresh() })
        self.observers.append(whitegramServiceObserve(WhitegramServiceCredential.updatedNotification) { [weak self] notification in
            guard let self = self, let credential = notification.object as? WhitegramServiceCredential, credential != .virusTotal else { return }
            self.cancel(message: "API key changed. Request cancelled.")
            self.connection = "Not checked for this API key."
            self.response = nil
            self.refresh()
        })
        self.observers.append(whitegramServiceObserve(UIApplication.didEnterBackgroundNotification) { [weak self] _ in self?.cancel() })
        self.observers.append(whitegramServiceObserve(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.refresh() })
        self.refresh()
    }

    deinit {
        self.request?.cancel()
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func appeared() {
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
            self.response = nil
        }
        self.configuration = configuration
        let idle = self.request == nil && !self.presenter.isPresenting
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
        add("network", 0, .text("Official Gemini and Groq APIs via Apple URLSession and system network settings. Requests are single-turn text with a 4,096-token output limit."))
        add("promptHeader", 1, .header("PROMPT"))
        add("compose", 1, .action("Compose Prompt…", idle))
        add("prompt", 1, .text(self.prompt.isEmpty ? "Write or paste the text you want to send." : String(self.prompt.prefix(500)) + (self.prompt.count > 500 ? "…" : "")))
        add("promptPrivacy", 1, .text("Send Prompt sends only the text you entered to the selected provider. The prompt and response stay in memory while this screen is open."))
        add("send", 1, .action("Send Prompt", idle && enabled && provider != nil && keyAvailable && !model.isEmpty && !self.prompt.isEmpty))
        if self.request != nil { add("cancel", 1, .action("Cancel Request", true)) }
        add("connection", 1, .text("Connection: " + self.connection))
        if !self.status.isEmpty { add("status", 1, .text(self.status)) }
        if let response = self.response {
            add("responseHeader", 2, .header("RESPONSE"))
            add("response", 2, .text(String(response.text.prefix(800)) + (response.text.count > 800 ? "…" : "")))
            add("viewResponse", 2, .action("View Full Response", idle))
            add("copyResponse", 2, .action("Copy Response", idle))
            if response.isTruncated { add("truncated", 2, .text("The provider reached the output limit. This response is partial.")) }
            var usage: [String] = []
            if let input = response.inputTokens { usage.append("Input: \(input)") }
            if let output = response.outputTokens { usage.append("Output: \(output)") }
            if let total = response.totalTokens { usage.append("Total: \(total)") }
            if !usage.isEmpty { add("usage", 2, .text("Provider-reported tokens — " + usage.joined(separator: " · "))) }
        }
        self.entries.set(rows)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.request == nil, !self.presenter.isPresenting else { return }
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
        guard self.request == nil, !self.presenter.isPresenting else { return }
        switch id {
        case "provider": self.chooseProvider()
        case "model": self.editModel()
        case "key": self.editKey()
        case "removeKey": self.removeKey()
        case "compose":
            self.checkPresentation(self.presenter.showText(title: "AI Prompt", text: self.prompt, editable: true, saved: { [weak self] text in
                self?.prompt = text
                self?.status = "Prompt ready. Tap Send Prompt to submit it."
                self?.refresh()
            }))
        case "send": self.send()
        case "viewResponse":
            if let response = self.response { self.checkPresentation(self.presenter.showText(title: response.provider.title + " Response", text: response.text)) }
        case "copyResponse":
            if let response = self.response {
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

    private func send() {
        let id = UUID()
        self.requestId = id
        self.response = nil
        self.status = "Sending your prompt…"
        self.request = whitegramGenerateAIText(self.prompt) { [weak self] result in
            guard let self = self, self.requestId == id else { return }
            self.request = nil
            self.requestId = nil
            switch result {
            case let .success(response):
                self.response = response
                self.connection = "Response received from \(response.provider.title) (\(response.model)) at \(whitegramServiceDate(Date()))."
                self.status = "Response received."
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
            self.refresh()
        }
        self.refresh()
    }

    private func cancel(message: String = "Request cancelled.") {
        guard let request = self.request else { return }
        self.requestId = nil
        self.request = nil
        request.cancel()
        self.status = message
        self.refresh()
    }

    private func checkPresentation(_ success: Bool) {
        if !success { self.status = "The screen is not ready to present an editor. Try again after the transition."; self.refresh() }
    }
}

public func whitegramAISettingsController(context: AccountContext) -> ViewController {
    return whitegramAISettingsController(context: context, text: nil)
}

/// Prefills the composer with selected message text. Nothing is submitted until the user taps Send Prompt.
public func whitegramAISettingsController(context: AccountContext, text: String?) -> ViewController {
    let coordinator = WhitegramAICoordinator(text: text)
    let controller = whitegramServiceListController(context: context, title: "AI", entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.appeared() }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
