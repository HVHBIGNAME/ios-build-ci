import Foundation
import UIKit
import UniformTypeIdentifiers
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore

private final class WhitegramVirusTotalCoordinator: NSObject, WhitegramServiceListActions, UIDocumentPickerDelegate {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private var observers: [NSObjectProtocol] = []
    private var hash: String
    private var file: WhitegramVirusTotalFileHash?
    private var result: WhitegramVirusTotalLookupResult?
    private var task: WhitegramServiceTask?
    private var taskId: UUID?
    private var configuration: [Bool]?
    private var refreshing = false
    private var status = ""
    private var connection = "Not checked in this session."

    init(sha256: String?) {
        self.hash = sha256 ?? ""
        super.init()
        self.presenter.changed = { [weak self] in self?.refresh() }
        self.observers.append(whitegramServiceObserve(WhitegramPreferences.updatedNotification) { [weak self] _ in self?.refresh() })
        self.observers.append(whitegramServiceObserve(WhitegramServiceCredential.updatedNotification) { [weak self] notification in
            guard let self = self, notification.object as? WhitegramServiceCredential == .virusTotal else { return }
            self.cancel(message: "API key changed. Operation cancelled.")
            self.result = nil
            self.connection = "Not checked for this API key."
            if !WhitegramPreferences.set("", for: "virusTotalConnectionStatus") { self.status = WhitegramServiceError.preferences.localizedDescription }
            self.refresh()
        })
        self.observers.append(whitegramServiceObserve(UIApplication.didEnterBackgroundNotification) { [weak self] _ in self?.cancel() })
        self.observers.append(whitegramServiceObserve(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.refresh() })
        self.refresh()
    }

