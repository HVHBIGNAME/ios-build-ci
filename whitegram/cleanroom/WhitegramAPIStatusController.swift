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
        func add(_ id: String, _ content: WhitegramServiceEntry.Content, section: Int32 = 0) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("server", .text(WhitegramBackendProtocol.baseURL.absoluteString))
        add("status", .action("Check API status", !busy))
        if let status {
            add("state", .text("Status: " + status.status))
            if let uptime = status.uptimeSeconds { add("uptime", .text("Uptime: \(uptime) seconds")) }
            if let time = status.processingMs { add("processing", .text(String(format: "Server processing: %.1f ms", time))) }
            for (index, service) in status.services.enumerated() { add("service.\(index)", .text(service.name + ": " + (service.ok ? "OK" : "Degraded")), section: 1) }
        } else { add("unchecked", .text("No current server status.")) }
        add("measure", .action("Measure connection", !busy), section: 2)
        add("measureInfo", .text("Measures a 1 KiB probe, 512 KiB download and 256 KiB random-data upload to the original API. No Telegram messages are included."), section: 2)
        if let measurement {
            add("measurement", .text(String(format: "Ping: %.1f ms\nDownload: %.2f Mbit/s\nUpload: %.2f Mbit/s", measurement.pingMilliseconds, measurement.downloadMbps, measurement.uploadMbps)), section: 2)
        }
        add("period", .disclosure("My API requests", days == 1 ? "Today (UTC)" : "30 days (UTC)", true), section: 3)
        let counts = WhitegramAPIUsage.shared.counts(days: days)
        if counts.isEmpty { add("noRequests", .text("No requests recorded for this period."), section: 3) }
        for (index, count) in counts.enumerated() { add("count.\(index)", .text("\(count.path): \(count.count)"), section: 3) }
        if busy { add("cancel", .action("Cancel request", true), section: 4) }
        if let error { add("error", .text(error), section: 4) }
        entries.set(rows)
    }
}

public func whitegramAPIStatusController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramAPIStatusCoordinator()
    let controller = whitegramServiceListController(context: context, title: WhitegramLocalization.string("apiStatus.title"), entries: coordinator.entries.get(), actions: coordinator)
    controller.didDisappear = { [coordinator] _ in coordinator.cancel() }
    return controller
}
