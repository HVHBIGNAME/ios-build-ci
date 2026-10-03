import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramCore
import SwiftSignalKit
import AccountContext
import AvatarComponent
import ChatListHeaderComponent

final class WhitegramAccountSwitcher {
    private let context: AccountContext
    private let disposable = MetaDisposable()
    private var observer: NSObjectProtocol?
    private var nextContext: AccountContext?
    private var nextPeer: EnginePeer?

    init(context: AccountContext, updated: @escaping () -> Void) {
        self.context = context
        observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { _ in updated() }
        disposable.set((context.sharedContext.activeAccountContexts
        |> mapToSignal { _, accounts, _ -> Signal<(AccountContext, EnginePeer?)?, NoError> in
            guard let nextId = WhitegramAccountSelection.next(current: context.account.id.int64, orderedIds: accounts.map { $0.0.int64 }, enabled: true), let next = accounts.first(where: { $0.0.int64 == nextId })?.1 else { return .single(nil) }
            return next.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: next.account.peerId))
            |> map { peer in (next, peer) }
        }
        |> deliverOnMainQueue).start(next: { [weak self] value in
            self?.nextContext = value?.0
            self?.nextPeer = value?.1
            updated()
        }))
    }

    deinit { disposable.dispose(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    var button: AnyComponentWithIdentity<NavigationButtonComponentEnvironment>? {
        guard WhitegramPreferences.bool("accountSwitcherEnabled"), let nextContext, let nextPeer else { return nil }
        return AnyComponentWithIdentity(id: "whitegram-account-switcher", component: AnyComponent(WhitegramAccountSwitcherComponent(context: nextContext, peer: nextPeer, pressed: { [weak self] in
            guard let self, WhitegramPreferences.bool("accountSwitcherEnabled"), self.nextContext?.account.id == nextContext.account.id else { return }
            self.context.sharedContext.switchToAccount(id: nextContext.account.id, fromSettingsController: nil, withChatListController: nil)
        })))
    }
}

private final class WhitegramAccountSwitcherComponent: Component {
    typealias EnvironmentType = NavigationButtonComponentEnvironment
    let context: AccountContext
    let peer: EnginePeer
    let pressed: () -> Void
    init(context: AccountContext, peer: EnginePeer, pressed: @escaping () -> Void) { self.context = context; self.peer = peer; self.pressed = pressed }
    static func ==(lhs: WhitegramAccountSwitcherComponent, rhs: WhitegramAccountSwitcherComponent) -> Bool { return lhs.context === rhs.context && lhs.peer == rhs.peer }

    final class View: HighlightTrackingButton {
        private let avatar = ComponentView<Empty>()
        private let arrow = UILabel()
        private var component: WhitegramAccountSwitcherComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addTarget(self, action: #selector(pressed), for: .touchUpInside)
            arrow.text = "⇄"
            arrow.font = Font.semibold(12)
            arrow.textAlignment = .center
            arrow.isUserInteractionEnabled = false
            addSubview(arrow)
            isAccessibilityElement = true
            accessibilityTraits = .button
            highligthedChanged = { [weak self] value in self?.alpha = value ? 0.6 : 1.0 }
        }
        required init?(coder: NSCoder) { return nil }
        @objc private func pressed() { component?.pressed() }

        func update(component: WhitegramAccountSwitcherComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationButtonComponentEnvironment>, transition: ComponentTransition) -> CGSize {
            self.component = component
            let theme = environment[NavigationButtonComponentEnvironment.self].value.theme
            let size = CGSize(width: 44, height: availableSize.height)
            let avatarSize = avatar.update(transition: transition, component: AnyComponent(AvatarComponent(context: component.context, theme: theme, peer: component.peer, size: CGSize(width: 28, height: 28))), environment: {}, containerSize: CGSize(width: 28, height: 28))
            if let view = avatar.view {
                if view.superview == nil { insertSubview(view, belowSubview: arrow); view.isUserInteractionEnabled = false }
                view.frame = CGRect(origin: CGPoint(x: 8, y: floor((size.height - avatarSize.height) / 2)), size: avatarSize)
            }
            arrow.textColor = theme.rootController.navigationBar.accentTextColor
            arrow.backgroundColor = theme.rootController.navigationBar.opaqueBackgroundColor
            arrow.layer.cornerRadius = 7
            arrow.clipsToBounds = true
            arrow.frame = CGRect(x: 27, y: size.height / 2 + 3, width: 14, height: 14)
            accessibilityLabel = component.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.hasPrefix("ru") } ? "Переключиться: \(component.peer.debugDisplayTitle)" : "Switch to \(component.peer.debugDisplayTitle)"
            return size
        }
    }
    func makeView() -> View { return View(frame: .zero) }
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationButtonComponentEnvironment>, transition: ComponentTransition) -> CGSize { return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition) }
}