    deinit {
        self.task?.cancel()
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func disappeared() {
        if !self.presenter.isPresenting { self.cancel() }
    }

    func refresh() {
        guard !self.refreshing else { return }
        self.refreshing = true
        defer { self.refreshing = false }
        let enabled = WhitegramPreferences.bool("virusTotalEnabled")
        var keyAvailable = false
        var credentialError: WhitegramServiceError?
        do { keyAvailable = try WhitegramServiceCredentials.vault.token(for: .virusTotal) != nil }
        catch { credentialError = error as? WhitegramServiceError ?? .preferences }
        let configuration = [enabled, keyAvailable]
        if let previous = self.configuration, previous != configuration {
            self.cancel(message: "Configuration changed. Operation cancelled.")
            self.connection = "Not checked for these settings."
            self.result = nil
        }
        self.configuration = configuration
        let idle = self.task == nil && !self.presenter.isPresenting
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ section: Int32, _ content: WhitegramServiceEntry.Content) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("enabled", 0, .toggle("Enable VirusTotal Lookups", enabled, idle))
        add("key", 0, .disclosure("API Key", keyAvailable ? "•••••••• · Keychain" : "Not set", idle))
        add("removeKey", 0, .action("Remove API Key", idle && (keyAvailable || credentialError != nil)))
        if let error = credentialError { add("credentialError", 0, .text(error.localizedDescription)) }
        add("network", 0, .text("Queries https://www.virustotal.com/api/v3/files/{sha256} using system network settings. Lookups are spaced at least 15 seconds apart. Your account's daily or other API quotas still apply."))
        add("hashHeader", 1, .header("FILE HASH"))
        add("chooseFile", 1, .action("Choose File to Hash…", idle))
        add("editHash", 1, .action("Enter SHA-256…", idle))
        add("hashInfo", 1, .text("A selected file is read locally in 1 MiB chunks, up to 512 MiB. Look Up SHA-256 sends only its hash. File contents and the local filename are never uploaded."))
        if let file = self.file {
            add("file", 1, .text(String(file.fileName.prefix(256)) + " · " + ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)))
        }
        if !self.hash.isEmpty {
            add("hash", 1, .text("SHA-256\n" + String(self.hash.prefix(128))))
            add("copyHash", 1, .action("Copy SHA-256", idle))
        }
        add("lookup", 1, .action("Look Up SHA-256", idle && enabled && keyAvailable && !self.hash.isEmpty))
        if self.task != nil { add("cancel", 1, .action("Cancel Operation", true)) }
        add("connection", 1, .text("Connection: " + self.connection))
        if !self.status.isEmpty { add("status", 1, .text(self.status)) }
        if let result = self.result {
            add("reportHeader", 2, .header("EXISTING REPORT"))
            switch result {
            case .notFound:
                add("unknown", 2, .text("Unknown — VirusTotal has no report for this hash (HTTP 404). The file has not been classified as clean or submitted for analysis."))
            case let .found(report):
                add("summary", 2, .text(report.summary))
                add("analysisDate", 2, .text(report.analysisDate.map { "Last analysis: " + whitegramServiceDate($0) } ?? "Last analysis date was not provided."))
                if let statistics = report.statistics, !statistics.isEmpty {
                    for category in statistics.keys.sorted() {
                        if let count = statistics[category] { add("stat:" + category, 2, .text(category + ": \(count)")) }
                    }
                } else {
                    add("noStats", 2, .text("Analysis statistics were not provided."))
                }
                add("engines", 2, .action("View Engine Results (\(report.engines.count))", idle))
                add("openReport", 2, .action("Open VirusTotal Report", idle))
                add("reportURL", 2, .text(report.reportURL.absoluteString))
            }
        }
        self.entries.set(rows)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.task == nil, !self.presenter.isPresenting else { return }
        self.status = WhitegramPreferences.set(enabled, for: "virusTotalEnabled") ? "Settings saved." : WhitegramServiceError.preferences.localizedDescription
        self.refresh()
    }

    func perform(_ id: String) {
        if id == "cancel" { self.cancel(); return }
        guard self.task == nil, !self.presenter.isPresenting else { return }
        switch id {
        case "key": self.editKey()
        case "removeKey":
            do { try WhitegramServiceCredentials.vault.remove(.virusTotal); self.status = "API key removed." }
            catch { self.status = (error as? WhitegramServiceError ?? .preferences).localizedDescription }
            self.refresh()
        case "chooseFile": self.chooseFile()
        case "editHash": self.editHash()
        case "copyHash": whitegramServiceCopy(self.hash); self.status = "Hash copied for one hour."; self.refresh()
        case "lookup": self.lookup()
        case "engines":
            if case let .found(report)? = self.result { self.checkPresentation(self.presenter.showText(title: "VirusTotal Engine Results", text: whitegramVirusTotalReportText(report))) }
        case "openReport": self.openReport()
        default: break
        }
    }

    private func editKey() {
        self.checkPresentation(self.presenter.editValue(title: "VirusTotal API Key", message: "Paste a new API key. It is stored in this device's Keychain. A hash lookup is required to check API access.",
            placeholder: "API key", secure: true, saved: { [weak self] value in
                do { try WhitegramServiceCredentials.vault.save(value, for: .virusTotal); self?.status = "API key saved in Keychain." }
                catch { self?.status = (error as? WhitegramServiceError ?? .preferences).localizedDescription }
                self?.refresh()
            }))
    }

    private func editHash() {
        self.checkPresentation(self.presenter.editValue(title: "SHA-256", message: "Enter a 64-character hexadecimal SHA-256 hash. This does not submit a file.",
            value: self.hash, placeholder: "SHA-256", saved: { [weak self] value in
                do {
                    self?.hash = try WhitegramVirusTotalWire.validatedHash(value)
                    self?.file = nil
                    self?.result = nil
                    self?.status = "Hash ready. Tap Look Up SHA-256 to query VirusTotal."
                } catch {
                    self?.status = (error as? WhitegramServiceError ?? .invalidHash).localizedDescription
                }
                self?.refresh()
            }))
    }

    private func chooseFile() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.data"], in: .open)
        }
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        self.checkPresentation(self.presenter.present(picker))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.presenter.close()
        self.status = "File selection cancelled."
        self.refresh()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.presenter.close()
        guard urls.count == 1, let url = urls.first else { self.status = "Choose exactly one file."; self.refresh(); return }
        let id = UUID()
        self.taskId = id
        self.hash = ""
        self.file = nil
        self.result = nil
        self.status = "Reading the selected file and computing SHA-256…"
        self.task = WhitegramVirusTotalFileHasher.hash(url: url, progress: { [weak self] count, total in
            guard let self = self, self.taskId == id else { return }
            self.status = "Hashing: \(ByteCountFormatter.string(fromByteCount: count, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            self.refresh()
        }, completion: { [weak self] result in
            guard let self = self, self.taskId == id else { return }
            self.task = nil
            self.taskId = nil
            switch result {
            case let .success(file):
                self.file = file
                self.hash = file.sha256
                self.status = "SHA-256 computed locally. Tap Look Up SHA-256 to query the report."
            case let .failure(error): self.status = error.localizedDescription
            }
            self.refresh()
        })
        self.refresh()
    }

    private func lookup() {
        let id = UUID()
        self.taskId = id
        self.result = nil
        self.status = "Looking up the existing hash report…"
        self.task = whitegramLookupVirusTotalHash(self.hash) { [weak self] result in
            guard let self = self, self.taskId == id else { return }
            self.task = nil
            self.taskId = nil
            switch result {
            case let .success(value):
                self.result = value
                switch value {
                case .found:
                    self.status = "Existing report received."
                    self.recordConnection("Report received")
                case .notFound:
                    self.status = "Unknown hash. No file was uploaded."
                    self.recordConnection("VirusTotal responded: hash not found (HTTP 404)")
                }
            case let .failure(error):
                self.status = error.localizedDescription
                switch error {
                case let .httpStatus(status): self.recordConnection("VirusTotal returned HTTP \(status)")
                case .network, .timedOut, .redirectRefused: self.recordConnection("Connection failed")
                case .invalidResponse, .responseTooLarge: self.recordConnection("Response could not be read")
                default: break
                }
            }
            self.refresh()
        }
        self.refresh()
    }

    private func recordConnection(_ text: String) {
        self.connection = text + " at " + whitegramServiceDate(Date()) + "."
        if !WhitegramPreferences.set(self.connection, for: "virusTotalConnectionStatus") {
            self.status += " Could not save the connection status."
        }
    }

    private func openReport() {
        guard case let .found(report)? = self.result else { return }
        UIApplication.shared.open(report.reportURL, options: [:], completionHandler: { [weak self] opened in
            if !opened { self?.status = "The system could not open the report URL."; self?.refresh() }
        })
    }

    private func cancel(message: String = "Operation cancelled.") {
        guard let task = self.task else { return }
        self.taskId = nil
        self.task = nil
        task.cancel()
        self.status = message
        self.refresh()
    }

    private func checkPresentation(_ success: Bool) {
        if !success { self.status = "The screen is not ready to present a picker or editor. Try again after the transition."; self.refresh() }
    }
}

