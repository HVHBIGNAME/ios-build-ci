import Foundation
import UIKit
import TelegramCore
import TelegramPresentationData

func whitegramInformationItems(data: PeerInfoScreenData, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [PeerInfoScreenItem] {
    guard let peer = data.peer else { return [] }
    let settings = WhitegramAppearancePolicy.current
    let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
    var items: [PeerInfoScreenItem] = []
    func append(_ id: String, label: String, text: String, copyable: Bool = true) {
        items.append(PeerInfoScreenLabeledValueItem(
            id: "whitegram.info." + id, label: label, text: text,
            action: copyable ? { _, _ in UIPasteboard.general.string = text } : nil,
            longTapAction: copyable ? { _ in UIPasteboard.general.string = text } : nil,
            requestLayout: { interaction.requestLayout($0) }
        ))
    }

    if settings.isEnabled("showChatCreationDate") {
        let timestamp: Int32?
        switch peer {
        case let .channel(channel): timestamp = channel.creationDate
        case let .legacyGroup(group): timestamp = group.creationDate
        default: timestamp = nil
        }
        if let timestamp, timestamp > 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: presentationData.strings.baseLanguageCode)
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            append("created", label: WhitegramLocalization.string("profile.created", baseLanguage: presentationData.strings.baseLanguageCode), text: formatter.string(from: Date(timeIntervalSince1970: Double(timestamp))))
        }
    }

    if settings.isEnabled("showPeerIDAndDC") {
        let rawId = String(peer.id.id._internalGetInt64Value())
        let id: String
        if case .channel = peer { id = "-100" + rawId } else { id = rawId }
        append("id", label: "ID", text: id)

        // Photo resources expose the media DC. Telegram does not publish an account DC for every peer.
        var representations: [TelegramMediaImageRepresentation] = []
        if let small = peer.smallProfileImage { representations.append(small) }
        representations.append(contentsOf: peer.profileImageRepresentations)
        if let cached = data.cachedData as? CachedUserData, case let .known(photo) = cached.photo, let photo {
            representations.append(contentsOf: photo.representations)
        }
        let datacenterId = representations.lazy.compactMap { representation -> Int? in
            if let resource = representation.resource as? CloudPeerPhotoSizeMediaResource, resource.datacenterId > 0 { return resource.datacenterId }
            if let resource = representation.resource as? CloudPhotoSizeMediaResource, resource.datacenterId > 0 { return resource.datacenterId }
            return nil
        }.first
        append("dc", label: russian ? "DC фотографии" : "Photo DC", text: datacenterId.map(String.init) ?? "—", copyable: datacenterId != nil)
    }
    return items
}
