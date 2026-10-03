"""Original 3.1.1 appearance semantics on the assembled 12.9.2 public overlay."""

from pathlib import Path

from source_patches import SourcePatches


APPEARANCE_PARITY_RUNTIME_FILES = {
    "WhitegramAppearancePolicy.swift": "submodules/TelegramCore/Sources/Settings/WhitegramAppearancePolicy.swift",
    "WhitegramInformation.swift": "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/WhitegramInformation.swift",
    "WhitegramLocalStars.swift": "submodules/TelegramCore/Sources/Settings/WhitegramLocalStars.swift",
    "WhitegramAppearanceControlsController.swift": "submodules/SettingsUI/Sources/WhitegramAppearanceControlsController.swift",
    "WhitegramAppearanceSliderItem.swift": "submodules/SettingsUI/Sources/WhitegramAppearanceSliderItem.swift",
}

CHAT = "submodules/TelegramUI/Components/Chat/"
STICKER = CHAT + "ChatMessageStickerItemNode/Sources/ChatMessageStickerItemNode.swift"
ANIMATED = CHAT + "ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift"
STATUS = CHAT + "ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift"
BUBBLE = CHAT + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift"
PEER = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
TABS = "submodules/TabBarUI/Sources/TabBarContollerNode.swift"
TAB_CONTROLLER = "submodules/TabBarUI/Sources/TabBarController.swift"
TAB_COMPONENT = "submodules/TelegramUI/Components/TabBarComponent/Sources/TabBarComponent.swift"
LIST = "submodules/ChatListUI/Sources/ChatListController.swift"
STARS = "submodules/TelegramUI/Components/Stars/"


def replace(patches, feature, path, before, after, count=1):
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != count or before in value.replace(after, "")):
        raise ValueError(f"{feature}: {path}: ambiguous partially applied appearance patch")
    patches.replace(feature, path, before, after, count=count)


def _sticker_patches(patches):
    before = "CGFloat(WhiteGramChatSettings.current.stickerSizePercent) / 100.0"
    for path, count in ((STICKER, 1), (ANIMATED, 2)):
        replace(patches, "stickerSizeScale", path, before,
                "CGFloat(WhitegramAppearancePolicy.current.stickerScale)", count=count)
    for path, count in ((STICKER, 1), (ANIMATED, 2)):
        replace(patches, "stickerSizeScale", path,
                "WhiteGramChatSettings.current.stickerSizePercent == 0",
                "WhitegramAppearancePolicy.current.stickerScale == 0.0", count=count)
    replace(patches, "stickerSizeScale", ANIMATED,
            "private var appliedWhiteGramStickerSizePercent = WhiteGramChatSettings.current.stickerSizePercent",
            "private var appliedWhiteGramStickerSizePercent = WhitegramAppearancePolicy.current.stickerScale")
    replace(patches, "stickerSizeScale", ANIMATED,
            "let currentStickerSizePercent = WhiteGramChatSettings.current.stickerSizePercent",
            "let currentStickerSizePercent = WhitegramAppearancePolicy.current.stickerScale")


def _reaction_patches(patches):
    before = "public func whiteGramShouldHideChannelPostReactions(message: Message) -> Bool {\n"
    replace(patches, "hideReactions", STATUS, before, before + "    if WhitegramAppearancePolicy.current.isEnabled(\"hideReactions\") { return true }\n")
    before = "    if let channel = firstMessage.peers[firstMessage.id.peerId] as? TelegramChannel, case .broadcast = channel.info, !WhiteGramChatSettings.current.channelPostReactions {\n"
    after = "    if whiteGramShouldHideChannelPostReactions(message: firstMessage) {\n"
    replace(patches, "hideReactions", BUBBLE, before, after)
    before = "            if let channel = item.message.peers[item.message.id.peerId] as? TelegramChannel, case .broadcast = channel.info, !WhiteGramChatSettings.current.channelPostReactions {\n"
    after = "            if whiteGramShouldHideChannelPostReactions(message: item.message) {\n"
    for path in (STICKER, ANIMATED):
        replace(patches, "hideReactions", path, before, after)


