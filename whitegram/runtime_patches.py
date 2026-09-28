import json
from pathlib import Path

from source_patches import SourcePatches

CORE = "submodules/TelegramCore/Sources/"


def apply_privacy(patches: SourcePatches):
    presence = CORE + "State/ManagedAccountPresence.swift"
    patches.replace("online-status", presence,
        "    private var wasOnline: Bool = false",
        "    private var whitegramSettingsObserver: NSObjectProtocol?\n    private var wasOnline: Bool = false")
    patches.replace("online-status", presence,
        "        self.network = network\n",
        "        self.network = network\n"
        "        self.whitegramSettingsObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { [weak self] _ in\n"
        "            self?.queue.async { [weak self] in\n"
        "                guard let self else { return }\n"
        "                self.updatePresence(self.wasOnline)\n"
        "            }\n"
        "        }\n")
    patches.replace("online-status", presence,
        "        self.currentRequestDisposable.dispose()\n",
        "        self.currentRequestDisposable.dispose()\n"
        "        if let observer = self.whitegramSettingsObserver {\n"
        "            NotificationCenter.default.removeObserver(observer)\n"
        "        }\n")
    patches.replace("online-status", presence,
        "    private func updatePresence(_ isOnline: Bool) {\n",
        "    private func updatePresence(_ isOnline: Bool) {\n"
        "        let isOnline = WhitegramGhost.effectiveOnlineStatus(requested: isOnline)\n"
        "        self.onlineTimer?.invalidate()\n")

    activity = CORE + "State/ManagedLocalInputActivities.swift"
    signature = "private func requestActivity(postbox: Postbox, network: Network, accountPeerId: PeerId, peerId: PeerId, threadId: Int64?, activity: PeerInputActivity?) -> Signal<Void, NoError> {\n"
    patches.replace("typing-recording-upload", activity, signature,
        signature + "    if WhitegramGhost.suppressActivity(activity) {\n        return .complete()\n    }\n")

    reads = CORE + "State/SynchronizePeerReadState.swift"
    signature = "private func pushPeerReadState(network: Network, postbox: Postbox, stateManager: AccountStateManager, peerId: PeerId, readState: PeerReadState) -> Signal<PeerReadState, PeerReadStateValidationError> {\n"
    patches.replace("read-receipts", reads, signature,
        signature + "    if WhitegramGhost.suppressReadReceipts {\n        return .single(readState)\n    }\n")
    contents = CORE + "State/ManagedSynchronizeConsumeMessageContentsOperations.swift"
    signature = "private func synchronizeConsumeMessageContents(transaction: Transaction, network: Network, stateManager: AccountStateManager, peerId: PeerId, operation: SynchronizeConsumeMessageContentsOperation) -> Signal<Void, NoError> {\n"
    patches.replace("media-read-receipts", contents, signature,
        signature + "    if WhitegramGhost.suppressReadReceipts {\n        return .complete()\n    }\n")

    discussion = CORE + "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift"
    patches.guard_requests("discussion-read-receipts", discussion,
        "network.request(Api.functions.messages.readDiscussion(", "!WhitegramGhost.suppressReadReceipts", 3)
    patches.guard_requests("discussion-read-receipts", discussion,
        "network.request(Api.functions.messages.readSavedHistory(", "!WhitegramGhost.suppressReadReceipts", 3)
    thread = CORE + "TelegramEngine/Messages/ReplyThreadHistory.swift"
    anchor = "            if let subPeerId {\n                let signal = strongSelf.account.network.request(Api.functions.messages.readSavedHistory"
    patches.replace("discussion-read-receipts", thread, anchor,
        "            if WhitegramGhost.suppressReadReceipts {\n                return\n            }\n" + anchor)
    mark_all = CORE + "TelegramEngine/Messages/MarkAllChatsAsRead.swift"
    patches.replace("bulk-read-receipts", mark_all, "            for peer in result {\n",
        "            for peer in result {\n                if WhitegramGhost.suppressReadReceipts { continue }\n")

    stories = CORE + "TelegramEngine/Messages/Stories.swift"
    patches.replace("story-read-receipts", stories,
        "            return account.network.request(Api.functions.stories.incrementStoryViews(peer: inputPeer, id: [id]))",
        "            if WhitegramGhost.suppressStoryReadReceipts { return .complete() }\n"
        "            return account.network.request(Api.functions.stories.incrementStoryViews(peer: inputPeer, id: [id]))")
    patches.replace("story-read-receipts", stories,
        "            _internal_addSynchronizeViewStoriesOperation(peerId: peerId, storyId: id, transaction: transaction)",
        "            if !WhitegramGhost.suppressStoryReadReceipts {\n"
        "                _internal_addSynchronizeViewStoriesOperation(peerId: peerId, storyId: id, transaction: transaction)\n"
        "            }")
    queued_stories = CORE + "State/ManagedSynchronizeViewStoriesOperations.swift"
    signature = "private func pushStoriesAreSeen(postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: SynchronizeViewStoriesOperation) -> Signal<Void, NoError> {\n"
    patches.replace("story-read-receipts", queued_stories, signature,
        signature + "    if WhitegramGhost.suppressStoryReadReceipts {\n        return .complete()\n    }\n")

    personal = CORE + "State/ManagedConsumePersonalMessagesActions.swift"
    for function, indentation in (("synchronizeConsumeMessageContents", 12), ("synchronizeReadMessageReactionsOrPollVotes", 8)):
        prefix = f"private func {function}(transaction: Transaction, postbox: Postbox, network: Network, stateManager: AccountStateManager, id: MessageId) -> Signal<Void, NoError> {{\n"
        prefix += "    if id.peerId.namespace == Namespaces.Peer.CloudUser || id.peerId.namespace == Namespaces.Peer.CloudGroup {\n        return "
        anchor = prefix + "network.request(Api.functions.messages.readMessageContents(id: [id.id]))\n" + " " * indentation + "|> map(Optional.init)"
        patches.replace("media-read-receipts", personal, anchor, prefix + "WhitegramGhost.messageContentsRequest(network: network, ids: [id.id])")
    patches.replace("media-read-receipts", personal,
        "network.request(Api.functions.channels.readMessageContents(channel: inputChannel, id: [id.id]))",
        "WhitegramGhost.channelContentsRequest(network: network, channel: inputChannel, ids: [id.id])", count=2)
    tracker = CORE + "State/AccountViewTracker.swift"
    anchor = "    public func updateSeenLiveLocationForMessageIds(messageIds: Set<MessageId>) {\n        self.queue.async {\n"
    patches.replace("media-read-receipts", tracker, anchor,
        anchor + "            if WhitegramGhost.suppressReadReceipts { return }\n")

    bulk = CORE + "State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift"
    signature = "private func synchronizeMarkAllUnseen(transaction: Transaction, postbox: Postbox, network: Network, stateManager: AccountStateManager, peerId: PeerId, operation: SynchronizeMarkAllUnseenPersonalMessagesOperation) -> Signal<Void, NoError> {\n"
    patches.replace("bulk-content-receipts", bulk, signature,
        signature + "    if WhitegramGhost.suppressReadReceipts { return .complete() }\n")
    anchor = "        |> mapToSignal { ids -> Signal<Int32?, MTRpcError> in\n            let filteredIds = ids.filter { $0.id <= operation.maxId }"
    patches.replace("bulk-content-receipts", bulk, anchor,
        "        |> mapToSignal { ids -> Signal<Int32?, MTRpcError> in\n            if WhitegramGhost.suppressReadReceipts { return .single(nil) }\n            let filteredIds = ids.filter { $0.id <= operation.maxId }")
    for method, arguments in (
        ("readReactions", "flags: flags, peer: inputPeer, topMsgId: topMsgId, savedPeerId: savedPeerId"),
        ("readPollVotes", "flags: flags, peer: inputPeer, topMsgId: topMsgId"),
    ):
        request = f"network.request(Api.functions.messages.{method}({arguments}))"
        anchor = f"    let signal = {request}\n    |> map(Optional.init)"
        patches.replace("bulk-content-receipts", bulk, anchor,
            "    let signal = deferred { () -> Signal<Api.messages.AffectedHistory?, MTRpcError> in\n"
            "        if WhitegramGhost.suppressReadReceipts { return .single(nil) }\n"
            f"        return {request} |> map(Optional.init)\n"
            "    }")

    secret = CORE + "State/ManagedSecretChatOutgoingOperations.swift"
    for layer in (46, 73, 101, 144):
        anchor = f"return .layer{layer}(.decryptedMessageService(randomId: actionGloballyUniqueId, action: .decryptedMessageActionReadMessages(randomIds: globallyUniqueIds)))"
        patches.replace("secret-content-receipts", secret, anchor,
            f"return .layer{layer}(.decryptedMessageService(randomId: actionGloballyUniqueId, action: WhitegramGhost.suppressReadReceipts ? .decryptedMessageActionNoop : .decryptedMessageActionReadMessages(randomIds: globallyUniqueIds)))")
    anchor = "randomBytes: randomBytes, action: .decryptedMessageActionReadMessages(randomIds: globallyUniqueIds)"
    patches.replace("secret-content-receipts", secret, anchor,
        "randomBytes: randomBytes, action: .decryptedMessageActionReadMessages(randomIds: WhitegramGhost.suppressReadReceipts ? [] : globallyUniqueIds)")
    enqueue = CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift"
    patches.replace("secret-content-receipts", enqueue, "                                if let layer = layer {\n", "                                if let layer = layer, !WhitegramGhost.suppressReadReceipts {\n")
    patches.replace("secret-content-receipts", enqueue,
        "                            if let state = state, let layer = layer, let globallyUniqueId = message.globallyUniqueId {",
        "                            if let state = state, let layer = layer, let globallyUniqueId = message.globallyUniqueId, !WhitegramGhost.suppressReadReceipts {", count=2)


