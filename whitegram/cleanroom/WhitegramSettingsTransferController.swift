import Foundation
import UIKit
import UniformTypeIdentifiers
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

public enum WhitegramSettingsTransferAction: String, CaseIterable {
    case exportSettings, importSettings, saveSettingsToKeychain, restoreSettingsFromKeychain

    var title: String {
        switch self {
        case .exportSettings: return "Export Settings to Files"
        case .importSettings: return "Import Settings from Files"
        case .saveSettingsToKeychain: return "Save Settings to Keychain"
        case .restoreSettingsFromKeychain: return "Restore Settings from Keychain"
        }
    }
}

private struct WhitegramSettingsTransferEntry: ItemListNodeEntry {
    let stableId: String
    let order: Int
    let text: String
    let action: Bool
    let enabled: Bool
    var section: ItemListSectionId { return action ? 0 : 1 }

    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if action {
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text,
                kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: section, style: .blocks, action: {
                    if enabled { (arguments as! WhitegramSettingsTransferCoordinator).perform(stableId) }
                })
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section, style: .blocks)
    }
}

private final class WhitegramSettingsTransferCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    let entries = ValuePromise<[WhitegramSettingsTransferEntry]>([], ignoreRepeated: true)
    weak var controller: ItemListController?
    private let queue = DispatchQueue(label: "Whitegram.SettingsTransfer", qos: .userInitiated)
    private let keychain = WhitegramSettingsArchiveKeychain()
    private var operation: WhitegramSettingsTransferWork?
    private var reader: WhitegramSettingsTransferDocumentRead?
    private var exportFile: WhitegramSettingsTransferExportFile?
    private var modal: UIViewController?
    private var exporting = false
    private var didStart = false
    private var observer: NSObjectProtocol?
    private var status = "Choose an operation. Imports change only settings explicitly present in the archive."
    private var summary = "Port format v1. Original IPA backup compatibility is not established."

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.cancelWork() }
        refresh()
    }

    deinit {
        operation?.cancel()
        reader?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let modal { DispatchQueue.main.async { modal.dismiss(animated: false) } }
    }

    func appeared(action: WhitegramSettingsTransferAction?) {
        guard !didStart else { return }
        didStart = true
        DispatchQueue.main.async { [weak self] in self?.perform(action?.rawValue ?? "inspect") }
    }

    func disappeared() { if modal == nil { cancelWork() } }

    private func refresh() {
        let enabled = operation == nil && modal == nil
        var rows = WhitegramSettingsTransferAction.allCases.enumerated().map {
            WhitegramSettingsTransferEntry(stableId: $0.element.rawValue, order: $0.offset, text: $0.element.title, action: true, enabled: enabled)
        }
        rows.append(WhitegramSettingsTransferEntry(stableId: "inspect", order: rows.count, text: "Inspect Portable Settings", action: true, enabled: enabled))
        if operation != nil { rows.append(WhitegramSettingsTransferEntry(stableId: "cancel", order: rows.count, text: "Cancel Pending Operation", action: true, enabled: true)) }
        for (id, text) in [("status", status), ("summary", summary),
            ("scope", "Exports contain allowlisted configuration only. API keys, Telegram sessions, plugin permissions/data, media paths and unrelated device preferences are excluded."),
            ("keychain", "Keychain backups stay on this device, are available only while unlocked, and replace this port's previous settings backup."),
            ("refresh", "Shared settings and public-fork mirrors refresh after import. Compact navigation/list modes can still require the public fork's restart/apply step.")] {
            rows.append(WhitegramSettingsTransferEntry(stableId: id, order: rows.count, text: text, action: false, enabled: true))
        }
        entries.set(rows)
    }

    func perform(_ id: String) {
        if id == "cancel" { cancelWork(); return }
        guard operation == nil, modal == nil else { return }
        switch id {
        case WhitegramSettingsTransferAction.exportSettings.rawValue:
            run({
                let snapshot = try WhitegramSettingsArchiveStore.exportSettings()
                return (snapshot, try WhitegramSettingsTransferExportFile(snapshot.archive))
            }, completed: { [weak self] result in
                guard let self else { return }
                let (snapshot, file) = result
                self.describe(snapshot)
                self.exportFile = file
                let picker: UIDocumentPickerViewController
                if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true) }
                else { picker = UIDocumentPickerViewController(url: file.url, in: .exportToService) }
                self.exporting = true
                self.presentPicker(picker)
            })
        case WhitegramSettingsTransferAction.importSettings.rawValue:
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: false) }
            else { picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .open) }
            exporting = false
            presentPicker(picker)
        case WhitegramSettingsTransferAction.saveSettingsToKeychain.rawValue:
            let keychain = self.keychain
            run({
                let snapshot = try WhitegramSettingsArchiveStore.exportSettings()
                try keychain.save(snapshot.archive)
                return snapshot
            }, completed: { [weak self] snapshot in
                self?.describe(snapshot)
                self?.status = "Saved and read back \(snapshot.archive.keys.count) settings from this device's Keychain."
            })
        case WhitegramSettingsTransferAction.restoreSettingsFromKeychain.rawValue:
            let keychain = self.keychain
            run({ try keychain.restore() }, completed: { [weak self] archive in self?.review(archive) })
        case "inspect":
            run({ try WhitegramSettingsArchiveStore.exportSettings() }, completed: { [weak self] snapshot in
                self?.describe(snapshot)
                self?.status = "Portable configuration inspected. No settings were changed."
            })
        default: break
        }
        refresh()
    }

    private func describe(_ snapshot: WhitegramSettingsArchiveExport) {
        summary = "\(snapshot.archive.keys.count) portable settings · \(WhitegramSettingsArchive.format) v1."
        if !snapshot.omittedInvalidKeys.isEmpty { summary += " Invalid saved values omitted: " + snapshot.omittedInvalidKeys.joined(separator: ", ") }
    }

    private func run<T>(_ work: @escaping () throws -> T, completed: @escaping (T) -> Void) {
        let workState = WhitegramSettingsTransferWork()
        operation = workState
        status = "Working…"
        refresh()
        queue.async { [weak self] in
            guard workState.begin() else { return }
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operation === workState else { return }
                self.operation = nil
                self.reader = nil
                switch result {
                case let .success(value): completed(value)
                case let .failure(error): self.show(error)
                }
                self.refresh()
            }
        }
    }

    private func cancelWork() {
        guard operation != nil else { return }
        operation?.cancel()
        operation = nil
        reader?.cancel()
        reader = nil
        status = "Pending operation cancelled. A Keychain write already in progress may have completed; restore to inspect it."
        refresh()
    }

    private func show(_ error: Error) {
        if let error = error as? WhitegramSettingsArchiveError { status = error.localizedDescription }
        else if let error = error as? WhitegramSettingsArchiveKeychainError { status = error.localizedDescription }
        else if let error = error as? WhitegramSettingsTransferDocumentError { status = error.localizedDescription }
        else { status = "The settings operation failed. No success was recorded. Check that the device is unlocked and the saved settings stores are readable." }
    }

    private func present(_ viewController: UIViewController) -> Bool {
        guard modal == nil, let controller, controller.viewIfLoaded?.window != nil,
              controller.presentedViewController == nil, !controller.isBeingDismissed else {
            status = "The screen is not ready to present a document or confirmation. Try again after the transition."
            return false
        }
        modal = viewController
        controller.present(viewController, animated: true)
        viewController.presentationController?.delegate = self
        refresh()
        return true
    }

    private func presentPicker(_ picker: UIDocumentPickerViewController) {
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        if !present(picker) { cleanExport() }
    }

    private func finishModal(_ completion: @escaping () -> Void) {
        let modal = self.modal
        self.modal = nil
        if let modal { modal.dismiss(animated: true, completion: completion) }
        else { completion() }
    }

    private func cleanExport() {
        do { try exportFile?.remove() }
        catch { status += " Temporary export cleanup failed." }
        exportFile = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard modal === controller else { return }
        if exporting {
            status = urls.isEmpty ? "Export returned no destination." : "Settings document exported."
            cleanExport()
            finishModal { [weak self] in self?.refresh() }
        } else {
            finishModal { [weak self] in
                guard let self else { return }
                guard let url = urls.first else { self.status = "No settings document was selected."; self.refresh(); return }
                let reader = WhitegramSettingsTransferDocumentRead()
                self.reader = reader
                self.run({ try reader.read(url) }, completed: { [weak self] archive in self?.review(archive) })
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard modal === controller else { return }
        status = exporting ? "Settings export cancelled." : "Settings import cancelled."
        cleanExport()
        finishModal { [weak self] in self?.refresh() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard modal === presentationController.presentedViewController else { return }
        modal = nil
        status = "Settings operation dismissed."
        cleanExport()
        refresh()
    }

    private func review(_ archive: WhitegramSettingsArchive) {
        var message = "Apply \(archive.keys.count) validated settings? Missing keys keep their current values."
        if !archive.privacyKeys.isEmpty { message += "\nExplicit privacy/read settings: " + archive.privacyKeys.joined(separator: ", ") }
        if !archive.migratedKeys.isEmpty { message += "\nRecognized port aliases: \(archive.migratedKeys.count)." }
        let alert = UIAlertController(title: "Import Port Settings", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in
            self?.finishModal { [weak self] in self?.status = "Settings import cancelled."; self?.refresh() }
        }))
        alert.addAction(UIAlertAction(title: "Apply", style: .default, handler: { [weak self] _ in
            self?.finishModal { [weak self] in
                guard let self else { return }
                do {
                    let result = try WhitegramSettingsArchiveStore.importSettings(archive)
                    self.status = "Applied \(result.importedKeys.count) settings. Shared preferences and public-fork mirrors refreshed."
                    if result.restartRecommended { self.status += " Apply/restart the public compact mode to update its cached layout." }
                } catch { self.show(error) }
                self.refresh()
            }
        }))
        _ = present(alert)
    }
}

public func whitegramSettingsTransferController(context: AccountContext, action: WhitegramSettingsTransferAction? = nil) -> ViewController {
    let coordinator = WhitegramSettingsTransferCoordinator()
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.entries.get())
    |> deliverOnMainQueue
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let data = ItemListPresentationData(presentationData)
        let state = ItemListControllerState(presentationData: data, title: .text("Settings Backup"), leftNavigationButton: nil,
            rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: data, entries: entries, style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.appeared(action: action) }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
