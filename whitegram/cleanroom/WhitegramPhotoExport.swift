import Foundation
import UIKit

public enum WhitegramPhotoExport {
    public static func resizedUploadImage(_ image: UIImage, size: CGSize) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1.0, size.height >= 1.0,
              size.width <= 4096.0, size.height <= 4096.0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
