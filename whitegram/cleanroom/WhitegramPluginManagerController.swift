import Foundation
import UIKit
import UniformTypeIdentifiers
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private final class WhitegramPluginManager {
    // Only explicit manager entry creates a session. No application bootstrap
    // evaluates plugins. Account removal tears down that account's sessions.
    private static var managers: [String: WhitegramPluginManager] = [:]
    static func forContext(_ context: AccountContext) -> WhitegramPluginManager {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = String(context.account.id.int64)
        if let manager = self.managers[id], manager.context === context, manager.isAvailable { return manager }
        self.managers[id]?.isAvailable = false
        self.managers[id]?.stopAll()
        let manager = WhitegramPluginManager(context: context, accountId: id)
        self.managers[id] = manager
        manager.observeAccount()
        return manager
    }

    private weak var context: AccountContext?
    let accountId: String
    private let io = DispatchQueue(label: "WhitegramPlugin.Import", qos: .userInitiated)
    private let storage: WhitegramPluginStorage?
    private let accountDisposable = MetaDisposable()
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    private var revision = 0
    private var scheduledUpdate = false
    private var runtimes: [String: WhitegramPluginRuntime] = [:]
    private var deleting: Set<String> = []
    private var isAvailable = true
    private(set) var records: [WhitegramPluginRecord] = []
    private(set) var statuses: [String: WhitegramPluginStatus] = [:]
    private(set) var logs: [String: [WhitegramPluginLogEntry]] = [:]
    private(set) var error: String?
    private(set) var loading = true

    private init(context: AccountContext, accountId: String) {
        self.context = context
        self.accountId = accountId
        do { self.storage = try WhitegramPluginStorage(accountId: accountId) }
        catch { self.storage = nil; self.error = error.localizedDescription }
        self.reload()
    }

    private func observeAccount() {
        guard let context = self.context else { return }
        self.accountDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self = self else { return }
            if !value.accounts.contains(where: { String($0.0.int64) == self.accountId }) {
                self.isAvailable = false
                self.stopAll()
                self.accountDisposable.dispose()
                if Self.managers[self.accountId] === self { Self.managers.removeValue(forKey: self.accountId) }
            }
        }))
    }

    private func changed() {
        guard !self.scheduledUpdate else { return }
        self.scheduledUpdate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.scheduledUpdate = false
            self.revision += 1
            self.updates.set(self.revision)
        }
    }

    private func reload() {
        guard let storage = self.storage else { self.loading = false; self.changed(); return }
        self.io.async { [weak self] in
            let result = Result { try storage.records() }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.loading = false
                switch result {
                case let .success(records): self.records = records; self.error = nil
                case let .failure(error): self.error = error.localizedDescription
                }
                self.changed()
            }
        }
    }

    func install(_ url: URL, completion: @escaping (Result<WhitegramPluginRecord, Error>) -> Void) {
        guard self.isAvailable else { completion(.failure(WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is unavailable"))); return }
        guard let storage = self.storage else { completion(.failure(WhitegramPluginError("STORAGE_UNAVAILABLE", self.error ?? "Plugin directory is unavailable"))); return }
        self.io.async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            let result = Result { try storage.install(from: url) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { [weak self] in
                if case let .success(record) = result { self?.records.append(record); self?.changed() }
                completion(result)
            }
        }
    }

    func start(_ record: WhitegramPluginRecord, from controller: ViewController) {
        guard self.isAvailable, self.runtimes[record.id] == nil, !self.deleting.contains(record.id), self.records.contains(where: { $0.id == record.id }),
              let context = self.context, let storage = self.storage else { return }
        do {
            guard self.runtimes.count < 8 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "At most eight plugins can run in one account") }
            let runtime = WhitegramPluginRuntime(context: context, accountId: self.accountId, record: record, root: try storage.pluginRoot(record.id))
            self.runtimes[record.id] = runtime
            self.statuses[record.id] = .starting
            runtime.attach(controller)
            runtime.logged = { [weak self] entry in
                guard let self = self else { return }
                var entries = self.logs[record.id] ?? []
                entries.append(entry)
                if entries.count > 200 { entries.removeFirst(entries.count - 200) }
                self.logs[record.id] = entries
                self.changed()
            }
            runtime.stateChanged = { [weak self, weak runtime] status in
                guard let self = self, let runtime = runtime, self.runtimes[record.id] === runtime else { return }
                self.statuses[record.id] = self.deleting.contains(record.id) ? .deleting : status
                if status == .failed || status == .stopped { self.runtimes.removeValue(forKey: record.id) }
                self.changed()
            }
            runtime.start()
            self.changed()
        } catch {
            self.statuses[record.id] = .failed
            self.logs[record.id, default: []].append(WhitegramPluginLogEntry(date: Date(), level: "error", message: error.localizedDescription))
            self.changed()
        }
    }

    func attach(_ record: WhitegramPluginRecord, from controller: ViewController) { self.runtimes[record.id]?.attach(controller) }

    func stop(_ id: String, completion: (() -> Void)? = nil) {
        guard let runtime = self.runtimes[id] else { completion?(); return }
        self.statuses[id] = self.deleting.contains(id) ? .deleting : .stopping
        self.changed()
        runtime.stop(completion: completion)
    }

    func stopAll() { for id in Array(self.runtimes.keys) { self.stop(id) } }

    func grants(_ id: String) -> [String: Bool] { return WhitegramPluginPermission.grants(accountId: self.accountId, pluginId: id) }

    func setPermission(_ permission: WhitegramPluginPermission, value: Bool, id: String) {
        guard !self.deleting.contains(id) else { return }
        self.stop(id) { [weak self] in
            guard let self = self, !self.deleting.contains(id), self.records.contains(where: { $0.id == id }) else { return }
            var grants = self.grants(id)
            grants[permission.rawValue] = value
            if !WhitegramPreferences.set(grants, for: WhitegramPluginPermission.key(accountId: self.accountId, pluginId: id)) {
                self.error = "Could not save plugin permissions"
            }
            self.changed()
        }
    }

    func delete(_ id: String, completion: @escaping (Error?) -> Void) {
        guard self.deleting.insert(id).inserted else { completion(WhitegramPluginError("PLUGIN_BUSY", "Plugin deletion is already in progress")); return }
        self.statuses[id] = .deleting
        self.changed()
        self.stop(id) { [weak self] in
            guard let self = self else { completion(WhitegramPluginError("ACCOUNT_UNAVAILABLE", "Account is unavailable")); return }
            guard let storage = self.storage else {
                self.deleting.remove(id)
                self.statuses[id] = .stopped
                self.changed()
                completion(WhitegramPluginError("STORAGE_UNAVAILABLE", "Plugin directory is unavailable"))
                return
            }
            self.io.async { [weak self] in
                let result = Result { try storage.remove(id) }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.deleting.remove(id)
                    switch result {
                    case .success:
                        self.records.removeAll { $0.id == id }
                        self.statuses.removeValue(forKey: id)
                        self.logs.removeValue(forKey: id)
                        _ = WhitegramPreferences.set([String: Bool](), for: WhitegramPluginPermission.key(accountId: self.accountId, pluginId: id))
                        completion(nil)
                    case let .failure(error): self.statuses[id] = .stopped; completion(error)
                    }
                    self.changed()
                }
            }
        }
    }

    func source(_ record: WhitegramPluginRecord, completion: @escaping (Result<String, Error>) -> Void) {
        guard let storage = self.storage else { completion(.failure(WhitegramPluginError("STORAGE_UNAVAILABLE", "Plugin directory is unavailable"))); return }
        self.io.async {
            let result = Result { () throws -> String in
                let files = try WhitegramPluginFiles(root: storage.pluginRoot(record.id))
                guard let data = try files.packageFile(record.entry), let text = String(data: data, encoding: .utf8) else { throw WhitegramPluginError("ENTRY_MISSING", "Entry script is missing") }
                return text
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func clearLogs(_ id: String) { self.logs[id] = []; self.changed() }
}

private final class WhitegramPluginControllerReference {
    weak var value: ViewController?
}

private final class WhitegramPluginListArguments {
    let action: (String) -> Void
    let toggle: (String, Bool) -> Void
    var importer: WhitegramPluginImporter?

    init(action: @escaping (String) -> Void, toggle: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.action = action
        self.toggle = toggle
    }
}

private struct WhitegramPluginEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case text(String)
        case header(String)
        case action(String, Bool)
        case disclosure(String, String)
        case toggle(String, Bool)
    }
    let stableId: String
    let index: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramPluginEntry, rhs: WhitegramPluginEntry) -> Bool { return lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramPluginListArguments
        switch self.content {
        case let .text(text): return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(text): return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .action(title, destructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : .generic,
                alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.action(self.stableId) })
        case let .disclosure(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section,
                style: .blocks, action: { arguments.action(self.stableId) })
        case let .toggle(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section,
                style: .blocks, updated: { arguments.toggle(self.stableId, $0) })
        }
    }
}

