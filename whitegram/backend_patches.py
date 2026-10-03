"""Backend runtime registry and account lifecycle hooks for the assembled overlay."""

from pathlib import Path

from source_patches import SourcePatches


BACKEND_RUNTIME_FILES = {
    **{name + ".swift": "submodules/TelegramCore/Sources/" + name + ".swift" for name in (
        "WhitegramBackendMessageEvent", "WhitegramBackendMessageBridge",
    )},
    **{name + ".swift": "submodules/SettingsUI/Sources/" + name + ".swift" for name in (
        "WhitegramBackendProtocol", "WhitegramBackendHTTP", "WhitegramBackendClient", "WhitegramBackendTransport", "WhitegramBackendAccess",
        "WhitegramBackendCredentials", "WhitegramBackendAuthentication",
        "WhitegramBackendDecoding", "WhitegramBackendLifecycle", "WhitegramBackendActivityRuntime",
        "WhitegramAPIStatusService", "WhitegramAPIStatusController",
        "WhitegramProfileModels", "WhitegramProfileService", "WhitegramProfileController",
        "WhitegramProfilePhotos", "WhitegramProfilePhotosController", "WhitegramProfilePhotoWallStore", "WhitegramProfileTextEditor",
        "WhitegramProfileWallController", "WhitegramProfilePresenceService",
        "WhitegramProfileStreakService", "WhitegramProfileStreakSession",
        "WhitegramProfileStreakController", "WhitegramProfileRegistration", "WhitegramProfileRegistrationController",
        "WhitegramRadioModels", "WhitegramRadioPlayer", "WhitegramRadioController",
        "WhitegramScammerDatabase",
    )},
}

APP_DELEGATE = "submodules/TelegramUI/Sources/AppDelegate.swift"
STATE_MANAGER = "submodules/TelegramCore/Sources/State/AccountStateManager.swift"
SENT_MESSAGES = "submodules/TelegramCore/Sources/State/ApplyUpdateMessage.swift"


def _insert_once(patches: SourcePatches, feature: str, path: str, anchor: str, insertion: str) -> None:
    value = patches.read(path)
    if value.count(anchor) != 1 or value.count(insertion) > 1:
        raise ValueError(f"{feature}: {path}: ambiguous or missing lifecycle anchor")
    if insertion not in value:
        patches.pending[path] = value.replace(anchor, anchor + insertion)
    patches.features.setdefault(feature, set()).add(path)


def backend_patches(patches: SourcePatches) -> None:
    _insert_once(patches, "whitegramBackendLifecycle", APP_DELEGATE,
        "        Logger.setSharedLogger(Logger(rootPath: rootPath, basePath: logsPath))\n",
        "        whitegramInstallBackend()\n")
    _insert_once(patches, "whitegramBackendAccount", APP_DELEGATE,
        "                return accountAndSettings.flatMap { context, callListSettings in\n",
        "                    whitegramRegisterBackendAccount(userId: context.account.peerId.id._internalGetInt64Value())\n")
    anchor = "                let signal = self.postbox.transaction { transaction -> [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)] in\n"
    patches.replace("whitegramStreakReceived", STATE_MANAGER, anchor, '''                for id in events.addedIncomingMessageIds {
                    WhitegramBackendMessageBridge.record(postbox: self.postbox, accountId: self.accountPeerId, messageId: id, direction: .received)
                }
''' + anchor)
    _insert_once(patches, "whitegramStreakSent", SENT_MESSAGES,
        "        if let updatedMessage, case let .Id(id) = updatedMessage.id {\n",
        "            WhitegramBackendMessageBridge.record(postbox: postbox, accountId: accountPeerId, messageId: id, direction: .sent)\n")
    anchor = "            return PeerPendingMessageDelivered(\n"
    patches.replace("whitegramStreakSent", SENT_MESSAGES, anchor,
        "            WhitegramBackendMessageBridge.record(postbox: postbox, accountId: stateManager.accountPeerId, messageId: id, direction: .sent)\n" + anchor)


def apply_backend_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    backend_patches(patches)
    return patches.write()
