import Foundation
import UIKit
import Display
import TelegramCore

/// Kept in TelegramPresentationData so low-level bubble nodes need no new module dependency.
public struct WhitegramBubbleAppearance: Equatable {
    public let fillOpacity: CGFloat
    public let borderEnabled: Bool
    public let borderRGB: UInt32?
    public let glass: WhitegramGlassSettings

    private static let outlines: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        return cache
    }()

    public init(settings: WhitegramAppearanceSettings, glass: WhitegramGlassSettings = .current) {
        self.glass = glass
        self.fillOpacity = self.glass.hasBubbleSurface ? 0.0 : CGFloat(settings.bubbleFillOpacity)
        self.borderEnabled = settings.isEnabled(.messageBorderEnabled)
        self.borderRGB = settings.borderRGB
    }

    public static var current: WhitegramBubbleAppearance {
        return WhitegramBubbleAppearance(settings: .current)
    }

    public func outlineImage(incoming: Bool, neighbors: MessageBubbleImageNeighbors, graphics: PrincipalThemeEssentialGraphics) -> UIImage? {
        guard self.borderEnabled else { return nil }
        let corners = graphics.whitegramBubbleCorners
        let maxRadius = corners.mainRadius
        let minRadius = (corners.mergeBubbleCorners && maxRadius >= 10.0) ? corners.auxiliaryRadius : maxRadius
        let automaticColor = incoming ? graphics.whitegramIncomingBorderColor : graphics.whitegramOutgoingBorderColor
        let rgb = self.borderRGB ?? automaticColor.rgb
        let key = "\(incoming):\(neighbors):\(maxRadius):\(minRadius):\(rgb):\(UIScreenScale)" as NSString
        if let image = Self.outlines.object(forKey: key) { return image }
        let image = messageBubbleImage(
            maxCornerRadius: maxRadius, minCornerRadius: minRadius, incoming: incoming,
            fillColor: .clear, strokeColor: UIColor(rgb: rgb), neighbors: neighbors,
            shadow: nil, wallpaper: .color(0xffffff), knockout: false,
            extendedEdges: true, onlyOutline: true
        )
        Self.outlines.setObject(image, forKey: key)
        return image
    }
}
