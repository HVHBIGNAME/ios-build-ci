import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import AccountContext

private func privacyString(_ strings: PresentationStrings, ru: String, en: String) -> String {
    return strings.baseLanguageCode.lowercased().hasPrefix("ru") ? ru : en
}

private func privacyString(_ presentationData: ItemListPresentationData, ru: String, en: String) -> String {
    return privacyString(presentationData.strings, ru: ru, en: en)
}

private final class WhitegramPrivacySettingsArguments {
    let update: ((WhitegramPrivacySettings) -> WhitegramPrivacySettings) -> Void

    init(update: @escaping ((WhitegramPrivacySettings) -> WhitegramPrivacySettings) -> Void) {
        self.update = update
    }
}

private enum WhitegramPrivacySettingsSection: Int32 {
    case ghost
    case privacy
}

private enum WhitegramPrivacySettingsEntry: ItemListNodeEntry {
    case header(WhitegramPrivacySettingsSection, String)
    case ghostMode(WhitegramPrivacySettings)
    case readReceipts(WhitegramPrivacySettings)
    case typingStatus(WhitegramPrivacySettings)
    case onlineStatus(WhitegramPrivacySettings)
    case phoneNumber(WhitegramPrivacySettings)
    case avatarInGroups(WhitegramPrivacySettings)
    case deletedMessages(WhitegramPrivacySettings)
    case antiCensorship(WhitegramPrivacySettings)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _):
            return section.rawValue
        case .ghostMode, .readReceipts, .typingStatus:
            return WhitegramPrivacySettingsSection.ghost.rawValue
        case .onlineStatus, .phoneNumber, .avatarInGroups, .deletedMessages, .antiCensorship:
            return WhitegramPrivacySettingsSection.privacy.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(section, _):
            return section.rawValue * 1000
        case .ghostMode:
            return WhitegramPrivacySettingsSection.ghost.rawValue * 1000 + 1
        case .readReceipts:
            return WhitegramPrivacySettingsSection.ghost.rawValue * 1000 + 2
        case .typingStatus:
            return WhitegramPrivacySettingsSection.ghost.rawValue * 1000 + 3
        case .onlineStatus:
            return WhitegramPrivacySettingsSection.privacy.rawValue * 1000 + 1
        case .phoneNumber:
            return WhitegramPrivacySettingsSection.privacy.rawValue * 1000 + 2
        case .avatarInGroups:
            return WhitegramPrivacySettingsSection.privacy.rawValue * 1000 + 3
        case .deletedMessages:
            return WhitegramPrivacySettingsSection.privacy.rawValue * 1000 + 4
        case .antiCensorship:
            return WhitegramPrivacySettingsSection.privacy.rawValue * 1000 + 5
        }
    }

    static func ==(lhs: WhitegramPrivacySettingsEntry, rhs: WhitegramPrivacySettingsEntry) -> Bool {
        switch lhs {
        case let .header(lhsSection, lhsText):
            if case let .header(rhsSection, rhsText) = rhs {
                return lhsSection == rhsSection && lhsText == rhsText
            }
            return false
        case let .ghostMode(lhsSettings):
            if case let .ghostMode(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .readReceipts(lhsSettings):
            if case let .readReceipts(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .typingStatus(lhsSettings):
            if case let .typingStatus(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .onlineStatus(lhsSettings):
            if case let .onlineStatus(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .phoneNumber(lhsSettings):
            if case let .phoneNumber(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .avatarInGroups(lhsSettings):
            if case let .avatarInGroups(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .deletedMessages(lhsSettings):
            if case let .deletedMessages(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        case let .antiCensorship(lhsSettings):
            if case let .antiCensorship(rhsSettings) = rhs { return lhsSettings == rhsSettings }
            return false
        }
    }

    static func <(lhs: WhitegramPrivacySettingsEntry, rhs: WhitegramPrivacySettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramPrivacySettingsArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .ghostMode(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Ghost Mode", text: "Suppress activity indicators and optional privacy events.", section: self.section) { value in
                arguments.update { $0.ghostModeEnabled = value }
            }
        case let .readReceipts(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Disable Read Receipts", text: "Do not mark outgoing messages as read remotely.", section: self.section) { value in
                arguments.update { $0.disableReadReceipts = value }
            }
        case let .typingStatus(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Disable Typing Status", text: "Hide typing and recording activity.", section: self.section) { value in
                arguments.update { $0.disableTypingStatus = value }
            }
        case let .onlineStatus(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Disable Online Status", text: "Do not publish online state.", section: self.section) { value in
                arguments.update { $0.disableOnlineStatus = value }
            }
        case let .phoneNumber(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Hide Phone Number", text: "Hide phone numbers in supported profile views.", section: self.section) { value in
                arguments.update { $0.hidePhoneNumber = value }
            }
        case let .avatarInGroups(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Hide Avatars In Groups", text: "Reduce identity exposure in group views.", section: self.section) { value in
                arguments.update { $0.hideAvatarInGroups = value }
            }
        case let .deletedMessages(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Save Deleted Messages", text: "Keep a local copy of deleted messages when supported.", section: self.section) { value in
                arguments.update { $0.saveDeletedMessages = value }
            }
        case let .antiCensorship(settings):
            return privacySwitch(presentationData: presentationData, settings: settings, title: "Anti-Censorship Mode", text: "Use conservative fallback behavior for restricted content.", section: self.section) { value in
                arguments.update { $0.antiCensorshipEnabled = value }
            }
        }
    }

    private func privacySwitch(
        presentationData: ItemListPresentationData,
        settings: WhitegramPrivacySettings,
        title: String,
        text: String,
        section: ItemListSectionId,
        update: @escaping (Bool) -> Void
    ) -> ListViewItem {
        return ItemListSwitchItem(
            presentationData: presentationData,
            systemStyle: .glass,
            title: privacyString(presentationData, ru: title, en: title),
            text: privacyString(presentationData, ru: text, en: text),
            value: settings.ghostModeEnabled && title == "Ghost Mode" ? true : (title == "Disable Read Receipts" ? settings.disableReadReceipts : (title == "Disable Typing Status" ? settings.disableTypingStatus : (title == "Disable Online Status" ? settings.disableOnlineStatus : (title == "Hide Phone Number" ? settings.hidePhoneNumber : (title == "Hide Avatars In Groups" ? settings.hideAvatarInGroups : (title == "Save Deleted Messages" ? settings.saveDeletedMessages : settings.antiCensorshipEnabled)))))),
            sectionId: section,
            style: .blocks,
            updated: update
        )
    }
}

private func whitegramPrivacySettingsEntries(settings: WhitegramPrivacySettings) -> [WhitegramPrivacySettingsEntry] {
    return [
        .header(.ghost, "Ghost"),
        .ghostMode(settings),
        .readReceipts(settings),
        .typingStatus(settings),
        .header(.privacy, "Privacy"),
        .onlineStatus(settings),
        .phoneNumber(settings),
        .avatarInGroups(settings),
        .deletedMessages(settings),
        .antiCensorship(settings)
    ]
}

public func whitegramPrivacySettingsController(context: AccountContext) -> ViewController {
    let initialSettings = WhitegramPrivacySettings.current
    let statePromise = ValuePromise(initialSettings, ignoreRepeated: true)
    let stateValue = Atomic(value: initialSettings)
    let arguments = WhitegramPrivacySettingsArguments(update: { transform in
        let updated = stateValue.modify { current in
            let value = transform(current)
            value.save()
            return value
        }
        statePromise.set(updated)
    })
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(privacyString(presentationData.strings, ru: "Приватность", en: "Privacy")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: whitegramPrivacySettingsEntries(settings: settings),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
