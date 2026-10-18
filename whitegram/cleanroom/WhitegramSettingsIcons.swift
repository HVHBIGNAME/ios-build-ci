import Foundation
import UIKit
import TelegramCore

// Original 3.1.1 TelegramUI helper 0x8f0d64: named Whitegram image or stock fallback.
func whitegramSettingsIcon(_ name: String, fallback: UIImage?) -> UIImage? {
    guard WhitegramIconSettings.current.customSettingsIcons else {
        return fallback
    }
    return UIImage(named: name, in: Bundle.main, compatibleWith: nil) ?? fallback
}
