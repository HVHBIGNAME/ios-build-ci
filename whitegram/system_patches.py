"""RAM overlay and local-notification integration into the assembled Telegram sources."""

from pathlib import Path

from source_patches import SourcePatches


SYSTEM_RUNTIME_FILES = {
    **{name + ".swift": "submodules/Display/Source/" + name + ".swift" for name in (
        "WhitegramRAMUsage", "WhitegramRAMUsageOverlay",
    )},
    **{name + ".swift": "submodules/TelegramCore/Sources/" + name + ".swift" for name in (
        "WhitegramNotificationSettings", "WhitegramLocalNotificationId",
    )},
    **{name + ".swift": "submodules/TelegramUI/Sources/" + name + ".swift" for name in (
        "WhitegramSilentAudio", "WhitegramBackgroundKeepAlive", "WhitegramNotificationContent", "WhitegramLocalNotifications",
    )},
}

WINDOW = "submodules/Display/Source/WindowContent.swift"
APP_DELEGATE = "submodules/TelegramUI/Sources/AppDelegate.swift"
APPLICATION_CONTEXT = "submodules/TelegramUI/Sources/ApplicationContext.swift"
WAKEUP = "submodules/TelegramUI/Sources/SharedWakeupManager.swift"


def _replace_once(patches: SourcePatches, feature: str, path: str, before: str, after: str) -> None:
    value = patches.read(path)
    if after in value and (value.count(after) != 1 or before in value.replace(after, "")):
        raise ValueError(f"{feature}: {path}: mixed or duplicate system hooks")
    patches.replace(feature, path, before, after)


def ram_patches(patches: SourcePatches) -> None:
    _replace_once(patches, "showRAMUsage", WINDOW,
        "    public let badgeView: UIImageView\n",
        "    public let badgeView: UIImageView\n    private var whitegramRAMUsage: WhitegramRAMUsageOverlay?\n")
    anchor = "        self.hostView.containerView.addSubview(self.badgeView)\n"
    _replace_once(patches, "showRAMUsage", WINDOW, anchor, anchor + """        if self.statusBarHost != nil {
            self.whitegramRAMUsage = WhitegramRAMUsageOverlay(hostView: self.hostView.containerView,
                statusBarHeight: self.windowLayout.statusBarHeight ?? 0.0, leftInset: self.windowLayout.safeInsets.left)
        }
""")
    anchor = "                self.updatedContainerLayout = childLayout\n"
    _replace_once(patches, "showRAMUsage", WINDOW, anchor, anchor + """                self.whitegramRAMUsage?.updateLayout(statusBarHeight: childLayout.statusBarHeight ?? 0.0,
                    leftInset: childLayout.safeInsets.left)
""")


def notification_patches(patches: SourcePatches) -> None:
    _replace_once(patches, "whitegramNotifications", APPLICATION_CONTEXT,
        "    private let notificationMessagesDisposable = MetaDisposable()\n",
        "    private let notificationMessagesDisposable = MetaDisposable()\n    private let whitegramLocalNotifications: WhitegramLocalNotifications\n")
    anchor = "        self.notificationController = NotificationContainerController(context: context)\n"
    _replace_once(patches, "whitegramNotifications", APPLICATION_CONTEXT, anchor,
        "        self.whitegramLocalNotifications = WhitegramLocalNotifications(context: context)\n" + anchor)
    anchor = "                    strongSelf.inAppNotificationSettings = settings\n"
    _replace_once(patches, "whitegramNotifications", APPLICATION_CONTEXT, anchor,
        anchor + "                    strongSelf.whitegramLocalNotifications.updateSettings(settings)\n")
    anchor = "            if let strongSelf = self, let (messages, _, notify, threadData) = messageList.last, let firstMessage = messages.first {\n"
    _replace_once(patches, "whitegramNotifications", APPLICATION_CONTEXT, anchor, """            if let strongSelf = self {
                for (messages, _, notify, threadData) in messageList {
                    strongSelf.whitegramLocalNotifications.enqueue(messages: messages, notify: notify, threadData: threadData)
                }
            }
""" + anchor)
    anchor = "                strongSelf.context.sharedContext.applicationBindings.clearMessageNotifications(ids)\n"
    _replace_once(patches, "persistentNotifications", APPLICATION_CONTEXT, anchor,
        anchor + "                strongSelf.whitegramLocalNotifications.clearReadMessages(ids)\n")


def background_patches(patches: SourcePatches) -> None:
    anchor = "    private var clearNotificationsManager: ClearNotificationsManager?\n"
    _replace_once(patches, "backgroundKeepAlive", APP_DELEGATE, anchor,
        anchor + "    private var whitegramBackgroundKeepAlive: WhitegramBackgroundKeepAlive?\n")
    anchor = "            let sharedApplicationContext = SharedApplicationContext(sharedContext: sharedContext, notificationManager: notificationManager, wakeupManager: wakeupManager)\n"
    _replace_once(patches, "backgroundKeepAlive", APP_DELEGATE, anchor, anchor + """            self.whitegramBackgroundKeepAlive = WhitegramBackgroundKeepAlive(audioSession: sharedContext.mediaManager.audioSession,
                activityUpdated: { [weak wakeupManager] active in wakeupManager?.setWhitegramKeepAlive(active) })
""")
    anchor = "    private var hasActiveAudioSession: Bool = false\n"
    _replace_once(patches, "backgroundKeepAlive", WAKEUP, anchor,
        anchor + "    private var whitegramKeepAlive: Bool = false\n")
    anchor = "    func checkTasks() {\n"
    _replace_once(patches, "backgroundKeepAlive", WAKEUP, anchor, """    func setWhitegramKeepAlive(_ value: Bool) {
        guard self.whitegramKeepAlive != value else { return }
        self.whitegramKeepAlive = value
        self.checkTasks()
    }

""" + anchor)
    _replace_once(patches, "backgroundKeepAlive", WAKEUP,
        "        if self.inForeground || self.hasActiveAudioSession || self.isInBackgroundExtension ||",
        "        if self.whitegramKeepAlive || self.inForeground || self.hasActiveAudioSession || self.isInBackgroundExtension ||")
    _replace_once(patches, "backgroundKeepAlive", WAKEUP,
        "                if (self.inForeground && primary) || !tasks.isEmpty ||",
        "                if ((self.inForeground || self.whitegramKeepAlive) && primary) || !tasks.isEmpty ||")
    _replace_once(patches, "backgroundKeepAlive", WAKEUP,
        "account.shouldExplicitelyKeepWorkerConnections.set(.single(tasks.backgroundAudio ||",
        "account.shouldExplicitelyKeepWorkerConnections.set(.single((self.whitegramKeepAlive && primary) || tasks.backgroundAudio ||")


def apply_system_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    ram_patches(patches)
    notification_patches(patches)
    background_patches(patches)
    return patches.write()
