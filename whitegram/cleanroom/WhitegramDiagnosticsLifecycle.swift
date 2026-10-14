import Foundation
import MetricKit
import TelegramCore
import UIKit

final class WhitegramDiagnosticsLifecycle {
    static let shared = WhitegramDiagnosticsLifecycle()
    private var subscriber: AnyObject?
    private var observer: NSObjectProtocol?

    func start() {
        guard self.observer == nil else { return }
        WhitegramErrorReporter.shared.start()
        if #available(iOS 14.0, *) { self.subscriber = WhitegramMetricSubscriber() }
        self.observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            WhitegramErrorReporter.shared.flush()
        }
    }
}

@available(iOS 14.0, *)
private final class WhitegramMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit { MXMetricManager.shared.remove(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard WhitegramErrorReporter.shared.enabled else { return }
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                WhitegramErrorReporter.shared.record(kind: .crash, component: .app,
                    code: crash.signal?.intValue ?? crash.exceptionType?.intValue ?? 0,
                    frames: WhitegramErrorReport.frames(from: crash.callStackTree.jsonRepresentation()), diagnosticBuild: crash.metaData.applicationBuildVersion)
            }
            for hang in payload.hangDiagnostics ?? [] {
                WhitegramErrorReporter.shared.record(kind: .hang, component: .app, code: 0,
                    frames: WhitegramErrorReport.frames(from: hang.callStackTree.jsonRepresentation()), diagnosticBuild: hang.metaData.applicationBuildVersion)
            }
        }
    }
}
