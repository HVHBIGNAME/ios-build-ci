import Foundation
import Photos
import TelegramCore

/// Photos receives a retained local file, so expiry can proceed while authorization is shown.
public enum WhitegramContentPhotoExporter {
    private static var observer: NSObjectProtocol?
    private static var pending: [(URL, WhitegramContentMediaStore.Entry)] = []
    private static var active = false

    public static func install() {
        precondition(Thread.isMainThread)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: WhitegramContentMediaStore.captured, object: nil, queue: .main) { notification in
            guard WhitegramContentSettings.saveViewOnceMedia,
                let root = notification.object as? URL,
                let entries = notification.userInfo?["entries"] as? [WhitegramContentMediaStore.Entry] else { return }
            for entry in entries where entry.viewOnce && entry.kind != .audio && entry.photoLibraryIdentifier == nil {
                if !pending.contains(where: { $0.0 == root && $0.1.id == entry.id }) { pending.append((root, entry)) }
            }
            processNext()
        }
    }

    private static func processNext() {
        guard !active, !pending.isEmpty else { return }
        active = true
        let (root, entry) = pending.removeFirst()
        let finish: (String?) -> Void = { error in
            DispatchQueue.main.async {
                WhitegramContentMediaStore.recordError(root: root, message: error)
                active = false
                processNext()
            }
        }
        guard WhitegramContentSettings.saveViewOnceMedia else { finish(nil); return }
        do {
            if try WhitegramContentMediaStore.entries(root: root).contains(where: { $0.id == entry.id && $0.photoLibraryIdentifier != nil }) { finish(nil); return }
        } catch { finish(error.localizedDescription); return }
        let authorized: (PHAuthorizationStatus) -> Void = { status in
            guard WhitegramContentSettings.saveViewOnceMedia else { finish(nil); return }
            var allowed = status == .authorized
            if #available(iOS 14.0, *) { allowed = allowed || status == .limited }
            guard allowed else { finish("Photos access was not granted. The local copy is available in Retained Media."); return }
            do {
                let url = try WhitegramContentMediaStore.fileURL(root: root, entry: entry)
                var identifier: String?
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: entry.kind == .image ? .photo : .video, fileURL: url, options: nil)
                    identifier = request.placeholderForCreatedAsset?.localIdentifier
                }, completionHandler: { success, error in
                    guard success, let identifier else { finish(error?.localizedDescription ?? "Photos did not save the media. The local copy is retained."); return }
                    do {
                        try WhitegramContentMediaStore.markSavedToPhotos(root: root, entry: entry, identifier: identifier)
                        finish(nil)
                    } catch { finish(error.localizedDescription) }
                })
            } catch { finish(error.localizedDescription) }
        }
        if #available(iOS 14.0, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined { PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: authorized) } else { authorized(status) }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .notDetermined { PHPhotoLibrary.requestAuthorization(authorized) } else { authorized(status) }
        }
    }
}
