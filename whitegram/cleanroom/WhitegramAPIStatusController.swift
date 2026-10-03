import Foundation
import AccountContext
import Display
import SwiftSignalKit
import TelegramCore

private final class WhitegramAPIStatusCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    private let service = WhitegramAPIStatusService(client: WhitegramBackendClient(userId: 0))
    private var request: WhitegramBackendTask?
    private var status: WhitegramAPIStatus?
    private var measurement: WhitegramAPIConnectionMeasurement?
    private var error: String?
    private var busy = false
    private var days = 1
    private var generation = 0

    init() { refresh() }
    deinit { request?.cancel() }
    func setEnabled(_ enabled: Bool) {}

    func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        busy = false
        refresh()
    }

    func perform(_ id: String) {
        if id == "period" { days = days == 1 ? 30 : 1; refresh(); return }
        if id == "cancel" { cancel(); return }
        guard !busy, id == "status" || id == "measure" else { return }
        busy = true
        error = nil
        generation += 1
        let generation = self.generation
        refresh()
        if id == "status" {
            request = service.status { [weak self] result in
                guard let self, generation == self.generation else { return }
                busy = false
                request = nil
                switch result {
                case let .success(value): status = value
                case let .failure(value): status = nil; error = value.localizedDescription
                }
                refresh()
            }
        } else if id == "measure" {
            measurement = nil
            request = service.measure { [weak self] result in
                guard let self, generation == self.generation else { return }
                busy = false
                request = nil
                switch result {
                case let .success(value): measurement = value
                case let .failure(value): error = value.localizedDescription
                }
                refresh()
            }
        }
    }

    private func refresh() {
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ section: Int32 = 0, _ content: WhitegramServiceEntry.Content) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("server", .text(WhitegramBackendProtocol.baseURL.absoluteString))
        add("status", .action("Check API status", !busy))
        if let status {
            add("state", .text("Status: " + status.status))
            if let uptime = status.uptimeSeconds { add("uptime", .text("Uptime: \(uptime) seconds")) }
            if let time = status.processingMs { add("processing", .text(String(format: "Server processing: %.1f ms", time))) }
            for (index, service) in status.services.enumerated() { add("service.\(index)", 1, .text(service.name + ": " + (service.ok ? "OK" : "Degraded"))) }
        } else { add("unchecked", .text("No current server status.")) }
        add("measure", 2, .action("Measure connection", !busy))
        add("measureInfo", 2, .text("Measures a 1 KiB probe, 512 KiB download and 256 KiB random-data upload to the original API. No Telegram messages are included."))
        if let measurement {
            add("measurement", 2, .text(String(format: "Ping: %.1f ms\nDownload: %.2f Mbit/s\nUpload: %.2f Mbit/s", measurement.pingMilliseconds, measurement.downloadMbps, measurement.uploadMbps)))
        }
        add("period", 3, .disclosure("My API requests", days == 1 ? "Today (UTC)" : "30 days (UTC)", true))
        let counts = WhitegramAPIUsage.shared.counts(days: days)
        if counts.isEmpty { add("noRequests", 3, .text("No requests recorded for this period.")) }
        for (index, count) in counts.enumerated() { add("count.\(index)", 3, .text("\(count.path): \(count.count)")) }
        if busy { add("cancel", 4, .action("Cancel request", true)) }
        if let error { add("error", 4, .text(error)) }
        entries.set(rows)
    }
}

public func whitegramAPIStatusController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramAPIStatusCoordinator()
    let controller = whitegramServiceListController(context: context, title: WhitegramLocalization.string("apiStatus.title"), entries: coordinator.entries.get(), actions: coordinator)
    controller.didDisappear = { [coordinator] _ in coordinator.cancel() }
    return controller
}
