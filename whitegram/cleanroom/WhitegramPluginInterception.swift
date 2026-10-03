import Foundation

public struct WhitegramPluginInterceptDecision {
    public let payload: [String: Any]
    public let cancelled: Bool
    public let reason: String?

    public init(payload: [String: Any], cancelled: Bool = false, reason: String? = nil) {
        self.payload = payload
        self.cancelled = cancelled
        self.reason = reason
    }
}

public final class WhitegramPluginInterceptToken {
    private let lock = NSLock()
    private var active = true
    private var cancellation: (() -> Void)?

    public var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active
    }

    fileprivate func onCancel(_ action: @escaping () -> Void) {
        self.lock.lock()
        if self.active { self.cancellation = action; self.lock.unlock() }
        else { self.lock.unlock(); action() }
    }

    fileprivate func finish() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.active else { return false }
        self.active = false
        self.cancellation = nil
        return true
    }

    public func dispose() {
        self.lock.lock()
        self.active = false
        let action = self.cancellation
        self.cancellation = nil
        self.lock.unlock()
        action?()
    }
}

// No caller (including the main and Postbox queues) waits for JavaScript. Only
// bounded JSON enters the plugin's serial queue; a late result cannot commit an
// operation whose owner disposed it, timed out, or revoked its permission.
public final class WhitegramPluginInterceptionHub {
    public static let shared = WhitegramPluginInterceptionHub()
    public static let names = ["message.beforeSend", "tg.request"]

    private final class Handler {
        weak var scope: AnyObject?
        let owner: String
        let id: String
        let name: String
        let phase: Int
        let priority: Int
        let before: [String]
        let after: [String]
        let sequence: UInt64
        let queue: DispatchQueue
        let token = WhitegramPluginInterceptToken()
        let permitted: () -> Bool
        let invoke: ([String: Any]) -> [String: Any]
        let diagnostic: (String) -> Void

        init(scope: AnyObject, owner: String, id: String, name: String, legacy: Bool, priority: Int, before: [String], after: [String], sequence: UInt64,
             queue: DispatchQueue, permitted: @escaping () -> Bool, invoke: @escaping ([String: Any]) -> [String: Any], diagnostic: @escaping (String) -> Void) {
            self.scope = scope; self.owner = owner; self.id = id; self.name = name
            self.phase = (name == "message.beforeSend" ? legacy : !legacy) ? 0 : 1
            self.priority = priority; self.before = before; self.after = after; self.sequence = sequence
            self.queue = queue; self.permitted = permitted; self.invoke = invoke; self.diagnostic = diagnostic
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WhitegramPlugin.Interception", qos: .userInitiated)
    private var handlers: [Handler] = []
    private var sequence: UInt64 = 0
    private var pending = 0
    private let deadline: TimeInterval

    public init(deadline: TimeInterval = 0.5) { self.deadline = max(0.01, min(5, deadline)) }

    public func register(scope: AnyObject, owner: String, id: String, name: String, legacy: Bool, priority: Int, before: [String], after: [String],
                         queue: DispatchQueue, permitted: @escaping () -> Bool, invoke: @escaping ([String: Any]) -> [String: Any], diagnostic: @escaping (String) -> Void) -> WhitegramPluginInterceptToken? {
        guard Self.names.contains(name), !owner.isEmpty, !id.isEmpty, before.count <= 32, after.count <= 32 else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.handlers.removeAll { $0.scope == nil || !$0.token.isActive }
        guard self.handlers.filter({ $0.scope === scope }).count < 256 else { return nil }
        self.sequence &+= 1
        let handler = Handler(scope: scope, owner: owner, id: id, name: name, legacy: legacy, priority: priority, before: before, after: after, sequence: self.sequence,
                              queue: queue, permitted: permitted, invoke: invoke, diagnostic: diagnostic)
        let candidates = self.handlers.filter { $0.scope === scope && $0.name == name } + [handler]
        guard Self.ordered(candidates) != nil else { return nil }
        self.handlers.append(handler)
        return handler.token
    }

    public func hasHandlers(scope: AnyObject, name: String) -> Bool {
        self.lock.lock()
        let result = self.handlers.contains { $0.scope === scope && $0.name == name && $0.token.isActive }
        self.lock.unlock()
        return result
    }

    private static func ordered(_ values: [Handler]) -> [Handler]? {
        var remaining = values.sorted {
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.sequence < $1.sequence
        }
        var output: [Handler] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { candidate in
                !remaining.contains(where: { other in
                    other !== candidate && (other.phase < candidate.phase || (other.phase == candidate.phase &&
                        (other.before.contains(candidate.owner) || candidate.after.contains(other.owner))))
                })
            }) else { return nil }
            output.append(remaining.remove(at: index))
        }
        return output
    }

