import Foundation
import UIKit

private final class WhitegramRAMUsageLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 10.0, height: size.height + 4.0)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 5.0, dy: 2.0))
    }
}

final class WhitegramRAMUsageOverlay {
    private let label = WhitegramRAMUsageLabel()
    private var timer: Foundation.Timer?
    private var observers: [NSObjectProtocol] = []
    private var statusBarHeight: CGFloat
    private var leftInset: CGFloat

    init(hostView: UIView, statusBarHeight: CGFloat, leftInset: CGFloat) {
        self.statusBarHeight = statusBarHeight
        self.leftInset = leftInset
        self.label.font = .monospacedDigitSystemFont(ofSize: 9.0, weight: .bold)
        self.label.textAlignment = .center
        self.label.textColor = UIColor { traits in
            return traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.92) : UIColor.black.withAlphaComponent(0.88)
        }
        self.label.backgroundColor = .clear
        self.label.isUserInteractionEnabled = false
        self.label.layer.zPosition = 2000.0
        hostView.addSubview(self.label)
        for name in ["WGShowRAMUsageChanged", "WhitegramSettingsStateUpdated"] {
            self.observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        self.refresh()
    }

    deinit {
        self.timer?.invalidate()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.label.removeFromSuperview()
    }

    func updateLayout(statusBarHeight: CGFloat, leftInset: CGFloat) {
        self.statusBarHeight = statusBarHeight
        self.leftInset = leftInset
        self.layoutLabel()
    }

    private func refresh() {
        let enabled = UserDefaults.standard.bool(forKey: "wg_showRAMUsage")
        self.label.isHidden = !enabled
        if enabled {
            self.sample()
            if self.timer == nil {
                let timer = Foundation.Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.sample()
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func sample() {
        guard let bytes = WhitegramRAMUsage.physicalFootprint() else { return }
        self.label.text = WhitegramRAMUsage.text(physicalFootprint: bytes)
        self.layoutLabel()
    }

    private func layoutLabel() {
        guard !self.label.isHidden else { return }
        self.label.frame = WhitegramRAMUsage.frame(labelSize: self.label.intrinsicContentSize,
            statusBarHeight: self.statusBarHeight, leftInset: self.leftInset,
            scale: self.label.window?.screen.scale ?? UIScreen.main.scale)
    }
}
