import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext

final class WhitegramAccountActions: NSObject, UIDocumentPickerDelegate {
    let context: AccountContext
    let screen: WhitegramAccountsScreen
    let revision = ValuePromise<Int>(0, ignoreRepeated: false)
    weak var controller: ViewController?
    var accounts: [AccountWithInfo] = []
    var records: [AccountRecord<TelegramAccountRecordAttribute>] = []
    var currentId: AccountRecordId?
    var saved: [WhitegramSavedSession] = []
    var pending: [WhitegramSessionBackup] = []
    var selected = Set<WhitegramSessionIdentity>()
    var status = ""
    private(set) var busy = false
    private let keychain = WhitegramSessionKeychain()
    private let workQueue = DispatchQueue(label: "whitegram.account.operations", qos: .userInitiated)
    private let operation = MetaDisposable()
    private var observers: [NSObjectProtocol] = []
    private var documents: WhitegramAccountDocuments?
    private var exportDirectory: WhitegramSessionStagingDirectory?
    private var generation = 0
    private var revisionNumber = 0
    private var completedImports = 0
    private var localCancellation: WhitegramSessionCancellation?

    var existingIdentities: Set<WhitegramSessionIdentity> {
        var result = Set(records.compactMap(whitegramRecordIdentity))
        for item in accounts { result.insert(WhitegramSessionIdentity(userId: item.account.peerId.id._internalGetInt64Value(), testingEnvironment: item.account.testingEnvironment)) }
        return result
    }

