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
    private let context: AccountContext
    private let proxyConnection: WhitegramServiceProxyConnection
    private let attachment: EngineMessage?
    private var observers: [NSObjectProtocol] = []
    private var sha256: String
    private var target: WhitegramVirusTotalTarget?
    private let messageTargets: [WhitegramVirusTotalTarget]
    private var file: WhitegramVirusTotalFileHash?
    private var fileURL: URL?
    private var fileName: String?
    private var analysis: WhitegramVirusTotalAnalysis?
    private var analysisId: String?
    private var result: WhitegramVirusTotalTargetLookupResult?
    private var task: WhitegramServiceTask?
    private var taskId: UUID?
    private var configuration: [Bool]?
    private var refreshing = false
    private var status = ""
    private var connection = "Not checked in this session."

    init(context: AccountContext, sha256: String? = nil, targets: [WhitegramVirusTotalTarget] = [], attachment: EngineMessage? = nil, fileURL: URL? = nil, fileName: String? = nil) {
        self.context = context
        self.proxyConnection = WhitegramServiceProxyConnection(context: context)
        self.attachment = attachment
        self.fileURL = fileURL
        self.fileName = fileName
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
        self.proxyConnection.changed = { [weak self] in self?.refresh() }
        self.observers.append(whitegramServiceObserve(WhitegramPreferences.updatedNotification) { [weak self] _ in self?.refresh() })
        self.observers.append(whitegramServiceObserve(WhitegramLocalizationStore.changedNotification) { [weak self] _ in self?.refresh() })
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
        let route = WhitegramServiceRoute.configuredVirusTotal
        let configuration = [enabled, keyAvailable, route == .direct]
        if let previous = self.configuration, previous != configuration {
            self.cancel(message: "Configuration changed. Operation cancelled.")
            self.connection = "Not checked for these settings."
            self.result = nil
        }
        self.configuration = configuration
        let idle = self.task == nil && !self.proxyConnection.isConnecting && !self.presenter.isPresenting
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ section: Int32, _ content: WhitegramServiceEntry.Content) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("enabled", 0, .toggle(WhitegramLocalization.string("s.virusTotalEnabled"), enabled, idle))
        add("route", 0, .disclosure("Connection Route", route == .direct ? "Direct API" : "Original Whitegram Proxy", idle))
        if route == .originalProxy {
            add("proxyStatus", 0, .text(self.proxyConnection.status))
            add("connectProxy", 0, .action("Connect / Refresh Whitegram Access", idle))
        }
        add("key", 0, .disclosure(WhitegramLocalization.string("s.virusTotalApiKey"), keyAvailable ? "•••••••• · Keychain" : "Not set", idle))
        add("removeKey", 0, .action("Remove API Key", idle && (keyAvailable || credentialError != nil)))
        add("testConnection", 0, .action("Test Connection", idle && enabled && keyAvailable))
        if let error = credentialError { add("credentialError", 0, .text(error.localizedDescription)) }
        add("network", 0, .text("Direct API is an explicit choice using your key at VirusTotal's official API v3. The original route uses a signed Whitegram session. Reports, uploads and polling share the 15-second spacing and your account's quotas. Test Connection looks up the original fixed https://vk.com probe; it sends no message or file."))
        add("hashHeader", 1, .header("TARGET"))
        add("chooseFile", 1, .action("Choose File to Hash…", idle))
        if self.attachment != nil { add("downloadAttachment", 1, .action("Download Message File & Hash", idle)) }
        if self.fileURL != nil && self.file == nil { add("hashSelectedFile", 1, .action("Hash Selected File", idle)) }
        add("editHash", 1, .action("Enter SHA-256…", idle))
        add("editTarget", 1, .action("Enter URL or IP Address…", idle))
        if self.messageTargets.count > 1 { add("chooseTarget", 1, .disclosure("Message Targets", "\(self.messageTargets.count)", idle)) }
        add("hashInfo", 1, .text("A selected file is read locally in 1 MiB chunks, up to 512 MiB. Look Up SHA-256 sends only its hash. Upload File & Scan sends an exact checked snapshot of its contents and filename to VirusTotal, which can retain and share submitted files."))
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
        if case .url? = self.target { add("submitScan", 1, .action("Submit URL for Scan", idle && enabled && keyAvailable)) }
        if case .file? = self.target { add("submitScan", 1, .action("Reanalyse Existing File Report", idle && enabled && keyAvailable)) }
        if self.fileURL != nil { add("uploadScan", 1, .action("Upload File & Scan…", idle && enabled && keyAvailable)) }
        if self.analysisId != nil { add("resumeAnalysis", 1, .action("Check Submitted Analysis", idle && enabled && keyAvailable)) }
        if self.task != nil || self.proxyConnection.isConnecting { add("cancel", 1, .action("Cancel Operation", true)) }
        add("connection", 1, .text("Connection: " + self.connection))
        if !self.status.isEmpty { add("status", 1, .text(self.status)) }
        if let analysis = self.analysis {
            add("analysisHeader", 2, .header("SUBMITTED ANALYSIS"))
            add("analysisState", 2, .text("Status: " + analysis.status.rawValue + "\nID: " + analysis.id))
            add("analysisSummary", 2, .text(analysis.summary))
            if let date = analysis.date { add("analysisTime", 2, .text(whitegramServiceDate(date))) }
            for category in (analysis.statistics ?? [:]).keys.sorted() {
                if let count = analysis.statistics?[category] { add("analysisStat:" + category, 2, .text(category + ": \(count)")) }
            }
            add("analysisEngines", 2, .action("View Submitted Analysis Engines (\(analysis.engines.count))", idle))
            add("analysisReportHint", 2, .text("Look Up retrieves the target's latest stored report and its report link."))
        }
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
        guard self.task == nil, !self.proxyConnection.isConnecting, !self.presenter.isPresenting else { return }
        self.status = WhitegramPreferences.set(enabled, for: "virusTotalEnabled") ? "Settings saved." : WhitegramServiceError.preferences.localizedDescription
        self.refresh()
    }

    func perform(_ id: String) {
        if id == "cancel" { self.cancel(); return }
        guard self.task == nil, !self.proxyConnection.isConnecting, !self.presenter.isPresenting else { return }
        switch id {
        case "route": self.chooseRoute()
        case "connectProxy": self.proxyConnection.connect()
        case "key": self.editKey()
        case "removeKey":
            do { try WhitegramServiceCredentials.vault.remove(.virusTotal); self.status = "API key removed." }
            catch { self.status = (error as? WhitegramServiceError ?? .preferences).localizedDescription }
            self.refresh()
        case "chooseFile": self.chooseFile()
        case "downloadAttachment": self.downloadAttachment()
        case "hashSelectedFile": if let url = self.fileURL { self.hashFile(url: url, fileName: self.fileName) }
        case "editHash": self.editHash()
        case "editTarget": self.editTarget()
        case "chooseTarget": self.chooseTarget()
        case "reviewTarget":
            if let target = self.target { self.checkPresentation(self.presenter.showText(title: target.title + " to Look Up", text: target.value)) }
        case "copyHash": whitegramServiceCopy(self.sha256); self.status = "Hash copied for one hour."; self.refresh()
        case "lookup": self.lookup()
        case "testConnection": self.testConnection()
        case "submitScan": self.startScan(upload: false, resume: false)
        case "resumeAnalysis": self.startScan(upload: false, resume: true)
        case "uploadScan": self.confirmUpload()
        case "analysisEngines":
            if let analysis = self.analysis {
                let text = analysis.engines.map { $0.name + " — " + $0.category + "\n" + ($0.result ?? "No detection name provided") }.joined(separator: "\n\n")
                self.checkPresentation(self.presenter.showText(title: "Analysis Engine Results", text: text))
            }
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

    private func chooseRoute() {
        let alert = UIAlertController(title: "VirusTotal Connection", message: "Whitegram Proxy forwards the reviewed indicator or explicitly uploaded file and provider key through this Telegram account's signed session. Direct API sends directly to VirusTotal.", preferredStyle: .alert)
        for (title, useProxy) in [("Direct API", false), ("Original Whitegram Proxy", true)] {
            alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.presenter.close()
                self.status = WhitegramPreferences.update(["virusTotalUseProxy": useProxy, "virusTotalConnectionStatus": ""]) ? "Connection route saved." : WhitegramServiceError.preferences.localizedDescription
                self.refresh()
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in self?.presenter.close() }))
        self.checkPresentation(self.presenter.present(alert))
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
        self.fileURL = nil
        self.fileName = nil
        self.analysis = nil
        self.analysisId = nil
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
        self.hashFile(url: url, fileName: nil)
    }

    private func hashFile(url: URL, fileName: String?) {
        self.fileURL = url
        self.fileName = fileName
        self.analysis = nil
        self.analysisId = nil
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
                self.file = WhitegramVirusTotalFileHash(sha256: file.sha256, byteCount: file.byteCount, fileName: fileName ?? file.fileName)
                self.sha256 = file.sha256
                self.target = .file(sha256: file.sha256)
                self.status = "SHA-256 computed locally. Tap Look Up SHA-256 to query the report."
            case let .failure(error): self.status = error.localizedDescription
            }
            self.refresh()
        })
        self.refresh()
    }

    private func downloadAttachment() {
        guard let attachment = self.attachment else { return }
        let id = UUID()
        self.taskId = id
        self.status = "Downloading the selected attachment from Telegram…"
        self.task = whitegramFetchVirusTotalMessageFile(context: self.context, message: attachment, progress: { [weak self] count in
            guard let self, self.taskId == id else { return }
            self.status = "Downloaded " + ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
            self.refresh()
        }) { [weak self] result in
            guard let self, self.taskId == id else { return }
            self.task = nil
            self.taskId = nil
            switch result {
            case let .success(file): self.hashFile(url: file.url, fileName: file.fileName)
            case let .failure(error): self.status = error.localizedDescription; self.refresh()
            }
        }
        self.refresh()
    }

    private func confirmUpload() {
        guard self.fileURL != nil else { return }
        let alert = UIAlertController(title: "Upload File to VirusTotal?", message: "This sends the selected file's contents and filename to VirusTotal for analysis. VirusTotal may retain and share submitted files. Cancelling later cannot retract an uploaded file.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in self?.presenter.close() }))
        alert.addAction(UIAlertAction(title: "Upload & Scan", style: .default, handler: { [weak self] _ in
            self?.presenter.close()
            self?.startScan(upload: true, resume: false)
        }))
        self.checkPresentation(self.presenter.present(alert))
    }

    private func startScan(upload: Bool, resume: Bool) {
        guard !resume || self.analysisId != nil else { return }
        let id = UUID()
        self.taskId = id
        self.analysis = nil
        if !resume { self.analysisId = nil }
        self.status = resume ? "Checking the submitted analysis…" : "Preparing the explicit scan request…"
        let progress: (WhitegramVirusTotalScanProgress) -> Void = { [weak self] progress in
            guard let self, self.taskId == id else { return }
            switch progress {
            case let .preparing(count, total): self.status = "Preparing checked snapshot: \(count) / \(total) bytes"
            case let .prepared(file):
                self.file = WhitegramVirusTotalFileHash(sha256: file.sha256, byteCount: file.byteCount, fileName: self.fileName ?? file.fileName)
                self.sha256 = file.sha256
                self.target = .file(sha256: file.sha256)
                self.result = nil
            case let .uploading(count, total): self.status = "Uploading: \(count) / \(total) bytes"
            case let .submitted(analysisId):
                self.analysisId = analysisId
                self.status = "Submission accepted. Waiting for analysis; no verdict is available yet."
            case let .analysing(state, attempt): self.status = "Analysis \(state) · status check \(attempt)"
            }
            self.refresh()
        }
        let completion: (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void = { [weak self] result in
            guard let self, self.taskId == id else { return }
            self.task = nil
            self.taskId = nil
            switch result {
            case let .success(analysis):
                self.analysis = analysis
                self.analysisId = analysis.id
                self.status = "VirusTotal reported this analysis completed."
                self.recordConnection("Completed analysis received")
            case let .failure(error): self.status = error.localizedDescription
            }
            self.refresh()
        }
        self.task = whitegramWithVirusTotalCredential(account: self.proxyConnection.account, completion: completion) { key, service in
            if resume, let analysisId = self.analysisId {
                return service.resumeAnalysis(id: analysisId, progress: progress, apiKey: key, completion: completion)
            } else if upload, let url = self.fileURL {
                return service.uploadAndScan(fileURL: url, fileName: self.fileName, expectedHash: self.file?.sha256, progress: progress, apiKey: key, completion: completion)
            } else if let target = self.target {
                return service.scan(target: target, progress: progress, apiKey: key, completion: completion)
            }
            let operation = WhitegramServiceOperation(completion: completion)
            operation.finish(.failure(.invalidTarget))
            return operation.task
        }
        self.refresh()
    }

    private func testConnection() {
        let id = UUID()
        self.taskId = id
        self.status = "Looking up the original fixed connection probe…"
        let completion: (Result<Bool, WhitegramServiceError>) -> Void = { [weak self] result in
            guard let self, self.taskId == id else { return }
            self.task = nil
            self.taskId = nil
            switch result {
            case let .success(found):
                self.status = found ? "Connection probe returned a valid URL report." : "API responded: the connection probe has no report (HTTP 404)."
                self.recordConnection(self.status)
            case let .failure(error):
                self.status = error.localizedDescription
                self.recordConnection("Connection test failed")
            }
            self.refresh()
        }
        self.task = whitegramWithVirusTotalCredential(account: self.proxyConnection.account, completion: completion) { key, service in
            service.testConnection(apiKey: key, completion: completion)
        }
        self.refresh()
    }

    private func lookup() {
        guard let target = self.target else { return }
        let id = UUID()
        self.taskId = id
        self.result = nil
        self.status = "Looking up the selected " + target.title.lowercased() + " report…"
        self.task = whitegramLookupVirusTotalTarget(target, account: self.proxyConnection.account) { [weak self] result in
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
        guard self.task != nil || self.proxyConnection.isConnecting else { return }
        self.proxyConnection.cancel()
        let task = self.task
        self.taskId = nil
        self.task = nil
        task?.cancel()
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
    let coordinator = WhitegramVirusTotalCoordinator(context: context, sha256: sha256)
    return whitegramVirusTotalController(context: context, coordinator: coordinator)
}

/// Reviews extracted targets. Opening this screen and choosing a target never submits a lookup.
public func whitegramVirusTotalController(context: AccountContext, targets: [WhitegramVirusTotalTarget]) -> ViewController {
    let coordinator = WhitegramVirusTotalCoordinator(context: context, targets: targets)
    return whitegramVirusTotalController(context: context, coordinator: coordinator)
}

public func whitegramVirusTotalController(context: AccountContext, message: EngineMessage) -> ViewController {
    let targets = whitegramVirusTotalTargets(text: message.text, entities: message._asMessage().textEntitiesAttribute?.entities ?? [])
    let coordinator = WhitegramVirusTotalCoordinator(context: context, targets: targets, attachment: message)
    return whitegramVirusTotalController(context: context, coordinator: coordinator)
}

public func whitegramVirusTotalController(context: AccountContext, fileURL: URL, fileName: String) -> ViewController {
    return whitegramVirusTotalController(context: context, coordinator: WhitegramVirusTotalCoordinator(context: context, fileURL: fileURL, fileName: fileName))
}

private func whitegramVirusTotalController(context: AccountContext, coordinator: WhitegramVirusTotalCoordinator) -> ViewController {
    let controller = whitegramServiceListController(context: context, title: "VirusTotal", entries: coordinator.entries.get(), actions: coordinator, titleKey: "section.virusTotal")
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.refresh() }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
