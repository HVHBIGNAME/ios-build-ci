import Foundation
import UIKit
import QuartzCore

/// Decoration for the existing saved-music button. Its title, marquee and
/// navigation action continue to be supplied by PeerInfoHeaderNode.
final class WhitegramPlayerProfileCard: UIView {
    private let gradient = CAGradientLayer()
    private let wave = CAShapeLayer()
    private let secondaryWave = CAShapeLayer()
    private var motionObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.layer.cornerRadius = 12
        self.clipsToBounds = true
        self.gradient.startPoint = CGPoint(x: 0, y: 0)
        self.gradient.endPoint = CGPoint(x: 1, y: 1)
        self.layer.addSublayer(self.gradient)
        self.layer.addSublayer(self.wave)
        self.layer.addSublayer(self.secondaryWave)
        self.motionObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in self?.updateAnimations() })
    }

    required init?(coder: NSCoder) { preconditionFailure() }
    deinit {
        if let observer = self.motionObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func update(accent: UIColor, overlay: Bool) {
        self.backgroundColor = overlay ? UIColor.black.withAlphaComponent(0.22) : accent.withAlphaComponent(0.08)
        self.gradient.colors = [accent.withAlphaComponent(0.08).cgColor, accent.withAlphaComponent(0.22).cgColor, accent.withAlphaComponent(0.08).cgColor]
        self.wave.fillColor = accent.withAlphaComponent(0.13).cgColor
        self.secondaryWave.fillColor = accent.withAlphaComponent(0.08).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.gradient.frame = self.bounds.insetBy(dx: -self.bounds.width * 0.2, dy: 0)
        let width = self.bounds.width
        let height = self.bounds.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -width * 0.2, y: height * 0.65))
        path.addCurve(to: CGPoint(x: width * 1.2, y: height * 0.45), controlPoint1: CGPoint(x: width * 0.2, y: -height * 0.2), controlPoint2: CGPoint(x: width * 0.6, y: height * 1.3))
        path.addLine(to: CGPoint(x: width * 1.2, y: height))
        path.addLine(to: CGPoint(x: -width * 0.2, y: height))
        path.close()
        for layer in [self.wave, self.secondaryWave] {
            layer.frame = self.bounds
            layer.path = path.cgPath
        }
        CATransaction.commit()
        self.updateAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updateAnimations()
    }

    private func updateAnimations() {
        guard self.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            for layer in [self.gradient, self.wave, self.secondaryWave] { layer.removeAllAnimations() }
            return
        }
        for (layer, key, duration, offset) in [(self.gradient as CALayer, "wgMusicGradientDrift", 5.0, 0.08), (self.wave as CALayer, "wgMusicWaveDrift", 3.8, 0.12), (self.secondaryWave as CALayer, "wgMusicWaveDriftSecondary", 6.0, -0.1)] {
            if layer.animation(forKey: key) == nil {
                let animation = CABasicAnimation(keyPath: "transform.translation.x")
                animation.fromValue = -self.bounds.width * CGFloat(offset)
                animation.toValue = self.bounds.width * CGFloat(offset)
                animation.duration = duration
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: key)
            }
        }
    }
}
