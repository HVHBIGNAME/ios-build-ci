import Foundation
import AccountContext
import TelegramCore
import SwiftSignalKit

public final class WhitegramBackendAuthentication: WhitegramBackendTask {
    private struct Bot: Decodable { let username: String }
    private struct SessionRequest: Encodable {
        let userId: Int64
        let deviceToken: String
        let buildMode = "beta"
        let clientUptime: Int
        let initData: String
        let devicePublicKey: String
        enum CodingKeys: String, CodingKey {
            case userId = "user_id", deviceToken = "device_token", buildMode = "build_mode"
            case clientUptime = "client_uptime", initData = "init_data", devicePublicKey = "device_pubkey"
        }
    }

    private let context: AccountContext
    private let client: WhitegramBackendClient
    private let disposable = MetaDisposable()
    private var task: WhitegramBackendTask?
    private var generation = 0

    init(context: AccountContext, client: WhitegramBackendClient) {
        self.context = context
        self.client = client
    }

    public convenience init(context: AccountContext) {
        self.init(context: context, client: WhitegramBackendClient(userId: context.account.peerId.id._internalGetInt64Value()))
    }

    deinit { task?.cancel(); disposable.dispose() }

    public func cancel() {
        precondition(Thread.isMainThread)
        generation += 1
        task?.cancel()
        task = nil
        disposable.set(nil)
    }

    public func connect(completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        guard context.account.peerId.id._internalGetInt64Value() == client.userId, client.userId > 0 else {
            completion(.failure(.accountMismatch)); return
        }
        let generation = self.generation
        task = client.request(Bot.self, path: "/v1/auth/bot", authenticated: false) { [weak self] result in
            guard let self, generation == self.generation else { return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(bot):
                guard !bot.username.isEmpty, bot.username.count <= 64,
                      bot.username.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
                    completion(.failure(.invalidResponse)); return
                }
                disposable.set((context.engine.peers.resolvePeerByName(name: bot.username, referrer: nil)
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let self, generation == self.generation, case let .result(peer) = result else { return }
                    guard let peer, case let .user(user) = peer, user.botInfo != nil else { completion(.failure(.telegramAuthentication)); return }
                    requestWebView(botId: peer.id, generation: generation, completion: completion)
                }))
            }
        }
    }

    private func requestWebView(botId: EnginePeer.Id, generation: Int, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) {
        // Defer replacing the resolver disposable in case its result is synchronous.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.generation else { return }
            disposable.set((context.engine.messages.requestSimpleWebView(botId: botId,
                url: WhitegramBackendProtocol.baseURL.absoluteString + "/auth", source: .generic, themeParams: nil)
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, generation == self.generation else { return }
                do { try exchange(initData: WhitegramBackendProtocol.webAppInitData(from: result.url), generation: generation, completion: completion) }
                catch let error as WhitegramBackendError { completion(.failure(error)) }
                catch { completion(.failure(.telegramAuthentication)) }
            }, error: { [weak self] _ in
                guard let self, generation == self.generation else { return }
                completion(.failure(.telegramAuthentication))
            }))
        }
    }

    private func exchange(initData: String, generation: Int, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) throws {
        let body = SessionRequest(userId: client.userId, deviceToken: try WhitegramBackendKeychain.shared.deviceToken(),
            clientUptime: Int(ProcessInfo.processInfo.systemUptime), initData: initData, devicePublicKey: try WhitegramBackendIdentity.shared.publicKeyBase64())
        task = client.request(WhitegramBackendSessionResponse.self, path: "/v1/auth/session", method: "POST",
            body: try JSONEncoder().encode(body), authenticated: false) { [weak self] result in
            guard let self, generation == self.generation else { return }
            do {
                let session = try result.get().session(for: client.userId, now: Date())
                try client.sessions.save(session)
                client.access.reset(userId: client.userId)
                NotificationCenter.default.post(name: WhitegramBackendClient.sessionUpdated, object: nil, userInfo: ["userId": client.userId])
                task = client.refreshAccess { [weak self] result in
                    guard let self, generation == self.generation else { return }
                    completion(result.flatMap { $0 == .allowed ? .success(Void()) : .failure(.betaAccessDenied) })
                }
            } catch let error as WhitegramBackendError { completion(.failure(error)) }
            catch { completion(.failure(.invalidResponse)) }
        }
    }
}
