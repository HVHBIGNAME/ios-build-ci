import Foundation
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils

private extension WhitegramVoicePreset {
    var title: String {
        switch self {
        case .custom: return "Custom"
        case .echo: return "Echo"
        case .child: return "Child"
        case .adult: return "Adult"
        case .robot: return "Robot"
        case .helium: return "Helium"
        case .monster: return "Monster"
        case .radio: return "Radio"
        case .whisper: return "Whisper"
        case .alien: return "Alien"
        case .cavern: return "Cavern"
        }
    }

    var detail: String {
        switch self {
        case .custom: return "Use the four controls below"
        case .echo: return "Short, decaying repeats"
        case .child: return "Higher and brighter (+6.2 semitones)"
        case .adult: return "Lower and warmer (−3.8 semitones)"
        case .robot: return "Metallic ring modulation"
        case .helium: return "High, bright pitch (+9 semitones)"
        case .monster: return "Deep pitch, distortion and echo"
        case .radio: return "Bright tone, clarity and saturation"
        case .whisper: return "Breathy, envelope-shaped noise"
        case .alien: return "Pitch, ring modulation and echo"
        case .cavern: return "Longer, stronger echo"
        }
    }
}

private struct WhitegramVoiceScreenState: Equatable {
    let settings: WhitegramVoiceSettings
    let error: String?
}

private struct WhitegramVoiceEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case info(String)
        case enabled(Bool)
        case mode(WhitegramVoiceMode, Bool)
        case preset(WhitegramVoicePreset, Bool, Bool)
        case control(WhitegramVoiceControl, Double, Bool)
        case reset
        case bleepEnabled(Bool)
        case selectiveBleep(Bool)
        case bleepMode(WhitegramVoiceBleepMode, Bool)
        case calls(Bool)
        case remoteSettings
        case importFile
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramVoiceEntry, rhs: WhitegramVoiceEntry) -> Bool {
        return lhs.order < rhs.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramVoiceCoordinator
        switch self.content {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .enabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.voiceChangerEnabled"), value: value, sectionId: self.section, style: .blocks, updated: { arguments.setEnabled($0) })
        case let .mode(mode, selected):
            let local = mode == .local
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string(local ? "s.vcModeLocal" : "s.vcModeElevenLabs"), subtitle: local ? "Offline processing before Opus encoding" : "Convert with the selected ElevenLabs voice before sending", style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.selectMode(mode) })
        case let .preset(preset, selected, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: preset.title, subtitle: preset.detail, style: .right, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.selectPreset(preset) })
        case let .control(control, value, enabled):
            return WhitegramVoiceSliderItem(presentationData: presentationData, control: control, value: value, enabled: enabled, sectionId: self.section, updated: { arguments.setControl(control, value: $0) })
        case .reset:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reset Custom Controls", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.resetCustom() })
        case let .bleepEnabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Replace Entire Voice Message", text: "Replaces ALL microphone audio with a beep or silence", value: value, sectionId: self.section, style: .blocks, updated: { arguments.setBleepEnabled($0) })
        case let .selectiveBleep(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.voiceBleep"), value: value, sectionId: self.section, style: .blocks, updated: { arguments.setSelectiveBleep($0) })
        case let .bleepMode(mode, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: mode == .beep ? "Beep (1 kHz)" : "Silence", style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.setBleepMode(mode) })
        case let .calls(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.vcInCalls"), text: "Local presets only; outgoing shared-device call audio", value: value, sectionId: self.section, style: .blocks, updated: { arguments.setCalls($0) })
        case .remoteSettings:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.vcSelectVoice"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.openRemote() })
        case .importFile:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Convert Audio / Video File", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.openFile() })
        }
    }
}

private func whitegramVoiceEntries(_ state: WhitegramVoiceScreenState) -> [WhitegramVoiceEntry] {
    let settings = state.settings
    var entries: [WhitegramVoiceEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramVoiceEntry.Content) {
        entries.append(WhitegramVoiceEntry(stableId: id, order: entries.count, section: section, content: content))
    }

    add("enabled", 0, .enabled(settings.enabled))
    let status: String
    if settings.activeBleepMode != nil {
        status = "Whole-message replacement is active. New recordings contain only the selected beep or silence."
    } else if settings.hasLocalEffect {
        status = "Local \(settings.preset?.title ?? "Custom") effects apply to newly recorded voice messages."
    } else if settings.localEnabled {
        status = "The custom controls are neutral. Audio is unchanged until a control or preset is selected."
    } else if settings.enabled && settings.mode == .remote {
        status = "ElevenLabs conversion is requested before sending. Select a voice and configure the connection below. A failed conversion keeps the recording as a draft."
    } else {
        status = "Local voice effects are off."
    }
    add("status", 0, .info(status))
    add("recordingInfo", 0, .info("Local effects are captured when a recorder is created. Word bleeping and ElevenLabs run when sending, after trimming. Paused drafts keep their original resumable audio."))
    if let error = state.error { add("error", 0, .info(error)) }
    if settings.mode == nil || settings.preset == nil || settings.bleepMode == nil {
        add("invalidSelection", 0, .info("A saved mode or preset is unrecognized and inactive. Choose a supported option below."))
    }

    add("modeHeader", 1, .header("PROCESSING MODE"))
    add("localMode", 1, .mode(.local, settings.mode == .local))
    add("remoteMode", 1, .mode(.remote, settings.mode == .remote))
    add("remoteSettings", 1, .remoteSettings)
    add("importFile", 1, .importFile)

    add("presetHeader", 2, .header("LOCAL PRESET"))
    for preset in WhitegramVoicePreset.allCases {
        add("preset:\(preset.rawValue)", 2, .preset(preset, settings.preset == preset, settings.mode == .local))
    }

    add("customHeader", 3, .header("CUSTOM CONTROLS"))
    for control in WhitegramVoiceControl.allCases {
        add(control.key, 3, .control(control, settings.value(for: control), settings.mode == .local && settings.preset == .custom))
    }
    add("customInfo", 3, .info("Choose Custom to edit. Pitch, timbre, clarity, modulation and echo use the recovered original parameter policy. Pitch has up to 76 ms delay at 48 kHz. Duration stays unchanged; effect tails stop with the recording."))
    add("reset", 3, .reset)

    add("bleepHeader", 4, .header(WhitegramLocalization.string("s.voiceBleepMode")))
    add("selectiveBleep", 4, .selectiveBleep(settings.bleepEnabled && !settings.bleepWholeRecording))
    add("bleepEnabled", 4, .bleepEnabled(settings.activeBleepMode != nil))
    for mode in WhitegramVoiceBleepMode.allCases {
        add("bleepMode:\(mode.rawValue)", 4, .bleepMode(mode, settings.bleepMode == mode))
    }
    add("bleepInfo", 4, .info(WhitegramLocalization.string("s.voiceBleep.desc") + " Apple Speech uses on-device recognition when available; otherwise it may send audio to Apple. Whole-message replacement is a separate opt-in."))

    add("callsHeader", 5, .header("CALLS"))
    add("calls", 5, .calls(settings.callsRequested))
    if settings.callsRequested && !settings.localEnabled {
        add("savedCalls", 5, .info("Enable Local Presets to process outgoing call audio. ElevenLabs and word bleeping are message/file operations."))
    }
    return entries
}

