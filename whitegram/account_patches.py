"""Account/session consumers. All anchors are validated before any target is written."""

from pathlib import Path

from source_patches import SourcePatches


CORE = "submodules/TelegramCore/Sources/"
UI = "submodules/TelegramUI/Sources/"
SETTINGS = "submodules/SettingsUI/Sources/"
CHAT = "submodules/ChatListUI/Sources/ChatListController.swift"
SHARED = UI + "SharedAccountContext.swift"
NETWORK = CORE + "Network/Network.swift"
ACCOUNT = CORE + "Account/Account.swift"
MANAGER = CORE + "Account/AccountManager.swift"
APPLICATION = UI + "ApplicationContext.swift"
NOTIFICATIONS = UI + "SharedNotificationManager.swift"

ACCOUNTS_RUNTIME_FILES = {
    **{name: CORE + name for name in (
        "WhitegramSessionModels.swift", "WhitegramSessionCrypto.swift", "WhitegramSessionFiles.swift",
        "WhitegramSessionTelethon.swift", "WhitegramSessionTData.swift", "WhitegramSessionZip.swift",
        "WhitegramAccountImportState.swift", "WhitegramAccountImport.swift", "WhitegramAccountFrozenStore.swift",
    )},
    **{name: SETTINGS + name for name in (
        "WhitegramAccountsSettingsController.swift", "WhitegramAccountActions.swift",
        "WhitegramAccountDocuments.swift", "WhitegramSessionKeychain.swift",
    )},
    "WhitegramAccountSwitcher.swift": "submodules/ChatListUI/Sources/WhitegramAccountSwitcher.swift",
}

ACCOUNTS_REQUIRED_DEPENDENCIES = {
    "submodules/TelegramCore/BUILD": ["//submodules/sqlcipher:sqlcipher"],
    "submodules/ChatListUI/BUILD": ["//submodules/TelegramUI/Components/AvatarComponent", "//submodules/TelegramUI/Components/ChatListHeaderComponent"],
}


def _session_host(patches: SourcePatches):
    feature = "accountTransfer"
    patches.replace(feature, SHARED, "public final class SharedAccountContextImpl: SharedAccountContext {", "public final class SharedAccountContextImpl: SharedAccountContext, WhitegramAccountSessionHost {")
    anchor = "    public let basePath: String\n"
    patches.replace(feature, SHARED, anchor, anchor + "    public let whitegramOpenSessionAccount: (AccountRecordId, AccountBackupData?, Bool) -> Signal<AccountResult, NoError>\n")
    anchor = "        self.basePath = basePath\n"
    patches.replace(feature, SHARED, anchor, anchor + """        self.whitegramOpenSessionAccount = { id, backup, testing in
            return accountWithId(accountManager: accountManager, networkArguments: networkArguments, id: id, encryptionParameters: encryptionParameters, supplementary: true, isSupportUser: false, rootPath: rootPath, beginWithTestingEnvironment: testing, backupData: backup, auxiliaryMethods: makeTelegramAccountAuxiliaryMethods(uploadInBackground: appDelegate?.uploadInBackround), shouldKeepAutoConnection: false)
        }
""")
    anchor = "            for record in view.records {\n                let isLoggedOut = record.attributes.contains(where: { attribute in\n"
    patches.replace(feature, SHARED, anchor, """            for record in view.records {
                // Session imports remain private until Telegram has verified their identity.
                if record.temporarySessionId != nil {
                    continue
                }
                let isLoggedOut = record.attributes.contains(where: { attribute in
""")


