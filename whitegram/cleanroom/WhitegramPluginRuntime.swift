import Foundation
import UIKit
import JavaScriptCore
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display

enum WhitegramPluginStatus: String {
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case deleting = "Deleting"
    case stopped = "Stopped"
    case failed = "Failed"
}

struct WhitegramPluginLogEntry: Equatable {
    let date: Date
    let level: String
    let message: String
}

private final class WhitegramPluginLifetime {
    private let lock = NSLock()
    private var active = true
    private var cancellations: [String: () -> Void] = [:]

    var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active
    }

    func add(_ id: String, cancel: @escaping () -> Void) {
        self.lock.lock()
        if self.active { self.cancellations[id] = cancel; self.lock.unlock() }
        else { self.lock.unlock(); cancel() }
    }

    func remove(_ id: String) {
        self.lock.lock()
        self.cancellations.removeValue(forKey: id)
        self.lock.unlock()
    }

    func cancel() {
        self.lock.lock()
        self.active = false
        let actions = Array(self.cancellations.values)
        self.cancellations.removeAll()
        self.lock.unlock()
        for action in actions { action() }
    }
}

private struct WhitegramPluginAPIEntry {
    let path: String
    let permission: String
    let sync: Bool
    let exposed: Bool

    var json: [String: Any] { return ["path": self.path, "permission": self.permission, "sync": self.sync, "exposed": self.exposed] }
}

private enum WhitegramPluginAPI {
    static let entries: [WhitegramPluginAPIEntry] = {
        var result: [WhitegramPluginAPIEntry] = []
        func add(_ paths: [String], permission: String = "", sync: Bool = true, exposed: Bool = true) {
            for path in paths { result.append(WhitegramPluginAPIEntry(path: path, permission: permission, sync: sync, exposed: exposed)) }
        }
        add(["runtime.info", "runtime.started", "runtime.failed", "permissions.check", "log", "timer.create", "timer.clear", "events.setSubscriptions"], exposed: false)
        add(["interceptors.add", "interceptors.remove"], exposed: false)
        add(["package.resolveModule", "package.list", "package.read"], permission: "storage", exposed: false)
        add(["storage.get", "storage.set", "storage.remove", "storage.keys", "storage.clear"], permission: "storage")
        add(["fs.list", "fs.read", "fs.readBase64", "fs.readBytes", "fs.write", "fs.writeBase64", "fs.writeBytes", "fs.exists", "fs.remove"], permission: "storage")
        add(["preferences.get", "preferences.set", "preferences.values"], permission: "settings")
        add(["clipboard.get", "clipboard.set"], permission: "clipboard")
        add(["capabilities.info"])
        add(["ui.createSurface", "ui.updateSurface", "ui.setSurfaceOptions", "ui.setSurfaceVisible", "ui.closeSurface", "ui.surfaceInfo", "ui.pushScreen", "ui.toast"], permission: "uiMutation", exposed: false)
        add(["ui.registerSettingsPage", "ui.addSettingsRow"], permission: "uiMutation", exposed: false)
        add(["ui.addMenuItem"], permission: "uiMutation", exposed: false)
        add(["ui.theme", "ui.keyboardHeight", "ui.haptic"], permission: "uiMutation")
        add(["ui.confirm", "ui.actionSheet"], permission: "uiMutation", sync: false)
        add(["http.request"], permission: "network", sync: false)
        add(["tg.myId"], permission: "account")
        add(["tg.getMe"], permission: "account", sync: false)
        add(["tg.getPeer", "tg.getChatList", "tg.getMessages", "tg.getMessage", "tg.sendTextMessage", "tg.reply", "tg.sendDiceMessage", "tg.sendLocationMessage", "tg.sendContactMessage",
             "tg.editMessage", "tg.deleteMessage", "tg.forwardMessage", "tg.pinMessage", "tg.reactToMessage", "tg.markChatAsRead", "tg.openChat"], permission: "messages", sync: false)
        add(["tg.sendFileMessage"], permission: "media", sync: false)
        add(["tg.watchMessages"], permission: "messages", sync: false, exposed: false)
        add(["tg.unwatchMessages"], permission: "messages", exposed: false)
        add(["tg.getCurrentChat"], permission: "messages", exposed: false)
        return result
    }()
    static let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
}

final class WhitegramPluginRuntime {
    private struct Request {
        let lifetime: WhitegramPluginLifetime
        let path: String
    }

