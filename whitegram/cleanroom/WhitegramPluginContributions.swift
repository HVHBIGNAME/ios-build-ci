import Foundation

public struct WhitegramPluginMessageMenuItem {
    public let token: String
    public let id: String
    public let title: String
    public let icon: String
    public let priority: Int
}

public final class WhitegramPluginMenuRegistration {
    private let lock = NSLock()
    private var active = true

    fileprivate var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active
    }

    public func dispose() {
        self.lock.lock(); self.active = false; self.lock.unlock()
    }
}

// Shared through TelegramCore, without retaining an AccountContext, JSValue or
// UIKit object. The menu captures tokens, not executable plugin callbacks.
public final class WhitegramPluginContributions {
    public static let shared = WhitegramPluginContributions()

    private final class Entry {
        weak var scope: AnyObject?
        let owner: String
        let item: WhitegramPluginMessageMenuItem
        let registration = WhitegramPluginMenuRegistration()
        let queue: DispatchQueue
        let permitted: () -> Bool
        let activate: ([String: Any]) -> Void

        init(scope: AnyObject, owner: String, item: WhitegramPluginMessageMenuItem, queue: DispatchQueue, permitted: @escaping () -> Bool, activate: @escaping ([String: Any]) -> Void) {
            self.scope = scope; self.owner = owner; self.item = item; self.queue = queue; self.permitted = permitted; self.activate = activate
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    public init() {}

    public func register(scope: AnyObject, owner: String, id: String, token: String, title: String, icon: String, priority: Int,
                         queue: DispatchQueue, permitted: @escaping () -> Bool, activate: @escaping ([String: Any]) -> Void) -> WhitegramPluginMenuRegistration? {
        guard !id.isEmpty, id.utf8.count <= 128, !token.isEmpty, token.utf8.count <= 128, !title.isEmpty,
              title.utf8.count <= 512, icon.utf8.count <= 128, (-10000 ... 10000).contains(priority) else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeAll { $0.scope == nil || !$0.registration.isActive }
        let previous = self.entries.first { $0.scope === scope && $0.owner == owner && $0.item.id == id }
        guard previous != nil || self.entries.filter({ $0.scope === scope }).count < 128 else { return nil }
        previous?.registration.dispose()
        self.entries.removeAll { $0 === previous }
        let item = WhitegramPluginMessageMenuItem(token: UUID().uuidString, id: id, title: title, icon: icon, priority: priority)
        let entry = Entry(scope: scope, owner: owner, item: item, queue: queue, permitted: permitted, activate: activate)
        self.entries.append(entry)
        return entry.registration
    }

    public func messageMenu(scope: AnyObject) -> [WhitegramPluginMessageMenuItem] {
        self.lock.lock()
        let entries = self.entries.filter { $0.scope === scope && $0.registration.isActive }
        self.lock.unlock()
        return entries.filter { $0.permitted() }.sorted {
            if $0.item.priority != $1.item.priority { return $0.item.priority > $1.item.priority }
            if $0.owner != $1.owner { return $0.owner < $1.owner }
            return $0.item.id < $1.item.id
        }.map { $0.item }
    }

    public func activate(scope: AnyObject, token: String, payload: [String: Any]) {
        self.lock.lock()
        let entry = self.entries.first { $0.scope === scope && $0.item.token == token && $0.registration.isActive }
        self.lock.unlock()
        guard let entry = entry, entry.permitted(), let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 65536,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        entry.queue.async {
            guard entry.registration.isActive, entry.permitted(), entry.scope != nil else { return }
            entry.activate(payload)
        }
    }
}
