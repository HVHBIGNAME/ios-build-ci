import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private struct WhitegramRetainedMediaEntry: ItemListNodeEntry {
    let stableId: String
    let order: Int
    let title: String
    let detail: String
    let media: WhitegramContentMediaStore.Entry?
    var section: ItemListSectionId { return 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramRetainedMediaCoordinator
        if let media {
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: detail, sectionId: 0, style: .blocks, action: { coordinator.open(media) })
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(title), sectionId: 0, style: .blocks)
    }
}

private final class WhitegramRetainedMediaCoordinator {
    let root: URL
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ItemListController?
    private var revision = 0
    private var observer: NSObjectProtocol?
    private(set) var entries: [WhitegramContentMediaStore.Entry] = []
    private(set) var error: String?

    init(context: AccountContext) {
        root = WhitegramContentMediaStore.root(mediaBoxPath: context.account.postbox.mediaBox.basePath)
        observer = NotificationCenter.default.addObserver(forName: WhitegramContentMediaStore.updated, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? URL == self.root else { return }
            self.reload()
        }
        reload()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func reload() {
        let root = self.root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try WhitegramContentMediaStore.entries(root: root) }
            let exportError = WhitegramContentMediaStore.lastError(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(entries): self.entries = entries; self.error = exportError
                case let .failure(error): self.error = error.localizedDescription
                }
                self.revision += 1
                self.updates.set(self.revision)
            }
        }
    }

    func open(_ entry: WhitegramContentMediaStore.Entry) {
        guard let controller, controller.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: entry.fileName, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Export…", style: .default, handler: { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            do {
                let url = try WhitegramContentMediaStore.fileURL(root: self.root, entry: entry)
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = controller.view
                share.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
                controller.present(share, animated: true)
            } catch { WhitegramContentMediaStore.recordError(root: self.root, message: error.localizedDescription) }
        }))
        alert.addAction(UIAlertAction(title: "Delete Local Copy", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            do { try WhitegramContentMediaStore.remove(root: self.root, entry: entry) }
            catch { WhitegramContentMediaStore.recordError(root: self.root, message: error.localizedDescription) }
            self.reload()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        controller.present(alert, animated: true)
    }
}

public func whitegramContentMediaController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramRetainedMediaCoordinator(context: context)
    let state = combineLatest(context.sharedContext.presentationData, coordinator.updates.get())
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentation = ItemListPresentationData(data)
        let russian = data.strings.baseLanguageCode.hasPrefix("ru")
        var entries: [WhitegramRetainedMediaEntry] = []
        if let error = coordinator.error { entries.append(.init(stableId: "error", order: entries.count, title: error, detail: "", media: nil)) }
        for media in coordinator.entries {
            let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(media.timestamp)), dateStyle: .medium, timeStyle: .short)
            entries.append(.init(stableId: media.id, order: entries.count, title: "\(media.kind.rawValue.capitalized) · \(date)", detail: ByteCountFormatter.string(fromByteCount: media.byteCount, countStyle: .file), media: media))
        }
        if entries.isEmpty { entries.append(.init(stableId: "empty", order: 0, title: russian ? "Сохранённых файлов пока нет." : "No retained media yet.", detail: "", media: nil)) }
        return (ItemListControllerState(presentationData: presentation, title: .text(russian ? "Сохранённые медиа" : "Retained Media"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back), animateChanges: false), (ItemListNodeState(presentationData: presentation, entries: entries, style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: state)
    coordinator.controller = controller
    return controller
}
