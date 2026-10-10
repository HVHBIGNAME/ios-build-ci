import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

private final class WhitegramDiagnosticsCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private let context: AccountContext
    private let collection = MetaDisposable()
    private var busy = false
    private var status: String?
    private var snapshot = ""
    private var export: WhitegramDiagnosticsExport?

    init(context: AccountContext) {
        self.context = context
        self.presenter.changed = { [weak self] in
            guard let self, !self.presenter.isPresenting else { return }
            self.export = nil
            self.refresh()
        }
        self.refresh()
    }

    deinit { self.collection.dispose() }
    func setEnabled(_ enabled: Bool) {}

    private func text(_ ru: String, _ en: String) -> String {
        let language = self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
        return WhitegramLocalization.selectedLanguage(baseLanguage: language) == "ru" ? ru : en
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        let memory = WhitegramRAMUsage.physicalFootprint().map { "\($0 / 1_048_576) MiB" } ?? "unavailable"
        let bundle = Bundle.main.infoDictionary ?? [:]
        self.snapshot = [
            "Whitegram \(bundle["CFBundleShortVersionString"] ?? "?") (\(bundle["CFBundleVersion"] ?? "?"))",
            "Time: \(ISO8601DateFormatter().string(from: Date()))",
            "Device: \(UIDevice.current.model)", "OS: \(info.operatingSystemVersionString)",
            "Memory footprint: \(memory)", "Physical memory: \(info.physicalMemory / 1_048_576) MiB",
            "Processors: \(info.activeProcessorCount)/\(info.processorCount)", "Uptime: \(Int(info.systemUptime)) s",
            "Low power mode: \(info.isLowPowerModeEnabled)", "Thermal state: \(info.thermalState.rawValue)"
        ].joined(separator: "\n")
        let enabled = !self.busy && !self.presenter.isPresenting
        var rows = [
            WhitegramServiceEntry(stableId: "snapshot", order: 0, section: 0, content: .text(self.snapshot)),
            WhitegramServiceEntry(stableId: "refresh", order: 1, section: 1, content: .action(self.text("Обновить", "Refresh"), enabled)),
            WhitegramServiceEntry(stableId: "copy", order: 2, section: 1, content: .action(self.text("Скопировать диагностику", "Copy Diagnostics"), enabled)),
            WhitegramServiceEntry(stableId: "export", order: 3, section: 1, content: .action(self.text("Экспортировать журналы", "Export Logs"), enabled))
        ]
        if let status { rows.append(WhitegramServiceEntry(stableId: "status", order: 4, section: 2, content: .text(status))) }
        self.entries.set(rows)
    }

    func perform(_ id: String) {
        guard !self.busy && !self.presenter.isPresenting else { return }
        switch id {
        case "refresh": self.status = nil; self.refresh()
        case "copy":
            self.refresh()
            whitegramServiceCopy(self.snapshot)
            self.status = self.text("Диагностика скопирована.", "Diagnostics copied.")
            self.refresh()
        case "export":
            self.busy = true
            self.status = self.text("Подготовка журналов…", "Preparing logs…")
            self.refresh()
            let snapshot = self.snapshot
            self.collection.set((combineLatest(Logger.shared.collectLogs(), Logger.shared.collectShortLogFiles())
            |> deliverOn(Queue.concurrentDefaultQueue())
            |> map { logs, shortLogs -> Result<WhitegramDiagnosticsExport, Error> in
                return Result { try WhitegramDiagnosticsExport(snapshot: snapshot, paths: (logs + shortLogs).map { $0.1 }) }
            }
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self else { return }
                self.busy = false
                switch result {
                case let .failure(error): self.status = error.localizedDescription
                case let .success(export):
                    self.export = export
                    let sheet = UIActivityViewController(activityItems: export.files, applicationActivities: nil)
                    sheet.popoverPresentationController?.sourceView = self.presenter.controller?.view
                    sheet.popoverPresentationController?.sourceRect = CGRect(x: 30, y: 100, width: 1, height: 1)
                    // Retain exported files until the share extension has completed.
                    sheet.completionWithItemsHandler = { [weak self, export] _, completed, _, error in
                        _ = export.files
                        guard let self else { return }
                        self.status = error?.localizedDescription ?? (completed ? self.text("Экспорт завершён.", "Export completed.") : nil)
                        self.presenter.close()
                    }
                    self.status = export.files.count == 1 ? self.text("Журналов нет; доступен отчёт диагностики.", "No log files; the diagnostics report is available.") : nil
                    if !self.presenter.present(sheet) {
                        self.export = nil
                        self.status = self.text("Дождитесь завершения перехода и повторите экспорт.", "Wait for the screen transition and retry export.")
                    }
                }
                self.refresh()
            }))
        default: break
        }
    }
}

private final class WhitegramDiagnosticsExport {
    let directory: URL
    let files: [URL]

    init(snapshot: String, paths: [String]) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("WhitegramDiagnostics-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let report = directory.appendingPathComponent("diagnostics.txt")
            try Data(snapshot.utf8).write(to: report, options: .atomic)
            var files = [report]
            var seen = Set<String>()
            for path in paths where seen.insert(path).inserted {
                let source = URL(fileURLWithPath: path)
                let target = directory.appendingPathComponent("\(files.count)-" + source.lastPathComponent)
                try manager.copyItem(at: source, to: target)
                files.append(target)
            }
            self.directory = directory
            self.files = files
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: self.directory) }
}

public func whitegramDiagnosticsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramDiagnosticsCoordinator(context: context)
    let controller = whitegramServiceListController(context: context, title: "Diagnostics", entries: coordinator.entries.get(), actions: coordinator, titleKey: "h.analytics")
    coordinator.presenter.controller = controller
    return controller
}
