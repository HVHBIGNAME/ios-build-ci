import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext

final class WhitegramChatOnlineIndicatorNode: ASDisplayNode {
    private let context: AccountContext
    private let dotNode = ASImageNode()
    private let presenceDisposable = MetaDisposable()
    private var observers: [NSObjectProtocol] = []
    private var peer: Peer?
    private var theme: PresentationTheme?
    private var subscribedPeerId: PeerId?
    private var subscriptionRevision: UInt = 0
    private var isOnline = false

    init(context: AccountContext) {
        self.context = context
        super.init()
        self.isUserInteractionEnabled = false
        self.dotNode.isLayerBacked = true
        self.dotNode.displaysAsynchronously = false
        self.dotNode.isHidden = true
        self.dotNode.frame = CGRect(x: 23.0, y: 23.0, width: 11.0, height: 11.0)
        self.addSubnode(self.dotNode)
    }

    deinit {
        self.presenceDisposable.dispose()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func didLoad() {
        super.didLoad()
        for name in [WhitegramPreferences.updatedNotification, UserDefaults.didChangeNotification, UIApplication.didBecomeActiveNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                let force = notification.name == UIApplication.didBecomeActiveNotification
                Queue.mainQueue().justDispatch { [weak self] in
                    self?.refreshSubscription(force: force)
                }
            })
        }
        self.refreshSubscription()
    }

    func update(peer: Peer?, theme: PresentationTheme) {
        self.peer = peer
        self.updateTheme(theme)
        if self.isNodeLoaded {
            self.refreshSubscription()
        }
    }

    func updateTheme(_ theme: PresentationTheme) {
        guard self.theme !== theme else { return }
        self.theme = theme
        self.dotNode.image = generateImage(CGSize(width: 11.0, height: 11.0), rotatedContext: { size, context in
            let rect = CGRect(origin: .zero, size: size)
            context.clear(rect)
            context.setFillColor(theme.chatList.itemBackgroundColor.cgColor)
            context.fillEllipse(in: rect)
            context.setFillColor(theme.chatList.onlineDotColor.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
        })
    }

    private func refreshSubscription(force: Bool = false) {
        let peerId: PeerId?
        if WhitegramAppearancePolicy.current.isEnabled("showOnlineDotInChats"),
           let user = self.peer as? TelegramUser, user.botInfo == nil,
           user.firstName != nil || user.lastName != nil,
           user.id != self.context.account.peerId, !isServicePeer(user) {
            peerId = user.id
        } else {
            peerId = nil
        }
        guard force || peerId != self.subscribedPeerId else { return }
        self.subscriptionRevision &+= 1
        let revision = self.subscriptionRevision
        self.presenceDisposable.set(nil)
        self.subscribedPeerId = peerId
        self.setOnline(false, animated: false)
        guard let peerId else { return }

        var first = true
        self.presenceDisposable.set((self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Presence(id: peerId))
        |> deliverOnMainQueue
        |> mapToSignal { presence -> Signal<Bool, NoError> in
            guard let presence, case let .present(until) = presence.status else { return .single(false) }
            let now = Int64(Date().timeIntervalSince1970)
            guard Int64(until) > now else { return .single(false) }
            return .single(true)
            |> then(.single(false) |> delay(Double(Int64(until) - now), queue: Queue.mainQueue()))
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { [weak self] online in
            guard let self, self.subscriptionRevision == revision else { return }
            self.setOnline(online, animated: !first)
            first = false
        }))
    }

    private func setOnline(_ online: Bool, animated: Bool) {
        if online == self.isOnline && animated { return }
        self.isOnline = online
        self.dotNode.layer.removeAnimation(forKey: "transform.scale")
        self.dotNode.layer.removeAnimation(forKey: "opacity")
        guard animated else {
            self.dotNode.isHidden = !online
            return
        }
        self.dotNode.isHidden = false
        self.dotNode.layer.animateScale(from: online ? 0.001 : 1.0, to: online ? 1.0 : 0.001, duration: 0.2, removeOnCompletion: false, completion: { [weak self] finished in
            guard let self, finished else { return }
            self.dotNode.isHidden = !self.isOnline
        })
        self.dotNode.layer.animateAlpha(from: online ? 0.0 : 1.0, to: online ? 1.0 : 0.0, duration: 0.2, removeOnCompletion: false)
    }
}
