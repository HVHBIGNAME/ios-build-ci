import Foundation
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public func whitegramRecordLoginVerification(event: String, code: Int? = nil) {
    #if targetEnvironment(simulator)
    Queue.mainQueue().async { WhitegramSimulatorLoginProbe.current?.verification(event: event, code: code) }
    #endif
}

/// Simulator-only evidence from the same Network instance used by the login UI.
public func whitegramObserveLoginConnection(network: Network, foreground: Signal<Bool, NoError>) -> Disposable {
    #if targetEnvironment(simulator)
    guard let token = ProcessInfo.processInfo.environment["WHITEGRAM_LOGIN_PROBE"],
          token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return EmptyDisposable }
    let probe = WhitegramSimulatorLoginProbe(network: network, token: token)
    probe.start(foreground: foreground)
    return ActionDisposable { probe.dispose() }
    #else
    return EmptyDisposable
    #endif
}

enum WhitegramLoginProbe {
    static func authRequest(network: Network) {
        #if targetEnvironment(simulator)
        Queue.mainQueue().async { [weak network] in
            guard let network else { return }
            WhitegramSimulatorLoginProbe.current?.authRequest(network: network)
        }
        #endif
    }

    static func authResponse(network: Network, error: MTRpcError?) {
        #if targetEnvironment(simulator)
        let datacenterId = network.datacenterId
        Queue.mainQueue().async { WhitegramSimulatorLoginProbe.current?.authResponse(datacenterId: datacenterId, error: error) }
        #endif
    }

    static func authFlowError(_ error: AuthorizationCodeRequestError) {
        #if targetEnvironment(simulator)
        let status: String
        if case .timeout = error { status = "timeout" } else { status = "error" }
        Queue.mainQueue().async { WhitegramSimulatorLoginProbe.current?.authFlowError(status) }
        #endif
    }
}

#if targetEnvironment(simulator)
private final class WhitegramSimulatorLoginProbe {
    static weak var current: WhitegramSimulatorLoginProbe?
    private let network: Network
    private let token: String
    private let status = MetaDisposable()
    private let foreground = MetaDisposable()
    private let request = MetaDisposable()
    private let authStatus = MetaDisposable()
    private var authResponses: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var record: [String: Any]
    private var disposed = false

    init(network: Network, token: String) {
        self.network = network
        self.token = token
        self.record = ["schema": 1, "token": token, "probe": "not-started", "auth": "not-submitted", "connection": "unknown"]
    }

