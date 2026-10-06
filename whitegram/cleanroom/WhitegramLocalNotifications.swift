import Foundation
import PlatformRestrictionMatching
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import UIKit
import UserNotifications

final class WhitegramLocalNotifications {
    private let context: AccountContextImpl
    private let center = UNUserNotificationCenter.current()
    private let ledger = WhitegramNotificationLedger()
    private let lockDisposable = MetaDisposable()
    private var isLocked = true
    private var settings = InAppNotificationSettings.defaultSettings
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContextImpl) {
        self.context = context
        if let lock = context.sharedContext.appLockContext as? AppLockContextImpl {
            self.lockDisposable.set((lock.isCurrentlyLocked |> deliverOnMainQueue).start(next: { [weak self] value in
                self?.isLocked = value
            }))
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.cancelPending()
            })
        }
        self.observers.append(NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
            if !WhitegramNotificationSettings.current.enabled { self?.cancelPending() }
        })
    }

    deinit {
        self.lockDisposable.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.center.removePendingNotificationRequests(withIdentifiers: self.ledger.invalidatePending())
    }

    func updateSettings(_ settings: InAppNotificationSettings) {
        self.settings = settings
    }

    func enqueue(messages: [Message], notify: Bool, threadData: MessageHistoryThreadData?) {
        guard let first = messages.first, self.isEligible(first, notify: notify) else { return }
        let id = self.id(first.id)
        guard let ticket = self.ledger.reserve(id) else { return }
        self.center.getNotificationSettings { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self, self.ledger.isCurrent(ticket) else { return }
                var allowed = authorization.authorizationStatus == .authorized || authorization.authorizationStatus == .provisional
                if #available(iOS 14.0, *) { allowed = allowed || authorization.authorizationStatus == .ephemeral }
                guard allowed, self.isEligible(first, notify: notify) else {
                    self.ledger.finish(ticket, delivered: false)
                    return
                }
                let preview = WhitegramNotificationPreview.resolve(isLocked: self.isLocked,
                    displayPreviews: self.settings.displayPreviews, displayName: self.settings.displayNameOnLockscreen)
                guard let content = WhitegramNotificationContent.make(context: self.context, messages: messages,
                    threadData: threadData, id: id, preview: preview, playSound: self.settings.playSounds) else {
                    self.ledger.finish(ticket, delivered: false)
                    return
                }
                let request = UNNotificationRequest(identifier: id.rawValue, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))
                let center = self.center
                center.add(request) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else {
                            center.removePendingNotificationRequests(withIdentifiers: [id.rawValue])
                            return
                        }
                        if !self.ledger.isCurrent(ticket), !self.ledger.contains(id) {
                            center.removePendingNotificationRequests(withIdentifiers: [id.rawValue])
                        }
                        self.ledger.finish(ticket, delivered: error == nil)
                        if let error { NSLog("Whitegram: local notification could not be scheduled (%ld)", (error as NSError).code) }
                    }
                }
            }
        }
    }

    private func isEligible(_ message: Message, notify: Bool) -> Bool {
        let muted = message.attributes.contains { attribute in
            return (attribute as? NotificationInfoMessageAttribute)?.flags.contains(.muted) == true
        }
        let contentSettings = self.context.currentContentSettings.with { $0 }
        let restricted = message.restrictionReason(platform: "ios", contentSettings: contentSettings) != nil ||
            message.peers[message.id.peerId].flatMap { EnginePeer($0).restrictionText(platform: "ios", contentSettings: contentSettings) } != nil
        return WhitegramNotificationSettings.current.shouldNotify(isActive: UIApplication.shared.applicationState == .active,
            notify: notify, incoming: message.flags.contains(.Incoming), selfChat: message.id.peerId == self.context.account.peerId,
            wasScheduled: message.flags.contains(.WasScheduled), muted: muted, restricted: restricted)
    }

    private func id(_ id: MessageId) -> WhitegramLocalNotificationId {
        return WhitegramLocalNotificationId(accountId: self.context.account.id.int64, peerId: id.peerId.toInt64(), namespace: id.namespace, messageId: id.id)
    }

    private func cancelPending() {
        self.center.removePendingNotificationRequests(withIdentifiers: self.ledger.invalidatePending())
    }

    func clearReadMessages(_ ids: [MessageId]) {
        let maximumIds = ids.map(self.id)
        self.ledger.recordRead(maximumIds)
        guard !maximumIds.isEmpty, !WhitegramNotificationSettings.current.persistent else { return }
        let matching: (String) -> Bool = { identifier in
            guard let id = WhitegramLocalNotificationId(rawValue: identifier) else { return false }
            return maximumIds.contains { id.isRead(by: $0) }
        }
        let center = self.center
        center.getDeliveredNotifications { notifications in
            guard !WhitegramNotificationSettings.current.persistent else { return }
            center.removeDeliveredNotifications(withIdentifiers: notifications.map { $0.request.identifier }.filter(matching))
        }
        center.getPendingNotificationRequests { requests in
            guard !WhitegramNotificationSettings.current.persistent else { return }
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter(matching))
        }
    }
}
