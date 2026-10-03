import Foundation
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils

private struct WhitegramPlayerScreenState: Equatable {
    var settings: WhitegramPlayerSettings
    var draft: [String: String] = [:]
    var error: String?
}

private struct WhitegramPlayerEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case info(String)
        case toggle(String, String, Bool)
        case number(String, String, String)
        case preset(WhitegramPlayerEqualizerPreset, Bool)
        case apply
        case reset
    }
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramPlayerEntry, rhs: WhitegramPlayerEntry) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramPlayerCoordinator
        switch self.content {
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .toggle(key, title, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: enabled, sectionId: self.section, style: .blocks, updated: { coordinator.save([key: $0]) })
        case let .number(key, title, text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: title), text: text, placeholder: "0", type: .regular(capitalization: false, autocorrection: false), returnKeyType: .done, alignment: .right, maxLength: 10, selectAllOnFocus: true, sectionId: self.section, textUpdated: { coordinator.edit(key, text: $0) }, action: { coordinator.apply() })
        case let .preset(preset, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: preset.rawValue.capitalized, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { coordinator.preset(preset) })
        case .apply:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Apply Values", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { coordinator.apply() })
        case .reset:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reset Equalizer", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { coordinator.preset(.neutral) })
        }
    }
}

private final class WhitegramPlayerCoordinator {
    let state: ValuePromise<WhitegramPlayerScreenState>
    private var current: WhitegramPlayerScreenState
    private var observer: NSObjectProtocol?

    init() {
        self.current = WhitegramPlayerScreenState(settings: WhitegramPlayerSettings(values: WhitegramPreferences.values()))
        self.state = ValuePromise(self.current, ignoreRepeated: true)
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main, using: { [weak self] _ in
            guard let self else { return }
            self.current.settings = WhitegramPlayerSettings(values: WhitegramPreferences.values())
            self.state.set(self.current)
        })
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
    }

    func edit(_ key: String, text: String) {
        self.current.draft[key] = text
        self.current.error = nil
        self.state.set(self.current)
    }

    func save(_ values: [String: Any]) {
        if WhitegramPreferences.update(values) {
            self.current.error = nil
            self.current.settings = WhitegramPlayerSettings(values: WhitegramPreferences.values())
        } else {
            self.current.error = "Could not save music settings."
        }
        self.state.set(self.current)
    }

    func preset(_ preset: WhitegramPlayerEqualizerPreset) {
        for index in WhitegramPlayerSettings.frequencies.indices {
            self.current.draft.removeValue(forKey: "band:\(index)")
        }
        self.save(["musicEqualizerBands": preset.gains.map(Double.init)])
    }

    func apply() {
        var values: [String: Any] = [:]
        var bands = self.current.settings.bands
        for (key, text) in self.current.draft {
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else {
                self.current.error = "Enter a finite number for every edited value."
                self.state.set(self.current)
                return
            }
            if key == "musicPlaybackSpeed" {
                guard WhitegramPlayerSettings.speedRange.contains(value) else {
                    self.fail("Speed must be between 0.1 and 3.0.")
                    return
                }
                values[key] = value
            } else if key == "musicCrossfadeDuration" {
                guard value >= 0, let seconds = Int(exactly: value) else {
                    self.fail("Crossfade duration must be a nonnegative whole number of seconds.")
                    return
                }
                values[key] = seconds
            } else if key.hasPrefix("band:"), let index = Int(key.dropFirst(5)), bands.indices.contains(index) {
                guard WhitegramPlayerSettings.gainRange.contains(value) else {
                    self.fail("Equalizer gains must be between −12 and +12 dB.")
                    return
                }
                bands[index] = Float(value)
                values["musicEqualizerBands"] = bands.map(Double.init)
            }
        }
        if values.isEmpty { return }
        if WhitegramPreferences.update(values) {
            self.current.draft.removeAll()
            self.current.settings = WhitegramPlayerSettings(values: WhitegramPreferences.values())
            self.current.error = nil
            self.state.set(self.current)
        } else {
            self.fail("Could not save music settings.")
        }
    }

    private func fail(_ message: String) {
        self.current.error = message
        self.state.set(self.current)
    }
}