    func start(foreground: Signal<Bool, NoError>) {
        Self.current = self
        self.status.set((self.network.connectionStatus |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self, !self.disposed else { return }
            switch status {
            case .online: self.record["connection"] = "online"
            case .updating: self.record["connection"] = "updating"
            case .waitingForNetwork: self.record["connection"] = "waiting-for-network"
            case let .connecting(proxyAddress, _): self.record["connection"] = proxyAddress == nil ? "connecting-direct" : "connecting-proxy"
            }
            self.write()
        }))
        self.foreground.set((foreground |> distinctUntilChanged |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self, !self.disposed else { return }
            self.request.set(nil)
            self.record["foreground"] = active
            guard active else { self.write(); return }
            if self.record["probe"] as? String == "success" { self.write(); return }
            self.record["probe"] = "pending"
            self.write()
            self.request.set((self.network.request(Api.functions.help.getNearestDc(), automaticFloodWait: false)
            |> take(1)
            |> timeout(30.0, queue: .mainQueue(), alternate: .fail(MTRpcError(errorCode: -1001, errorDescription: "LOGIN_PROBE_TIMEOUT")))
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                self?.record["probe"] = "success"
                self?.write()
            }, error: { [weak self] error in
                self?.record["probe"] = error.errorCode == -1001 ? "timeout" : "rpc-error"
                self?.record["probe_code"] = error.errorCode
                self?.record["probe_error"] = Self.errorName(error)
                self?.write()
            }))
        }))
    }

    func authRequest(network: Network) {
        self.event("auth-request", datacenter: network.datacenterId)
        self.record["auth"] = "pending"
        self.record["auth_code"] = nil
        self.record["auth_error"] = nil
        self.record["auth_flow"] = "pending"
        self.record["auth_datacenter"] = network.datacenterId
        let previousAttempts = self.record["auth_attempts"] as? Int
        self.record["auth_attempts"] = (previousAttempts ?? 0) + 1
        self.record["auth_connection"] = "unknown"
        self.record["auth_keep_connection"] = nil
        self.write()
        let datacenterId = network.datacenterId
        self.authStatus.set((combineLatest(network.connectionStatus, network.shouldKeepConnection.get())
        |> deliverOnMainQueue).start(next: { [weak self] status, keepConnection in
            guard let self, !self.disposed else { return }
            switch status {
            case .online: self.record["auth_connection"] = "online"
            case .updating: self.record["auth_connection"] = "updating"
            case .waitingForNetwork: self.record["auth_connection"] = "waiting-for-network"
            case let .connecting(proxyAddress, _): self.record["auth_connection"] = proxyAddress == nil ? "connecting-direct" : "connecting-proxy"
            }
            self.record["auth_keep_connection"] = keepConnection
            self.event("auth-connection", datacenter: datacenterId, state: self.record["auth_connection"] as? String)
            self.write()
        }))
    }

    func authResponse(datacenterId: Int, error: MTRpcError?) {
        self.event("auth-response", datacenter: datacenterId, state: error.map(Self.errorName) ?? "success")
        self.record["auth"] = error == nil ? "success" : "rpc-error"
        var response: [String: Any] = ["datacenter": datacenterId, "status": error == nil ? "success" : "rpc-error"]
        if let error {
            self.record["auth_code"] = error.errorCode
            self.record["auth_error"] = Self.errorName(error)
            response["code"] = error.errorCode
            response["error"] = Self.errorName(error)
        }
        self.authResponses.append(response)
        self.authResponses = Array(self.authResponses.suffix(8))
        self.record["auth_responses"] = self.authResponses
        self.write()
    }

    func authFlowError(_ status: String) {
        self.record["auth_flow"] = status
        self.event("auth-flow", state: status)
        self.write()
    }

    func verification(event: String, code: Int?) {
        let allowed: Set<String> = ["apns-requested", "recaptcha-requested", "recaptcha-client-success",
                                    "recaptcha-client-error", "recaptcha-execute-success", "recaptcha-execute-error"]
        guard allowed.contains(event) else { return }
        self.event(event, code: code)
        self.write()
    }

    private func event(_ name: String, datacenter: Int? = nil, state: String? = nil, code: Int? = nil) {
        var event: [String: Any] = ["name": name, "seconds": ProcessInfo.processInfo.systemUptime - self.startedAt]
        event["datacenter"] = datacenter
        event["state"] = state
        event["code"] = code
        self.events.append(event)
        self.events = Array(self.events.suffix(32))
        self.record["events"] = self.events
    }

    private static func errorName(_ error: MTRpcError) -> String {
        let value = error.errorDescription ?? ""
        return value.range(of: "^[A-Z][A-Z0-9_]{0,79}$", options: .regularExpression) != nil ? value : "OTHER_RPC_ERROR"
    }

    private func write() {
        guard !self.disposed else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: self.record, options: [.sortedKeys])
            let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try data.write(to: root.appendingPathComponent("whitegram-login-\(self.token).json"), options: .atomic)
            print("WHITEGRAM_LOGIN_PROBE " + String(decoding: data, as: UTF8.self))
        } catch {
            print("WHITEGRAM_LOGIN_PROBE_WRITE_FAILED")
        }
    }

    func dispose() {
        self.disposed = true
        self.status.dispose()
        self.foreground.dispose()
        self.request.dispose()
        self.authStatus.dispose()
    }
}
#endif
