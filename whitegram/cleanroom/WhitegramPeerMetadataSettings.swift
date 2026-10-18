import Foundation
import SwiftSignalKit

extension WhitegramPeerMetadataSettings {
    public static var current: Self {
        return Self(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public static func signal() -> Signal<Self, NoError> {
        return Signal { subscriber in
            let names = [WhitegramPreferences.updatedNotification, WhitegramLocalizationStore.changedNotification]
            let observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                    subscriber.putNext(Self.current)
                }
            }
            subscriber.putNext(Self.current)
            return ActionDisposable { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        }
    }
}