private func whitegramPluginListController(context: AccountContext, title: String, manager: WhitegramPluginManager, arguments: WhitegramPluginListArguments, entries: @escaping () -> [WhitegramPluginEntry]) -> ItemListController {
    let state = combineLatest(context.sharedContext.presentationData, manager.updates.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        return (ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil,
            rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries(), style: .blocks, animateChanges: true), arguments))
    }
    return ItemListController(context: context, state: state)
}

private func whitegramPluginAlert(_ controller: ViewController?, title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    controller?.present(alert, animated: true)
}

private final class WhitegramPluginImporter: NSObject, UIDocumentPickerDelegate {
    private let manager: WhitegramPluginManager
    private let completed: (WhitegramPluginRecord) -> Void
    private weak var presenter: ViewController?

    init(manager: WhitegramPluginManager, completed: @escaping (WhitegramPluginRecord) -> Void) {
        self.manager = manager
        self.completed = completed
    }

    func present(from controller: ViewController) {
        self.presenter = controller
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forOpeningContentTypes: [.javaScript, .json, .data], asCopy: true) }
        else { picker = UIDocumentPickerViewController(documentTypes: ["com.netscape.javascript-source", "public.json", "public.data"], in: .import) }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        controller.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        self.manager.install(url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(record): self.completed(record)
            case let .failure(error): whitegramPluginAlert(self.presenter, title: "Import failed", message: error.localizedDescription)
            }
        }
    }
}

