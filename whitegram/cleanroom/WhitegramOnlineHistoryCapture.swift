import Foundation
import Postbox
import TelegramApi

enum WhitegramOnlineHistoryCapture {
    static var enabled: Bool {
        return WhitegramPreferences.bool("onlineHistoryEnabled", default: UserDefaults.standard.bool(forKey: "wg_onlineHistoryEnabled"))
    }

    static func recordUsers(transaction: Transaction, accountPeerId: PeerId, users: [PeerId: Api.User], acceptedPeerIds: Set<PeerId>) {
        guard enabled else { return }
        var statuses: [PeerId: Api.UserStatus] = [:]
        for peerId in acceptedPeerIds {
            if let user = users[peerId], case let .user(data) = user, let status = data.status { statuses[peerId] = status }
        }
        record(transaction: transaction, accountPeerId: accountPeerId, statuses: statuses, acceptedPeerIds: acceptedPeerIds)
    }

    static func record(transaction: Transaction, accountPeerId: PeerId, statuses: [PeerId: Api.UserStatus], acceptedPeerIds: Set<PeerId>) {
        guard enabled else { return }
        let timestamp = Date().timeIntervalSince1970
        var entries: [WhitegramOnlineHistoryEntry] = []
        for peerId in acceptedPeerIds.sorted(by: { $0.toInt64() < $1.toInt64() }) {
            guard peerId != accountPeerId, peerId.namespace == Namespaces.Peer.CloudUser,
                  transaction.isPeerContact(peerId: peerId), let status = statuses[peerId] else { continue }
            let isOnline: Bool
            switch status {
            case .userStatusOnline: isOnline = true
            case .userStatusOffline: isOnline = false
            default: continue
            }
            let peer = transaction.getPeer(peerId)
            entries.append(WhitegramOnlineHistoryEntry(peerId: peerId.toInt64(),
                peerName: peer.map { EnginePeer($0).debugDisplayTitle } ?? String(peerId.toInt64()),
                peerUsername: (peer as? TelegramUser)?.addressName, isOnline: isOnline, timestamp: timestamp))
        }
        WhitegramOnlineHistoryStore.forAccount(accountPeerId.toInt64()).append(entries)
    }
}
