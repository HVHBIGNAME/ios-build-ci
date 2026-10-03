"""Local presentation settings mapped to their actual Telegram rendering paths."""

from pathlib import Path

from source_patches import SourcePatches


def apply_interface_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    avatar = "submodules/AvatarNode/Sources/AvatarNode.swift"
    clip = '            var clipStyle = clipStyle\n            if case .round = clipStyle, WhitegramPreferences.bool("squareAvatars") {\n                clipStyle = .roundedRect\n            }\n'
    patches.replace("squareAvatars", avatar, "            var synchronousLoad = synchronousLoad\n", clip + "            var synchronousLoad = synchronousLoad\n", count=2)
    patches.replace("squareAvatars", avatar, "            let smallProfileImage = peer?.smallProfileImage\n", clip + "            let smallProfileImage = peer?.smallProfileImage\n")

    settings = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift"
    anchor = "    var result: [(AnyHashable, [PeerInfoScreenItem])] = []\n    for section in SettingsSection.allCases {"
    before_result = '''    let whitegramHiddenRows: [SettingsSection: [Int: String]] = [
        .edit: [0: "hideSettingsEmojiStatus", 1: "hideSettingsProfileColor", 2: "hideSettingsSetPhoto"],
        .accounts: [100: "hideSettingsAddAccount"],
        .myProfile: [0: "hideMyProfile"],
        .proxy: [0: "hideProxy"],
        .advanced: [0: "hideNotifications", 1: "hidePrivacy", 2: "hideDataAndStorage", 3: "hideAppearance", 4: "hideLanguage", 6: "hideEnergySaving"]
    ]
    for (section, rows) in whitegramHiddenRows {
        items[section] = items[section]?.filter { item in
            guard let id = item.id.base as? Int, let key = rows[id] else { return true }
            return !WhitegramPreferences.bool(key)
        }
    }

'''
    patches.replace("settings-row-visibility", settings, anchor, before_result + anchor)
    phone = "    if case let .user(user) = data.peer {\n        items[.info]!.append(PeerInfoScreenDisclosureItem(id: ItemPhoneNumber,"
    patches.replace("hidePhoneNumber", settings, phone,
        phone.replace("if case let", 'if !WhitegramPreferences.bool("hidePhoneNumber"), case let'))

    dates = "submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift"
    anchor = "compactNumericCountString(impressionCount, decimalSeparator: arguments.presentationData.dateTimeFormat.decimalSeparator)"
    patches.replace("showFullViewCount", dates, anchor,
        '(WhitegramPreferences.bool("showFullViewCount") ? String(impressionCount) : ' + anchor + ')')

    ads = "submodules/TelegramCore/Sources/TelegramEngine/Messages/AdMessages.swift"
    guard = 'WhitegramPreferences.bool("disableAds") || WhitegramPreferences.bool("hideChannelAds")'
    upgraded_guard = guard.replace('WhitegramPreferences.bool("disableAds")', 'WhitegramContentSettings.bool("disableAds")')
    anchor = "\n        self.stateValue = State(interPostInterval: nil, messages: [])\n"
    replacement = anchor + f"        if {guard} {{\n            self.state.set(.single(State(interPostInterval: nil, messages: [])))\n            return\n        }}\n"
    patches.replace("hideChannelAds", ads, anchor, replacement,
        accepted_after=(replacement.replace(guard, upgraded_guard),))
    anchor = "    func activate() {\n"
    body = f"        if {guard} {{\n            self.disposable.set(nil)\n            self.state.set(.single(State(interPostInterval: nil, messages: [])))\n            return\n        }}\n"
    patches.replace("hideChannelAds", ads, anchor, anchor + body,
        accepted_after=(anchor + "        self.whitegramActivationRequested = true\n" + body.replace(guard, upgraded_guard),))
    search_ads = "submodules/TelegramCore/Sources/TelegramEngine/Peers/AdPeers.swift"
    anchor = "func _internal_searchAdPeers(account: Account, query: String) -> Signal<[AdPeer], NoError> {\n"
    patches.replace("disableAds", search_ads, anchor, anchor + '    if WhitegramPreferences.bool("disableAds") { return .single([]) }\n',
        accepted_after=(anchor + '    if WhitegramContentSettings.bool("disableAds") { return .single([]) }\n',))
    return patches.write()
