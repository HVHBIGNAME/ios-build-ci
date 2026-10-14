"""Profile-only display preferences without changing Telegram peer/account state."""

from appearance_parity_patches import replace
from source_patches import SourcePatches

PROFILE_APPEARANCE_RUNTIME_FILES = {
    "WhitegramVisualUsername.swift": "submodules/TelegramCore/Sources/WhitegramVisualUsername.swift",
    "WhitegramVisualUsernameController.swift": "submodules/SettingsUI/Sources/WhitegramVisualUsernameController.swift",
}
PEER = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
DATA = PEER + "PeerInfoData.swift"
PANES = PEER + "PeerInfoPaneContainerNode.swift"
ITEMS = PEER + "PeerInfoProfileItems.swift"
HEADER = PEER + "PeerInfoHeaderNode.swift"


def apply_profile_appearance_patches(root):
    patches = SourcePatches(root)
    replace(patches, "hideGifts", DATA, "    let availablePanes: [PeerInfoPaneKey]\n", """    private let whitegramOriginalPanes: [PeerInfoPaneKey]
    var availablePanes: [PeerInfoPaneKey] {
        guard WhitegramAppearancePolicy.current.isEnabled("hideGifts") else { return self.whitegramOriginalPanes }
        return self.whitegramOriginalPanes.filter { $0 != .gifts }
    }
""")
    replace(patches, "hideGifts", DATA, "        self.availablePanes = availablePanes\n", "        self.whitegramOriginalPanes = availablePanes\n")
    before = "        let currentIndex: Int?\n"
    replace(patches, "hideGifts", PANES, before, """        if self.pendingSwitchToPaneKey == .gifts && !availablePanes.contains(.gifts) && WhitegramAppearancePolicy.current.isEnabled("hideGifts") {
            self.pendingSwitchToPaneKey = availablePanes.first
        }

""" + before)
    # Keep real username/QR/context actions bound to the actual account.
    before = "        if let mainUsername = user.addressName {\n"
    replace(patches, "visualUsername", ITEMS, before,
            "        if let mainUsername = WhitegramVisualUsername.display(actual: user.addressName, isOwnProfile: user.id == context.account.peerId) {\n")
    replace(patches, "visualUsername", ITEMS,
            "            let usernames = user.usernames.filter { $0.isActive && $0.username != mainUsername }\n",
            "            let usernames = user.usernames.filter { $0.isActive && $0.username != mainUsername && mainUsername == user.addressName }\n")
    before = '''                    text: "@\\(mainUsername)",
                    additionalText: additionalUsernames,
                    textColor: .accent,
                    icon: .qrCode,
                    action: { _, progress in
                        interaction.openUsername(mainUsername, true, progress)
'''
    replace(patches, "visualUsername", ITEMS, before,
            before.replace("interaction.openUsername(mainUsername, true, progress)", "if let actualUsername = user.addressName { interaction.openUsername(actualUsername, true, progress) }"))
    replace(patches, "visualUsername", HEADER,
            "                if let mainUsername = user.addressName, !mainUsername.isEmpty {\n",
            "                if let mainUsername = WhitegramVisualUsername.display(actual: user.addressName, isOwnProfile: user.id == self.context.account.peerId), !mainUsername.isEmpty {\n")
    return patches.write()
