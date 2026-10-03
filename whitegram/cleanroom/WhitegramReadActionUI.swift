import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// Capturing the signal before enqueueing pins the receipt to the visible chat snapshot,
/// even if the user navigates to a different chat while the enqueue transaction runs.
func whitegramEnqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage], readAction: Signal<Never, NoError>) -> Signal<[MessageId?], NoError> {
    return enqueueMessages(account: account, peerId: peerId, messages: messages)
    |> afterNext { ids in
        if ids.contains(where: { $0?.namespace == Namespaces.Message.Local }) {
            let _ = readAction.startStandalone()
        }
    }
}
