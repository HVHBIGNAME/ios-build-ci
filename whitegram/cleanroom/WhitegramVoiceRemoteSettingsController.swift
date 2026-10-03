import Foundation
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private struct WhitegramVoiceRemoteState: Equatable {
    var key = ""
    var voiceId: String
    var useProxy: Bool
    var voices: [WhitegramVoiceRemoteVoice] = []
    var loading = false
    var status = ""
}

private struct WhitegramVoiceRemoteEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case key(String), voiceId(String), proxy(Bool), status(String), load(Bool), save, clear
        case voice(WhitegramVoiceRemoteVoice, Bool)
    }
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramVoiceRemoteCoordinator
        switch self.content {
        case let .key(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: WhitegramLocalization.string("s.vcApiKey")), text: value, placeholder: "Enter a new key", type: .password, maxLength: 4096, sectionId: self.section, textUpdated: { coordinator.editKey($0) }, action: { coordinator.save() })
        case let .voiceId(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Voice ID"), text: value, placeholder: WhitegramLocalization.string("s.vcNoVoice"), type: .regular(capitalization: false, autocorrection: false), maxLength: 256, sectionId: self.section, textUpdated: { coordinator.editVoice($0) }, action: { coordinator.save() })
        case let .proxy(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.vcUseProxy"), value: value, sectionId: self.section, style: .blocks, updated: { coordinator.setProxy($0) })
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .load(loading):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: loading ? "Cancel" : "Check Connection / Load Voices", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { coordinator.load() })
        case .save:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Save", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { coordinator.save() })
        case .clear:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Remove API Key", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: { coordinator.clearKey() })
        case let .voice(voice, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: voice.name, subtitle: voice.id, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { coordinator.select(voice) })
        }
    }
}

private final class WhitegramVoiceRemoteCoordinator {
    let state: ValuePromise<WhitegramVoiceRemoteState>
    private var current: WhitegramVoiceRemoteState
    private var task: WhitegramVoiceTask?
    private var generation = 0

    init() {
        let settings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
        self.current = WhitegramVoiceRemoteState(voiceId: settings.voiceId, useProxy: settings.useProxy)
        self.state = ValuePromise(self.current, ignoreRepeated: true)
    }
    deinit { self.task?.cancel() }

    func editKey(_ text: String) { self.cancel(); self.current.key = text; self.state.set(self.current) }
    func editVoice(_ text: String) { self.current.voiceId = text; self.state.set(self.current) }
    func setProxy(_ value: Bool) {
        self.cancel()
        if WhitegramPreferences.set(value, for: "voiceChangerUseProxy") {
            self.current.useProxy = value
            self.current.voices = []
            self.current.status = ""
        } else { self.current.status = "Could not save connection settings." }
        self.state.set(self.current)
    }

    @discardableResult
    func save() -> Bool {
        self.cancel()
        do {
            let id = self.current.voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.isEmpty || WhitegramVoiceRemoteService.isValidVoiceId(id) else { throw WhitegramVoiceProcessingError.missingVoice }
            if !self.current.key.isEmpty {
                try WhitegramVoiceCredentials.save(self.current.key)
                guard WhitegramPreferences.set("", for: "voiceChangerApiKey") else { throw WhitegramVoiceProcessingError.credentialStore(-1) }
                self.current.key = ""
            }
            let oldId = WhitegramPreferences.string("voiceChangerVoiceId")
            let name = self.current.voices.first(where: { $0.id == id })?.name ?? (oldId == id ? WhitegramPreferences.string("voiceChangerVoiceName") : "")
            guard WhitegramPreferences.update(["voiceChangerVoiceId": id, "voiceChangerVoiceName": name]) else {
                self.current.status = "Could not save the selected voice."
                self.state.set(self.current)
                return false
            }
            self.current.voiceId = id
            self.current.status = "Saved. Check the connection to retrieve available voices."
            self.state.set(self.current)
            return true
        } catch {
            self.current.status = error.localizedDescription
            self.state.set(self.current)
            return false
        }
    }

    func clearKey() {
        self.cancel()
        do {
            guard WhitegramPreferences.set("", for: "voiceChangerApiKey") else { throw WhitegramVoiceProcessingError.credentialStore(-1) }
            try WhitegramVoiceCredentials.save("")
            self.current.key = ""
            self.current.status = "API key removed."
        } catch { self.current.status = error.localizedDescription }
        self.state.set(self.current)
    }

    func select(_ voice: WhitegramVoiceRemoteVoice) {
        if WhitegramPreferences.update(["voiceChangerVoiceId": voice.id, "voiceChangerVoiceName": voice.name]) {
            self.current.voiceId = voice.id
        } else { self.current.status = "Could not save the selected voice." }
        self.state.set(self.current)
    }

    func load() {
        if self.current.loading {
            self.cancel()
            self.current.status = "Cancelled."
            self.state.set(self.current)
            return
        }
        if !self.current.key.isEmpty && !self.save() { return }
        do {
            let key = try WhitegramVoiceRuntime.apiKey()
            let task = WhitegramVoiceTask()
            self.task = task
            self.generation += 1
            let generation = self.generation
            self.current.loading = true
            self.current.status = WhitegramLocalization.string("s.vcConnecting")
            self.state.set(self.current)
            WhitegramVoiceRuntime.remoteService().voices(key: key, useProxy: self.current.useProxy, task: task) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, generation == self.generation, !task.isCancelled else { return }
                    self.task = nil
                    task.cancel()
                    self.current.loading = false
                    switch result {
                    case let .success(voices):
                        self.current.voices = voices
                        self.current.status = WhitegramLocalization.string("s.vcConnected")
                    case let .failure(error): self.current.status = error.localizedDescription
                    }
                    self.state.set(self.current)
                }
            }
        } catch {
            self.current.status = error.localizedDescription
            self.state.set(self.current)
        }
    }

    private func cancel() {
        self.generation += 1
        self.task?.cancel()
        self.task = nil
        self.current.loading = false
    }
}

public func whitegramVoiceRemoteSettingsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramVoiceRemoteCoordinator()
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
        |> deliverOnMainQueue
        |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let data = ItemListPresentationData(presentationData)
            var entries: [WhitegramVoiceRemoteEntry] = []
            func add(_ id: String, _ section: Int32, _ content: WhitegramVoiceRemoteEntry.Content) {
                entries.append(WhitegramVoiceRemoteEntry(stableId: id, order: entries.count, section: section, content: content))
            }
            add("proxy", 0, .proxy(state.useProxy))
            add("connectionInfo", 0, .status("Direct ElevenLabs uses your API key. Proxy mode requires an authenticated Whitegram connection. Checking the connection downloads the voice list; converting audio sends it to the selected service."))
            add("key", 1, .key(state.key))
            add("keyInfo", 1, .status("The stored key is kept in Keychain and is never displayed. An empty field keeps the current key."))
            add("voiceId", 1, .voiceId(state.voiceId))
            add("save", 1, .save)
            add("clear", 1, .clear)
            add("load", 2, .load(state.loading))
            if !state.status.isEmpty { add("status", 2, .status(state.status)) }
            for voice in state.voices { add("voice:" + voice.id, 3, .voice(voice, state.voiceId == voice.id)) }
            return (ItemListControllerState(presentationData: data, title: .text(WhitegramLocalization.string("s.vcSelectVoice", baseLanguage: presentationData.strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false), (ItemListNodeState(presentationData: data, entries: entries, style: .blocks, animateChanges: false), coordinator))
        }
    return ItemListController(context: context, state: signal)
}