    @discardableResult
    public func intercept(scope: AnyObject, name: String, payload: [String: Any], completion: @escaping (WhitegramPluginInterceptDecision) -> Void) -> WhitegramPluginInterceptToken {
        let token = WhitegramPluginInterceptToken()
        self.lock.lock()
        let snapshot = Self.ordered(self.handlers.filter { $0.scope === scope && $0.name == name && $0.token.isActive }) ?? []
        let admitted = self.pending < 128
        if admitted { self.pending += 1 }
        self.lock.unlock()
        guard admitted else {
            self.queue.async { if token.finish() { completion(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "INTERCEPT_QUOTA")) } }
            return token
        }
        let released = WhitegramPluginInterceptToken()
        let release = { [weak self] in
            guard released.finish(), let self = self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
        token.onCancel(release)
        self.queue.async {
            guard token.isActive else { return }
            guard let json = try? JSONSerialization.data(withJSONObject: payload), json.count <= 65536,
                  let payload = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
                release()
                if token.finish() { completion(WhitegramPluginInterceptDecision(payload: [:], cancelled: true, reason: "INTERCEPT_PAYLOAD_TOO_LARGE")) }
                return
            }
            self.step(snapshot, index: 0, name: name, payload: payload, token: token, finish: { decision in
                release()
                if token.finish() { completion(decision) }
            })
        }
        return token
    }

    private func step(_ handlers: [Handler], index: Int, name: String, payload: [String: Any], token: WhitegramPluginInterceptToken,
                      finish: @escaping (WhitegramPluginInterceptDecision) -> Void) {
        guard token.isActive else { return }
        guard index < handlers.count else { finish(WhitegramPluginInterceptDecision(payload: payload)); return }
        let handler = handlers[index]
        guard handler.token.isActive, handler.permitted() else {
            finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "PLUGIN_STOPPED"))
            return
        }
        let attempt = WhitegramPluginInterceptToken()
        self.queue.asyncAfter(deadline: .now() + self.deadline) {
            guard attempt.finish(), token.isActive else { return }
            // Diagnostics use the owning JS queue, never concurrent JSC access.
            handler.queue.async { handler.diagnostic("\(name) timed out; operation cancelled") }
            finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "INTERCEPT_TIMEOUT"))
        }
        handler.queue.async {
            guard token.isActive, attempt.isActive else { return }
            let result: [String: Any]
            if handler.token.isActive && handler.permitted() { result = handler.invoke(payload) }
            else { result = ["action": "cancel", "reason": "PLUGIN_STOPPED"] }
            let data = try? JSONSerialization.data(withJSONObject: result)
            self.queue.async {
                guard attempt.finish(), token.isActive else { return }
                guard handler.token.isActive, handler.permitted() else {
                    finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "PLUGIN_STOPPED")); return
                }
                guard let data = data, data.count <= 65536, let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "INVALID_HOOK_RESULT")); return
                }
                let action = ((result["action"] ?? result["strategy"]) as? String) ?? "continue"
                if action == "cancel" {
                    finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: result["reason"] as? String)); return
                }
                var next = payload
                if ["modify", "modifyFinal", "replace"].contains(action) {
                    if name == "message.beforeSend" {
                        let value = result["value"]
                        guard let text = (value as? String) ?? ((value as? [String: Any])?["text"] as? String), text.utf8.count <= 16384 else {
                            finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "INVALID_HOOK_TEXT")); return
                        }
                        next["text"] = text
                    } else {
                        handler.queue.async { handler.diagnostic("tg.request supports cancellation; native Telegram does not apply request replacement") }
                    }
                } else if action != "continue" {
                    finish(WhitegramPluginInterceptDecision(payload: payload, cancelled: true, reason: "INVALID_HOOK_ACTION")); return
                }
                if name == "message.beforeSend" && ["modifyFinal", "replace"].contains(action) {
                    finish(WhitegramPluginInterceptDecision(payload: next)); return
                }
                self.step(handlers, index: index + 1, name: name, payload: next, token: token, finish: finish)
            }
        }
    }
}
