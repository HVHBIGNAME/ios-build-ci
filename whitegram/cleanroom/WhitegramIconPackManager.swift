import Foundation
import UIKit
import ImageIO
import AppBundle
import Display
import Svg
import TelegramCore
import ZipArchive

public final class WhitegramIconPackManager {
    public static let shared = WhitegramIconPackManager()
    public static let changedNotification = Notification.Name("WGIconPackChanged")

    public final class StagedPack {
        public let manifest: WhitegramIconPackManifest
        let directory: URL
        fileprivate var consumed = false
        init(manifest: WhitegramIconPackManifest, directory: URL) { self.manifest = manifest; self.directory = directory }
        deinit {
            if !self.consumed {
                do { try FileManager.default.removeItem(at: self.directory) }
                catch { NSLog("Whitegram: could not remove icon staging directory (%@)", String(describing: type(of: error))) }
            }
        }
    }

    private struct PackIndex {
        let manifest: WhitegramIconPackManifest
        let icons: [String: URL]
        let animations: [String: URL]
    }

    private let lock = NSRecursiveLock()
    private let files = FileManager.default
    private let cache = NSCache<NSString, UIImage>()
    private var active: PackIndex?
    private var selectionKey: String?
    private var started = false
    private var observer: NSObjectProtocol?
    private var screenScale: CGFloat = 2.0
    private var issue: String?

    private init() { self.cache.countLimit = 512 }
    deinit { if let observer = self.observer { NotificationCenter.default.removeObserver(observer) } }

