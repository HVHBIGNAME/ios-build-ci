"""Opt-in contact-list filtering; search and recipient selectors keep their peers."""

from appearance_parity_patches import replace
from source_patches import SourcePatches


CONTACTS = "submodules/ContactListUI/Sources/ContactListNode.swift"
CONTROLLER = "submodules/ContactListUI/Sources/ContactsControllerNode.swift"


def apply_contact_visibility_patches(root):
    patches = SourcePatches(root)
    replace(patches, "hideCryptoBot", CONTACTS,
            "        isGroupInvitation: Bool,\n",
            "        isGroupInvitation: Bool,\n        whitegramContactsVisibility: Bool = false,\n")
    before = """                return (
                    combineLatest(
                        self.contactPeersViewPromise.get(),
"""
    after = """                let whitegramContactVisibility: Signal<Bool, NoError>
                if whitegramContactsVisibility {
                    whitegramContactVisibility = WhitegramAppearanceSettings.signal()
                    |> map { $0.policy.isEnabled("hideCryptoBot") }
                    |> distinctUntilChanged
                } else {
                    whitegramContactVisibility = .single(false)
                }

                return (
                    combineLatest(
                        combineLatest(self.contactPeersViewPromise.get(), whitegramContactVisibility),
"""
    replace(patches, "hideCryptoBot", CONTACTS, before, after)
    replace(patches, "hideCryptoBot", CONTACTS,
            "                    |> mapToQueue {\n                        view,\n                        chatListPeers,\n",
            "                    |> mapToQueue {\n                        whitegramContactView,\n                        chatListPeers,\n")
    replace(patches, "hideCryptoBot", CONTACTS,
            """                        topPeers -> Signal<ContactsListNodeTransition, NoError> in
                        let signal = deferred { () -> Signal<ContactsListNodeTransition, NoError> in
""",
            """                        topPeers -> Signal<ContactsListNodeTransition, NoError> in
                        let (view, whitegramHideCryptoBot) = whitegramContactView
                        let signal = deferred { () -> Signal<ContactsListNodeTransition, NoError> in
""")
    replace(patches, "hideCryptoBot", CONTACTS,
            "                            var peers = view.0.peers.map({ ContactListPeer.peer(peer: $0, isGlobal: false, participantCount: nil) })\n",
            """                            let whitegramVisiblePeers = view.0.peers.filter { peer in
                                guard whitegramHideCryptoBot, case let .user(user) = peer else { return true }
                                let usernames = user.usernames.filter { $0.isActive }.map { $0.username } + [user.username].compactMap { $0 }
                                return !WhitegramAppearancePolicy.hidesCryptoBotContact(enabled: whitegramHideCryptoBot, isBot: user.botInfo != nil, usernames: usernames)
                            }
                            var peers = whitegramVisiblePeers.map({ ContactListPeer.peer(peer: $0, isGlobal: false, participantCount: nil) })
""")
    replace(patches, "hideCryptoBot", CONTROLLER,
            "presentation: presentation, onlyWriteable: false, isGroupInvitation: false, displaySortOptions: true,",
            "presentation: presentation, onlyWriteable: false, isGroupInvitation: false, whitegramContactsVisibility: true, displaySortOptions: true,")
    return patches.write()
