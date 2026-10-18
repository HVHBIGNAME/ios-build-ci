"""Inline 3.1.1 profile metadata, composed against the pinned assembled candidate.

Registration uses Telegram's supplied month, then the authenticated service.
Original persistent date caches and known-user discovery are not implemented.
"""

from source_patches import SourcePatches


PEER = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
ITEMS = PEER + "PeerInfoProfileItems.swift"
SCREEN = PEER + "PeerInfoScreen.swift"
PROFILE_METADATA_RUNTIME_FILES = {
    "WhitegramPeerMetadataPolicy.swift": "submodules/TelegramCore/Sources/WhitegramPeerMetadataPolicy.swift",
    "WhitegramPeerMetadataSettings.swift": "submodules/TelegramCore/Sources/WhitegramPeerMetadataSettings.swift",
    "WhitegramPeerMetadataCardAdapter.swift": "submodules/SettingsUI/Sources/WhitegramPeerMetadataCardAdapter.swift",
    "WhitegramPeerMetadataItems.swift": PEER + "WhitegramPeerMetadataItems.swift",
}


def _replace(patches, path, before, after):
    value = patches.read(path)
    if after in value:
        if value.count(after) != 1 or before in value.replace(after, ""):
            raise ValueError(f"profile-metadata: {path}: mixed or duplicated anchor")
    patches.replace("profile-metadata", path, before, after)


def profile_metadata_patches(patches: SourcePatches) -> None:
    _replace(patches, ITEMS, "    case unofficial\n", "    case unofficial\n    case wgPeerMetadata\n")
    _replace(patches, ITEMS, "    case peerInfoTrailing\n", "    case peerInfoTrailing\n    case wgPeerInfoTrailing\n")
    _replace(patches, ITEMS, "    isMyProfile: Bool\n) -> [(AnyHashable, [PeerInfoScreenItem])] {",
             "    isMyProfile: Bool,\n    whitegramRegistrationDate: WhitegramPeerMetadataDate? = nil\n) -> [(AnyHashable, [PeerInfoScreenItem])] {")
    anchor = "    let bioContextAction: (ASDisplayNode, ContextGesture?, CGPoint?) -> Void = { node, gesture, _ in\n"
    _replace(patches, ITEMS, anchor, """    if case .user = data.peer {
        if let item = whitegramProfileRegistrationItem(date: whitegramRegistrationDate, presentationData: presentationData, interaction: interaction) {
            items[.wgPeerMetadata, default: []].append(item)
        }
        if let item = whitegramProfileMutualContactItem(data: data, presentationData: presentationData, interaction: interaction) {
            items[.wgPeerInfoTrailing, default: []].append(item)
        }
    }

""" + anchor)
    anchor = "    private(set) var data: PeerInfoScreenData?\n"
    _replace(patches, SCREEN, anchor, anchor + "    private var whitegramMetadataCard: WhitegramPeerMetadataCardAdapter?\n    private var whitegramMetadataDisposable: Disposable?\n")
    anchor = "        self.dataDisposable = combineLatest(\n"
    _replace(patches, SCREEN, anchor, """        if !self.isSettings {
            let adapter = WhitegramPeerMetadataCardAdapter(accountUserId: context.account.peerId.id._internalGetInt64Value())
            self.whitegramMetadataCard = adapter
            adapter.updated = { [weak self] in self?.requestLayout(animated: false) }
            self.whitegramMetadataDisposable = (WhitegramPeerMetadataSettings.signal()
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                guard let self, let adapter = self.whitegramMetadataCard else { return }
                whitegramUpdateProfileMetadataCard(adapter, data: self.data)
                self.requestLayout(animated: false)
            })
        }

""" + anchor)
    anchor = "        self.data = data\n"
    _replace(patches, SCREEN, anchor, anchor + "        if let adapter = self.whitegramMetadataCard { whitegramUpdateProfileMetadataCard(adapter, data: data) }\n")
    anchor = "        self.dataDisposable?.dispose()\n"
    _replace(patches, SCREEN, anchor,
             "        self.whitegramMetadataDisposable?.dispose()\n"
             "        if let adapter = self.whitegramMetadataCard { DispatchQueue.main.async { adapter.cancel() } }\n" + anchor)
    anchor = "callMessages: self.callMessages, chatLocation: self.chatLocation, isOpenedFromChat: self.isOpenedFromChat, isMyProfile: self.isMyProfile)"
    _replace(patches, SCREEN, anchor, anchor[:-1] + ", whitegramRegistrationDate: self.whitegramMetadataCard?.date)")


def apply_profile_metadata_patches(root) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    profile_metadata_patches(patches)
    return patches.write()