private final class WhitegramPluginTextController: ViewController {
    private let textView = UITextView()
    private let textColor: UIColor
    private let background: UIColor
    private var value: String
    private let disposable = MetaDisposable()

    init(context: AccountContext, title: String, text: String, updates: Signal<String, NoError>? = nil) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.textColor = presentationData.theme.list.itemPrimaryTextColor
        self.background = presentationData.theme.list.blocksBackgroundColor
        self.value = text
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData))
        self.title = title
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(self.copyText))
        if let updates = updates { self.disposable.set((updates |> deliverOnMainQueue).start(next: { [weak self] value in self?.value = value; self?.textView.text = value })) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.disposable.dispose() }
    @objc private func copyText() { UIPasteboard.general.string = self.value }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.background
        self.textView.isEditable = false
        self.textView.alwaysBounceVertical = true
        self.textView.font = UIFont(name: "Menlo", size: 12) ?? UIFont.systemFont(ofSize: 12)
        self.textView.textColor = self.textColor
        self.textView.backgroundColor = self.background
        self.textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        self.textView.text = self.value
        self.displayNode.view.addSubview(self.textView)
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.textView.frame = CGRect(x: layout.safeInsets.left, y: top, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0, layout.size.height - top - layout.intrinsicInsets.bottom))
    }
}

