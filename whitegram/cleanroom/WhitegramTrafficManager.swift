import Foundation
import UIKit
import TelegramCore

public func whitegramInstallTraffic() { WhitegramTrafficManager.install() }

final class WhitegramTrafficManager: NSObject, URLSessionDataDelegate {
    static let shared = WhitegramTrafficManager()
    static let updated = Notification.Name("WhitegramTrafficStateUpdated")
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var responseBytes = 0
    private(set) var lastResult: String?
    private(set) var nextRequestAt: Date?
    private(set) var requestCount = 0
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    static func install() { shared.refresh() }

    private override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIDevice.batteryLevelDidChangeNotification, WhitegramPreferences.updatedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == UIApplication.willResignActiveNotification || notification.name == UIApplication.didEnterBackgroundNotification {
                    self?.stop()
                } else { self?.refresh() }
            })
        }
    }

    var suspension: WhitegramTrafficPolicy.Suspension? {
        return WhitegramTrafficPolicy.suspension(enabled: WhitegramPreferences.bool("antiCensorshipEnabled"),
            foreground: UIApplication.shared.applicationState == .active, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            battery: UIDevice.current.batteryLevel)
    }

    var status: String {
        switch suspension {
        case .disabled: return "Off"
        case .background: return "Paused while the app is inactive"
        case .lowPower: return "Paused in Low Power Mode"
        case .lowBattery: return "Paused below 20% battery"
        case nil: return task == nil ? "Waiting for the next decoy request" : "Sending a decoy request"
        }
    }

    func refresh() {
        precondition(Thread.isMainThread)
        if suspension != nil { stop(); return }
        guard task == nil, timer == nil else { return }
        schedule()
    }

    private func notify() { NotificationCenter.default.post(name: Self.updated, object: self) }

    private func schedule() {
        guard suspension == nil else { stop(); return }
        timer?.invalidate()
        let delay = TimeInterval.random(in: WhitegramTrafficPolicy.delay)
        nextRequestAt = Date().addingTimeInterval(delay)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.send() }
        notify()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        nextRequestAt = nil
        let task = self.task
        self.task = nil
        task?.cancel()
        notify()
    }

    private func send() {
        timer = nil
        nextRequestAt = nil
        guard suspension == nil else { stop(); return }
        guard let endpoint = WhitegramTrafficPolicy.endpoints.randomElement(), let agent = WhitegramTrafficPolicy.userAgents.randomElement(),
              let request = WhitegramTrafficPolicy.request(endpoint: endpoint, userAgent: agent, head: Bool.random()) else { return }
        responseBytes = 0
        requestCount += 1
        task = session.dataTask(with: request)
        task?.resume()
        notify()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else { completionHandler(nil); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        responseBytes += data.count
        if responseBytes > 256 * 1024 { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        let host = task.originalRequest?.url?.host ?? ""
        if responseBytes > 256 * 1024 {
            lastResult = "\(host): response stopped at 256 KiB"
        } else if let error = error as NSError? {
            lastResult = "\(host): network error \(error.code)"
        } else if let response = task.response as? HTTPURLResponse {
            lastResult = "\(host): HTTP \(response.statusCode)"
        } else { lastResult = "\(host): no HTTP response" }
        schedule()
    }
}
