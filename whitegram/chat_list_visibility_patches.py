"""Original chat-list title/status visibility and proxy-promotion filtering."""

from source_patches import SourcePatches

CONTROLLER = "submodules/ChatListUI/Sources/ChatListController.swift"
TITLE = "submodules/TelegramUI/Components/ChatListTitleView/Sources/ChatListTitleView.swift"
ENTRIES = "submodules/ChatListUI/Sources/Node/ChatListNodeEntries.swift"
NODE = "submodules/ChatListUI/Sources/Node/ChatListNode.swift"


def apply_chat_list_visibility_patches(root):
    patches = SourcePatches(root)
    # Original component UI 0x16b2a4c..0x16b2acc changes only title text/status.
    anchor = "            self.chatListTitle = titleContent\n"
    patches.replace("chatListTitleVisibility", CONTROLLER, anchor, '''            let whitegramAppearance = WhitegramAppearancePolicy.current
            if whitegramAppearance.isEnabled("hideChatListTitle") { titleContent.text = "" }
            if whitegramAppearance.isEnabled("hideChatListPremiumBadge") || whitegramAppearance.isEnabled("hideChatListPremiumStatus") {
                titleContent.peerStatus = nil
            }
''' + anchor)
    anchor = "                    networkState,\n                    hasProxy,\n"
    patches.replace("chatListTitleVisibility", CONTROLLER, anchor,
                    "                    combineLatest(networkState, WhitegramAppearanceSettings.signal()) |> map { value, _ in value },\n                    hasProxy,\n")
    anchor = "    public func setTitle(_ title: NetworkStatusTitle, animated: Bool) {\n"
    patches.replace("chatListTitleVisibility", TITLE, anchor, anchor + '''        self.whitegramUnfilteredTitle = title
        let appearance = WhitegramAppearancePolicy.current
        self.titleNode.isHidden = appearance.isEnabled("hideChatListTitle")
        var title = title
        if appearance.isEnabled("hideChatListPremiumBadge") || appearance.isEnabled("hideChatListPremiumStatus") {
            title.peerStatus = nil
        }
''')
    anchor = "    private var validLayout: CGSize?\n"
    patches.replace("chatListTitleVisibility", TITLE, anchor, anchor + '''    private var whitegramUnfilteredTitle: NetworkStatusTitle?
    private var whitegramAppearanceObserver: NSObjectProtocol?
''')
    anchor = "        self.proxyButton.addTarget(self, action: #selector(self.proxyButtonPressed), for: .touchUpInside)\n"
    patches.replace("chatListTitleVisibility", TITLE, anchor, anchor + '''        self.whitegramAppearanceObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let title = self.whitegramUnfilteredTitle else { return }
            self.setTitle(title, animated: false)
            self.requestUpdate?(.immediate)
        }
''')
    anchor = "    required public init?(coder aDecoder: NSCoder) {\n"
    patches.replace("chatListTitleVisibility", TITLE, anchor, '''    deinit {
        if let observer = self.whitegramAppearanceObserver { NotificationCenter.default.removeObserver(observer) }
    }

''' + anchor)
    # Original UI 0x180e11c skips proxy entries but retains PSA entries.
    anchor = "    let filteredAdditionalItemEntries = view.additionalItems.filter { item -> Bool in\n"
    patches.replace("hideSponsoredProxyChannel", ENTRIES, anchor, anchor + '''        if WhitegramAppearancePolicy.current.isEnabled("hideSponsoredProxyChannel"), case .proxy = item.promoInfo.content { return false }
''')
    # Rebuild entries on preference changes even if Postbox has no new update.
    anchor = "            self.statePromise.get(),\n"
    patches.replace("hideSponsoredProxyChannel", NODE, anchor,
                    "            combineLatest(self.statePromise.get(), WhitegramAppearanceSettings.signal()) |> map { value, _ in value },\n")
    return patches.write()