def _information_patches(patches):
    path = PEER + "PeerInfoProfileItems.swift"
    before = "    var result: [(AnyHashable, [PeerInfoScreenItem])] = []\n    for section in InfoSection.allCases {"
    after = "    items[.peerInfoTrailing, default: []].append(contentsOf: whitegramInformationItems(data: data, presentationData: presentationData, interaction: interaction))\n\n" + before
    replace(patches, "peer-information", path, before, after)
    before = "        if let phone = user.phone {\n"
    replace(patches, "hidePhoneNumber-profile", path, before,
            '        if !WhitegramAppearancePolicy.current.isEnabled("hidePhoneNumber"), let phone = user.phone {\n')
    path = PEER + "PeerInfoScreen.swift"
    before = "            screenData,\n            self.forceIsContactPromise.get(),"
    after = "            combineLatest(screenData, WhitegramAppearanceSettings.signal()) |> map { data, _ in data },\n            self.forceIsContactPromise.get(),"
    replace(patches, "appearance-profile-refresh", path, before, after)
    path = PEER + "PeerInfoHeaderNode.swift"
    before = "        if let starRating = self.currentStarRating {\n"
    after = "        if !WhitegramAppearancePolicy.current.isEnabled(\"hideAccountRating\"), let starRating = self.currentStarRating {\n"
    replace(patches, "hideAccountRating", path, before, after)
    before = "                if case let .user(user) = peer, let phone = user.phone {\n"
    after = '                if !(WhitegramAppearancePolicy.current.isEnabled("hidePhoneNumber") && (self.isSettings || self.isMyProfile)), case let .user(user) = peer, let phone = user.phone {\n'
    replace(patches, "hidePhoneNumber-profile", path, before, after)
    before = '                var subtitle = formatPhoneNumber(context: self.context, number: user.phone ?? "")\n'
    after = '                var subtitle = WhitegramAppearancePolicy.current.isEnabled("hidePhoneNumber") ? "" : formatPhoneNumber(context: self.context, number: user.phone ?? "")\n'
    replace(patches, "hidePhoneNumber-profile", path, before, after)
    before = '                    subtitle = "\\(subtitle) • @\\(mainUsername)"\n'
    after = '                    subtitle = subtitle.isEmpty ? "@\\(mainUsername)" : "\\(subtitle) • @\\(mainUsername)"\n'
    replace(patches, "hidePhoneNumber-profile", path, before, after)
    before = "    @objc private func handlePhoneLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {\n"
    replace(patches, "hidePhoneNumber-profile", path, before, before + '        if WhitegramAppearancePolicy.current.isEnabled("hidePhoneNumber") && (self.isSettings || self.isMyProfile) { return }\n')
    path = PEER + "PeerInfoSettingsItems.swift"
    before = '            if bot.shortName.lowercased() == "wallet" {\n'
    replace(patches, "hideWallet", path, before,
            '            if bot.shortName.lowercased() == "wallet" && WhitegramAppearancePolicy.current.isEnabled("hideWallet") {\n')


