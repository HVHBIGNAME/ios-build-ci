import Foundation
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import SettingsUI

func whitegramUpdateProfileMetadataCard(_ adapter: WhitegramPeerMetadataCardAdapter, data: PeerInfoScreenData?) {
    guard let data, case let .user(user) = data.peer else {
        adapter.cancel()
        return
    }
    adapter.update(userId: user.id.id._internalGetInt64Value(),
        telegramMonth: (data.cachedData as? CachedUserData)?.peerStatusSettings?.registrationDate,
        enabled: WhitegramPeerMetadataSettings.current.showRegistrationDateCard)
}

func whitegramProfileRegistrationItem(date: WhitegramPeerMetadataDate?, presentationData: PresentationData, interaction: PeerInfoInteraction) -> PeerInfoScreenItem? {
    guard WhitegramPeerMetadataSettings.current.showRegistrationDateCard, let date else { return nil }
    let text = date.formatted { month, year in
        stringForMonth(strings: presentationData.strings, month: Int32(month - 1), ofYear: Int32(year - 1900))
    }
    return PeerInfoScreenLabeledValueItem(id: "whitegram.metadata.registration", label: WhitegramLocalization.string("profile.registrationDate", baseLanguage: presentationData.strings.baseLanguageCode),
        text: text, action: nil, requestLayout: { interaction.requestLayout($0) })
}

func whitegramProfileMutualContactItem(data: PeerInfoScreenData, presentationData: PresentationData, interaction: PeerInfoInteraction) -> PeerInfoScreenItem? {
    guard WhitegramPeerMetadataSettings.current.showMutualContactsCard,
          case let .user(user) = data.peer, user.flags.contains(.mutualContact) else { return nil }
    return PeerInfoScreenLabeledValueItem(id: "whitegram.metadata.mutualContact", label: WhitegramLocalization.string("profile.inContacts", baseLanguage: presentationData.strings.baseLanguageCode),
        text: "✓", action: nil, requestLayout: { interaction.requestLayout($0) })
}
