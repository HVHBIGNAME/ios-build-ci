"""Restore the original presence indicator on chat-history sender avatars."""

from source_patches import SourcePatches

HEADER = "submodules/TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift"
ONLINE_INDICATOR_RUNTIME_FILES = {
    "WhitegramChatOnlineIndicator.swift": "submodules/TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/WhitegramChatOnlineIndicator.swift",
}


def apply_online_indicator_patches(root):
    patches = SourcePatches(root)

    def append(anchor, addition):
        patches.replace("showOnlineDotInChats", HEADER, anchor, anchor + addition)

    append("    public let avatarNode: AvatarNode\n",
           "    private let whitegramOnlineIndicator: WhitegramChatOnlineIndicatorNode\n")
    append("        self.avatarNode.contentNode.displaysAsynchronously = !presentationData.isPreview\n",
           "        self.whitegramOnlineIndicator = WhitegramChatOnlineIndicatorNode(context: context)\n")
    append("        self.containerNode.addSubnode(self.avatarNode)\n",
           "        self.containerNode.addSubnode(self.whitegramOnlineIndicator)\n")
    append("        self.avatarNode.setCustomLetters(letters, icon: !letters.isEmpty ? nil : .phone)\n",
           "        self.whitegramOnlineIndicator.update(peer: nil, theme: theme)\n")
    append("    public func updatePeer(peer: Peer) {\n",
           "        self.whitegramOnlineIndicator.update(peer: peer, theme: self.presentationData.theme.theme)\n")
    append("    public func setPeer(context: AccountContext, theme: PresentationTheme, synchronousLoad: Bool, peer: Peer, authorOfMessage: MessageReference?, emptyColor: UIColor) {\n",
           "        self.whitegramOnlineIndicator.update(peer: peer, theme: theme)\n")
    anchor = "    public func updatePresentationData(_ presentationData: ChatPresentationData, context: AccountContext) {\n        if self.presentationData !== presentationData {\n            self.presentationData = presentationData\n"
    append(anchor, "            self.whitegramOnlineIndicator.updateTheme(presentationData.theme.theme)\n")
    append("        self.avatarNode.updateSize(size: avatarFrame.size)\n",
           "        self.whitegramOnlineIndicator.position = avatarFrame.center\n"
           "        self.whitegramOnlineIndicator.bounds = CGRect(origin: .zero, size: avatarFrame.size)\n")
    append("            self.avatarNode.layer.animateScale(from: 1.0, to: 0.2, duration: duration, removeOnCompletion: false)\n",
           "            self.whitegramOnlineIndicator.layer.animateScale(from: 1.0, to: 0.2, duration: duration, removeOnCompletion: false)\n")
    append("        self.avatarNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.2)\n",
           "        self.whitegramOnlineIndicator.layer.animateScale(from: 0.2, to: 1.0, duration: 0.2)\n")
    append("        transition.updateAlpha(node: self.avatarNode, alpha: isHidden ? 0.0 : 1.0)\n",
           "        transition.updateTransform(node: self.whitegramOnlineIndicator, transform: avatarTransform)\n"
           "        transition.updateAlpha(node: self.whitegramOnlineIndicator, alpha: isHidden ? 0.0 : 1.0)\n")
    return patches.write()
