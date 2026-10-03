import Foundation
import UIKit
import Display
import ComponentFlow

/// The replacement is a sibling of the native content view, so mode changes keep controls alive.
final class WhitegramGlassReplacementView: UIView {
    private struct Parameters: Equatable {
        let shape: GlassBackgroundView.Shape
        let isDark: Bool
        let tintColor: GlassBackgroundView.TintColor
        let solidColor: UIColor?
        let mode: WhitegramGlassSettings.Replacement
    }

    private let clippingView = UIView()
    private let clippingMask = SimpleShapeLayer()
    private let foregroundView = UIImageView()
    private let shadowView = UIImageView()
    private var blurView: UIVisualEffectView?
    private var legacyView: LegacyGlassView?
    private var parameters: Parameters?
    private var renderedRadii: GlassBackgroundView.CornerRadii?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.clippingView.layer.mask = self.clippingMask
        self.clippingMask.fillColor = UIColor.black.cgColor
        self.addSubview(self.shadowView)
        self.addSubview(self.clippingView)
        self.addSubview(self.foregroundView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func tint(_ value: GlassBackgroundView.TintColor, settings: WhitegramGlassSettings) -> GlassBackgroundView.TintColor {
        guard !settings.isSelected(.glassTinting) else { return value }
        switch value.kind {
        case .panel:
            return .init(kind: .clear, innerColor: value.innerColor, innerInset: value.innerInset)
        case let .custom(_, color):
            return .init(kind: .custom(style: .clear, color: color), innerColor: value.innerColor, innerInset: value.innerInset)
        case .clear:
            return value
        }
    }

    func update(size: CGSize, shape: GlassBackgroundView.Shape, isDark: Bool, tintColor: GlassBackgroundView.TintColor,
                solidColor: UIColor?, mode: WhitegramGlassSettings.Replacement, transition: ComponentTransition) {
        let parameters = Parameters(shape: shape, isDark: isDark, tintColor: tintColor, solidColor: solidColor, mode: mode)
        let changed = self.parameters != parameters
        let previousMode = self.parameters?.mode
        let previousDark = self.parameters?.isDark
        self.parameters = parameters
        if #available(iOS 13.0, *) { self.overrideUserInterfaceStyle = isDark ? .dark : .light }

        if previousMode != mode {
            self.blurView?.removeFromSuperview()
            self.blurView = nil
            self.legacyView?.removeFromSuperview()
            self.legacyView = nil
            self.clippingView.backgroundColor = .clear
            if mode == .telegram {
                let view = LegacyGlassView(frame: .zero)
                self.legacyView = view
                self.clippingView.addSubview(view)
            } else if mode == .blur {
                let view = UIVisualEffectView()
                self.blurView = view
                self.clippingView.addSubview(view)
            }
        }

        let frame = CGRect(origin: .zero, size: size)
        transition.setFrame(view: self.clippingView, frame: frame)
        transition.setFrame(layer: self.clippingMask, frame: frame)
        let radii: GlassBackgroundView.CornerRadii
        switch shape {
        case let .roundedRect(radius): radii = .init(radius: radius)
        case let .customRoundedRect(value): radii = value
        }
        let clamped = GlassBackgroundView.clampedCornerRadii(size: size, cornerRadii: radii)
        transition.setShapeLayerPath(layer: self.clippingMask, path: GlassBackgroundView.generateRoundedRectPath(size: size, cornerRadii: clamped))

        if let blurView = self.blurView {
            if previousMode != mode || previousDark != isDark {
                if #available(iOS 13.0, *) { blurView.effect = UIBlurEffect(style: .systemThinMaterial) }
                else { blurView.effect = UIBlurEffect(style: isDark ? .dark : .light) }
            }
            transition.setFrame(view: blurView, frame: frame)
        }

        let fillColor: UIColor
        let style: LegacyGlassView.Style
        switch tintColor.kind {
        case .panel:
            fillColor = isDark ? UIColor(white: 0.11, alpha: 0.85) : UIColor(white: 1.0, alpha: 0.7)
            style = .normal
        case .clear:
            fillColor = .clear
            style = .clear
        case let .custom(customStyle, color):
            fillColor = color
            switch customStyle {
            case .default: style = .normal
            case .clear: style = .clear
            }
        }
        if mode == .color {
            let fallback = isDark ? UIColor(white: 0.11, alpha: 1.0) : UIColor.white
            let custom: UIColor?
            if case let .custom(_, color) = tintColor.kind { custom = color } else { custom = nil }
            self.clippingView.backgroundColor = (solidColor ?? custom ?? fallback).withAlphaComponent(1.0)
        }
        if let view = self.legacyView {
            view.update(size: size, shape: shape, style: style, transition: transition)
            transition.setFrame(view: view, frame: frame)
        }
        self.foregroundView.isHidden = mode != .telegram
        self.shadowView.isHidden = mode != .telegram
        if mode == .telegram {
            // Corner clamping changes when a panel shrinks even if its requested radii stay equal.
            if changed || self.renderedRadii != clamped {
                self.renderedRadii = clamped
                self.foregroundView.image = GlassBackgroundView.generateLegacyGlassImage(cornerRadii: clamped, inset: 32.0,
                    borderWidthFactor: style == .clear ? 2.0 : 1.0, isDark: isDark, fillColor: fillColor)
                self.shadowView.image = GlassBackgroundView.generateLegacyShadowImage(cornerRadii: clamped)
            }
            transition.setFrame(view: self.foregroundView, frame: frame.insetBy(dx: -32.0, dy: -32.0))
            transition.setFrame(view: self.shadowView, frame: frame.insetBy(dx: -32.0, dy: -32.0))
        }
    }
}
