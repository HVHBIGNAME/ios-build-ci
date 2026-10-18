import Foundation
import SwiftSignalKit
import TelegramApi
import MtProtoKit

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
    static func authRequest() {
        #if targetEnvironment(simulator)
        Queue.mainQueue().async { WhitegramSimulatorLoginProbe.current?.authRequest() }
        #endif
    }

    static func authResponse(error: MTRpcError?) {
        #if targetEnvironment(simulator)
        Queue.mainQueue().async { WhitegramSimulatorLoginProbe.current?.authResponse(error: error) }
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

    func authRequest() {
        self.record["auth"] = "pending"
        self.write()
    }

    func authResponse(error: MTRpcError?) {
        self.record["auth"] = error == nil ? "success" : "rpc-error"
        if let error {
            self.record["auth_code"] = error.errorCode
            self.record["auth_error"] = Self.errorName(error)
        }
        self.write()
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
    }
}
#endif
