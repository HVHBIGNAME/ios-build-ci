import Foundation
import UIKit
import ImageIO
import AccountContext
import Display
import SwiftSignalKit
import TelegramCore

private final class WhitegramProfileImageViewer: UIViewController {
    private let image: UIImage
    init(image: UIImage) { self.image = image; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)])
    }
}

private final class WhitegramProfilePhotosCoordinator: NSObject, WhitegramServiceListActions, UIDocumentPickerDelegate {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private let userId: Int64
    private let service: WhitegramProfilePhotosService
    private var slots: [Int] = []
    private var task: WhitegramBackendTask?
    private var selectedSlot: Int?
    private var publishWall = true
    private var localWallpaper: Data?
    private var publicationPreference: Bool?
    private var busy = false
    private var error: String?
    private var localError: String?

    init(context: AccountContext, userId: Int64) {
        self.userId = userId
        service = WhitegramProfilePhotosService(client: WhitegramBackendClient(userId: context.account.peerId.id._internalGetInt64Value()))
        super.init()
        refresh()
    }
    deinit { task?.cancel() }
    func setEnabled(_ enabled: Bool) {}

    func load() {
        guard !busy else { return }
        loadLocalWallpaper()
        busy = true; refresh()
        task = service.slots(userId: userId) { [weak self] result in
            guard let self else { return }
            busy = false; task = nil
            switch result {
            case let .success(slots): self.slots = slots; error = nil
            case let .failure(error): self.error = error.localizedDescription
            }
            refresh()
        }
    }

    private func loadLocalWallpaper() {
        guard userId == service.client.userId else { return }
        do {
            let store = try WhitegramProfilePhotoWallStore()
            localWallpaper = try store.load(userId: userId)
            publicationPreference = store.savedPublicationPreference(userId: userId)
            localError = nil
        } catch { localError = error.localizedDescription; localWallpaper = nil }
    }

