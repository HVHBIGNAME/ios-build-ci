import Foundation
import Postbox
import SwiftSignalKit

public enum WhitegramContentMedia {
    private static let queue = Queue(name: "WhitegramContentMedia")

    private static func shouldRetain(_ message: Message) -> Bool {
        guard message.flags.contains(.Incoming), message.containsSecretMedia || message.minAutoremoveOrClearTimeout == viewOnceTimeout else { return false }
        return WhitegramContentSettings.saveProtectedContent || (message.minAutoremoveOrClearTimeout == viewOnceTimeout && WhitegramContentSettings.saveViewOnceMedia)
    }

    private static func retainedResource(_ media: Media) -> (MediaResource, WhitegramContentMediaStore.Kind)? {
        if let image = media as? TelegramMediaImage, let largest = largestImageRepresentation(image.representations) {
            return (largest.resource, .image)
        }
        if let file = media as? TelegramMediaFile, file.isVideo || file.isInstantVideo || file.isVoice || file.mimeType.hasPrefix("video/") {
            return (file.resource, file.isVoice ? .audio : .video)
        }
        return nil
    }

    /// Observe the viewer's normal download; the caller cancels when its viewer/playlist closes.
    public static func observeViewedMedia(message: Message, mediaBox: MediaBox) -> Signal<Never, NoError> {
        guard shouldRetain(message) else { return .complete() }
        let resources = message.media.compactMap { retainedResource($0)?.0 }
        guard !resources.isEmpty else { return .complete() }
        let signals = resources.map { resource -> Signal<Void, NoError> in
            return mediaBox.resourceData(resource)
            |> filter { $0.complete && $0.size > 0 }
            |> take(1)
            |> deliverOn(queue)
            |> map { _ in captureAvailable(message: message, mediaBox: mediaBox) }
        }
        return combineLatest(signals) |> ignoreValues
    }

    /// No fetch is started here. Only an incoming timed resource already complete in
    /// this account's MediaBox can be retained. Receipt/expiry operations run afterwards.
    static func captureBeforeConsumption(postbox: Postbox, messageId: MessageId) -> Signal<Void, NoError> {
        guard WhitegramContentSettings.saveProtectedContent || WhitegramContentSettings.saveViewOnceMedia else { return .complete() }
        return postbox.transaction { $0.getMessage(messageId) }
        |> deliverOn(queue)
        |> mapToSignal { message -> Signal<Void, NoError> in
            guard let message else { return .complete() }
            captureAvailable(message: message, mediaBox: postbox.mediaBox)
            return .complete()
        }
    }

    public static func captureAvailable(message: Message, mediaBox: MediaBox) {
        guard shouldRetain(message) else { return }
        let viewOnce = message.minAutoremoveOrClearTimeout == viewOnceTimeout
        let root = WhitegramContentMediaStore.root(mediaBoxPath: mediaBox.basePath)
        var captured: [WhitegramContentMediaStore.Entry] = []
        for (offset, media) in message.media.enumerated() {
            guard let (resource, kind) = retainedResource(media) else { continue }
            guard let path = mediaBox.completedResourcePath(resource) else { continue }
            let id = "\(message.id.peerId.toInt64())_\(message.id.namespace)_\(message.id.id)_\(offset)"
            do {
                captured.append(try WhitegramContentMediaStore.capture(root: root, candidate: .init(id: id, source: URL(fileURLWithPath: path), kind: kind, timestamp: message.timestamp, viewOnce: viewOnce)))
            } catch {
                WhitegramContentMediaStore.recordError(root: root, message: "Could not retain media: \(error.localizedDescription)")
            }
        }
        if !captured.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: WhitegramContentMediaStore.updated, object: root)
                NotificationCenter.default.post(name: WhitegramContentMediaStore.captured, object: root, userInfo: ["entries": captured])
            }
        }
    }
}
