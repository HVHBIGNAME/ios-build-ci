import Foundation
import UIKit
import Display
import ComponentFlow
import ComponentDisplayAdapters

/// Background-only material; all interactive content remains in its native owning node.
public final class WhitegramGlassSurfaceView: UIView {
    private struct Parameters {
        let size: CGSize
        let cornerRadius: CGFloat
        let isDark: Bool
        let color: UIColor
        let area: WhitegramGlassSettings.Area
        let isAllowed: Bool
    }

    public var enabledUpdated: ((Bool) -> Void)?
    private var glassView: GlassBackgroundView?
    private var blurView: WhitegramGlassReplacementView?
    private var parameters: Parameters?
    private var observers: [NSObjectProtocol] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.clipsToBounds = true
        for name in [WhitegramGlassSettings.updatedNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, let parameters = self.parameters else { return }
                self.update(size: parameters.size, cornerRadius: parameters.cornerRadius, isDark: parameters.isDark, color: parameters.color, area: parameters.area, isAllowed: parameters.isAllowed, transition: .immediate)
            })
        }
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { for observer in self.observers { NotificationCenter.default.removeObserver(observer) } }

    public func update(size: CGSize, cornerRadius: CGFloat, isDark: Bool, color: UIColor, area: WhitegramGlassSettings.Area, isAllowed: Bool = true, transition: ContainedViewLayoutTransition) {
        let settings = WhitegramGlassSettings.current
        self.parameters = Parameters(size: size, cornerRadius: cornerRadius, isDark: isDark, color: color, area: area, isAllowed: isAllowed)
        let material = isAllowed && size.width > 0.0 && size.height > 0.0 ? settings.material(for: area) : nil
        self.isHidden = material == nil
        self.enabledUpdated?(material != nil)
        guard let material else {
            self.glassView?.removeFromSuperview()
            self.glassView = nil
            self.blurView?.removeFromSuperview()
            self.blurView = nil
            return
        }
        let transition: ContainedViewLayoutTransition = UIAccessibility.isReduceMotionEnabled ? .immediate : transition
        transition.updateCornerRadius(layer: self.layer, cornerRadius: cornerRadius)
        if #available(iOS 13.0, *) { self.overrideUserInterfaceStyle = isDark ? .dark : .light }
        switch material {
        case .glass:
            self.blurView?.removeFromSuperview()
            self.blurView = nil
            let view: GlassBackgroundView
            if let current = self.glassView { view = current }
            else {
                view = GlassBackgroundView(frame: .zero)
                self.glassView = view
                self.addSubview(view)
            }
            view.whitegramSolidColor = color
            transition.updateFrame(view: view, frame: CGRect(origin: .zero, size: size))
            view.update(size: size, cornerRadius: cornerRadius, isDark: isDark, tintColor: .init(kind: .panel), transition: ComponentTransition(transition))
        case .blur:
            self.glassView?.removeFromSuperview()
            self.glassView = nil
            let view: WhitegramGlassReplacementView
            if let current = self.blurView { view = current }
            else {
                view = WhitegramGlassReplacementView(frame: .zero)
                self.blurView = view
                self.addSubview(view)
            }
            transition.updateFrame(view: view, frame: CGRect(origin: .zero, size: size))
            view.update(size: size, shape: .roundedRect(cornerRadius: cornerRadius), isDark: isDark,
                tintColor: .init(kind: .clear), solidColor: color,
                mode: UIAccessibility.isReduceTransparencyEnabled ? .color : .blur,
                transition: ComponentTransition(transition))
        }
    }
}
