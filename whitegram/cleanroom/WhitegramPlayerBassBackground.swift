import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

enum WhitegramPlayerBassEvents {
    static let levels = ValuePipe<(Int64, Float)>()
}

final class WhitegramPlayerBassBackground: UIView {
    private var disposable: Disposable?
    private var settingsObserver: NSObjectProtocol?
    private var enabled = false
    private var decay: SwiftSignalKit.Timer?

    init(accountId: Int64) {
        super.init(frame: .zero)
        self.backgroundColor = .black
        self.alpha = 0
        self.isUserInteractionEnabled = false
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.reload()
        self.settingsObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main, using: { [weak self] _ in self?.reload() })
        self.disposable = (WhitegramPlayerBassEvents.levels.signal() |> deliverOnMainQueue).start(next: { [weak self] id, level in
            guard id == accountId, let self else { return }
            self.setLevel(level)
        })
    }

    required init?(coder: NSCoder) { preconditionFailure() }

    deinit {
        self.disposable?.dispose()
        self.decay?.invalidate()
        if let observer = self.settingsObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        self.enabled = WhitegramPlayerSettings(values: WhitegramPreferences.values()).bassEffect
        if !self.enabled { self.setLevel(0) }
    }

    private func setLevel(_ level: Float) {
        let level = self.enabled && !UIAccessibility.isReduceMotionEnabled && level.isFinite ? min(1, max(0, level)) : 0
        UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: { self.alpha = CGFloat(level) * 0.45 })
        self.decay?.invalidate()
        self.decay = nil
        if level > 0 {
            let timer = SwiftSignalKit.Timer(timeout: 0.2, repeat: false, completion: { [weak self] in self?.setLevel(0) }, queue: .mainQueue())
            self.decay = timer
            timer.start()
        }
    }
}
