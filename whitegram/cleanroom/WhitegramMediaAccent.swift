import Foundation
import UIKit
import TelegramCore

/// Per-render media colors; the shared Telegram theme is never modified.
public enum WhitegramMediaAccent {
    public static func mediaColors(_ colors: PresentationThemePartedColors) -> PresentationThemePartedColors {
        guard WhitegramAppearancePolicy.current.isEnabled("neutralMediaAccent") else { return colors }
        let text = colors.primaryTextColor
        return colors.withUpdated(
            mediaActiveControlColor: text,
            mediaInactiveControlColor: text.withAlphaComponent(text.cgColor.alpha * 0.4),
            fileTitleColor: text
        )
    }

    /// Translucent selected/unselected fills keep the text readable on either bubble direction.
    public static func reactionColors(_ colors: PresentationThemeBubbleColorComponents, text: UIColor, enabled: Bool) -> PresentationThemeBubbleColorComponents {
        guard enabled else { return colors }
        return colors.withUpdated(
            reactionInactiveBackground: text.withAlphaComponent(text.cgColor.alpha * 0.1),
            reactionInactiveForeground: text,
            reactionActiveBackground: text.withAlphaComponent(text.cgColor.alpha * 0.25),
            reactionActiveForeground: text,
            reactionInactiveMediaPlaceholder: text.withAlphaComponent(text.cgColor.alpha * 0.3),
            reactionActiveMediaPlaceholder: text.withAlphaComponent(text.cgColor.alpha * 0.6)
        )
    }
}