    let record: WhitegramPluginRecord
    private let accountId: String
    private weak var accountContext: AccountContext?
    private let pluginRoot: URL
    private let queue: DispatchQueue
    private let lifetime = WhitegramPluginLifetime()
    private let http = WhitegramPluginHTTP()
    private let ui: WhitegramPluginUI
    private let iosVersion: String
    private let initialGrants: [String: Bool]
    private let automaticStart: Bool
    private var hookSubscription: WhitegramPluginEventSubscription?
    private var networkSubscription: WhitegramPluginEventSubscription?
    private var interceptions: [String: WhitegramPluginInterceptToken] = [:]
    private var menuRegistrations: [String: WhitegramPluginMenuRegistration] = [:]
    private var js: JSContext?
    private var bootstrapReady = false
    private var didStart = false
    private var stopQueued = false
    private var stopFinished = false
    private var stopCompletions: [() -> Void] = []
    private var files: WhitegramPluginFiles?
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var requests: [String: Request] = [:]
    private var watches: [String: MetaDisposable] = [:]
    private var watchRequests: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private let presentationDisposable = MetaDisposable()
    private var lastException: String?
    private var unloading = false
    private var didCleanUp = false
    private var logWindow = Date()
    private var logCount = 0
    private var startupDeadline: DispatchWorkItem?
    var stateChanged: ((WhitegramPluginStatus) -> Void)?
    var logged: ((WhitegramPluginLogEntry) -> Void)?
    var settingsChanged: (() -> Void)?

    var settingsItems: [WhitegramPluginSettingsItem] {
        dispatchPrecondition(condition: .onQueue(.main))
        return self.ui.settingsItems
    }

    init(context: AccountContext, accountId: String, record: WhitegramPluginRecord, root: URL, automaticStart: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.accountContext = context
        self.accountId = accountId
        self.record = record
        self.pluginRoot = root
        self.queue = DispatchQueue(label: "WhitegramPlugin.JS.\(record.id)", qos: .userInitiated)
        self.ui = WhitegramPluginUI(context: context)
        self.iosVersion = UIDevice.current.systemVersion
        self.initialGrants = WhitegramPluginPermission.grants(accountId: accountId, pluginId: record.id)
        self.automaticStart = automaticStart
        self.ui.dispatch = { [weak self] surface, callback, payload in
            self?.queue.async { [weak self] in
                guard let self = self, self.lifetime.isActive, self.granted("uiMutation") else { return }
                self.callJS("__wgUIDispatch", [surface, callback, payload])
            }
        }
        self.ui.settingsChanged = { [weak self] in self?.settingsChanged?() }
        let subscription = WhitegramPluginHooks.subscribe(postbox: context.account.postbox, queue: self.queue, receive: { [weak self] events, dropped in
            guard let self = self, self.lifetime.isActive, self.granted("messages") else { return }
            if dropped != 0 { self.log("warn", "Telegram event queue dropped \(dropped) observations; the plugin is not keeping up") }
            for event in events {
                guard self.lifetime.isActive, self.granted("messages") else { return }
                self.callJS("__wgNativeEvent", [event.name, event.payload])
            }
        })
        self.hookSubscription = subscription
        self.lifetime.add("events", cancel: { subscription.dispose() })
        let networkSubscription = WhitegramPluginNativeInterception.subscribe(network: context.account.network, queue: self.queue, receive: { [weak self] events, dropped in
            guard let self = self, self.lifetime.isActive, self.granted("telegram.intercept") else { return }
            if dropped != 0 { self.log("warn", "Telegram request event queue dropped \(dropped) observations") }
            for event in events {
                guard self.lifetime.isActive, self.granted("telegram.intercept") else { return }
                self.callJS("__wgNativeEvent", [event.name, event.payload])
            }
        })
        self.networkSubscription = networkSubscription
        self.lifetime.add("networkEvents", cancel: { networkSubscription.dispose() })
    }