def _tab_size_patches(patches):
    replace(patches, "tabBarWidthScale", TABS, "import TelegramPresentationData\n", "import TelegramPresentationData\nimport TelegramCore\n")
    before = "    private var isUpdateRequested: Bool = false\n"
    replace(patches, "tabBarWidthScale", TABS, before, before + "    private var whitegramAppearanceObserver: NSObjectProtocol?\n    var whitegramAppearanceUpdated: (() -> Void)?\n")
    before = "        //self.addSubnode(self.disabledOverlayNode)\n    }\n"
    after = before[:-6] + """        self.whitegramAppearanceObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.layoutResult = nil
            self.whitegramAppearanceUpdated?()
        }
    }

    deinit {
        if let observer = self.whitegramAppearanceObserver { NotificationCenter.default.removeObserver(observer) }
    }
"""
    replace(patches, "tabBarWidthScale", TABS, before, after)
    before = "        self.displayNodeDidLoad()\n"
    replace(patches, "tabBarScale", TAB_CONTROLLER, before, """        self.tabBarControllerNode.whitegramAppearanceUpdated = { [weak self] in
            self?.updateLayout(transition: .immediate)
        }
""" + before)

    before = "                hideItemTitles: whiteGramTabSettings.hideTabTitles || whiteGramTabSettings.compactPanel,\n"
    replace(patches, "tabBarScale", TABS, before,
            "                heightScale: CGFloat(WhitegramAppearancePolicy.current.tabHeightPercent / 100.0),\n" + before)
    for before, after in (
        ("    public let hideItemTitles: Bool\n", "    public let heightScale: CGFloat\n    public let hideItemTitles: Bool\n"),
        ("        hideItemTitles: Bool = false,\n", "        heightScale: CGFloat = 1.0,\n        hideItemTitles: Bool = false,\n"),
        ("        self.hideItemTitles = hideItemTitles\n", "        self.heightScale = heightScale.isFinite ? min(1.5, max(0.5, heightScale)) : 1.0\n        self.hideItemTitles = hideItemTitles\n"),
        ("        if lhs.hideItemTitles != rhs.hideItemTitles {\n", "        if lhs.heightScale != rhs.heightScale { return false }\n        if lhs.hideItemTitles != rhs.hideItemTitles {\n"),
        ("            let itemHeight: CGFloat = component.hideItemTitles ? 44.0 : 56.0\n            let barHeight: CGFloat = itemHeight + innerInset * 2.0\n",
         "            let baseItemHeight: CGFloat = component.hideItemTitles ? 44.0 : 56.0\n            let itemHeight = baseItemHeight * component.heightScale\n            let barHeight = (baseItemHeight + innerInset * 2.0) * component.heightScale\n"),
    ):
        replace(patches, "tabBarScale", TAB_COMPONENT, before, after)
    before = "            containerSize: CGSize(width: params.layout.size.width - sideInset * 2.0, height: 100.0)\n"
    after = "            containerSize: CGSize(width: (params.layout.size.width - sideInset * 2.0) * CGFloat(WhitegramAppearancePolicy.current.tabWidthPercent / 100.0), height: 100.0)\n"
    replace(patches, "tabBarWidthScale", TABS, before, after)


def _folder_patches(patches):
    before = "            filterItems,\n            self.context.account.postbox.peerView(id: self.context.account.peerId),"
    after = "            combineLatest(filterItems, WhitegramAppearanceSettings.signal()) |> map { items, _ in items },\n            self.context.account.postbox.peerView(id: self.context.account.peerId),"
    replace(patches, "hideAllChatsTab", LIST, before, after)
    before = "            let (_, items) = countAndFilterItems\n            var filterItems: [ChatListFilterTabEntry] = []\n"
    after = """            let (_, allItems) = countAndFilterItems
            let hideAllChats = WhitegramAppearancePolicy.current.isEnabled("hideAllChatsTab") && allItems.count > 1
            let items = allItems.filter { item in
                if case .allChats = item.0 { return !hideAllChats }
                return true
            }
            var filterItems: [ChatListFilterTabEntry] = []
"""
    replace(patches, "hideAllChatsTab", LIST, before, after)
    replace(patches, "hideAllChatsTab", LIST,
            "            let firstItem = countAndFilterItems.1.first?.0 ?? .allChats\n",
            "            let firstItem = items.first?.0 ?? .allChats\n")
    replace(patches, "hideAllChatsTab", LIST,
            "            if !hasAllChats {\n                availableFilters.insert(.all, at: 0)\n",
            "            if !hasAllChats && !hideAllChats {\n                availableFilters.insert(.all, at: 0)\n")
    before = "            let filtersLimit = isPremium == false ? limits.maxFoldersCount : nil\n"
    replace(patches, "hideAllChatsTab", LIST, before, """            if hideAllChats, selectedEntryId == .all, let first = resolvedItems.first {
                selectedEntryId = first.id
                resetCurrentEntry = true
            }
""" + before)