def _retention(patches: SourcePatches):
    feature = "keepUnavailableAccounts"
    before = '                Logger.shared.log("ApplicationContext", "account logged out")\n                let _ = logoutFromAccount(id: accountId, accountManager: accountManager, alreadyLoggedOutRemotely: false).start()'
    after = '                Logger.shared.log("ApplicationContext", "account logged out")\n                let _ = whitegramHandleUnavailableAccount(account: context.account, accountManager: accountManager).start()'
    patches.replace(feature, APPLICATION, before, after)
    patches.replace(feature, APPLICATION, "        let accountId = context.account.id\n        self.loggedOutDisposable.set((context.account.loggedOut", "        self.loggedOutDisposable.set((context.account.loggedOut")
    patches.replace(feature, NOTIFICATIONS,
                    "logoutFromAccount(id: account.id, accountManager: accountManager, alreadyLoggedOutRemotely: true)",
                    "whitegramHandleUnavailableAccount(account: account, accountManager: accountManager, alreadyLoggedOutRemotely: true)")
    anchor = '    Logger.shared.log("AccountManager", "logoutFromAccount \\(id)")\n'
    patches.replace(feature, MANAGER, anchor, "    WhitegramAccountFrozenStore.shared.clear(accountId: id.int64)\n" + anchor)
    anchor = """                    } else {
                        let _ = accountManager.transaction({ transaction in
                            transaction.updateRecord(accountRecord.0, { _ in
                                return nil
                            })
                        }).start()
                    }
"""
    patches.replace(feature, SHARED, anchor, """                    } else {
                        let _ = accountManager.transaction({ transaction in
                            transaction.updateRecord(accountRecord.0, { record in
                                if let record, record.temporarySessionId == nil, WhitegramPreferences.bool("keepUnavailableAccounts") {
                                    WhitegramAccountFrozenStore.shared.markFrozen(accountId: record.id.int64, peerId: whitegramRecordIdentity(record)?.peerId, reason: .unknown)
                                    return record
                                }
                                return nil
                            })
                        }).start()
                    }
""")
    anchor = "    var didReceiveSoftAuthResetError: (() -> Void)?\n"
    patches.replace(feature, NETWORK, anchor, anchor + "    var whitegramAuthorizationFailure: ((String) -> Void)?\n")
    anchor = "        return Signal { subscriber in\n            let request = MTRequest()\n"
    patches.replace(feature, NETWORK, anchor, "        let whitegramAuthorizationFailure = self.whitegramAuthorizationFailure\n" + anchor, count=2)
    anchor = "                if let error = error {\n                    subscriber.putError(error)"
    patches.replace(feature, NETWORK, anchor, "                if let error = error {\n                    whitegramAuthorizationFailure?(error.errorDescription)\n                    subscriber.putError(error)", count=2)
    anchor = "        self.network.didReceiveSoftAuthResetError = { [weak self] in\n"
    patches.replace(feature, ACCOUNT, anchor, """        self.network.whitegramAuthorizationFailure = { [weak self] description in
            guard let self else { return }
            whitegramRecordAuthorizationFailure(accountManager: accountManager, accountId: self.id, peerId: self.peerId, description: description)
        }
""" + anchor)


def _switcher(patches: SourcePatches):
    feature = "accountSwitcherEnabled"
    anchor = "    var rightButton: AnyComponentWithIdentity<NavigationButtonComponentEnvironment>?\n"
    patches.replace(feature, CHAT, anchor, anchor + "    private var whitegramAccountSwitcher: WhitegramAccountSwitcher?\n")
    anchor = "        self.parentController = parentController\n        \n        let hasProxy = context.sharedContext.accountManager.sharedData"
    patches.replace(feature, CHAT, anchor, """        self.parentController = parentController
        if case .chatList(.root) = location {
            self.whitegramAccountSwitcher = WhitegramAccountSwitcher(context: context, updated: { [weak parentController] in
                parentController?.requestLayout(transition: .immediate)
            })
        }
""" + "        \n" + "        let hasProxy = context.sharedContext.accountManager.sharedData")
    anchor = """        if let rightButton = self.rightButton {
            result.append(rightButton)
        }
"""
    patches.replace(feature, CHAT, anchor, anchor + """        if self.rightButton?.id == AnyHashable("compose"), let button = self.whitegramAccountSwitcher?.button {
            result.append(button)
        }
""")


def apply_account_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    _session_host(patches)
    _retention(patches)
    _switcher(patches)
    inventory = {
        SHARED: {"whitegramOpenSessionAccount": 2, "WhitegramAccountSessionHost": 1, "WhitegramAccountFrozenStore.shared.markFrozen": 1},
        NETWORK: {"var whitegramAuthorizationFailure": 1, "let whitegramAuthorizationFailure": 2, "whitegramAuthorizationFailure?(": 2},
        ACCOUNT: {"self.network.whitegramAuthorizationFailure": 1},
        APPLICATION: {"whitegramHandleUnavailableAccount(": 1},
        NOTIFICATIONS: {"whitegramHandleUnavailableAccount(": 1},
        CHAT: {"WhitegramAccountSwitcher?": 1, "self.whitegramAccountSwitcher =": 1, "self.whitegramAccountSwitcher?.button": 1},
    }
    for path, markers in inventory.items():
        for marker, count in markers.items():
            if patches.read(path).count(marker) != count:
                raise ValueError(f"account hook inventory: {path}: expected {count} {marker!r}")
    return patches.write()