    func attach(_ controller: UIViewController) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.ui.attach(controller)
    }

    func activateSettingsItem(_ key: String, from controller: ViewController) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.lifetime.isActive, self.granted("uiMutation") else { return }
        self.ui.attach(controller)
        self.ui.activateSettingsItem(key)
    }

    private func setState(_ state: WhitegramPluginStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if (state == .starting || state == .running) && !self.lifetime.isActive { return }
            self.stateChanged?(state)
        }
    }

    private func log(_ level: String, _ message: String) {
        let now = Date()
        if now.timeIntervalSince(self.logWindow) >= 1 { self.logWindow = now; self.logCount = 0 }
        guard self.logCount < 100 else { return }
        self.logCount += 1
        let level = ["debug", "info", "warn", "error"].contains(level) ? level : "info"
        let entry = WhitegramPluginLogEntry(date: now, level: level, message: String(decoding: message.utf8.prefix(8192), as: UTF8.self))
        DispatchQueue.main.async { [weak self] in self?.logged?(entry) }
    }

    static let resources = ["whitegram-native-bootstrap", "whitegram-sdk-core", "whitegram-plugin-lifecycle", "whitegram-sdk-extensions", "whitegram-sdk-bridge", "whitegram-plugin-host"]

    private func resource(_ name: String) throws -> String {
        guard Self.resources.contains(name) else { throw WhitegramPluginError("INVALID_RESOURCE", name) }
        var url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "WhitegramPluginSDK")
        if url == nil, let bundleURL = Bundle.main.url(forResource: "WhitegramPluginSDK", withExtension: "bundle"), let bundle = Bundle(url: bundleURL) {
            url = bundle.url(forResource: name, withExtension: "js")
        }
        guard let resourceURL = url, let source = String(data: try WhitegramPluginStorage.readLimited(resourceURL), encoding: .utf8) else {
            throw WhitegramPluginError("SDK_MISSING", "Bundle WhitegramPluginSDK/\(name).js with the application")
        }
        return source
    }

    private func evaluate(_ source: String, name: String) throws {
        guard let js = self.js else { throw WhitegramPluginError("RUNTIME_UNAVAILABLE", "JavaScriptCore context is unavailable") }
        self.lastException = nil
        js.exception = nil
        js.evaluateScript(source, withSourceURL: URL(string: "whitegram-plugin:///" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
        if let error = self.lastException { throw WhitegramPluginError("JAVASCRIPT_ERROR", error) }
    }

    private func callJS(_ name: String, _ arguments: [Any]) {
        guard let js = self.js else { return }
        js.exception = nil
        js.objectForKeyedSubscript(name)?.call(withArguments: arguments)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !self.didStart, self.lifetime.isActive else { return }
        self.didStart = true
        self.setState(.starting)
        self.installObservers()
        self.queue.async { [self] in
            guard self.lifetime.isActive else { return }
            do {
                self.files = try WhitegramPluginFiles(root: self.pluginRoot)
                guard let js = JSContext(virtualMachine: JSVirtualMachine()) else { throw WhitegramPluginError("RUNTIME_UNAVAILABLE", "Cannot create JavaScriptCore context") }
                self.js = js
                js.exceptionHandler = { [weak self] _, exception in
                    let message = exception?.toString() ?? "Unknown JavaScript exception"
                    self?.lastException = message
                    self?.log("error", message)
                }
                let hostSync: @convention(block) (String, String) -> String = { [weak self] path, json in
                    guard let self = self else { return "{\"ok\":false,\"error\":{\"code\":\"PLUGIN_STOPPED\",\"message\":\"Plugin stopped\"}}" }
                    return self.syncEnvelope(path, json: json)
                }
                let hostAsync: @convention(block) (String, String, String) -> Void = { [weak self] path, json, token in self?.asyncCall(path, json: json, token: token) }
                js.setObject(hostSync, forKeyedSubscript: "__wgHostSync" as NSString)
                js.setObject(hostAsync, forKeyedSubscript: "__wgHostAsync" as NSString)
                for name in Self.resources.prefix(4) {
                    try self.evaluate(self.resource(name), name: name + ".js")
                    if name == "whitegram-native-bootstrap" { self.bootstrapReady = true }
                }
                try self.evaluate("__wgInstallNativeCompatibility();", name: "install-compatibility.js")
                try self.evaluate(self.resource("whitegram-sdk-bridge"), name: "whitegram-sdk-bridge.js")
                guard let data = try self.files?.packageFile(self.record.entry), let source = String(data: data, encoding: .utf8) else {
                    throw WhitegramPluginError("ENTRY_MISSING", "Plugin entry is missing or is not UTF-8")
                }
                let deadline = DispatchWorkItem { [weak self] in self?.fail("Plugin onLoad did not finish within 30 seconds") }
                self.startupDeadline = deadline
                self.lifetime.add("startup", cancel: { deadline.cancel() })
                self.queue.asyncAfter(deadline: .now() + 30, execute: deadline)
                try self.evaluate(source, name: self.record.entry)
                try self.evaluate("__wgFinishEntry();", name: "finish-entry.js")
            } catch { self.fail(WhitegramPluginError.wrap(error).localizedDescription) }
        }
    }

    private func installObservers() {
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app.foreground"), (UIApplication.didEnterBackgroundNotification, "app.background"),
            (UIApplication.userDidTakeScreenshotNotification, "app.screenshot"), (WhitegramPreferences.updatedNotification, "settings.changed")
        ]
        for (name, event) in events {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self = self, event == "settings.changed",
                   WhitegramPluginPermission.grants(accountId: self.accountId, pluginId: self.record.id) != self.initialGrants {
                    self.stop()
                    return
                }
                self?.queue.async { [weak self] in
                    guard let self = self, self.lifetime.isActive else { return }
                    if event == "settings.changed" && !self.granted("settings") { return }
                    self.callJS("__wgNativeEvent", [event, ["timestamp": Date().timeIntervalSince1970]])
                }
            })
        }
        if let context = self.accountContext {
            self.presentationDisposable.set((context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
                let dark = data.theme.overallDarkAppearance
                self?.queue.async { [weak self] in
                    guard let self = self, self.lifetime.isActive else { return }
                    self.callJS("__wgNativeEvent", ["theme.changed", ["dark": dark]])
                }
            }))
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if self.stopFinished { completion?(); return }
        if let completion = completion { self.stopCompletions.append(completion) }
        guard !self.stopQueued else { return }
        self.stopQueued = true
        self.lifetime.cancel()
        self.http.invalidate()
        self.presentationDisposable.dispose()
        self.ui.stop()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.observers.removeAll()
        self.setState(.stopping)
        self.queue.async { [self] in
            self.cleanUp()
            DispatchQueue.main.async { [self] in
                self.stopFinished = true
                self.stateChanged?(.stopped)
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                for completion in completions { completion() }
            }
        }
    }

    private func fail(_ message: String) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard self.lifetime.isActive, !self.didCleanUp else { return }
        self.log("error", message)
        self.lifetime.cancel()
        self.http.invalidate()
        self.cleanUp()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ui.stop()
            self.presentationDisposable.dispose()
            for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
            self.observers.removeAll()
            self.stateChanged?(.failed)
        }
    }

    private func cleanUp() {
        guard !self.didCleanUp else { return }
        self.didCleanUp = true
        self.unloading = true
        self.startupDeadline?.cancel()
        self.startupDeadline = nil
        if self.bootstrapReady {
            self.callJS("__wgPrepareStop", [])
            do { try self.evaluate(self.resource("whitegram-plugin-host"), name: "whitegram-plugin-host.js") }
            catch { self.log("error", "onUnload: \(error.localizedDescription)") }
            self.callJS("__wgDidStop", [])
        }
        for timer in self.timers.values { timer.cancel() }
        self.timers.removeAll()
        for request in self.requests.values { request.lifetime.cancel() }
        self.requests.removeAll()
        for watch in self.watches.values { watch.dispose() }
        self.watches.removeAll()
        self.watchRequests.removeAll()
        self.hookSubscription?.dispose()
        self.hookSubscription = nil
        self.networkSubscription?.dispose()
        self.networkSubscription = nil
        for token in self.interceptions.values { token.dispose() }
        self.interceptions.removeAll()
        self.menuRegistrations.removeAll()
        self.js?.exceptionHandler = nil
        self.js = nil
        self.bootstrapReady = false
        self.files = nil
        self.unloading = false
    }

    private func granted(_ permission: String) -> Bool {
        return WhitegramPluginPermission.grants(accountId: self.accountId, pluginId: self.record.id)[permission] == true
    }

    private func permissionFailure(_ path: String) -> WhitegramPluginError? {
        guard let entry = WhitegramPluginAPI.byPath[path] else { return WhitegramPluginError("UNSUPPORTED_API", path) }
        var required = entry.permission.isEmpty ? [] : [entry.permission]
        if path == "tg.sendFileMessage" { required.append(contentsOf: ["messages", "storage"]) }
        if path == "tg.openChat" { required.append("uiMutation") }
        if path == "ui.addMenuItem" { required.append("messages") }
        if required.isEmpty { return nil }
        let grants = WhitegramPluginPermission.grants(accountId: self.accountId, pluginId: self.record.id)
        if let missing = required.first(where: { grants[$0] != true }) {
            return WhitegramPluginError("PERMISSION_DENIED", "wg.\(path) requires \(missing)")
        }
        return nil
    }

    private func validate(_ path: String, synchronous: Bool) throws {
        guard self.lifetime.isActive || (self.unloading && (path == "log" || path == "permissions.check" || path.hasPrefix("storage."))) else { throw WhitegramPluginError("PLUGIN_STOPPED", "Plugin is stopped") }
        guard let entry = WhitegramPluginAPI.byPath[path], entry.sync == synchronous else { throw WhitegramPluginError("UNSUPPORTED_API", "No \(synchronous ? "synchronous" : "asynchronous") implementation for wg.\(path)") }
        if let error = self.permissionFailure(path) { throw error }
    }

    private func arguments(_ json: String) throws -> [Any] {
        guard json.utf8.count <= 6 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else { throw WhitegramPluginError("INVALID_ARGUMENT", "Native arguments must be a bounded JSON array") }
        return value
    }

    private func syncEnvelope(_ path: String, json: String) -> String {
        let result: [String: Any]
        do {
            try self.validate(path, synchronous: true)
            result = ["ok": true, "value": try self.syncCall(path, arguments: self.arguments(json))]
        } catch { result = ["ok": false, "error": WhitegramPluginError.wrap(error).json] }
        do { return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]), as: UTF8.self) }
        catch { return "{\"ok\":false,\"error\":{\"code\":\"SERIALIZATION_ERROR\",\"message\":\"Native result is not JSON\"}}" }
    }

    private func capabilities() -> [String: Any] {
        return ["runtime": "JavaScriptCore", "version": "whitegram-native-2", "ios": self.iosVersion,
                "subsystems": ["javascript": "1", "ui": "1", "storage": "1", "http": "1", "tg": "12.9.2"],
                "functions": WhitegramPluginAPI.entries.filter { $0.exposed }.map { $0.path },
                "events": WhitegramPluginHooks.eventNames + WhitegramPluginNativeInterception.eventNames, "eventSemantics": "observational-postbox",
                "interceptors": ["message.beforeSend": ["cancel", "modify", "modifyFinal", "replace"], "tg.request": ["cancel"]],
                "interceptorSemantics": "synchronous-results-async-native-handoff", "deferredInterceptors": false,
                "features": ["javascript": true, "http": true, "localHistory": true, "peerWatches": true, "nativeSurfaces": true,
                             "globalTelegramEvents": true, "pluginSettingsPages": true, "currentChat": true,
                             "globalTelegramHooks": true, "tabs": false, "interceptors": true, "languageWorkers": false, "rawMTProto": false]]
    }

    private func syncCall(_ path: String, arguments: [Any]) throws -> Any {
        switch path {
        case "runtime.info": return ["id": self.record.id, "name": self.record.name, "version": self.record.version, "entry": self.record.entry,
                                     "automaticStart": self.automaticStart,
                                     "packageId": self.record.packageId as Any? ?? NSNull(),
                                     "manifest": WhitegramPluginAPI.entries.map { $0.json },
                                     "events": WhitegramPluginHooks.eventNames + WhitegramPluginNativeInterception.eventNames,
                                     "requestEvents": WhitegramPluginNativeInterception.eventNames]
        case "runtime.started":
            self.startupDeadline?.cancel(); self.startupDeadline = nil; self.lifetime.remove("startup")
            self.log("info", "Plugin started")
            self.setState(.running)
            return true
        case "runtime.failed":
            let message = try whitegramPluginString(arguments, 0)
            self.queue.async { [weak self] in self?.fail(message) }
            return NSNull()
        case "permissions.check": return self.granted(try whitegramPluginString(arguments, 0))
        case "capabilities.info": return self.capabilities()
        case "events.setSubscriptions":
            let allowed = Set(WhitegramPluginHooks.eventNames + WhitegramPluginNativeInterception.eventNames)
            guard arguments.count == 1, let names = arguments[0] as? [String], Set(names).isSubset(of: allowed),
                  names.count <= allowed.count, let subscription = self.hookSubscription, let networkSubscription = self.networkSubscription else {
                throw WhitegramPluginError("INVALID_ARGUMENT", "Expected supported Telegram event names")
            }
            let postboxNames = Set(names).intersection(WhitegramPluginHooks.eventNames)
            let requestNames = Set(names).intersection(WhitegramPluginNativeInterception.eventNames)
            guard postboxNames.isEmpty || self.granted("messages"), requestNames.isEmpty || self.granted("telegram.intercept") else {
                throw WhitegramPluginError("PERMISSION_DENIED", "Telegram events require messages / telegram.intercept permission")
            }
            subscription.setEvents(postboxNames)
            networkSubscription.setEvents(requestNames)
            return true
        case "interceptors.add": return try self.addInterceptor(arguments)
        case "ui.addMenuItem": return try self.addMenuItem(arguments)
        case "interceptors.remove":
            let id = try whitegramPluginString(arguments, 0)
            self.interceptions.removeValue(forKey: id)?.dispose()
            self.lifetime.remove("interceptor:" + id)
            return true
        case "tg.getCurrentChat":
            guard let context = self.accountContext else { throw WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is unavailable") }
            return WhitegramPluginHooks.currentChat(postbox: context.account.postbox) as Any? ?? NSNull()
        case "tg.myId":
            guard let context = self.accountContext else { throw WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is unavailable") }
            return String(context.account.peerId.toInt64())
        case "log": self.log(try whitegramPluginString(arguments, 0), try whitegramPluginString(arguments, 1)); return NSNull()
        case "timer.create":
            let idNumber = try whitegramPluginNumber(arguments, 0)
            let milliseconds = try whitegramPluginNumber(arguments, 1)
            guard let id = Int(exactly: idNumber), id > 0, self.timers[id] == nil, self.timers.count < 256,
                  milliseconds >= 0, milliseconds <= 86400000, arguments.count == 3 else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid timer") }
            let repeats = try whitegramPluginBool(arguments, 2)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let delay = max(repeats ? 0.016 : 0, milliseconds / 1000)
            if repeats { timer.schedule(deadline: .now() + delay, repeating: delay) }
            else { timer.schedule(deadline: .now() + delay) }
            timer.setEventHandler { [weak self] in
                guard let self = self, self.lifetime.isActive else { return }
                if !repeats { self.timers.removeValue(forKey: id)?.cancel(); self.lifetime.remove("timer:\(id)") }
                self.callJS("__wgTimerFire", [id])
            }
            self.timers[id] = timer
            self.lifetime.add("timer:\(id)", cancel: { timer.cancel() })
            timer.resume()
            return id
        case "timer.clear":
            guard let id = Int(exactly: try whitegramPluginNumber(arguments, 0)) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid timer id") }
            self.timers.removeValue(forKey: id)?.cancel(); self.lifetime.remove("timer:\(id)")
            return NSNull()
        case "tg.unwatchMessages":
            let id = try whitegramPluginString(arguments, 0)
            self.watches.removeValue(forKey: id)?.dispose(); self.lifetime.remove("watch:" + id)
            return true
        case "package.list": return try self.requireFiles().packageFiles()
        case "package.resolveModule": return try self.requireFiles().resolveModule(directory: whitegramPluginString(arguments, 0), name: whitegramPluginString(arguments, 1))
        case "package.read":
            guard let data = try self.requireFiles().packageFile(whitegramPluginString(arguments, 0)) else { return NSNull() }
            if arguments.count > 1 && arguments[1] as? Bool == true { return data.base64EncodedString() }
            guard let text = String(data: data, encoding: .utf8) else { throw WhitegramPluginError("INVALID_ENCODING", "Package file is not UTF-8") }
            return text
        case "clipboard.get": return try self.onMain(path: path) { UIPasteboard.general.string as Any? ?? NSNull() }
        case "clipboard.set":
            let text = try whitegramPluginString(arguments, 0)
            return try self.onMain(path: path) { UIPasteboard.general.string = text; return true }
        default:
            if path.hasPrefix("storage.") { return try self.requireFiles().storage(String(path.dropFirst(8)), arguments: arguments) }
            if path.hasPrefix("fs.") { return try self.requireFiles().file(String(path.dropFirst(3)), arguments: arguments) }
            if path.hasPrefix("preferences.") { return try self.preferences(path, arguments: arguments) }
            if path.hasPrefix("ui.") {
                var arguments = arguments
                if path == "ui.createSurface", arguments.count == 3 { arguments[2] = try self.prepareImages(arguments[2]) }
                if path == "ui.updateSurface", arguments.count == 2 { arguments[1] = try self.prepareImages(arguments[1]) }
                return try self.onMain(path: path) { try self.ui.call(path, arguments: arguments) }
            }
            throw WhitegramPluginError("UNSUPPORTED_API", path)
        }
    }

    private func onMain<T>(path: String, _ f: () throws -> T) throws -> T {
        // Main never synchronously waits for this queue. This preserves the
        // recovered createSurface -> ID contract without JSC on the UI thread.
        return try DispatchQueue.main.sync {
            guard self.lifetime.isActive else { throw WhitegramPluginError("PLUGIN_STOPPED", "Plugin stopped before UI operation") }
            if let error = self.permissionFailure(path) { throw error }
            return try f()
        }
    }

    private func requireFiles() throws -> WhitegramPluginFiles {
        guard let files = self.files else { throw WhitegramPluginError("STORAGE_UNAVAILABLE", "Plugin storage is closed") }
        return files
    }

    private func addInterceptor(_ arguments: [Any]) throws -> Bool {
        guard arguments.count == 4, let options = arguments[2] as? [String: Any], let context = self.accountContext else {
            throw WhitegramPluginError("INVALID_ARGUMENT", "Expected interceptor ID, name, options and legacy flag")
        }
        let id = try whitegramPluginString(arguments, 0)
        let name = try whitegramPluginString(arguments, 1)
        let legacy = try whitegramPluginBool(arguments, 3)
        let canonical = name == "onSendMessage" ? "message.beforeSend" : name == "preRequest" ? "tg.request" : name
        guard WhitegramPluginInterceptionHub.names.contains(canonical), !id.isEmpty, id.utf8.count <= 128,
              self.interceptions[id] == nil, self.interceptions.count < 128 else {
            throw WhitegramPluginError("UNSUPPORTED_INTERCEPTOR", "Unsupported, duplicate or excessive interceptor: \(name)")
        }
        guard Set(options.keys).isSubset(of: ["priority", "before", "after"]) else {
            throw WhitegramPluginError("UNSUPPORTED_OPTION", "Native interception supports priority, before and after; its queue deadline is fixed")
        }
        let priorityNumber = try whitegramPluginNumber([options["priority"] ?? 0], 0)
        guard let priority = Int(exactly: priorityNumber), (-10000 ... 10000).contains(priority),
              let before = (options["before"] ?? [String]()) as? [String], let after = (options["after"] ?? [String]()) as? [String],
              before.count <= 32, after.count <= 32, (before + after).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else {
            throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid interceptor ordering")
        }
        let permission = canonical == "message.beforeSend" ? "messages.intercept" : "telegram.intercept"
        guard self.granted(permission) else { throw WhitegramPluginError("PERMISSION_DENIED", "\(name) requires \(permission)") }
        let scope: AnyObject = canonical == "message.beforeSend" ? context.account.postbox : context.account.network
        guard let token = WhitegramPluginInterceptionHub.shared.register(scope: scope, owner: self.record.packageId ?? self.record.id, id: id, name: canonical,
            legacy: legacy, priority: priority, before: before, after: after, queue: self.queue,
            permitted: { [weak self] in self?.lifetime.isActive == true && self?.granted(permission) == true },
            invoke: { [weak self] payload in
                guard let self = self, let js = self.js, self.lifetime.isActive else { return ["action": "cancel", "reason": "PLUGIN_STOPPED"] }
                js.exception = nil
                guard let json = js.objectForKeyedSubscript("__wgNativeIntercept")?.call(withArguments: [id, name, payload, legacy])?.toString(),
                      json.utf8.count <= 65536, let result = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                    return ["action": "cancel", "reason": "INVALID_HOOK_RESULT"]
                }
                return result
            }, diagnostic: { [weak self] message in self?.log("warn", message) }) else {
            throw WhitegramPluginError("INTERCEPT_ORDER", "Interceptor order contains a cycle or exceeds the account quota")
        }
        self.interceptions[id] = token
        self.lifetime.add("interceptor:" + id, cancel: { token.dispose() })
        return true
    }

    private func addMenuItem(_ arguments: [Any]) throws -> String {
        guard let config = arguments.first as? [String: Any], let id = config["id"] as? String, let token = config["token"] as? String,
              let title = config["title"] as? String, let icon = config["icon"] as? String,
              let priority = Int(exactly: try whitegramPluginNumber([config["priority"] ?? 0], 0)),
              let context = self.accountContext, self.menuRegistrations[id] != nil || self.menuRegistrations.count < 32 else {
            throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid or excessive message menu registrations")
        }
        guard let registration = WhitegramPluginContributions.shared.register(scope: context.account.postbox, owner: self.record.id, id: id,
            token: token, title: title, icon: icon, priority: priority, queue: self.queue,
            permitted: { [weak self] in self?.lifetime.isActive == true && self?.granted("messages") == true && self?.granted("uiMutation") == true },
            activate: { [weak self] payload in self?.callJS("__wgUIDispatch", ["__messageMenu", token, payload]) }) else {
            throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid menu metadata or account menu quota exceeded")
        }
        self.menuRegistrations[id]?.dispose()
        self.menuRegistrations[id] = registration
        self.lifetime.add("menu:" + id, cancel: { registration.dispose() })
        return id
    }

    private func preferences(_ path: String, arguments: [Any]) throws -> Any {
        let secrets: Set<String> = ["geminiApiKey", "groqApiKey", "virusTotalApiKey", "voiceChangerApiKey"]
        if path == "preferences.values" { return WhitegramPreferences.values().filter { !$0.key.hasPrefix("pluginRuntime.") && !secrets.contains($0.key) } }
        let key = try whitegramPluginString(arguments, 0)
        guard !key.isEmpty, key.utf8.count <= 256, !key.hasPrefix("pluginRuntime."), !secrets.contains(key) else { throw WhitegramPluginError("PERMISSION_DENIED", "Runtime permissions and service credentials are private") }
        if path == "preferences.get" { return WhitegramPreferences.values()[key] ?? (arguments.count > 1 ? arguments[1] : NSNull()) }
        guard path == "preferences.set", arguments.count == 2 else { throw WhitegramPluginError("INVALID_ARGUMENT", "preferences.set requires key and JSON value") }
        let data = try JSONSerialization.data(withJSONObject: [key: arguments[1]])
        guard data.count <= 65536 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Setting is too large") }
        guard WhitegramPreferences.set(arguments[1], for: key) else { throw WhitegramPluginError("STORAGE_ERROR", "Could not save Whitegram setting") }
        return true
    }

    private func prepareImages(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth <= 24 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "UI tree is too deep") }
        guard var node = value as? [String: Any] else { return value }
        if node["type"] as? String == "image", var props = node["props"] as? [String: Any], let source = props["src"] as? String {
            let bytes: Data
            if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"), let data = Data(base64Encoded: String(source[source.index(after: comma)...])) {
                bytes = data
            } else {
                guard self.granted("storage") else { throw WhitegramPluginError("PERMISSION_DENIED", "Package images require storage") }
                guard let data = try self.requireFiles().packageFile(source) else { throw WhitegramPluginError("FILE_NOT_FOUND", source) }
                bytes = data
            }
            guard bytes.count <= WhitegramPluginStorage.maximumFileBytes else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Image is too large") }
            props["__imageBase64"] = bytes.base64EncodedString()
            node["props"] = props
        }
        if let children = node["children"] as? [Any] { node["children"] = try children.map { try self.prepareImages($0, depth: depth + 1) } }
        return node
    }

    private func asyncCall(_ path: String, json: String, token: String) {
        do {
            try self.validate(path, synchronous: false)
            let arguments = try self.arguments(json)
            guard self.requests[token] == nil, self.requests.count < 128 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Too many native requests") }
            let disposable = MetaDisposable()
            let requestLifetime = WhitegramPluginLifetime()
            let timeout = DispatchWorkItem { [weak self] in self?.complete(token, .failure(WhitegramPluginError("TIMEOUT", "wg.\(path) timed out"))) }
            requestLifetime.add("operation", cancel: { disposable.dispose(); timeout.cancel() })
            self.requests[token] = Request(lifetime: requestLifetime, path: path)
            self.lifetime.add("request:" + token, cancel: { requestLifetime.cancel() })
            self.queue.asyncAfter(deadline: .now() + (path.hasPrefix("ui.") ? 120 : 65), execute: timeout)
            let isActive = { [weak self, weak requestLifetime] in
                guard let self = self, self.lifetime.isActive, requestLifetime?.isActive == true else { return false }
                return self.permissionFailure(path) == nil
            }
            let complete: (Result<Any, WhitegramPluginError>) -> Void = { [weak self] result in self?.queue.async { [weak self] in self?.complete(token, result) } }
            if path == "http.request" {
                guard let options = arguments.first as? [String: Any] else { throw WhitegramPluginError("INVALID_ARGUMENT", "HTTP request expects options") }
                let id = try self.http.request(options, completion: complete)
                disposable.set(ActionDisposable { [weak self] in self?.http.cancel(id) })
            } else if path.hasPrefix("ui.") {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, isActive() else { return }
                    do {
                        let cancel = try self.ui.dialog(path: path, arguments: arguments, completion: complete)
                        disposable.set(ActionDisposable { DispatchQueue.main.async(execute: cancel) })
                    }
                    catch { complete(.failure(WhitegramPluginError.wrap(error))) }
                }
            } else if path == "tg.watchMessages" {
                try self.startWatch(arguments, token: token, isActive: isActive, complete: complete)
            } else {
                var fileData: Data?
                if path == "tg.sendFileMessage" {
                    let filePath = try whitegramPluginString(arguments, 1)
                    if filePath.hasPrefix("package:") { fileData = try self.requireFiles().packageFile(String(filePath.dropFirst(8))) }
                    else if let base64 = try self.requireFiles().file("readBase64", arguments: [filePath]) as? String { fileData = Data(base64Encoded: base64) }
                    guard fileData != nil else { throw WhitegramPluginError("FILE_NOT_FOUND", filePath) }
                }
                let preparedFileData = fileData
                DispatchQueue.main.async { [weak self] in
                    guard isActive() else { return }
                    guard let self = self, let context = self.accountContext else { complete(.failure(WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is unavailable"))); return }
                    do {
                        let signal = try WhitegramPluginTelegram.signal(context: context, path: path, arguments: arguments, fileData: preparedFileData, isActive: isActive)
                        var received = false
                        disposable.set(signal.start(next: { value in received = true; complete(.success(value)) }, error: { complete(.failure($0)) }, completed: {
                            if !received { complete(.failure(WhitegramPluginError("NO_RESULT", "Telegram completed without a result"))) }
                        }))
                    } catch { complete(.failure(WhitegramPluginError.wrap(error))) }
                }
            }
        } catch {
            let error = WhitegramPluginError.wrap(error)
            self.queue.async { [weak self] in
                guard let self = self, self.lifetime.isActive else { return }
                if self.requests[token] != nil { self.complete(token, .failure(error)) }
                else { self.callJS("__wgNativeComplete", [token, ["ok": false, "error": error.json]]) }
            }
        }
    }

    private func complete(_ token: String, _ result: Result<Any, WhitegramPluginError>) {
        guard let request = self.requests.removeValue(forKey: token) else { return }
        var result = result
        if self.lifetime.isActive {
            do { try self.validate(request.path, synchronous: false) }
            catch { result = .failure(WhitegramPluginError.wrap(error)) }
        }
        request.lifetime.cancel()
        self.lifetime.remove("request:" + token)
        if let watchId = self.watchRequests.removeValue(forKey: token), case .failure = result {
            self.watches.removeValue(forKey: watchId)?.dispose()
            self.lifetime.remove("watch:" + watchId)
        }
        guard self.lifetime.isActive else { return }
        let response: [String: Any]
        switch result {
        case let .success(value): response = ["ok": true, "value": value]
        case let .failure(error): response = ["ok": false, "error": error.json]
        }
        self.callJS("__wgNativeComplete", [token, response])
    }

    private func startWatch(_ arguments: [Any], token: String, isActive: @escaping () -> Bool, complete: @escaping (Result<Any, WhitegramPluginError>) -> Void) throws {
        let peer = try whitegramPluginString(arguments, 0)
        let id = try whitegramPluginString(arguments, 1)
        guard self.watches.count < 8, self.watches[id] == nil, let count = Int(exactly: try whitegramPluginNumber(arguments, 2)), (1 ... 100).contains(count) else {
            throw WhitegramPluginError("QUOTA_EXCEEDED", "Invalid watch or more than eight watched peers")
        }
        let watch = MetaDisposable()
        self.watches[id] = watch
        self.watchRequests[token] = id
        self.lifetime.add("watch:" + id, cancel: { watch.dispose() })
        DispatchQueue.main.async { [weak self] in
            guard isActive() else { return }
            guard let self = self, let context = self.accountContext else { complete(.failure(WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is unavailable"))); return }
            do {
                let signal = try WhitegramPluginTelegram.watch(context: context, peer: peer, count: count)
                var first = true
                watch.set(signal.start(next: { [weak self] value in
                    guard let self = self else { return }
                    let initial = first; first = false
                    self.queue.async { [weak self] in
                        guard let self = self, self.lifetime.isActive, self.granted("messages"), self.watches[id] != nil else { return }
                        if initial { complete(.success(id)) }
                        var payload = (value as? [String: Any]) ?? [:]
                        payload["initial"] = initial
                        self.callJS("__wgNativeEvent", ["chat.messages." + id, payload])
                    }
                }, error: { [weak self] error in
                    self?.queue.async { [weak self] in
                        self?.watches.removeValue(forKey: id)?.dispose(); self?.lifetime.remove("watch:" + id)
                        complete(.failure(error))
                    }
                }))
            } catch {
                self.queue.async { [weak self] in
                    self?.watches.removeValue(forKey: id)?.dispose(); self?.lifetime.remove("watch:" + id)
                    complete(.failure(WhitegramPluginError.wrap(error)))
                }
            }
        }
    }
}