    init(context: AccountContext, screen: WhitegramAccountsScreen) {
        self.context = context
        self.screen = screen
        super.init()
        for name in [WhitegramPreferences.updatedNotification, WhitegramAccountFrozenStore.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.changed() })
        }
        if screen == .keychain { reload() }
    }

    deinit {
        operation.dispose()
        localCancellation?.cancel()
        documents?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func text(_ english: String, _ russian: String) -> String { return context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.hasPrefix("ru") } ? russian : english }
    func changed() { revisionNumber += 1; revision.set(revisionNumber) }
    func reason(_ reason: WhitegramAccountUnavailableReason) -> String {
        switch reason {
        case .unknown: return text("Unavailable", "Недоступен")
        case .deleted: return text("Deleted account", "Аккаунт удалён")
        case .banned: return text("Banned account", "Аккаунт заблокирован")
        case .sessionRevoked: return text("Session revoked", "Сеанс отозван")
        case .frozen: return text("Frozen account", "Аккаунт заморожен")
        }
    }

    func toggle(_ key: String, _ value: Bool) {
        guard !busy else { return }
        if !WhitegramPreferences.set(value, for: key) { status = text("Could not save setting", "Не удалось сохранить настройку") }
        changed()
    }

    private func confirm(_ title: String, message: String, destructive: Bool = false, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: text("Continue", "Продолжить"), style: destructive ? .destructive : .default, handler: { _ in action() }))
        controller?.present(alert, animated: true)
    }

    private func sheet(_ sheet: UIAlertController) {
        guard let controller else { return }
        sheet.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        controller.present(sheet, animated: true)
    }

    private func begin(_ message: String) -> Int {
        generation += 1
        busy = true
        status = message
        changed()
        return generation
    }
    private func finish(_ message: String) { busy = false; status = message; changed() }
    private func fail(_ error: Error) { finish((error as? WhitegramSessionError ?? .unreadable).localizedDescription) }

    private func local<T>(_ message: String, work: @escaping (WhitegramSessionCancellation) throws -> T, completed: @escaping (T) -> Void) {
        let generation = begin(message)
        let cancellation = WhitegramSessionCancellation()
        localCancellation = cancellation
        workQueue.async { [weak self] in
            let result = Result { try cancellation.check(); return try work(cancellation) }
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.busy = false
                self.localCancellation = nil
                switch result {
                case let .success(value): completed(value)
                case let .failure(error): self.fail(error)
                }
            }
        }
    }

    func action(_ id: String) {
        if id == "cancel" { cancel(); return }
        guard !busy else { return }
        switch id {
        case "keychainAccounts": controller?.navigationController?.pushViewController(whitegramKeychainAccountsController(context: context), animated: true)
        case "accountTransfer": controller?.navigationController?.pushViewController(whitegramAccountTransferController(context: context), animated: true)
        case "botAccounts": controller?.navigationController?.pushViewController(whitegramBotAccountsController(context: context), animated: true)
        case "add": context.sharedContext.beginNewAuth(testingEnvironment: false)
        case "botLogin": botLogin()
        case "reload": reload()
        case "diagnostics":
            let keychain = self.keychain
            local(text("Checking Keychain access…", "Проверка доступа к Связке ключей…"), work: { _ in keychain.diagnostics() }) { [weak self] values in
                self?.finish(values.map { "\($0.service): \($0.count) · OSStatus \($0.status)" }.joined(separator: "\n"))
            }
        case "saveAll": save(accounts.map(\.account))
        case "restoreAll": review(saved.compactMap(\.backup))
        case "deleteAll":
            confirm(text("Delete saved sessions?", "Удалить сохранённые сеансы?"), message: text("Delete all listed account-session backups, including compatible legacy services, from this device's Keychain. Active accounts remain logged in.", "Удалить все перечисленные копии сеансов, включая совместимые старые форматы, из Связки ключей этого устройства. Активные аккаунты останутся в приложении."), destructive: true) { [weak self] in self?.deleteSaved(id: nil) }
        case "importFiles": pick(folder: false)
        case "importFolder": pick(folder: true)
        case "exportAll": export(accounts.map(\.account))
        case "discardImport": discardImport()
        case "confirmImport":
            let backups = pending.filter { selected.contains($0.account.identity) }
            completedImports = 0
            let generation = begin(text("Verifying with Telegram…", "Проверка в Telegram…"))
            importNext(backups, generation: generation)
        default:
            if id.hasPrefix("account:"), let rawId = Int64(id.dropFirst(8)), let account = accounts.first(where: { $0.account.id.int64 == rawId }) { accountMenu(account) }
            else if id.hasPrefix("saved:"), let index = Int(id.dropFirst(6)), saved.indices.contains(index) { savedMenu(saved[index]) }
            else if id.hasPrefix("pending:"), let index = Int(id.dropFirst(8)), pending.indices.contains(index) {
                let identity = pending[index].account.identity
                guard !existingIdentities.contains(identity) else { return }
                if selected.contains(identity) { selected.remove(identity) } else { selected.insert(identity) }
                changed()
            } else if id.hasPrefix("unavailable:") { finish(text("This record is retained locally. Use a valid saved session or Add Account to authenticate again.", "Запись сохранена локально. Используйте действующий сохранённый сеанс или «Добавить аккаунт» для повторного входа.")) }
        }
    }

    private func accountMenu(_ item: AccountWithInfo) {
        let menu = UIAlertController(title: item.peer.debugDisplayTitle, message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: text("Switch to account", "Переключиться на аккаунт"), style: .default, handler: { [weak self] _ in
            guard let self, self.accounts.contains(where: { $0.account.id == item.account.id }) else { return }
            self.context.sharedContext.switchToAccount(id: item.account.id, fromSettingsController: self.controller, withChatListController: nil)
        }))
        menu.addAction(UIAlertAction(title: text("Save to Keychain", "Сохранить в Связку ключей"), style: .default, handler: { [weak self] _ in self?.save([item.account]) }))
        menu.addAction(UIAlertAction(title: text("Export session", "Экспортировать сеанс"), style: .default, handler: { [weak self] _ in self?.export([item.account]) }))
        if WhitegramAccountFrozenStore.shared.entry(accountId: item.account.id.int64) != nil {
            menu.addAction(UIAlertAction(title: text("Check authorization again", "Повторно проверить авторизацию"), style: .default, handler: { [weak self] _ in self?.verifyRetained(item.account) }))
        }
        sheet(menu)
    }

    private func reload() {
        let keychain = self.keychain
        local(text("Reading Keychain…", "Чтение Связки ключей…"), work: { _ in try keychain.list() }) { [weak self] items in
            guard let self else { return }
            self.saved = items
            self.finish(self.text("Saved sessions: \(items.count)", "Сохранено сеансов: \(items.count)"))
        }
    }

    private func deleteSaved(id: String?, service: String? = nil) {
        let keychain = self.keychain
        local(text("Deleting saved sessions…", "Удаление сохранённых сеансов…"), work: { _ in
            if let id { try keychain.delete(id: id, service: service) } else { try keychain.deleteAll() }
            return try keychain.list()
        }) { [weak self] items in self?.saved = items; self?.finish(self?.text("Saved sessions deleted.", "Сохранённые сеансы удалены.") ?? "") }
    }

    private func savedMenu(_ item: WhitegramSavedSession) {
        let menu = UIAlertController(title: item.backup?.account.name ?? text("Saved session", "Сохранённый сеанс"), message: item.error?.localizedDescription, preferredStyle: .actionSheet)
        if item.backup != nil {
            menu.addAction(UIAlertAction(title: text("Restore", "Восстановить"), style: .default, handler: { [weak self] _ in
                guard let self else { return }
                let keychain = self.keychain
                self.local(self.text("Reading saved session…", "Чтение сохранённого сеанса…"), work: { _ in try keychain.restore(id: item.id, service: item.service) }) { [weak self] backup in self?.review([backup]) }
            }))
        }
        menu.addAction(UIAlertAction(title: text("Delete backup", "Удалить копию"), style: .destructive, handler: { [weak self] _ in self?.deleteSaved(id: item.id, service: item.service) }))
        sheet(menu)
    }

    private func snapshot(_ accounts: [Account], completion: @escaping ([WhitegramSessionBackup]) -> Void) {
        guard !accounts.isEmpty, accounts.count <= WhitegramSessionBackup.maximumAccounts else { fail(WhitegramSessionError.missingIdentity); return }
        let generation = begin(text("Reading account credentials locally…", "Чтение ключей аккаунтов на устройстве…"))
        operation.set((combineLatest(accounts.map { whitegramSnapshotSession(account: $0) }) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] backups in
            guard let self, self.generation == generation else { return }
            self.busy = false
            completion(backups)
        }, error: { [weak self] error in
            guard let self, self.generation == generation else { return }
            self.fail(error)
        }))
    }

    private func save(_ accounts: [Account]) {
        confirm(text("Save account credentials?", "Сохранить ключи аккаунтов?"), message: text("Save \(accounts.count) session(s) to this device's Keychain, replacing previous backups for the same account and environment.", "Сохранить сеансы (\(accounts.count)) в Связку ключей этого устройства, заменив предыдущие копии тех же аккаунтов и среды.")) { [weak self] in
            self?.snapshot(accounts) { [weak self] backups in
                guard let self else { return }
                let keychain = self.keychain
                self.local(self.text("Saving sessions…", "Сохранение сеансов…"), work: { cancellation in
                    var savedCount = 0
                    for backup in backups {
                        do { try cancellation.check(); try keychain.save(backup); savedCount += 1 }
                        catch { return (savedCount, error as? WhitegramSessionError ?? .storageVerification) }
                    }
                    return (savedCount, Optional<WhitegramSessionError>.none)
                }) { [weak self] count, error in
                    guard let self else { return }
                    self.finish(self.text("Saved and verified \(count) session(s).", "Сохранено и проверено сеансов: \(count).") + (error.map { " " + $0.localizedDescription } ?? ""))
                    if self.screen == .keychain { self.refreshSavedKeepingStatus() }
                }
            }
        }
    }

    private func refreshSavedKeepingStatus() {
        let status = self.status
        let keychain = self.keychain
        local(status, work: { _ in try keychain.list() }) { [weak self] items in self?.saved = items; self?.finish(status) }
    }

    private func export(_ accounts: [Account]) {
        let menu = UIAlertController(title: text("Export account credentials", "Экспорт ключей аккаунтов"), message: text("Anyone with these files can access the exported accounts. Save them in a trusted location.", "Файлы позволяют войти в экспортированные аккаунты. Сохраните их в надёжном месте."), preferredStyle: .actionSheet)
        for (title, telethon) in [("Telethon (.session + .json)", true), ("Whitegram (.wgsession)", false)] {
            menu.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                self?.snapshot(accounts) { [weak self] backups in self?.writeExport(backups, telethon: telethon) }
            }))
        }
        sheet(menu)
    }

    private func writeExport(_ backups: [WhitegramSessionBackup], telethon: Bool) {
        local(text("Preparing session export…", "Подготовка экспорта сеансов…"), work: { cancellation in
            let directory = try WhitegramSessionStagingDirectory()
            var files: [URL] = []
            for backup in backups {
                try cancellation.check()
                if telethon { files += try WhitegramSessionTelethon.write(backup.account, to: directory.url) }
                else {
                    let file = directory.url.appendingPathComponent(backup.account.identity.keychainId.replacingOccurrences(of: ":", with: "-") + ".wgsession")
                    try WhitegramSessionFiles.write(backup.encoded(), to: file)
                    files.append(file)
                }
            }
            let entries = try files.map { WhitegramSessionZip.Entry(name: $0.lastPathComponent, data: try WhitegramSessionFiles.read($0)) }
            let zip = directory.url.appendingPathComponent("whitegram-accounts.zip")
            try WhitegramSessionFiles.write(WhitegramSessionZip.encode(entries), to: zip)
            return (directory, zip)
        }) { [weak self] directory, zip in
            guard let self, let controller = self.controller else { return }
            self.exportDirectory = directory
            self.busy = true
            let picker = UIDocumentPickerViewController(urls: [zip], in: .exportToService)
            picker.delegate = self
            controller.present(picker, animated: true)
            self.changed()
        }
    }

    private func pick(folder: Bool) {
        let picker = UIDocumentPickerViewController(documentTypes: folder ? ["public.folder"] : ["public.data", "public.json", "public.zip-archive"], in: .open)
        picker.allowsMultipleSelection = !folder
        picker.delegate = self
        controller?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if exportDirectory != nil { cleanupExport(cancelled: false); return }
        do {
            let documents = try WhitegramAccountDocuments()
            self.documents = documents
            local(text("Reading session files…", "Чтение файлов сеансов…"), work: { _ in try documents.prepare(urls) }) { [weak self] _ in self?.parseDocuments() }
        } catch { fail(error) }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { if exportDirectory != nil { cleanupExport(cancelled: true) } }

    private func cleanupExport(cancelled: Bool) {
        do { try exportDirectory?.remove(); exportDirectory = nil; finish(text(cancelled ? "Export cancelled." : "Session files exported.", cancelled ? "Экспорт отменён." : "Файлы сеансов экспортированы.")) }
        catch { exportDirectory = nil; finish(text("The export staging files could not be removed. Retry after unlocking the device.", "Не удалось удалить временные файлы экспорта. Повторите после разблокировки устройства.")) }
    }

    private func parseDocuments(passcode: String = "") {
        guard let documents else { return }
        let generation = begin(text("Parsing session files…", "Разбор файлов сеансов…"))
        workQueue.async { [weak self] in
            let result = Result { try documents.parse(passcode: passcode) }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.busy = false
                switch result {
                case let .success(backups): self.review(backups)
                case let .failure(error):
                    if let sessionError = error as? WhitegramSessionError, sessionError == .passcodeRequired || sessionError == .invalidPasscode { self.requestPasscode() }
                    else { self.fail(error) }
                }
            }
        }
    }

    private func requestPasscode() {
        let alert = UIAlertController(title: text("Telegram Desktop passcode", "Локальный пароль Telegram Desktop"), message: text("Enter the local passcode for the selected tdata folder. It is used only on this device.", "Введите локальный пароль выбранной папки tdata. Он используется только на этом устройстве."), preferredStyle: .alert)
        alert.addTextField { $0.isSecureTextEntry = true; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel, handler: { [weak self] _ in self?.discardImport() }))
        alert.addAction(UIAlertAction(title: text("Unlock", "Разблокировать"), style: .default, handler: { [weak self, weak alert] _ in
            let passcode = alert?.textFields?.first?.text ?? ""
            alert?.textFields?.first?.text = ""
            self?.parseDocuments(passcode: passcode)
        }))
        controller?.present(alert, animated: true)
        changed()
    }

    private func review(_ backups: [WhitegramSessionBackup]) {
        do { pending = try WhitegramSessionBackup.unique(backups) }
        catch { fail(error); return }
        selected = Set(pending.map { $0.account.identity }).subtracting(existingIdentities)
        finish(text("Select accounts, then verify them with Telegram to restore. Existing accounts are not replaced.", "Выберите аккаунты и подтвердите проверку в Telegram для восстановления. Существующие аккаунты не заменяются."))
    }

    private func importNext(_ backups: [WhitegramSessionBackup], generation: Int) {
        guard generation == self.generation else { return }
        guard let backup = backups.first else {
            pending = []; selected = []; documents = nil
            finish(text("Verified and added \(completedImports) account(s).", "Проверено и добавлено аккаунтов: \(completedImports)."))
            return
        }
        guard let host = context.sharedContext as? WhitegramAccountSessionHost else { fail(WhitegramSessionError.unavailable); return }
        operation.set((whitegramImportAccount(host: host, accountManager: context.sharedContext.accountManager, login: .session(backup), existingIdentities: existingIdentities) |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.completedImports += 1
            self.pending.removeAll(where: { $0.account.identity == backup.account.identity })
            self.selected.remove(backup.account.identity)
            // Defer installing the next disposable until the previous start() has returned.
            DispatchQueue.main.async { [weak self] in self?.importNext(Array(backups.dropFirst()), generation: generation) }
        }, error: { [weak self] error in
            guard let self, self.generation == generation else { return }
            self.finish(self.text("Added \(self.completedImports) account(s). ", "Добавлено аккаунтов: \(self.completedImports). ") + error.localizedDescription)
        }))
    }

    private func discardImport() {
        documents?.cancel(); documents = nil
        pending = []; selected = []
        finish(text("Import discarded.", "Импорт отменён."))
    }

    private func cancel() {
        generation += 1
        operation.set(nil)
        localCancellation?.cancel()
        localCancellation = nil
        documents?.cancel()
        documents = nil
        finish(text("Operation cancelled. Accounts already verified and added, or Keychain writes already started, are retained.", "Операция отменена. Уже проверенные и добавленные аккаунты и начатые записи в Связку ключей сохраняются."))
    }

    private func botLogin() {
        let alert = UIAlertController(title: text("Bot token", "Токен бота"), message: text("Log in through Telegram with a token from BotFather.", "Вход через Telegram по токену из BotFather."), preferredStyle: .alert)
        alert.addTextField { field in field.isSecureTextEntry = true; field.autocapitalizationType = .none; field.autocorrectionType = .no; field.textContentType = .password }
        alert.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: text("Log In", "Войти"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let host = self.context.sharedContext as? WhitegramAccountSessionHost else { return }
            let token = alert?.textFields?.first?.text ?? ""
            alert?.textFields?.first?.text = ""
            let generation = self.begin(self.text("Authorizing bot with Telegram…", "Авторизация бота в Telegram…"))
            self.operation.set((whitegramImportAccount(host: host, accountManager: self.context.sharedContext.accountManager, login: .bot(token: token, testingEnvironment: false), existingIdentities: self.existingIdentities) |> deliverOnMainQueue).start(next: { [weak self] _ in
                guard let self, self.generation == generation else { return }
                self.finish(self.text("Bot account authorized and added.", "Бот авторизован и добавлен."))
            }, error: { [weak self] error in
                guard let self, self.generation == generation else { return }
                self.fail(error)
            }))
        }))
        controller?.present(alert, animated: true)
    }

    private func verifyRetained(_ account: Account) {
        let generation = begin(text("Checking Telegram authorization…", "Проверка авторизации Telegram…"))
        operation.set((whitegramRecheckRetainedAccount(account: account) |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.finish(self.text("Telegram confirmed this account's authorization.", "Telegram подтвердил авторизацию аккаунта."))
        }, error: { [weak self] error in
            guard let self, self.generation == generation else { return }
            self.fail(error)
        }))
    }
}
