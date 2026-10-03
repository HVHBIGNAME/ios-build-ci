import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

enum WhitegramAccountsScreen { case accounts, keychain, transfer, bots }

struct WhitegramAccountsRow: ItemListNodeEntry {
    enum Kind: Equatable { case action, info, toggle(Bool), selection(Bool) }
    let id: String
    let index: Int
    let section: ItemListSectionId
    let title: String
    let detail: String
    let kind: Kind
    let enabled: Bool
    var stableId: String { return id }
    static func <(lhs: WhitegramAccountsRow, rhs: WhitegramAccountsRow) -> Bool { return lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let actions = arguments as! WhitegramAccountActions
        switch kind {
        case .info:
            return ItemListTextItem(presentationData: presentationData, text: .plain(title), sectionId: section)
        case let .toggle(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: section, style: .blocks, updated: { actions.toggle(self.id, $0) })
        case let .selection(selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: detail.isEmpty ? nil : detail, style: .left, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: section, action: { actions.action(self.id) })
        case .action:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: enabled, label: detail, labelStyle: .multilineDetailText, sectionId: section, style: .blocks, action: { actions.action(self.id) })
        }
    }
}

private func whitegramAccountRows(_ actions: WhitegramAccountActions) -> [WhitegramAccountsRow] {
    var rows: [WhitegramAccountsRow] = []
    func row(_ id: String, _ title: String, _ detail: String = "", section: Int32 = 0, kind: WhitegramAccountsRow.Kind = .action, enabled: Bool? = nil) {
        rows.append(WhitegramAccountsRow(id: id, index: rows.count, section: section, title: title, detail: detail, kind: kind, enabled: enabled ?? !actions.busy))
    }
    let text = actions.text
    if actions.screen == .accounts {
        row("keepUnavailableAccounts", text("Keep unavailable accounts", "Сохранять недоступные аккаунты"), kind: .toggle(WhitegramPreferences.bool("keepUnavailableAccounts")))
        row("accountSwitcherEnabled", text("Account switcher", "Переключатель аккаунтов"), kind: .toggle(WhitegramPreferences.bool("accountSwitcherEnabled")))
        row("keychainAccounts", text("Accounts in Keychain", "Аккаунты в Связке ключей"))
        row("accountTransfer", text("Transfer accounts", "Перенос аккаунтов"))
        row("botAccounts", text("Bot accounts", "Аккаунты ботов"))
        row("add", text("Add Account", "Добавить аккаунт"))
    }
    if actions.screen == .accounts || actions.screen == .bots {
        if actions.screen == .bots { row("botLogin", text("Log in with bot token", "Войти по токену бота")) }
        for account in actions.accounts where actions.screen != .bots || account.peer._asPeer() is TelegramUser && (account.peer._asPeer() as? TelegramUser)?.botInfo != nil {
            let id = account.account.id
            let current = actions.currentId == id
            let frozen = WhitegramAccountFrozenStore.shared.entry(accountId: id.int64)
            var detail = "ID \(account.account.peerId.id._internalGetInt64Value())"
            if account.account.testingEnvironment { detail += " · TEST" }
            if let reason = frozen?.reason { detail += " · " + actions.reason(reason) }
            row("account:\(id.int64)", (current ? "✓ " : "") + account.peer.debugDisplayTitle, detail, section: 1)
        }
        if actions.screen == .accounts {
            let liveIds = Set(actions.accounts.map { $0.account.id })
            for record in actions.records where record.temporarySessionId == nil && !liveIds.contains(record.id) {
                let name = whitegramRecordIdentity(record).map { "ID \($0.userId)" } ?? "\(record.id.int64)"
                row("unavailable:\(record.id.int64)", name, text("Unavailable — retained locally", "Недоступен — сохранён локально"), section: 1)
            }
        }
    }
    if actions.screen == .keychain {
        row("keychainInfo", text("Saved sessions contain account credentials. Restoring verifies each session with Telegram before adding it. New backups are stored only in this device's Keychain.", "Копии содержат ключи доступа к аккаунтам. Перед восстановлением каждый сеанс проверяется в Telegram. Новые копии сохраняются только в Связке ключей этого устройства."), kind: .info)
        row("saveAll", text("Save all active accounts", "Сохранить все активные аккаунты"))
        row("restoreAll", text("Restore saved accounts", "Восстановить сохранённые аккаунты"), enabled: !actions.busy && actions.saved.contains(where: { $0.backup != nil }))
        row("reload", text("Refresh Keychain", "Обновить список"))
        row("diagnostics", text("Keychain diagnostics", "Диагностика Связки ключей"))
        row("deleteAll", text("Delete all saved sessions", "Удалить все сохранённые сеансы"), enabled: !actions.busy && !actions.saved.isEmpty)
        for (index, item) in actions.saved.enumerated() {
            if let backup = item.backup {
                let identity = backup.account.identity
                let title = backup.account.name.isEmpty ? "ID \(identity.userId)" : backup.account.name
                let date = DateFormatter.localizedString(from: backup.date, dateStyle: .short, timeStyle: .short)
                row("saved:\(index)", title, "ID \(identity.userId) · DC\(backup.account.dcId)\(identity.testingEnvironment ? " · TEST" : "") · \(date)", section: 1)
            } else {
                row("saved:\(index)", text("Unreadable saved session", "Нечитаемый сохранённый сеанс"), item.error?.localizedDescription ?? "", section: 1)
            }
        }
        if actions.saved.isEmpty { row("empty", text("No saved sessions", "Сохранённых сеансов нет"), section: 1, kind: .info) }
    }
    if actions.screen == .transfer {
        row("transferInfo", text("Import Telethon .session files together with matching .json sidecars, Whitegram .wgsession archives, ZIPs, or a Telegram Desktop tdata folder. Close the source client before copying its files.", "Импортируйте файлы Telethon .session вместе с соответствующими .json, архивы Whitegram .wgsession, ZIP или папку tdata Telegram Desktop. Перед копированием закройте исходный клиент."), kind: .info)
        row("importFiles", text("Import session files", "Импортировать файлы сеансов"))
        row("importFolder", text("Import tdata folder", "Импортировать папку tdata"))
        row("exportAll", text("Export active accounts", "Экспортировать активные аккаунты"))
    }
    if !actions.pending.isEmpty {
        row("review", text("Review accounts to restore", "Выберите аккаунты для восстановления"), section: 2, kind: .info)
        for (index, backup) in actions.pending.enumerated() {
            let account = backup.account
            let existing = actions.existingIdentities.contains(account.identity)
            let title = account.name.isEmpty ? "ID \(account.identity.userId)" : account.name
            let detail = "ID \(account.identity.userId) · DC\(account.dcId)\(account.identity.testingEnvironment ? " · TEST" : "")" + (existing ? " · " + text("Already present", "Уже добавлен") : "")
            row("pending:\(index)", title, detail, section: 2, kind: .selection(actions.selected.contains(account.identity)), enabled: !actions.busy && !existing)
        }
        row("confirmImport", text("Verify and restore selected accounts", "Проверить и восстановить выбранные"), section: 2, enabled: !actions.busy && !actions.selected.isEmpty)
        row("discardImport", text("Discard import", "Отменить импорт"), section: 2)
    }
    if !actions.status.isEmpty { row("status", actions.status, section: 3, kind: .info) }
    if actions.busy { row("cancel", text("Cancel operation", "Отменить операцию"), section: 3, enabled: true) }
    if let error = WhitegramAccountFrozenStore.shared.error() { row("frozenError", error.localizedDescription, section: 3, kind: .info) }
    return rows
}