private func whitegramPluginDetailController(context: AccountContext, manager: WhitegramPluginManager, record: WhitegramPluginRecord) -> ViewController {
    let reference = WhitegramPluginControllerReference()
    let arguments = WhitegramPluginListArguments(action: { action in
        guard let controller = reference.value else { return }
        manager.attach(record, from: controller)
        switch action {
        case "run": manager.start(record, from: controller)
        case "stop": manager.stop(record.id)
        case "logs":
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let signal = manager.updates.get() |> deliverOnMainQueue |> map { _ -> String in
                let entries = manager.logs[record.id] ?? []
                return entries.isEmpty ? "No log entries yet." : entries.map { "\(formatter.string(from: $0.date)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
            }
            controller.push(WhitegramPluginTextController(context: context, title: record.name + " — Log", text: "", updates: signal))
        case "clearLogs": manager.clearLogs(record.id)
        case "source":
            manager.source(record) { result in
                switch result {
                case let .success(source): reference.value?.push(WhitegramPluginTextController(context: context, title: record.entry, text: source))
                case let .failure(error): whitegramPluginAlert(reference.value, title: "Source unavailable", message: error.localizedDescription)
                }
            }
        case "delete":
            let alert = UIAlertController(title: "Delete \(record.name)?", message: "The imported package and this plugin's saved data will be deleted.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
                manager.delete(record.id) { error in
                    if let error = error { whitegramPluginAlert(reference.value, title: "Delete failed", message: error.localizedDescription) }
                    else { reference.value?.dismiss() }
                }
            }))
            controller.present(alert, animated: true)
        default: break
        }
    }, toggle: { key, value in
        guard let permission = WhitegramPluginPermission(rawValue: key) else { return }
        manager.setPermission(permission, value: value, id: record.id)
    })
    let controller = whitegramPluginListController(context: context, title: record.name, manager: manager, arguments: arguments, entries: {
        let status = manager.statuses[record.id] ?? .stopped
        let active = [.starting, .running, .stopping, .deleting].contains(status)
        var entries: [WhitegramPluginEntry] = [
            WhitegramPluginEntry(stableId: "info", index: 0, section: 0, content: .text("Version \(record.version) · JavaScriptCore\n\(status.rawValue) · \(record.entry)\n\(record.id)")),
            WhitegramPluginEntry(stableId: active ? "stop" : "run", index: 1, section: 1, content: .action(active ? "Stop Plugin" : "Run Plugin", active)),
            WhitegramPluginEntry(stableId: "logs", index: 2, section: 1, content: .disclosure("Log", "\(manager.logs[record.id]?.count ?? 0)")),
            WhitegramPluginEntry(stableId: "source", index: 3, section: 1, content: .disclosure("View Entry Script", "")),
            WhitegramPluginEntry(stableId: "permissions", index: 4, section: 2, content: .header("PERMISSIONS"))
        ]
        let grants = manager.grants(record.id)
        for (index, permission) in WhitegramPluginPermission.allCases.enumerated() {
            entries.append(WhitegramPluginEntry(stableId: permission.rawValue, index: index + 5, section: 2, content: .toggle(permission.title, grants[permission.rawValue] == true)))
        }
        let requested = record.permissions.isEmpty ? "This script declares no permissions." : "Declared: " + record.permissions.joined(separator: ", ") + "."
        entries.append(WhitegramPluginEntry(stableId: "permissionInfo", index: 30, section: 2, content: .text(requested + " Changing permissions stops the running plugin. Run it again to use the new permissions.")))
        entries.append(WhitegramPluginEntry(stableId: "clearLogs", index: 31, section: 3, content: .action("Clear Log", false)))
        entries.append(WhitegramPluginEntry(stableId: "delete", index: 32, section: 3, content: .action("Delete Plugin", true)))
        return entries
    })
    reference.value = controller
    return controller
}

public func whitegramPluginManagerController(context: AccountContext) -> ViewController {
    let manager = WhitegramPluginManager.forContext(context)
    let reference = WhitegramPluginControllerReference()
    let importer = WhitegramPluginImporter(manager: manager, completed: { record in
        reference.value?.push(whitegramPluginDetailController(context: context, manager: manager, record: record))
    })
    let arguments = WhitegramPluginListArguments(action: { action in
        guard let controller = reference.value else { return }
        if action == "import" { importer.present(from: controller) }
        else if action == "stopAll" { manager.stopAll() }
        else if let record = manager.records.first(where: { $0.id == action }) { controller.push(whitegramPluginDetailController(context: context, manager: manager, record: record)) }
    })
    arguments.importer = importer
    let controller = whitegramPluginListController(context: context, title: "Whitegram Plugins", manager: manager, arguments: arguments, entries: {
        var entries: [WhitegramPluginEntry] = [
            WhitegramPluginEntry(stableId: "info", index: 0, section: 0, content: .text("Import a JavaScript file or a JSON .wgplugin package. Open a plugin to inspect its source, set permissions and run it. Plugins start only when you tap Run.")),
            WhitegramPluginEntry(stableId: "import", index: 1, section: 1, content: .action("Import Plugin…", false)),
            WhitegramPluginEntry(stableId: "stopAll", index: 2, section: 1, content: .action("Stop All Plugins", false)),
            WhitegramPluginEntry(stableId: "installed", index: 3, section: 2, content: .header("INSTALLED PLUGINS"))
        ]
        if let error = manager.error { entries.append(WhitegramPluginEntry(stableId: "error", index: 4, section: 2, content: .text(error))) }
        else if manager.records.isEmpty { entries.append(WhitegramPluginEntry(stableId: "empty", index: 4, section: 2, content: .text(manager.loading ? "Loading plugins…" : "No plugins installed."))) }
        for (index, record) in manager.records.enumerated() {
            entries.append(WhitegramPluginEntry(stableId: record.id, index: index + 5, section: 2, content: .disclosure(record.name, (manager.statuses[record.id] ?? .stopped).rawValue)))
        }
        return entries
    })
    reference.value = controller
    return controller
}