    private func show(slot: Int?) {
        busy = true; refresh()
        task = service.photo(userId: userId, slot: slot) { [weak self] result in
            guard let self else { return }
            busy = false; task = nil
            do {
                let data = try result.get()
                let image = try Self.image(data: data)
                let viewer = WhitegramProfileImageViewer(image: image)
                viewer.title = slot.map { "Photo \($0 + 1)" } ?? "Photo Wall"
                let navigation = UINavigationController(rootViewController: viewer)
                viewer.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(close))
                if !presenter.present(navigation) { error = "The image viewer could not be opened." }
            } catch { self.error = error.localizedDescription }
            refresh()
        }
    }

    @objc private func close() { presenter.close() }

    private static func image(data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else {
            throw WhitegramBackendError.invalidResponse
        }
        return UIImage(cgImage: image)
    }

    private func choosePhoto(slot: Int?, publish: Bool = true) {
        selectedSlot = slot
        publishWall = publish
        let picker = UIDocumentPickerViewController(documentTypes: ["public.image"], in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        if !presenter.present(picker) { error = "The image picker could not be opened."; refresh() }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { presenter.close() }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        presenter.close()
        guard let url = urls.first, userId == service.client.userId else { return }
        busy = true; error = nil; refresh()
        let slot = selectedSlot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let input = try FileHandle(forReadingFrom: url)
                defer { input.closeFile() }
                let data = input.readData(ofLength: 20 * 1024 * 1024 + 1)
                guard data.count <= 20 * 1024 * 1024 else { throw WhitegramBackendError.responseTooLarge }
                let image = try Self.image(data: data)
                guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw WhitegramBackendError.invalidRequest }
                DispatchQueue.main.async { self?.upload(jpeg, slot: slot) }
            } catch {
                DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription; self?.refresh() }
            }
        }
    }

    private func upload(_ jpeg: Data?, slot: Int?) {
        do {
            if slot == nil, let jpeg {
                try WhitegramProfilePhotoWallStore().save(jpeg, userId: userId)
                localWallpaper = jpeg
                if !publishWall { busy = false; error = nil; refresh(); return }
            }
            task = try service.setPhoto(jpeg, slot: slot) { [weak self] result in
                guard let self else { return }
                busy = false; task = nil
                if case let .failure(error) = result { self.error = error.localizedDescription; refresh() }
                else {
                    do {
                        if slot == nil { try WhitegramProfilePhotoWallStore().confirmedPublication(jpeg != nil, userId: userId) }
                        error = nil; load()
                    } catch { self.error = error.localizedDescription; refresh() }
                }
            }
        } catch { busy = false; self.error = error.localizedDescription; refresh() }
    }

    private func confirmDelete(slot: Int?) {
        let alert = UIAlertController(title: "Delete public profile photo?", message: "This removes the photo from the Whitegram server.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.presenter.close() })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in self?.presenter.close(); self?.busy = true; self?.upload(nil, slot: slot) })
        if !presenter.present(alert) { error = "The confirmation could not be opened."; refresh() }
    }

    func perform(_ id: String) {
        guard !busy else { return }
        if id == "refresh" { load(); return }
        if id == "wall" { show(slot: nil); return }
        if id.hasPrefix("view:"), let slot = Int(id.dropFirst(5)) { show(slot: slot); return }
        guard userId == service.client.userId else { return }
        if id == "wallLocal" { choosePhoto(slot: nil, publish: false) }
        else if id == "wallUpload" {
            publishWall = true
            if let localWallpaper { busy = true; refresh(); upload(localWallpaper, slot: nil) }
            else { choosePhoto(slot: nil) }
        }
        else if id == "wallResetLocal" {
            do { try WhitegramProfilePhotoWallStore().removeLocal(userId: userId); localWallpaper = nil }
            catch { self.error = error.localizedDescription }
            refresh()
        }
        else if id == "wallDelete" { confirmDelete(slot: nil) }
        else if id.hasPrefix("upload:"), let slot = Int(id.dropFirst(7)) { choosePhoto(slot: slot) }
        else if id.hasPrefix("delete:"), let slot = Int(id.dropFirst(7)) { confirmDelete(slot: slot) }
    }

    private func refresh() {
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content, section: Int32 = 0) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("account", .text("Profile: \(userId). Uploaded photos are published to the original Whitegram service."))
        add("refresh", .action(busy ? "Working…" : "Refresh photos", !busy))
        for slot in 0..<3 {
            add("view:\(slot)", .action("View photo \(slot + 1)", !busy && slots.contains(slot)), section: 1)
            if userId == service.client.userId {
                add("upload:\(slot)", .action("Upload photo \(slot + 1)", !busy), section: 1)
                add("delete:\(slot)", .action("Delete photo \(slot + 1)", !busy && slots.contains(slot)), section: 1)
            }
        }
        add("wall", .action("View public photo wall", !busy), section: 2)
        if userId == service.client.userId {
            add("wallLocal", .action(WhitegramLocalization.string("s.profilePhotoWallpaper"), !busy), section: 2)
            add("wallLocalState", .text(localWallpaper == nil ? "No local wallpaper saved." : "Local wallpaper saved for this account."), section: 2)
            add("wallUpload", .action("Publish saved wallpaper", !busy), section: 2)
            add("wallDelete", .action("Delete public photo wall", !busy), section: 2)
            add("wallResetLocal", .action("Remove local wallpaper", !busy && localWallpaper != nil), section: 2)
            add("wallVisibility", .text("Saved publication preference: " + (publicationPreference.map { $0 ? "Public" : "Private" } ?? "Unknown") + ". View public photo wall to fetch the current server image."), section: 2)
        }
        if let error { add("error", .text(error), section: 3) }
        if let localError { add("localError", .text(localError), section: 3) }
        entries.set(rows)
    }
}

public func whitegramProfilePhotosController(context: AccountContext, userId: Int64) -> ViewController {
    let coordinator = WhitegramProfilePhotosCoordinator(context: context, userId: userId)
    let controller = whitegramServiceListController(context: context, title: WhitegramLocalization.string("s.profilePhotos"), entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.load() }
    return controller
}
