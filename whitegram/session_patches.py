"""Protect committed authorization from stale login UI writes and trace local transitions."""

from source_patches import SourcePatches

CORE = "submodules/TelegramCore/Sources/"
AUTH = CORE + "TelegramEngine/Auth/TelegramEngineAuth.swift"
AUTHORIZATION = CORE + "Authorization.swift"
ACCOUNT = CORE + "Account/Account.swift"
NETWORK = CORE + "Network/Network.swift"
SHARED = "submodules/TelegramUI/Sources/SharedAccountContext.swift"
APP = "submodules/TelegramUI/Sources/AppDelegate.swift"
APPLICATION = "submodules/TelegramUI/Sources/ApplicationContext.swift"
RUNTIME_FILES = {"WhitegramSessionDiagnostics.swift": CORE + "WhitegramSessionDiagnostics.swift"}


def apply_session_patches(root):
    patches = SourcePatches(root)
    feature = "committedAuthorizationState"
    patches.replace(feature, AUTH,
        "        public func setState(state: UnauthorizedAccountState) -> Signal<Never, NoError> {\n"
        "            return self.account.postbox.transaction { transaction -> Void in\n"
        "                transaction.setState(state)",
        "        public func setState(state: UnauthorizedAccountState) -> Signal<Never, NoError> {\n"
        "            return self.account.postbox.transaction { transaction -> Void in\n"
        "                if transaction.getState() is AuthorizedAccountState {\n"
        "                    WhitegramSessionDiagnostics.shared.record(.staleLoginWriteBlocked)\n"
        "                    return\n"
        "                }\n"
        "                transaction.setState(state)")
    feature = "localSessionDiagnostics"
    for path, anchor, insertion in (
        (AUTHORIZATION, "    transaction.removeAuth()\n", "    WhitegramSessionDiagnostics.shared.record(.authorizationCommitted, datacenter: Int(account.masterDatacenterId))\n"),
        (ACCOUNT, "                                case let unauthorizedState as UnauthorizedAccountState:\n", "                                    WhitegramSessionDiagnostics.shared.record(.unauthorizedStateLoaded, datacenter: Int(unauthorizedState.masterDatacenterId))\n"),
        (ACCOUNT, "                                case let authorizedState as AuthorizedAccountState:\n", "                                    WhitegramSessionDiagnostics.shared.record(.authorizedStateLoaded, datacenter: Int(authorizedState.masterDatacenterId))\n"),
        (ACCOUNT, "                        #if DEBUG\n                        let initialDatacenterId: Int = 1\n", "                        WhitegramSessionDiagnostics.shared.record(.missingStateLoaded)\n"),
        (NETWORK, '            Logger.shared.log("Network", "contextLoggedOut")\n', "            WhitegramSessionDiagnostics.shared.record(.networkContextLoggedOut)\n"),
        (NETWORK, '        Logger.shared.log("Network", "requestMessageServiceAuthorizationRequired")\n', "        WhitegramSessionDiagnostics.shared.record(.networkAuthorizationRequired, datacenter: self.datacenterId)\n"),
        (SHARED, "                            self.activeAccountsValue!.accounts.append((account.id, context, accountRecord.2))\n", "                            WhitegramSessionDiagnostics.shared.record(.authorizedAccountAdded, datacenter: account.network.datacenterId)\n"),
        (SHARED, "    public func beginNewAuth(testingEnvironment: Bool) {\n", "        WhitegramSessionDiagnostics.shared.record(.newLoginCreated)\n"),
        (APP, "                    self.mainWindow.viewController = context.rootController\n", "                    WhitegramSessionDiagnostics.shared.record(.authorizedUIReady)\n"),
    ):
        after = insertion + anchor if ".missingStateLoaded" in insertion else anchor + insertion
        patches.replace(feature, path, anchor, after)
    anchor = "                            default:\n                                return .single(.ready(id, nil, attributes.sortIndex,"
    patches.replace(feature, SHARED, anchor, anchor.replace("                                return", "                                WhitegramSessionDiagnostics.shared.record(.unavailableAccountLoaded)\n                                return"))
    anchor = "        self.isReady.set(self.rootController.ready.get())\n"
    patches.replace(feature, APPLICATION, anchor, anchor + """        self.sessionDiagnosticsObserver = NotificationCenter.default.addObserver(forName: Notification.Name("WhitegramLoginDiagnostics.export"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            do {
                let file = try WhitegramSessionDiagnostics.shared.export()
                let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                controller.popoverPresentationController?.sourceView = self.rootController.view
                controller.popoverPresentationController?.sourceRect = CGRect(x: self.rootController.view.bounds.midX, y: self.rootController.view.bounds.midY, width: 1, height: 1)
                self.rootController.present(controller, animated: true)
            } catch {
                let alert = UIAlertController(title: "WhiteGram", message: "Could not export login diagnostics.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.rootController.present(alert, animated: true)
            }
        }
""")
    anchor = "    var authorizationCompleted: Bool = false\n"
    patches.replace(feature, APPLICATION, anchor, anchor + "    private var sessionDiagnosticsObserver: NSObjectProtocol?\n")
    anchor = "    deinit {\n        self.serviceNotificationEventsDisposable?.dispose()\n"
    patches.replace(feature, APPLICATION, anchor, "    deinit {\n        if let sessionDiagnosticsObserver { NotificationCenter.default.removeObserver(sessionDiagnosticsObserver) }\n        self.serviceNotificationEventsDisposable?.dispose()\n")
    return patches.write()
