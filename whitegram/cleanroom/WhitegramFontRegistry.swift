import Foundation
import CoreFoundation
import UIKit
import CoreText

public struct WhitegramFontRecord: Equatable {
    public let name: String
    public let displayName: String
    public let fileName: String?

    public init(name: String, displayName: String, fileName: String? = nil) {
        self.name = name
        self.displayName = displayName
        self.fileName = fileName
    }
}

public struct WhitegramFontRemoval {
    public let names: [String]
    public let warning: String?
}

private struct WhitegramFontRegistryError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return self.message
    }
}

/// Lives in Display: primitive mirrors are the hot path, with read-only recovery of older settings.
public final class WhitegramFontRegistry {
    public static let shared = WhitegramFontRegistry()

    private struct CacheKey: Hashable {
        let name: String
        let size: CGFloat
        let weight: String
        let traits: Int32
    }

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private var prepared = false
    private var files: [String: [WhitegramFontRecord]] = [:]
    private var registeredFiles = Set<String>()
    private var blockedNames = Set<String>()
    private var issues: [String: String] = [:]
    private var cache: [CacheKey: UIFont] = [:]
    private var activeName: String?
    private var unmirroredSelection: (enabled: Bool, name: String)?
    private var generation = 0
    private var observer: NSObjectProtocol?

    private init() {
        self.observer = NotificationCenter.default.addObserver(forName: Notification.Name("WhitegramSettingsStateUpdated"), object: nil, queue: nil) { [weak self] _ in
            self?.invalidateCache()
        }
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func library() -> (fonts: [WhitegramFontRecord], warnings: [String], revision: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.prepareLocked()
        return (
            self.files.values.flatMap { $0 }.sorted { $0.name < $1.name },
            self.issues.keys.sorted().compactMap { self.issues[$0] },
            self.generation
        )
    }

    public func invalidateCache() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.cache.removeAll()
        self.activeName = nil
        self.unmirroredSelection = nil
        self.generation += 1
    }

    /// Called before Telegram's system-font cache, never from a UIFont swizzle.
    public func font(size: CGFloat, design: Font.Design, weight: Font.Weight, width: Font.Width, traits: Font.Traits) -> UIFont? {
        guard design != .monospace, design != .camera, width == .standard,
              !traits.contains(.monospacedNumbers) else {
            return nil
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        let name = self.selectedNameLocked()
        if self.activeName != name {
            self.cache.removeAll()
            self.activeName = name
        }
        guard let name = name, !name.isEmpty else {
            return nil
        }
        self.prepareLocked()
        return self.fontLocked(named: name, size: size, weight: weight, traits: traits)
    }

    private func selectedNameLocked() -> String? {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "wg_customFontEnabled").map { Self.boolean($0) }
        let name = defaults.object(forKey: "wg_customFontName") as? String
        // An explicit off/reset always wins, even if the older snapshot had a selection.
        if enabled == false || name == "" {
            return nil
        }
        if enabled == true, let name = name {
            return name
        }
        if self.unmirroredSelection == nil {
            let saved = Self.fontSettings(defaults.data(forKey: "WhitegramSettingsState.v1"))
            let legacy = Self.fontSettings(defaults.data(forKey: "WhitegramPrivacySettings.v1"))
            self.unmirroredSelection = (
                Self.boolean(saved["customFontEnabled"] ?? legacy["customFontEnabled"]),
                ((saved["customFontName"] ?? legacy["customFontName"]) as? String) ?? ""
            )
        }
        guard enabled ?? self.unmirroredSelection?.enabled ?? false else {
            return nil
        }
        return name ?? self.unmirroredSelection?.name
    }

    private static func fontSettings(_ data: Data?) -> [String: Any] {
        guard let data = data else {
            return [:]
        }
        do {
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            NSLog("Whitegram: could not recover saved font selection (%@)", String(describing: type(of: error)))
            return [:]
        }
    }