    public var activeId: String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.active?.manifest.id
    }

    public var loadError: String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.issue
    }

    public func setUpAtLaunch() {
        precondition(Thread.isMainThread)
        self.lock.lock()
        if self.started { self.lock.unlock(); return }
        self.started = true
        self.screenScale = UIScreen.main.scale
        self.lock.unlock()
        self.reloadSelection()
        WGSetBundleImageOverrideResolver { [weak self] name, original in
            return self?.image(named: name, original: original)
        }
        WGSetBundleAnimationOverrideResolver { [weak self] name in
            return self?.animationPath(named: name)
        }
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.reloadSelection()
        }
    }

    private func directory() throws -> URL {
        guard let documents = self.files.urls(for: .documentDirectory, in: .userDomainMask).first else { throw WhitegramIconPackError("Documents is unavailable.") }
        return documents.appendingPathComponent("whitegram/iconpacks", isDirectory: true)
    }

    private func packURL(_ id: String) throws -> URL {
        guard WhitegramIconPackArchive.validRelativePath(id), !id.contains("/"), !id.hasPrefix(".") else { throw WhitegramIconPackError("Invalid icon pack identifier.") }
        return try self.directory().appendingPathComponent(id, isDirectory: true)
    }

    public func installedPacks() throws -> [WhitegramIconPackManifest] {
        self.lock.lock(); defer { self.lock.unlock() }
        let directory = try self.directory()
        guard self.files.fileExists(atPath: directory.path) else { return [] }
        let urls = try self.files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var result: [WhitegramIconPackManifest] = []
        for url in urls {
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            do { result.append(try self.index(at: url, id: url.lastPathComponent).manifest) }
            catch { throw WhitegramIconPackError("Could not read \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func reloadSelection() {
        self.lock.lock(); defer { self.lock.unlock() }
        let values = WhitegramPreferences.values()
        let id = (values["activeIconPackId"] ?? UserDefaults.standard.object(forKey: "wg_activeIconPackId")) as? String
        let revision = (values["appearanceAssetRevision"] as? String) ?? ""
        let selectionKey = (id ?? "") + ":" + revision
        if self.selectionKey == selectionKey { return }
        self.selectionKey = selectionKey
        self.cache.removeAllObjects()
        self.active = nil
        self.issue = nil
        if let id, !id.isEmpty {
            do { self.active = try self.index(at: self.packURL(id), id: id) }
            catch { self.issue = error.localizedDescription }
        }
        // Imports and resets can change selection without opening the manager.
        WGInvalidateBundleOverrides()
        self.notifyChanged()
    }

    public func activate(_ id: String?) throws {
        precondition(Thread.isMainThread)
        let index = try id.map { try self.index(at: self.packURL($0), id: $0) }
        let revision = UUID().uuidString
        guard WhitegramPreferences.update(["activeIconPackId": id ?? "", "appearanceAssetRevision": revision]) else {
            throw WhitegramIconPackError("Could not save the selected icon pack.")
        }
        self.lock.lock()
        self.active = index
        self.selectionKey = (id ?? "") + ":" + revision
        self.issue = nil
        self.cache.removeAllObjects()
        self.lock.unlock()
        WGInvalidateBundleOverrides()
        self.notifyChanged()
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }

    public func inspectArchive(at url: URL) throws -> StagedPack {
        guard WhitegramIconPackArchive.archiveExtensions.contains(url.pathExtension.lowercased()) else { throw WhitegramIconPackError("Choose a .wgicons or .zip file.") }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size > 0, size <= 64 * 1024 * 1024 else { throw WhitegramIconPackError("Icon archives must be regular files up to 64 MiB.") }
        guard let entries = SSZipArchive.getEntriesForFile(atPath: url.path) else { throw WhitegramIconPackError("The icon archive could not be opened.") }
        let plan = try WhitegramIconPackArchive.plan(entries: entries.map { .init(path: $0.path, size: UInt64($0.uncompressedSize)) })
        let parent = try self.directory()
        try self.files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let staging = parent.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try self.files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: nil)
        do {
            for entry in plan.files {
                let relative = String(entry.path.dropFirst(plan.prefix.count))
                let destination = staging.appendingPathComponent(relative, isDirectory: false)
                try self.files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                guard SSZipArchive.extractFileFromArchive(atPath: url.path, filePath: entry.path, toPath: destination.path) else { throw WhitegramIconPackError("Could not extract \(relative).") }
                let extracted = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard extracted.isRegularFile == true, extracted.isSymbolicLink != true, let extractedSize = extracted.fileSize, UInt64(extractedSize) == entry.size else { throw WhitegramIconPackError("An archive entry has an invalid size or file type.") }
            }
            let name = url.deletingPathExtension().lastPathComponent
            let index = try self.index(at: staging, id: WhitegramIconPackArchive.identifier(for: name), fallbackName: name)
            return StagedPack(manifest: index.manifest, directory: staging)
        } catch {
            do { try self.files.removeItem(at: staging) }
            catch let cleanupError { throw WhitegramIconPackError("\(error.localizedDescription) Staging cleanup failed: \(cleanupError.localizedDescription)") }
            throw error
        }
    }

    public func install(_ staged: StagedPack) throws {
        precondition(Thread.isMainThread)
        guard !staged.consumed else { throw WhitegramIconPackError("This preview has already been installed.") }
        let destination = try self.packURL(staged.manifest.id)
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".backup-" + UUID().uuidString, isDirectory: true)
        let replacing = self.files.fileExists(atPath: destination.path)
        if replacing { try self.files.moveItem(at: destination, to: backup) }
        do {
            try self.files.moveItem(at: staged.directory, to: destination)
            do { try self.activate(staged.manifest.id) }
            catch {
                try self.files.moveItem(at: destination, to: staged.directory)
                throw error
            }
        } catch {
            if replacing { try self.files.moveItem(at: backup, to: destination) }
            throw error
        }
        staged.consumed = true
        if replacing { try self.files.removeItem(at: backup) }
    }

    public func delete(_ id: String) throws {
        precondition(Thread.isMainThread)
        let source = try self.packURL(id)
        _ = try self.index(at: source, id: id)
        let trash = source.deletingLastPathComponent().appendingPathComponent(".removed-" + UUID().uuidString, isDirectory: true)
        try self.files.moveItem(at: source, to: trash)
        do {
            if self.activeId == id { try self.activate(nil) }
        } catch {
            try self.files.moveItem(at: trash, to: source)
            throw error
        }
        try self.files.removeItem(at: trash)
        self.notifyChanged()
    }

    private func index(at root: URL, id: String, fallbackName: String? = nil) throws -> PackIndex {
        let attributes = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw WhitegramIconPackError("Invalid icon pack directory.") }
        let iconsRoot = root.appendingPathComponent("icons", isDirectory: true)
        let iconAttributes = try iconsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard iconAttributes.isDirectory == true, iconAttributes.isSymbolicLink != true else { throw WhitegramIconPackError("Invalid icons directory.") }
        guard let iterator = self.files.enumerator(at: iconsRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw WhitegramIconPackError("The pack has no icons directory.") }
        var icons: [String: URL] = [:]
        var animations: [String: URL] = [:]
        var count = 0
        var bytes: UInt64 = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw WhitegramIconPackError("Icon packs cannot contain symbolic links.") }
            guard values.isRegularFile == true else { continue }
            count += 1
            guard count <= 4096, let size = values.fileSize, size >= 0, UInt64(size) <= WhitegramIconPackArchive.maximumFileBytes else { throw WhitegramIconPackError("The installed pack exceeds file limits.") }
            bytes += UInt64(size)
            guard bytes <= WhitegramIconPackArchive.maximumArchiveBytes else { throw WhitegramIconPackError("The installed pack exceeds size limits.") }
            let relative = String(url.path.dropFirst(iconsRoot.path.count + 1))
            guard WhitegramIconPackArchive.validRelativePath(relative) else { throw WhitegramIconPackError("Invalid icon path.") }
            let name = (relative as NSString).deletingPathExtension
            let ext = url.pathExtension.lowercased()
            if WhitegramIconPackArchive.iconExtensions.contains(ext) {
                if icons[name] == nil || ext == "svg" { icons[name] = url }
            } else if WhitegramIconPackArchive.animationExtensions.contains(ext) {
                if animations[name] == nil || ext == "json" { animations[name] = url }
            }
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestAttributes = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestAttributes.isRegularFile == true, manifestAttributes.isSymbolicLink != true, let manifestSize = manifestAttributes.fileSize, manifestSize <= 256 * 1024 else { throw WhitegramIconPackError("Invalid manifest file.") }
        let manifest = try WhitegramIconPackManifest(data: Data(contentsOf: manifestURL), id: id, fallbackName: fallbackName ?? id, iconCount: icons.count + animations.count)
        return PackIndex(manifest: manifest, icons: icons, animations: animations)
    }

    public func preview(_ staged: StagedPack) throws -> [(String, UIImage?, UIImage?)] {
        let index = try self.index(at: staged.directory, id: staged.manifest.id)
        return try index.icons.keys.sorted().prefix(8).map { name in
            let original = UIImage(named: name, in: getAppBundle(), compatibleWith: nil)
            guard let url = index.icons[name] else { throw WhitegramIconPackError("The preview icon is no longer available.") }
            let replacement = try self.render(url, manifest: index.manifest, size: original?.size ?? CGSize(width: 30.0, height: 30.0))
            return (name, original, replacement)
        }
    }

    private func image(named name: String, original: UIImage?) -> UIImage? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let active = self.active, let url = active.icons[name] else { return nil }
        let size = original?.size ?? CGSize(width: 30.0, height: 30.0)
        let key = "\(active.manifest.id):\(name):\(size.width):\(size.height):\(self.screenScale)" as NSString
        if let cached = self.cache.object(forKey: key) { return cached }
        do {
            let image = try self.render(url, manifest: active.manifest, size: size)
            self.cache.setObject(image, forKey: key)
            return image
        } catch {
            self.issue = "\(name): \(error.localizedDescription)"
            return nil
        }
    }

    private func animationPath(named name: String) -> String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.active?.animations[name]?.path
    }

    private func render(_ url: URL, manifest: WhitegramIconPackManifest, size: CGSize) throws -> UIImage {
        let size = CGSize(width: size.width * CGFloat(manifest.iconScale), height: size.height * CGFloat(manifest.iconScale))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size.width <= 1024, size.height <= 1024 else { throw WhitegramIconPackError("Invalid icon dimensions.") }
        let image: UIImage?
        switch url.pathExtension.lowercased() {
        case "svg":
            image = drawSvgImage(data: try Data(contentsOf: url), size: size, backgroundColor: .clear, foregroundColor: manifest.monochrome ? .black : nil, scale: self.screenScale, opaque: false)
        case "pdf":
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { throw WhitegramIconPackError("Invalid PDF icon.") }
            let format = UIGraphicsImageRendererFormat()
            format.scale = self.screenScale
            image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                context.cgContext.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
                context.cgContext.drawPDFPage(page)
            }
        case "png":
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * self.screenScale)] as CFDictionary) else { throw WhitegramIconPackError("Invalid PNG icon.") }
            let decoded = UIImage(cgImage: cgImage)
            let format = UIGraphicsImageRendererFormat()
            format.scale = self.screenScale
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let fitted = decoded.size.aspectFitted(size)
                decoded.draw(in: CGRect(x: (size.width - fitted.width) * 0.5, y: (size.height - fitted.height) * 0.5, width: fitted.width, height: fitted.height))
            }
        default:
            throw WhitegramIconPackError("Unsupported icon format.")
        }
        guard let image else { throw WhitegramIconPackError("The icon could not be rendered.") }
        return image.withRenderingMode(manifest.monochrome ? .alwaysTemplate : .alwaysOriginal)
    }
}