private func whitegramVirusTotalReportText(_ report: WhitegramVirusTotalReport) -> String {
    var lines = [report.summary, "SHA-256: " + report.sha256]
    if let date = report.analysisDate { lines.append("Last analysis: " + whitegramServiceDate(date)) }
    lines.append("\nStatistics")
    if let statistics = report.statistics, !statistics.isEmpty {
        for category in statistics.keys.sorted() {
            if let count = statistics[category] { lines.append(category + ": \(count)") }
        }
    } else {
        lines.append("Not provided")
    }
    lines.append("\nEngines (\(report.engines.count))")
    for engine in report.engines {
        lines.append("\n" + engine.name + " — " + engine.category)
        lines.append("Result: " + (engine.result ?? "No detection name provided"))
        if let version = engine.version { lines.append("Version: " + version) }
        if let update = engine.update { lines.append("Engine update: " + update) }
    }
    if report.engines.isEmpty { lines.append("No engine results were provided.") }
    lines.append("\n" + report.reportURL.absoluteString)
    return lines.joined(separator: "\n")
}

public func whitegramVirusTotalController(context: AccountContext) -> ViewController {
    return whitegramVirusTotalController(context: context, sha256: nil)
}

/// Opens a prefilled hash for review; a lookup still requires the user's explicit tap.
public func whitegramVirusTotalController(context: AccountContext, sha256: String?) -> ViewController {
    let coordinator = WhitegramVirusTotalCoordinator(sha256: sha256)
    let controller = whitegramServiceListController(context: context, title: "VirusTotal", entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.refresh() }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
