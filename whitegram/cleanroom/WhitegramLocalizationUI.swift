import Foundation
import SwiftSignalKit
import TelegramCore

public func whitegramLocalizationUpdates() -> Signal<Void, NoError> {
    return Signal { subscriber in
        var observers: [NSObjectProtocol] = []
        for name in [WhitegramLocalizationStore.changedNotification, WhitegramPreferences.updatedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in subscriber.putNext(Void()) })
        }
        subscriber.putNext(Void())
        return ActionDisposable {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