private final class WhitegramVoiceCoordinator {
    let state: ValuePromise<WhitegramVoiceScreenState>
    private var observer: NSObjectProtocol?
    private var error: String?
    var openRemote: () -> Void = {}
    var openFile: () -> Void = {}

    init() {
        self.state = ValuePromise(WhitegramVoiceScreenState(settings: WhitegramVoiceSettings(values: WhitegramPreferences.values()), error: nil), ignoreRepeated: true)
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.refresh()
        })
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        self.state.set(WhitegramVoiceScreenState(settings: WhitegramVoiceSettings(values: WhitegramPreferences.values()), error: self.error))
    }

    private func save(_ changes: [String: Any]) {
        self.error = nil
        if !WhitegramPreferences.update(changes) {
            self.error = "Could not save voice settings. Please try again."
        }
        self.refresh()
    }

    func setEnabled(_ enabled: Bool) {
        var changes: [String: Any] = ["voiceChangerEnabled": enabled]
        if enabled {
            if WhitegramVoiceSettings(values: WhitegramPreferences.values()).mode == nil {
                changes["voiceChangerMode"] = WhitegramVoiceMode.local.rawValue
            }
            if WhitegramVoiceSettings(values: WhitegramPreferences.values()).preset == nil {
                changes["voiceChangerPreset"] = WhitegramVoicePreset.custom.rawValue
            }
        }
        self.save(changes)
    }

    func selectMode(_ mode: WhitegramVoiceMode) {
        self.save(["voiceChangerMode": mode.rawValue])
    }

    func selectPreset(_ preset: WhitegramVoicePreset) {
        self.save(["voiceChangerMode": WhitegramVoiceMode.local.rawValue, "voiceChangerPreset": preset.rawValue])
    }

    func setControl(_ control: WhitegramVoiceControl, value: Double) {
        let settings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
        guard value.isFinite, settings.mode == .local, settings.preset == .custom else { return }
        self.save([control.key: control.quantized(value)])
    }

    func resetCustom() {
        var changes: [String: Any] = ["voiceChangerMode": WhitegramVoiceMode.local.rawValue, "voiceChangerPreset": WhitegramVoicePreset.custom.rawValue]
        for control in WhitegramVoiceControl.allCases { changes[control.key] = 0.0 }
        self.save(changes)
    }

    func setBleepEnabled(_ enabled: Bool) {
        var changes: [String: Any] = ["voiceBleepEnabled": enabled, WhitegramVoiceSettings.wholeRecordingBleepKey: enabled]
        if enabled && WhitegramVoiceSettings(values: WhitegramPreferences.values()).bleepMode == nil {
            changes["voiceBleepMode"] = WhitegramVoiceBleepMode.beep.rawValue
        }
        self.save(changes)
    }

    func setBleepMode(_ mode: WhitegramVoiceBleepMode) {
        self.save(["voiceBleepMode": mode.rawValue])
    }

    func setSelectiveBleep(_ enabled: Bool) {
        self.save(["voiceBleepEnabled": enabled, WhitegramVoiceSettings.wholeRecordingBleepKey: false])
    }

    func setCalls(_ enabled: Bool) { self.save(["voiceChangerInCalls": enabled]) }
}

/// SettingsUI entrypoint; creating this screen does not access the microphone.
public func whitegramVoiceSettingsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramVoiceCoordinator()
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
        |> deliverOnMainQueue
        |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let data = ItemListPresentationData(presentationData)
            let controllerState = ItemListControllerState(presentationData: data, title: .text("Voice Effects"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
            let listState = ItemListNodeState(presentationData: data, entries: whitegramVoiceEntries(state), style: .blocks, animateChanges: false)
            return (controllerState, (listState, coordinator))
        }
    let controller = ItemListController(context: context, state: signal)
    coordinator.openRemote = { [weak controller] in
        (controller?.navigationController as? NavigationController)?.pushViewController(whitegramVoiceRemoteSettingsController(context: context))
    }
    coordinator.openFile = { [weak controller] in
        (controller?.navigationController as? NavigationController)?.pushViewController(WhitegramVoiceFileController(context: context))
    }
    controller.didAppear = { [coordinator] _ in coordinator.refresh() }
    return controller
}
