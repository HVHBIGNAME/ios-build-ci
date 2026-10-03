import Foundation

public struct WhitegramBackendMessageEvent: Equatable {
    public enum Direction: String { case sent, received }
    public static let notification = Notification.Name("WhitegramBackendConfirmedMessage")

    public let accountId: Int64
    public let peerId: Int64
    public let messageId: Int32
    public let timestamp: Int32
    public let direction: Direction

    public init(accountId: Int64, peerId: Int64, messageId: Int32, timestamp: Int32, direction: Direction) {
        self.accountId = accountId
        self.peerId = peerId
        self.messageId = messageId
        self.timestamp = timestamp
        self.direction = direction
    }
}