def apply_runtime_patches(root: Path):
    patches = SourcePatches(root)
    apply_privacy(patches)
    apply_fork_bindings(patches)
    features = patches.write()
    (root / "whitegram-runtime-report.json").write_text(json.dumps(features, indent=2), encoding="utf-8")
    print(f"Connected {len(features)} runtime paths")


def apply_fork_bindings(patches: SourcePatches):
    startup = "submodules/TelegramUI/Sources/AppDelegate.swift"
    anchor = "        testIsLaunched = true\n"
    patches.replace("fork-settings-bindings", startup, anchor,
        anchor + "        WhitegramForkBridge.migrate()\n        DispatchQueue.global(qos: .utility).async {\n            let _ = whitegramMigrateServiceCredentials()\n        }\n")
    preferences = "submodules/TelegramUIPreferences/Sources/"
    for filename, load, save in (
        ("WhiteGramChatSettings.swift", "chat", "saveChat"),
        ("WhiteGramTabSettings.swift", "tabs", "saveTabs"),
        ("WhiteGramStorySettings.swift", "stories", "saveStories"),
    ):
        path = preferences + filename
        patches.replace("fork-settings-bindings", path, "            return value\n", f"            return WhitegramForkBridge.{load}(value)\n")
        patches.replace("fork-settings-bindings", path, "        return .defaultSettings\n", f"        return WhitegramForkBridge.{load}(.defaultSettings)\n")
        patches.replace("fork-settings-bindings", path, "            UserDefaults.standard.set(data, forKey: Self.storageKey)\n", f"            UserDefaults.standard.set(data, forKey: Self.storageKey)\n            WhitegramForkBridge.{save}(self)\n")
    menu = preferences + "WhiteGramContextMenuSettings.swift"
    patches.replace("fork-settings-bindings", menu, "        self.values = values", "        self.values = WhitegramForkBridge.menu(values)")
    patches.replace("fork-settings-bindings", menu, "        UserDefaults.standard.set(value, forKey: option.storageKey)", "        UserDefaults.standard.set(value, forKey: option.storageKey)\n        WhitegramForkBridge.saveMenu(option, enabled: value)")
    other = preferences + "WhiteGramOtherSettings.swift"
    anchor = "    }\n\n    public static var current: WhiteGramOtherSettings {"
    patches.replace("fork-settings-bindings", other, anchor, "        self = WhitegramForkBridge.other(self)\n" + anchor)
    for original, canonical in (("autoTranslate", "translateMessagesEnabled"), ("forceDeviceMicrophone", "forceDeviceMicrophone"), ("hideCameraInGallery", "hideGalleryCamera")):
        anchor = f'        UserDefaults.standard.set(value, forKey: "whitegram.other.{original}")'
        patches.replace("fork-settings-bindings", other, anchor, anchor + f'\n        WhitegramPreferences.set(value, for: "{canonical}")')
    patches.replace("fork-settings-bindings", other, "import Foundation\n", "import Foundation\nimport TelegramCore\n")
