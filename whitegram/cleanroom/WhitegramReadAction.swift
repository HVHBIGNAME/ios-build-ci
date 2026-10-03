import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public enum WhitegramReadAction {
    /// Sends exactly the bound receipt. A later subscription cannot widen its bound or reuse it.
    public static func read(account: Account, index: MessageIndex, threadId: Int64?, applyLocalRead: @escaping () -> Void) -> Signal<Never, NoError> {
        guard WhitegramContentSettings.readOnAction, !account.isSupportUser else { return .complete() }
        guard index.id.namespace == Namespaces.Message.Cloud || (index.id.peerId.namespace == Namespaces.Peer.SecretChat && index.id.namespace == Namespaces.Message.SecretIncoming) else { return .complete() }
        guard index.id.id > 0, index.timestamp > 0 else { return .complete() }
        let scope = WhitegramReadActionScope(accountId: account.peerId.toInt64(), peerId: index.id.peerId.toInt64(), threadId: threadId, namespace: index.id.namespace, messageId: index.id.id, timestamp: index.timestamp)
        let permit = WhitegramReadActionPermit(scope: scope)
        return deferred {
            guard permit.consume(for: scope), WhitegramContentSettings.readOnAction else { return .complete() }
            // Original action-pending state also admits the local read under ghost mode;
            // the hard network gate is independent and remains in force.
            applyLocalRead()
            guard WhitegramGhost.canReadOnAction(for: index.id.peerId) else { return .complete() }
            return account.postbox.transaction { transaction -> (Peer?, Peer?) in
                let peer = transaction.getPeer(index.id.peerId)
                let subPeer = threadId.flatMap { transaction.getPeer(PeerId($0)) }
                return (peer, subPeer)
            }
            |> mapToSignal { peer, subPeer -> Signal<Never, NoError> in
                guard let peer, WhitegramGhost.canReadOnAction(for: index.id.peerId) else { return .complete() }
                let request: Signal<Never, MTRpcError>
                if let inputSecretChat = apiInputSecretChat(peer), threadId == nil {
                    request = account.network.request(Api.functions.messages.readEncryptedHistory(peer: inputSecretChat, maxDate: index.timestamp)) |> ignoreValues
                } else if let inputPeer = apiInputPeerOrSelf(peer, accountPeerId: account.peerId) {
                    if let threadId {
                        if peer.id == account.peerId || peer.isMonoForum {
                            guard let subPeer, let inputSubPeer = apiInputPeer(subPeer) else { return .complete() }
                            request = account.network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: inputSubPeer, maxId: index.id.id)) |> ignoreValues
                        } else {
                            guard let threadId = Int32(exactly: threadId), threadId > 0 else { return .complete() }
                            request = account.network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: threadId, readMaxId: index.id.id)) |> ignoreValues
                        }
                    } else if let channel = apiInputChannel(peer) {
                        request = account.network.request(Api.functions.channels.readHistory(channel: channel, maxId: index.id.id)) |> ignoreValues
                    } else {
                        request = account.network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: index.id.id))
                        |> map { result -> Void in
                            switch result {
                            case let .affectedMessages(data):
                                account.stateManager.addUpdateGroups([.updatePts(pts: data.pts, ptsCount: data.ptsCount)])
                            }
                        }
                        |> ignoreValues
                    }
                } else {
                    return .complete()
                }
                // No retry/restart: a new action gets a new authorization. Only a real RPC
                // response can advance PTS; failure is never represented as server success.
                return request |> `catch` { _ -> Signal<Never, NoError> in .complete() }
            }
        }
    }

    public static func applyLocalRead(account: Account, index: MessageIndex) -> Signal<Void, NoError> {
        return account.postbox.transaction { transaction -> Void in
            _internal_applyMaxReadIndexInteractively(transaction: transaction, stateManager: account.stateManager, index: index, whitegramReadAction: true)
        }
    }
}
