import Foundation
import UIKit
import AppBundle

enum WhitegramIconPackPresentationCache {
    private static let lock = NSRecursiveLock()
    private static var revision: UInt = 0
    private static var images: [String: UIImage] = [:]

    static func image(_ name: String, create: () -> UIImage?) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        let current = WGBundleOverrideRevision()
        if revision != current {
            images.removeAll()
            revision = current
        }
        if let image = images[name] { return image }
        let image = create()
        images[name] = image
        return image
    }
}