def _local_stars_patches(patches):
    # Only the arguments to text formatters change. StarsContext, totals, eligibility,
    # transaction history, payment requests and TON are deliberately never overridden.
    targets = (
        (PEER + "PeerInfoSettingsItems.swift", "starsState.balance", "presentationData", 1),
        (STARS + "StarsTransactionsScreen/Sources/StarsTransactionsScreen.swift", "self.starsState?.balance ?? StarsAmount.zero", "environment", 1),
        (STARS + "StarsPurchaseScreen/Sources/StarsPurchaseScreen.swift", "state.starsState?.balance ?? StarsAmount.zero", "environment", 1),
        (STARS + "StarsTransferScreen/Sources/StarsTransferScreen.swift", "state.balance ?? StarsAmount.zero", "environment", 1),
    )
    for path, value, data, count in targets:
        before = f"formatStarsAmountText({value}, dateTimeFormat: {data}.dateTimeFormat)"
        after = f"formatStarsAmountText(WhitegramLocalStars.current.displayBalance({value}), dateTimeFormat: {data}.dateTimeFormat)"
        replace(patches, "localStars-display-only", path, before, after, count=count)

    path = STARS + "StarsBalanceOverlayComponent/Sources/StarsBalanceOverlayComponent.swift"
    before = "            let balance = presentationStringsFormattedNumber(Int32(self.starsBalance), presentationData.dateTimeFormat.groupingSeparator)\n"
    after = """            let actualBalance = StarsAmount(value: self.starsBalance, nanos: 0)
            let displayBalance = component.peerId == component.context.account.peerId ? WhitegramLocalStars.current.displayBalance(actualBalance) : actualBalance
            let balance = formatStarsAmountText(displayBalance, dateTimeFormat: presentationData.dateTimeFormat)
"""
    replace(patches, "localStars-display-only", path, before, after)

    # Re-emit real state when only the local presentation preference changes.
    for path, before, after in (
        (STARS + "StarsTransactionsScreen/Sources/StarsTransactionsScreen.swift",
         "                self.stateDisposable = (component.starsContext.state\n",
         "                self.stateDisposable = (combineLatest(component.starsContext.state, WhitegramAppearanceSettings.signal()) |> map { state, _ in state }\n"),
        (STARS + "StarsPurchaseScreen/Sources/StarsPurchaseScreen.swift",
         "                starsContext.state,\n",
         "                combineLatest(starsContext.state, WhitegramAppearanceSettings.signal()) |> map { state, _ in state },\n"),
        (STARS + "StarsTransferScreen/Sources/StarsTransferScreen.swift",
         "            self.stateDisposable = (starsContext.state\n",
         "            self.stateDisposable = (combineLatest(starsContext.state, WhitegramAppearanceSettings.signal()) |> map { state, _ in state }\n"),
        (STARS + "StarsBalanceOverlayComponent/Sources/StarsBalanceOverlayComponent.swift",
         "                            starsContext.state,\n",
         "                            combineLatest(starsContext.state, WhitegramAppearanceSettings.signal()) |> map { state, _ in state },\n"),
    ):
        replace(patches, "localStars-live-refresh", path, before, after)


def apply_appearance_parity_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    _sticker_patches(patches)
    _reaction_patches(patches)
    _information_patches(patches)
    _tab_size_patches(patches)
    _folder_patches(patches)
    _local_stars_patches(patches)
    return patches.write()