func whitegramAccountsController(context: AccountContext, screen: WhitegramAccountsScreen) -> ViewController {
    let actions = WhitegramAccountActions(context: context, screen: screen)
    let signal = combineLatest(context.sharedContext.presentationData, context.sharedContext.activeAccountsWithInfo, context.sharedContext.accountManager.accountRecords(), actions.revision.get())
    |> deliverOnMainQueue
    |> map { presentationData, accounts, view, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        actions.accounts = accounts.accounts
        actions.currentId = accounts.primary
        actions.records = view.records
        let title: String
        switch screen {
        case .accounts: title = actions.text("Accounts", "Аккаунты")
        case .keychain: title = actions.text("Accounts in Keychain", "Аккаунты в Связке ключей")
        case .transfer: title = actions.text("Transfer accounts", "Перенос аккаунтов")
        case .bots: title = actions.text("Bot accounts", "Аккаунты ботов")
        }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: whitegramAccountRows(actions), style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    actions.controller = controller
    return controller
}

public func whitegramAccountsSettingsController(context: AccountContext) -> ViewController { return whitegramAccountsController(context: context, screen: .accounts) }
public func whitegramKeychainAccountsController(context: AccountContext) -> ViewController { return whitegramAccountsController(context: context, screen: .keychain) }
public func whitegramAccountTransferController(context: AccountContext) -> ViewController { return whitegramAccountsController(context: context, screen: .transfer) }
public func whitegramBotAccountsController(context: AccountContext) -> ViewController { return whitegramAccountsController(context: context, screen: .bots) }