    private static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    public func previewFont(named name: String, size: CGFloat, weight: Font.Weight = .regular, traits: Font.Traits = []) -> UIFont? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.prepareLocked()
        return self.fontLocked(named: name, size: size, weight: weight, traits: traits)
    }

    /// The caller retains security-scoped access while this synchronous operation runs.
    public func importFont(from source: URL) throws -> [WhitegramFontRecord] {
        return try self.importFonts(from: [source])
    }

    public func importFonts(from sources: [URL]) throws -> [WhitegramFontRecord] {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.prepareLocked()
        guard !sources.isEmpty, sources.count <= 512 else {
            throw WhitegramFontRegistryError(message: "Choose between 1 and 512 font files.")
        }
        let directory = try self.directory(create: true)
        var pending: [(url: URL, records: [WhitegramFontRecord])] = []
        var copied: [URL] = []
        var registered: [URL] = []
        do {
            var names = Set<String>()
            for source in sources {
                _ = try self.records(at: source)
                let fileName = UUID().uuidString + "." + source.pathExtension.lowercased()
                let destination = directory.appendingPathComponent(fileName, isDirectory: false)
                try self.fileManager.copyItem(at: source, to: destination)
                copied.append(destination)
                let records = try self.records(at: destination)
                for record in records {
                    if !names.insert(record.name).inserted || UIFont(name: record.name, size: 16.0) != nil {
                        throw WhitegramFontRegistryError(message: "\(record.displayName) is already available or occurs twice in this import. Choose it from the font list or remove the duplicate file. If you just removed it, restart Whitegram before importing it again.")
                    }
                }
                pending.append((destination, records))
            }
            for entry in pending {
                try self.register(entry.url)
                registered.append(entry.url)
            }
        } catch {
            var cleanupIssues: [String] = []
            for url in registered.reversed() {
                var releaseError: Unmanaged<CFError>?
                if !CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &releaseError) {
                    self.blockedNames.formUnion(pending.filter { $0.url == url }.flatMap { $0.records.map { $0.name } })
                    cleanupIssues.append("iOS may retain an unused font until restart.")
                }
                if let releaseError { _ = releaseError.takeRetainedValue() }
            }
            for url in copied {
                do { try self.fileManager.removeItem(at: url) }
                catch { cleanupIssues.append(error.localizedDescription) }
            }
            if cleanupIssues.isEmpty { throw error }
            throw WhitegramFontRegistryError(message: ([error.localizedDescription] + cleanupIssues).joined(separator: " "))
        }
        for entry in pending {
            self.files[entry.url.lastPathComponent] = entry.records
            self.registeredFiles.insert(entry.url.lastPathComponent)
            self.blockedNames.subtract(entry.records.map { $0.name })
        }
        self.cache.removeAll()
        self.generation += 1
        return pending.flatMap { $0.records }
    }

    public func removeFont(fileName: String) throws -> WhitegramFontRemoval {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.prepareLocked()
        let directory = try self.directory(create: false)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\\"),
              url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              ["ttf", "otf"].contains(url.pathExtension.lowercased()) else {
            throw WhitegramFontRegistryError(message: "Invalid font-library filename.")
        }
        let records = self.files[fileName] ?? []
        self.cache.removeAll()
        var warning: String?
        var unregistered = false
        if self.registeredFiles.contains(fileName) {
            var error: Unmanaged<CFError>?
            unregistered = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
            let detail = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
            if !unregistered {
                warning = "Removed from the library; iOS will release the loaded font after restart. " + (detail ?? "The font is still in use.")
            }
        }
        do {
            if self.fileManager.fileExists(atPath: url.path) {
                try self.fileManager.removeItem(at: url)
            }
        } catch {
            if unregistered {
                do {
                    try self.register(url)
                } catch let restoreError {
                    self.registeredFiles.remove(fileName)
                    self.blockedNames.formUnion(records.map { $0.name })
                    self.issues[fileName] = "\(fileName): \(restoreError.localizedDescription)"
                    throw WhitegramFontRegistryError(message: "\(error.localizedDescription) The font also could not be re-registered: \(restoreError.localizedDescription)")
                }
            }
            throw error
        }
        self.files.removeValue(forKey: fileName)
        self.issues.removeValue(forKey: fileName)
        self.registeredFiles.remove(fileName)
        // UIKit may retain a font after unregister reports 'in use'. Never return it again.
        self.blockedNames.formUnion(records.map { $0.name })
        self.generation += 1
        return WhitegramFontRemoval(names: records.map { $0.name }, warning: warning)
    }

    private func directory(create: Bool) throws -> URL {
        guard let support = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw WhitegramFontRegistryError(message: "Application Support is unavailable.")
        }
        let directory = support.appendingPathComponent("Whitegram", isDirectory: true).appendingPathComponent("Fonts", isDirectory: true)
        if create {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory
    }

    private func records(at url: URL) throws -> [WhitegramFontRecord] {
        guard url.isFileURL, ["ttf", "otf"].contains(url.pathExtension.lowercased()) else {
            throw WhitegramFontRegistryError(message: "Choose a TrueType (.ttf) or OpenType (.otf) font file.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 32 * 1024 * 1024 else {
            throw WhitegramFontRegistryError(message: "Font imports must be regular files between 1 byte and 32 MiB.")
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw WhitegramFontRegistryError(message: "This file does not contain a readable TrueType or OpenType font.")
        }
        var result: [WhitegramFontRecord] = []
        for descriptor in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, !name.isEmpty else {
                throw WhitegramFontRegistryError(message: "The font has no PostScript name.")
            }
            if !result.contains(where: { $0.name == name }) {
                let displayName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String) ?? name
                result.append(WhitegramFontRecord(name: name, displayName: displayName, fileName: url.lastPathComponent))
            }
        }
        return result
    }

    private func register(_ url: URL) throws {
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        let detail = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
        if !registered {
            throw WhitegramFontRegistryError(message: detail ?? "Core Text could not register the font.")
        }
    }

    private func prepareLocked() {
        guard !self.prepared else {
            return
        }
        self.prepared = true
        self.recoverOriginalLibraryLocked()
        do {
            let directory = try self.directory(create: false)
            guard self.fileManager.fileExists(atPath: directory.path) else {
                return
            }
            let urls = try self.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                let fileName = url.lastPathComponent
                do {
                    let records = try self.records(at: url)
                    self.files[fileName] = records
                    try self.register(url)
                    self.registeredFiles.insert(fileName)
                } catch {
                    if self.files[fileName] == nil {
                        self.files[fileName] = [WhitegramFontRecord(name: "unreadable:" + fileName, displayName: "Unreadable font (\(fileName))", fileName: fileName)]
                    }
                    self.blockedNames.formUnion((self.files[fileName] ?? []).map { $0.name })
                    self.issues[fileName] = "\(fileName): \(error.localizedDescription)"
                }
            }
        } catch {
            self.issues["library"] = error.localizedDescription
        }
    }

    private func recoverOriginalLibraryLocked() {
        let defaults = UserDefaults.standard
        let values = Self.fontSettings(defaults.data(forKey: "WhitegramSettingsState.v1"))
        let history = WhitegramFontHistory.read(values: values, defaults: defaults)
        guard let documents = self.fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        var fileNames = Set(history.compactMap { $0["fileName"] })
        if values["fontHistory"] == nil, let selected = defaults.string(forKey: "wg_customFontFileName"), !selected.isEmpty {
            fileNames.insert(selected)
        }
        for fileName in fileNames.sorted() where WhitegramFontHistory.isFontFileName(fileName) {
            let source = documents.appendingPathComponent(fileName, isDirectory: false)
            guard self.fileManager.fileExists(atPath: source.path) else { continue }
            do {
                let destination = try self.directory(create: true).appendingPathComponent(fileName, isDirectory: false)
                guard !self.fileManager.fileExists(atPath: destination.path) else { continue }
                _ = try self.records(at: source)
                try self.fileManager.copyItem(at: source, to: destination)
            } catch {
                self.issues["legacy:" + fileName] = "Could not recover \(fileName): \(error.localizedDescription)"
            }
        }
    }

    private func fontLocked(named name: String, size: CGFloat, weight: Font.Weight, traits: Font.Traits) -> UIFont? {
        guard !self.blockedNames.contains(name), size.isFinite, size > 0.0 else {
            return nil
        }
        let key = CacheKey(name: name, size: size, weight: weight.key, traits: traits.rawValue)
        if let cached = self.cache[key] {
            return cached
        }
        guard let base = UIFont(name: name, size: size) else {
            return nil
        }
        let wantsItalic = traits.contains(.italic) || base.fontDescriptor.symbolicTraits.contains(.traitItalic)
        var font = base
        if weight != .regular || wantsItalic != base.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            var attributes = base.fontDescriptor.fontAttributes
            // A fixed PostScript name/face would override family weight and italic matching.
            attributes.removeValue(forKey: .name)
            attributes.removeValue(forKey: .face)
            attributes[.family] = base.familyName
            var fontTraits = (attributes[.traits] as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
            var symbolic = base.fontDescriptor.symbolicTraits
            if wantsItalic {
                symbolic.insert(.traitItalic)
            }
            if weight != .regular {
                fontTraits[.weight] = weight.weight.rawValue
                if weight.weight.rawValue >= UIFont.Weight.bold.rawValue {
                    symbolic.insert(.traitBold)
                } else {
                    symbolic.remove(.traitBold)
                }
            }
            fontTraits[.symbolic] = symbolic.rawValue
            attributes[.traits] = fontTraits
            font = UIFont(descriptor: UIFontDescriptor(fontAttributes: attributes), size: size)
            guard font.familyName == base.familyName,
                  !wantsItalic || font.fontDescriptor.symbolicTraits.contains(.traitItalic) else {
                return nil
            }
            if weight != .regular {
                let resolvedTraits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
                let resolvedWeight = (resolvedTraits?[.weight] as? NSNumber)?.doubleValue ?? (font.fontDescriptor.symbolicTraits.contains(.traitBold) ? Double(UIFont.Weight.bold.rawValue) : 0.0)
                let requestedWeight = Double(weight.weight.rawValue)
                if (requestedWeight > 0.0 && resolvedWeight <= 0.0) || (requestedWeight < 0.0 && resolvedWeight >= 0.0) {
                    return nil
                }
            }
        }
        if self.cache.count >= 512 {
            self.cache.removeAll(keepingCapacity: true)
        }
        self.cache[key] = font
        return font
    }
}
