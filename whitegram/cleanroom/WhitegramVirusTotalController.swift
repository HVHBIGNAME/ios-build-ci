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
    private var sha256: String
    private var target: WhitegramVirusTotalTarget?
    private let messageTargets: [WhitegramVirusTotalTarget]
    private var file: WhitegramVirusTotalFileHash?
    private var result: WhitegramVirusTotalTargetLookupResult?
    private var task: WhitegramServiceTask?
    private var taskId: UUID?
    private var configuration: [Bool]?
    private var refreshing = false
    private var status = ""
    private var connection = "Not checked in this session."

    init(sha256: String? = nil, targets: [WhitegramVirusTotalTarget] = []) {
        self.sha256 = sha256 ?? ""
        var seen = Set<WhitegramVirusTotalTarget>()
        self.messageTargets = Array(targets.compactMap { try? $0.validated() }.filter { seen.insert($0).inserted }.prefix(WhitegramVirusTotalTargets.maximumTargets))
        if let sha256 = sha256 {
            self.target = try? WhitegramVirusTotalTarget.file(sha256: sha256).validated()
        } else {
            self.target = self.messageTargets.first
            if case let .file(hash)? = self.target { self.sha256 = hash }
        }
        super.init()
        if sha256 != nil && self.target == nil { self.status = WhitegramServiceError.invalidHash.localizedDescription }
        if !self.messageTargets.isEmpty { self.status = "Review the selected target, then tap Look Up to send it to VirusTotal." }
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
        add("network", 0, .text("Queries VirusTotal's official API v3 file, URL and IP address reports using system network settings. All target types share the 15-second request spacing and your account's API quotas."))
        add("hashHeader", 1, .header("TARGET"))
        add("chooseFile", 1, .action("Choose File to Hash…", idle))
        add("editHash", 1, .action("Enter SHA-256…", idle))
        add("editTarget", 1, .action("Enter URL or IP Address…", idle))
        if self.messageTargets.count > 1 { add("chooseTarget", 1, .disclosure("Message Targets", "\(self.messageTargets.count)", idle)) }
        add("hashInfo", 1, .text("A selected file is read locally in 1 MiB chunks, up to 512 MiB. Look Up SHA-256 sends only its hash. File contents and the local filename are never uploaded."))
        add("targetPrivacy", 1, .text("URL/IP lookup sends the selected indicator, including URL query parameters, to VirusTotal. VirusTotal may retain or analyze queried indicators. Review it before sending. Other message text is not sent."))
        if let file = self.file {
            add("file", 1, .text(String(file.fileName.prefix(256)) + " · " + ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)))
        }
        if let target = self.target {
            add("target", 1, .text(target.title + "\n" + String(target.value.prefix(500)) + (target.value.count > 500 ? "…" : "")))
            add("reviewTarget", 1, .action("Review Full Target", idle))
            if case .file = target { add("copyHash", 1, .action("Copy SHA-256", idle)) }
        }
        add("lookup", 1, .action("Look Up " + (self.target?.title ?? "Report"), idle && enabled && keyAvailable && self.target != nil))
        if self.task != nil { add("cancel", 1, .action("Cancel Operation", true)) }
        add("connection", 1, .text("Connection: " + self.connection))
        if !self.status.isEmpty { add("status", 1, .text(self.status)) }
        if let result = self.result {
            add("reportHeader", 2, .header("EXISTING REPORT"))
            switch result {
            case .notFound:
                add("unknown", 2, .text("Unknown — VirusTotal returned no report for this target (HTTP 404). This is not a clean verdict."))
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
        case "editTarget": self.editTarget()
        case "chooseTarget": self.chooseTarget()
        case "reviewTarget":
            if let target = self.target { self.checkPresentation(self.presenter.showText(title: target.title + " to Look Up", text: target.value)) }
        case "copyHash": whitegramServiceCopy(self.sha256); self.status = "Hash copied for one hour."; self.refresh()
        case "lookup": self.lookup()
        case "engines":
            if case let .found(report)? = self.result { self.checkPresentation(self.presenter.showText(title: "VirusTotal Engine Results", text: whitegramVirusTotalReportText(report))) }
        case "openReport": self.openReport()
        default: break
        }
    }

    private func editKey() {
        self.checkPresentation(self.presenter.editValue(title: "VirusTotal API Key", message: "Paste a new API key. It is stored in this device's Keychain. An explicit target lookup checks API access.",
            placeholder: "API key", secure: true, saved: { [weak self] value in
                do { try WhitegramServiceCredentials.vault.save(value, for: .virusTotal); self?.status = "API key saved in Keychain." }
                catch { self?.status = (error as? WhitegramServiceError ?? .preferences).localizedDescription }
                self?.refresh()
            }))
    }

    private func editHash() {
        self.checkPresentation(self.presenter.editValue(title: "SHA-256", message: "Enter a 64-character hexadecimal SHA-256 hash. This does not submit a file.",
            value: self.sha256, placeholder: "SHA-256", saved: { [weak self] value in
                do {
                    self?.select(try WhitegramVirusTotalTarget.file(sha256: value).validated())
                } catch {
                    self?.status = (error as? WhitegramServiceError ?? .invalidHash).localizedDescription
                }
                self?.refresh()
            }))
    }

    private func editTarget() {
        let value: String
        switch self.target {
        case let .url(url)?, let .ipAddress(url)?: value = url
        default: value = ""
        }
        self.checkPresentation(self.presenter.editValue(title: "URL or IP Address", message: "Enter an explicit http:// or https:// URL, IPv4 or IPv6 address. Credentials in URLs and IPv6 zone identifiers are not accepted. URL fragments are omitted. Nothing is sent until Look Up is tapped.",
            value: value, placeholder: "https://example.com/ or 203.0.113.1", saved: { [weak self] value in
                do { self?.select(try WhitegramVirusTotalTarget.parse(value)) }
                catch { self?.status = (error as? WhitegramServiceError ?? .invalidTarget).localizedDescription }
                self?.refresh()
            }))
    }

    private func chooseTarget() {
        let alert = UIAlertController(title: "Message Targets", message: "Choose one target to review. Each lookup is a separate explicit action.", preferredStyle: .alert)
        for target in self.messageTargets {
            alert.addAction(UIAlertAction(title: target.title + ": " + String(target.value.prefix(100)), style: .default, handler: { [weak self] _ in
                self?.presenter.close()
                self?.select(target)
                self?.refresh()
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in self?.presenter.close() }))
        self.checkPresentation(self.presenter.present(alert))
    }

    private func select(_ target: WhitegramVirusTotalTarget) {
        self.target = target
        self.sha256 = ""
        if case let .file(hash) = target { self.sha256 = hash }
        self.file = nil
        self.result = nil
        self.status = "Target ready. Tap Look Up " + target.title + " to query VirusTotal."
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
        self.sha256 = ""
        self.target = nil
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
                self.sha256 = file.sha256
                self.target = .file(sha256: file.sha256)
                self.status = "SHA-256 computed locally. Tap Look Up SHA-256 to query the report."
            case let .failure(error): self.status = error.localizedDescription
            }
            self.refresh()
        })
        self.refresh()
    }

    private func lookup() {
        guard let target = self.target else { return }
        let id = UUID()
        self.taskId = id
        self.result = nil
        self.status = "Looking up the selected " + target.title.lowercased() + " report…"
        self.task = whitegramLookupVirusTotalTarget(target) { [weak self] result in
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
                    self.status = "Unknown target. No report was returned."
                    self.recordConnection("VirusTotal responded: target not found (HTTP 404)")
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

private func whitegramVirusTotalReportText(_ report: WhitegramVirusTotalTargetReport) -> String {
    var lines = [report.summary, report.target.title + ": " + report.target.value]
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
    return whitegramVirusTotalController(context: context, coordinator: coordinator)
}

/// Reviews extracted targets. Opening this screen and choosing a target never submits a lookup.
public func whitegramVirusTotalController(context: AccountContext, targets: [WhitegramVirusTotalTarget]) -> ViewController {
    let coordinator = WhitegramVirusTotalCoordinator(targets: targets)
    return whitegramVirusTotalController(context: context, coordinator: coordinator)
}

private func whitegramVirusTotalController(context: AccountContext, coordinator: WhitegramVirusTotalCoordinator) -> ViewController {
    let controller = whitegramServiceListController(context: context, title: "VirusTotal", entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.refresh() }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