private func whitegramPlayerEntries(_ state: WhitegramPlayerScreenState, equalizerOnly: Bool) -> [WhitegramPlayerEntry] {
    var entries: [WhitegramPlayerEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramPlayerEntry.Content) {
        entries.append(WhitegramPlayerEntry(stableId: id, order: entries.count, section: section, content: content))
    }
    let settings = state.settings
    if !equalizerOnly {
        add("speed", 0, .number("musicPlaybackSpeed", "Playback Speed", state.draft["musicPlaybackSpeed"] ?? String(format: "%.2f", settings.speed)))
        add("pitch", 0, .toggle("musicPlaybackPitchFollowsSpeed", "Pitch Follows Speed", settings.pitchFollowsSpeed))
        add("crossfade", 1, .toggle("musicCrossfadeEnabled", "Crossfade", settings.crossfadeEnabled))
        add("duration", 1, .number("musicCrossfadeDuration", "Duration (seconds)", state.draft["musicCrossfadeDuration"] ?? String(format: "%.0f", settings.crossfadeDuration)))
        add("transitionInfo", 1, .info("Overlaps the end of a track with the next track. Skips crossfade for repeat-one, shuffle, and tracks shorter than the fade. Pause, seek, and manual navigation end the transition."))
        add("voiceStop", 2, .toggle("stopAfterVoiceMessage", "Stop After Voice Message", settings.stopAfterVoiceMessage))
        add("bass", 2, .toggle("bassEffect", WhitegramLocalization.string("s.bassEffect"), settings.bassEffect))
        add("musicCard", 2, .toggle("wgCustomMusicCard", WhitegramLocalization.string("s.musicCardStyle"), settings.customMusicCard))
    }
    add("equalizer", 3, .toggle("musicEqualizerEnabled", "Equalizer", settings.equalizerEnabled))
    add("equalizerInfo", 3, .info("Ten bands, −12…+12 dB. Edit numeric values and tap Apply Values. Saved gains and presets update playing music immediately when the equalizer is enabled."))
    for index in WhitegramPlayerSettings.frequencies.indices {
        let key = "band:\(index)"
        let frequency = WhitegramPlayerSettings.frequencies[index]
        let title = frequency >= 1000 ? String(format: "%.0f kHz", frequency / 1000) : String(format: "%.0f Hz", frequency)
        add(key, 4, .number(key, title, state.draft[key] ?? String(format: "%+.1f", settings.bands[index])))
    }
    add("apply", 5, .apply)
    if let error = state.error { add("error", 5, .info(error)) }
    for preset in WhitegramPlayerEqualizerPreset.allCases {
        add(preset.rawValue, 6, .preset(preset, settings.bands == preset.gains))
    }
    add("reset", 6, .reset)
    return entries
}

public func whitegramPlayerSettingsController(context: AccountContext, equalizerOnly: Bool = false) -> ViewController {
    let coordinator = WhitegramPlayerCoordinator()
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
        |> deliverOnMainQueue
        |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let data = ItemListPresentationData(presentationData)
            let controller = ItemListControllerState(presentationData: data, title: .text(equalizerOnly ? "Equalizer" : "Music Player"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
            return (controller, (ItemListNodeState(presentationData: data, entries: whitegramPlayerEntries(state, equalizerOnly: equalizerOnly), style: .blocks, animateChanges: false), coordinator))
        }
    return ItemListController(context: context, state: signal)
}

public func whitegramPlayerEqualizerController(context: AccountContext) -> ViewController {
    return whitegramPlayerSettingsController(context: context, equalizerOnly: true)
}
